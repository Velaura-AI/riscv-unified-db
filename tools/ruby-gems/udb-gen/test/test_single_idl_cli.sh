#!/usr/bin/env bash
# Run from the submodule root: tools/ruby-gems/udb-gen/test/test_single_idl_cli.sh
set -euo pipefail
out="$(./bin/generate single-idl -c _ 2>/dev/null)" || { echo "FAIL: nonzero exit"; exit 1; }
first_line="${out%%$'\n'*}"
[[ "$first_line" =~ ^%version:\ 1\.0 ]] || { echo "FAIL: missing %version: header (first line: $first_line)"; exit 1; }
echo PASS
