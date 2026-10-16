// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Timing-study stand-in for `tc_sram` (vendor/pulp-platform/tech_cells_generic).
//
// `timings sta-rtl` substitutes this file for the behavioural model when it
// writes the study manifest (`--no-sram-stub` keeps the model). The real
// module is an SRAM *macro* seam: in silicon it is a hard macro with its own
// liberty timing, never flops. Yosys's `memory_map` turns the behavioural
// array into one flop per bit plus 1024:1 read-mux trees — 48 KiB of caches
// alone killed two whole-core mappings on a 128 GiB builder (OOM at 51 GiB
// flat, bad_alloc at 44 GiB hierarchical, both before STA).
//
// What this stub keeps: the macro *boundary* as registers, so every core path
// into the macro (addr/wdata/be/we/req) is a real setup check and every path
// out of it launches from a flop. What it does not model: the macro's access
// time (clk->q here is a flop's, a real SRAM is several times slower) and
// storage (rdata is a function of the previous cycle's request, not memory
// contents). It is a study netlist for the core logic, not a functional model
// and not sign-off — the macro side of these paths needs the macro's .lib.
module tc_sram #(
  parameter int unsigned NumWords     = 32'd1024,
  parameter int unsigned DataWidth    = 32'd128,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd2,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
  parameter bit          PrintSimCfg  = 1'b0,
  parameter              ImplKey      = "none",
  parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth   = (DataWidth + ByteWidth - 32'd1) / ByteWidth,
  parameter type         addr_t    = logic [AddrWidth-1:0],
  parameter type         data_t    = logic [DataWidth-1:0],
  parameter type         be_t      = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,
  output data_t [NumPorts-1:0] rdata_o
);
  // Byte-enable expanded to a data mask: keeps be_i on a timed path.
  function automatic data_t be_mask(input be_t be);
    data_t m;
    for (int unsigned b = 0; b < DataWidth; b++) m[b] = be[b / ByteWidth];
    return m;
  endfunction

  data_t [NumPorts-1:0] rdata_q;
  for (genvar p = 0; p < NumPorts; p++) begin : gen_port
    // Address folded onto the data width so addr_i is timed too; the stub
    // has no array, so the exact function is irrelevant beyond "not constant".
    data_t addr_fold;
    always_comb begin
      addr_fold = '0;
      for (int unsigned b = 0; b < DataWidth; b++) addr_fold[b] = addr_i[p][b % AddrWidth];
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) rdata_q[p] <= '0;
      else if (req_i[p]) rdata_q[p] <= we_i[p] ? (wdata_i[p] & be_mask(be_i[p])) : addr_fold;
    end
  end
  assign rdata_o = rdata_q;
endmodule
