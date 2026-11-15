#!/usr/bin/env bash
# Container entrypoint: check the USRP, then start the gNB with the mounted config.
set -eu

echo "==> mbs-gnb: $(gnb --version 2>/dev/null | grep -m1 -o 'commit [0-9a-f]*' || echo 'OCUDU gNB')"

if [[ "${SKIP_USRP_CHECK:-0}" != "1" ]]; then
  echo "==> Looking for a USRP B2xx..."
  found=$(uhd_find_devices --args "type=b200" 2>/dev/null || true)
  if ! grep -q "type: b200" <<<"$found"; then
    echo "ERROR: no USRP B2xx found. Is the B210 plugged in (USB 3) and the container started with"
    echo "       --privileged -v /dev/bus/usb:/dev/bus/usb ?  (set SKIP_USRP_CHECK=1 to bypass)"
    exit 1
  fi
  speed=""
  for d in /sys/bus/usb/devices/*/idVendor; do
    if [[ "$(cat "$d" 2>/dev/null)" == "2500" ]]; then speed=$(cat "$(dirname "$d")/speed" 2>/dev/null); break; fi
  done
  echo "==> B2xx found ($(grep -m1 -o 'serial: [0-9A-F]*' <<<"$found" || true)), USB speed ${speed:-unknown} Mb/s"
  if [[ "${speed:-0}" -lt 5000 ]]; then
    echo "WARNING: B210 is not on USB 3 (5000 Mb/s); expect underflows and lost slots."
  fi
fi

# Real-time scheduling like the tested host launch (chrt -f 50). Needs --cap-add SYS_NICE and --ulimit rtprio=99.
if [[ -n "${RT_PRIO:-}" ]]; then
  echo "==> Starting gNB with SCHED_FIFO priority ${RT_PRIO}"
  exec chrt -f "${RT_PRIO}" gnb "$@"
fi
echo "==> Starting gNB"
exec gnb "$@"
