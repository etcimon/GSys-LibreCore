// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness-shaped single-beat AXI4 (64-bit data) to AXI-Lite (32-bit data)
// bridge. Accepts aligned 32-bit accesses (len=0, size=2) and aligned 64-bit
// single-beat stores (len=0, size=3, addr[2:0]=0) which split into two 32-bit
// lite writes. CVA6 WT may pack two 32-bit MMIO stores into one beat.
// Default-off is a SLVERR error slave. A rejected burst accepts every
// AWLEN+1 or ARLEN+1 beat before its response. A split store keeps an
// earlier half's error when the later half succeeds. Not a general downsizer.

module g6lc_apu_axi4_lite
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b1,
  parameter type axi4_req_t = apu_dma_axi_req_t,
  parameter type axi4_rsp_t = apu_dma_axi_resp_t,
  parameter type lite_req_t = apu_axi_req_t,
  parameter type lite_rsp_t = apu_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  axi4_req_t slv_req_i,
  output axi4_rsp_t slv_rsp_o,
  output lite_req_t lite_req_o,
  input  lite_rsp_t lite_rsp_i,
  // Live admission epoch. Captured with AW/AR and held while the lite
  // request is presented, so a later epoch change cannot retag the beat.
  input  logic [31:0] epoch_i,
  output logic hold_o,
  output logic [31:0] admitted_o
);
  typedef enum logic [3:0] {
    Idle, WaitW, DrainW, IssueW, WaitWB, SendB, IssueR, WaitRR, SendR,
    ErrB, ErrR, Fault
  } state_e;

  // The second half of a split store must not replace an error already
  // recorded for the low half with OKAY.
  function automatic logic [1:0] agg_bresp(
    input logic [1:0] prev, next,
    input logic keep_err
  );
    if (keep_err && prev != axi_pkg::RESP_OKAY && next == axi_pkg::RESP_OKAY)
      return prev;
    return next;
  endfunction

  function automatic logic wr_ok(input axi4_req_t r);
    logic ok;
    ok = r.aw.len == '0 && r.aw.addr[1:0] == 2'b00;
    if (r.aw.size == 3'd2) return ok;
    // CVA6 WT may pack two 32-bit MMIO stores into one 64-bit beat.
    if (r.aw.size == 3'd3) return ok && r.aw.addr[2] == 1'b0;
    return 1'b0;
  endfunction
  function automatic logic rd_ok(input axi4_req_t r);
    return r.ar.len == '0 && r.ar.size == 3'd2 && r.ar.addr[1:0] == 2'b00;
  endfunction

  localparam int unsigned IdW = $bits(slv_req_i.aw.id);
  localparam int unsigned LenW = $bits(slv_req_i.aw.len);

  if (!Enable) begin : gen_off
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [LenW-1:0] beats_q;
    always_comb begin
      slv_rsp_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW, DrainW: slv_rsp_o.w_ready = 1'b1;
        ErrB, SendB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        ErrR: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = (beats_q == '0);
        end
        default: ;
      endcase
    end
    assign lite_req_o = '0;
    assign hold_o = 1'b0;
    assign admitted_o = '0;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0; beats_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            beats_q <= slv_req_i.aw.len;
            state_q <= DrainW;
            if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
              if (slv_req_i.w.last != (slv_req_i.aw.len == '0)) state_q <= Fault;
              else if (slv_req_i.aw.len == '0) state_q <= ErrB;
              else beats_q <= slv_req_i.aw.len - 1'b1;
            end
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            beats_q <= slv_req_i.ar.len;
            state_q <= ErrR;
          end
        end
        WaitW, DrainW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          if (slv_req_i.w.last != (beats_q == '0)) state_q <= Fault;
          else if (beats_q == '0) state_q <= ErrB;
          else beats_q <= beats_q - 1'b1;
        end
        ErrB, SendB: if (slv_req_i.b_ready) state_q <= Idle;
        ErrR: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1'b1;
        end
        default: ;
      endcase
    end
    logic unused;
    assign unused = testmode_i | |lite_rsp_i | (|epoch_i);
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q inside {WaitW, DrainW, Fault} |-> !slv_rsp_o.b_valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == ErrR && beats_q != '0 |-> slv_rsp_o.r_valid && !slv_rsp_o.r.last);
    `endif
  end else begin : gen_on
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [63:0] addr_q, wdata_q;
    logic [31:0] data_q;
    logic [7:0] wstrb_q;
    logic [3:0] strb_q;
    logic [1:0] resp_q;
    logic [LenW-1:0] beats_q;
    logic hi, aw_h, w_h, size3_q, half_q, low_done_q;
    logic [31:0] epoch_aw_q, epoch_ar_q;
    assign hi = addr_q[2];
    assign hold_o = (state_q == IssueW) || (state_q == IssueR);
    assign admitted_o = (state_q == IssueR) ? epoch_ar_q : epoch_aw_q;

    always_comb begin
      slv_rsp_o = '0;
      lite_req_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW, DrainW: slv_rsp_o.w_ready = 1'b1;
        IssueW: begin
          lite_req_o.aw.addr = (size3_q && half_q) ? (addr_q + 64'd4) : addr_q;
          lite_req_o.aw.prot = 3'b000;
          lite_req_o.w.data = size3_q ?
              (half_q ? wdata_q[63:32] : wdata_q[31:0]) : data_q;
          lite_req_o.w.strb = size3_q ?
              (half_q ? wstrb_q[7:4] : wstrb_q[3:0]) : strb_q;
          lite_req_o.aw_valid = !aw_h;
          lite_req_o.w_valid = !w_h;
          lite_req_o.b_ready = 1'b1;
        end
        WaitWB: begin
          lite_req_o.b_ready = 1'b1;
        end
        SendB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = resp_q;
        end
        IssueR: begin
          lite_req_o.ar.addr = addr_q;
          lite_req_o.ar.prot = 3'b000;
          lite_req_o.ar_valid = 1'b1;
        end
        WaitRR: lite_req_o.r_ready = 1'b1;
        SendR: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = resp_q;
          slv_rsp_o.r.last = 1'b1;
          slv_rsp_o.r.data = hi ? {data_q, 32'h0} : {32'h0, data_q};
        end
        ErrB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        ErrR: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = (beats_q == '0);
        end
        default: ;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0; addr_q <= '0; data_q <= '0; strb_q <= '0;
        wdata_q <= '0; wstrb_q <= '0; resp_q <= '0; beats_q <= '0;
        aw_h <= 1'b0; w_h <= 1'b0;
        size3_q <= 1'b0; half_q <= 1'b0; low_done_q <= 1'b0;
        epoch_aw_q <= '0; epoch_ar_q <= '0;
      end else unique case (state_q)
        Idle: begin
          aw_h <= 1'b0; w_h <= 1'b0; half_q <= 1'b0; low_done_q <= 1'b0;
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            addr_q <= slv_req_i.aw.addr;
            epoch_aw_q <= epoch_i;
            beats_q <= slv_req_i.aw.len;
            size3_q <= slv_req_i.aw.size == 3'd3;
            if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
              wdata_q <= slv_req_i.w.data;
              wstrb_q <= slv_req_i.w.strb;
              data_q <= slv_req_i.aw.addr[2] ? slv_req_i.w.data[63:32]
                                             : slv_req_i.w.data[31:0];
              strb_q <= slv_req_i.aw.addr[2] ? slv_req_i.w.strb[7:4]
                                             : slv_req_i.w.strb[3:0];
              half_q <= slv_req_i.aw.size == 3'd3 &&
                        slv_req_i.w.strb[3:0] == 4'h0 &&
                        slv_req_i.w.strb[7:4] != 4'h0;
              if (slv_req_i.w.last != (slv_req_i.aw.len == '0)) state_q <= Fault;
              else if (slv_req_i.aw.len != '0) begin
                beats_q <= slv_req_i.aw.len - 1'b1;
                state_q <= DrainW;
              end else state_q <= wr_ok(slv_req_i) ? IssueW : ErrB;
            end else state_q <= wr_ok(slv_req_i) ? WaitW : DrainW;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            addr_q <= slv_req_i.ar.addr;
            epoch_ar_q <= epoch_i;
            beats_q <= slv_req_i.ar.len;
            state_q <= rd_ok(slv_req_i) ? IssueR : ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          wdata_q <= slv_req_i.w.data;
          wstrb_q <= slv_req_i.w.strb;
          data_q <= addr_q[2] ? slv_req_i.w.data[63:32] : slv_req_i.w.data[31:0];
          strb_q <= addr_q[2] ? slv_req_i.w.strb[7:4] : slv_req_i.w.strb[3:0];
          half_q <= size3_q && slv_req_i.w.strb[3:0] == 4'h0 &&
                    slv_req_i.w.strb[7:4] != 4'h0;
          state_q <= slv_req_i.w.last ? IssueW : Fault;
        end
        DrainW: if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
          if (slv_req_i.w.last != (beats_q == '0)) state_q <= Fault;
          else if (beats_q == '0) state_q <= ErrB;
          else beats_q <= beats_q - 1'b1;
        end
        IssueW: begin
          if (lite_req_o.aw_valid && lite_rsp_i.aw_ready) aw_h <= 1'b1;
          if (lite_req_o.w_valid && lite_rsp_i.w_ready) w_h <= 1'b1;
          if ((aw_h || (lite_req_o.aw_valid && lite_rsp_i.aw_ready)) &&
              (w_h  || (lite_req_o.w_valid && lite_rsp_i.w_ready))) begin
            if (lite_rsp_i.b_valid) begin
              resp_q <= agg_bresp(resp_q, lite_rsp_i.b.resp, low_done_q);
              if (size3_q && !half_q && |wstrb_q[7:4]) begin
                half_q <= 1'b1; aw_h <= 1'b0; w_h <= 1'b0; low_done_q <= 1'b1;
              end else state_q <= SendB;
            end else state_q <= WaitWB;
          end
        end
        WaitWB: if (lite_rsp_i.b_valid && lite_req_o.b_ready) begin
          resp_q <= agg_bresp(resp_q, lite_rsp_i.b.resp, low_done_q);
          if (size3_q && !half_q && |wstrb_q[7:4]) begin
            half_q <= 1'b1; aw_h <= 1'b0; w_h <= 1'b0; low_done_q <= 1'b1;
            state_q <= IssueW;
          end else state_q <= SendB;
        end
        SendB: if (slv_req_i.b_ready) state_q <= Idle;
        IssueR: if (lite_req_o.ar_valid && lite_rsp_i.ar_ready) state_q <= WaitRR;
        WaitRR: if (lite_rsp_i.r_valid && lite_req_o.r_ready) begin
          data_q <= lite_rsp_i.r.data;
          resp_q <= lite_rsp_i.r.resp;
          state_q <= SendR;
        end
        SendR: if (slv_req_i.r_ready) state_q <= Idle;
        ErrB: if (slv_req_i.b_ready) state_q <= Idle;
        ErrR: if (slv_req_i.r_ready) begin
          if (beats_q == '0) state_q <= Idle;
          else beats_q <= beats_q - 1'b1;
        end
        default: ;
      endcase
    end
    logic unused_tm;
    assign unused_tm = testmode_i;
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q inside {WaitW, DrainW, Fault} |-> !slv_rsp_o.b_valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == ErrR && beats_q != '0 |-> slv_rsp_o.r_valid && !slv_rsp_o.r.last);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q inside {DrainW, ErrB, ErrR, Fault} |-> !lite_req_o.aw_valid &&
                                                     !lite_req_o.w_valid &&
                                                     !lite_req_o.ar_valid);
    `endif
  end
endmodule
