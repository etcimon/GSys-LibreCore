// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_apu_dma_write
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input logic clk_i, rst_ni, testmode_i,
  input logic enable_i, cancel_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input apu_dma_write_req_t req_i,
  input apu_dma_mapping_t mapping_i,
  input logic data_valid_i,
  output logic data_ready_o,
  input apu_dma_write_data_t data_i,
  output logic cpl_valid_o,
  input logic cpl_ready_i,
  output apu_dma_write_cpl_t cpl_o,
  output logic idle_o, bus_fault_o,
  output axi_req_t axi_req_o,
  input axi_rsp_t axi_rsp_i
);
  `ifndef SYNTHESIS
  initial begin
    assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU DMA write: invalid configuration");
    assert ($bits(axi_req_o.aw.addr) == 64 && $bits(axi_req_o.w.data) == 64)
      else $fatal(1, "APU DMA write: requires 64-bit AXI address and data");
  end
  `endif

  if (!ApuCfg.Enable || !ApuCfg.DmaWriteEn) begin : gen_off
    assign req_ready_o = 1'b0;
    assign data_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign idle_o = 1'b1;
    assign bus_fault_o = 1'b0;
    assign axi_req_o = '0;
  end else begin : gen_on
    typedef enum logic [2:0] {Idle, Check, Load, Plan, Issue, Response, Done, Halted} state_e;
    state_e state_q;
    apu_dma_write_req_t req_q;
    apu_dma_mapping_t mapping_q;
    apu_dma_status_e status_q, check_status;
    logic [63:0] cursor_q, packet_q, wdata_q;
    logic [31:0] received_q, sent_q;
    logic [3:0] packet_bytes_q, step_q, input_bytes, plan_step;
    logic [2:0] size_q, plan_size;
    logic [7:0] wstrb_q;
    logic aw_pending_q, w_pending_q, fault_q, kill, input_bad;
    logic aw_done, w_done;

    assign kill = cancel_i || !enable_i;
    assign req_ready_o = state_q == Idle && !kill && !axi_rsp_i.b_valid && rst_ni;
    assign idle_o = state_q == Idle && !axi_rsp_i.b_valid;
    assign bus_fault_o = fault_q;
    assign data_ready_o = state_q == Load && !kill && !axi_rsp_i.b_valid;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? apu_dma_write_cpl_t'{status: status_q,
      resource_id: req_q.resource_id, context_id: req_q.context_id, epoch: req_q.epoch,
      bytes: sent_q, tag: req_q.tag} : apu_dma_write_cpl_t'('0);
    assign check_status = apu_dma_write_check(ApuCfg, mapping_q, req_q);
    assign input_bytes = 4'($countones(data_i.keep));
    assign input_bad = input_bytes == 0 || data_i.keep != (8'hff >> (8 - 32'(input_bytes))) ||
                       data_i.offset != received_q || 32'(input_bytes) > req_q.bytes - received_q ||
                       data_i.last != (received_q + 32'(input_bytes) == req_q.bytes);
    assign aw_done = !aw_pending_q || axi_rsp_i.aw_ready;
    assign w_done = !w_pending_q || axi_rsp_i.w_ready;

    always_comb begin
      plan_size = 0;
      plan_step = 1;
      if (cursor_q[2:0] == 0 && packet_bytes_q >= 8) begin
        plan_size = 3;
        plan_step = 8;
      end else if (cursor_q[1:0] == 0 && packet_bytes_q >= 4) begin
        plan_size = 2;
        plan_step = 4;
      end else if (cursor_q[0] == 0 && packet_bytes_q >= 2) begin
        plan_size = 1;
        plan_step = 2;
      end
    end

    always_comb begin
      axi_req_o = '0;
      if (state_q == Issue) begin
        axi_req_o.aw_valid = aw_pending_q;
        axi_req_o.aw.id = 1;
        axi_req_o.aw.addr = cursor_q;
        axi_req_o.aw.size = size_q;
        axi_req_o.aw.burst = axi_pkg::BURST_INCR;
        axi_req_o.w_valid = w_pending_q;
        axi_req_o.w.data = wdata_q;
        axi_req_o.w.strb = wstrb_q;
        axi_req_o.w.last = 1;
      end
      axi_req_o.b_ready = state_q == Response || (fault_q && state_q != Issue);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        req_q <= '0;
        mapping_q <= '0;
        status_q <= APU_DMA_OK;
        cursor_q <= '0;
        packet_q <= '0;
        wdata_q <= '0;
        wstrb_q <= '0;
        received_q <= '0;
        sent_q <= '0;
        packet_bytes_q <= '0;
        step_q <= '0;
        size_q <= '0;
        aw_pending_q <= 0;
        w_pending_q <= 0;
        fault_q <= 0;
      end else begin
        if (kill && status_q == APU_DMA_OK && state_q != Idle &&
            state_q != Done && state_q != Halted) status_q <= APU_DMA_CANCELLED;
        unique case (state_q)
          Idle: begin
            if (axi_rsp_i.b_valid) begin
              fault_q <= 1;
              state_q <= Halted;
            end else if (req_valid_i && req_ready_o) begin
              req_q <= req_i;
              mapping_q <= mapping_i;
              received_q <= 0;
              sent_q <= 0;
              status_q <= APU_DMA_OK;
              state_q <= Check;
            end
          end
          Check: begin
            if (kill) state_q <= Done;
            else if (check_status != APU_DMA_OK) begin
              status_q <= check_status;
              state_q <= Done;
            end else begin
              cursor_q <= mapping_q.base + req_q.offset;
              state_q <= Load;
            end
          end
          Load: begin
            if (kill) state_q <= Done;
            else if (data_valid_i && data_ready_o) begin
              if (input_bad) begin
                status_q <= APU_DMA_STREAM;
                state_q <= Done;
              end else begin
                packet_q <= data_i.data;
                packet_bytes_q <= input_bytes;
                received_q <= received_q + 32'(input_bytes);
                state_q <= Plan;
              end
            end
          end
          Plan: begin
            if (kill) state_q <= Done;
            else begin
              step_q <= plan_step;
              size_q <= plan_size;
              wdata_q <= (packet_q & (64'hffff_ffff_ffff_ffff >> ((8 - 32'(plan_step)) * 8)))
                         << (32'(cursor_q[2:0]) * 8);
              wstrb_q <= (8'hff >> (8 - 32'(plan_step))) << cursor_q[2:0];
              aw_pending_q <= 1;
              w_pending_q <= 1;
              state_q <= Issue;
            end
          end
          Issue: begin
            if (aw_pending_q && axi_rsp_i.aw_ready) aw_pending_q <= 0;
            if (w_pending_q && axi_rsp_i.w_ready) begin
              w_pending_q <= 0;
              sent_q <= sent_q + 32'(step_q);
            end
            if (aw_done && w_done) state_q <= Response;
            if (axi_rsp_i.b_valid) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1;
            end
          end
          Response: if (axi_rsp_i.b_valid) begin
            if (fault_q || axi_rsp_i.b.id != 1) begin
              status_q <= APU_DMA_PROTOCOL;
              fault_q <= 1;
              state_q <= Done;
            end else if (axi_rsp_i.b.resp != axi_pkg::RESP_OKAY) begin
              status_q <= APU_DMA_BUS_ERROR;
              state_q <= Done;
            end else if (kill || status_q != APU_DMA_OK) state_q <= Done;
            else begin
              cursor_q <= cursor_q + 64'(step_q);
              packet_q <= packet_q >> (32'(step_q) * 8);
              packet_bytes_q <= packet_bytes_q - step_q;
              if (packet_bytes_q != step_q) state_q <= Plan;
              else if (received_q == req_q.bytes) state_q <= Done;
              else state_q <= Load;
            end
          end
          Done: if (cpl_ready_i) state_q <= fault_q ? Halted : Idle;
          Halted: ;
          default: state_q <= Halted;
        endcase
        if (axi_rsp_i.b_valid && (state_q == Check || state_q == Load || state_q == Plan)) begin
          status_q <= APU_DMA_PROTOCOL;
          fault_q <= 1;
          state_q <= Done;
        end
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      axi_req_o.aw_valid && !axi_rsp_i.aw_ready |=> axi_req_o.aw_valid && $stable(axi_req_o.aw));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      axi_req_o.w_valid && !axi_rsp_i.w_ready |=> axi_req_o.w_valid && $stable(axi_req_o.w));
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
