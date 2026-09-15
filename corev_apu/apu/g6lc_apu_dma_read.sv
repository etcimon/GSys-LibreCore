// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_apu_dma_read
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic enable_i,
  input logic cancel_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input apu_dma_read_req_t req_i,
  input apu_dma_mapping_t mapping_i,
  output logic data_valid_o,
  input logic data_ready_i,
  output apu_dma_read_data_t data_o,
  output logic cpl_valid_o,
  input logic cpl_ready_i,
  output apu_dma_read_cpl_t cpl_o,
  output logic idle_o,
  output logic bus_fault_o,
  output axi_req_t axi_req_o,
  input axi_rsp_t axi_rsp_i
);
  `ifndef SYNTHESIS
  initial begin
    assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU DMA: invalid configuration");
    assert ($bits(axi_req_o.ar.addr) == 64 && $bits(axi_rsp_i.r.data) == 64)
      else $fatal(1, "APU DMA: requires 64-bit AXI address and data");
  end
  `endif

  if (!ApuCfg.Enable || !ApuCfg.DmaReadEn) begin : gen_off
    assign req_ready_o = 1'b0;
    assign data_valid_o = 1'b0;
    assign data_o = '0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign idle_o = 1'b1;
    assign bus_fault_o = 1'b0;
    assign axi_req_o = '0;
  end else begin : gen_on
    typedef enum logic [2:0] {Idle, Check, Plan, Address, Read, Finish, Done, Halted} state_e;
    state_e state_q;
    apu_dma_read_req_t req_q;
    apu_dma_mapping_t mapping_q;
    apu_dma_status_e status_q, check_status;
    logic [63:0] cursor_q;
    logic [31:0] remaining_q, delivered_q;
    logic [8:0] beats_q;
    logic [7:0] ar_len_q;
    logic [2:0] ar_size_q;
    logic [3:0] step_q;
    logic data_valid_q, fault_q, kill;
    logic [3:0] data_bytes_q;
    apu_dma_read_data_t data_q;
    logic [31:0] plan_beats;
    logic [2:0] plan_size;
    logic [3:0] plan_step;
    logic [12:0] page_bytes;
    logic r_fire, r_bad_frame, r_bad_resp;

    assign kill = cancel_i || !enable_i;
    assign req_ready_o = state_q == Idle && !kill && !axi_rsp_i.r_valid && rst_ni;
    assign idle_o = state_q == Idle && !axi_rsp_i.r_valid;
    assign bus_fault_o = fault_q;
    assign data_valid_o = data_valid_q;
    assign data_o = data_valid_q ? data_q : apu_dma_read_data_t'('0);
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? apu_dma_read_cpl_t'{status: status_q,
      resource_id: req_q.resource_id, context_id: req_q.context_id, epoch: req_q.epoch,
      bytes: delivered_q, tag: req_q.tag} : apu_dma_read_cpl_t'('0);
    assign check_status = apu_dma_read_check(ApuCfg, mapping_q, req_q);
    assign page_bytes = 13'd4096 - {1'b0, cursor_q[11:0]};
    assign r_fire = axi_rsp_i.r_valid && axi_req_o.r_ready && state_q == Read;
    assign r_bad_frame = axi_rsp_i.r.id != 0 || axi_rsp_i.r.last != (beats_q == 1);
    assign r_bad_resp = axi_rsp_i.r.resp != axi_pkg::RESP_OKAY;

    always_comb begin
      plan_beats = 1;
      plan_size = 0;
      plan_step = 1;
      if (cursor_q[2:0] == 0 && remaining_q >= 8) begin
        plan_size = 3;
        plan_step = 8;
        plan_beats = remaining_q >> 3;
        if (plan_beats > ApuCfg.DmaReadBurstBeats) plan_beats = ApuCfg.DmaReadBurstBeats;
        if (plan_beats > (32'(page_bytes) >> 3)) plan_beats = 32'(page_bytes) >> 3;
      end else if (cursor_q[1:0] == 0 && remaining_q >= 4) begin
        plan_size = 2;
        plan_step = 4;
      end else if (cursor_q[0] == 0 && remaining_q >= 2) begin
        plan_size = 1;
        plan_step = 2;
      end
    end

    always_comb begin
      axi_req_o = '0;
      if (state_q == Address) begin
        axi_req_o.ar_valid = 1'b1;
        axi_req_o.ar.addr = cursor_q;
        axi_req_o.ar.len = ar_len_q;
        axi_req_o.ar.size = ar_size_q;
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
      end
      if (state_q == Read)
        axi_req_o.r_ready = status_q != APU_DMA_OK || kill || !data_valid_q || data_ready_i;
      if (fault_q) axi_req_o.r_ready = 1'b1;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        req_q <= '0;
        mapping_q <= '0;
        status_q <= APU_DMA_OK;
        cursor_q <= '0;
        remaining_q <= '0;
        delivered_q <= '0;
        beats_q <= '0;
        ar_len_q <= '0;
        ar_size_q <= '0;
        step_q <= '0;
        data_valid_q <= 1'b0;
        data_q <= '0;
        data_bytes_q <= '0;
        fault_q <= 1'b0;
      end else begin
        if (data_valid_q && data_ready_i) begin
          data_valid_q <= 1'b0;
          delivered_q <= delivered_q + 32'(data_bytes_q);
        end
        if (kill && status_q == APU_DMA_OK && state_q != Idle &&
            state_q != Done && state_q != Halted) status_q <= APU_DMA_CANCELLED;
        unique case (state_q)
          Idle: begin
            if (axi_rsp_i.r_valid) begin
              fault_q <= 1'b1;
              state_q <= Halted;
            end else if (req_valid_i && req_ready_o) begin
              req_q <= req_i;
              mapping_q <= mapping_i;
              delivered_q <= '0;
              status_q <= APU_DMA_OK;
              state_q <= Check;
            end
          end
          Check: begin
            if (kill) state_q <= Finish;
            else if (check_status != APU_DMA_OK) begin
              status_q <= check_status;
              state_q <= Finish;
            end else begin
              cursor_q <= mapping_q.base + req_q.offset;
              remaining_q <= req_q.bytes;
              state_q <= Plan;
            end
            if (axi_rsp_i.r_valid) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1'b1;
              state_q <= Finish;
            end
          end
          Plan: begin
            if (kill || status_q != APU_DMA_OK) state_q <= Finish;
            else begin
              ar_len_q <= 8'(plan_beats - 1);
              ar_size_q <= plan_size;
              step_q <= plan_step;
              beats_q <= 9'(plan_beats);
              state_q <= Address;
            end
            if (axi_rsp_i.r_valid) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1'b1;
              state_q <= Finish;
            end
          end
          Address: begin
            if (axi_rsp_i.ar_ready) state_q <= Read;
            if (axi_rsp_i.r_valid && !axi_rsp_i.ar_ready) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1'b1;
            end
          end
          Read: if (r_fire) begin
            if (r_bad_frame) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1'b1;
              state_q <= Finish;
            end else begin
              cursor_q <= cursor_q + 64'(step_q);
              remaining_q <= remaining_q - 32'(step_q);
              beats_q <= beats_q - 9'd1;
              if (r_bad_resp && status_q == APU_DMA_OK) status_q <= APU_DMA_BUS_ERROR;
              if (!kill && status_q == APU_DMA_OK && !r_bad_resp) begin
                data_q.data <= (axi_rsp_i.r.data >> (32'(cursor_q[2:0]) * 8)) &
                               (64'hffff_ffff_ffff_ffff >> ((8 - 32'(step_q)) * 8));
                data_q.keep <= 8'hff >> (8 - 32'(step_q));
                data_q.offset <= req_q.bytes - remaining_q;
                data_q.last <= remaining_q == 32'(step_q);
                data_bytes_q <= step_q;
                data_valid_q <= 1'b1;
              end
              if (beats_q == 1) begin
                if (kill || status_q != APU_DMA_OK || r_bad_resp || remaining_q == 32'(step_q))
                  state_q <= Finish;
                else state_q <= Plan;
              end
            end
          end
          Finish: if (!data_valid_q || data_ready_i) state_q <= Done;
          Done: if (cpl_ready_i) state_q <= fault_q ? Halted : Idle;
          Halted: ;
          default: state_q <= Halted;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      axi_req_o.ar_valid && !axi_rsp_i.ar_ready |=> axi_req_o.ar_valid && $stable(axi_req_o.ar));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      data_valid_o && !data_ready_i |=> data_valid_o && $stable(data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_DMA_OK |-> cpl_o.bytes == req_q.bytes && !fault_q);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fault_q |-> !idle_o && !req_ready_o);
    `endif
  end
  logic unused_testmode;
  assign unused_testmode = testmode_i;
endmodule
