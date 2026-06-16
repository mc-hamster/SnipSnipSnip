#!/usr/bin/env bash
set -euo pipefail

SSSCTL="${SSSCTL:-/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl}"

"$SSSCTL" --json presets list | python3 -c '
import json
import sys

data = json.load(sys.stdin)
presets = data.get("payload", {}).get("presets", {}).get("_0", [])
for preset in presets:
    print("{}\t{}".format(preset.get("id"), preset.get("name")))
'
