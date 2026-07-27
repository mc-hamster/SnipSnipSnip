#!/usr/bin/env bash
set -euo pipefail

ITEM_ID="${ITEM_ID:-00000000-0000-0000-0000-000000000001}"

open "snipsnipsnip://v1/capture/frontmost-window?destination=replace&item=$ITEM_ID&output=editor"
