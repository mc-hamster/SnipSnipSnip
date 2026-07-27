#!/usr/bin/env bash
set -euo pipefail

open "snipsnipsnip://v1/export/current?format=html&output=file&outputPath=$HOME/Downloads/comparison.html&appearance=styled&overwrite=true"
