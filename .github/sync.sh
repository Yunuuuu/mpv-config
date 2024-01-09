#! /bin/bash
tmp=$(mktemp -d)

repo=$1             # source repo
from=$2             # used files

if [ ! $3 ]; then
    to=$from
else
    to=$3
fi

git clone https://github.com/$repo $tmp --depth 1

cp $tmp/$from $to

rm -rf $tmp
