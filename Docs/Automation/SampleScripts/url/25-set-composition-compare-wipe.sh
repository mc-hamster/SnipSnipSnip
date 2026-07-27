#!/usr/bin/env bash
set -euo pipefail

FIRST_ITEM_ID="${FIRST_ITEM_ID:-00000000-0000-0000-0000-000000000001}"
SECOND_ITEM_ID="${SECOND_ITEM_ID:-00000000-0000-0000-0000-000000000002}"

open "snipsnipsnip://v1/composition/compare?mode=wipe&firstItemID=$FIRST_ITEM_ID&secondItemID=$SECOND_ITEM_ID&wipePosition=0.4"
