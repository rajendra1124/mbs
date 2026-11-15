#!/usr/bin/env bash
# Optional real-time tuning of the gNB host (needs sudo; settings are lost on reboot).
# Reduces SDR underflows/late samples. Same settings as the tested lab host.
#   sudo ./host-tune.sh [irq_cpus=0-3,8-11]
set -uo pipefail
IRQ_CPUS="${1:-0-3,8-11}"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

echo "==> CPU governor: performance"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done

echo "==> Disabling deep CPU C-states (C1E and deeper)"
for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]; do
  [[ -f "$state/disable" ]] && echo 1 > "$state/disable"
done

echo "==> Larger socket buffers (USB/UDP sample streaming)"
for k in wmem_max rmem_max wmem_default rmem_default; do sysctl -qw net.core.$k=33554432; done

echo "==> Moving IRQs to CPUs $IRQ_CPUS (keep the gNB on the others, e.g. CPUS=4-7,12-15 ../gnb/start.sh)"
systemctl stop irqbalance 2>/dev/null || true
for d in /proc/irq/[0-9]*/; do echo "$IRQ_CPUS" > "$d/smp_affinity_list" 2>/dev/null || true; done

echo "Done. USB check (B210 must show 5000M):"
lsusb -t | grep -B1 -i "5000M" | head -4
