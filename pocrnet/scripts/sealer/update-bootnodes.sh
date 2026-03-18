#!/bin/bash
# Sync local enode into the shared bootnodes file on S3
# Intended to run as a cron job every 5 minutes

set -euo pipefail

S3_BOOTNODES="s3://pocrnet-node-setup/chain/bootnodes"
LOCAL_BOOTNODES="$HOME/bootnodes"
IPC_PATH="$HOME/.ethereum/geth.ipc"
NODEKEY="$HOME/.keystore/nodekey"
PORT=30303

source "$HOME/.aws-instance-env"
PUBLIC_IP=${AWS_PUBLIC_IP:-$(curl -s https://checkip.amazonaws.com)}

# 1. Download bootnodes from S3
aws s3 cp "$S3_BOOTNODES" "$LOCAL_BOOTNODES" --quiet

# 2. Extract local enode from the nodekey
if [ ! -f "$NODEKEY" ]; then
    echo "Error: nodekey not found at $NODEKEY" >&2
    exit 1
fi

# Derive the public key from the nodekey using geth's bootnode tool if available,
# otherwise extract it via the running geth IPC
if [ -S "$IPC_PATH" ]; then
    LOCAL_ENODE=$($HOME/bin/geth attach --exec "admin.nodeInfo.enode" "$IPC_PATH" 2>/dev/null | tr -d '"')
else
    echo "Error: geth IPC socket not found at $IPC_PATH — is geth running?" >&2
    exit 1
fi

# Replace the IP in the enode with the public IP (geth may report 0.0.0.0 or private IP)
LOCAL_PUBKEY=$(echo "$LOCAL_ENODE" | sed -n 's|enode://\([^@]*\)@.*|\1|p')
if [ -z "$LOCAL_PUBKEY" ]; then
    echo "Error: could not extract pubkey from enode: $LOCAL_ENODE" >&2
    exit 1
fi
LOCAL_ENODE="enode://${LOCAL_PUBKEY}@${PUBLIC_IP}:${PORT}"

# 3. Check if the enode is already in the bootnodes file
if grep -qF "$LOCAL_PUBKEY" "$LOCAL_BOOTNODES"; then
    # Already registered — update the IP in case it changed
    if grep -qF "$LOCAL_ENODE" "$LOCAL_BOOTNODES"; then
        exit 0
    fi
    # Same pubkey but different IP — update the line
    sed -i "s|enode://${LOCAL_PUBKEY}@[^[:space:]]*|${LOCAL_ENODE}|" "$LOCAL_BOOTNODES"
else
    # 4. Add the enode
    echo "$LOCAL_ENODE" >> "$LOCAL_BOOTNODES"
fi

# Upload updated bootnodes to S3
aws s3 cp "$LOCAL_BOOTNODES" "$S3_BOOTNODES" --quiet

echo "$(date): bootnodes updated with $LOCAL_ENODE"
