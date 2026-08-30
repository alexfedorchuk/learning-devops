#!/usr/bin/env bash
#
# Periodic health summary: disk, inodes, memory, load, failed units, pending reboot.
#
# The summary always goes to stdout — under the timer that is the journal, so
# history and rotation are already solved (journalctl -u lab-monitor).
# Telegram is not a log: a message is sent only when the SET of active alerts
# changes, so a problem notifies once and a recovery notifies once.
#
# Installed by bootstrap.sh as /usr/local/sbin/lab-monitor.
#
set -euo pipefail

ENV_FILE=/etc/lab-monitor.env
STATE_DIR=/var/lib/lab-monitor
STATE_FILE="$STATE_DIR/alerts"

# Thresholds, overridable from the environment for testing:
#   sudo env DISK_PCT=0 /usr/local/sbin/lab-monitor
DISK_PCT="${DISK_PCT:-85}"
INODE_PCT="${INODE_PCT:-85}"
MEM_AVAIL_PCT="${MEM_AVAIL_PCT:-10}"
LOAD_FACTOR="${LOAD_FACTOR:-1.5}"
MOUNT="${MOUNT:-/}"

DRY_RUN=0
ALERTS=()          # entries are "key|human readable message"
HOST="${HOSTNAME:-$(uname -n)}"

usage() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Health summary for this machine. Prints to stdout; sends a Telegram message
only when the set of active alerts changes.

Options:
  -n, --dry-run   print the summary and any message, send nothing, keep state
  -h, --help      show this help and exit

Environment (thresholds, all optional):
  DISK_PCT=${DISK_PCT}         alert above this percentage used on \$MOUNT
  INODE_PCT=${INODE_PCT}        alert above this percentage of inodes used
  MEM_AVAIL_PCT=${MEM_AVAIL_PCT}     alert below this percentage of MemAvailable
  LOAD_FACTOR=${LOAD_FACTOR}     alert above nproc * this, on the 5-minute average
  MOUNT=${MOUNT}             filesystem to check

Credentials are read from ${ENV_FILE} (mode 0600, never committed):
  TELEGRAM_BOT_TOKEN=...
  TELEGRAM_CHAT_ID=...

Exit codes:
  0  ran (alerts are reported, not signalled by the exit code)
  1  runtime failure
  2  usage error
EOF
}

log() {
  echo "$*"
  return 0
}

