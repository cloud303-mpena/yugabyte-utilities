#!/bin/bash

# Usage: ./start_master.sh <bind_ip> <zone> <region> <fs_data_dir> <master_addrs>
# Example: ./start_master.sh 10.0.0.159 us-east-2a us-east /home/ubuntu "10.0.0.159:7100,10.0.1.131:7100,10.0.2.245:7100"

set -e

BIND_IP="$1"
ZONE="$2"
REGION="$3"
FS_DIR="$4"
MASTER_ADDRS="$5"

if [ -z "$BIND_IP" ] || [ -z "$ZONE" ] || [ -z "$REGION" ] || [ -z "$FS_DIR" ] || [ -z "$MASTER_ADDRS" ]; then
  echo "Usage: $0 <bind_ip> <zone> <region> <fs_data_dir> <master_addrs>"
  exit 1
fi

./bin/yb-master \
  --master_addresses "$MASTER_ADDRS" \
  --rpc_bind_addresses "$BIND_IP:7100" \
  --fs_data_dirs "$FS_DIR" \
  --placement_cloud aws \
  --placement_region "$REGION" \
  --placement_zone "$ZONE" \
  >& "$FS_DIR/yb-master.out" &