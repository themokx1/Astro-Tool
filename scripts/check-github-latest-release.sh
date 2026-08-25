#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <expected-release-tag>" >&2
    exit 64
fi

EXPECTED_TAG="$1"

if [ -n "${ASTROTOOL_LATEST_RELEASE_JSON:-}" ]; then
    ACTUAL_TAG="$(printf '%s' "$ASTROTOOL_LATEST_RELEASE_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
else
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must identify the release repository}"
    ACTUAL_TAG="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name)"
fi

if [ -z "$ACTUAL_TAG" ]; then
    echo "ERROR: GitHub latest release tag could not be read." >&2
    exit 1
fi

if [ "$ACTUAL_TAG" != "$EXPECTED_TAG" ]; then
    echo "ERROR: expected $EXPECTED_TAG, got $ACTUAL_TAG from GitHub latest release." >&2
    exit 1
fi

echo "GitHub latest release is $ACTUAL_TAG."
