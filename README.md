# AWS Node Setup (Common)

This repository contains scripts to provision and configure EC2 nodes for two networks:

- [Kerleano testnet](README.kerleano.md)
- [PoCRnet production](README.pocrnet.md)

Use this file for shared setup steps, then continue with the network-specific guide.

## Repository structure

```text
kerleano/scripts/
  common/
  sealer/
  rpc/

pocrnet/scripts/
  common/
  sealer/
  rpc/
```

## 1) Create the EC2 instance

- AMI: `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20251212`
- Instance type: `t2.small` (or larger if needed)
- Disk: `40 GB` minimum
- Public IP: enabled
- SSH key pair: configured
- Subnet: public (route table attached to an Internet Gateway)
- RPC nodes only: open inbound ports `80` and `443`

Helper scripts at repository root:

- `./clone-ec2.sh` to generate a create script from an existing EC2
- `./ssh-connect.sh` to connect quickly (optionally refresh instance list)

## 2) Connect as ubuntu

```sh
ssh -i ~/.ssh/myAws ubuntu@<EC2_PUBLIC_IP>
```

## 3) Create geth user and install AWS CLI

```sh
sudo adduser --home /chain --disabled-password geth
sudo chmod o+rx /chain

sudo apt-get update
sudo apt-get install -y unzip curl

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

## 4) Switch to geth user

```sh
sudo su - geth
```

From now on, run commands as `geth` unless specified otherwise.

## 5) Continue with network-specific guide

The next steps depend on network-specific files downloaded from S3.
Complete one of the guides below from top to bottom.

- For Kerleano: [README.kerleano.md](README.kerleano.md)
- For PoCRnet: [README.pocrnet.md](README.pocrnet.md)
