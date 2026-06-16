#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

result="$("$SSSCTL" --json repeat-last --open-editor)"
printf '%s\n' "$result"

python3 -c '
import json
import sys

data = json.loads(sys.argv[1])
if data.get("status") != "succeeded":
    error = data.get("error") or {}
    raise SystemExit("repeat-last failed: {} {}".format(error.get("code"), error.get("message")))
' "$result"
