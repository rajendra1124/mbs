#!/usr/bin/env bash
# One-time: let normal users open the USRP (udev rules for Ettus USB devices). Run: sudo ./setup-usb.sh
# Then unplug and replug the B210. Not needed if UHD (uhd-host) is already installed on this PC.
set -euo pipefail
cd "$(dirname "$0")"
[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
if grep -qsE 'idVendor\}?==?"2500"' /etc/udev/rules.d/*.rules /lib/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
  echo "USRP udev rules already installed."
else
  install -m 644 udev/60-uhd-usrp.rules /etc/udev/rules.d/60-uhd-usrp.rules
  echo "Installed /etc/udev/rules.d/60-uhd-usrp.rules"
fi
udevadm control --reload-rules && udevadm trigger
echo "Done. Unplug and replug the B210, then: ./ue/start.sh"
