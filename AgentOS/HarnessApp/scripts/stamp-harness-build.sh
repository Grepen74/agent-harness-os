#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <repository> <stamp.json>\n' "$0" >&2
    exit 64
fi

commit=$(git -C "$1" rev-parse --verify HEAD)
status=$(git -C "$1" status --porcelain --untracked-files=normal)
modified=false
if [ -n "$status" ]; then
    modified=true
fi

mkdir -p "$(dirname "$2")"
printf '{"commit":"%s","modified":%s}\n' "$commit" "$modified" > "$2"
