#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <repository> <stamp.json>\n' "$0" >&2
    exit 64
fi

# Builds from a copy without git (like the harness's own baseline check) have no stamp: the app records
# the build as unknown. Remove an older stamp so it can't claim a commit this build isn't from.
if ! commit=$(git -C "$1" rev-parse --verify --quiet HEAD 2>/dev/null); then
    rm -f "$2"
    printf 'warning: %s is not a git working copy with a commit; the harness build is recorded as unknown\n' "$1" >&2
    exit 0
fi
status=$(git -C "$1" status --porcelain --untracked-files=normal)
modified=false
if [ -n "$status" ]; then
    modified=true
fi

mkdir -p "$(dirname "$2")"
printf '{"commit":"%s","modified":%s}\n' "$commit" "$modified" > "$2"
