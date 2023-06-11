#!/bin/sh

rsync -rv \
    --delete \
    --exclude /.git \
    --exclude /library/strategy \
    --exclude scripts \
    --exclude target \
    --exclude .teller.yml \
    --exclude /out \
    --exclude '*.sh' \
    ../grasshopper/ .

mkdir -p library/strategy
cp ../grasshopper/library/strategy/hedge.lua library/strategy/
cp ../grasshopper/library/strategy/trade_utils.lua library/strategy/
