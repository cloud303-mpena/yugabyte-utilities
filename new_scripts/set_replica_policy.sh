#!/bin/bash

# Usage: ./modify_placement.sh <region> <zone1> <zone2> <zone3> <replication_factor> <master_addrs>
# Example: ./modify_placement.sh us-east us-east-2a us-east-2b us-east-2c 3 "10.0.0.159:7100,10.0.1.131:7100,10.0.2.245:7100"

set -e

REGION="$1"
ZONE1="$2"
ZONE2="$3"
ZONE3="$4"
RF="$5"
MASTER_ADDRS="$6"

if [ -z "$REGION" ] || [ -z "$ZONE1" ] || [ -z "$ZONE2" ] || [ -z "$ZONE3" ] || [ -z "$RF" ] || [ -z "$MASTER_ADDRS" ]; then
  echo "Usage: $0 <region> <zone1> <zone2> <zone3> <replication_factor> <master_addrs>"
  exit 1
fi

./bin/yb-admin \
  --master_addresses "$MASTER_ADDRS" \
  modify_placement_info \
  aws."$REGION"."$ZONE1",aws."$REGION"."$ZONE2",aws."$REGION"."$ZONE3" "$RF"