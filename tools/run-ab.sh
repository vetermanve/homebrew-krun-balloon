#!/bin/bash
# A/B run for libkrun balloon free page reclaim.
# Dirties 4 GiB of guest tmpfs, frees it, and records the host footprint of krunkit
# before, during and after, next to the guest's own memory counters.
set -u
PROFILE="${1:-krbal}"
LABEL="${2:-run}"
M="$(dirname "$0")/measure.sh"

echo "=== $LABEL: guest balloon state"
colima --profile "$PROFILE" ssh -- sh -c 'cat /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null; ls /sys/bus/virtio/drivers/virtio_balloon/ 2>/dev/null | head -3'

"$M" "$PROFILE" "$LABEL/idle"

echo "=== $LABEL: dirtying 4 GiB in tmpfs"
colima --profile "$PROFILE" ssh -- sudo sh -c 'mkdir -p /mnt/t; mount -t tmpfs -o size=6g tmpfs /mnt/t 2>/dev/null; dd if=/dev/zero of=/mnt/t/f bs=1M count=4096 2>&1 | tail -1'
"$M" "$PROFILE" "$LABEL/dirty-4g"

echo "=== $LABEL: freeing it"
colima --profile "$PROFILE" ssh -- sudo rm -f /mnt/t/f
for i in 1 2 3 4 5 6; do
  sleep 5
  "$M" "$PROFILE" "$LABEL/freed+$((i*5))s"
done
