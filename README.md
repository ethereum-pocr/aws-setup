# Steps to create a VM for kerleano

## Scripts organization

```
scripts/
  common/           # Shared by both node types
    download-geth.sh
    download-genesis.sh
    update-aws-instance-vars.sh
    check-stale-bootnodes.sh
    geth-kerleano-logrotate
    kerleano.json
    kerleano-v2.0.0.json
  sealer/            # Sealer node only
    start_sealer_node.sh
    geth-kerleano.service
    init-sealer.sh
    update-bootnodes.sh
  rpc/               # RPC node only
    start_rpc_node.sh
    geth-kerleano-rpc.service
    nginx-rpc.conf
    nginx-rpc-locations.conf
    setup-nginx-ssl.sh
```

## AWS EC2
- AMI Name: ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20251212
- Instance type : t2.small
- Disk size: 40 Go
- Public IP: yes
- Specify a public key
- Ensure the subnet is public (ie the route table is connected to an internet gateway IGW)
- **RPC node only**: open ports 80 and 443 in the security group (for nginx/SSL)

You can use the `./clone-ec2.sh` to generate a script that will create the instance based on an existing ec2.

## Connection
get the pblic ip generated from the console

```sh
ssh -i ~/.ssh/myAws ubuntu@3.71.205.129
```

or use the `./ssh-connect` with optionnally the `refresh` parameter to update the list of ec2.

## On the ubuntu user

Create user
```sh
sudo adduser --home /chain --disabled-password geth
# allow ubuntu user to read /chain (needed for copying service files and running setup scripts)
sudo chmod o+rx /chain
```

Create a `vi install-aws.sh`

```sh
# Install dependencies
sudo apt-get update
sudo apt-get install -y unzip curl

# Download and install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Verify installation
aws --version
```

```sh
chmod +x install-aws.sh
./install-aws.sh
```

## Connect to the geth user profile and install the node

```sh
sudo su - geth
```

Source the scripts from aws s3 bucket.
Il will also download a backup of the kerleano network up to block 24.000.000 ish

```sh
aws s3 cp s3://kerleano-node-setup/chain/ . --recursive
# give execute rights to the scripts
chmod +x common/*.sh sealer/*.sh rpc/*.sh
# create the keystore
mkdir -p .keystore
# expand the chain data
mkdir -p ~/.ethereum/geth/
tar -xzf ./chaindata-20260206.tar.gz -C ~/.ethereum/geth/
rm chaindata-20260206.tar.gz
```

The export result should give
```sh
du -h .
      80K     ./common
      8.6G    ./.ethereum/geth/chaindata/ancient/chain
      8.6G    ./.ethereum/geth/chaindata/ancient
      12G     ./.ethereum/geth/chaindata
      12G     ./.ethereum/geth
      12G     ./.ethereum
      24K     ./rpc
      20K     ./sealer
      12G     .
```

Install geth for pocr:
```sh
mkdir bin
./common/download-geth.sh v1.10.26-pocr-2.0.0
ln -s geth-v1.10.26-pocr-2.0.0 bin/geth
```


Add the following at the end of the `.bashrc` file

```sh

ENV_FILE="$HOME/.aws-instance-env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
   $HOME/common/update-aws-instance-vars.sh
fi
```

Exit the shell `ctrl+d` and login again `sudo su - geth` to force a reload of the profile

Check the loading of env variables:
```sh
cat .aws-instance-env
```

## Generate the new nodekey

```sh
geth --datadir .ethereum/
# then kill the process when it has started. This will generate a nodekey file we will move
mv ./.ethereum/geth/nodekey .keystore
```

---

# Sealer Node Setup

Follow the common steps above, then continue with the sealer-specific steps below.

## Generate a new account (sealer only) if you do not have it yet

```sh
geth account new --keystore .keystore/
# you will be asked for the password, ensure to save it in a file
# place your password in .passphrase
vi .passphrase
# set the wallet address into
echo "0xxxx...yyy" > .etherbase
```

## Reuse an existing etherbase wallet

```sh
# paste the json wallet into a UTC file
vi .keystore/UTC--2022-06-27T13-33-20.841699368Z--0543aa379ec69fad09a0d0362ef85aa0b861e410
# paste the password into .passphrase
vi .passphrase
# set the wallet address into
echo "0xxxx...yyy" > .etherbase
```

## Setup bootnodes auto-registration (Sealer only)

