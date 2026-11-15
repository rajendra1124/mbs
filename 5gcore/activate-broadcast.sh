#!/usr/bin/env bash
# Create an MBS broadcast session and start streaming into it (run after the core and the gNB are up).
#
#   ./activate-broadcast.sh                 video: media/demo.ts at 1500 kb/s, looped
#   MODE=text ./activate-broadcast.sh       text: "testMsg N Tx_ns=<ns>" once per second
#   BITRATE_KBPS=1500 MEDIA=demo.ts STREAM_START_DELAY=30 ./activate-broadcast.sh
#
# Steps: (1) AF/AS allocates a TMGI and creates a BROADCAST session at the MB-SMF, (2) wait until the gNB joins the
# multicast group announced over NGAP, (3) start exactly one sender on that group/TEID, (4) verify MTCH on G-RNTI.
set -euo pipefail
cd "$(dirname "$0")"
AF=test_mbs_af_as
MODE="${MODE:-video}"
GNB_LOG="${GNB_LOG:-../gnb/logs/gnb.log}"
MEDIA="${MEDIA:-demo.ts}"
BITRATE_KBPS="${BITRATE_KBPS:-1500}"      # must equal the TS mux rate of the media file
STREAM_START_DELAY="${STREAM_START_DELAY:-30}"
TEXT_INTERVAL="${TEXT_INTERVAL:-1}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -f "$GNB_LOG" ]] || die "gNB log $GNB_LOG not found. Start the gNB first (../gnb/start.sh)."
[[ "$MODE" == text || -f "media/$MEDIA" ]] || die "media/$MEDIA missing; run ./make-demo-media.sh"

offset=$(( $(stat -c %s "$GNB_LOG") + 1 ))
echo "==> Creating MBS broadcast session (TMGI + session at MB-SMF)..."
docker exec "$AF" sh -c "cd /test && python3 -m unittest -q MB_SMF.MBSSessionServiceAPI.MBSSessionServiceOperation.test_create_and_release_mbs_session" \
  || die "session creation failed (check: docker logs smf_mb-smf)"

echo "==> Waiting for the gNB to join the multicast group..."
tunnel=""
for _ in $(seq 1 30); do
  tunnel=$(tail -c +"$offset" "$GNB_LOG" | sed -n -E 's/.*Joined multicast group ([0-9.]+):2152 teid=(0x[0-9a-fA-F]+).*/\1 \2/p' | tail -1)
  [[ -n "$tunnel" ]] && break
  sleep 1
done
[[ -n "$tunnel" ]] || die "gNB did not join a multicast group within 30 s (is the gNB connected to the AMF?)"
read -r group teid <<<"$tunnel"
echo "==> Session live on group $group, TEID $teid"

echo "==> Waiting ${STREAM_START_DELAY}s so receivers can acquire the cell..."
sleep "$STREAM_START_DELAY"
docker exec "$AF" sh -c "pkill -f 'mbs_(video|text)_stream.py'" 2>/dev/null || true
sleep 1
if [[ "$MODE" == text ]]; then
  docker exec -d "$AF" sh -c "exec python3 /test/tools/mbs_text_stream.py --group $group --teid $teid --interval $TEXT_INTERVAL >/tmp/mbs_text_stream.log 2>&1"
else
  docker exec -d "$AF" sh -c "exec python3 /test/tools/mbs_video_stream.py --input /test/media/$MEDIA --group $group --teid $teid --bitrate-kbps $BITRATE_KBPS --pace rate --loop >/tmp/mbs_video_stream.log 2>&1"
fi

verify=$(( $(stat -c %s "$GNB_LOG") + 1 ))
for _ in $(seq 1 20); do
  # (no pipefail-sensitive "grep -q" here: tail would get SIGPIPE and the pipeline would report failure)
  hit=$(tail -c +"$verify" "$GNB_LOG" | grep -a -o -m1 'MTCH: rnti=0x[0-9a-f]*' || true)
  if [[ -n "$hit" ]]; then
    echo "OK: broadcasting ($MODE) on MTCH, G-RNTI ${hit##*=}"
    if [[ "${hit##*=}" != "0xfe01" ]]; then
      echo "NOTE: this is not the first session since the gNB started, so the G-RNTI is ${hit##*=}. Receivers configured"
      echo "      for 0xfe01 will not decode it: restart the gNB (../gnb/stop.sh && ../gnb/start.sh) before activating."
    fi
    exit 0
  fi
  sleep 1
done
die "sender started but no MTCH grants seen in the gNB log within 20 s"
