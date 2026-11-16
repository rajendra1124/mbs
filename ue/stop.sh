#!/usr/bin/env bash
# Stop the UE (SIGINT first so it closes the radio and the recording cleanly).
set -uo pipefail
cd "$(dirname "$0")"
pid="$(cat logs/ue.pid 2>/dev/null || true)"
if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
  echo "UE is not running."; rm -f logs/ue.pid; exit 0
fi
kill -INT "${pid}"
for _ in $(seq 10); do kill -0 "${pid}" 2>/dev/null || break; sleep 1; done
kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}"
for _ in $(seq 5); do [[ -f logs/ue.pid ]] || break; sleep 1; done
rm -f logs/ue.pid
echo "UE stopped."
