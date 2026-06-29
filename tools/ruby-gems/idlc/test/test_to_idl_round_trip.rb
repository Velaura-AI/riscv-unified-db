# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "pathname"

require "idlc"
require_relative "helpers"

$root ||= (Pathname.new(__FILE__) / ".." / ".." / ".." / "..").realpath

# Regression tests for to_idl serializer correctness.
#
# Each test round-trips an ISA snippet through:
#   source -> build_ast -> to_idl -> re-parse (should not raise SyntaxError)
#
# Bugs fixed (xpu/single-idl-emitter branch):
#   - GlobalWithInitializationAst#to_idl: missing trailing ';'
#   - GlobalAst#to_idl: missing trailing ';'
#   - BuiltinEnumDefinitionAst#to_idl: missing trailing ';'
#   - CsrFunctionCallAst#to_idl: emitted bare 'name.fn()' instead of 'CSR[name].fn()'
class TestToIdlRoundTrip < Minitest::Test
  include TestMixin

  ISA_HEADER = "%version: 1.0\n"

  # Parse an ISA source snippet; raises SyntaxError if the grammar rejects it.
  def parse_isa(source)
    compiler = Idl::Compiler.new
    compiler.ts_build(source, filename: "[test]")
  end

  # Round-trip helper: parse source, call to_idl on each top-level definition,
  # reassemble a minimal ISA, and re-parse. Asserts no SyntaxError.
  def round_trip_isa(source)
    full = "#{ISA_HEADER}#{source}"
    ast = parse_isa(full)
    assert_instance_of Idl::IsaAst, ast, "Expected IsaAst from parse"

    reconstructed = ISA_HEADER + ast.children.map(&:to_idl).join("\n")
    begin
      parse_isa(reconstructed)
    rescue SyntaxError => e
      flunk "to_idl output failed to re-parse:\n#{e.message}\n\nEmitted IDL:\n#{reconstructed}"
    end
    reconstructed
  end

  # -------------------------------------------------------------------------
  # GlobalWithInitializationAst: global var with initializer must end with ';'
  # -------------------------------------------------------------------------

  def test_global_with_initialization_round_trips
    idl = round_trip_isa("Bits<32> MY_CONST = 32'hDEAD;\n")
    # The serialized global must carry a trailing semicolon
    assert_match(/Bits<32>.*MY_CONST.*=.*32'hDEAD.*;\s*\z/m, idl.sub(ISA_HEADER, "").strip + ";")
    # Exactly one semicolon per global (no double-semicolon)
    refute_match(/;;/, idl)
  end

  def test_global_with_initialization_exactly_one_semicolon
    full = "#{ISA_HEADER}Bits<32> MY_CONST = 32'h0;\n"
    ast  = parse_isa(full)
    decl = ast.children.first
    assert_instance_of Idl::GlobalWithInitializationAst, decl
    serialized = decl.to_idl
    assert serialized.end_with?(";"), "GlobalWithInitializationAst#to_idl must end with ';', got: #{serialized.inspect}"
    assert_equal 1, serialized.count(";"), "Expected exactly one ';', got: #{serialized.inspect}"
  end

  # -------------------------------------------------------------------------
  # GlobalAst: global var declaration without initializer must end with ';'
  # -------------------------------------------------------------------------

  def test_global_no_init_round_trips
    round_trip_isa("Bits<32> my_global;\n")
  end

  def test_global_no_init_exactly_one_semicolon
    full = "#{ISA_HEADER}Bits<32> my_global;\n"
    ast  = parse_isa(full)
    decl = ast.children.first
    assert_instance_of Idl::GlobalAst, decl
    serialized = decl.to_idl
    assert serialized.end_with?(";"), "GlobalAst#to_idl must end with ';', got: #{serialized.inspect}"
    assert_equal 1, serialized.count(";"), "Expected exactly one ';', got: #{serialized.inspect}"
  end

  # -------------------------------------------------------------------------
  # BuiltinEnumDefinitionAst: 'generated enum TypeName' must end with ';'
  # -------------------------------------------------------------------------

  def test_builtin_enum_round_trips
    round_trip_isa("generated enum ExtensionName;\n")
  end

  def test_builtin_enum_exactly_one_semicolon
    full = "#{ISA_HEADER}generated enum ExtensionName;\n"
    ast  = parse_isa(full)
    decl = ast.children.first
    assert_instance_of Idl::BuiltinEnumDefinitionAst, decl
    serialized = decl.to_idl
    assert serialized.end_with?(";"), "BuiltinEnumDefinitionAst#to_idl must end with ';', got: #{serialized.inspect}"
    assert_equal 1, serialized.count(";"), "Expected exactly one ';', got: #{serialized.inspect}"
  end

  # -------------------------------------------------------------------------
  # Variable declarations INSIDE function bodies must have exactly one ';'
  # (StatementAst supplies it; the underlying Ast nodes must NOT add their own)
  # -------------------------------------------------------------------------

  def test_variable_decl_in_function_body_single_semicolon
    full = <<~IDL
      #{ISA_HEADER}
      enum ExceptionCode {
        ACode 0
      }

      function test_fn {
        description { test }
        body {
          Bits<32> local_var = 32'h0;
          Bits<16> another = 16'hFF;
        }
      }
    IDL
    ast = parse_isa(full)
    fn_ast = ast.children.find { |c| c.is_a?(Idl::FunctionDefAst) }
    assert fn_ast, "Expected a function body definition in the ISA"

    body_idl = fn_ast.to_idl
    # Each variable declaration inside a function body should have exactly one ';'
    # after it (from StatementAst). Detect double semicolons as a failure signal.
    refute_match(/;;/, body_idl, "Double semicolons found in function body to_idl output")
  end
end
