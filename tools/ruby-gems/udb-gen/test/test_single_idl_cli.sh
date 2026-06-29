#!/usr/bin/env bash
# Run from the submodule root: tools/ruby-gems/udb-gen/test/test_single_idl_cli.sh
set -euo pipefail
out="$(./bin/generate single-idl -c _ 2>&1)" || { echo "FAIL: nonzero exit"; echo "$out"; exit 1; }
echo "$out" | head -1 | grep -q '^%version: 1.0' || { echo "FAIL: missing %version: header"; echo "$out"; exit 1; }
echo PASS
