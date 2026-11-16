#!/usr/bin/env bash
# Rebuild the bundled UE (ue/bin, ue/lib, ue/share) from source. Not needed to run the UE: the bundle is in the repo.
#
#   ./build-from-source.sh                     upstream srsRAN_4G release_25_10 + patches/*.patch (like gnb/Dockerfile)
#   SRC_TREE=~/srsRAN_4G ./build-from-source.sh  bundle an already-patched source tree you are developing in
#   INSTALL_DEPS=1 ./build-from-source.sh      also install the Ubuntu build packages (sudo)
#
# Build on Ubuntu 24.04 x86-64 (the bundle carries the build host's glibc and libraries) with UHD 4.11 from the
# Ettus PPA. The binary targets x86-64-v3 (AVX2/FMA), like the gNB image, not -march=native.
set -euo pipefail
cd "$(dirname "$0")"
UE_DIR="$PWD"
SRSRAN_REPO="${SRSRAN_REPO:-https://github.com/srsRAN/srsRAN_4G.git}"
SRSRAN_TAG="${SRSRAN_TAG:-release_25_10}"
SRSRAN_COMMIT=6bcbd9e5bf8686aa7085202cd847c5ddd64a9c16
MARCH="${MARCH:-x86-64-v3}"
WORK="${WORK:-${UE_DIR}/.build}"
JOBS="${JOBS:-$(nproc)}"

if [[ "${INSTALL_DEPS:-0}" == 1 ]]; then
  sudo add-apt-repository -y ppa:ettusresearch/uhd
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build pkg-config git ca-certificates \
    libfftw3-dev libmbedtls-dev libpcsclite-dev libboost-program-options-dev libboost-system-dev \
    libconfig++-dev libsctp-dev libuhd-dev uhd-host
  sudo uhd_images_downloader -t b2xx
fi
for t in cmake ninja git pkg-config; do command -v "$t" >/dev/null || { echo "Missing $t; rerun with INSTALL_DEPS=1"; exit 1; }; done
pkg-config --exists uhd || { echo "UHD development files missing; rerun with INSTALL_DEPS=1"; exit 1; }

mkdir -p "${WORK}"
if [[ -n "${SRC_TREE:-}" ]]; then
  SRC="$(cd "${SRC_TREE}" && pwd)"
  [[ -f "${SRC}/srsue/src/mbs_receiver_main.cc" ]] || { echo "${SRC} is not an MBS srsRAN_4G tree"; exit 1; }
  SOURCE_DESC="local tree ${SRC} ($(git -C "${SRC}" describe --tags --always --dirty 2>/dev/null || echo 'no git'))"
else
  SRC="${WORK}/srsRAN_4G"
  rm -rf "${SRC}"
  echo "==> Cloning srsRAN_4G ${SRSRAN_TAG}"
  git clone -q --depth 1 --branch "${SRSRAN_TAG}" "${SRSRAN_REPO}" "${SRC}"
  [[ "$(git -C "${SRC}" rev-parse HEAD)" == "${SRSRAN_COMMIT}" ]] || { echo "ERROR: ${SRSRAN_TAG} is not ${SRSRAN_COMMIT}"; exit 1; }
  for p in patches/*.patch; do echo "==> Applying $p"; git -C "${SRC}" apply --whitespace=nowarn "${UE_DIR}/$p"; done
  SOURCE_DESC="srsRAN_4G ${SRSRAN_TAG} (${SRSRAN_COMMIT:0:10}) + $(cd patches && sha256sum *.patch | awk '{printf "%s sha256:%.12s ", $2, $1}')"
fi

BUILD="${WORK}/build"
rm -rf "${BUILD}"
# RUNPATH $ORIGIN/../lib instead of the build folder, so the bundled files carry no paths of this PC.
cmake -S "${SRC}" -B "${BUILD}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SRSUE=ON -DENABLE_SRSENB=OFF -DENABLE_SRSEPC=OFF -DENABLE_GUI=OFF -DENABLE_ZEROMQ=OFF \
  -DENABLE_HARDSIM=OFF -DENABLE_UHD=ON -DENABLE_WERROR=OFF \
  -DGCC_ARCH="${MARCH}" -DENABLE_AVX512=OFF \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=${SRC}/=" -DCMAKE_CXX_FLAGS="-ffile-prefix-map=${SRC}/=" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' >"${WORK}/cmake.log" \
  || { tail -20 "${WORK}/cmake.log"; exit 1; }
grep -q 'march=native' "${BUILD}/build.ninja" && { echo "ERROR: build uses -march=native"; exit 1; }
echo "${SOURCE_DESC}" > "${BUILD}/.mbs-source"

echo "==> Building srsue_mbs (${MARCH}, ${JOBS} jobs)"
cmake --build "${BUILD}" -j "${JOBS}" --target srsue_mbs srsran_rf_uhd \
  ocudu_mbs_rx_test ocudu_mbs_phy_test ocudu_mbs_gateway_test mbs_radio_test mbs_control_test
echo "==> Running the MBS software tests"
LD_LIBRARY_PATH="${BUILD}/lib/src/phy/rf" ctest --test-dir "${BUILD}" --output-on-failure \
  -R '^(ocudu_mbs_.*_test|mbs_radio_test|mbs_control_test)$'

"${UE_DIR}/tools/bundle.sh" "${BUILD}" "${UE_DIR}"
echo "==> Done. Start the UE with: ${UE_DIR}/start.sh"
