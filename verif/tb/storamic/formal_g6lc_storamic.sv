// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module formal_g6lc_storamic (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axi_req_t req_i
);
  g6lc_storamic_pkg::axi_resp_t resp, previous_resp;
  g6lc_storamic_pkg::axi_req_t previous_req;
  logic past_valid;
  g6lc_storamic_axi_refuse dut (.clk_i, .rst_ni, .req_i, .resp_o(resp));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      past_valid <= 1'b0;
      previous_req <= '0;
      previous_resp <= '0;
    end else begin
      past_valid <= 1'b1;
      previous_req <= req_i;
      previous_resp <= resp;
      if (past_valid) begin
        if (previous_resp.r_valid && !previous_req.r_ready) begin
          assert (resp.r_valid);
          assert (resp.r == previous_resp.r);
        end
        if (previous_resp.b_valid && !previous_req.b_ready) begin
          assert (resp.b_valid);
          assert (resp.b == previous_resp.b);
        end
      end
      if (resp.r_valid) assert (resp.r.resp == 2'b10 && resp.r.data == 0);
      if (resp.b_valid) assert (resp.b.resp == 2'b10);
    end
  end
endmodule
