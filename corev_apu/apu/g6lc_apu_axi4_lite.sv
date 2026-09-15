// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness-shaped single-beat AXI4 (64-bit data) to AXI-Lite (32-bit data)
// bridge. Accepts aligned 32-bit accesses (len=0, size=2) and aligned 64-bit
// single-beat stores (len=0, size=3, addr[2:0]=0) which split into two 32-bit
// lite writes. CVA6 WT may pack two 32-bit MMIO stores into one beat.
// Default-off is a SLVERR error slave. Not a general downsizer.

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
  input  lite_rsp_t lite_rsp_i
);
  typedef enum logic [3:0] {
    Idle, WaitW, IssueW, WaitWB, SendB, IssueR, WaitRR, SendR, ErrB, ErrR
  } state_e;

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

  if (!Enable) begin : gen_off
    state_e state_q;
    logic [IdW-1:0] id_q;
    always_comb begin
      slv_rsp_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW: slv_rsp_o.w_ready = 1'b1;
        ErrB, SendB: begin
          slv_rsp_o.b_valid = 1'b1;
          slv_rsp_o.b.id = id_q;
          slv_rsp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        default: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = 1'b1;
        end
      endcase
    end
    assign lite_req_o = '0;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            state_q <= (slv_req_i.w_valid && slv_rsp_o.w_ready) ? ErrB : WaitW;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            state_q <= ErrR;
          end
        end
        WaitW: if (slv_req_i.w_valid) state_q <= ErrB;
        ErrB, SendB: if (slv_req_i.b_ready) state_q <= Idle;
        default: if (slv_req_i.r_ready) state_q <= Idle;
      endcase
    end
    logic unused;
    assign unused = testmode_i | |lite_rsp_i;
  end else begin : gen_on
    state_e state_q;
    logic [IdW-1:0] id_q;
    logic [63:0] addr_q, wdata_q;
    logic [31:0] data_q;
    logic [7:0] wstrb_q;
    logic [3:0] strb_q;
    logic [1:0] resp_q;
    logic hi, aw_h, w_h, size3_q, half_q;
    assign hi = addr_q[2];

    always_comb begin
      slv_rsp_o = '0;
      lite_req_o = '0;
      unique case (state_q)
        Idle: begin
          slv_rsp_o.aw_ready = 1'b1;
          slv_rsp_o.w_ready  = slv_req_i.aw_valid;
          slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
        end
        WaitW: slv_rsp_o.w_ready = 1'b1;
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
        default: begin
          slv_rsp_o.r_valid = 1'b1;
          slv_rsp_o.r.id = id_q;
          slv_rsp_o.r.resp = axi_pkg::RESP_SLVERR;
          slv_rsp_o.r.last = 1'b1;
        end
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; id_q <= '0; addr_q <= '0; data_q <= '0; strb_q <= '0;
        wdata_q <= '0; wstrb_q <= '0; resp_q <= '0; aw_h <= 1'b0; w_h <= 1'b0;
        size3_q <= 1'b0; half_q <= 1'b0;
      end else unique case (state_q)
        Idle: begin
          aw_h <= 1'b0; w_h <= 1'b0; half_q <= 1'b0;
          if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
            id_q <= slv_req_i.aw.id;
            addr_q <= slv_req_i.aw.addr;
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
              state_q <= (wr_ok(slv_req_i) && slv_req_i.w.last) ? IssueW : ErrB;
            end else state_q <= wr_ok(slv_req_i) ? WaitW : ErrB;
          end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
            id_q <= slv_req_i.ar.id;
            addr_q <= slv_req_i.ar.addr;
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
          state_q <= slv_req_i.w.last ? IssueW : ErrB;
        end
        IssueW: begin
          if (lite_req_o.aw_valid && lite_rsp_i.aw_ready) aw_h <= 1'b1;
          if (lite_req_o.w_valid && lite_rsp_i.w_ready) w_h <= 1'b1;
          if ((aw_h || (lite_req_o.aw_valid && lite_rsp_i.aw_ready)) &&
              (w_h  || (lite_req_o.w_valid && lite_rsp_i.w_ready))) begin
            if (lite_rsp_i.b_valid) begin
              resp_q <= lite_rsp_i.b.resp;
              if (size3_q && !half_q && |wstrb_q[7:4]) begin
                half_q <= 1'b1; aw_h <= 1'b0; w_h <= 1'b0;
              end else state_q <= SendB;
            end else state_q <= WaitWB;
          end
        end
        WaitWB: if (lite_rsp_i.b_valid && lite_req_o.b_ready) begin
          resp_q <= lite_rsp_i.b.resp;
          if (size3_q && !half_q && |wstrb_q[7:4]) begin
            half_q <= 1'b1; aw_h <= 1'b0; w_h <= 1'b0;
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
        default: if (slv_req_i.r_ready) state_q <= Idle;
      endcase
    end
    logic unused_tm;
    assign unused_tm = testmode_i;
  end
endmodule
