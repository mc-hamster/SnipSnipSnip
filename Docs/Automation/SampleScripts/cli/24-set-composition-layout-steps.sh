#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json composition layout \
    --layout steps \
    --axis vertical \
    --step-numbering uppercase-letters \
    --step-start-index 1 \
    --step-captions true \
    --step-connector arrow
