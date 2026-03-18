# PoCRnet Network Setup

Follow the shared steps in [README.md](README.md) first.

## Script source and layout

Use scripts from [pocrnet/scripts](pocrnet/scripts):

```text
common/
  check-stale-bootnodes.sh
  download-genesis.sh
  download-geth.sh
  geth-pocrnet-logrotate
  pocrnet.json
  update-aws-instance-vars.sh
sealer/
  geth-pocrnet.service
  init-sealer.sh
  start_sealer_node.sh
  update-bootnodes.sh
rpc/
  geth-pocrnet-rpc.service
  nginx-rpc-locations.conf
  nginx-rpc.conf
  setup-nginx-ssl.sh
  start_rpc_node.sh
```

## 1) Download setup assets on the node

As user `geth`:

```sh
aws s3 cp s3://pocrnet-node-setup/chain/ . --recursive
chmod +x common/*.sh sealer/*.sh rpc/*.sh
mkdir -p .keystore ~/.ethereum/geth
```

## 2) Bootstrap chain data (archive first, genesis fallback)

### Preferred: restore archived historical chain data

This is the recommended path because it is much faster than syncing from genesis.

```sh
ARCHIVE=$(ls -1 chaindata-*.tar.gz 2>/dev/null | head -n 1)
if [ -n "$ARCHIVE" ]; then
  tar -xzf "$ARCHIVE" -C ~/.ethereum/geth/
  rm "$ARCHIVE"
else
  echo "No chaindata archive found in /chain"
fi
```

### Fallback: initialize from genesis (if no archive)

```sh
./sealer/init-sealer.sh
```

`init-sealer.sh` uses `pocrnet.json` from `/chain` when present, otherwise it
initializes directly from `common/pocrnet.json`.

## 3) Install geth binary

```sh
mkdir -p bin
./common/download-geth.sh v1.10.26-pocr-2.0.0
ln -sfn geth-v1.10.26-pocr-2.0.0 bin/geth
```

You can choose another release tag if needed.

## Sealer node (PoCRnet)

If you restored archived chain data above, do not run genesis initialization again.

### Account and mining identity

Create a new account (or import existing wallet):

```sh
geth account new --keystore .keystore/
# save password in:
vi .passphrase
# save address in:
echo "0x..." > .etherbase
```

### Bootnode auto-registration

Install cron job:

```sh
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/sealer/update-bootnodes.sh >> $HOME/update-bootnodes.log 2>&1") | crontab -
```

`update-bootnodes.sh` syncs with `s3://pocrnet-node-setup/chain/bootnodes`.

### Install and run systemd service

As user `ubuntu`:

```sh
sudo cp /chain/sealer/geth-pocrnet.service /etc/systemd/system/
sudo cp /chain/common/geth-pocrnet-logrotate /etc/logrotate.d/geth-pocrnet
sudo systemctl daemon-reload
sudo systemctl enable geth-pocrnet
sudo systemctl start geth-pocrnet
```

Checks:

```sh
sudo systemctl status geth-pocrnet
sudo tail -f /chain/geth.log
sudo journalctl -u geth-pocrnet -f
```

Current sealer start script network id: `2606`.

## RPC node (PoCRnet)

### Install and start service

As user `ubuntu`:

```sh
sudo cp /chain/rpc/geth-pocrnet-rpc.service /etc/systemd/system/
sudo cp /chain/common/geth-pocrnet-logrotate /etc/logrotate.d/geth-pocrnet
sudo systemctl daemon-reload
sudo systemctl enable geth-pocrnet-rpc
sudo systemctl start geth-pocrnet-rpc
```

Checks:

```sh
sudo systemctl status geth-pocrnet-rpc
sudo tail -f /chain/geth.log
```

Local RPC check:

```sh
curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Nginx + SSL

Use a custom DNS domain pointing to the EC2 public IP, then run:

```sh
/chain/rpc/setup-nginx-ssl.sh rpc.pocrnet.example.com your-email@example.com
```

Endpoints:

- HTTPS JSON-RPC: `https://rpc.pocrnet.example.com/`
- WSS: `wss://rpc.pocrnet.example.com/ws`

Current RPC start script network id in [pocrnet/scripts/rpc/start_rpc_node.sh](pocrnet/scripts/rpc/start_rpc_node.sh): `1804`.
