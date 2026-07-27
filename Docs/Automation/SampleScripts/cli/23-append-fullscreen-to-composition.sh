#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
AFTER_ITEM_ID="${AFTER_ITEM_ID:-00000000-0000-0000-0000-000000000001}"

"$SSSCTL" --json capture fullscreen \
    --destination append \
    --after-item-id "$AFTER_ITEM_ID" \
    --appearance plain \
    --open-editor
