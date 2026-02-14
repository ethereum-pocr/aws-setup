VERSION=$1

if [ -z "$VERSION" ]
then
  echo -n "What version do you want to download? (latest):"
  read VERSION
fi

VER=${VERSION:-latest}


curl -f -L -o ~/kerleano-$VER.json https://github.com/ethereum-pocr/ethereum-pocr.github.io/releases/download/$VER/kerleano.json
