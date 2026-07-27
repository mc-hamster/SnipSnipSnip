#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_ID="${TEMPLATE_ID:-builtin.numbered-steps}"

open "snipsnipsnip://v1/composition/template?id=$TEMPLATE_ID"
