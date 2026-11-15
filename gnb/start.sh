#!/usr/bin/env bash
# Start the MBS gNB container with the USRP B210.
#   ./start.sh              foreground (Ctrl-C stops the gNB)
#   DETACH=1 ./start.sh     background; logs in gnb/logs/gnb.log, stop with ./stop.sh
#   CPUS=4-7,12-15 ./start.sh   pin the gNB to dedicated cores (recommended on multi-core hosts)
#   RT_PRIO=50 ./start.sh       run with SCHED_FIFO priority 50 (default; RT_PRIO= disables)
#
# Needs: Docker, the B210 on a USB 3 port, the core running (../5gcore/start.sh).
# The image is pulled from GHCR; if that fails it is built locally from gnb/Dockerfile (~15-30 min, once).
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${IMAGE:-ghcr.io/rajendra1124/mbs-gnb:latest}"
NAME=mbs-gnb

command -v docker >/dev/null || { echo "Docker is required: https://docs.docker.com/engine/install/"; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1 || true

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Pulling $IMAGE ..."
  if ! docker pull "$IMAGE"; then
    echo "==> Pull failed; building the image locally (one time)..."
    docker build -t "$IMAGE" .
  fi
fi

docker network inspect 5g-mag >/dev/null 2>&1 || { echo "ERROR: core network '5g-mag' not found. Run ../5gcore/start.sh first."; exit 1; }

# keep the previous run's log
[[ -f logs/gnb.log ]] && mv -f logs/gnb.log "logs/gnb.$(date -u +%Y%m%d-%H%M%S).log" 2>/dev/null || true

args=(--name "$NAME" --network host --privileged
      -v /dev/bus/usb:/dev/bus/usb -v "$PWD/config:/config:ro" -v "$PWD/logs:/logs"
      --ulimit rtprio=99 --ulimit memlock=-1 --cap-add SYS_NICE -e RT_PRIO="${RT_PRIO-50}")
[[ -n "${CPUS:-}" ]] && args+=(--cpuset-cpus "$CPUS")

if [[ "${DETACH:-0}" == "1" ]]; then
  docker run -d "${args[@]}" "$IMAGE" >/dev/null
  echo "==> gNB started in the background. Follow: docker logs -f $NAME   (detailed log: gnb/logs/gnb.log)"
else
  exec docker run --rm -it "${args[@]}" "$IMAGE"
fi
