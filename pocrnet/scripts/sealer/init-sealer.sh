#!/bin/bash
set -euo pipefail

GENESIS_FILE="pocrnet.json"
COMMON_GENESIS="common/$GENESIS_FILE"
GENESIS_PATH="$GENESIS_FILE"

# Prefer root genesis if present, otherwise use the one in common/.
if [ ! -f "$GENESIS_FILE" ] && [ -f "$COMMON_GENESIS" ]; then
	GENESIS_PATH="$COMMON_GENESIS"
fi

if [ ! -f "$GENESIS_PATH" ]; then
	echo "Error: missing $GENESIS_FILE (expected in current directory or $COMMON_GENESIS)" >&2
	exit 1
fi

rm -rf .ethereum
geth init --datadir .ethereum "$GENESIS_PATH"
