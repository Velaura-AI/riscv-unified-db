# Copyright (c) Velaura AI.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "idlc"
require "idlc/passes/prune"
require_relative "helpers"
require "minitest/autorun"

# Pruning already-pruned code (smorg). An `if` whose condition is known prunes to its taken
# body, an IfBodyAst spliced into the parent's statement list; a second prune must treat that
# body as the straight-line code it stands for.
class TestPruneReprune < Minitest::Test
  include TestMixin

  def symtab_with_names
    symtab = Idl::SymbolTable.new
    symtab.add("ENABLED", Idl::Var.new("ENABLED", Idl::Type.new(:boolean, qualifiers: [:const]), true, param: true))
    symtab.add("x", Idl::Var.new("x", Idl::Type.new(:bits, width: 8)))
    symtab
  end

  def prune_body(idl)
    symtab = symtab_with_names
    body = @compiler.compile_func_body(idl, return_type: Idl::Type.new(:bits, width: 8), symtab:, input_file: "temp")
    body.prune(symtab)
  end

  def reprune(pruned) = pruned.prune(symtab_with_names)

  # The spliced body's assignment must stay visible after it: rolling it back leaves `v` at its
  # initial 0, and the return folds to that stale literal.
  def test_reprune_keeps_assignment_made_in_taken_branch
    pruned = prune_body(<<~IDL)
      Bits<8> w = x;
      Bits<8> v = 8'd0;
      if (ENABLED) {
        v = x;
      }
      return v;
    IDL
    assert_match(/return v;/, pruned.to_idl)
    again = reprune(pruned)
    refute_nil again
    assert_equal pruned.to_idl, again.to_idl
  end

  # Executing the spliced body hits an unknown value (`x`); that must reach the enclosing
  # value_try as unknown, not as a nil that no value_else recognizes, which left the pruned
  # function body unset.
  def test_reprune_of_taken_branch_with_unknown_value_returns_a_body
    pruned = prune_body(<<~IDL)
      Bits<8> v = 8'd0;
      if (ENABLED) {
        v = x;
      }
      return v;
    IDL
    again = reprune(pruned)
    refute_nil again, "re-prune returned nil"
    assert_equal pruned.to_idl, again.to_idl
  end

  def test_if_body_execute_reports_unknown_value
    symtab = symtab_with_names
    body = @compiler.compile_func_body(<<~IDL, return_type: Idl::Type.new(:bits, width: 8), symtab:, input_file: "temp")
      Bits<8> v = 8'd0;
      if (ENABLED) {
        v = x;
      }
      return v;
    IDL
    if_body = body.statements.find { |s| s.is_a?(Idl::IfAst) }.if_body
    symtab.push(body)
    symtab.add("v", Idl::Var.new("v", Idl::Type.new(:bits, width: 8), 0))
    result = Idl::AstNode.value_try { if_body.execute(symtab) }
    symtab.pop
    assert_equal :unknown_value, result
  end
end
