#!/usr/bin/env bash
# Find and probe the USRP with the bundled UHD (no UHD installation needed).
#   ./check-usrp.sh            uhd_find_devices + uhd_usrp_probe (loads the FPGA image, ~10 s)
#   ./check-usrp.sh find       uhd_find_devices only
set -euo pipefail
cd "$(dirname "$0")"
run() { env UHD_IMAGES_DIR="$PWD/share/uhd/images" lib/ld-linux-x86-64.so.2 --library-path lib --argv0 "$1" "bin/$1" "${@:2}"; }
run uhd_find_devices --args "type=b200"
[[ "${1:-}" == find ]] || run uhd_usrp_probe --args "type=b200" 2>&1 | grep -E 'Operating over|Device: |Mboard: |serial|FPGA|Error|error' || true
