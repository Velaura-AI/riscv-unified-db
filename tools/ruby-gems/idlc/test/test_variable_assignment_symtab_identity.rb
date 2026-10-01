# Copyright (c) Velaura AI.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "minitest/autorun"

require "idlc"
require_relative "helpers"

# VariableAssignmentAst#var used to cache the Var it resolved on the AST node, keyed only by
# symtab.name. Symbol tables are routinely distinct objects that share a name (every table built
# for one configuration is named after it), so a node that had already been executed against an
# earlier table kept writing to THAT table's Var. The table currently being walked never saw the
# assignment: a variable assigned an unknown value stayed at its old, known value, and any
# condition on it folded to a known constant. The reachable-functions pass then pruned the dead arm
# of `if (dtype_val == 10'd3)` and dropped the functions called inside it.
class TestVariableAssignmentSymtabIdentity < Minitest::Test
  include TestMixin

  def fresh_symtab(vars)
    symtab = Idl::SymbolTable.new(register_files: [DEFAULT_X_REGISTER_FILE])
    symtab.push(nil)
    vars.each do |name, value|
      symtab.add(name, Idl::Var.new(name, Idl::Type.new(:bits, width: 32), value))
    end
    symtab
  end

  # The one assignment statement in `idl`, type-checked once and then reused against several tables.
  def assignment_in(idl)
    body = @compiler.compile_func_body(idl, symtab: @symtab, no_rescue: true, input_file: "")
    assignments = body.statements.map(&:action).grep(Idl::VariableAssignmentAst)
    assert_equal 1, assignments.size
    assignments.first
  end

  def test_two_symtabs_with_the_same_name_really_are_distinct_objects
    a = fresh_symtab({})
    b = fresh_symtab({})
    assert_equal a.name, b.name
    refute_same a, b
  end

  def test_known_assignment_updates_the_live_variable_of_every_symtab
    assign = assignment_in("U32 x = 0; x = 5;")

    a = fresh_symtab({ "x" => 0 })
    assign.execute(a)
    assert_equal 5, a.get("x").value

    b = fresh_symtab({ "x" => 0 })
    assign.execute(b)
    assert_equal 5, b.get("x").value, "second symtab's x was not updated (stale cached Var)"
  end

  # The production shape: `dtype_val = CSR[...].VALUE` has an unknown right-hand side, so the
  # variable must become unknown in whichever table is being walked.
  def test_unknown_assignment_makes_the_live_variable_unknown_in_every_symtab
    assign = assignment_in("U32 x = 0; U32 y; x = y;")

    # value_error is a `throw :value_error`, not an exception: value_try reports it as :unknown_value.
    a = fresh_symtab({ "x" => 0, "y" => nil })
    assert_equal :unknown_value, Idl::AstNode.value_try { assign.execute(a) }
    assert_nil a.get("x").value

    b = fresh_symtab({ "x" => 0, "y" => nil })
    assert_equal :unknown_value, Idl::AstNode.value_try { assign.execute(b) }
    assert_nil b.get("x").value, "x stayed at its stale known value in the second symtab"
  end

  def test_execution_never_touches_another_symtabs_variable
    assign = assignment_in("U32 x = 0; x = 5;")

    a = fresh_symtab({ "x" => 0 })
    b = fresh_symtab({ "x" => 0 })
    assign.execute(a)
    assert_equal 5, a.get("x").value
    assert_equal 0, b.get("x").value, "assigning in one symtab leaked into another"
  end
end
