#!/bin/bash

if [ $# -ge 1 ]; then
   FLAGS=$@
else
   FLAGS="-vv"
fi

if [ "$MAINNET_FORK_URL" = "" -a "$INFURA_API_KEY" = "" -a "$ALCHEMY_API_KEY" = "" ]; then
   echo "Please export MAINNET_FORK_URL, INFURA_API_KEY or ALCHEMY_API_KEY to continue"
   echo "e.g."
   echo "   export MAINNET_FORK_URL=https://mainnet.infura.io/v3/deadbeefdeadbeefdeadbeefdeadbeef"
   echo "or the slightly shorter:"
   echo "   export INFURA_API_KEY=deadbeefdeadbeefdeadbeefdeadbeef"
   echo "or even:"
   echo "   export ALCHEMY_API_KEY=deadbeefdeadbeefdeadbeefdeadbeef"
   exit 1
fi

if [ "$INFURA_API_KEY" != "" ]; then
   export MAINNET_FORK_URL="https://mainnet.infura.io/v3/$INFURA_API_KEY"
fi

if [ "$ALCHEMY_API_KEY" != "" ]; then
   export MAINNET_FORK_URL="https://eth-mainnet.alchemyapi.io/v2/$ALCHEMY_API_KEY"
fi

## Sep-02-2022 01:51:09 AM +UTC
forge test --fork-url "$MAINNET_FORK_URL" --fork-block-number 15456374 --revert-strings debug $FLAGS

