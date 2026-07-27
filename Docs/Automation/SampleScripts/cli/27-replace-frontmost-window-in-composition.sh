#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
ITEM_ID="${ITEM_ID:-00000000-0000-0000-0000-000000000001}"

"$SSSCTL" --json capture frontmost-window \
    --destination replace \
    --replace-item-id "$ITEM_ID" \
    --open-editor
