#!/usr/bin/env bash
set -euo pipefail

target="${1:-area}"
case "${target}" in
    active|area|output|screen) ;;
    *)
        printf 'usage: %s [active|area|output|screen]\n' "$0" >&2
        exit 2
        ;;
esac

directory="${HOME:?}/Pictures/Screenshots"
mkdir -p "${directory}"

timestamp="$(date +'%Y-%m-%d_%H-%M-%S_%N')"
path="${directory}/Screenshot_${timestamp}.png"

# Keep the clipboard behavior while making the on-disk capture authoritative.
grimblast -n copysave "${target}" "${path}"
