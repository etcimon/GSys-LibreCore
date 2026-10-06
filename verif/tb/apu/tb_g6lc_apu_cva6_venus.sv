// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// 3d-a (apu-vulkan-engine.md §12.3 phase B): a real CVA6 hart boots the
// bare-metal Venus probe from DRAM (software/apu-venus-probe) and drives
// the virtio-mmio + virtio-gpu probe register-for-register through the
// SoC-facing compositor (g6lc_apu_th_load with ApuCfg = ApuVenus): split
// virtqueues in DRAM, QUEUE_NOTIFY doorbells, INTERRUPT_STATUS/ACK,
// used-ring consumption, aperture polling, and the vn_golden .exp
// checks — all from C.  The APU's DMA reaches the same sparse DRAM the
// hart executes from through a 2:1 join; the aperture at APU_SHM_BASE
// is DRAM here (a real guest maps it WC via Svpbmt; the probe emulates
// that with cbo.inval/cbo.flush).
//
// TB checks independent of the C cookie:
//   * every APU AW/AR stays inside the guest window or the aperture
//   * used-ring image: a used.idx advance requires the element already
//     written; the used.idx write precedes the plic_irq rise
//   * plic_irq rises for each publication and falls after the guest ack
//   * a D$ store into the descriptor table and a committed CBO precede
//     the first doorbell
//   * software checkpoints (fence pulse, objtab live, page allocator,
//     ring extra/head/status fallbacks) evaluated against the hierarchy
//     through a DRAM mailbox
//   * VenusOff arm (+venusoff): ApuP1Transport fixture — the probe fails
//     at the feature check with cookie 0xBAD0_0005 and the APU master
//     stays silent.

`timescale 1ns/1ps
`include "rvfi_types.svh"

package g6lc_venus_pkg;
  // demux rule indices (GuestIdx/CtrlIdx/RamIdx mirror th_load defaults;
  // DestNone is a sentinel idx the rules never carry)
  localparam int unsigned NRules   = 6;
  localparam int unsigned DramIdx  = 0;
  localparam int unsigned PlicIdx  = 6;
  localparam int unsigned GuestIdx = 10;
  localparam int unsigned CtrlIdx  = 11;
  localparam int unsigned RamIdx   = 12;
  localparam int DestNone  = -1;
  localparam int DestDram  = DramIdx;
  localparam int DestGuest = GuestIdx;
  localparam int DestCtrl  = CtrlIdx;
  localparam int DestRam   = RamIdx;
  localparam int DestPlic  = PlicIdx;
endpackage

