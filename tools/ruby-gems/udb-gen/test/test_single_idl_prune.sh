#!/usr/bin/env bash
# Run from the submodule root. Pruning ⇒ rv32 and rv64 emissions differ in at least one body,
# and both still parse.
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
./bin/generate single-idl -c rv32 -o "$tmp/rv32.isa"
./bin/generate single-idl -c rv64 -o "$tmp/rv64.isa"
./bin/idlc compile --root isa "$tmp/rv32.isa" >/dev/null || { echo "FAIL: rv32 emit does not parse"; exit 1; }
./bin/idlc compile --root isa "$tmp/rv64.isa" >/dev/null || { echo "FAIL: rv64 emit does not parse"; exit 1; }
if diff -q "$tmp/rv32.isa" "$tmp/rv64.isa" >/dev/null; then
  echo "FAIL: rv32 and rv64 emissions are identical — pruning is not config-specific"; exit 1
fi
# reachability prune: emitted function count == the reachable set, and strictly fewer than all functions.
# Stderr is captured separately so info-log noise does not corrupt the captured stdout, while a
# genuine ruby crash (non-zero exit) still surfaces — the stderr log is printed and the test fails.
ruby_stderr="$tmp/ruby_stderr.log"
ruby_out=$(./bin/mise exec -- bundle exec ruby -e '
  require "udb/cfg_arch"
  ca = Udb::Resolver.new.cfg_arch_for("rv64")
  emitted = File.read(ARGV[0]).scan(/\bfunction \w+\?? \{/).size
  puts "#{emitted} #{ca.reachable_functions(show_progress: false).size} #{ca.global_ast.functions.size}"
' "$tmp/rv64.isa" 2>"$ruby_stderr") || {
  echo "FAIL: ruby subprocess exited non-zero"
  echo "--- ruby stderr ---"
  cat "$ruby_stderr"
  exit 1
}
read -r emitted reachable total <<<"$ruby_out"
test "$emitted" -eq "$reachable" || { echo "FAIL: emitted funcs ($emitted) != reachable ($reachable)"; exit 1; }
test "$reachable" -lt "$total"   || { echo "FAIL: reachability dropped nothing ($reachable of $total)"; exit 1; }
echo PASS
