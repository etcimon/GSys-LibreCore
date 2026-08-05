// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Golden for `ParseOptions::allow_parse_errors` (P16 monorepo readings).
//
// Reduced from CVA6's own `common/local/util/sram.sv`, which aborted a 248-file
// monorepo analyze: a `// synthesis translate_off` region holding bare `begin`
// blocks at *generate* scope. Synthesis and simulators accept it; a strict IEEE
// grammar (the vendored sv-parser) does not.
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
  for (genvar k = 0; k < 1; k++) begin : gen_mem
    assign rdata_o = '0;
    // synthesis translate_off
    begin : i_wrapper
      begin : i_inner
        initial $display("sim-only nesting at generate scope");
      end
    end
    // synthesis translate_on
  end
endmodule
