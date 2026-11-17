# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# typed: false
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "idlc/formatter"

# The reflow pass (tools/node/idl-reflow) run directly, stdin to stdout: Formatter.format
# falls back to its input on any failure, which would hide a broken reflow from these tests.
class TestFormatterReflow < Minitest::Test
  def reflow(source, width = 100)
    out, err, status = Open3.capture3(Idl::Formatter::NODE_BIN, Idl::Formatter::REFLOW_JS,
                                      width.to_s, stdin_data: source)
    assert status.success?, "idl-reflow failed: #{err}"
    out
  end

  # A description is AsciiDoc prose, not IDL: the reflow must not break it at the
  # "operators" and commas it happens to contain. A block title (a line starting with ".") is
  # one line in AsciiDoc, and the reflow used to split a long one at the "&" of a character
  # reference (creg2reg's ".Registers specified by the three-bit _rs1_&#x2032;, ..."), leaving
  # "_rs1_&" as the title and "#x2032;, ..." as a stray paragraph.
  def test_a_long_description_line_is_left_whole
    title = ".Registers specified by the three-bit _rs1_&#x2032;, _rs2_&#x2032;, and _rd_&#x2032; " \
            "fields of the CIW, CL, CS, CA, and CB formats."
    source = <<~IDL
      function f {
        returns Bits<8>
        description {
          #{title}
          A second line, also longer than the width, with commas, a + b, x || y, p && q, and more besides.
        }
        body {
          return 0;
        }
      }
    IDL

    assert_equal source, reflow(source)
  end

  # Only descriptions are exempt: a long code line, including one after a description, still
  # breaks.
  def test_a_long_code_line_after_a_description_still_breaks
    cond = (1..6).map { |i| "(a_long_variable_name_#{i} == 1)" }.join(" && ")
    source = <<~IDL
      function f {
        returns Boolean
        description {
          Short.
        }
        body {
          return #{cond};
        }
      }
    IDL

    out = reflow(source)

    assert out.lines.all? { |l| l.chomp.length <= 100 }, out
    assert_equal source.delete(" \n"), out.delete(" \n")
  end
end