On the `geth` user, install a cron job that registers the local enode into the shared bootnodes file on S3 every 5 minutes:

```sh
# install the cron job
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/sealer/update-bootnodes.sh >> $HOME/update-bootnodes.log 2>&1") | crontab -
```

The script will:
1. Download the bootnodes file from S3
2. Extract the local enode from the running geth node (via IPC)
3. Add the enode if missing, or update the IP if it changed
4. Upload the updated file back to S3

## Install the systemd service (Sealer)

Back on the `ubuntu` user, install the service to ensure geth is monitored and restarted automatically:

```sh
# copy the service file
sudo cp /chain/sealer/geth-kerleano.service /etc/systemd/system/
# install log rotation (daily, keeps 7 days, rotates at 100MB)
sudo cp /chain/common/geth-kerleano-logrotate /etc/logrotate.d/geth-kerleano
# reload systemd
sudo systemctl daemon-reload
# enable the service to start on boot
sudo systemctl enable geth-kerleano
```

Note: `start_sealer_node.sh` must run geth in the **foreground** (no `nohup`, no `&`, no `daemonize`). If it currently backgrounds the process, edit it so geth runs directly (e.g. `exec geth ...`). systemd needs to manage the process lifecycle.

Log rotation is handled by logrotate: daily rotation, compressed archives kept for 7 days, with an additional size trigger at 100MB.

## Run the sealer node

Start the service:
```sh
sudo systemctl start geth-kerleano
# check status
sudo systemctl status geth-kerleano
# watch logs
sudo tail -f /chain/geth.log
# or via journalctl
sudo journalctl -u geth-kerleano -f
```

To stop manually:
```sh
sudo systemctl stop geth-kerleano
```

---

# RPC Node Setup (JSON-RPC client)

Follow the common steps above, then continue with the RPC-specific steps below.

The RPC node does not mine and does not require an etherbase account. It exposes HTTP and WebSocket JSON-RPC endpoints behind an nginx reverse proxy with SSL.

Note that you will need to map the public ip of the node to a dns name.  
We can use the https://freedns.afraid.org/subdomain/ 

## Install the systemd service (RPC)

Back on the `ubuntu` user:

```sh
# copy the service file
sudo cp /chain/rpc/geth-kerleano-rpc.service /etc/systemd/system/
# install log rotation (daily, keeps 7 days, rotates at 100MB)
sudo cp /chain/common/geth-kerleano-logrotate /etc/logrotate.d/geth-kerleano
# reload systemd
sudo systemctl daemon-reload
# enable the service to start on boot
sudo systemctl enable geth-kerleano-rpc
```

Note: `start_rpc_node.sh` must run geth in the **foreground** (same as sealer). systemd manages the process lifecycle.

## Start geth and wait for sync

```sh
sudo systemctl start geth-kerleano-rpc
# check status
sudo systemctl status geth-kerleano-rpc
# watch logs
sudo tail -f /chain/geth.log
```

You can verify the RPC is working locally:
```sh
curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Setup nginx reverse proxy with SSL

**Important**: Let's Encrypt cannot issue certificates for AWS default hostnames (`*.compute.amazonaws.com`). You must use a custom domain name. Options:
- Use a domain you own and create an A record pointing to the EC2 public IP
- Register a cheap domain via Route 53 (`.click`, `.link` domains start at ~$3/year)

Once your domain's A record points to the EC2 public IP and ports 80/443 are open in the security group, run the setup script on the `ubuntu` user:

```sh
/chain/rpc/setup-nginx-ssl.sh rpc.kerleano.example.com your-email@example.com
```

This will:
1. Install nginx and certbot
2. Configure nginx to reverse proxy HTTP JSON-RPC (`/`) and WebSocket (`/ws`)
3. Obtain a Let's Encrypt SSL certificate (certbot modifies the nginx config to add the HTTPS server block)
4. Enable automatic certificate renewal via systemd timer

## Using the RPC endpoints

Once setup is complete, the endpoints are available at:

- **HTTPS JSON-RPC**: `https://rpc.kerleano.example.com/`
- **WebSocket**: `wss://rpc.kerleano.example.com/ws`

Test from your local machine:
```sh
# HTTP JSON-RPC
curl -s -X POST https://rpc.kerleano.example.com/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# WebSocket (requires wscat: npm install -g wscat)
wscat -c wss://rpc.kerleano.example.com/ws
> {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}
```

To stop the RPC node:
```sh
sudo systemctl stop geth-kerleano-rpc
```
