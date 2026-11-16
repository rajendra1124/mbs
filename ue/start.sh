#!/usr/bin/env bash
# Start the receive-only MBS UE (srsRAN_4G based) with a USRP B200/B210 and play the broadcast.
#   ./start.sh                  foreground: receiver + video player; Ctrl-C stops both
#   DETACH=1 ./start.sh         background, no player; log in ue/logs/ue.log, stop with ./stop.sh
#   PLAYER=ffplay ./start.sh    player: auto (vlc > ffplay > mpv) | vlc | ffplay | mpv | none
#   RF_GAIN=60 RECORD=0 ./start.sh   any setting from config/ue.env
#   ./start.sh --help           receiver options; extra arguments are passed to srsue_mbs
#
# Self-contained: bin/ and lib/ hold the prebuilt receiver with every library it needs (UHD, FFTW, Boost,
# glibc, ...) and share/ the B210 firmware. Nothing to install except, once, the USB permission rules
# (sudo ./setup-usb.sh) and a video player (VLC/ffplay/mpv) to watch the stream.
set -euo pipefail
cd "$(dirname "$0")"
UE_DIR="$PWD"
SELF="${UE_DIR}/$(basename "$0")"
LIB="${UE_DIR}/lib"
BIN="${UE_DIR}/bin"
PID_FILE="${UE_DIR}/logs/ue.pid"
. config/ue.env

# Run a bundled program with the bundled loader and libraries only (independent of the host's libraries).
# libstdbuf makes its output line-buffered so the log is written as it happens.
bundled_cmd() {
  local prog="$1"; shift
  CMD=(env _STDBUF_O=L _STDBUF_E=L UHD_IMAGES_DIR="${UE_DIR}/share/uhd/images"
       "${LIB}/ld-linux-x86-64.so.2" --library-path "${LIB}")
  [[ -f "${LIB}/libstdbuf.so" ]] && CMD+=(--preload "${LIB}/libstdbuf.so")
  CMD+=(--argv0 "${prog}" "${BIN}/${prog}" "$@")
}

