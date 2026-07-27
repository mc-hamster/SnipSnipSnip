#!/usr/bin/env bash
set -euo pipefail

AFTER_ITEM_ID="${AFTER_ITEM_ID:-00000000-0000-0000-0000-000000000001}"

open "snipsnipsnip://v1/capture/fullscreen?destination=append&after=$AFTER_ITEM_ID&appearance=plain&output=editor"
