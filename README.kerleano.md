# Kerleano Network Setup

Follow the shared steps in [README.md](README.md) first.

## Script source and layout

Use scripts from [kerleano/scripts](kerleano/scripts):

```text
common/
  check-stale-bootnodes.sh
  download-genesis.sh
  download-geth.sh
  geth-kerleano-logrotate
  kerleano.json
  kerleano-v2.0.0.json
  monitor-sync.sh
  update-aws-instance-vars.sh
sealer/
  geth-kerleano.service
  init-sealer.sh
  start_sealer_node.sh
  update-bootnodes.sh
rpc/
  geth-kerleano-rpc.service
  nginx-rpc-locations.conf
  nginx-rpc.conf
  setup-nginx-ssl.sh
  start_rpc_node.sh
```

## 1) Download setup assets on the node

As user `geth`:

```sh
aws s3 cp s3://kerleano-node-setup/chain/ . --recursive
chmod +x common/*.sh sealer/*.sh rpc/*.sh
mkdir -p .keystore ~/.ethereum/geth
```

## 2) Enable instance environment variables

Append this block to `~/.bashrc`:

```sh
ENV_FILE="$HOME/.aws-instance-env"

if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
else
  $HOME/common/update-aws-instance-vars.sh
fi

# Add EC2 name to prompt using existing PS1 value (idempotent)
case "$PS1" in
  *'${AWS_INSTANCE_NAME:+['*) ;;
  *) PS1="${PS1%\\$} \[\033[0;33m\]\${AWS_INSTANCE_NAME:+[\$AWS_INSTANCE_NAME]}\[\033[00m\]\\$ " ;;
esac
```

Reload the shell and verify:

```sh
exit
sudo su - geth
cat ~/.aws-instance-env
```

## 3) Install geth binary

```sh
mkdir -p bin
./common/download-geth.sh v1.10.26-pocr-2.0.0
ln -sfn geth-v1.10.26-pocr-2.0.0 bin/geth
```

You can choose another release tag if needed.

## 4) Generate nodekey (required for sealer and rpc)

If `~/.keystore/nodekey` already exists, skip this step.

```sh
geth --datadir ~/.ethereum/
# stop geth once it starts
mv ~/.ethereum/geth/nodekey ~/.keystore/
```

## 5) Bootstrap chain data (archive first, genesis fallback)

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

`init-sealer.sh` uses `kerleano.json` from `/chain` when present, otherwise it
initializes directly from `common/kerleano.json`.

## Sealer node (Kerleano)

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

`update-bootnodes.sh` syncs with `s3://kerleano-node-setup/chain/bootnodes`.

### Install and run systemd service

As user `ubuntu`:

```sh
sudo cp /chain/sealer/geth-kerleano.service /etc/systemd/system/
sudo cp /chain/common/geth-kerleano-logrotate /etc/logrotate.d/geth-kerleano
sudo systemctl daemon-reload
sudo systemctl enable geth-kerleano
sudo systemctl start geth-kerleano
```

Checks:

```sh
sudo systemctl status geth-kerleano
sudo tail -f /chain/geth.log
sudo journalctl -u geth-kerleano -f
```

Current sealer start script network id: `1804`.

## RPC node (Kerleano)

### Install and start service

As user `ubuntu`:

```sh
sudo cp /chain/rpc/geth-kerleano-rpc.service /etc/systemd/system/
sudo cp /chain/common/geth-kerleano-logrotate /etc/logrotate.d/geth-kerleano
sudo systemctl daemon-reload
sudo systemctl enable geth-kerleano-rpc
sudo systemctl start geth-kerleano-rpc
```

Checks:

```sh
sudo systemctl status geth-kerleano-rpc
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
/chain/rpc/setup-nginx-ssl.sh rpc.kerleano.example.com your-email@example.com
```

Endpoints:

- HTTPS JSON-RPC: `https://rpc.kerleano.example.com/`
- WSS: `wss://rpc.kerleano.example.com/ws`