// Sparse byte-addressed DRAM: one outstanding burst per direction,
// backdoor peek/poke for the TB (cookie, mailbox, image preload).
module g6lc_venus_dram #(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  axi_req_t  slv_req_i,
  output axi_rsp_t  slv_rsp_o
);
  logic [7:0] mem [logic [63:0]];
  localparam int unsigned IdW = $bits(slv_req_i.aw.id);

  // Beat address for a burst beat: base + cnt*size for INCR, wraps inside
  // the (len+1)<<size window for WRAP (I$ critical-word-first fills).
  function automatic logic [63:0] beat_of(input logic [63:0] base,
      input logic [63:0] cnt, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [63:0] line_mask;
    if (burst == axi_pkg::BURST_FIXED) return base;
    line_mask = ((64'(len) + 64'd1) << size) - 64'd1;
    if (burst == axi_pkg::BURST_WRAP)
      return (base & ~line_mask) | ((base + (cnt << size)) & line_mask);
    return base + (cnt << size);
  endfunction

  function automatic logic [7:0] peek8(input logic [63:0] a);
    return mem.exists(a) ? mem[a] : 8'h00;
  endfunction
  function automatic logic [63:0] peek64(input logic [63:0] a);
    peek64 = '0;
    for (int b = 0; b < 8; b++) peek64[8*b +: 8] = peek8(a + 64'(b));
  endfunction
  function automatic logic [31:0] peek32(input logic [63:0] a);
    peek32 = '0;
    for (int b = 0; b < 4; b++) peek32[8*b +: 8] = peek8(a + 64'(b));
  endfunction
  task automatic poke8(input logic [63:0] a, input logic [7:0] d);
    mem[a] = d;
  endtask
  task automatic load_hex(input string path, input logic [63:0] base);
    logic [31:0] img [0:4194303];
    int n;
    $readmemh(path, img);
    n = 0;
    for (int i = 0; i < 4194304; i++)
      if (img[i] !== 32'h0) n = i + 1;
    for (int i = 0; i < n; i++)
      for (int b = 0; b < 4; b++)
        mem[base + 64'(4 * i + b)] = img[i][8*b +: 8];
    $display("DRAM: loaded %0d words from %s at %016x", n, path, base);
  endtask

  logic        r_busy_q;
  logic [63:0] r_addr_q;
  logic [7:0]  r_len_q, r_cnt_q;
  logic [2:0]  r_size_q;
  logic [1:0]  r_burst_q;
  logic [IdW-1:0] r_id_q;
  logic        w_busy_q, b_pend_q;
  logic [63:0] w_addr_q;
  logic [7:0]  w_len_q, w_cnt_q;
  logic [2:0]  w_size_q;
  logic [1:0]  w_burst_q;
  logic [IdW-1:0] w_id_q;

  always_comb begin
    slv_rsp_o = '0;
    slv_rsp_o.ar_ready = !r_busy_q;
    slv_rsp_o.r_valid  = r_busy_q;
    slv_rsp_o.r.id   = r_id_q;
    slv_rsp_o.r.last = (r_cnt_q == r_len_q);
    slv_rsp_o.r.resp = axi_pkg::RESP_OKAY;
    for (int b = 0; b < 8; b++)
      slv_rsp_o.r.data[8*b +: 8] =
          peek8(beat_of(r_addr_q, 64'(r_cnt_q), r_len_q, r_size_q,
                        r_burst_q) + 64'(b));
    slv_rsp_o.aw_ready = !w_busy_q && !b_pend_q;
    slv_rsp_o.w_ready  = w_busy_q;
    slv_rsp_o.b_valid  = b_pend_q;
    slv_rsp_o.b.id     = w_id_q;
    slv_rsp_o.b.resp   = axi_pkg::RESP_OKAY;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= 1'b0; r_addr_q <= '0; r_len_q <= '0; r_cnt_q <= '0;
      r_size_q <= '0; r_burst_q <= '0; r_id_q <= '0;
      w_busy_q <= 1'b0; b_pend_q <= 1'b0; w_addr_q <= '0; w_len_q <= '0;
      w_cnt_q <= '0; w_size_q <= '0; w_burst_q <= '0; w_id_q <= '0;
    end else begin
      if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
        r_busy_q <= 1'b1; r_addr_q <= slv_req_i.ar.addr;
        r_len_q <= slv_req_i.ar.len; r_cnt_q <= '0;
        r_size_q <= slv_req_i.ar.size; r_burst_q <= slv_req_i.ar.burst;
        r_id_q <= slv_req_i.ar.id;
      end
      if (slv_rsp_o.r_valid && slv_req_i.r_ready) begin
        if (r_cnt_q == r_len_q) r_busy_q <= 1'b0;
        else r_cnt_q <= r_cnt_q + 8'd1;
      end
      if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
        w_busy_q <= 1'b1; w_addr_q <= slv_req_i.aw.addr;
        w_len_q <= slv_req_i.aw.len; w_cnt_q <= '0;
        w_size_q <= slv_req_i.aw.size; w_burst_q <= slv_req_i.aw.burst;
        w_id_q <= slv_req_i.aw.id;
      end
      if (slv_req_i.w_valid && slv_rsp_o.w_ready) begin
        for (int b = 0; b < 8; b++)
          if (slv_req_i.w.strb[b])
            mem[beat_of(w_addr_q, 64'(w_cnt_q), w_len_q, w_size_q,
                        w_burst_q) + 64'(b)] <= slv_req_i.w.data[8*b +: 8];
        if (slv_req_i.w.last) begin
          w_busy_q <= 1'b0;
          b_pend_q <= 1'b1;
        end else
          w_cnt_q <= w_cnt_q + 8'd1;
      end
      if (slv_rsp_o.b_valid && slv_req_i.b_ready) b_pend_q <= 1'b0;
    end
  end
endmodule

// Core-side demux: last-matching rule wins, DestNone -> SLVERR.
module g6lc_venus_cmux
  import g6lc_venus_pkg::*;
#(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  axi_req_t  mem_req_i,
  output axi_rsp_t  mem_rsp_o,
  output axi_req_t  dram_req_o,
  input  axi_rsp_t  dram_rsp_i,
  output axi_req_t  guest_req_o,
  input  axi_rsp_t  guest_rsp_i,
  output axi_req_t  ctrl_req_o,
  input  axi_rsp_t  ctrl_rsp_i,
  output axi_req_t  ram_req_o,
  input  axi_rsp_t  ram_rsp_i,
  output axi_req_t  plic_req_o,
  input  axi_rsp_t  plic_rsp_i,
  input  axi_pkg::xbar_rule_64_t [NRules-1:0] rules_i
);
  localparam int unsigned IdW = $bits(mem_req_i.aw.id);

  // DestNone SLVERR responder state (declared before pick()).
  logic        n_r_busy_q, n_w_busy_q, n_b_pend_q;
  logic [7:0]  n_r_len_q, n_r_cnt_q;
  logic [IdW-1:0] n_r_id_q, n_w_id_q;
  axi_rsp_t    none_rsp;

  function automatic int last_match(input logic [63:0] a);
    int idx;
    idx = DestNone;
    for (int i = 0; i < NRules; i++)
      if (a[31:0] >= rules_i[i].start_addr[31:0] &&
          a[31:0] <  rules_i[i].end_addr[31:0])
        idx = int'(rules_i[i].idx);
    return idx;
  endfunction
  function automatic axi_rsp_t pick(input int d);
    unique case (d)
      DestDram:  return dram_rsp_i;
      DestGuest: return guest_rsp_i;
      DestCtrl:  return ctrl_rsp_i;
      DestRam:   return ram_rsp_i;
      DestPlic:  return plic_rsp_i;
      default:   return none_rsp;
    endcase
  endfunction

  int r_dest_q, w_dest_q;
  logic r_busy_q, w_busy_q;
  int dest_ar, dest_aw;
  axi_rsp_t sel, ar_pick, aw_pick, w_pick;

  always_comb begin
    none_rsp = '0;
    none_rsp.ar_ready = !n_r_busy_q;
    none_rsp.r_valid  = n_r_busy_q;
    none_rsp.r.id     = n_r_id_q;
    none_rsp.r.last   = (n_r_cnt_q == n_r_len_q);
    none_rsp.r.resp   = axi_pkg::RESP_SLVERR;
    none_rsp.aw_ready = !n_w_busy_q && !n_b_pend_q;
    none_rsp.w_ready  = n_w_busy_q;
    none_rsp.b_valid  = n_b_pend_q;
    none_rsp.b.id     = n_w_id_q;
    none_rsp.b.resp   = axi_pkg::RESP_SLVERR;
  end
  logic n_ar_h, n_aw_h, n_w_h, n_r_h, n_b_h;
  assign n_ar_h = mem_req_i.ar_valid && mem_rsp_o.ar_ready &&
                  dest_ar == DestNone;
  assign n_aw_h = mem_req_i.aw_valid && mem_rsp_o.aw_ready &&
                  dest_aw == DestNone;
  assign n_w_h  = mem_req_i.w_valid && w_busy_q && w_dest_q == DestNone;
  assign n_r_h  = none_rsp.r_valid && mem_req_i.r_ready &&
                  r_busy_q && r_dest_q == DestNone;
  assign n_b_h  = none_rsp.b_valid && mem_req_i.b_ready &&
                  w_busy_q && w_dest_q == DestNone;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      n_r_busy_q <= 1'b0; n_w_busy_q <= 1'b0; n_b_pend_q <= 1'b0;
      n_r_len_q <= '0; n_r_cnt_q <= '0; n_r_id_q <= '0; n_w_id_q <= '0;
    end else begin
      if (n_ar_h) begin
        n_r_busy_q <= 1'b1; n_r_id_q <= mem_req_i.ar.id;
        n_r_len_q <= mem_req_i.ar.len; n_r_cnt_q <= '0;
      end
      if (n_r_h) begin
        if (n_r_cnt_q == n_r_len_q) n_r_busy_q <= 1'b0;
        else n_r_cnt_q <= n_r_cnt_q + 8'd1;
      end
      if (n_aw_h) begin
        n_w_busy_q <= 1'b1; n_w_id_q <= mem_req_i.aw.id;
      end
      if (n_w_h && mem_req_i.w.last) begin
        n_w_busy_q <= 1'b0; n_b_pend_q <= 1'b1;
      end
      if (n_b_h) n_b_pend_q <= 1'b0;
    end
  end

  assign dest_ar = last_match(mem_req_i.ar.addr);
  assign dest_aw = last_match(mem_req_i.aw.addr);
  assign sel     = r_busy_q ? pick(r_dest_q) :
                   w_busy_q ? pick(w_dest_q) : dram_rsp_i;
  assign ar_pick = pick(dest_ar);
  assign aw_pick = pick(dest_aw);
  assign w_pick  = pick(w_busy_q ? w_dest_q : dest_aw);

  always_comb begin
    dram_req_o  = mem_req_i;
    guest_req_o = mem_req_i;
    ctrl_req_o  = mem_req_i;
    ram_req_o   = mem_req_i;
    plic_req_o  = mem_req_i;
    dram_req_o.ar_valid  = mem_req_i.ar_valid && !r_busy_q &&
                           dest_ar == DestDram;
    guest_req_o.ar_valid = mem_req_i.ar_valid && !r_busy_q &&
                           dest_ar == DestGuest;
    ctrl_req_o.ar_valid  = mem_req_i.ar_valid && !r_busy_q &&
                           dest_ar == DestCtrl;
    ram_req_o.ar_valid   = mem_req_i.ar_valid && !r_busy_q &&
                           dest_ar == DestRam;
    plic_req_o.ar_valid  = mem_req_i.ar_valid && !r_busy_q &&
                           dest_ar == DestPlic;
    dram_req_o.aw_valid  = mem_req_i.aw_valid && !w_busy_q &&
                           dest_aw == DestDram;
    guest_req_o.aw_valid = mem_req_i.aw_valid && !w_busy_q &&
                           dest_aw == DestGuest;
    ctrl_req_o.aw_valid  = mem_req_i.aw_valid && !w_busy_q &&
                           dest_aw == DestCtrl;
    ram_req_o.aw_valid   = mem_req_i.aw_valid && !w_busy_q &&
                           dest_aw == DestRam;
    plic_req_o.aw_valid  = mem_req_i.aw_valid && !w_busy_q &&
                           dest_aw == DestPlic;
    dram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestDram) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestDram));
    guest_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestGuest) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestGuest));
    ctrl_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestCtrl) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestCtrl));
    ram_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestRam) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestRam));
    plic_req_o.w_valid = mem_req_i.w_valid &&
        ((w_busy_q && w_dest_q == DestPlic) ||
         (!w_busy_q && mem_req_i.aw_valid && dest_aw == DestPlic));
    dram_req_o.r_ready  = mem_req_i.r_ready && r_busy_q &&
                          r_dest_q == DestDram;
    guest_req_o.r_ready = mem_req_i.r_ready && r_busy_q &&
                          r_dest_q == DestGuest;
    ctrl_req_o.r_ready  = mem_req_i.r_ready && r_busy_q &&
                          r_dest_q == DestCtrl;
    ram_req_o.r_ready   = mem_req_i.r_ready && r_busy_q &&
                          r_dest_q == DestRam;
    plic_req_o.r_ready  = mem_req_i.r_ready && r_busy_q &&
                          r_dest_q == DestPlic;
    dram_req_o.b_ready  = mem_req_i.b_ready && w_busy_q &&
                          w_dest_q == DestDram;
    guest_req_o.b_ready = mem_req_i.b_ready && w_busy_q &&
                          w_dest_q == DestGuest;
    ctrl_req_o.b_ready  = mem_req_i.b_ready && w_busy_q &&
                          w_dest_q == DestCtrl;
    ram_req_o.b_ready   = mem_req_i.b_ready && w_busy_q &&
                          w_dest_q == DestRam;
    plic_req_o.b_ready  = mem_req_i.b_ready && w_busy_q &&
                          w_dest_q == DestPlic;
    mem_rsp_o = sel;
    mem_rsp_o.ar_ready = !r_busy_q && ar_pick.ar_ready;
    mem_rsp_o.aw_ready = !w_busy_q && aw_pick.aw_ready;
    mem_rsp_o.w_ready  = w_busy_q ? w_pick.w_ready :
        (mem_req_i.aw_valid && aw_pick.w_ready);
    if (r_busy_q) begin
      mem_rsp_o.r_valid = sel.r_valid;
      mem_rsp_o.r       = sel.r;
    end else
      mem_rsp_o.r_valid = 1'b0;
    if (w_busy_q) begin
      mem_rsp_o.b_valid = sel.b_valid;
      mem_rsp_o.b       = sel.b;
    end else
      mem_rsp_o.b_valid = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_busy_q <= 1'b0; w_busy_q <= 1'b0;
      r_dest_q <= DestNone; w_dest_q <= DestNone;
    end else begin
      if (!r_busy_q && mem_req_i.ar_valid && mem_rsp_o.ar_ready) begin
        r_busy_q <= 1'b1;
        r_dest_q <= dest_ar;
      end else if (r_busy_q && mem_rsp_o.r_valid && mem_req_i.r_ready &&
                   mem_rsp_o.r.last)
        r_busy_q <= 1'b0;
      if (!w_busy_q && mem_req_i.aw_valid && mem_rsp_o.aw_ready) begin
        w_busy_q <= 1'b1;
        w_dest_q <= dest_aw;
      end else if (w_busy_q && mem_rsp_o.b_valid && mem_req_i.b_ready)
        w_busy_q <= 1'b0;
    end
  end
