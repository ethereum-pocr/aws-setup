#!/bin/bash

VERSION=$1

if [ -z "$VERSION" ]
then
  echo -n "What version do you want to download? (master):"
  read VERSION
fi

VER=${VERSION:-master}
curl -f -L -o "bin/geth-$VER" \
    https://github.com/ethereum-pocr/go-ethereum/releases/download/$VER/geth

chmod +x "bin/geth-$VER"
# rm bin/geth
# ln -s geth-$VER bin/geth

bin/geth-$VER version
