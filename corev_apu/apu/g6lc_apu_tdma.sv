// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// 2:1 AXI join: APU DMA (port A) wins over a secondary master (port B,
// testharness AI DMA). Enable=0 drives the master idle. FeatureVirgl
// stays illegal. Not instantiated in g6lc_apu_sys.

// TestharnessDma (tdma): 2:1 AXI join of APU DMA onto the testharness slave[2] path. Default-off. FeatureVirgl stays illegal.
// Interplay: TestharnessLoad ==> TestharnessDma (tdma) ==> xbar slave[2]. Opt-in G6LC_APU. See AGENTS-impl-interplays.md.
module g6lc_apu_tdma
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0,
  parameter type axi_req_t = apu_dma_axi_req_t,
  parameter type axi_rsp_t = apu_dma_axi_resp_t
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t a_req_i,
  output axi_rsp_t a_rsp_o,
  input  axi_req_t b_req_i,
  output axi_rsp_t b_rsp_o,
  output axi_req_t mst_req_o,
  input  axi_rsp_t mst_rsp_i
);
  if (!Enable) begin : gen_off
    assign a_rsp_o = '0;
    assign b_rsp_o = '0;
    assign mst_req_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | (|a_req_i) | (|b_req_i) | (|mst_rsp_i);
  end else begin : gen_on
    logic lock_q, lock_b_q, r_busy_q, w_busy_q;
    logic a_go, b_go, take_b, ar_h, aw_h, r_done, b_done;

    assign a_go = a_req_i.ar_valid || a_req_i.aw_valid;
    assign b_go = b_req_i.ar_valid || b_req_i.aw_valid;
    assign take_b = (lock_q || r_busy_q || w_busy_q) ? lock_b_q : (!a_go && b_go);
    assign mst_req_o = take_b ? b_req_i : a_req_i;
    assign ar_h = mst_req_o.ar_valid && mst_rsp_i.ar_ready;
    assign aw_h = mst_req_o.aw_valid && mst_rsp_i.aw_ready;
    assign r_done = mst_rsp_i.r_valid && mst_req_o.r_ready && mst_rsp_i.r.last;
    assign b_done = mst_rsp_i.b_valid && mst_req_o.b_ready;

    always_comb begin
      a_rsp_o = mst_rsp_i;
      b_rsp_o = mst_rsp_i;
      if (take_b) begin
        a_rsp_o.aw_ready = 1'b0;
        a_rsp_o.w_ready = 1'b0;
        a_rsp_o.ar_ready = 1'b0;
        a_rsp_o.r_valid = 1'b0;
        a_rsp_o.b_valid = 1'b0;
      end else begin
        b_rsp_o.aw_ready = 1'b0;
        b_rsp_o.w_ready = 1'b0;
        b_rsp_o.ar_ready = 1'b0;
        b_rsp_o.r_valid = 1'b0;
        b_rsp_o.b_valid = 1'b0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        lock_q <= 1'b0;
        lock_b_q <= 1'b0;
        r_busy_q <= 1'b0;
        w_busy_q <= 1'b0;
      end else begin
        // ar_h with r_done: idle 0-wait last beat completes; outstanding
        // last beat plus a new AR stays busy (R belongs to the old burst).
        r_busy_q <= ar_h ? !(r_done && !r_busy_q) : (r_busy_q && !r_done);
        w_busy_q <= aw_h ? !(b_done && !w_busy_q) : (w_busy_q && !b_done);
        if (ar_h || aw_h) lock_b_q <= take_b;
        lock_q <= (ar_h ? !(r_done && !r_busy_q) : (r_busy_q && !r_done)) ||
                  (aw_h ? !(b_done && !w_busy_q) : (w_busy_q && !b_done));
      end
    end
  end
endmodule

// TestharnessDma (tdma) enable-0 fixture: 2:1 AXI DMA join.
module g6lc_apu_tdma_fixture
  import g6lc_apu_bus_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_dma_axi_req_t a_req_i,
  output apu_dma_axi_resp_t a_rsp_o,
  input  apu_dma_axi_req_t b_req_i,
  output apu_dma_axi_resp_t b_rsp_o,
  output apu_dma_axi_req_t mst_req_o,
  input  apu_dma_axi_resp_t mst_rsp_i
);
  g6lc_apu_tdma #(.Enable(Enable)) i_dut (.*);
endmodule
