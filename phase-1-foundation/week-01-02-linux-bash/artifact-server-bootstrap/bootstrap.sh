#!/usr/bin/env bash
#
# Baseline server bootstrap: admin user, sshd hardening, firewall, auto updates.
# A teaching artifact: it shows the mechanics that cloud-init and Ansible wrap.
# See README.md for what it deliberately does not do.
#
set -euo pipefail

DRY_RUN=0
VERBOSE=1
SSH_PORT=22
USER_NAME=""
SSH_KEY=""
ARGS=()
CHANGED=0          # changes made this run; a second run must report 0
LAST_CHANGED=0     # did the most recent write_file change anything

TMP_FILE=""

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
APT_AUTO=/etc/apt/apt.conf.d/20auto-upgrades

usage() {
  cat <<EOF
Usage: ${0##*/} --user NAME [OPTIONS] [--]

Baseline server bootstrap: admin user setup, sshd, firewall, security updates.

Options:
  -u, --user NAME       admin user to create and configure
  -k, --ssh-key PATH    public key file to install for that user
  -p, --ssh-port PORT   sshd listening port (default: ${SSH_PORT})
  -n, --dry-run         report what would change, change nothing
  -h, --help            show this help and exit

Examples:
  ${0##*/} --user deploy --ssh-key /root/deploy.pub --dry-run
  ${0##*/} --user deploy --ssh-key /root/deploy.pub

Exit codes:
  0  success
  1  runtime failure
  2  usage error
EOF
}

cleanup() {
  [[ -n $TMP_FILE && -e $TMP_FILE ]] && rm -f "$TMP_FILE"
  return 0
}

log() {
  (( VERBOSE )) && echo "[log]: $*" >&2
  return 0
}

die() {
  echo "Error: $*" >&2
  exit 1
}

die_usage() {
  echo "Error: $*" >&2
  echo "Try ${0##*/} --help for reference" >&2
  exit 2
}

# Cannot carry a redirection: `run cmd > file` redirects in the caller's shell
# and would write even under --dry-run.
run() {
  log "RUN: $*"
  (( DRY_RUN )) && return 0
  "$@"
}

write_file() {
  local path="$1" content
  content="$(cat)"
  LAST_CHANGED=0

  if [[ -f $path ]] && cmp -s - "$path" <<<"$content"; then
    log "unchanged: $path"
    return 0
  fi

  LAST_CHANGED=1
  CHANGED=$(( CHANGED + 1 ))

  if (( DRY_RUN )); then
    log "would write: $path"
    return 0
  fi

  # Rename rather than write in place: a reader never sees a half-written
  # config, and a crash mid-write leaves the old one intact.
  TMP_FILE="$path.tmp"
  printf '%s\n' "$content" >"$TMP_FILE"
  mv "$TMP_FILE" "$path"
  TMP_FILE=""
  log "written: $path"
}

preflight() {
  (( EUID == 0 )) || die "must be run as root"
  command -v apt-get >/dev/null || die "needs a Debian/Ubuntu system"
  [[ -n $USER_NAME ]] || die_usage "--user is required"
}

ensure_user() {
  local home ssh_dir auth_keys key_line key_blob sudoers rule

  if id -u "$USER_NAME" >/dev/null 2>&1; then
    log "user exists: $USER_NAME"
  else
    log "creating user: $USER_NAME"
    CHANGED=$(( CHANGED + 1 ))
    run useradd --create-home --shell /bin/bash "$USER_NAME"
  fi

  # `|| true` is load-bearing: getent exits 2 for an unknown user, pipefail
  # promotes that to the pipeline, and set -e would kill the script here
  # before the fallback below could run.
  home="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
  home="${home:-/home/$USER_NAME}"
  ssh_dir="$home/.ssh"
  auth_keys="$ssh_dir/authorized_keys"

  if [[ -n $SSH_KEY ]]; then
    [[ -f $SSH_KEY ]] || die "ssh key file not found: $SSH_KEY"
    key_line="$(head -n1 "$SSH_KEY")"
    key_blob="$(awk '{print $2}' <<<"$key_line")"

    # sshd runs with StrictModes on and silently ignores the key if these are looser.
    run install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$ssh_dir"

    # Appended, not rewritten: write_file would drop keys added by hand.
    # Matched on the base64 blob because the trailing comment differs between
    # machines, and matching the whole line would re-append on every run.
    if [[ -f $auth_keys ]] && grep -qF -- "$key_blob" "$auth_keys"; then
      log "ssh key already installed for $USER_NAME"
    else
      log "installing ssh key for $USER_NAME"
      CHANGED=$(( CHANGED + 1 ))
      if (( ! DRY_RUN )); then
        printf '%s\n' "$key_line" >>"$auth_keys"
      fi
    fi

    run chown "$USER_NAME:$USER_NAME" "$auth_keys"
    run chmod 0600 "$auth_keys"
  fi

  sudoers="/etc/sudoers.d/90-$USER_NAME"
  rule="$USER_NAME ALL=(ALL) NOPASSWD: ALL"
  write_file "$sudoers" <<<"$rule"
  run chmod 0440 "$sudoers"

  # A malformed file here breaks sudo for every user, so take it back out
  # rather than leave it in place.
  if (( ! DRY_RUN )); then
    visudo -cf "$sudoers" >/dev/null \
      || { rm -f "$sudoers"; die "generated sudoers rule is invalid for $USER_NAME"; }
  fi
}

setup_firewall() {
  run apt-get update -qq
  run apt-get install -y -qq ufw

  # The SSH rule must exist before default-deny takes effect, or enabling the
  # firewall cuts the session running this script.
  run ufw allow "${SSH_PORT}/tcp"
  # 22 stays reachable while the port moves; closing it is a manual follow-up.
  (( SSH_PORT == 22 )) || run ufw allow 22/tcp

  run ufw default deny incoming
  run ufw default allow outgoing

  # Captured for the same SIGPIPE reason as verify(): piping into `grep -q`
  # makes the result a race between grep exiting and ufw finishing its output.
  local ufw_state; ufw_state="$(ufw status 2>/dev/null || true)"
  if grep -q '^Status: active' <<<"$ufw_state"; then
    log "ufw already active"
  else
    log "enabling ufw"
    CHANGED=$(( CHANGED + 1 ))
    run ufw --force enable
  fi
}

harden_ssh() {
  # Named 00-* deliberately: sshd reads sshd_config.d/*.conf in lexical order
  # and keeps the FIRST value per keyword, so Ubuntu's 50-cloud-init.conf
  # would otherwise win and leave password login enabled.
  write_file "$SSHD_DROPIN" <<EOF
# Managed by ${0##*/} — do not edit by hand.
Port $SSH_PORT
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
AllowUsers $USER_NAME
EOF
  run chmod 0644 "$SSHD_DROPIN"

  (( LAST_CHANGED )) || { log "sshd config unchanged, no reload needed"; return 0; }

  # Validate first: sshd refuses to start on a bad config, which on a
  # firewalled box means no way back in. Reload, not restart — existing
  # sessions are separate forks and survive it.
  run sshd -t
  run systemctl reload ssh
}

security_updates() {
  run apt-get install -y -qq unattended-upgrades

  write_file "$APT_AUTO" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  run chmod 0644 "$APT_AUTO"

  # These timers do the periodic work, reading APT::Periodic::* from the file
  # above. unattended-upgrades.service is only the shutdown handler and enabling
  # it proves nothing about whether upgrades actually run.
  run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

# Asserts what the system reports, not what was written: a config file can be
# present, correct and completely ignored.
verify() {
  if (( DRY_RUN )); then
    log "dry-run: skipping verification"
    return 0
  fi

  local sshd_conf ufw_state apt_conf

  # Captured, not piped into grep: `grep -q` exits on the first match and closes
  # the pipe, the producer dies of SIGPIPE (141), and pipefail turns a matching
  # check into a failing one. It is a race — short output usually survives,
  # which makes it worse than a consistent bug.
  sshd_conf="$(sshd -T)"
  ufw_state="$(ufw status)"
  apt_conf="$(apt-config dump)"

  log "verifying effective state"
  id -u "$USER_NAME" >/dev/null 2>&1 || die "verify: user $USER_NAME is missing"
  grep -qix "passwordauthentication no" <<<"$sshd_conf" || die "verify: sshd still accepts passwords"
  grep -qix "allowusers $USER_NAME"     <<<"$sshd_conf" || die "verify: sshd does not allow $USER_NAME"
  grep -qix "port $SSH_PORT"            <<<"$sshd_conf" || die "verify: sshd is not on port $SSH_PORT"
  grep -q  '^Status: active'            <<<"$ufw_state" || die "verify: ufw is not active"
  grep -q  '^APT::Periodic::Unattended-Upgrade "1";$' <<<"$apt_conf" \
    || die "verify: automatic upgrades are switched off"
  systemctl is-enabled --quiet apt-daily-upgrade.timer \
    || die "verify: apt-daily-upgrade.timer is not enabled"
  log "verified"
}

parse_args() {
  local a ddash=0
  local -a argv=()

  # Split --opt=value once, so the loop below handles a single form. Stops at
  # --, after which arguments pass through untouched.
  for a in "$@"; do
    if (( ddash )); then argv+=("$a"); continue; fi
    case $a in
      --)    ddash=1; argv+=("$a") ;;
      --*=*) argv+=("${a%%=*}" "${a#*=}") ;;
      *)     argv+=("$a") ;;
    esac
  done
  set -- ${argv+"${argv[@]}"}

  while (( $# )); do
    case "$1" in
      -u|--user)     USER_NAME="${2:-}"; shift 2 ;;
      -k|--ssh-key)  SSH_KEY="${2:-}";   shift 2 ;;
      -p|--ssh-port) SSH_PORT="${2:-}";  shift 2 ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      --)            shift; ARGS+=("$@"); break ;;
      -*)            die_usage "unknown option: $1" ;;
      *)             ARGS+=("$1"); shift ;;
    esac
  done
}

main() {
  parse_args "$@"
  preflight
  ensure_user       # the key must exist before AllowUsers points at this account
  setup_firewall    # the port must be open before sshd starts listening on it
  harden_ssh
  security_updates
  verify
  log "done — changes applied: $CHANGED"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Guarded so tests can source the file without configuring the machine.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
