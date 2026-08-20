#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)"[[:space:]]*$/\1/p' Sources/AstroCore/Product/ProductInfo.swift)"

targets=(README.md docs/index.html docs/features.html docs/tutorial.html docs/cli.html docs/privacy.html docs/support.html Sources/AstroToolApp)
forbidden=(
    "/Volumes/images"
    "/Users/zoltan"
    "Canon R8"
    "SV220"
    "SVBONY"
    "100–400"
    "42,5 h-ból 28 h"
    "167 GB"
    "IC 1396 · Elefántormány-köd"
    ">4:12<"
    ">3 gyűjtés<"
)

failed=0
for needle in "${forbidden[@]}"; do
    if grep -rFn "$needle" "${targets[@]}"; then
        echo "ERROR: public/production placeholder found: $needle" >&2
        failed=1
    fi
done

if [ -z "$VERSION" ]; then
    echo "ERROR: ProductInfo.version could not be read" >&2
    failed=1
fi

if grep -F 'INSTALL_DIR=' build.sh >/dev/null; then
    echo "ERROR: build.sh must not install as a side effect" >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "Public content check passed."
