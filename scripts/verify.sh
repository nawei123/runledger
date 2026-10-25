#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
moon_bin="${MOON:-moon}"
"$moon_bin" version --all
"$moon_bin" update
"$moon_bin" fmt --check
"$moon_bin" check --deny-warn
"$moon_bin" test --deny-warn
"$moon_bin" build --deny-warn
python3 scripts/test_cli.py
"$moon_bin" info
git diff --exit-code -- '*.mbti'
