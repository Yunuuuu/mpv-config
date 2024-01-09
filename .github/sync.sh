#! /bin/bash
tmp=$(mktemp -d)

repo=$1             # source repo

if [[ "$2" =~ ^@ ]]; then
    branch=$2           # repo branch
    from=$3             # used files
    to=$4
else
    from=$2
    to=$3
fi

echo "$branch"

if [ ! $to ]; then
    to=$from
fi

if [[ $branch == '@gist' ]]; then
    curl -o "$tmp/$from" "https://gist.githubusercontent.com/$repo/raw/$from"
else
    if [ ! $branch ]; then
        git clone --depth 1 https://github.com/$repo $tmp 
    else
        git clone --depth 1 --branch ${branch:1} https://github.com/$repo $tmp
    fi
fi

mkdir -p $to
cp $tmp/$from $to

rm -rf $tmp
