#!/bin/bash
set -v

if [ $# -ge 1 ]; then
   FLAGS=$@
else
   FLAGS="-vv"
fi

## Sep-02-2022 01:51:09 AM +UTC
forge test --fork-url https://mainnet.infura.io/v3/88c04cb1d87c4a1d863bc878516e6e34 --fork-block-number 15456374 --revert-strings debug $FLAGS