endmodule

// 2:1 join: port A (APU DMA) wins; port B (core DRAM traffic).  Whole
// bursts lock per direction, same convention as g6lc_apu_tdma.
module g6lc_venus_join (
  input  logic clk_i,
  input  logic rst_ni,
  input  g6lc_apu_bus_pkg::apu_dma_axi_req_t  a_req_i,
  output g6lc_apu_bus_pkg::apu_dma_axi_resp_t a_rsp_o,
  input  ariane_axi::req_t  b_req_i,
  output ariane_axi::resp_t b_rsp_o,
  output ariane_axi::req_t  mst_req_o,
  input  ariane_axi::resp_t mst_rsp_i
);
  function automatic ariane_axi::req_t conv_a(
      input g6lc_apu_bus_pkg::apu_dma_axi_req_t r);
    ariane_axi::req_t o;
    o = '0;
    o.aw.id = r.aw.id; o.aw.addr = r.aw.addr; o.aw.len = r.aw.len;
    o.aw.size = r.aw.size; o.aw.burst = r.aw.burst; o.aw.lock = r.aw.lock;
    o.aw.cache = r.aw.cache; o.aw.prot = r.aw.prot; o.aw.qos = r.aw.qos;
    o.aw.region = r.aw.region; o.aw.atop = r.aw.atop;
    o.aw.user = 64'(r.aw.user);
    o.w.data = r.w.data; o.w.strb = r.w.strb; o.w.last = r.w.last;
    o.w.user = 64'(r.w.user);
    o.ar.id = r.ar.id; o.ar.addr = r.ar.addr; o.ar.len = r.ar.len;
    o.ar.size = r.ar.size; o.ar.burst = r.ar.burst; o.ar.lock = r.ar.lock;
    o.ar.cache = r.ar.cache; o.ar.prot = r.ar.prot; o.ar.qos = r.ar.qos;
    o.ar.region = r.ar.region; o.ar.user = 64'(r.ar.user);
    o.aw_valid = r.aw_valid; o.w_valid = r.w_valid; o.ar_valid = r.ar_valid;
    o.b_ready = r.b_ready; o.r_ready = r.r_ready;
    return o;
  endfunction

  logic lock_q, lock_b_q, r_busy_q, w_busy_q;
  logic a_go, b_go, take_b, ar_h, aw_h, r_done, b_done;
  ariane_axi::req_t a_conv;

  assign a_conv = conv_a(a_req_i);
  assign a_go = a_req_i.ar_valid || a_req_i.aw_valid;
  assign b_go = b_req_i.ar_valid || b_req_i.aw_valid;
  assign take_b = (lock_q || r_busy_q || w_busy_q) ? lock_b_q
                                                 : (!a_go && b_go);
  assign mst_req_o = take_b ? b_req_i : a_conv;
  assign ar_h = mst_req_o.ar_valid && mst_rsp_i.ar_ready;
  assign aw_h = mst_req_o.aw_valid && mst_rsp_i.aw_ready;
  assign r_done = mst_rsp_i.r_valid && mst_req_o.r_ready && mst_rsp_i.r.last;
  assign b_done = mst_rsp_i.b_valid && mst_req_o.b_ready;

  always_comb begin
    a_rsp_o = '0;
    a_rsp_o.aw_ready = !take_b && mst_rsp_i.aw_ready;
    a_rsp_o.w_ready  = !take_b && mst_rsp_i.w_ready;
    a_rsp_o.ar_ready = !take_b && mst_rsp_i.ar_ready;
    a_rsp_o.r_valid  = !take_b && mst_rsp_i.r_valid;
    a_rsp_o.b_valid  = !take_b && mst_rsp_i.b_valid;
    a_rsp_o.b.id   = 4'(mst_rsp_i.b.id);
    a_rsp_o.b.resp = mst_rsp_i.b.resp;
    a_rsp_o.b.user = mst_rsp_i.b.user[0];
    a_rsp_o.r.id   = 4'(mst_rsp_i.r.id);
    a_rsp_o.r.data = mst_rsp_i.r.data;
    a_rsp_o.r.resp = mst_rsp_i.r.resp;
    a_rsp_o.r.last = mst_rsp_i.r.last;
    a_rsp_o.r.user = mst_rsp_i.r.user[0];
    b_rsp_o = mst_rsp_i;
    if (!take_b) begin
      b_rsp_o.aw_ready = 1'b0;
      b_rsp_o.w_ready  = 1'b0;
      b_rsp_o.ar_ready = 1'b0;
      b_rsp_o.r_valid  = 1'b0;
      b_rsp_o.b_valid  = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lock_q <= 1'b0; lock_b_q <= 1'b0;
      r_busy_q <= 1'b0; w_busy_q <= 1'b0;
    end else begin
      r_busy_q <= ar_h ? !(r_done && !r_busy_q) : (r_busy_q && !r_done);
      w_busy_q <= aw_h ? !(b_done && !w_busy_q) : (w_busy_q && !b_done);
      if (ar_h || aw_h) lock_b_q <= take_b;
      lock_q <= (ar_h ? !(r_done && !r_busy_q) : (r_busy_q && !r_done)) ||
                (aw_h ? !(b_done && !w_busy_q) : (w_busy_q && !b_done));
    end
  end
