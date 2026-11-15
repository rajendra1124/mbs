#!/usr/bin/env bash
# Stop the core (subscriber database is kept in the open5gs_db_data volume).
#   ./stop.sh            stop containers
set -euo pipefail
cd "$(dirname "$0")"
docker exec test_mbs_af_as sh -c "pkill -f 'mbs_(video|text)_stream.py'" 2>/dev/null || true
docker compose down
