# Copyright (c) Velaura AI.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require "idlc"
require "idlc/passes/reachable_functions"
require_relative "helpers"

# The reachable-functions pass tracks compile-time-known variable values so it can skip arms that
# can never run. That is only sound if a variable assigned in code that MAY NOT RUN (an arm taken
# under an unknown condition, a loop body, a conditional statement) is unknown afterwards. The pass
# used to keep the value from the last arm it walked, so a later call such as `gate(sp)` was
# analysed with a constant `sp`, a condition inside `gate` folded, and the callee under it was
# dropped. A real instance: fcvt.d.s does `if (<unknown>) { sp_value = SP_CANONICAL_NAN; }` and then
# calls f32_to_f64(sp_value); the subnormal-input path of f32_to_f64_no_flag was never reached.
#
# Unknown values come from `opaque()`, a builtin whose result is never known at compile time.
# Every assertion is on a callee that is reachable in at least one real execution, except the
# precision control, which checks that known conditions still prune.
class TestReachableFunctionsAssignedValues < Minitest::Test
  include TestMixin

  PRELUDE = <<~IDL
    %version: 1.0

    builtin function opaque {
      returns Bits<8>
      description { a value that is never known at compile time }
    }

    function only_five {
      description { reached only when its caller's value can be 5 }
      body { }
    }

    function gate {
      arguments Bits<8> v
      description { calls only_five iff v is 5 }
      body {
        if (v == 8'h5) {
          only_five();
        }
      }
    }
  IDL

  def compile_idl(idl_str)
    t = Tempfile.new("idl")
    t.write PRELUDE + idl_str
    t.close
    ast = @compiler.compile_file(Pathname.new(t.path))
    ast.add_global_symbols(@symtab)
    @symtab.deep_freeze
    ast.freeze_tree(@symtab)
    ast
  end

  # Walks `func_name`'s body the way the pass does on entering a call: in a fresh, writable scope.
  def reachable_names(func_name, ast)
    fn_ast = ast.functions.find { |f| f.name == func_name }
    symtab = @symtab.deep_clone
    symtab.push(fn_ast)
    names = fn_ast.body.reachable_functions(symtab, {}).map(&:name)
    symtab.pop
    names
  end

  # The fcvt.d.s shape: a constant is assigned under an unknown condition, then the variable is
  # passed on. It is the constant OR the opaque value, so only_five is reachable when that is 5.
  def test_variable_assigned_a_constant_under_an_unknown_condition_is_unknown_afterwards
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          Bits<8> sp = opaque();
          if (opaque() != 8'h1) {
            sp = 8'h0;
          }
          gate(sp);
        }
      }
    IDL

    assert_includes reachable_names("a", ast), "only_five",
                    "sp is opaque() or 0 after the if, so gate(sp) can reach only_five"
  end

  # An assignment in one arm must not be visible while walking a sibling arm.
  def test_assignment_in_one_arm_does_not_leak_into_a_sibling_arm
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          Bits<8> t = 8'h5;
          if (opaque() == 8'h1) {
            t = 8'h0;
          } else {
            gate(t);
          }
        }
      }
    IDL

    assert_includes reachable_names("a", ast), "only_five",
                    "in the else arm t is still 5; the if arm's t = 0 must not leak into it"
  end

  # A loop body runs an unknown number of times, so a value assigned late in the body is visible to
  # the next iteration's earlier statements.
  def test_loop_body_assignment_is_visible_to_earlier_statements_of_the_body
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          Bits<8> t = 8'h0;
          for (U32 i = 0; i < 2; i++) {
            gate(t);
            t = 8'h5;
          }
        }
      }
    IDL

    assert_includes reachable_names("a", ast), "only_five",
                    "on the second iteration gate sees t == 5"
  end

  def test_conditional_statement_assignment_is_unknown_afterwards
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          Bits<8> t = 8'h0;
          t = 8'h5 if (opaque() == 8'h1);
          gate(t);
        }
      }
    IDL

    assert_includes reachable_names("a", ast), "only_five",
                    "t is 5 when the condition holds, so gate(t) can reach only_five"
  end

  # Precision must survive: when the condition IS known, the chosen arm's assignment is exact and
  # the dead arm's callee stays unreachable.
  def test_known_condition_arm_keeps_the_exact_value
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          Bits<8> t = 8'h5;
          if (8'h1 == 8'h1) {
            t = 8'h0;
          }
          gate(t);
        }
      }
    IDL

    refute_includes reachable_names("a", ast), "only_five",
                    "the known-true arm sets t to 0, so gate(0) cannot reach only_five"
  end

  # Control: an unknown condition with no assignments changes nothing about what is reachable.
  def test_unknown_condition_without_assignments_walks_both_arms
    ast = compile_idl(<<~IDL)
      function a {
        description { a }
        body {
          if (opaque() == 8'h1) {
            gate(8'h5);
          } else {
            gate(8'h0);
          }
        }
      }
    IDL

    assert_includes reachable_names("a", ast), "only_five"
  end
end
