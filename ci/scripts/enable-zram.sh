#!/usr/bin/env bash
# Enable compressed swap on ephemeral Linux CI runners before memory-heavy builds.
set -euo pipefail

if ! command -v zramctl >/dev/null 2>&1 || ! command -v swapon >/dev/null 2>&1; then
    echo "ERROR: zramctl/swapon are required to configure CI zram" >&2
    exit 1
fi

if sudo swapon --show=NAME --noheadings | awk '$1 ~ /^\/dev\/zram/ { found=1 } END { exit(found ? 0 : 1) }'; then
    echo "zram swap is already active"
    sudo zramctl
    sudo swapon --show
    # This helper is sourced by setup-runner.sh; do not terminate its caller.
    return 0 2>/dev/null || exit 0
fi

if ! sudo modprobe zram && [ ! -d /sys/class/zram-control ]; then
    echo "ERROR: the runner kernel does not provide the zram module" >&2
    exit 1
fi

mem_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
test -n "$mem_kib"
size_mib=$((mem_kib / 1024 / 2))
if [ "$size_mib" -lt 4096 ]; then
    size_mib=4096
elif [ "$size_mib" -gt 16384 ]; then
    size_mib=16384
fi

zram_device="$(sudo zramctl --find --size "${size_mib}M")"
test -n "$zram_device"
sudo mkswap -f "$zram_device" >/dev/null
sudo swapon --priority 100 "$zram_device"

echo "Enabled ${size_mib} MiB compressed swap on ${zram_device}"
sudo zramctl "$zram_device"
sudo swapon --show
