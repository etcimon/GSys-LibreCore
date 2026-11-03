// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Explicit simulation fixture. Never include this array in production RTL lists.
// Completion, including write commit, can be delayed or faulted by the bench.
module g6lc_storamic_sram_model #(
  parameter int unsigned DataWidth = 64,
  parameter int unsigned Capacity = 8192,
  parameter int unsigned Latency = 3
) (
  input logic clk_i,
  input logic rst_ni,
  input logic available_i,
  input logic grant_enable_i,
  input logic reply_enable_i,
  input logic error_i,
  output logic ready_o,
  input logic req_i,
  output logic gnt_o,
  input logic we_i,
  input logic [63:0] addr_i,
  input logic [DataWidth-1:0] data_i,
  input logic [DataWidth/8-1:0] be_i,
  input g6lc_storamic_pkg::txn_id_t tag_i,
  output logic rvalid_o,
  output logic [DataWidth-1:0] data_o,
  output logic error_o,
  output g6lc_storamic_pkg::txn_id_t tag_o
);
  localparam int unsigned Bytes = DataWidth / 8;
  byte unsigned ram [Capacity];
  logic pending, write_q, error_q;
  logic [63:0] addr_q;
  logic [DataWidth-1:0] data_q;
  logic [Bytes-1:0] be_q;
  g6lc_storamic_pkg::txn_id_t tag_q;
  int unsigned delay_q;

  initial begin
    if (Capacity < Bytes || Latency < 1)
      $fatal(1, "STORAMIC_FIXTURE_GEOMETRY");
    for (int i = 0; i < Capacity; i++)
      ram[i] = 8'((i * 13) ^ (i >> 8) ^ 'h5a);
  end
  assign ready_o = rst_ni && available_i;
  assign gnt_o = ready_o && grant_enable_i && !pending;

  // The behavioral array retains contents across controller reset.
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending <= 0;
      write_q <= 0;
      error_q <= 0;
      addr_q <= 0;
      data_q <= 0;
      be_q <= 0;
      tag_q <= '0;
      delay_q <= 0;
      rvalid_o <= 0;
      data_o <= 0;
      error_o <= 0;
      tag_o <= '0;
    end else begin
      rvalid_o <= 0;
      if (req_i && gnt_o) begin
        pending <= 1;
        write_q <= we_i;
        addr_q <= addr_i;
        data_q <= data_i;
        be_q <= be_i;
        tag_q <= tag_i;
        // Full-width comparison before indexing; no truncation into the array.
        error_q <= error_i || addr_i > 64'(Capacity - Bytes) ||
                   (addr_i % Bytes) != 0;
        delay_q <= Latency - 1;
      end
      if (pending) begin
        if (delay_q != 0) delay_q <= delay_q - 1;
        else if (reply_enable_i) begin
          pending <= 0;
          rvalid_o <= 1;
          error_o <= error_q;
          tag_o <= tag_q;
          data_o <= '0;
          if (!error_q) begin
            for (int lane = 0; lane < Bytes; lane++) begin
              if (write_q) begin
                if (be_q[lane]) ram[int'(addr_q) + lane] = data_q[8*lane +: 8];
              end else data_o[8*lane +: 8] <= ram[int'(addr_q) + lane];
            end
          end
        end
      end
    end
  end
endmodule