endmodule

// Minimal PLIC-shaped stub: reads mirror the spliced source level;
// writes are recorded.  Not a real interrupt controller.
module g6lc_venus_plic_stub #(
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  axi_req_t  slv_req_i,
  output axi_rsp_t  slv_rsp_o,
  input  logic      src_level_i,
  output logic      saw_rd_o,
  output logic      saw_wr_o
);
  localparam int unsigned IdW = $bits(slv_req_i.aw.id);
  typedef enum logic [1:0] { Idle, WaitW, SendB, SendR } state_e;
  state_e state_q;
  logic [IdW-1:0] id_q;
  logic sawr_q, saww_q;
  assign saw_rd_o = sawr_q;
  assign saw_wr_o = saww_q;
  always_comb begin
    slv_rsp_o = '0;
    unique case (state_q)
      Idle: begin
        slv_rsp_o.aw_ready = 1'b1;
        slv_rsp_o.w_ready  = slv_req_i.aw_valid;
        slv_rsp_o.ar_ready = !slv_req_i.aw_valid;
      end
      WaitW: slv_rsp_o.w_ready = 1'b1;
      SendB: begin
        slv_rsp_o.b_valid = 1'b1;
        slv_rsp_o.b.id    = id_q;
        slv_rsp_o.b.resp  = axi_pkg::RESP_SLVERR;
      end
      default: begin
        slv_rsp_o.r_valid = 1'b1;
        slv_rsp_o.r.id    = id_q;
        slv_rsp_o.r.last  = 1'b1;
        slv_rsp_o.r.resp  = axi_pkg::RESP_SLVERR;
        slv_rsp_o.r.data  = {63'b0, src_level_i};
      end
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle; id_q <= '0; sawr_q <= 1'b0; saww_q <= 1'b0;
    end else unique case (state_q)
      Idle: begin
        if (slv_req_i.aw_valid && slv_rsp_o.aw_ready) begin
          id_q <= slv_req_i.aw.id;
          if (slv_req_i.w_valid) begin
            saww_q <= 1'b1;
            state_q <= SendB;
          end else
            state_q <= WaitW;
        end else if (slv_req_i.ar_valid && slv_rsp_o.ar_ready) begin
          id_q <= slv_req_i.ar.id;
          sawr_q <= 1'b1;
          state_q <= SendR;
        end
      end
      WaitW: if (slv_req_i.w_valid) begin
        saww_q <= 1'b1;
        state_q <= SendB;
      end
      SendB: if (slv_req_i.b_ready) state_q <= Idle;
      default: if (slv_req_i.r_ready) state_q <= Idle;
    endcase
  end
endmodule

module tb_g6lc_apu_cva6_venus;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_venus_pkg::*;
  import axi_pkg::*;

  `include "vn_map.svh"

  function automatic config_pkg::cva6_cfg_t cluster_cfg();
    config_pkg::cva6_cfg_t c;
    c = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    c.L2En = 1'b0;
    c.L3En = 1'b0;
    c.ServerPrefetchEn = 1'b0;
    // HPDCACHE_WT: with no L2, CMOs complete locally (wbuf drain =
    // flush, L1 inval = inval); check_cfg forbids L2CmoEn&&!L2En.
    c.L2CmoEn = 1'b0;
    c.L2WriteUpdateEn = 1'b0;
    c.L2PostedWriteEn = 1'b0;
    c.NrCores = 2;
    c.NrHarts = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CoreCfg = cluster_cfg();
  typedef `RVFI_PROBES_INSTR_T(CoreCfg) rvfi_instr_t;
  typedef `RVFI_PROBES_CSR_T(CoreCfg) rvfi_csr_t;
  typedef struct packed {
    rvfi_csr_t csr;
    rvfi_instr_t instr;
  } rvfi_probes_t;

  // VenusOff fixture: the transport-only config needs the hart/RAM
  // pairing (apu_cfg_legal); the hole lands inside the DRAM window.
  function automatic apu_cfg_t venus_off_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.FirmwareHart     = 1;
    cfg.FirmwareRamBase  = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction

  localparam logic [63:0] PlicBase = 64'h0C00_0000;
  localparam logic [63:0] PlicEnd  = 64'h1000_0000;
  localparam logic [63:0] BootPc   = 64'h8002_0000;   // venus_probe .text
  localparam logic [63:0] ParkPc   = 64'h8001_F000;   // core 1 spin
  localparam logic [63:0] U0       = SV_VN_Q0_USED;   // used ring 0
  localparam logic [63:0] D0       = SV_VN_Q0_DESC;   // desc table 0
  localparam logic [63:0] MMIO     = SV_VN_MMIO_BASE;
  localparam int unsigned MAXCYC   = 300_000_000;
  localparam apu_cfg_t OffCfg = venus_off_cfg();

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0;
  logic venusoff;
  initial venusoff = $test$plusargs("venusoff");

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) begin
    if (cycles > MAXCYC) $fatal(1, "watchdog cycles=%0d", cycles);
    if (cycles % 2000000 == 0)
      $display("[hb] cyc=%0d cookie=%016x doorbell=%0d desc_st=%0d cbo=%0d pc=%016x apu_aw=%0d ar=%0d w=%0d pubs=%0d irq=%0d/%0d",
              cycles, i_dram.peek64(SV_VN_COOKIE_ADDR), doorbell_seen,
              desc_stores, cbo_seen, apu_aw_n, apu_ar_n, apu_w_n,
              pubs, irq_rises, irq_falls, last_pc);
  end

  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (cycle=%0d)", msg, cycles);
      if (errors > 40) $fatal(1, "too many errors");
    end
  endtask

  // straddling-window helpers
  function automatic bit covers(input logic [63:0] b,
      input logic [7:0] strb, input logic [63:0] lo, input int n);
    // true when the W beat at base b writes at least one byte of [lo,lo+n)
    for (int i = 0; i < n; i++) begin
      if (lo + 64'(i) >= b && lo + 64'(i) < b + 8 &&
          strb[int'(lo + 64'(i) - b)])
        return 1'b1;
    end
    return 1'b0;
  endfunction
  function automatic logic [15:0] beat_h16(input logic [63:0] b,
      input logic [63:0] d, input logic [63:0] a);
    return d[8 * int'(a - b) +: 16];
  endfunction

  // ---- cluster ------------------------------------------------------------
  ariane_axi::req_t  mem_req;
  ariane_axi::resp_t mem_rsp;
  rvfi_probes_t rvfi0;
  logic [1:0][CoreCfg.VLEN-1:0] boot;
  logic [1:0][0:0][1:0] irq_v;
  assign boot[0] = CoreCfg.VLEN'(BootPc);
  assign boot[1] = CoreCfg.VLEN'(ParkPc);

  logic plic_irq;
  assign irq_v[0][0][0] = plic_irq;   // M_EXT level
  assign irq_v[0][0][1] = 1'b0;       // S_EXT
  assign irq_v[1][0]    = 2'b00;

  g6lc_cluster #(
    .CVA6Cfg(CoreCfg), .NR_CORES(2), .L2_ENABLE(1'b0),
    .IDENTITY_FAST(1'b1), .INCLUSIVE_L3(1'b0), .PerCoreBoot(1'b1),
    .AXI_ADDR_WIDTH(ariane_axi::AddrWidth),
    .AXI_DATA_WIDTH(ariane_axi::DataWidth),
    .AXI_ID_WIDTH(ariane_axi::IdWidth),
    .AXI_USER_WIDTH(ariane_axi::UserWidth),
    .axi_req_t(ariane_axi::req_t), .axi_resp_t(ariane_axi::resp_t),
    .rvfi_probes_t(rvfi_probes_t)
  ) i_cluster (
    .clk_i(clk), .rst_ni(rst_ni),
    .boot_addr_i(boot[0]), .boot_addr_core_i(boot),
    .irq_i(irq_v), .ipi_i('0), .time_irq_i('0), .rtc_time_i('0),
    .debug_req_i('0),
    .mem_req_o(mem_req), .mem_resp_i(mem_rsp),
    .rvfi_probes_o(rvfi0),
    .l2_miss_o(), .l3_hit_o(), .l3_miss_o(), .pf_issue_o(), .pf_train_o(),
    .ai_sb_enq_valid_o(), .ai_sb_enq_ready_i(1'b1), .ai_sb_enq_ticket_i('0),
    .ai_sb_qid_o(), .ai_sb_ticket_o(), .ai_sb_desc_ptr_o(),
    .ai_isl_attached_i(1'b0), .ai_isl_has_completion_i(1'b0),
    .ai_isl_retired_valid_i(1'b0), .ai_isl_retired_ticket_i('0),
    .ai_isl_last_ticket_i('0), .ai_isl_last_status_i('0),
    .ai_dma_inval_valid_i(1'b0), .ai_dma_inval_addr_i('0),
    .ai_dma_inval_ready_o(), .ai_dma_inval_done_o()
  );

  // ---- demux ---------------------------------------------------------------
  ariane_axi::req_t  dram_req, guest_req, ctrl_req, ram_req, plic_req;
  ariane_axi::resp_t dram_rsp, guest_rsp, ctrl_rsp, ram_rsp, plic_rsp;
  xbar_rule_64_t [NRules-1:0] rules;
  xbar_rule_64_t tl_guest, tl_ctrl, tl_ram, tl_dlo, tl_dhi;
  xbar_rule_64_t o_guest, o_ctrl, o_ram, o_dlo, o_dhi;

  assign rules[0] = venusoff ? o_dlo : tl_dlo;
  assign rules[1] = '{idx: PlicIdx, start_addr: PlicBase,
                     end_addr: PlicEnd};
  assign rules[2] = venusoff ? o_dhi : tl_dhi;
  assign rules[3] = venusoff ? o_guest : tl_guest;
  assign rules[4] = venusoff ? o_ctrl : tl_ctrl;
  assign rules[5] = venusoff ? o_ram : tl_ram;

  g6lc_venus_cmux #(
    .axi_req_t(ariane_axi::req_t), .axi_rsp_t(ariane_axi::resp_t)
  ) i_cmux (
    .clk_i(clk), .rst_ni(rst_ni),
    .mem_req_i(mem_req), .mem_rsp_o(mem_rsp),
    .dram_req_o(dram_req), .dram_rsp_i(dram_rsp),
    .guest_req_o(guest_req), .guest_rsp_i(guest_rsp),
    .ctrl_req_o(ctrl_req), .ctrl_rsp_i(ctrl_rsp),
    .ram_req_o(ram_req), .ram_rsp_i(ram_rsp),
    .plic_req_o(plic_req), .plic_rsp_i(plic_rsp),
    .rules_i(rules)
  );

  // ---- APU compositor: Venus + VenusOff instances, muxed by arm ------------
  logic [29:0] irq_src_v, irq_src_o;
  logic plic_irq_v, plic_irq_o_arm;
  logic fw_rdy_v, fw_rdy_o, ram_fault_v, ram_fault_o;
  logic [1:0][CoreCfg.VLEN-1:0] boot_v, boot_o;
  apu_dma_axi_req_t  dma_req_v, dma_req_o_s;
  apu_dma_axi_resp_t dma_rsp_v, dma_rsp_o_s;
  ariane_axi::req_t  creq_v, creq_o, greq_v, greq_o, rreq_v, rreq_o;
  ariane_axi::resp_t crsp_v, crsp_o, grsp_v, grsp_o, rrsp_v, rrsp_o;

  assign plic_irq = venusoff ? plic_irq_o_arm : plic_irq_v;
  assign greq_v = venusoff ? '0 : guest_req;
  assign greq_o = venusoff ? guest_req : '0;
  assign guest_rsp = venusoff ? grsp_o : grsp_v;
  assign creq_v = venusoff ? '0 : ctrl_req;
  assign creq_o = venusoff ? ctrl_req : '0;
  assign ctrl_rsp = venusoff ? crsp_o : crsp_v;
  assign rreq_v = venusoff ? '0 : ram_req;
  assign rreq_o = venusoff ? ram_req : '0;
  assign ram_rsp = venusoff ? rrsp_o : rrsp_v;

  g6lc_apu_th_load #(
    .ApuCfg(ApuVenus), .CoreCfg(CoreCfg), .AppBoot(BootPc),
    .DramBase(64'h8000_0000), .DramBytes(64'h4000_0000),
    .GuestIdx(GuestIdx), .CtrlIdx(CtrlIdx), .RamIdx(RamIdx),
    .DramIdx(DramIdx), .NumCores(2), .Vlen(CoreCfg.VLEN),
    .HexFile("none"), .HartIdWidth(32), .NumSources(30),
    .axi4_req_t(ariane_axi::req_t), .axi4_rsp_t(ariane_axi::resp_t),
    .dma_req_t(apu_dma_axi_req_t), .dma_rsp_t(apu_dma_axi_resp_t)
  ) i_thl_v (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b1),
    .guest_req_i(greq_v), .guest_rsp_o(grsp_v),
    .control_req_i(creq_v), .control_rsp_o(crsp_v),
    .ram_req_i(rreq_v), .ram_rsp_o(rrsp_v),
    .control_aw_hart_i(32'd0), .control_ar_hart_i(32'd0),
    .ram_aw_hart_i(32'd0), .ram_ar_hart_i(32'd0),
    .irq_sources_i('0), .irq_sources_o(irq_src_v),
    .plic_irq_o(plic_irq_v), .fw_ready_o(fw_rdy_v),
    .boot_addr_core_o(boot_v),
    .guest_rule_o(tl_guest), .control_rule_o(tl_ctrl),
    .ram_rule_o(tl_ram), .dram_lo_rule_o(tl_dlo), .dram_hi_rule_o(tl_dhi),
    .dma_req_o(dma_req_v), .dma_rsp_i(dma_rsp_v),
    .ram_fault_o(ram_fault_v)
  );
  g6lc_apu_th_load #(
    .ApuCfg(OffCfg), .CoreCfg(CoreCfg), .AppBoot(BootPc),
    .DramBase(64'h8000_0000), .DramBytes(64'h4000_0000),
    .GuestIdx(GuestIdx), .CtrlIdx(CtrlIdx), .RamIdx(RamIdx),
    .DramIdx(DramIdx), .NumCores(2), .Vlen(CoreCfg.VLEN),
    .HexFile("none"), .HartIdWidth(32), .NumSources(30),
    .axi4_req_t(ariane_axi::req_t), .axi4_rsp_t(ariane_axi::resp_t),
    .dma_req_t(apu_dma_axi_req_t), .dma_rsp_t(apu_dma_axi_resp_t)
  ) i_thl_o (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b1),
    .guest_req_i(greq_o), .guest_rsp_o(grsp_o),
    .control_req_i(creq_o), .control_rsp_o(crsp_o),
    .ram_req_i(rreq_o), .ram_rsp_o(rrsp_o),
    .control_aw_hart_i(32'd0), .control_ar_hart_i(32'd0),
    .ram_aw_hart_i(32'd0), .ram_ar_hart_i(32'd0),
    .irq_sources_i('0), .irq_sources_o(irq_src_o),
    .plic_irq_o(plic_irq_o_arm), .fw_ready_o(fw_rdy_o),
    .boot_addr_core_o(boot_o),
    .guest_rule_o(o_guest), .control_rule_o(o_ctrl),
    .ram_rule_o(o_ram), .dram_lo_rule_o(o_dlo), .dram_hi_rule_o(o_dhi),
    .dma_req_o(dma_req_o_s), .dma_rsp_i(dma_rsp_o_s),
    .ram_fault_o(ram_fault_o)
  );

  // ---- DRAM join + sparse model -------------------------------------------
  apu_dma_axi_req_t  j_a_req;
  apu_dma_axi_resp_t j_a_rsp;
  ariane_axi::req_t  jd_req;
  ariane_axi::resp_t jd_rsp;
  assign j_a_req     = venusoff ? dma_req_o_s : dma_req_v;
  assign dma_rsp_v   = j_a_rsp;
  assign dma_rsp_o_s = j_a_rsp;

  g6lc_venus_join i_join (
    .clk_i(clk), .rst_ni(rst_ni),
    .a_req_i(j_a_req), .a_rsp_o(j_a_rsp),
    .b_req_i(dram_req), .b_rsp_o(dram_rsp),
    .mst_req_o(jd_req), .mst_rsp_i(jd_rsp)
  );
  g6lc_venus_dram #(
    .axi_req_t(ariane_axi::req_t), .axi_rsp_t(ariane_axi::resp_t)
  ) i_dram (
    .clk_i(clk), .rst_ni(rst_ni),
    .slv_req_i(jd_req), .slv_rsp_o(jd_rsp)
  );

  g6lc_venus_plic_stub #(
    .axi_req_t(ariane_axi::req_t), .axi_rsp_t(ariane_axi::resp_t)
  ) i_plic (
    .clk_i(clk), .rst_ni(rst_ni),
    .slv_req_i(plic_req), .slv_rsp_o(plic_rsp),
    .src_level_i(plic_irq), .saw_rd_o(), .saw_wr_o()
  );

  // ---- hierarchical observability of the Venus fixture ----------------------
  wire        vg_idle   = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.vg_idle;
  wire        f_pulse   = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.fence_pulse_o;
  wire [63:0] f_id      = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.fence_id_o;
  wire [7:0]  f_ring    = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.fence_ring_o;
  wire [15:0] ot_live   = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.objtab_live_o;
  wire [3:0][31:0] r_status = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.ring_status_o;
  wire [3:0][31:0] r_head   = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.ring_head_o;
  wire [3:0][17:0] r_extra  = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.ring_extra_w_o;
  wire [255:0] vgp_free = i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys
                            .gen_venus.i_vgsys.gen_on.i_top.gen_on.i_vgp
                            .gen_on.free_q;
  // Guest INTERRUPT_ACK[0] write decode inside the virtio-mmio register
  // block (combinational pulse on the register-write strobe).
  wire        irq_ack_pulse =
      |i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys.i_lite.gen_on.i_apu
        .gen_enabled.i_transport.irq_ack[0];
  // Guest QUEUE_NOTIFY write decode (per-queue pulse).
  wire        notify_pulse =
      |i_thl_v.i_xbar.i_th.i_attach.i_soc.i_sys.i_lite.gen_on.i_apu
        .gen_enabled.i_transport.notify_set;

  // ---- APU DMA monitor: window assertion + used-ring ordering --------------
  int unsigned apu_aw_n = 0, apu_ar_n = 0, apu_w_n = 0, apu_b_n = 0,
               apu_r_n = 0;
  function automatic bit in_win(input logic [63:0] a);
    return (a >= SV_VN_DMA_BASE &&
            a < SV_VN_DMA_BASE + SV_VN_DMA_BYTES) ||
           (a >= SV_VN_SHM_BASE && a < SV_VN_SHM_BASE + SV_VN_SHM_BYTES);
  endfunction

  // A-port write burst tracker (the APU is single-outstanding)
  logic        mon_wact = 0;
  logic [63:0] mon_waddr;
  logic [2:0]  mon_wsize;
  logic [1:0]  mon_wburst;
  logic [63:0] elem_seen;
  int unsigned idx_q = 0, pubs = 0;
  int unsigned irq_rises = 0, irq_falls = 0;
  logic irq_q = 0, ack_seen_q = 0;
  logic [63:0] cur_waddr;            // W beat address this cycle
  logic        cur_wh;               // A-port W handshake this cycle

  assign cur_wh = j_a_req.w_valid && j_a_rsp.w_ready;
  assign cur_waddr = mon_waddr;

  always @(posedge clk) begin
    logic [15:0] new_idx;
    if (!rst_ni) begin
      mon_wact <= 1'b0; elem_seen <= '0; idx_q <= 0; pubs <= 0;
      irq_q <= 0; ack_seen_q <= 0;
      irq_rises <= 0; irq_falls <= 0;
    end else begin
      if (j_a_req.aw_valid && j_a_rsp.aw_ready) begin
        apu_aw_n++;
        if (!in_win(j_a_req.aw.addr))
          $fatal(1, "APU AW %016x outside guest/aperture windows",
                 j_a_req.aw.addr);
        mon_wact   <= 1'b1;
        mon_waddr  <= j_a_req.aw.addr;
        mon_wsize  <= j_a_req.aw.size;
        mon_wburst <= j_a_req.aw.burst;
      end
      if (j_a_req.ar_valid && j_a_rsp.ar_ready) begin
        apu_ar_n++;
        if (!in_win(j_a_req.ar.addr))
          $fatal(1, "APU AR %016x outside guest/aperture windows",
                 j_a_req.ar.addr);
      end
      if (cur_wh) begin
        apu_w_n++;
        for (int s = 0; s < 64; s++)
          if (covers(cur_waddr, j_a_req.w.strb, U0 + 4 + 8 * s, 8))
            elem_seen[s] <= 1'b1;
        if (covers(cur_waddr, j_a_req.w.strb, U0 + 2, 2)) begin
          new_idx = beat_h16(cur_waddr, j_a_req.w.data, U0 + 2);
          if (16'(new_idx) != 16'(idx_q)) begin
            check(elem_seen[(new_idx - 1) % 64] ||
                  covers(cur_waddr, j_a_req.w.strb,
                         U0 + 4 + 8 * ((new_idx - 1) % 64), 8),
                  "used.idx advanced before its element was written");
            idx_q <= 32'(new_idx);
            pubs++;
          end
        end
        if (j_a_req.w.last) mon_wact <= 1'b0;
        else mon_waddr <= cur_waddr + (64'd1 << mon_wsize);
      end
      if (j_a_rsp.b_valid && j_a_req.b_ready) apu_b_n++;
      if (j_a_rsp.r_valid && j_a_req.r_ready && j_a_rsp.r.last) apu_r_n++;
      // idle fixture: the unselected DMA master must stay silent
      if (!venusoff && |dma_req_o_s)
        $fatal(1, "VenusOff fixture driving DMA during Venus arm");
      if (venusoff && |dma_req_v)
        $fatal(1, "Venus fixture driving DMA during VenusOff arm");

      // plic level: every rise follows a used.idx write; every fall
      // follows the guest INTERRUPT_ACK bit0 write.  The ack is
      // observed at the mmio register decode (irq_ack pulse) — AXI
      // AW/W ordering at the guest port is arbitrary, so channel-snoop
      // correlation is racy.
      irq_q <= plic_irq;
      if (irq_ack_pulse) ack_seen_q <= 1'b1;
      if (plic_irq && !irq_q) begin
        check(pubs > irq_rises,
              "plic_irq rose before the used.idx write landed");
        irq_rises++;
      end
      if (!plic_irq && irq_q) begin
        check(ack_seen_q,
              "plic_irq fell without a guest INTERRUPT_ACK write");
        irq_falls++;
        ack_seen_q <= 1'b0;
      end
    end
  end

  // doorbell observability: a descriptor-table D$ store and a committed
  // CBO must precede the first QUEUE_NOTIFY write.
  int unsigned desc_stores = 0;
  logic doorbell_seen = 0, cbo_seen = 0;
  logic [63:0] last_pc = 0;
  logic        dmon_act = 0;
  logic [63:0] dmon_addr;
  logic [2:0]  dmon_size;
  logic [1:0]  dmon_burst;

  always @(posedge clk) begin
    logic [63:0] cur;
    if (!rst_ni) begin
      dmon_act <= 0; dmon_addr <= '0; dmon_size <= '0; dmon_burst <= '0;
      desc_stores <= 0; doorbell_seen <= 0; cbo_seen <= 0;
    end else begin
      if (dram_req.aw_valid && dram_rsp.aw_ready) begin
        dmon_act   <= 1'b1;
        dmon_addr  <= dram_req.aw.addr;
        dmon_size  <= dram_req.aw.size;
        dmon_burst <= dram_req.aw.burst;
      end
      if (dram_req.w_valid && dram_rsp.w_ready) begin
        cur = dmon_addr;
        if (!dmon_act && dram_req.aw_valid && dram_rsp.aw_ready)
          cur = dram_req.aw.addr;
        if (cur >= D0 && cur < D0 + 64'h400)
          desc_stores++;
        if (dram_req.w.last) dmon_act <= 1'b0;
        else dmon_addr <= cur + (64'd1 << dmon_size);
      end
      if (notify_pulse && !doorbell_seen) begin
        doorbell_seen <= 1'b1;
        check(desc_stores > 0,
              "no D$ store into the descriptor table before doorbell");
        check(cbo_seen,
              "no committed CBO before the first doorbell");
      end
      for (int p = 0; p < $bits(rvfi0.instr.commit_instr_valid); p++) begin
        if (rvfi0.instr.commit_instr_valid[p] && rvfi0.instr.commit_ack[p]) begin
          last_pc <= 64'(rvfi0.instr.commit_instr_pc[p]);
          if (!rvfi0.instr.commit_drop[p] &&
              (rvfi0.instr.commit_instr_op[p] == ariane_pkg::CBO_FLUSH ||
               rvfi0.instr.commit_instr_op[p] == ariane_pkg::CBO_CLEAN ||
               rvfi0.instr.commit_instr_op[p] == ariane_pkg::CBO_INVAL))
            cbo_seen <= 1'b1;
        end
      end
    end
  end

  // ---- checkpoint mailbox ---------------------------------------------------
  int unsigned mbx_handled = 0;
  int unsigned f_seen_n = 0;
  logic [63:0] f_seen_id;
  logic [7:0]  f_seen_ring;
  always @(posedge clk)
    if (rst_ni && f_pulse) begin
      f_seen_n++; f_seen_id <= f_id; f_seen_ring <= f_ring;
    end

  task automatic mbx_eval(input logic [31:0] kind, input logic [31:0] ring,
                          input logic [31:0] arg, input logic [63:0] exp);
    case (kind)
      8:  check(f_seen_id == exp && f_seen_ring == 8'(ring) &&
                f_seen_n != 0, "mbx fence pulse");
      6:  check(ot_live == 16'(exp[31:0]), "mbx EK_LIVE");
      11: check($countones(vgp_free) == int'(exp[31:0]), "mbx EK_PAGES");
      7:  check(i_dram.peek32(SV_VN_SHM_BASE +
                64'(4) * (64'(r_extra[ring]) + 64'(arg >> 2))) == exp[31:0],
                "mbx EK_EXTRA");
      3:  check(r_head[ring] == exp[31:0], "mbx EK_HEAD");
      4:  check(r_status[ring] == exp[31:0], "mbx EK_STATUS");
      default: check(1'b0, "mbx kind");
    endcase
  endtask

  // ---- main ------------------------------------------------------------------
  initial begin
    assert (apu_soc_legal(ApuVenus, CoreCfg))
      else $fatal(1, "ApuVenus+2-core CoreCfg must be legal");
    assert (apu_soc_legal(OffCfg, CoreCfg))
      else $fatal(1, "VenusOff cfg+2-core CoreCfg must be legal");
    assert (apu_dram_hole_legal(OffCfg.FirmwareRamBase,
                                OffCfg.FirmwareRamBytes,
                                64'h8000_0000, 64'h4000_0000))
      else $fatal(1, "VenusOff firmware RAM must be a DRAM hole");
  end

  initial begin
    logic [63:0] cookie_v;
    logic [31:0] mseq, kind, ring, arg;
    logic [63:0] mexp;
    i_dram.load_hex("venus_probe.hex", BootPc);
    // Hart 1 park stub at ParkPc: wfi + jal x0,-4 (never traps, minimal
    // fetch bandwidth whether wfi stalls or retires as a nop).
    i_dram.poke8(ParkPc + 0, 8'h73); i_dram.poke8(ParkPc + 1, 8'h00);
    i_dram.poke8(ParkPc + 2, 8'h50); i_dram.poke8(ParkPc + 3, 8'h10);
    i_dram.poke8(ParkPc + 4, 8'h6f); i_dram.poke8(ParkPc + 5, 8'hf0);
    i_dram.poke8(ParkPc + 6, 8'hdf); i_dram.poke8(ParkPc + 7, 8'hff);
    repeat (8) @(negedge clk);
    check(fw_rdy_v, "th_load fw_ready (venus)");
    check(fw_rdy_o, "th_load fw_ready (venusoff)");
    check(boot_v[0] == CoreCfg.VLEN'(BootPc),
          "venus arm: hart 0 boots the probe");
    check(boot_o[0] == CoreCfg.VLEN'(BootPc) &&
          boot_o[1] == CoreCfg.VLEN'(64'h9000_0000),
          "venusoff arm: hart split (probe + firmware RAM)");
    rst_ni = 1'b1;
    for (;;) begin
      @(posedge clk);
      // checkpoint mailbox: the sequence word at line offset 0x3c lands
      // last in an ascending writeback burst.
      mseq = i_dram.peek32(SV_VN_MBX_ADDR + 64'h3c);
      if (!venusoff && mseq != 0 && int'(mseq) != mbx_handled) begin
        kind = i_dram.peek32(SV_VN_MBX_ADDR + 64'h00);
        ring = i_dram.peek32(SV_VN_MBX_ADDR + 64'h04);
        arg  = i_dram.peek32(SV_VN_MBX_ADDR + 64'h08);
        mexp = i_dram.peek64(SV_VN_MBX_ADDR + 64'h10);
        mbx_eval(kind, ring, arg, mexp);
        mbx_handled = int'(mseq);
        i_dram.poke8(SV_VN_MBX_ACK + 0, mseq[7:0]);
        i_dram.poke8(SV_VN_MBX_ACK + 1, mseq[15:8]);
        i_dram.poke8(SV_VN_MBX_ACK + 2, mseq[23:16]);
        i_dram.poke8(SV_VN_MBX_ACK + 3, mseq[31:24]);
      end
      cookie_v = i_dram.peek64(SV_VN_COOKIE_ADDR);
      if (cookie_v[31:16] == 16'hBAD0) begin
        if (venusoff) begin
          check(cookie_v[31:0] == 32'hBAD0_0005,
                "VenusOff arm: probe must fail at the feature check (5)");
          check(apu_aw_n == 0 && apu_ar_n == 0 && apu_w_n == 0,
                "VenusOff arm: no DMA beats");
          if (errors != 0) $fatal(1, "APU cva6 venus errors=%0d", errors);
          $display("PASS tb_g6lc_apu_cva6_venus venusoff checks=%0d cycles=%0d cookie=%08x errors=0",
                   checks, cycles, cookie_v[31:0]);
          $finish;
        end else begin
          $fatal(1, "Venus probe FAIL cookie %016x step=%02x",
                 cookie_v, cookie_v[7:0]);
        end
      end
      if (!venusoff && cookie_v[31:0] == 32'h600D_0002) begin
        check(apu_aw_n == apu_b_n, "APU write balance");
        check(apu_ar_n == apu_r_n, "APU read balance");
        check(irq_rises == irq_falls && irq_rises != 0,
              "plic_irq rise/fall pairs");
        check(pubs == irq_rises, "one used publication per IRQ rise");
        check(irq_src_v[SV_VN_IRQ_SOURCE - 1] == plic_irq,
              "plic source splice");
        check(vg_idle, "vgsys idle at pass");
        if (errors != 0) $fatal(1, "APU cva6 venus errors=%0d", errors);
        $display("PASS tb_g6lc_apu_cva6_venus checks=%0d cycles=%0d pubs=%0d irq=%0d apu_aw=%0d apu_ar=%0d apu_w=%0d fence=%0d errors=0",
                 checks, cycles, pubs, irq_rises, apu_aw_n, apu_ar_n,
                 apu_w_n, f_seen_n);
        $finish;
      end
    end
  end
endmodule
