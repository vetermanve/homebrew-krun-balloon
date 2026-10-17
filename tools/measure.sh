#!/bin/bash
# Snapshot host footprint of the krunkit process plus guest memory for a colima profile.
# Usage: measure.sh <profile> <tag>
set -u
PROFILE="${1:-krbal}"
TAG="${2:-snapshot}"
PID=$(pgrep -f "krunkit --memory" | head -1)
if [ -z "$PID" ]; then
  echo "$TAG: no krunkit process"
  exit 1
fi
FOOT=$(vmmap --summary "$PID" 2>/dev/null | awk -F: '/Physical footprint:/ {gsub(/ /,"",$2); print $2; exit}')
GUEST=$(colima --profile "$PROFILE" ssh -- grep -E '^(MemTotal|MemFree|MemAvailable):' /proc/meminfo 2>/dev/null | tr -s ' \n' ' ')
HOSTFREE=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); printf "%d MiB", $3*16384/1048576}')
printf '%-24s pid=%-7s footprint=%-10s hostfree=%-10s guest=[%s]\n' "$TAG" "$PID" "$FOOT" "$HOSTFREE" "$GUEST"