[[ -x "${LIB}/ld-linux-x86-64.so.2" && -f "${BIN}/srsue_mbs" ]] \
  || { echo "ERROR: ue/bin or ue/lib missing (incomplete clone?). Rebuild with ./build-from-source.sh"; exit 1; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then bundled_cmd srsue_mbs --help; exec "${CMD[@]}"; fi

[[ "$(uname -m)" == x86_64 ]] || { echo "ERROR: the bundled UE is built for x86-64."; exit 1; }
grep -qw avx2 /proc/cpuinfo && grep -qw fma /proc/cpuinfo \
  || { echo "ERROR: this CPU lacks AVX2/FMA (needs Intel Haswell / AMD Zen or newer)."; exit 1; }
if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "ERROR: the UE is already running (pid $(cat "${PID_FILE}")). Stop it with ./stop.sh"; exit 1
fi
[[ -z "${SERVICE_ID}" || "${SERVICE_ID}" =~ ^[[:xdigit:]]{6}$ ]] || { echo "ERROR: SERVICE_ID must be 6 hex digits"; exit 1; }

if [[ "${DETACH:-0}" == 1 ]]; then
  mkdir -p logs
  DETACH=0 PLAYER=none setsid nohup "${SELF}" "$@" >logs/ue.console 2>&1 </dev/null &
  for _ in $(seq 50); do [[ -f "${PID_FILE}" ]] && break; sleep 0.1; done
  if [[ -f "${PID_FILE}" ]]; then
    echo "==> UE started in the background (pid $(cat "${PID_FILE}")). Follow: tail -f ue/logs/ue.log   Stop: ./ue/stop.sh"
  else
    echo "ERROR: the UE did not start:"; cat logs/ue.console; exit 1
  fi
  exit 0
fi

echo "==> mbs-ue: $(awk -F': *' '/^source:/ {print $2}' share/BUILDINFO 2>/dev/null | cut -c1-60)"

# ---- USRP: present, accessible, on USB 3 (sysfs only, so the check is instant) ----
if [[ "${SKIP_USRP_CHECK:-0}" != 1 && "${RF_DEVICE}" == uhd ]]; then
  usrp=""
  for d in /sys/bus/usb/devices/*/idVendor; do
    [[ "$(cat "$d" 2>/dev/null)" == 2500 ]] && { usrp="$(dirname "$d")"; break; }
  done
  if [[ -z "${usrp}" ]]; then
    echo "ERROR: no USRP B2xx on USB. Plug the B210 into a USB 3 port.  (SKIP_USRP_CHECK=1 to bypass)"; exit 1
  fi
  node="$(printf '/dev/bus/usb/%03d/%03d' "$(cat "${usrp}/busnum")" "$(cat "${usrp}/devnum")")"
  if [[ ! -w "${node}" ]]; then
    echo "ERROR: no permission to open the USRP (${node}). Run once:  sudo ./ue/setup-usb.sh   then replug the B210."
    exit 1
  fi
  speed="$(cat "${usrp}/speed" 2>/dev/null || echo 0)"
  echo "==> USRP found ($(cat "${usrp}/product" 2>/dev/null || echo B2xx), serial $(cat "${usrp}/serial" 2>/dev/null || echo ?), USB ${speed} Mb/s)"
  (( ${speed%%.*} >= 5000 )) || echo "WARNING: USRP is not on USB 3 (5000 Mb/s); expect overflows and sync losses."
fi

# ---- receiver arguments ----
args=(
  --rf.device "${RF_DEVICE}" --rf.args "${RF_ARGS}" --rf.gain "${RF_GAIN}"
  --rate "${SRATE}" --frequency "${FREQUENCY}" --ssb-frequency "${SSB_FREQUENCY}"
  --scs "${SCS}" --prbs "${PRBS}" --pci "${PCI}" --coreset0 "${CORESET0}" --ssb-period "${SSB_PERIOD}"
  --plmn "${PLMN}" --lcid "${LCID}" --mbs-wire-format "${MBS_WIRE_FORMAT}" --rnti "${GROUP_RNTI}"
  --udp-port "${UDP_PORT}" --pdcch-corr-thr "${PDCCH_CORR_THR}"
)
STAMP="$(date +%Y%m%d_%H%M%S)"
if [[ "${RECORD}" != 0 ]]; then
  mkdir -p "${SAVE_DIR}"
  args+=(--output-file "${SAVE_DIR}/received_${STAMP}.ts")
fi
[[ -n "${SERVICE_ID}" ]] && args+=(--service-id "${SERVICE_ID}")

# Hybrid Intel CPUs: receiver on performance cores, player on efficiency cores, so video decoding does not
# delay sample reads (UHD overflows cause resyncs). Override with CPUS=... / VLC_CPUS=...
CPUS="${CPUS-$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)}"
PLAYER_CPUS="${VLC_CPUS-$(cat /sys/devices/cpu_atom/cpus 2>/dev/null || true)}"

# ---- video player ----
if [[ "${PLAYER}" == auto ]]; then
  PLAYER=none
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    for p in vlc ffplay mpv; do
      [[ "$p" == vlc && "${EUID}" -eq 0 ]] && continue   # VLC refuses to run as root
      command -v "$p" >/dev/null && { PLAYER="$p"; break; }
    done
    [[ "${PLAYER}" == none ]] && echo "NOTE: no video player found (sudo apt install vlc); receiving without playback."
  fi
fi
url="udp://@127.0.0.1:${UDP_PORT}"
case "${PLAYER}" in
  vlc)    player=(vlc --network-caching=1000 "${url}") ;;
  ffplay) player=(ffplay -hide_banner -loglevel error -window_title "MBS broadcast" "udp://127.0.0.1:${UDP_PORT}") ;;
  mpv)    player=(mpv --really-quiet --title="MBS broadcast" "udp://127.0.0.1:${UDP_PORT}") ;;
  none)   player=() ;;
  *) echo "ERROR: PLAYER must be auto, vlc, ffplay, mpv or none"; exit 1 ;;
esac

PLAYER_PID=""
UE_PID=""
cleanup() {
  [[ -n "${UE_PID}" ]] && kill -KILL "${UE_PID}" 2>/dev/null
  rm -f "${PID_FILE}"
  if [[ -n "${PLAYER_PID}" ]]; then
    kill "${PLAYER_PID}" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "${PLAYER_PID}" 2>/dev/null || break; sleep 1; done
    kill -9 "${PLAYER_PID}" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT

if [[ ${#player[@]} -gt 0 ]]; then
  pin=(); [[ -n "${PLAYER_CPUS}" ]] && pin=(taskset -c "${PLAYER_CPUS}")
  "${pin[@]}" "${player[@]}" >/dev/null 2>&1 &
  PLAYER_PID=$!
  echo "==> Player: ${PLAYER} on ${url}"
else
  echo "==> No player; the stream is sent to ${url} (open it with VLC, ffplay or mpv)"
fi

# ---- logs: keep the previous run's log ----
mkdir -p logs
[[ -f logs/ue.log ]] && mv -f logs/ue.log "logs/ue.$(date -r logs/ue.log +%Y%m%d_%H%M%S).log"
echo "==> Log: ue/logs/ue.log$([[ "${RECORD}" != 0 ]] && echo ", recording: ${SAVE_DIR}/received_${STAMP}.ts")"

# Prefix each receiver line with the local time (ms). Ignores Ctrl-C so the final "Stopped:" line is logged.
add_timestamps() {
  trap '' INT
  local line now
  while IFS= read -r line; do
    now=${EPOCHREALTIME}
    printf '%(%Y-%m-%d %H:%M:%S)T.%s %s\n' "${now%.*}" "${now:(-6):3}" "${line}"
  done
}

bundled_cmd srsue_mbs "${args[@]}" "$@"
[[ -n "${CPUS}" ]] && CMD=(taskset -c "${CPUS}" "${CMD[@]}")
set +e
"${CMD[@]}" > >(add_timestamps | tee -i logs/ue.log) 2>&1 &
UE_PID=$!
echo "${UE_PID}" > "${PID_FILE}"

# Ctrl-C / stop.sh: first SIGINT (clean stop), then SIGTERM, then SIGKILL
stops=0
on_stop() {
  stops=$((stops + 1))
  case ${stops} in 1) sig=INT ;; 2) sig=TERM ;; *) sig=KILL ;; esac
  kill -"${sig}" "${UE_PID}" 2>/dev/null
}
trap on_stop INT TERM
while kill -0 "${UE_PID}" 2>/dev/null; do wait "${UE_PID}"; done
wait "${UE_PID}"; status=$?
UE_PID=""
sleep 0.3   # let the logger write the last lines
exit "${status}"
