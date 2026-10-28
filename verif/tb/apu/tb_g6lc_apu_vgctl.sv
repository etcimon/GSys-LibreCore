// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Unit test of g6lc_apu_vgctl (§6b control-queue processor) with the
// real g6lc_apu_objtab.  Directed cases: capset info/capset payloads,
// ctx create/destroy, blob create/map/unref, unknown type, a
// truncated chain, blob_id != 0, context_init != 4, and the FENCE
// flag echo/pulse.  The session-level tape covers the ring paths;
// this TB exercises the request/response edge cases directly.

module tb_g6lc_apu_vgctl;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_vgpages_pkg::*;

  localparam int unsigned GMW = 32'h40000;
  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic            ch_v = 0, ch_r;
  logic [3:0]      ch_n = '0;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] ch_d;
  logic            m_req, m_we;
  logic [63:0]     m_addr;
  logic [63:0]     m_wdata;
  logic [7:0]      m_wstrb;
  logic            m_rv = 0, m_fault;
  logic [63:0]     m_rdata = '0;
  logic            ot_v, ot_r, ot_cv, ot_cr;
  apu_objtab_req_t ot_req;
  apu_objtab_cpl_t ot_cpl;
  logic            xs_v, xs_done = 0, xs_fault = 0;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_d;
  logic [3:0]      xs_n;
  logic [31:0]     xs_off, xs_bytes;
  logic [7:0]      xs_ctx;
  logic            busy, dn;
  logic [31:0]     used_len;
  logic            f_dn;
  logic [63:0]     f_id;
  logic [7:0]      f_ring;
  logic            ck_v;
  logic [7:0]      ck_id;
  // §12.3 3d-d: relocation hold/drain — hold_o stops cmdexec dequeue,
  // drain_idle_i is the engine quiescence the mover waits on
  logic            hold;
  logic            drain_idle = 1'b1;
  int unsigned     ck_count = 0;
  logic [7:0]      ck_seen = '0;
  always @(posedge clk) if (ck_v) begin
    ck_count++; ck_seen <= ck_id;
  end

  g6lc_apu_vgctl #(.Enable(1'b1)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .chain_valid_i(ch_v), .chain_ready_o(ch_r),
    .chain_n_i(ch_n), .chain_desc_i(ch_d),
    .mem_req_o(m_req), .mem_we_o(m_we), .mem_dom_o(),
    .mem_addr_o(m_addr),
    .mem_wdata_o(m_wdata), .mem_wstrb_o(m_wstrb),
    .mem_ready_i(1'b1), .mem_rvalid_i(m_rv), .mem_rdata_i(m_rdata),
    .mem_err_i(1'b0), .mem_fault_o(m_fault),
    .ot_req_valid_o(ot_v), .ot_req_ready_i(ot_r), .ot_req_o(ot_req),
    .ot_cpl_valid_i(ot_cv), .ot_cpl_ready_o(ot_cr), .ot_cpl_i(ot_cpl),
    .pg_req_valid_o(pg_v), .pg_req_ready_i(pg_r), .pg_req_o(pg_req),
    .pg_cpl_valid_i(pg_cv), .pg_cpl_ready_o(pg_cr), .pg_cpl_i(pg_cpl),
    // §5a G3b-iii: the RESET_CTX reap drives real ObjPay/cmdrec
    // clients (F7) — the B1 arm builds context-owned buffers and
    // verifies the whole block/chain set returns to the allocator
    .op_req_valid_o(vg_op_v), .op_req_ready_i(vg_op_r),
    .op_req_o(vg_op_req),
    .op_cpl_valid_i(pay_cv && pay_own == 2'd0),
    .op_cpl_ready_o(), .op_cpl_i(pay_c),
    .cr_req_valid_o(vg_cr_v), .cr_req_ready_i(vg_cr_r),
    .cr_req_o(vg_cr_req),
    .cr_cpl_valid_i(cr_cv), .cr_cpl_ready_o(), .cr_cpl_i(cr_c),
    .sm_req_o(), .sm_req_pl_o(), .sm_gnt_i(1'b0),
    .sm_cpl_i(1'b0), .sm_cpl_pl_i('0),
    .xs_valid_o(xs_v), .xs_ready_i(1'b0),
    .xs_desc_o(xs_d), .xs_ndesc_o(xs_n), .xs_off_o(xs_off),
    .xs_bytes_o(xs_bytes), .xs_ctx_o(xs_ctx),
    .xs_done_i(xs_done), .xs_fault_i(xs_fault),
    .ctx_kill_valid_o(ck_v), .ctx_kill_id_o(ck_id),
    .hold_o(hold), .drain_idle_i(drain_idle),
    .busy_o(busy), .done_o(dn), .used_len_o(used_len),
    .fence_done_o(f_dn), .fence_id_o(f_id), .fence_ring_o(f_ring));

  // ---- objmem plumbing (ObjTab-V DRAM backing) --------------------
  localparam int unsigned ObjEntries = 256;
  localparam int unsigned PayMemB    = 64 * 1024;
  logic         omt_v, omt_r, omt_rv;
  apu_omt_req_t omt_req;
  apu_omt_rsp_t omt_rsp;
  logic         ompr_r, ompr_rv;
  apu_omp_rsp_t ompr_rsp;
  logic         mmp_v, mmp_r, mmp_rv;
  apu_mp_req_t  mmp_req;
  apu_mp_rsp_t  mmp_rsp;

  // F7 arm: the TB shares the ObjTab port for entry setup (the
  // vnfront role); the DUT always wins, the TB drives only between
  // chains, and tot_own routes the completion + releases cpl_ready
  logic            tot_v = 0, tot_r;
  apu_objtab_req_t tot_req = '0;
  logic            tot_own = 0;
  apu_objtab_cpl_t tcc;

  g6lc_apu_objtab #(.Enable(1'b1), .ObjEntries(ObjEntries)) i_tab (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(ot_v | tot_v), .req_ready_o(ot_r),
    .req_i(ot_v ? ot_req : tot_req),
    .cpl_valid_o(ot_cv), .cpl_ready_i(ot_cr | tot_own),
    .cpl_o(ot_cpl),
    .live_o(),
    .omt_req_valid_o(omt_v), .omt_req_ready_i(omt_r),
    .omt_req_o(omt_req),
    .omt_rsp_valid_i(omt_rv), .omt_rsp_i(omt_rsp));

  g6lc_apu_objmem #(.Enable(1'b1), .ObjEntries(ObjEntries),
                    .PayMemBytes(PayMemB),
                    .DirCacheSets(16), .EntCacheLines(8),
                    .PayCacheLines(4)) i_omm (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .omt_req_valid_i(omt_v), .omt_req_ready_o(omt_r),
    .omt_req_i(omt_req),
    .omt_rsp_valid_o(omt_rv), .omt_rsp_o(omt_rsp),
    .omp_req_valid_i(omp_v), .omp_req_ready_o(ompr_r),
    .omp_req_i(omp_req),
    .omp_rsp_valid_o(ompr_rv), .omp_rsp_o(ompr_rsp),
    .mp_req_valid_o(mmp_v), .mp_req_ready_i(mmp_r),
    .mp_req_o(mmp_req),
    .mp_rsp_valid_i(mmp_rv), .mp_rsp_i(mmp_rsp));

  // objmem's own aperture responder over the static carve window
  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(0),
                  .PWB(32'(APU_OBJMEM_OFF >> 2)),
                  .PPW(32'((apu_objmem_pay_off(ObjEntries) +
                            64'(PayMemB) - APU_OBJMEM_OFF) >> 2) +
                        64))
      i_omem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(mmp_v), .req_ready_o(mmp_r), .req_i('{mmp_req}),
    .rsp_valid_o(mmp_rv), .rsp_o('{mmp_rsp}));

  // §7b: the page allocator lives outside vgctl now
  logic            pg_v, pg_r, pg_cv, pg_cr;
  apu_vgpages_req_t pg_req;
  apu_vgpages_cpl_t pg_cpl;
  // §12.3 F5: 48 guest pages + 16 device-private pages so ALLOC_PRIV
  // (blob-owned backing, device memory) has an arena to serve
  g6lc_apu_vgpages #(.Enable(1'b1), .Pages(512), .GuestPages(256)) i_pages (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(pg_v), .req_ready_o(pg_r), .req_i(pg_req),
    .cpl_valid_o(pg_cv), .cpl_ready_i(pg_cr), .cpl_o(pg_cpl));

  // ---- reap client plumbing: real cmdrec + ObjPay -------------------
  // Requester muxes mirror vgtop's order (cmdrec > vgctl > TB); the
  // TB half only drives between chains, when both DUT clients idle.
  logic            vg_op_v, vg_op_r;
  apu_objpay_req_t vg_op_req;
  logic            vg_cr_v, vg_cr_r;
  apu_cmdrec_req_t vg_cr_req;

  logic            omp_v;
  apu_omp_req_t    omp_req;

  logic            cop_v, cop_r;
  apu_objpay_req_t cop_req;
  logic            tb_op_v = 0, tb_op_r;
  apu_objpay_req_t tb_op_req = '0;
  logic            pay_req_v, pay_r, pay_cv;
  apu_objpay_req_t pay_req;
  apu_objpay_cpl_t pay_c;
  logic [1:0]      pay_own = 2'd0;   // 0 vgctl / 1 cmdrec / 2 TB
  apu_objpay_cpl_t tpc;

  assign pay_req_v = cop_v | vg_op_v | tb_op_v;
  assign pay_req   = cop_v ? cop_req
                     : vg_op_v ? vg_op_req : tb_op_req;
  assign cop_r   = cop_v & pay_r;
  assign vg_op_r = !cop_v & vg_op_v & pay_r;
  // TB-side "safe to drive now" — independent of tb_op_v so the
  // task's wait-then-drive protocol can see it
  assign tb_op_r = !cop_v & !vg_op_v & pay_r;

  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) pay_own <= 2'd0;
    else if (pay_req_v && pay_r)
      pay_own <= cop_v ? 2'd1 : vg_op_v ? 2'd0 : 2'd2;

  logic            tcr_v = 0, tcr_r;
  apu_cmdrec_req_t tcr_req = '0;
  logic            cr_req_v, cr_r, cr_cv;
  apu_cmdrec_req_t cr_req;
  apu_cmdrec_cpl_t cr_c;
  logic            tpay_v = 0, tpay_r;
  logic [31:0]     tpay_d = '0;
  apu_cmdrec_cpl_t tccr;

  assign cr_req_v = vg_cr_v | tcr_v;
  assign cr_req   = vg_cr_v ? vg_cr_req : tcr_req;
  assign vg_cr_r  = vg_cr_v & cr_r;
  assign tcr_r    = !vg_cr_v & cr_r;

  g6lc_apu_cmdrec #(.Enable(1'b1), .CbOpen(4)) i_rec (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(cr_req_v), .req_ready_o(cr_r), .req_i(cr_req),
    .cpl_valid_o(cr_cv), .cpl_ready_i(1'b1), .cpl_o(cr_c),
    .pay_valid_i(tpay_v), .pay_data_i(tpay_d), .pay_ready_o(tpay_r),
    .op_req_valid_o(cop_v), .op_req_ready_i(cop_r),
    .op_req_o(cop_req),
    .op_cpl_valid_i(pay_cv && pay_own == 2'd1), .op_cpl_ready_o(),
    .op_cpl_i(pay_c));

  g6lc_apu_objpay #(.Enable(1'b1), .PayMemBytes(PayMemB)) i_pay (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(pay_req_v), .req_ready_o(pay_r), .req_i(pay_req),
    .cpl_valid_o(pay_cv), .cpl_ready_i(1'b1), .cpl_o(pay_c),
    .omp_req_valid_o(omp_v), .omp_req_ready_i(ompr_r),
    .omp_req_o(omp_req),
    .omp_rsp_valid_i(ompr_rv), .omp_rsp_i(ompr_rsp));

  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) tot_own <= 1'b0;
    else begin
      if (ot_cv && tot_own) tot_own <= 1'b0;
      if (tot_v && tot_r)   tot_own <= 1'b1;
    end
  assign tot_r = !ot_v & ot_r;

  logic [31:0] gmem [GMW];
  // handshake guest-memory model: ready=1, one rvalid next cycle;
  // returns the aligned 64-bit beat containing the request address
  // (vgctl picks the half by addr[2]); writes apply wstrb bytes.
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      m_rv <= 1'b0; m_rdata <= '0;
    end else begin
      m_rv <= 1'b0;
      if (m_req && !m_we)
        begin m_rv <= 1'b1;
          m_rdata <= {gmem[((m_addr[31:0] >> 2) & ~32'h1) + 1],
                      gmem[(m_addr[31:0] >> 2) & ~32'h1]}; end
      else if (m_req && m_we) begin
        m_rv <= 1'b1;
        // wstrb/wdata are beat-positioned; byte b lands in word
        // (m_addr & ~7)>>2 + b[2] at byte lane b[1:0]
        for (int b = 0; b < 8; b++)
          if (m_wstrb[b])
            gmem[32'((m_addr[31:0] >> 3) * 2) + (b >= 4 ? 1 : 0)]
                [b[1:0] * 8 +: 8] <= m_wdata[b * 8 +: 8];
      end
    end
  end

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  task automatic check(input bit ok, input string msg);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (t=%0d)", msg, cycles);
      if (errors > 40) $fatal(1, "too many errors");
    end
  endtask

  localparam logic [63:0] GREQ  = 64'h4000;
  localparam logic [63:0] GRESP = 64'h10000;

  // write request words into guest memory, submit {req,resp} chain,
  // wait done, return with response checked by the caller
  task automatic run_chain(input int unsigned nreq,
                           input int unsigned nresp_bytes);
    ch_d[0] = '{addr: GREQ, len: 32'(nreq * 4), write: 1'b0,
                default: '0};
    ch_d[1] = '{addr: GRESP, len: 32'(nresp_bytes), write: 1'b1,
                default: '0};
    ch_d[2] = '0; ch_d[3] = '0;
    ch_n = 4'd2;
    // wait for the previous chain to finish completely (done is a
    // pulse; a FENCE response spends one extra cycle in StFence)
    begin
      int unsigned t = 0;
      while (!ch_r && t < 2_000_000) begin @(posedge clk); t++; end
      check(ch_r, "vgctl not idle before chain");
    end
    // accept = chain_ready_o drops (FSM latched the chain and left
    // StIdle); hold valid until then, then wait for the done pulse
    ch_v = 1;
    begin
      int unsigned t = 0;
      @(posedge clk);
      while (ch_r && t < 1000) begin @(posedge clk); t++; end
      check(!ch_r, "chain not accepted");
    end
    ch_v = 0;
    begin
      int unsigned t = 0;
      // done_o is a one-cycle pulse; sample mid-cycle at negedge
      while (!dn && t < 2_000_000) begin @(negedge clk); t++; end
      check(dn, "done timeout");
      @(posedge clk);
    end
    cases++;
  endtask

  task automatic wr(input int unsigned i, input logic [31:0] w);
    gmem[32'(GREQ >> 2) + i] = w;
  endtask
  function automatic logic [31:0] resp(input int unsigned i);
    return gmem[32'(GRESP >> 2) + i];
  endfunction

  // fence-pulse observability: NBA-only writes (no mixed blocking/
  // nonblocking on the same variable in the TB)
  int unsigned f_count = 0;
  logic [63:0] f_seen_id;
  logic [7:0]  f_seen_ring;
  always @(posedge clk or negedge rst_ni)
    if (!rst_ni) begin
      f_count <= 0; f_seen_id <= '0; f_seen_ring <= '0;
    end else if (f_dn) begin
      f_count <= f_count + 1;
      f_seen_id <= f_id; f_seen_ring <= f_ring;
    end

  // response header builder check: type at resp[0]
  task automatic exp_resp(input logic [31:0] ty);
    check(resp(0) == ty,
          $sformatf("resp type got=%08x exp=%08x", resp(0), ty));
  endtask

  // ---- F7-arm drivers: the TB plays the vnfront role ---------------
  // ObjTab entry alloc/setaux on the shared port, ObjPay block ops on
  // the lowest-priority requester, and cmdrec BEGIN/APPEND/END/READ —
  // all strictly between vgctl chains, so no arbitration is needed.
  task automatic top(input apu_objtab_op_e o, input logic [63:0] id,
                     input logic [5:0] kind, input logic [7:0] ctx,
                     input logic [63:0] off, input logic [63:0] sz,
                     input logic [31:0] msk, input logic [31:0] val);
    @(negedge clk);
    while (!tot_r) @(negedge clk);
    tot_v   = 1'b1;
    tot_req = '{op: o, id: id, kind: kind, ctx: ctx, offset: off,
                size: sz, mask: msk, value: val, default: '0};
    @(posedge clk); @(negedge clk); tot_v = 1'b0;
  endtask
  task automatic tget();
    while (!(ot_cv && tot_own)) @(negedge clk);
    tcc = ot_cpl;
    @(posedge clk); @(negedge clk);
  endtask
  task automatic pop(input apu_objpay_op_e o, input logic [31:0] a,
                     input logic [31:0] w, input logic [31:0] d);
    @(negedge clk);
    while (!tb_op_r) @(negedge clk);
    tb_op_v   = 1'b1;
    tb_op_req = '{op: o, addr: a, words: w, wdata: d};
    @(posedge clk); @(negedge clk); tb_op_v = 1'b0;
  endtask
  task automatic pget();
    while (!(pay_cv && pay_own == 2'd2)) @(negedge clk);
    tpc = pay_c;
    @(posedge clk); @(negedge clk);
  endtask
  task automatic crq(input apu_cmdrec_op_e o, input logic [31:0] cbd,
                     input logic [15:0] ix, input logic [31:0] fl,
                     input apu_cmdrec_rec_t r, input int pn);
    @(negedge clk);
    while (!tcr_r) @(negedge clk);
    tcr_v   = 1'b1;
    tcr_req = '{op: o, cbd: cbd, idx: ix, pay_n: 16'(pn), flags: fl,
                rec: r};
    @(posedge clk); @(negedge clk); tcr_v = 1'b0;
  endtask
  task automatic crget();
    // one outstanding TB op at a time and the vgctl client is idle
    // between chains, so a cr_cv beat here is ours by construction
    while (!cr_cv) @(negedge clk);
    tccr = cr_c;
    @(posedge clk); @(negedge clk);
  endtask
  task automatic capp(input logic [31:0] cbd, input logic [31:0] tag,
                      input int pn, input apu_cmdrec_status_e est);
    crq(APU_CMDREC_OP_APPEND, cbd, '0, '0, mkrec(tag), pn);
    for (int i = 0; i < pn; i++) begin
      @(negedge clk);
      while (!tpay_r) @(negedge clk);
      tpay_v = 1'b1; tpay_d = tag + 32'(i);
      @(posedge clk); @(negedge clk); tpay_v = 1'b0;
    end
    crget();
    check(tccr.status == est,
          $sformatf("cb append cbd=%08x tag=%08x st=%0d",
                    cbd, tag, tccr.status));
  endtask
  function automatic apu_cmdrec_rec_t mkrec(input logic [31:0] tag);
    apu_cmdrec_rec_t r;
    r = '0;
    r.ctype  = 32'hC000_0000 | tag;
    r.imm[0] = tag;
    return r;
  endfunction
  // vnfront's 12-word descriptor init: flags/chain words zero, the
  // pool and own handles parked, the pool-chain links spliced
  task automatic cbdesc(input logic [31:0] cbd,
                        input logic [31:0] poolh,
                        input logic [31:0] ownh,
                        input logic [31:0] prev,
                        input logic [31:0] next);
    for (int w = 0; w < 12; w++) begin
      logic [31:0] d;
      case (w)
        APU_CBD_POOL:  d = poolh;
        APU_CBD_OWN:   d = ownh;
        APU_CBD_PPREV: d = prev;
        APU_CBD_PNEXT: d = next;
        default:       d = 32'h0;
      endcase
      pop(APU_OBJPAY_OP_WRITE, cbd + 32'(w), 32'd1, d);
      pget();
      check(tpc.status == APU_OBJPAY_OK, "cbdesc write");
    end
  endtask

  initial begin
    for (int i = 0; i < GMW; i++) gmem[i] = '0;
    repeat (8) @(posedge clk);
    rst_ni = 1;
    repeat (4) @(posedge clk);

    // ---- A1: GET_CAPSET_INFO idx 0 -------------------------------------
    // hdr 6w {type,flags,fence_lo,fence_hi,ctx,ring} + body {idx,pad}
    wr(0, 32'h0108); wr(1, 0); wr(2, 0); wr(3, 0); wr(4, 0); wr(5, 0);
    wr(6, 0); wr(7, 0);
    run_chain(8, 40);
    exp_resp(APU_VG_RESP_CAPSET_INFO);
    check(resp(6) == 4,  "capset id 4");
    check(resp(7) == 1,  "capset max_version 1");
    check(resp(8) == 160, "capset size 160");
    check(used_len == 8 * 4 + 40, "capset-info used_len");

    // ---- A2: GET_CAPSET id 4 ---------------------------------------------
    wr(0, 32'h0109); wr(6, 4); wr(7, 0);
    run_chain(8, 24 + 160);
    exp_resp(APU_VG_RESP_CAPSET);
    check(resp(6) == APU_VN_CAPSET[0], "capset[0] wire fmt");
    check(resp(6 + 39) == APU_VN_CAPSET[39], "capset[39]");
    check(used_len == 32 + 24 + 160, "capset used_len");

    // ---- A3: CTX_CREATE ctx=4 context_init=4 ------------------------------
    wr(0, 32'h0200); wr(4, 4);
    wr(6, 12);           // nlen
    wr(7, 4);            // context_init = 4 -> Venus
    for (int i = 0; i < 16; i++) wr(8 + i, 0);
    run_chain(24, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A4: CREATE_BLOB valid (rid 10, 8 KiB) ----------------------------
    wr(0, 32'h010C); wr(4, 4);
    wr(6, 10);           // resource_id
    wr(7, APU_VG_BLOB_HOST3D);
    wr(8, APU_VG_BLOB_MAPPABLE);
    wr(9, 0);            // pad
    wr(10, 0);           // blob_id 0
    wr(11, 0);
    wr(12, 32'h2000); wr(13, 0);   // size 8 KiB
    run_chain(14, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A5: MAP_BLOB rid 10 -> MAP_INFO {WC,0} ----------------------------
    wr(0, 32'h0208); wr(4, 4);
    wr(6, 10); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 32);
    exp_resp(APU_VG_RESP_MAP_INFO);
    check(resp(6) == 3, "map WC");
    check(resp(7) == 0, "map pad");

    // ---- A6: UNMAP_BLOB --------------------------------------------------
    wr(0, 32'h0209); wr(6, 10); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- A7: UNREF rid 10 ---------------------------------------------------
    wr(0, 32'h0102); wr(6, 10); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_RESP_NODATA);

    // ---- C1: unknown type 0x0999 -> ERR_UNSPEC -------------------------------
    wr(0, 32'h0999); wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_UNSPEC);

    // ---- C2: truncated chain: header alone (6w) declares CTX_CREATE ---------
    wr(0, 32'h0200);
    run_chain(6, 24);
    exp_resp(APU_VG_ERR_PARAM);
    check(used_len == 24 + 24, "truncated used_len");

    // ---- C3: CREATE_BLOB blob_id != 0, unknown memory -> ERR_RID -----
    // 5a-ii: blob_id != 0 resolves a VkDeviceMemory object of that id;
    // no such object here -> the resource-refusal path (ERR_RID).
    wr(0, 32'h010C); wr(4, 4);
    wr(6, 20); wr(7, APU_VG_BLOB_HOST3D);
    wr(8, APU_VG_BLOB_MAPPABLE); wr(9, 0);
    wr(10, 0); wr(11, 1);          // blob_id = 1<<32 (unknown memory)
    wr(12, 32'h1000); wr(13, 0);
    run_chain(14, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- C4: CTX_CREATE context_init = 5 -> ERR_PARAM ------------------------
    wr(0, 32'h0200); wr(4, 7);
    wr(6, 4); wr(7, 5);
    for (int i = 0; i < 16; i++) wr(8 + i, 0);
    run_chain(24, 24);
    exp_resp(APU_VG_ERR_PARAM);

    // ---- C5: MAP_BLOB unknown rid -> ERR_RESOURCE ----------------------------
    wr(0, 32'h0208); wr(4, 4);
    wr(6, 77); wr(7, 0); wr(8, 0); wr(9, 0);
    run_chain(10, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- C6: UNREF unknown rid -> ERR_RESOURCE --------------------------------
    wr(0, 32'h0102); wr(6, 77); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_RID);

    // ---- F1: FENCE echo on a NODATA response -----------------------------------
    begin int unsigned fc0 = f_count;
    wr(0, 32'h0999);
    wr(1, APU_VG_FLAG_FENCE);
    wr(2, 32'h1234); wr(3, 32'h5678);
    wr(4, 0); wr(5, 2);
    wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_ERR_UNSPEC);
    check((resp(1) & APU_VG_FLAG_FENCE) != 32'h0,
          "fence flag echoed");
    check(resp(2) == 32'h1234 && resp(3) == 32'h5678,
          "fence id echoed");
    check(resp(5) == 2, "ring_idx echoed");
    // the fence pulse fires in StFence, one cycle after done_o
    begin
      int unsigned t = 0;
      while (f_count == fc0 && t < 100) begin @(posedge clk); t++; end
      check(f_count == fc0 + 1 &&
            f_seen_id == 64'h00005678_00001234 && f_seen_ring == 2,
            "fence pulse");
    end
    end

    // ---- B1: RESET_CTX command-buffer reap (F7) -------------------
    // ctx 9 owns a pool and three command buffers — one left
    // RECORDING, one SEALED, one allocated but never BEGIN'd.  Each
    // swept buffer must go through cmdrec RESET (both chunk chains
    // freed and the CbOpen entry evicted) before its descriptor block
    // returns to ObjPay, and the reallocated blocks must then serve
    // BEGIN/APPEND/READ with no stale state.
    wr(0, 32'h0200); wr(4, 9);
    wr(6, 12); wr(7, 4);
    for (int i = 0; i < 16; i++) wr(8 + i, 0);
    run_chain(24, 24);
    exp_resp(APU_VG_RESP_NODATA);

    begin
      logic [31:0] cbd  [3];
      logic [31:0] ownh [3];
      logic [31:0] poolh, used0;
      int unsigned ck0;

      // allocator baseline: warmup alloc+free so the reserved-chunk
      // bookkeeping is settled before the snapshot
      pop(APU_OBJPAY_OP_ALLOC, '0, 32'(APU_CBD_WORDS), '0);
      pget();
      check(tpc.status == APU_OBJPAY_OK, "B1 warmup alloc");
      pop(APU_OBJPAY_OP_FREE, tpc.base, 32'(APU_CBD_WORDS), '0);
      pget();
      used0 = i_pay.gen_on.used_q;

      top(APU_OBJTAB_OP_ALLOC, APU_VN_ID_TAG | 64'hB1,
          6'(APU_VN_KIND_VK_COMMAND_POOL), 8'd9, '0, '0, '0, '0);
      tget();
      check(tcc.status == APU_OBJTAB_OK, "B1 pool entry");
      poolh = tcc.handle;

      for (int c = 0; c < 3; c++) begin
        pop(APU_OBJPAY_OP_ALLOC, '0, 32'(APU_CBD_WORDS), '0);
        pget();
        check(tpc.status == APU_OBJPAY_OK, "B1 desc alloc");
        cbd[c] = tpc.base;
        top(APU_OBJTAB_OP_ALLOC, APU_VN_ID_TAG | 64'(32'hB2 + c),
            6'(APU_VN_KIND_VK_COMMAND_BUFFER), 8'd9,
            {cbd[c], 32'h0}, '0, '0, '0);
        tget();
        check(tcc.status == APU_OBJTAB_OK, "B1 cb entry");
        ownh[c] = tcc.handle;
        cbdesc(cbd[c], poolh, ownh[c],
               c == 0 ? 32'h0 : cbd[c-1], 32'h0);
        if (c != 0) begin
          pop(APU_OBJPAY_OP_WRITE, cbd[c-1] + 32'(APU_CBD_PNEXT),
              32'd1, cbd[c]);
          pget();
          check(tpc.status == APU_OBJPAY_OK, "B1 chain splice");
        end
        if (c == 0) begin
          top(APU_OBJTAB_OP_SETAUXHI, APU_VN_ID_TAG | 64'hB1,
              6'(APU_VN_KIND_VK_COMMAND_POOL), 8'd9,
              '0, '0, 32'hFFFF_FFFF, cbd[0]);
          tget();
          check(tcc.status == APU_OBJTAB_OK, "B1 pool head");
        end
      end

      // CB0 stays RECORDING; CB1 ends SEALED with a payload chunk;
      // CB2 is descriptor-only — every ownership shape the reap meets
      crq(APU_CMDREC_OP_BEGIN, cbd[0], '0, '0, '0, 0);
      crget();
      check(tccr.status == APU_CMDREC_OK, "B1 cb0 begin");
      capp(cbd[0], 32'h6000, 0, APU_CMDREC_OK);
      capp(cbd[0], 32'h6001, 0, APU_CMDREC_OK);
      crq(APU_CMDREC_OP_BEGIN, cbd[1], '0, '0, '0, 0);
      crget();
      check(tccr.status == APU_CMDREC_OK, "B1 cb1 begin");
      capp(cbd[1], 32'h6100, 2, APU_CMDREC_OK);
      crq(APU_CMDREC_OP_END, cbd[1], '0, '0, '0, 0);
      crget();
      check(tccr.status == APU_CMDREC_OK, "B1 cb1 end");

      ck0 = ck_count;
      wr(0, 32'h0201); wr(1, 0); wr(2, 0); wr(3, 0); wr(4, 9);
      wr(5, 0); wr(6, 0); wr(7, 0);
      run_chain(8, 24);
      exp_resp(APU_VG_RESP_NODATA);
      check(ck_count == ck0 + 1 && ck_seen == 8'd9,
            "B1 ctx kill pulse ctx=9");
      check(i_pay.gen_on.used_q == used0,
            $sformatf("B1 objpay restored got=%0d exp=%0d",
                      i_pay.gen_on.used_q, used0));

      // sweep ALLOC until the three reaped descriptor chunks are
      // handed out again — the next-fit cursor walks forward on every
      // ALLOC, so non-matching chunks are returned and the scan makes
      // progress; a stale CbOpen entry at a reused address would
      // corrupt the BEGIN/APPEND/READ sequence below
      begin
        logic [31:0] ncbd [3];
        int unsigned got = 0, iters = 0;
        while (got < 3 && iters < 24) begin
          iters++;
          pop(APU_OBJPAY_OP_ALLOC, '0, 32'(APU_CBD_WORDS), '0);
          pget();
          check(tpc.status == APU_OBJPAY_OK, "B1 realloc sweep");
          if (tpc.base == cbd[0] || tpc.base == cbd[1] ||
              tpc.base == cbd[2]) begin
            ncbd[got] = tpc.base;
            got++;
          end else begin
            pop(APU_OBJPAY_OP_FREE, tpc.base, 32'(APU_CBD_WORDS), '0);
            pget();
          end
        end
        check(got == 3, $sformatf("B1 block reuse %0d/3", got));
        for (int c = 0; c < got; c++) begin
          cbdesc(ncbd[c], '0, '0, '0, '0);
          crq(APU_CMDREC_OP_BEGIN, ncbd[c], '0, '0, '0, 0);
          crget();
          check(tccr.status == APU_CMDREC_OK, "B1 re-begin");
          for (int i = 0; i < 3; i++)
            capp(ncbd[c], 32'h7000 + 32'(c * 16 + i), 0,
                 APU_CMDREC_OK);
          crq(APU_CMDREC_OP_END, ncbd[c], '0, '0, '0, 0);
          crget();
          check(tccr.status == APU_CMDREC_OK, "B1 re-end");
          crq(APU_CMDREC_OP_COUNT, ncbd[c], '0, '0, '0, 0);
          crget();
          check(tccr.status == APU_CMDREC_OK &&
                tccr.count == 32'd3, "B1 re-count");
          for (int i = 0; i < 3; i++) begin
            crq(APU_CMDREC_OP_READ, ncbd[c], 16'(i), '0, '0, 0);
            crget();
            check(tccr.status == APU_CMDREC_OK &&
                  tccr.rec.imm[0] == 32'h7000 + 32'(c * 16 + i),
                  "B1 re-read");
          end
        end
        for (int c = 0; c < got; c++) begin
          crq(APU_CMDREC_OP_RESET, ncbd[c], '0, '0, '0, 0);
          crget();
          check(tccr.status == APU_CMDREC_OK, "B1 re-reset");
          pop(APU_OBJPAY_OP_FREE, ncbd[c], 32'(APU_CBD_WORDS), '0);
          pget();
        end
        check(i_pay.gen_on.used_q == used0, "B1 objpay drained");
      end
    end

    // ---- CTX_DESTROY ctx 4 (teardown) -----------------------------------------
    wr(0, 32'h0201); wr(1, 0); wr(2, 0); wr(3, 0); wr(4, 4); wr(5, 0);
    wr(6, 0); wr(7, 0);
    run_chain(8, 24);
    exp_resp(APU_VG_RESP_NODATA);
    // §12.3 5b-r2: the kill pulse for vnpump fires on CTX_DESTROY —
    // this is the second destroy (B1 destroyed ctx 9 above)
    check(ck_count == 2 && ck_seen == 8'd4, "ctx kill pulse ctx=4");

    if (errors == 0)
      $display("PASS tb_g6lc_apu_vgctl cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    else
      $display("FAIL tb_g6lc_apu_vgctl cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
