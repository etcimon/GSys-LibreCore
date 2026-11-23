// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-037C labelled VOLATILE model block store for the native virtio-blk
// device (user-approved binding until qualified media exists, ST-018).
// It is SRAM behind the tc_sram macro seam: contents are lost on power loss
// and are NOT a persistence or durability claim. Capacity = NumWords * 8
// bytes; out-of-range accesses complete with an error and change nothing.
module g6lc_storamic_model_store #(
  parameter int unsigned NumWords = 8192          // 64 KiB = 128 sectors
) (
  input logic clk_i,
  input logic rst_ni,
  input logic st_req_i,
  output logic st_gnt_o,
  input logic st_we_i,
  input logic [63:0] st_addr_i,                   // byte offset, 8-aligned
  input logic [63:0] st_wdata_i,
  input logic [7:0] st_be_i,
  output logic st_rvalid_o,
  output logic [63:0] st_rdata_o,
  output logic st_err_o
);
  localparam int unsigned AW = $clog2(NumWords);
  logic in_range;
  assign in_range = st_addr_i[2:0] == 3'b000 && (st_addr_i >> 3) < 64'(NumWords);
  assign st_gnt_o = st_req_i;

  logic [63:0] rdata;
  tc_sram #(
    .NumWords(NumWords), .DataWidth(64), .ByteWidth(8), .NumPorts(1), .Latency(1)
  ) i_sram (
    .clk_i, .rst_ni,
    .req_i(st_req_i && in_range), .we_i(st_we_i),
    .addr_i(st_addr_i[AW+2:3]), .wdata_i(st_wdata_i), .be_i(st_be_i),
    .rdata_o(rdata)
  );

  logic err_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_rvalid_o <= 1'b0; err_q <= 1'b0;
    end else begin
      st_rvalid_o <= st_req_i;
      err_q <= st_req_i && !in_range;
    end
  end
  assign st_err_o = err_q;
  assign st_rdata_o = err_q ? '0 : rdata;
endmodule
