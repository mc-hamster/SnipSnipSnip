#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
FIRST_ITEM_ID="${FIRST_ITEM_ID:-00000000-0000-0000-0000-000000000001}"
SECOND_ITEM_ID="${SECOND_ITEM_ID:-00000000-0000-0000-0000-000000000002}"

"$SSSCTL" --json composition compare --mode wipe \
    --first-item-id "$FIRST_ITEM_ID" \
    --second-item-id "$SECOND_ITEM_ID" \
    --wipe-position 0.4
