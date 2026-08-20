#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <release-tag>" >&2
    exit 64
fi

case "$1" in
    v[0-9]*-*) printf '%s\n' '--prerelease' ;;
    v[0-9]*) : ;;
    *)
        echo "ERROR: invalid release tag: $1" >&2
        exit 64
        ;;
esac
