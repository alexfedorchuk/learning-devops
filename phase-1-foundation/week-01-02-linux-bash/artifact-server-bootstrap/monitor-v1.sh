#!/usr/bin/env bash
#
# Health summary, version 1: the smallest thing that meets the requirement.
# Prints disk, inodes, memory, load, failed units and pending reboot, and sends
# a Telegram message when a threshold is crossed.
#
# A teaching step, kept on purpose — bootstrap.sh installs monitor.sh instead.
# The difference between the two files is a list of failures this version has.
#
set -euo pipefail

DISK_PCT=85
INODE_PCT=85
MEM_AVAIL_PCT=10
LOAD_FACTOR=1.5

alerts=()

disk="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
inodes="$(df -iP / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
mem="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d", a * 100 / t }' /proc/meminfo)"
read -r _ load5 _ </proc/loadavg
cores="$(nproc)"
failed="$(systemctl list-units --state=failed --plain --no-legend --no-pager)"

echo "disk:   ${disk}% used"
echo "inodes: ${inodes}% used"
echo "memory: ${mem}% available"
echo "load:   ${load5} 5-min average on ${cores} cores"
echo "units:  ${failed:-0 failed}"
echo "reboot: $( [[ -e /run/reboot-required ]] && echo required || echo "not required" )"

# `if`, not `(( ... )) && alerts+=(...)`: under set -e a false test makes the
# whole && list exit 1 and kills the script.
if (( disk > DISK_PCT )); then alerts+=("disk ${disk}% used"); fi
if (( inodes > INODE_PCT )); then alerts+=("inodes ${inodes}% used"); fi
if (( mem < MEM_AVAIL_PCT )); then alerts+=("only ${mem}% memory available"); fi
if awk -v l="$load5" -v n="$cores" -v f="$LOAD_FACTOR" 'BEGIN { exit !(l > n * f) }'; then
  alerts+=("load ${load5} on ${cores} cores")
fi
if [[ -n $failed ]]; then alerts+=("failed units: $(awk '{ print $1 }' <<<"$failed" | tr '\n' ' ')"); fi
if [[ -e /run/reboot-required ]]; then alerts+=("reboot required"); fi

if (( ${#alerts[@]} == 0 )); then
  exit 0
fi

if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
  echo "warning: telegram is not configured; alerts not sent" >&2
  exit 0
fi

curl --silent --show-error --max-time 15 \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=ALERT $(uname -n): $(printf '%s; ' "${alerts[@]}")" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
