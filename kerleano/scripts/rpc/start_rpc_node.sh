#!/bin/bash
source ~/.aws-instance-env
BOOTNODE=$(readarray -t ARRAY < ~/bootnodes; IFS=,; echo "${ARRAY[*]}")
DATADIR=~/.ethereum/
KEYSTORE=~/.keystore
NODEKEY=$KEYSTORE/nodekey
PUBLIC_IP=${AWS_PUBLIC_IP:-$(curl https://checkip.amazonaws.com)}
exec /chain/bin/geth --networkid 1804 \
    --datadir $DATADIR \
    --bootnodes $BOOTNODE \
    --nodekey $NODEKEY \
    --syncmode full \
    --snapshot=false \
    --http --http.addr 127.0.0.1 --http.port 8545 \
    --http.api eth,net,web3,txpool \
    --http.corsdomain "*" --http.vhosts "*" \
    --ws --ws.addr 127.0.0.1 --ws.port 8546 \
    --ws.api eth,net,web3,txpool \
    --ws.origins "*" \
    --nat extip:$PUBLIC_IP
