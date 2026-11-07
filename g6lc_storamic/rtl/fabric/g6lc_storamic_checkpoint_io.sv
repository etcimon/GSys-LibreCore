// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Private word sequencer for the checkpoint engine's existing RAM/store seams.
// Offers and accepted responses retain ownership through abort at the caller.
module g6lc_storamic_checkpoint_io #(
  parameter logic [7:0] Source = 8'hFE,
  parameter int unsigned SeqWidth = 32,
  parameter int unsigned EpochWidth = 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [31:0] reset_generation_i,
  input logic command_i,
  output logic ready_o,
  input logic ram_i,
  input logic flush_i,
  input logic write_i,
  input logic [63:0] addr_i, data_i,
  output logic response_o,
  input logic response_ready_i,
  output logic [63:0] data_o,
  output logic error_o,
  output logic exhausted_o,
  output logic stale_event_o,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o, mem_wdata_o,
  output logic [7:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o, st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_error_i,
  output logic st_flush_req_o,
  input logic st_flush_ack_i, st_flush_error_i
);
  import g6lc_storamic_pkg::*;
  localparam int unsigned CW = SeqWidth + EpochWidth;
  typedef enum logic [2:0] {IIdle, IRamOffer, IRamWait, IStoreOffer, IStoreWait,
                            IFlush, IResponse} state_e;
  state_e state_q;
  logic write_q, error_q, exhausted_q;
  logic [63:0] addr_q, data_q, response_q;
  logic [31:0] namespace_q;
  logic [CW-1:0] count_q;
  txn_id_t tag_q;
  logic renew, bad_namespace;
  assign renew = reset_generation_i > namespace_q;
  assign bad_namespace = reset_generation_i < namespace_q;
  assign ready_o = state_q == IIdle;
  assign response_o = state_q == IResponse;
  assign data_o = response_q;
  assign error_o = error_q;
  assign exhausted_o = bad_namespace || (exhausted_q && !renew);
  assign mem_req_o = state_q == IRamOffer;
  assign mem_we_o = write_q;
  assign mem_addr_o = addr_q;
  assign mem_wdata_o = data_q;
  assign mem_be_o = '1;
  assign mem_tag_o = tag_q;
  assign st_req_o = state_q == IStoreOffer;
  assign st_we_o = write_q;
  assign st_addr_o = addr_q;
  assign st_wdata_o = data_q;
  assign st_be_o = '1;
  assign st_flush_req_o = state_q == IFlush;

  // pragma translate_off
  initial begin
    if (SeqWidth == 0 || SeqWidth > 32 || EpochWidth == 0 || EpochWidth > 8)
      $fatal(1, "STORAMIC_CHECKPOINT_IO_PARAM");
  end
  // pragma translate_on
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IIdle;
      write_q <= 0; error_q <= 0; exhausted_q <= 0;
      addr_q <= 0; data_q <= 0; response_q <= 0;
      namespace_q <= 0; count_q <= 0; tag_q <= '0; stale_event_o <= 0;
    end else begin
      stale_event_o <= 0;
      case (state_q)
        IIdle: begin
          if (renew) begin
            namespace_q <= reset_generation_i; count_q <= 0; exhausted_q <= 0;
          end
          if (command_i) begin
            write_q <= write_i; addr_q <= addr_i; data_q <= data_i;
            error_q <= 0; response_q <= 0;
            if ((ram_i && flush_i) ||
                (ram_i && (bad_namespace || (exhausted_q && !renew)))) begin
              error_q <= 1; state_q <= IResponse;
            end else if (ram_i) begin
              tag_q <= '0;
              tag_q.reset_generation <= reset_generation_i;
              tag_q.source <= Source;
              tag_q.axi_id <= 16'hFFFF;
              tag_q.seq <= renew ? '0 : 32'(count_q[SeqWidth-1:0]);
              tag_q.epoch <= renew ? '0 : 8'(count_q[CW-1:SeqWidth]);
              if (renew) count_q <= CW'(1);
              else if (&count_q) exhausted_q <= 1;
              else count_q <= count_q + 1'b1;
              state_q <= IRamOffer;
            end else state_q <= flush_i ? IFlush : IStoreOffer;
          end
        end
        IRamOffer: if (mem_gnt_i) state_q <= IRamWait;
        IRamWait: if (mem_rvalid_i) begin
          if (mem_tag_i == tag_q) begin
            response_q <= mem_error_i ? 64'd0 : mem_rdata_i;
            error_q <= mem_error_i; state_q <= IResponse;
          end else stale_event_o <= 1;
        end
        IStoreOffer: if (st_gnt_i) state_q <= IStoreWait;
        IStoreWait: if (st_rvalid_i) begin
          response_q <= st_error_i ? 64'd0 : st_rdata_i;
          error_q <= st_error_i; state_q <= IResponse;
        end
        IFlush: if (st_flush_ack_i) begin
          error_q <= st_flush_error_i; state_q <= IResponse;
        end
        IResponse: if (response_ready_i) state_q <= IIdle;
        default: begin error_q <= 1; state_q <= IResponse; end
      endcase
    end
  end
endmodule
