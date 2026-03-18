#!/bin/bash
# monitor-sync.sh - Monitor geth synchronisation progress
# Run directly on the VM: bash ~/common/monitor-sync.sh [-w <interval>]

DATADIR=${DATADIR:-~/.ethereum}
IPC="$DATADIR/geth.ipc"
INTERVAL=5
WATCH=false

usage() {
    echo "Usage: $0 [-w <seconds>] [-d <datadir>]"
    echo "  -w <seconds>  Watch mode: refresh every N seconds (default: $INTERVAL)"
    echo "  -d <datadir>  Geth data directory (default: $DATADIR)"
    exit 0
}

while getopts "w:d:h" opt; do
    case $opt in
        w) WATCH=true; INTERVAL="$OPTARG" ;;
        d) DATADIR="$OPTARG"; IPC="$DATADIR/geth.ipc" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ ! -S "$IPC" ]; then
    echo "Error: IPC socket not found at $IPC"
    echo "Is geth running? Check with: systemctl status geth-kerleano"
    exit 1
fi

geth_exec() {
    /chain/bin/geth attach --exec "$1" "$IPC" 2>/dev/null
}

print_status() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    # Query geth over IPC
    local syncing peers current_block

    syncing=$(geth_exec 'var s=eth.syncing; s ? JSON.stringify({cur:s.currentBlock,high:s.highestBlock,known:s.knownStates||0,pulled:s.pulledStates||0}) : "false"')
    peers=$(geth_exec 'net.peerCount')
    current_block=$(geth_exec 'eth.blockNumber')

    echo "=== Geth Sync Monitor [$now] ==="
    echo "Peers connected : $peers"
    echo "Current block   : $current_block"

    if [ "$syncing" = "false" ] || [ -z "$syncing" ]; then
        echo "Sync status     : UP TO DATE (not syncing)"
    else
        # Parse JSON values (geth returns plain JS object repr)
        local cur high pct
        cur=$(echo "$syncing" | grep -o '"cur":[0-9]*' | grep -o '[0-9]*$')
        high=$(echo "$syncing" | grep -o '"high":[0-9]*' | grep -o '[0-9]*$')

        if [ -n "$cur" ] && [ -n "$high" ] && [ "$high" -gt 0 ]; then
            # Use awk for float division
            pct=$(awk "BEGIN { printf \"%.2f\", ($cur / $high) * 100 }")
            local remaining=$(( high - cur ))
            echo "Sync status     : SYNCING"
            echo "Current block   : $cur"
            echo "Highest block   : $high"
            echo "Remaining       : $remaining blocks"
            echo "Progress        : $pct %"

            # Progress bar (40 chars wide)
            local filled
            filled=$(awk "BEGIN { printf \"%d\", ($cur / $high) * 40 }")
            local bar=""
            for ((i=0; i<filled; i++));    do bar="${bar}#"; done
            for ((i=filled; i<40; i++)); do bar="${bar}-"; done
            echo "                  [${bar}]"
        else
            echo "Sync status     : SYNCING (waiting for peer data...)"
            echo "Raw             : $syncing"
        fi
    fi
    echo ""
}

if $WATCH; then
    echo "Watch mode: refreshing every ${INTERVAL}s — press Ctrl+C to stop"
    echo ""
    while true; do
        clear
        print_status
        sleep "$INTERVAL"
    done
else
    print_status
fi
