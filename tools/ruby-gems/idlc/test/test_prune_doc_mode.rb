# Copyright (c) Velaura AI.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "idlc"
require "idlc/passes/prune"
require_relative "helpers"
require "minitest/autorun"

# Documentation prune mode (smorg): known values still choose control flow, but no expression is
# replaced by the literal it evaluates to.
class TestPruneDocMode < Minitest::Test
  include TestMixin

  def symtab_with_names
    symtab = Idl::SymbolTable.new
    symtab.add("MXLEN", Idl::Var.new("MXLEN", Idl::Type.new(:bits, width: 7, qualifiers: [:const]), 64, param: true))
    symtab.add("FLAGS", Idl::Var.new("FLAGS", Idl::Type.new(:bits, width: 8, qualifiers: [:const]), 0, param: true))
    symtab.add("NEG_OVERFLOW", Idl::Var.new("NEG_OVERFLOW", Idl::Type.new(:bits, width: 32, qualifiers: [:const]), 0x8000_0000))
    symtab.add("ENABLED", Idl::Var.new("ENABLED", Idl::Type.new(:boolean, qualifiers: [:const]), true, param: true))
    symtab.add("DISABLED", Idl::Var.new("DISABLED", Idl::Type.new(:boolean, qualifiers: [:const]), false, param: true))
    symtab.add("x", Idl::Var.new("x", Idl::Type.new(:bits, width: 8)))
    symtab.add("b", Idl::Var.new("b", Idl::Type.new(:boolean)))
    symtab
  end

  # to_idl parenthesizes binary expressions, so expected text is compared in the same printed form
  def printed(idl) = @compiler.build_ast(idl, root: :expression).to_idl

  def prune_expr(idl, fold:)
    symtab = symtab_with_names
    ast = @compiler.build_ast(idl, root: :expression)
    symtab.with_fold_values(fold) { ast.prune(symtab) }
  end

  # Each expression is fully known; doc mode must print it exactly as unpruned, default must fold.
  KEPT_EXPRESSIONS = [
    "MXLEN",              # parameter
    "NEG_OVERFLOW",       # global constant
    "MXLEN - 1",          # expression of a parameter
    "~FLAGS",             # unary of a parameter
    "{FLAGS, FLAGS}",     # concatenation of known values
    "MXLEN == 64",        # known comparison in a value position
    "ENABLED && ENABLED"  # both sides known in a value position
  ].freeze

  def test_doc_mode_keeps_known_expressions_as_written
    KEPT_EXPRESSIONS.each do |idl|
      unpruned = @compiler.build_ast(idl, root: :expression).to_idl
      assert_equal unpruned, prune_expr(idl, fold: false).to_idl, "doc mode changed #{idl}"
    end
  end

  def test_default_mode_still_folds_the_same_expressions
    KEPT_EXPRESSIONS.each do |idl|
      pruned = prune_expr(idl, fold: true)
      assert(pruned.is_a?(Idl::IntLiteralAst) || pruned.is_a?(Idl::TrueExpressionAst) || pruned.is_a?(Idl::FalseExpressionAst),
             "default mode did not fold #{idl}: #{pruned.to_idl}")
    end
  end

  def test_doc_mode_and_or_shortens_when_known_side_does_not_decide
    assert_equal "b", prune_expr("ENABLED && b", fold: false).to_idl
    assert_equal "b", prune_expr("b && ENABLED", fold: false).to_idl
    assert_equal "b", prune_expr("DISABLED || b", fold: false).to_idl
  end

  def test_doc_mode_and_or_keeps_expression_when_known_side_decides
    assert_equal printed("b && DISABLED"), prune_expr("b && DISABLED", fold: false).to_idl
    assert_equal printed("b || ENABLED"), prune_expr("b || ENABLED", fold: false).to_idl
  end

  def test_doc_mode_skips_bitwise_identities
    assert_equal printed("FLAGS | x"), prune_expr("FLAGS | x", fold: false).to_idl
    assert_equal printed("x & FLAGS"), prune_expr("x & FLAGS", fold: false).to_idl
    # default mode applies them
    assert_equal "x", prune_expr("FLAGS | x", fold: true).to_idl
  end

  def test_doc_mode_takes_known_ternary_arm_without_folding_it
    assert_equal printed("MXLEN - 1"), prune_expr("ENABLED ? MXLEN - 1 : 7'd0", fold: false).to_idl
  end

  def compile_body(idl, symtab)
    @compiler.compile_func_body(idl, return_type: Idl::Type.new(:bits, width: 8), symtab:, input_file: "temp")
  end

  def test_doc_mode_removes_dead_branch_and_keeps_names
    idl = <<~IDL
      if (MXLEN == 32) {
        return 8'd1;
      }
      return FLAGS;
    IDL
    symtab = symtab_with_names
    pruned = symtab.with_fold_values(false) { compile_body(idl, symtab).prune(symtab) }
    out = pruned.to_idl
    refute_match(/8'd1/, out, "dead branch survived")
    assert_match(/return FLAGS;/, out)
  end

  def test_doc_mode_keeps_known_local_by_name
    idl = <<~IDL
      Bits<8> shamt = 8'd3;
      return x << shamt;
    IDL
    symtab = symtab_with_names
    pruned = symtab.with_fold_values(false) { compile_body(idl, symtab).prune(symtab) }
    assert_match(/x << shamt/, pruned.to_idl)
  end

  def test_fold_values_defaults_true_and_on_allocated_tables
    assert Idl::SymbolTable.new.fold_values?
    assert Idl::SymbolTable.allocate.fold_values?, "pooled tables are built with allocate"
  end

  def test_with_fold_values_restores_on_exception
    symtab = Idl::SymbolTable.new
    assert_raises(RuntimeError) { symtab.with_fold_values(false) { raise "boom" } }
    assert symtab.fold_values?
  end
end
