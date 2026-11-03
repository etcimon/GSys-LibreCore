// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_storamic_axi_refuse #(
  parameter type req_t = g6lc_storamic_pkg::axi_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axi_resp_t
) (
  input logic clk_i,
  input logic rst_ni,
  input req_t req_i,
  output resp_t resp_o
);
  logic [8:0] read_left_q, write_left_q;
  logic [$bits(req_i.ar.id)-1:0] read_id_q;
  logic [$bits(req_i.aw.id)-1:0] write_id_q;
  logic b_valid_q;

  always_comb begin
    resp_o = '0;
    resp_o.aw_ready = write_left_q == 0 && !b_valid_q;
    resp_o.w_ready = write_left_q != 0;
    resp_o.b.id = write_id_q;
    resp_o.b.resp = g6lc_storamic_pkg::RespSlvErr;
    resp_o.b_valid = b_valid_q;
    resp_o.ar_ready = read_left_q == 0;
    resp_o.r.id = read_id_q;
    resp_o.r.resp = g6lc_storamic_pkg::RespSlvErr;
    resp_o.r.last = read_left_q == 1;
    resp_o.r_valid = read_left_q != 0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_left_q <= '0;
      write_left_q <= '0;
      read_id_q <= '0;
      write_id_q <= '0;
      b_valid_q <= 1'b0;
    end else begin
      if (resp_o.ar_ready && req_i.ar_valid) begin
        read_left_q <= {1'b0, req_i.ar.len} + 9'd1;
        read_id_q <= req_i.ar.id;
      end else if (resp_o.r_valid && req_i.r_ready) begin
        read_left_q <= read_left_q - 9'd1;
      end
      if (resp_o.b_valid && req_i.b_ready) b_valid_q <= 1'b0;
      if (resp_o.aw_ready && req_i.aw_valid) begin
        write_left_q <= {1'b0, req_i.aw.len} + 9'd1;
        write_id_q <= req_i.aw.id;
      end else if (resp_o.w_ready && req_i.w_valid) begin
        write_left_q <= write_left_q - 9'd1;
        if (write_left_q == 1) b_valid_q <= 1'b1;
      end
    end
  end
endmodule
