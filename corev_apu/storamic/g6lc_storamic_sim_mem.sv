// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-011B simulation binding for the Storamic model profile: backs the
// g6lc_storamic_axi_memory `mem_*` command seam with the same pulp `sram`
// module the gen_sim_axi backend uses, so the storage sits behind tc_sram.
// This is a simulation binding only — not a qualified memory controller, and
// no persistence or physical-media claim.
//
// The seam is one command outstanding: mem_gnt_o accepts a command while
// idle, and the read data or write completion arrives one cycle after grant
// with the tag echoed. mem_addr_i is the base-relative byte offset within
// the model window produced by the frontend (addr - ModelBase). An address
// beyond ModelBytes, or one not aligned to the data width, completes with
// mem_error_o and never touches the array (defensive; the frontend's own
// window check normally prevents it).
module g6lc_storamic_sim_mem #(
  parameter int unsigned DataWidth = 64,
  parameter int unsigned NumWords = 8192,
  parameter logic [63:0] ModelBytes = 64'h0
) (
  input logic clk_i,
  input logic rst_ni,
  output logic mem_ready_o,
  input logic mem_req_i,
  output logic mem_gnt_o,
  input logic mem_we_i,
  input logic [63:0] mem_addr_i,
  input logic [DataWidth-1:0] mem_wdata_i,
  input logic [DataWidth/8-1:0] mem_be_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic mem_rvalid_o,
  output logic [DataWidth-1:0] mem_rdata_o,
  output logic mem_error_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o
);

  localparam int unsigned ByteW = $clog2(DataWidth / 8);

  logic rsp_q;                        // completion due this cycle
  logic err_q;
  g6lc_storamic_pkg::txn_id_t tag_q;
  logic cmd_ok;
  logic sram_req, sram_we;
  logic [DataWidth-1:0] sram_rdata;

  assign mem_ready_o = 1'b1;
  assign cmd_ok = ({1'b0, mem_addr_i} < {1'b0, ModelBytes}) &&
                  ((mem_addr_i & ((64'd1 << ByteW) - 64'd1)) == 0);
  // One command outstanding: grant whenever the seam offers a command and no
  // response is pending.
  assign mem_gnt_o = mem_req_i && !rsp_q;
  assign sram_req = mem_req_i && mem_gnt_o && cmd_ok;
  assign sram_we = mem_we_i;

  assign mem_rvalid_o = rsp_q;
  assign mem_rdata_o = sram_rdata;
  assign mem_error_o = err_q;
  assign mem_tag_o = tag_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_q <= 1'b0;
      err_q <= 1'b0;
      tag_q <= '0;
    end else begin
      rsp_q <= mem_req_i && mem_gnt_o;
      if (mem_req_i && mem_gnt_o) begin
        err_q <= !cmd_ok;
        tag_q <= mem_tag_i;
      end
    end
  end

  sram #(
      .DATA_WIDTH ( DataWidth ),
      .USER_WIDTH ( 1         ),
      .USER_EN    ( 0         ),
`ifdef VERILATOR
      .SIM_INIT   ( "none"    ),
`else
      .SIM_INIT   ( "zeros"   ),
`endif
      .NUM_WORDS  ( NumWords  )
  ) i_sram (
      .clk_i   ( clk_i   ),
      .rst_ni  ( rst_ni  ),
      .req_i   ( sram_req ),
      .we_i    ( sram_we  ),
      .addr_i  ( mem_addr_i[ByteW+$clog2(NumWords)-1:ByteW] ),
      .wuser_i ( 1'b0    ),
      .wdata_i ( mem_wdata_i ),
      .be_i    ( mem_be_i ),
      .ruser_o (         ),
      .rdata_o ( sram_rdata )
  );
endmodule
