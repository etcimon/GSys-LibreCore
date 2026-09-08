// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Golden for `ParseOptions::allow_parse_errors` (P16 monorepo readings).
//
// This fixture used to hold CVA6's `common/local/util/sram.sv` shape: bare named
// `begin` blocks at *generate* scope inside a `// synthesis translate_off` region.
// That is no longer a parse failure and must not be used as one --
// `parse::mask_translate_off` honours the pragma, so the non-synthesized region is
// blanked (offsets preserved) before parsing, and `sram.sv` analyses normally.
// Coverage for that path lives in `parse::tests::translate_off_*` and
// `sram_translate_off_block_parses_without_allow_parse_errors`.
//
// `allow_parse_errors` still needs a genuinely malformed file, so the error below is
// a real one outside any pragma region: an assignment with no right-hand expression.
//
// Expected: with `allow_parse_errors` the file lands in `ParsedUnit::skipped`
// and the rest of the file list still analyzes; without it, `parse_paths` errors.

module unparsable_mem #(
    parameter int unsigned NUM_WORDS = 4
) (
    input  logic       clk_i,
    input  logic [3:0] addr_i,
    output logic [7:0] rdata_o
);
  // A translate_off region is NOT the error here; it is masked and ignored.
  // synthesis translate_off
  begin : i_wrapper
    begin : i_inner
      initial $display("sim-only nesting at generate scope");
    end
  end
  // synthesis translate_on

  // The actual syntax error: no expression on the right-hand side.
  always_comb begin
    rdata_o = ;
  end
endmodule
