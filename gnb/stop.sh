#!/usr/bin/env bash
# Stop the gNB container (sends SIGINT first so it closes the radio and pcaps cleanly).
set -uo pipefail
docker kill -s INT mbs-gnb >/dev/null 2>&1 && sleep 5
docker rm -f mbs-gnb >/dev/null 2>&1
echo "gNB stopped."
