// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Virtio used-ring publisher. Writes virtq_used_elem then used.idx through the
// checked DMA writer. The idx store is the publication; a failed or cancelled
// idx leaves a possible unread element prefix that must not be treated as a
// completed used entry. Does not pulse the transport used_valid sideband.

module g6lc_apu_queue
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic enable_i,
  input  logic cancel_i,
  input  logic used_valid_i,
  output logic used_ready_o,
  input  apu_used_req_t used_i,
  output logic used_cpl_valid_o,
  input  logic used_cpl_ready_i,
  output apu_map_cpl_t used_cpl_o,
  output logic idle_o,
  output logic bus_fault_o,
  output axi_req_t axi_req_o,
  input  axi_rsp_t axi_rsp_i
);
  `ifndef SYNTHESIS
  initial begin
    assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU queue: invalid configuration");
    assert ($bits(axi_req_o.aw.addr) == 64 && $bits(axi_req_o.w.data) == 64)
      else $fatal(1, "APU queue: requires 64-bit AXI address and data");
  end
  `endif

  if (!ApuCfg.Enable || !ApuCfg.DmaWriteEn) begin : gen_off
    assign used_ready_o = 1'b0;
    assign used_cpl_valid_o = 1'b0;
    assign used_cpl_o = '0;
    assign idle_o = 1'b1;
    assign bus_fault_o = 1'b0;
    assign axi_req_o = '0;
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, Check, ElemReq, ElemData, ElemWait, IdxReq, IdxData, IdxWait, Done, Halted
    } state_e;
    state_e state_q;
    apu_used_req_t req_q;
    apu_dma_status_e status_q, check_status;
    apu_dma_write_req_t wr_req;
    apu_dma_write_data_t wr_data;
    apu_dma_write_cpl_t wr_cpl;
    logic wr_req_valid, wr_req_ready, wr_data_valid, wr_data_ready;
    logic wr_cpl_valid, wr_cpl_ready, wr_idle, wr_fault, kill;
    logic [15:0] next_idx;
    logic [63:0] ring_bytes, elem_off;

    assign kill = cancel_i || !enable_i;
    assign used_ready_o = state_q == Idle && !kill && wr_idle && rst_ni;
    assign idle_o = state_q == Idle && wr_idle && !wr_fault;
    assign bus_fault_o = wr_fault;
    assign used_cpl_valid_o = state_q == Done;
    assign used_cpl_o = used_cpl_valid_o ? apu_map_cpl_t'{
        status: status_q, slot: {16'h0, req_q.idx}, resource_id: req_q.desc_id,
        context_id: req_q.context_id, epoch: req_q.qid, bytes: req_q.len, tag: req_q.tag
      } : apu_map_cpl_t'('0);
    assign next_idx = req_q.idx + 16'd1;
    assign ring_bytes = apu_used_ring_bytes(req_q.queue_num);
    assign elem_off = req_q.offset + apu_used_elem_off(req_q.queue_num, req_q.idx);
    assign wr_req = '{
        resource_id: req_q.mapping.resource_id,
        context_id: req_q.mapping.context_id,
        epoch: req_q.mapping.epoch,
        offset: (state_q == IdxReq || state_q == IdxData || state_q == IdxWait)
                ? (req_q.offset + 64'd2) : elem_off,
        bytes: (state_q == IdxReq || state_q == IdxData || state_q == IdxWait) ? 32'd2 : 32'd8,
        tag: req_q.tag
      };
    always_comb begin
      wr_data = '0;
      if (state_q == IdxData) begin
        wr_data.data = {48'h0, next_idx};
        wr_data.keep = 8'h03;
        wr_data.last = 1'b1;
      end else begin
        wr_data.data = {req_q.len, req_q.desc_id};
        wr_data.keep = 8'hff;
        wr_data.last = 1'b1;
      end
    end
    assign wr_req_valid = state_q == ElemReq || state_q == IdxReq;
    assign wr_data_valid = state_q == ElemData || state_q == IdxData;
    assign wr_cpl_ready = state_q == ElemWait || state_q == IdxWait;

    always_comb begin
      check_status = APU_DMA_OK;
      if (!pow2(32'(req_q.queue_num)) || req_q.queue_num < 16'd8 ||
          32'(req_q.queue_num) > ApuCfg.QueueDepth) check_status = APU_DMA_LIMIT;
      else if (req_q.offset + ring_bytes < req_q.offset) check_status = APU_DMA_BOUNDS;
      else check_status = apu_dma_write_check(ApuCfg, req_q.mapping, '{
          resource_id: req_q.mapping.resource_id,
          context_id: req_q.mapping.context_id,
          epoch: req_q.mapping.epoch,
          offset: req_q.offset,
          bytes: 32'(ring_bytes),
          tag: req_q.tag
        });
    end

    g6lc_apu_dma_write #(.ApuCfg(ApuCfg), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)) i_write (
      .clk_i, .rst_ni, .testmode_i, .enable_i(1'b1), .cancel_i(kill),
      .req_valid_i(wr_req_valid), .req_ready_o(wr_req_ready), .req_i(wr_req),
      .mapping_i(req_q.mapping),
      .data_valid_i(wr_data_valid), .data_ready_o(wr_data_ready), .data_i(wr_data),
      .cpl_valid_o(wr_cpl_valid), .cpl_ready_i(wr_cpl_ready), .cpl_o(wr_cpl),
      .idle_o(wr_idle), .bus_fault_o(wr_fault), .axi_req_o, .axi_rsp_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        req_q <= '0;
        status_q <= APU_DMA_OK;
      end else begin
        if (kill && status_q == APU_DMA_OK && state_q != Idle &&
            state_q != Done && state_q != Halted)
          status_q <= APU_DMA_CANCELLED;
        unique case (state_q)
          Idle: if (used_valid_i && used_ready_o) begin
            req_q <= used_i;
            status_q <= APU_DMA_OK;
            state_q <= Check;
          end
          Check: begin
            if (kill) state_q <= Done;
            else if (check_status != APU_DMA_OK) begin
              status_q <= check_status;
              state_q <= Done;
            end else state_q <= ElemReq;
          end
          ElemReq: if (wr_req_ready) state_q <= ElemData;
          ElemData: if (wr_data_ready) state_q <= ElemWait;
          ElemWait: if (wr_cpl_valid) begin
            if (wr_cpl.status != APU_DMA_OK) begin
              status_q <= wr_cpl.status;
              state_q <= Done;
            end else if (kill) state_q <= Done;
            else state_q <= IdxReq;
          end
          IdxReq: if (wr_req_ready) state_q <= IdxData;
          IdxData: if (wr_data_ready) state_q <= IdxWait;
          IdxWait: if (wr_cpl_valid) begin
            if (wr_cpl.status != APU_DMA_OK) status_q <= wr_cpl.status;
            state_q <= Done;
          end
          Done: if (used_cpl_ready_i) state_q <= wr_fault ? Halted : Idle;
          Halted: ;
          default: state_q <= Halted;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      used_cpl_valid_o && !used_cpl_ready_i |=> used_cpl_valid_o && $stable(used_cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q != Idle |-> !used_ready_o);
    `endif
  end
endmodule
