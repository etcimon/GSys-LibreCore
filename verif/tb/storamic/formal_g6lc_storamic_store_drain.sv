// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Model staging ownership, not physical persistence or native provider binding.
module formal_g6lc_storamic_store_drain #(
  parameter bit OracleNegative = 0
) (
  input logic clk_i, rst_ni, cut_i, req_i, write_i, flush_i,
  input logic [63:0] addr_i, data_i,
  input logic [7:0] be_i
);
  logic idle, drained, grant, flush_ack, flush_error;
  logic dirty_q, flushed_q, flush_req_q;
  g6lc_storamic_durable_store #(
    .NumWords(4), .StageEntries(2), .CommitCycles(1)
  ) store (
    .clk_i, .rst_ni, .power_cut_i(cut_i), .idle_o(idle), .drained_o(drained),
    .st_req_i(req_i), .st_gnt_o(grant), .st_we_i(write_i),
    .st_addr_i(addr_i), .st_wdata_i(data_i), .st_be_i(be_i),
    .st_rvalid_o(), .st_rdata_o(), .st_err_o(), .st_flush_req_i(flush_req_q),
    .st_flush_ack_o(flush_ack), .st_flush_err_o(flush_error),
    .save_i(1'b0), .save_done_o(), .cut_count_o(), .commit_gen_o(),
    .journal_gen_o(), .journal_id_o(), .unlock_key_i(32'd0),
    .restore_i(1'b0), .restore_done_o()
  );
  // Independent interface history: no inspection of the store's staging count.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin dirty_q <= 0; flushed_q <= 0; flush_req_q <= 0; end
    else begin
      // flush_i offers work; this requester owns it through success/error ACK.
      if (flush_ack) flush_req_q <= 0;
      else if (flush_i) flush_req_q <= 1;
      if (cut_i) begin dirty_q <= 0; flushed_q <= 0; end
      if (flush_ack && !flush_error) begin
        dirty_q <= 0; flushed_q <= dirty_q;
      end
      if (req_i && grant && write_i && addr_i < 32 && addr_i[2:0] == 0 && |be_i) begin
        dirty_q <= 1; flushed_q <= 0;
      end
    end
  end
  always_ff @(posedge clk_i) if (rst_ni) begin
    if (cut_i) assert (!drained);
    if (drained) assert (idle);
    if (!cut_i && dirty_q && !flush_ack) begin
      assert (!drained);
      if (OracleNegative) assert (drained);
    end
    cover (!cut_i && dirty_q && idle && !drained);
    cover (!cut_i && dirty_q && flush_ack && !flush_error);
    cover (!cut_i && flushed_q && drained);
  end
endmodule
