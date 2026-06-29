#!/usr/bin/env bash
# Run from the submodule root.
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
./bin/generate single-idl -c rv64 -o "$tmp/rv64.isa"
# (a) the grammar accepts it
./bin/idlc compile --root isa "$tmp/rv64.isa" >/dev/null || { echo "FAIL: emitted .isa does not parse"; exit 1; }
# (b) it actually contains function/enum content (not just the header)
grep -q '^%version: 1.0' "$tmp/rv64.isa" || { echo "FAIL: missing header"; exit 1; }
test "$(wc -l < "$tmp/rv64.isa")" -gt 50 || { echo "FAIL: suspiciously small output"; exit 1; }
grep -q 'function ' "$tmp/rv64.isa" || { echo "FAIL: no functions emitted"; exit 1; }
echo PASS
