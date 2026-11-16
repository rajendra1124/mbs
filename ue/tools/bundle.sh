#!/usr/bin/env bash
# Collect a built srsue_mbs into the self-contained layout used by ue/start.sh:
#   bin/    srsue_mbs + uhd_find_devices, uhd_usrp_probe
#   lib/    every shared library they load, including glibc and its loader (ld-linux-x86-64.so.2)
#   share/  USRP B200/B210 firmware and FPGA images matching the bundled UHD
#   udev/   USB permission rules for the USRP (installed once by ue/setup-usb.sh)
# The bundled loader runs the UE with only these libraries, so the host needs no UHD, Boost, FFTW, ...
#
# Usage: tools/bundle.sh <build-dir> [<ue-dir>]     (called by ue/build-from-source.sh)
set -euo pipefail
BUILD="$(cd "${1:?usage: bundle.sh <build-dir> [<ue-dir>]}" && pwd)"
UE_DIR="$(cd "${2:-$(dirname "$0")/..}" && pwd)"

UE_BIN="${BUILD}/srsue/src/srsue_mbs"
RF_DIR="${BUILD}/lib/src/phy/rf"
for f in "${UE_BIN}" "${RF_DIR}/libsrsran_rf.so.0" "${RF_DIR}/libsrsran_rf_uhd.so.0"; do
  [[ -e "$f" ]] || { echo "ERROR: $f missing; build srsue_mbs and srsran_rf_uhd first." >&2; exit 1; }
done
UHD_TOOLS=(); for t in uhd_find_devices uhd_usrp_probe; do UHD_TOOLS+=("$(command -v "$t")"); done
IMG_DIR="$(uhd_config_info --images-dir | awk -F': *' '{print $NF}' | tr -d '"')"
[[ -f "${IMG_DIR}/usrp_b210_fpga.bin" ]] || { echo "ERROR: no B210 images in ${IMG_DIR}; run: sudo uhd_images_downloader -t b2xx" >&2; exit 1; }
first_file() { for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return; }; done; }
STDBUF="$(first_file /usr/libexec/coreutils/libstdbuf.so /usr/lib/coreutils/libstdbuf.so)"
UDEV_RULES="$(first_file /lib/udev/rules.d/60-uhd-host.rules /usr/lib/uhd/utils/uhd-usrp.rules /usr/local/lib/uhd/utils/uhd-usrp.rules)"

echo "==> Bundling into ${UE_DIR}"
rm -rf "${UE_DIR}/bin" "${UE_DIR}/lib" "${UE_DIR}/share"
mkdir -p "${UE_DIR}/bin" "${UE_DIR}/lib" "${UE_DIR}/share/uhd/images" "${UE_DIR}/udev"

install -m 755 "${UE_BIN}" "${UHD_TOOLS[@]}" "${UE_DIR}/bin/"
strip "${UE_DIR}/bin/srsue_mbs"
# srsue_mbs links libsrsran_rf.so.0 and dlopen()s the UHD plugin by the name libsrsran_rf_uhd.so
install -m 755 "$(readlink -f "${RF_DIR}/libsrsran_rf.so.0")"     "${UE_DIR}/lib/libsrsran_rf.so.0"
install -m 755 "$(readlink -f "${RF_DIR}/libsrsran_rf_uhd.so.0")" "${UE_DIR}/lib/libsrsran_rf_uhd.so.0"
ln -sf libsrsran_rf_uhd.so.0 "${UE_DIR}/lib/libsrsran_rf_uhd.so"
strip "${UE_DIR}/lib/libsrsran_rf.so.0" "${UE_DIR}/lib/libsrsran_rf_uhd.so.0"
[[ -n "${STDBUF}" ]] && install -m 644 "${STDBUF}" "${UE_DIR}/lib/libstdbuf.so"   # line-buffered UE output

# Shared-library closure of everything above (ldd resolves transitively), glibc and the loader included.
{
  for f in "${UE_DIR}"/bin/* "${UE_DIR}/lib/libsrsran_rf_uhd.so.0"; do
    LD_LIBRARY_PATH="${UE_DIR}/lib" ldd "$f"
  done
} | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3} $1 ~ /^\/.*ld-linux/ {print "ld-linux-x86-64.so.2", $1}' \
  | sort -u | while read -r name path; do
      [[ -e "${UE_DIR}/lib/${name}" ]] || install -m 755 "$(readlink -f "${path}")" "${UE_DIR}/lib/${name}"
    done
if LD_LIBRARY_PATH="${UE_DIR}/lib" ldd "${UE_DIR}/bin/srsue_mbs" "${UE_DIR}/lib/libsrsran_rf_uhd.so.0" | grep -q 'not found'; then
  echo "ERROR: unresolved libraries:" >&2; LD_LIBRARY_PATH="${UE_DIR}/lib" ldd "${UE_DIR}/bin/srsue_mbs" | grep 'not found' >&2; exit 1
fi

for f in usrp_b200_fw.hex usrp_b200_bl.img usrp_b200_fpga.bin usrp_b210_fpga.bin usrp_b200mini_fpga.bin usrp_b205mini_fpga.bin; do
  [[ -f "${IMG_DIR}/$f" ]] && install -m 644 "${IMG_DIR}/$f" "${UE_DIR}/share/uhd/images/"
done
[[ -n "${UDEV_RULES}" ]] && install -m 644 "${UDEV_RULES}" "${UE_DIR}/udev/60-uhd-usrp.rules"

. /etc/os-release
cat > "${UE_DIR}/share/BUILDINFO" <<EOF
built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
build host: ${PRETTY_NAME}, $(ldd --version | head -1 | awk '{print "glibc", $NF}')
source:     $(cat "${BUILD}/.mbs-source" 2>/dev/null || echo "${BUILD}")
march:      $(grep -o -m1 'march=[a-z0-9-]*' "${BUILD}/build.ninja" 2>/dev/null || echo unknown)
uhd:        $(pkg-config --modversion uhd)
EOF
# Where each bundled third-party file comes from (unmodified Ubuntu / Ettus PPA packages; sources via apt-get source)
{
  echo "Bundled third-party files: Debian package, version, licence file (on the build host: /usr/share/doc/<package>/copyright)"
  for f in "${UE_DIR}"/lib/* "${UE_DIR}/bin/uhd_find_devices" "${UE_DIR}/bin/uhd_usrp_probe"; do
    n="$(basename "$f")"; [[ "$n" == libsrsran_rf* || -L "$f" ]] && continue
    src="$(dpkg -S "$(ldconfig -p | awk -v n="$n" '$1 == n {print $NF; exit}')" 2>/dev/null \
           || dpkg -S "/usr/bin/$n" 2>/dev/null || dpkg -S "/usr/libexec/coreutils/$n" 2>/dev/null \
           || dpkg -S "/usr/lib/x86_64-linux-gnu/$n" 2>/dev/null || true)"
    pkg="${src%%:*}"
    printf '%-48s %s %s\n' "$n" "${pkg:-?}" "$([[ -n "$pkg" ]] && dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
  done
  echo "share/uhd/images                                 uhd-images (Ettus Research, uhd_images_downloader) for UHD $(pkg-config --modversion uhd)"
} > "${UE_DIR}/share/THIRD_PARTY.txt"

echo "==> Bundle: $(du -sh "${UE_DIR}/bin" | cut -f1) bin, $(du -sh "${UE_DIR}/lib" | cut -f1) lib ($(ls "${UE_DIR}/lib" | wc -l) files), $(du -sh "${UE_DIR}/share" | cut -f1) share"
