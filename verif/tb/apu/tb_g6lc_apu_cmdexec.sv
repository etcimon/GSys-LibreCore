// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Integration test of g6lc_apu_cmdexec against the real g6lc_apu_cmdrec
// and g6lc_apu_objtab.  The TB owns the request ports during setup
// (allocating objects, recording buffers) then hands them to the
// executor.  The work port is modelled with a few-cycle accept plus a
// deferred work_done_i completion.
//
// Cases: ordered work issue across one submit, multi-buffer submit,
// pipeline-barrier drain, stale-record handle -> DEVICE_LOST, unsealed
// buffer -> DEVICE_LOST, fence clear, Enable=0 quiet.
module tb_g6lc_apu_cmdexec;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;

  localparam int Fences = 16;
  localparam int Slots  = 64;

  logic clk = 0, rst_ni = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- executor ports ------------------------------------------------
  logic               sub_v = 0, sub_r;
  apu_cmdexec_submit_t sub;
  logic               xcr_v, xcr_r;
  apu_cmdrec_req_t    xcr_req;
  logic               xcr_cv, xcr_cr;
  apu_cmdrec_cpl_t    xcr_cpl;
  logic               xot_v, xot_r;
  apu_objtab_req_t    xot_req;
  logic               xot_cv, xot_cr;
  apu_objtab_cpl_t    xot_cpl;
  logic               w_v, w_r = 0;
  apu_cmdexec_work_t  w_o;
  logic               w_done = 0;
  logic [15:0]        done_seq;
  logic [Fences-1:0]  fsig, flost, fclr = '0;
  logic               osub_r, ow_v, oxcr_v, oxcr_cr, oxot_v, oxot_cr;
  logic [15:0]        odone;
  logic [Fences-1:0]  ofsig, oflost;
  apu_cmdexec_work_t  ow_o;
  apu_cmdrec_req_t    oxcr_req;
  apu_objtab_req_t    oxot_req;
  // §7b/5a-ii: ObjPay port + shcore dispatch sideband.  No bound
  // descriptor sets in this TB, so the ObjPay request is never driven;
  // work_done carries a constant OK payload.
  logic               xop_v, oop_v, xop_cr, oop_cr;
  apu_objpay_req_t    xop_req, oop_req;
  apu_sh_done_t       w_done_pl;
  logic [2:0]         dslot, odslot;
  logic [16*113-1:0]  dbinds, odbinds;
  logic [5:0]         dpushn, odpushn;
  logic [1023:0]      dpush, odpush;
  assign w_done_pl = '{code: APU_SH_DONE_OK, default: '0};

  g6lc_apu_cmdexec #(.Enable(1'b1), .Fences(Fences)) i_dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .submit_valid_i(sub_v), .submit_ready_o(sub_r), .submit_i(sub),
    .cr_req_valid_o(xcr_v), .cr_req_ready_i(xcr_r), .cr_req_o(xcr_req),
    .cr_cpl_valid_i(xcr_cv), .cr_cpl_ready_o(xcr_cr), .cr_cpl_i(xcr_cpl),
    .ot_req_valid_o(xot_v), .ot_req_ready_i(xot_r), .ot_req_o(xot_req),
    .ot_cpl_valid_i(xot_cv), .ot_cpl_ready_o(xot_cr), .ot_cpl_i(xot_cpl),
    .op_req_valid_o(xop_v), .op_req_ready_i(1'b1), .op_req_o(xop_req),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(xop_cr), .op_cpl_i('0),
    .work_valid_o(w_v), .work_ready_i(w_r), .work_o(w_o),
    .work_done_i(w_done), .work_done_pl_i(w_done_pl),
    .disp_slot_o(dslot), .binds_o(dbinds),
    .push_n_o(dpushn), .push_o(dpush),
    .done_seq_o(done_seq),
    .fence_signaled_o(fsig), .fence_lost_o(flost),
    .fence_clr_i(fclr));
  g6lc_apu_cmdexec_fixture #(.Enable(1'b0), .Fences(Fences)) i_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .submit_valid_i(sub_v), .submit_ready_o(osub_r), .submit_i(sub),
    .cr_req_valid_o(oxcr_v), .cr_req_ready_i(xcr_r), .cr_req_o(oxcr_req),
    .cr_cpl_valid_i(xcr_cv), .cr_cpl_ready_o(oxcr_cr), .cr_cpl_i(xcr_cpl),
    .ot_req_valid_o(oxot_v), .ot_req_ready_i(xot_r), .ot_req_o(oxot_req),
    .ot_cpl_valid_i(xot_cv), .ot_cpl_ready_o(oxot_cr), .ot_cpl_i(xot_cpl),
    .op_req_valid_o(oop_v), .op_req_ready_i(1'b1), .op_req_o(oop_req),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(oop_cr), .op_cpl_i('0),
    .work_valid_o(ow_v), .work_ready_i(w_r), .work_o(ow_o),
    .work_done_i(w_done), .work_done_pl_i(w_done_pl),
    .disp_slot_o(odslot), .binds_o(odbinds),
    .push_n_o(odpushn), .push_o(odpush),
    .done_seq_o(odone),
    .fence_signaled_o(ofsig), .fence_lost_o(oflost),
    .fence_clr_i(fclr));

  // ---- backend mux: TB setup vs executor ------------------------------
  // The real cmdrec/objtab buses fan out to both masters; tb_drv selects
  // who drives req_valid/req payload (completions are broadcast).
  logic tb_drv = 1'b1;
  logic tcr_v = 0, tcr_r, tcr_cv;
  apu_cmdrec_req_t tcr_req;
  logic tot_v = 0, tot_r, tot_cv;
  apu_objtab_req_t tot_req;

  logic            cr_rdy, cr_cvld;
  apu_cmdrec_cpl_t cr_cpl;
  logic            ot_rdy, ot_cvld;
  apu_objtab_cpl_t ot_cpl;
  assign tcr_r  = cr_rdy;  assign xcr_r  = cr_rdy;
  assign tcr_cv = cr_cvld; assign xcr_cv = cr_cvld;
  assign xcr_cpl = cr_cpl;
  assign tot_r  = ot_rdy;  assign xot_r  = ot_rdy;
  assign tot_cv = ot_cvld; assign xot_cv = ot_cvld;
  assign xot_cpl = ot_cpl;

  wire cr_vld  = tb_drv ? tcr_v   : xcr_v;
  wire ot_vld  = tb_drv ? tot_v   : xot_v;
  wire cr_crdy = tb_drv ? 1'b1    : xcr_cr;
  wire ot_crdy = tb_drv ? 1'b1    : xot_cr;
  wire apu_cmdrec_req_t cr_req = tb_drv ? tcr_req : xcr_req;
  wire apu_objtab_req_t ot_req = tb_drv ? tot_req : xot_req;

  logic        tpay_v = 1'b0, tpay_r;
  logic [31:0] tpay_d = '0;

  g6lc_apu_cmdrec #(.Enable(1'b1)) i_rec (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(cr_vld), .req_ready_o(cr_rdy), .req_i(cr_req),
    .cpl_valid_o(cr_cvld), .cpl_ready_i(cr_crdy), .cpl_o(cr_cpl),
    .pay_valid_i(tpay_v), .pay_data_i(tpay_d),
    .pay_ready_o(tpay_r));
  g6lc_apu_objtab #(.Enable(1'b1), .Slots(Slots)) i_obj (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(ot_vld), .req_ready_o(ot_rdy), .req_i(ot_req),
    .cpl_valid_o(ot_cvld), .cpl_ready_i(ot_crdy), .cpl_o(ot_cpl),
    .live_o());

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(negedge clk) if (ow_v || oxcr_v || oxcr_cr || oxot_v ||
                            oxot_cr || oop_v || oop_cr || osub_r ||
                            odone !== '0 || ofsig !== '0 ||
                            oflost !== '0 || odslot !== '0 ||
                            odbinds !== '0 || odpushn !== '0 ||
                            odpush !== '0)
    $fatal(1, "disabled cmdexec active");

  // ---- work port model ----------------------------------------------
  logic [31:0] got_work [64];
  apu_cmdexec_state_t got_snap [64];
  int work_i = 0, pend = 0, dtimer = 0;
  always @(posedge clk) begin
    if (w_v && w_r) begin
      got_work[work_i] <= w_o.ctype;
      got_snap[work_i] <= w_o.snap;
      work_i <= work_i + 1;
      pend   <= pend + 1;
    end
    w_done <= 1'b0;
    if (dtimer != 0) begin
      dtimer <= dtimer - 1;
      if (dtimer == 1) begin
        w_done <= 1'b1;
        pend   <= pend - 1 + (w_v && w_r ? 1 : 0);
      end
    end else if (pend != 0) begin
      dtimer <= 3;
    end
  end
  // work_ready: deasserted for a cycle out of every 5
  always @(negedge clk) w_r <= (cycles % 5) != 4;

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL: %s", name);
      if (errors > 16) $fatal(1, "too many errors");
    end
  endtask

  // ---- backend setup helpers ------------------------------------------
  task automatic cr_op(input apu_cmdrec_op_e o, input logic [7:0] b,
                       input logic [15:0] ix, input apu_cmdrec_rec_t r,
                       input logic [15:0] pn = '0);
    @(negedge clk); tcr_v = 1'b1;
    tcr_req = '{op: o, cbuf: b, idx: ix, rec: r, pay_n: pn};
    @(posedge clk);
    while (!tcr_r) @(posedge clk);
    @(negedge clk); tcr_v = 1'b0;
    // APPEND with pay_n streams its payload words one per cycle while
    // the recorder sits in its StPay accept state. Hold pay_valid
    // across the whole burst: the last word exits StPay on the same
    // edge that accepts it, so polling pay_ready_o per word can miss
    // the final handshake under post-edge sampling.
    if (pn != 0) begin
      @(negedge clk); tpay_v = 1'b1;
      for (int i = 0; i < pn; i++) begin
        tpay_d = 32'hCAFE_0000 + 32'(i);
        @(negedge clk);
      end
      tpay_v = 1'b0;
    end
    while (!tcr_cv) @(negedge clk);
  endtask

  task automatic ot_op(input apu_objtab_op_e o, input logic [63:0] id,
                       input logic [7:0] k);
    @(negedge clk); tot_v = 1'b1;
    tot_req = '{op: o, id: id, kind: k[5:0], default: '0};
    @(posedge clk);
    while (!tot_r) @(posedge clk);
    @(negedge clk); tot_v = 1'b0;
    while (!tot_cv) @(negedge clk);
  endtask

  function automatic apu_cmdrec_rec_t mkrec(input logic [31:0] ty,
                                            input logic [31:0] h0,
                                            input logic [7:0] k0,
                                            input logic [31:0] i0);
    apu_cmdrec_rec_t r;
    r = '0;
    r.ctype = ty;
    r.handle[0] = h0; r.kind[0] = k0;
    r.imm[0] = i0;
    return r;
  endfunction

  logic [31:0] cb_h, pipe_h, dset_h, buf0_h, buf1_h;
  logic [15:0] seq0;

  task automatic submit(input logic [4:0] f, input int nb,
                        input logic [7:0] r0, input logic [31:0] h0,
                        input logic [7:0] r1, input logic [31:0] h1);
    sub_v = 1'b1;
    sub = '{fence_idx: f, nbufs: 3'(nb),
            crec: '{8'h0, 8'h0, r1, r0},
            chndl: '{32'h0, 32'h0, h1, h0}};
    // wait for handshake
    while (!sub_r) @(posedge clk);
    @(posedge clk);
    @(negedge clk); sub_v = 1'b0;
  endtask

  task automatic wait_fence(input int f, input int timeout);
    int t = 0;
    while (!fsig[f] && t < timeout) begin
      @(negedge clk); t++;
    end
    check("fence signaled", fsig[f]);
  endtask

  initial begin
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;

    // ---- setup: objects ------------------------------------------------
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0001,
          APU_VN_KIND_VK_COMMAND_BUFFER);
    cb_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0002,
          APU_VN_KIND_VK_PIPELINE);
    pipe_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0003,
          APU_VN_KIND_VK_DESCRIPTOR_SET);
    dset_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0004,
          APU_VN_KIND_VK_BUFFER);
    buf0_h = ot_cpl.handle;
    ot_op(APU_OBJTAB_OP_ALLOC, 64'h1000_0000_0000_0005,
          APU_VN_KIND_VK_BUFFER);
    buf1_h = ot_cpl.handle;
    check("alloc cb", cb_h !== '0);

    // ---- case 1: record + submit buf0 ------------------------------------
    cr_op(APU_CMDREC_OP_BEGIN, 0, 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, 0, 0,
          mkrec(APU_VN_TYPE_VK_CMD_BIND_PIPELINE_EXT, pipe_h,
                APU_VN_KIND_VK_PIPELINE, 0));
    cr_op(APU_CMDREC_OP_APPEND, 0, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 32'h8));
    cr_op(APU_CMDREC_OP_APPEND, 0, 0,
          mkrec(APU_VN_TYPE_VK_CMD_PIPELINE_BARRIER_EXT, 0, 0, 0));
    begin
      apu_cmdrec_rec_t rr = mkrec(APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT,
                                  buf0_h, APU_VN_KIND_VK_BUFFER, 0);
      rr.handle[1] = buf1_h; rr.kind[1] = APU_VN_KIND_VK_BUFFER;
      cr_op(APU_CMDREC_OP_APPEND, 0, 0, rr);
    end
    cr_op(APU_CMDREC_OP_END, 0, 0, '0);
    check("record buf0", cr_cpl.status == APU_CMDREC_OK);

    tb_drv = 1'b0;
    seq0 = done_seq;
    submit(5'd0, 1, 8'd0, cb_h, 8'h0, 32'h0);
    wait_fence(0, 4000);
    check("work count", work_i == 2);
    check("work0 dispatch",
          got_work[0] == APU_VN_TYPE_VK_CMD_DISPATCH_EXT);
    check("work1 copy",
          got_work[1] == APU_VN_TYPE_VK_CMD_COPY_BUFFER_EXT);
    check("snap pipeline", got_snap[1].pipeline == pipe_h);
    check("no lost", flost[0] === 1'b0);
    check("seq adv", done_seq == seq0 + 16'h1);
    cases++;

    // ---- case 2: fence clear ---------------------------------------------
    fclr[0] = 1'b1;
    @(negedge clk); fclr[0] = 1'b0;
    @(negedge clk);
    check("fence cleared", fsig[0] === 1'b0 && flost[0] === 1'b0);
    cases++;

    // ---- case 3: stale record handle -> DEVICE_LOST ----------------------
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, 1, 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, 1, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, buf0_h + 32'h10000,
                APU_VN_KIND_VK_BUFFER, 0));
    cr_op(APU_CMDREC_OP_END, 1, 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd1, 1, 8'd1, cb_h, 8'h0, 32'h0);
      wait_fence(1, 4000);
      check("stale lost", flost[1] === 1'b1);
      check("stale no work", work_i == w0);
      cases++;
    end

    // ---- case 4: unsealed buffer -> DEVICE_LOST ---------------------------
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, 2, 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, 2, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 1));
    tb_drv = 1'b0;   // buffer left unsealed
    begin
      int w0 = work_i;
      submit(5'd2, 1, 8'd2, cb_h, 8'h0, 32'h0);
      wait_fence(2, 4000);
      check("unsealed lost", flost[2] === 1'b1);
      check("unsealed no work", work_i == w0);
      cases++;
    end

    // ---- case 5: two buffers in one submit -------------------------------
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, 3, 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, 3, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 4));
    cr_op(APU_CMDREC_OP_END, 3, 0, '0);
    cr_op(APU_CMDREC_OP_BEGIN, 4, 0, '0);
    cr_op(APU_CMDREC_OP_APPEND, 4, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DISPATCH_EXT, 0, 0, 2));
    cr_op(APU_CMDREC_OP_END, 4, 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd3, 2, 8'd3, cb_h, 8'd4, cb_h);
      wait_fence(3, 4000);
      check("two-buf work", work_i == w0 + 2);
      check("buf order0", got_work[w0] == APU_VN_TYPE_VK_CMD_DRAW_EXT);
      check("buf order1",
            got_work[w0 + 1] == APU_VN_TYPE_VK_CMD_DISPATCH_EXT);
      check("two-buf ok", flost[3] === 1'b0);
      cases++;
    end

    // ---- case 6: unpin after completion ----------------------------------
    tb_drv = 1'b1;
    ot_op(APU_OBJTAB_OP_LOOKUP, {32'h0, cb_h},
          APU_VN_KIND_VK_COMMAND_BUFFER);
    check("cb unpinned", ot_cpl.status == APU_OBJTAB_OK &&
                         ot_cpl.entry.pins == 8'h0);
    tb_drv = 1'b0;
    cases++;

    // ---- case 7: §7b BindDS payload walk + push-constant state ------------
    // Two payload records share the buffer's pay arena: BindDS lands at
    // base 0 (imm[7]=0), PushConstants at base 2 (imm[7]=2).
    tb_drv = 1'b1;
    cr_op(APU_CMDREC_OP_BEGIN, 5, 0, '0);
    begin
      apu_cmdrec_rec_t rr = mkrec(
          APU_VN_TYPE_VK_CMD_BIND_DESCRIPTOR_SETS_EXT, 0, 0, 0);
      rr.imm[1] = 32'd1;   // firstSet
      rr.imm[2] = 32'd2;   // descriptorSetCount -> arena words 0,1
      cr_op(APU_CMDREC_OP_APPEND, 5, 0, rr, 16'd2);
    end
    begin
      apu_cmdrec_rec_t pr = mkrec(
          APU_VN_TYPE_VK_CMD_PUSH_CONSTANTS_EXT, 0, 0, 0);
      pr.imm[0] = 32'hAB;  // stageFlags
      pr.imm[2] = 32'd8;   // size bytes
      cr_op(APU_CMDREC_OP_APPEND, 5, 0, pr, 16'd2);
    end
    // §7b/5a-ii: a DISPATCH here would enter the full descriptor
    // assembly (the CAFE dset handles resolve to nothing); probe the
    // snap through a non-dispatch work record instead.  Dispatch
    // assembly itself is covered end-to-end in tb_g6lc_apu_vgtop.
    cr_op(APU_CMDREC_OP_APPEND, 5, 0,
          mkrec(APU_VN_TYPE_VK_CMD_DRAW_EXT, 0, 0, 32'h4));
    cr_op(APU_CMDREC_OP_END, 5, 0, '0);
    tb_drv = 1'b0;
    begin
      int w0 = work_i;
      submit(5'd4, 1, 8'd5, cb_h, 8'h0, 32'h0);
      wait_fence(4, 4000);
      check("bindds work", work_i == w0 + 1);
      // streamed pay words are CAFE_0000+i; BindDS reads two ->
      // dset[firstSet+k]; PushConstants parks base/len in the snap
      check("dset1", got_snap[w0].dset[1] === 32'hCAFE0000);
      check("dset2", got_snap[w0].dset[2] === 32'hCAFE0001);
      check("push_base", got_snap[w0].push_base === 16'd2);
      check("push_len",  got_snap[w0].push_len === 16'd8);
      check("bindds no lost", flost[4] === 1'b0);
      cases++;
    end

    $display("PASS tb_g6lc_apu_cmdexec cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "cmdexec %0d errors", errors);
    $finish;
  end

  initial begin #120_000_000; $fatal(1, "cmdexec timeout"); end
endmodule
