#!/bin/bash
source ~/.aws-instance-env
BOOTNODE=$(readarray -t ARRAY < ~/bootnodes; IFS=,; echo "${ARRAY[*]}")
DATADIR=~/.ethereum/
KEYSTORE=~/.keystore
NODEKEY=$KEYSTORE/nodekey
address=$(cat ~/.etherbase)
PUBLIC_IP=${AWS_PUBLIC_IP:-$(curl https://checkip.amazonaws.com)}
EXTRADATA=${AWS_INSTANCE_NAME:-PUBLIC_IP}
exec /chain/bin/geth --networkid 2606 \
    --datadir $DATADIR \
    --bootnodes $BOOTNODE \
    --nodekey $NODEKEY \
    --syncmode full \
    --snapshot=false \
    --mine --miner.gasprice 1000000000 \
    --miner.etherbase $address --unlock $address \
    --miner.extradata="$EXTRADATA" \
    --password ~/.passphrase --keystore $KEYSTORE \
    --nat extip:$PUBLIC_IP

  #  --vmodule=eth/*=5,p2p/server=5,clique/*=5 \