warn() {
  echo "warning: $*" >&2
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

alert() {
  ALERTS+=("$1|$2")
}

check_disk() {
  local used
  # -P forces one line per filesystem: without it a long device name wraps and
  # the awk field numbers shift.
  used="$(df -P "$MOUNT" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  log "disk:   ${used}% used on ${MOUNT} (alert above ${DISK_PCT}%)"
  if (( used > DISK_PCT )); then
    alert disk "disk ${used}% used on ${MOUNT}"
  fi
}

check_inodes() {
  local used
  used="$(df -iP "$MOUNT" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"

  # Filesystems that allocate inodes dynamically (btrfs, tmpfs, overlay) report
  # "-" here. Not a number, not a problem — nothing to threshold.
  if [[ ! $used =~ ^[0-9]+$ ]]; then
    log "inodes: not applicable on ${MOUNT}"
    return 0
  fi

  log "inodes: ${used}% used on ${MOUNT} (alert above ${INODE_PCT}%)"
  if (( used > INODE_PCT )); then
    alert inodes "inodes ${used}% used on ${MOUNT}"
  fi
}

check_memory() {
  local total avail pct
  total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  # MemAvailable, not MemFree: free memory on a healthy machine is near zero
  # because the page cache took the rest. MemAvailable is the kernel's own
  # estimate of what a new process could get without swapping.
  avail="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
  pct=$(( avail * 100 / total ))

  log "memory: ${pct}% available, $(( avail / 1024 )) MiB of $(( total / 1024 )) MiB (alert below ${MEM_AVAIL_PCT}%)"
  if (( pct < MEM_AVAIL_PCT )); then
    alert memory "only ${pct}% memory available ($(( avail / 1024 )) MiB)"
  fi
}

check_load() {
  local load5 cores limit
  # Fields: 1-min 5-min 15-min running/total lastpid. The 1-minute figure is
  # noise for a job that runs every 15 minutes — any apt run spikes it.
  read -r _ load5 _ </proc/loadavg
  cores="$(nproc)"

  # Load is a count of runnable AND uninterruptible-sleep tasks, so it only
  # means something divided by the core count. Bash has no floating point:
  # the comparison goes to awk.
  limit="$(awk -v n="$cores" -v f="$LOAD_FACTOR" 'BEGIN { printf "%.2f", n * f }')"
  log "load:   ${load5} 5-min average on ${cores} cores (alert above ${limit})"
  if awk -v l="$load5" -v m="$limit" 'BEGIN { exit !(l > m) }'; then
    alert load "load ${load5} on ${cores} cores"
  fi
}

check_failed_units() {
  local failed count names
  # --plain drops the bullet systemd otherwise prints in front of a failed unit,
  # which would shift every field by one.
  failed="$(systemctl list-units --state=failed --plain --no-legend --no-pager || true)"

  if [[ -z $failed ]]; then
    log "units:  0 failed"
    return 0
  fi

  count="$(grep -c . <<<"$failed")"
  names="$(awk '{ print $1 }' <<<"$failed" | tr '\n' ' ')"
  log "units:  ${count} failed — ${names}"
  alert units "${count} failed unit(s): ${names}"
}

check_reboot() {
  # /var/run is a compatibility symlink to /run; use the real path.
  if [[ ! -e /run/reboot-required ]]; then
    log "reboot: not required"
    return 0
  fi

  local pkgs=""
  if [[ -f /run/reboot-required.pkgs ]]; then
    pkgs="$(sort -u /run/reboot-required.pkgs | tr '\n' ' ')"
  fi

  log "reboot: required — ${pkgs:-unknown package}"
  # Automatic security updates install a new kernel but keep running the old
  # one until a reboot, so "updates are automatic" is only half the story.
  alert reboot "reboot required for: ${pkgs:-unknown package}"
}

# Sends one message. Returns non-zero when it did not reach Telegram, so the
# caller can leave the state file alone and retry on the next run.
notify() {
  local text="$1" esc

  if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
    warn "telegram is not configured in ${ENV_FILE}; message not sent"
    return 1
  fi

  # curl config quoting: backslashes and quotes first, then newlines as \n —
  # a quoted value in a config file cannot span lines.
  esc="${text//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"

  # --config - reads the request from stdin. The token is part of the URL, and
  # a URL on the command line is visible in `ps` to every user on the box for
  # as long as curl runs.
  if ! curl --silent --show-error --fail --max-time 15 --config - >/dev/null <<EOF
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
data-urlencode = "chat_id=${TELEGRAM_CHAT_ID}"
data-urlencode = "text=${esc}"
EOF
  then
    warn "sending the telegram message failed"
    return 1
  fi

  return 0
}

# The state file holds the sorted alert keys, one per line; an absent or empty
# file means "everything was fine". Comparing the whole set — not a single
# ok/alert flag — means a NEW problem appearing while another is still active
# still notifies.
report() {
  local entry current previous message
  local -a keys=()

  for entry in "${ALERTS[@]:-}"; do
    [[ -n $entry ]] || continue
    keys+=("${entry%%|*}")
  done

  current=""
  if (( ${#keys[@]} > 0 )); then
    current="$(printf '%s\n' "${keys[@]}" | sort)"
  fi

  previous="$(cat "$STATE_FILE" 2>/dev/null || true)"

  if [[ $current == "$previous" ]]; then
    log "state unchanged, no notification"
    return 0
  fi

  if [[ -z $current ]]; then
    message="OK ${HOST}: all checks back to normal"
  else
    message="ALERT ${HOST}:"
    for entry in "${ALERTS[@]}"; do
      message+=$'\n'"- ${entry#*|}"
    done
  fi

  if (( DRY_RUN )); then
    log "dry-run: would send and record this message:"
    log "$message"
    return 0
  fi

  # State is written only after the message is actually delivered. Recording it
  # first would swallow the transition: the alert would be lost and never resent.
  if notify "$message"; then
    install -d -m 0700 "$STATE_DIR"
    printf '%s\n' "$current" >"$STATE_FILE"
    log "notified, state recorded"
  else
    warn "state not recorded; the notification will be retried on the next run"
  fi
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            die_usage "unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  (( EUID == 0 )) || die "must be run as root"

  # Sourced here rather than declared as EnvironmentFile= in the unit, so that
  # running the script by hand behaves exactly like running it under the timer.
  if [[ -r $ENV_FILE ]]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
  fi

  log "health summary for ${HOST}"
  check_disk
  check_inodes
  check_memory
  check_load
  check_failed_units
  check_reboot
  report
}

trap 'exit 130' INT
trap 'exit 143' TERM

# Guarded so tests can source the file without running any checks.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
