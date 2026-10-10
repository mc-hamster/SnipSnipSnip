#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
encoded_path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$OUTPUT_DIR/comparison.html")"

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/export/current?format=html&output=file&outputPath=$encoded_path&appearance=app-default&overwrite=true"
