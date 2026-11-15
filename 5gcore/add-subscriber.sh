#!/usr/bin/env bash
# Add (or update) a UE subscriber in the core database.
#   ./add-subscriber.sh <IMSI> <K> <OPc>
# Example (PLMN 999/70):
#   ./add-subscriber.sh 999700000000001 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
# The SIM / UE config on the receiver must use the same IMSI, K and OPc.
set -euo pipefail
[[ $# -eq 3 ]] || { sed -n 2,6p "$0"; exit 1; }
IMSI=$1 K=$2 OPC=$3
[[ "$IMSI" =~ ^[0-9]{15}$ ]] || { echo "IMSI must be 15 digits"; exit 1; }
[[ "$K" =~ ^[0-9A-Fa-f]{32}$ && "$OPC" =~ ^[0-9A-Fa-f]{32}$ ]] || { echo "K and OPc must be 32 hex digits"; exit 1; }

docker exec db mongosh open5gs --quiet --eval "
const imsi = '$IMSI';
const ambr = { uplink: { value: 1, unit: 3 }, downlink: { value: 1, unit: 3 } };
db.subscribers.updateOne({ imsi }, { \$set: {
  imsi, msisdn: [],
  security: { k: '$K', op: null, opc: '$OPC', amf: '8000', sqn: NumberLong(0) },
  ambr,
  slice: [{ sst: 1, default_indicator: true, ambr,
            session: [{ name: 'internet', type: 3, pcc_rule: [], ambr,
                        qos: { index: 9, arp: { priority_level: 8, pre_emption_capability: 1, pre_emption_vulnerability: 1 } } }] }],
  access_restriction_data: 32, subscriber_status: 0, network_access_mode: 0
} }, { upsert: true });
print('subscriber ' + imsi + ' stored');
"
