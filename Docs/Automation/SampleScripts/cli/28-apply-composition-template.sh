#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"
TEMPLATE_ID="${TEMPLATE_ID:-builtin.numbered-steps}"

"$SSSCTL" --json composition template --id "$TEMPLATE_ID"
