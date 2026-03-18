#!/bin/bash
# List bootnodes that are not currently connected as peers
# Usage: ./check-stale-bootnodes.sh

set -euo pipefail

LOCAL_BOOTNODES="$HOME/bootnodes"
IPC_PATH="$HOME/.ethereum/geth.ipc"

if [ ! -S "$IPC_PATH" ]; then
    echo "Error: geth IPC socket not found at $IPC_PATH — is geth running?" >&2
    exit 1
fi

# Get connected peer pubkeys
PEER_PUBKEYS=$($HOME/bin/geth attach --exec '
    var peers = admin.peers;
    var keys = [];
    for (var i = 0; i < peers.length; i++) {
        var m = peers[i].enode.match(/enode:\/\/([^@]*)/);
        if (m) keys.push(m[1]);
    }
    keys.join("\n");
' "$IPC_PATH" 2>/dev/null | tr -d '"')

# Get local pubkey to skip it
LOCAL_PUBKEY=$($HOME/bin/geth attach --exec "admin.nodeInfo.enode" "$IPC_PATH" 2>/dev/null \
    | tr -d '"' | sed -n 's|enode://\([^@]*\)@.*|\1|p')

STALE=0
TOTAL=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    PUBKEY=$(echo "$line" | sed -n 's|enode://\([^@]*\)@.*|\1|p')
    [ -z "$PUBKEY" ] && continue
    [ "$PUBKEY" = "$LOCAL_PUBKEY" ] && continue

    TOTAL=$((TOTAL + 1))

    if ! echo "$PEER_PUBKEYS" | grep -qF "$PUBKEY"; then
        STALE=$((STALE + 1))
        echo "$line"
    fi
done < "$LOCAL_BOOTNODES"

echo ""
echo "--- $STALE/$TOTAL bootnodes not connected as peers ---"
