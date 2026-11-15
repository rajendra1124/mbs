#!/usr/bin/env bash
# Start the 5G core with MBS. Run on the gNB PC (the gNB container connects to 127.0.0.1:38412).
set -euo pipefail
cd "$(dirname "$0")"
command -v docker >/dev/null || { echo "Docker is required: https://docs.docker.com/engine/install/"; exit 1; }

echo "==> Pulling pinned core images (first run only)..."
docker compose pull -q
echo "==> Starting core..."
docker compose up -d

echo "==> Waiting for the AMF NGAP port..."
for _ in $(seq 1 60); do
  docker logs amf_with_mbs 2>&1 | grep -q "ngap_server()" && break
  sleep 1
done
docker compose ps --format 'table {{.Name}}\t{{.Status}}'

[[ -f media/demo.ts ]] || ./make-demo-media.sh

cat <<EOF

Core is up.
  Subscriber web UI : http://127.0.0.1:9999  (admin / 1423)   or  ./add-subscriber.sh <IMSI> <K> <OPc>
  PLMN 999/70, TAC 1, slice SST 1, DNN internet, UE IP pool 10.45.0.0/16
Next: ../gnb/start.sh   then   ./activate-broadcast.sh
EOF
