#!/usr/bin/env bash
set -euo pipefail

RECT="${RECT:-100,100,640,480}"

open "${SSS_URL_SCHEME:-snipsnipsnip}://v1/capture/region?rect=$RECT&output=editor"
