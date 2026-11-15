#!/usr/bin/env bash
# Generate a licence-free demo video (test pattern + tone) as CBR MPEG-TS for the broadcast.
#   ./make-demo-media.sh [mux_rate_kbps=1500] [seconds=120]
# Output: media/demo.ts, padded to a multiple of 1316 B (7 x 188 B TS packets per GTP-U datagram).
# Uses ffmpeg inside the AF/AS container, so nothing is installed on the host.
set -euo pipefail
cd "$(dirname "$0")"
RATE=${1:-1500}
SECS=${2:-120}
VRATE=$(( RATE * 77 / 100 ))   # video share of the mux rate; the rest is audio, PSI and null-packet headroom
mkdir -p media
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/media:/out" --entrypoint sh \
  ghcr.io/5g-mag/test_mbs_af_as@sha256:004ba6d44ff306a1517a24a3fb2030c19b2e5628f632becc54bfb97a029dff0b -c "
set -e
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1000x562:rate=24 -f lavfi -i sine=frequency=440:sample_rate=44100 -t $SECS \
  -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
  -b:v ${VRATE}k -minrate ${VRATE}k -maxrate ${VRATE}k -bufsize $((VRATE/2))k \
  -x264-params nal-hrd=cbr:force-cfr=1:keyint=24:min-keyint=24:scenecut=0:bframes=0:open-gop=0:repeat-headers=1:aud=1 \
  -c:a aac -b:a 64k -ac 2 -f mpegts -muxrate ${RATE}k -pcr_period 20 -pat_period 0.1 -sdt_period 0.5 /out/demo.ts
size=\$(stat -c %s /out/demo.ts); pad=\$(( (1316 - size % 1316) % 1316 / 188 ))
i=0; while [ \$i -lt \$pad ]; do printf '\107\037\377\020' >> /out/demo.ts; head -c 184 /dev/zero | tr '\0' '\377' >> /out/demo.ts; i=\$((i+1)); done
echo \"media/demo.ts: \$(stat -c %s /out/demo.ts) bytes, ${RATE} kb/s CBR, $SECS s\"
"
