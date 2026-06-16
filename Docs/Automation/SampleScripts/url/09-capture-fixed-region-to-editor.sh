#!/usr/bin/env bash
set -euo pipefail

RECT="${RECT:-100,100,640,480}"

open "snipsnipsnip://v1/capture/region?rect=$RECT&output=editor"
