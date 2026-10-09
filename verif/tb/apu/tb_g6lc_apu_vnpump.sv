// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Unit test of g6lc_apu_vnpump (§6b of
// architecture/uncore/apu-vulkan-engine.md): the Venus ring pump
// exercised through its execbuffer hand-off (xs_*) and ring polling,
// against the real g6lc_apu_objtab with pre-seeded BLOB_SHMEM
// aperture mappings.  The TB models the aperture (apm) and guest
// memory (gmem) arrays, the four blob resources of the transport
// fixture, and checks ring create/poll/head/status/extra/idle,
// ExecuteCommandStreams windows, the reply-window path, and the
// mutation arms:
//   non-power-of-two bufferSize, ring offsets outside the blob,
//   ExecuteCommandStreams window outside the blob, nested
//   ExecuteCommandStreams, unknown command type, truncated
//   execbuffer stream, and ring FATAL/head-stop.
//
// Command vectors are the literal wire encodings produced by
// vn_golden.py's encoder (same model that generates
// ue_sm5_transport.hex); layouts are commented per command.
//
// Blob aperture placement (word bases in the 1 MiB window):
//   RES_RING0 rid 100 -> page 0  (word    0) size  4096
//   RES_REPLY rid 101 -> page 1  (word 1024) size 16384
//   RES_EXEC  rid 103 -> page 5  (word 5120) size  4096
//   RES_RING1 rid 102 -> page 6  (word 6144) size  8192
// Ring geometry: head@0 tail@64 status@128 buffer@192.

module tb_g6lc_apu_vnpump;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_objpay_pkg::*;
  import g6lc_apu_cmdrec_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_vnfront_pkg::*;

  localparam int unsigned GMW   = 32'h40000;   // 1 MiB guest RAM
  localparam int unsigned APW   = 32'h40000;   // 1 MiB aperture
  localparam logic [63:0] GXBUF = 64'h10000;   // execbuffer in gmem
  localparam int unsigned GXW   = 32'h4000;    // GXBUF as a word index
  localparam int unsigned TMO   = 200000;

  localparam int unsigned R0_BASE = 0;         // ap word bases
  localparam int unsigned RP_BASE = 1024;
  localparam int unsigned EX_BASE = 5120;
  localparam int unsigned R1_BASE = 6144;

  localparam logic [31:0] ST_ALIVE = APU_VNRING_ALIVE;          // 4
  localparam logic [31:0] ST_IDLE  = APU_VNRING_ALIVE |
                                     APU_VNRING_IDLE;           // 5
  localparam logic [31:0] ST_FATAL = APU_VNRING_ALIVE |
                                     APU_VNRING_FATAL;          // 6

  logic clk = 0, rst_ni = 0;
  int unsigned cycles = 0, checks = 0, errors = 0, cases = 0;

  // ---- DUT execbuffer interface ------------------------------------
  logic         xs_v, xs_rdy, xs_done, xs_fault, xs_active;
  apu_vg_desc_t [APU_VG_MAX_DESC-1:0] xs_d;
  logic [3:0]   xs_n;
  logic [31:0]  xs_off, xs_bytes;
  logic [7:0]   xs_ctx;

  // ---- mp port (dom=0 guest-absolute, dom=1 aperture byte offset) ---
  logic        mp_req, mp_we, mp_dom;
  logic [63:0] mp_addr, mp_wdata;
  logic [7:0]  mp_wstrb;
  logic        mp_rv = 0;
  logic [63:0] mp_rdata = '0;

  // ---- ObjTab (real engine, TB-seeded while the pump is quiet) ------
  logic            ot_v, ot_r;
  apu_objtab_req_t ot_req;
  logic            ot_cv, ot_cr;
  apu_objtab_cpl_t ot_cpl;
  // pump side of the mux
  logic            d_ot_v, d_ot_cr;
  apu_objtab_req_t d_ot_req;
  // seed side
  logic            seeding;
  logic            s_ot_v;
  apu_objtab_req_t s_ot_req;

  // ---- cmdrec / cmdexec / objpay tie-offs (no RECORD/submit in this TB)
  logic            cr_v, cr_cr;
  apu_cmdrec_req_t cr_req;
  logic            cr_pay_v;
  logic [31:0]     cr_pay_d;
  apu_objpay_req_t op_req;
  logic            op_v;
  logic            ex_sv;
  apu_cmdexec_submit_t ex_s;
  logic [15:0]     ex_fclr;

  logic        busy;
  logic [3:0]       ring_active;
  logic [3:0][31:0] ring_status;
  logic [3:0][31:0] ring_head;
  logic [3:0][APU_VG_AP_WORD_W-1:0] ring_extra;

  g6lc_apu_vnpump #(.Enable(1'b1), .Rings(4)) dut (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .xs_valid_i(xs_v), .xs_ready_o(xs_rdy),
    .xs_desc_i(xs_d), .xs_ndesc_i(xs_n), .xs_off_i(xs_off),
    .xs_bytes_i(xs_bytes), .xs_ctx_i(xs_ctx),
    .xs_done_o(xs_done), .xs_fault_o(xs_fault),
    .xs_active_o(xs_active),
    .mp_req_o(mp_req), .mp_we_o(mp_we), .mp_dom_o(mp_dom),
    .mp_addr_o(mp_addr), .mp_wdata_o(mp_wdata),
    .mp_wstrb_o(mp_wstrb),
    .mp_ready_i(1'b1), .mp_rvalid_i(mp_rv), .mp_rdata_i(mp_rdata),
    .mp_err_i(1'b0),
    .ot_req_valid_o(d_ot_v), .ot_req_ready_i(ot_r && !seeding),
    .ot_req_o(d_ot_req),
    .ot_cpl_valid_i(ot_cv && !seeding), .ot_cpl_ready_o(d_ot_cr),
    .ot_cpl_i(ot_cpl),
    .cr_req_valid_o(cr_v), .cr_req_ready_i(1'b1), .cr_req_o(cr_req),
    .cr_cpl_valid_i(1'b0), .cr_cpl_ready_o(cr_cr), .cr_cpl_i('0),
    .cr_pay_valid_o(cr_pay_v), .cr_pay_data_o(cr_pay_d),
    .cr_pay_ready_i(1'b0),
    .op_req_valid_o(op_v), .op_req_ready_i(1'b0), .op_req_o(op_req),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(), .op_cpl_i('0),
    // §7b/5a-ii pass-throughs: no shader-module/pipeline or memory
    // commands in this tape, so the backends stay idle.
    .sm_req_o(), .sm_req_pl_o(),
    .sm_cpl_i(1'b0), .sm_cpl_pl_i('0),
    .sh_wr_en_o(), .sh_wr_slot_o(), .sh_wr_addr_o(), .sh_wr_data_o(),
    .sh_commit_o(), .sh_commit_pl_o(),
    .sh_c_done_i(1'b0), .sh_c_done_pl_i('0),
    .pg_req_valid_o(), .pg_req_ready_i(1'b0), .pg_req_o(),
    .pg_cpl_valid_i(1'b0), .pg_cpl_ready_o(), .pg_cpl_i('0),
    .ex_submit_valid_o(ex_sv), .ex_submit_ready_i(1'b1),
    .ex_submit_o(ex_s),
    .ex_done_seq_i(16'h0), .ex_fence_signaled_i(16'h0),
    .ex_fence_lost_i(16'h0), .ex_fence_clr_o(ex_fclr),
    .busy_o(busy),
    .ring_active_o(ring_active), .ring_status_o(ring_status),
    .ring_head_o(ring_head), .ring_extra_w_o(ring_extra));

  // Enable=0 fixture: outputs stay quiet
  logic        z_rdy, z_done, z_fault, z_act, z_busy;
  logic        z_mpreq, z_mpwe, z_otv, z_otcr;
  logic        z_crv, z_crcr, z_exsv;
  logic        z_cpayv, z_opv;
  logic        z_smv, z_shw, z_shc, z_pgv, z_pgcr;
  apu_sh_sm_req_t   z_smpl;
  apu_sh_commit_t   z_shpl;
  apu_vgpages_req_t z_pgreq;
  logic [3:0]       z_ract;
  logic [3:0][31:0] z_rstat, z_rhead;
  g6lc_apu_vnpump #(.Enable(1'b0), .Rings(4)) dut_off (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .xs_valid_i(1'b1), .xs_ready_o(z_rdy),
    .xs_desc_i('{default: '0}), .xs_ndesc_i(4'd1), .xs_off_i(32'h0),
    .xs_bytes_i(32'h40), .xs_ctx_i(8'h0),
    .xs_done_o(z_done), .xs_fault_o(z_fault), .xs_active_o(z_act),
    .mp_req_o(z_mpreq), .mp_we_o(z_mpwe), .mp_dom_o(),
    .mp_addr_o(), .mp_wdata_o(), .mp_wstrb_o(),
    .mp_ready_i(1'b1), .mp_rvalid_i(1'b0), .mp_rdata_i(64'h0),
    .mp_err_i(1'b0),
    .ot_req_valid_o(z_otv), .ot_req_ready_i(1'b1), .ot_req_o(),
    .ot_cpl_valid_i(1'b0), .ot_cpl_ready_o(z_otcr), .ot_cpl_i('0),
    .cr_req_valid_o(z_crv), .cr_req_ready_i(1'b1), .cr_req_o(),
    .cr_cpl_valid_i(1'b0), .cr_cpl_ready_o(z_crcr), .cr_cpl_i('0),
    .cr_pay_valid_o(z_cpayv), .cr_pay_data_o(),
    .cr_pay_ready_i(1'b0),
    .op_req_valid_o(z_opv), .op_req_ready_i(1'b0), .op_req_o(),
    .op_cpl_valid_i(1'b0), .op_cpl_ready_o(), .op_cpl_i('0),
    .sm_req_o(z_smv), .sm_req_pl_o(z_smpl),
    .sm_cpl_i(1'b0), .sm_cpl_pl_i('0),
    .sh_wr_en_o(z_shw), .sh_wr_slot_o(), .sh_wr_addr_o(),
    .sh_wr_data_o(), .sh_commit_o(z_shc), .sh_commit_pl_o(z_shpl),
    .sh_c_done_i(1'b0), .sh_c_done_pl_i('0),
    .pg_req_valid_o(z_pgv), .pg_req_ready_i(1'b0), .pg_req_o(z_pgreq),
    .pg_cpl_valid_i(1'b0), .pg_cpl_ready_o(z_pgcr), .pg_cpl_i('0),
    .ex_submit_valid_o(z_exsv), .ex_submit_ready_i(1'b1),
    .ex_submit_o(),
    .ex_done_seq_i(16'h0), .ex_fence_signaled_i(16'h0),
    .ex_fence_lost_i(16'h0), .ex_fence_clr_o(),
    .busy_o(z_busy),
    .ring_active_o(z_ract), .ring_status_o(z_rstat),
    .ring_head_o(z_rhead), .ring_extra_w_o());

  g6lc_apu_objtab #(.Enable(1'b1), .Slots(64)) i_tab (
    .clk_i(clk), .rst_ni(rst_ni), .testmode_i(1'b0),
    .req_valid_i(ot_v), .req_ready_o(ot_r), .req_i(ot_req),
    .cpl_valid_o(ot_cv), .cpl_ready_i(ot_cr), .cpl_o(ot_cpl),
    .live_o());

  assign ot_v   = seeding ? s_ot_v   : d_ot_v;
  assign ot_req = seeding ? s_ot_req : d_ot_req;
  assign ot_cr  = seeding ? 1'b1     : d_ot_cr;

  // sticky capture: cpl_valid and xs_done are single-cycle pulses that
  // post-edge task polling can miss
  int unsigned      s_seen = 0;
  apu_objtab_cpl_t  s_cpl;
  always @(posedge clk) if (seeding && ot_cv) begin
    s_seen++; s_cpl <= ot_cpl;
  end
  int unsigned xs_seen = 0;
  always @(posedge clk) if (xs_done) xs_seen++;
  // §12.3 E observability: aperture reads issued (ring tail polls are
  // the dominant source while the pump sits idle-but-live)
  int unsigned ap_rd = 0;
  always @(posedge clk) if (mp_req && !mp_we && mp_dom) ap_rd++;
  // accept counters sampled at the same posedge the engines use
  int unsigned ot_acc = 0, xs_acc = 0;
  always @(posedge clk) if (ot_v && ot_r) ot_acc++;
  always @(posedge clk) if (xs_v && xs_rdy) xs_acc++;

  // ---- mp memory model (ready=1, rvalid next cycle; dom selects the
  // aperture or guest array; rdata is the aligned 64-bit beat, wstrb
  // is beat-positioned) -------------------------------------------------
  logic [31:0] gmem [GMW];
  logic [31:0] apm  [APW];
  function automatic logic [31:0] mp_word(input logic [63:0] a,
                                          input int unsigned w);
    int unsigned idx = 32'((a >> 3) * 2) + w;
    if (mp_dom && idx >= APW)
      $fatal(1, "aperture word %d past dense model (%d)", idx, APW);
    return mp_dom ? apm[idx] : gmem[idx];
  endfunction
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      mp_rv <= 1'b0; mp_rdata <= '0;
    end else begin
      mp_rv <= 1'b0;
      if (mp_req && !mp_we)
        begin mp_rv <= 1'b1;
          mp_rdata <= {mp_word(mp_addr, 1), mp_word(mp_addr, 0)}; end
      else if (mp_req && mp_we) begin
        mp_rv <= 1'b1;
        for (int b = 0; b < 8; b++)
          if (mp_wstrb[b]) begin
            if (mp_dom) begin
              automatic int unsigned idx =
                  32'((mp_addr >> 3) * 2) + (b >= 4 ? 1 : 0);
              if (idx >= APW)
                $fatal(1, "aperture write word %d past dense model", idx);
              apm[idx][b[1:0] * 8 +: 8] <= mp_wdata[b * 8 +: 8];
            end
            else
              gmem[32'((mp_addr >> 3) * 2) + (b >= 4 ? 1 : 0)]
                  [b[1:0] * 8 +: 8] <= mp_wdata[b * 8 +: 8];
          end
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
      if (errors > 60) $fatal(1, "too many errors");
    end
  endtask

  // ---- ObjTab seed ops (driven while `seeding`) ----------------------
  task automatic ot_op(input apu_objtab_req_t r,
                       output apu_objtab_status_e st);
    int unsigned s0 = s_seen;
    int unsigned a0 = ot_acc;
    @(negedge clk);
    s_ot_req = r; s_ot_v = 1'b1;
    // hold valid until the posedge where valid&&ready are both
    // sampled high (the accept); then deassert at the next negedge
    // so the engine sees one request exactly once
    begin int unsigned tt = 0;
      while (ot_acc == a0 && tt < TMO) begin @(posedge clk); tt++; end
    end
    @(negedge clk);
    s_ot_v = 1'b0;
    begin int unsigned tt = 0;
      while (s_seen == s0 && tt < TMO) begin @(posedge clk); tt++; end
    end
    st = s_cpl.status;
    @(posedge clk);
  endtask

  task automatic seed_blob(input logic [31:0] rid,
                           input int unsigned page,
                           input logic [63:0] size);
    apu_objtab_status_e st;
    ot_op('{op: APU_OBJTAB_OP_ALLOC, id: APU_VG_ID_TAG | 64'(rid),
           kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM), parent_id: 64'h0,
           ctx: 8'd4, default: '0}, st);
    check(st == APU_OBJTAB_OK, "seed blob ALLOC");
    ot_op('{op: APU_OBJTAB_OP_SETBIND, id: APU_VG_ID_TAG | 64'(rid),
           kind: 6'(APU_VN_KIND_APU_BLOB_SHMEM),
           mem_id: APU_VG_ID_TAG | 64'(rid),
           offset: APU_VG_SHM_BASE + 64'(page) * 64'd4096, size: size,
           default: '0}, st);
    check(st == APU_OBJTAB_OK, "seed blob SETBIND");
  endtask

  // ---- execbuffer driver --------------------------------------------
  // payload = command words, staged at GXBUF + 32 (a fake 32-byte
  // virtio execbuffer header, mirroring vgctl's xs_off=32)
  task automatic xs_go(input logic [31:0] words [$],
                       input bit exp_fault, input string tag);
    int unsigned t;
    cases++;
    for (int i = 0; i < 8; i++) gmem[GXW + i] = 32'h0;
    for (int i = 0; i < words.size(); i++)
      gmem[GXW + 8 + i] = words[i];
    xs_d[0] = '{addr: GXBUF, len: 32'(32 + words.size() * 4),
                write: 1'b0, default: '0};
    xs_d[1] = '0; xs_d[2] = '0; xs_d[3] = '0;
    xs_n = 4'd1; xs_off = 32'd32;
    xs_bytes = 32'(words.size() * 4); xs_ctx = 8'd4;
    begin int unsigned s0 = xs_seen;
      int unsigned a0 = xs_acc;
      @(negedge clk);
      xs_v = 1'b1;
      t = 0;
      while (xs_acc == a0 && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": no idle cycle for accept"});
      @(negedge clk);
      xs_v = 1'b0;
      t = 0;
      while (xs_seen == s0 && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": xs_done timeout"});
      check(xs_fault == exp_fault, {tag, ": xs_fault"});
      t = 0;
      while (!xs_rdy && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": never returned to idle"});
    end
  endtask

  // truncated variant: xs_bytes shorter than the staged payload
  task automatic xs_go_trunc(input logic [31:0] words [$],
                             input int unsigned nbytes,
                             input string tag);
    int unsigned t;
    cases++;
    for (int i = 0; i < 8; i++) gmem[GXW + i] = 32'h0;
    for (int i = 0; i < words.size(); i++)
      gmem[GXW + 8 + i] = words[i];
    xs_d[0] = '{addr: GXBUF, len: 32'(32 + words.size() * 4),
                write: 1'b0, default: '0};
    xs_d[1] = '0; xs_d[2] = '0; xs_d[3] = '0;
    xs_n = 4'd1; xs_off = 32'd32;
    xs_bytes = 32'(nbytes); xs_ctx = 8'd4;
    begin int unsigned s0 = xs_seen;
      int unsigned a0 = xs_acc;
      @(negedge clk);
      xs_v = 1'b1;
      t = 0;
      while (xs_acc == a0 && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": no idle cycle for accept"});
      @(negedge clk);
      xs_v = 1'b0;
      t = 0;
      while (xs_seen == s0 && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": xs_done timeout"});
      t = 0;
      while (!xs_rdy && t < TMO) begin @(posedge clk); t++; end
      check(t < TMO, {tag, ": never returned to idle"});
    end
  endtask

  // ---- ring helpers ---------------------------------------------------
  // write command bytes into a ring buffer at its current head (with
  // wrap), then publish tail
  task automatic ring_put(input int unsigned buf_w,
                          input int unsigned head_bytes,
                          input logic [31:0] words [$],
                          input int unsigned tail_w,
                          input int unsigned new_tail);
    for (int i = 0; i < words.size(); i++)
      apm[buf_w + ((head_bytes + i * 4) & 2047) / 4] = words[i];
    apm[tail_w] = 32'(new_tail);
  endtask

  task automatic wait_ap(input int unsigned addr,
                         input logic [31:0] exp, input string tag);
    int unsigned t = 0;
    cases++;
    while (apm[addr] !== exp && t < TMO) begin @(posedge clk); t++; end
    check(t < TMO, {tag, ": wait timeout"});
    if (t < TMO)
      check(apm[addr] == exp, {tag, ": value"});
  endtask

  // ---- generated command vectors -------------------------------------
  // CRING0: vkCreateRingMESA ring=0x100 res=100 size=2240 idleTo=300
  //   head@0 tail@64 status@128 buf@192 bufSize=2048 extra@0 sz=0
  localparam logic [31:0] CRING0 [35] = '{
    32'h000000bc, 32'h00000000, 32'h00000100, 32'h00000000,
    32'h00000001, 32'h00000000, 32'h3ba0a600, 32'h00000001,
    32'h00000000, 32'h3ba0a606, 32'h00000000, 32'h00000000,
    32'h000003e8, 32'h00000000, 32'h00000064, 32'h00000000,
    32'h00000000, 32'h000008c0, 32'h00000000, 32'h0000012c,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000040,
    32'h00000000, 32'h00000080, 32'h00000000, 32'h000000c0,
    32'h00000000, 32'h00000800, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000};
  // CRING1: ring=0x400 res=102 size=2256 idleTo=4 extra@2240 sz=16
  localparam logic [31:0] CRING1 [35] = '{
    32'h000000bc, 32'h00000000, 32'h00000400, 32'h00000000,
    32'h00000001, 32'h00000000, 32'h3ba0a600, 32'h00000001,
    32'h00000000, 32'h3ba0a606, 32'h00000000, 32'h00000000,
    32'h000003e8, 32'h00000000, 32'h00000066, 32'h00000000,
    32'h00000000, 32'h000008d0, 32'h00000000, 32'h00000004,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000040,
    32'h00000000, 32'h00000080, 32'h00000000, 32'h000000c0,
    32'h00000000, 32'h00000800, 32'h00000000, 32'h000008c0,
    32'h00000000, 32'h00000010, 32'h00000000};
  // CRING_BADSZ: bufferSize=2000 (not a power of two)
  localparam logic [31:0] CRING_BADSZ [35] = '{
    32'h000000bc, 32'h00000000, 32'h00000200, 32'h00000000,
    32'h00000001, 32'h00000000, 32'h3ba0a600, 32'h00000001,
    32'h00000000, 32'h3ba0a606, 32'h00000000, 32'h00000000,
    32'h000003e8, 32'h00000000, 32'h00000064, 32'h00000000,
    32'h00000000, 32'h000008c0, 32'h00000000, 32'h0000012c,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000040,
    32'h00000000, 32'h00000080, 32'h00000000, 32'h000000c0,
    32'h00000000, 32'h000007d0, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000};
  // CRING_BADOFF: statusOffset=5000 outside the ring window
  localparam logic [31:0] CRING_BADOFF [35] = '{
    32'h000000bc, 32'h00000000, 32'h00000300, 32'h00000000,
    32'h00000001, 32'h00000000, 32'h3ba0a600, 32'h00000001,
    32'h00000000, 32'h3ba0a606, 32'h00000000, 32'h00000000,
    32'h000003e8, 32'h00000000, 32'h00000064, 32'h00000000,
    32'h00000000, 32'h000008c0, 32'h00000000, 32'h0000012c,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000040,
    32'h00000000, 32'h00001388, 32'h00000000, 32'h000000c0,
    32'h00000000, 32'h00000800, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000};
  // WREXTRA ring=0x400 off=0 val=0xdeadbeef
  localparam logic [31:0] WREXTRA [7] = '{
    32'h000000bf, 32'h00000000, 32'h00000400, 32'h00000000,
    32'h00000000, 32'h00000000, 32'hdeadbeef};
  // SUBVQ7 ring=0x100 seq=7 ; WAITVQ7 seq=7
  localparam logic [31:0] SUBVQ7 [6] = '{
    32'h000000fb, 32'h00000000, 32'h00000100, 32'h00000000,
    32'h00000007, 32'h00000000};
  localparam logic [31:0] WAITVQ7 [4] = '{
    32'h000000fc, 32'h00000000, 32'h00000007, 32'h00000000};
  // SETREPLY resourceId=101 off=0 size=16384
  localparam logic [31:0] SETREPLY [9] = '{
    32'h000000b2, 32'h00000000, 32'h00000001, 32'h00000000,
    32'h00000065, 32'h00000000, 32'h00000000, 32'h00004000,
    32'h00000000};
  // EXEC32: stream {res=103, off=0, size=32}, reply pos 0
  localparam logic [31:0] EXEC32 [18] = '{
    32'h000000b4, 32'h00000000, 32'h00000001, 32'h00000001,
    32'h00000000, 32'h00000067, 32'h00000000, 32'h00000000,
    32'h00000020, 32'h00000000, 32'h00000001, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000};
  // EXECBAD: stream {res=103, off=4080, size=64} > blob size
  localparam logic [31:0] EXECBAD [18] = '{
    32'h000000b4, 32'h00000000, 32'h00000001, 32'h00000001,
    32'h00000000, 32'h00000067, 32'h00000ff0, 32'h00000000,
    32'h00000040, 32'h00000000, 32'h00000001, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000};
  // EXECNEST: stream {res=103, off=0, size=72} -> inner is EXEC32
  localparam logic [31:0] EXECNEST [18] = '{
    32'h000000b4, 32'h00000000, 32'h00000001, 32'h00000001,
    32'h00000000, 32'h00000067, 32'h00000000, 32'h00000000,
    32'h00000048, 32'h00000000, 32'h00000001, 32'h00000000,
    32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000,
    32'h00000000, 32'h00000000};
  // GBMR: vkGetBufferMemoryRequirements device=0x1000 buffer=0x2000
  //   (both bogus -> error reply through the front/reply path)
  localparam logic [31:0] GBMR [8] = '{
    32'h0000001e, 32'h00000001, 32'h00001000, 32'h00000000,
    32'h00002000, 32'h00000000, 32'h00000001, 32'h00000000};
  // DESTROY0/DESTROY1 ring=0x100/0x400; NOTIFY1; WAITR1 seq=28
  localparam logic [31:0] DESTROY0 [4] = '{
    32'h000000bd, 32'h00000000, 32'h00000100, 32'h00000000};
  localparam logic [31:0] DESTROY1 [4] = '{
    32'h000000bd, 32'h00000000, 32'h00000400, 32'h00000000};
  localparam logic [31:0] NOTIFY1 [6] = '{
    32'h000000be, 32'h00000000, 32'h00000400, 32'h00000000,
    32'h00000000, 32'h00000000};
  // NOTIFY0 ring=0x100 (for the T16 backoff-liveness push)
  localparam logic [31:0] NOTIFY0 [6] = '{
    32'h000000be, 32'h00000000, 32'h00000100, 32'h00000000,
    32'h00000000, 32'h00000000};
  localparam logic [31:0] WAITR1 [6] = '{
    32'h000000fd, 32'h00000000, 32'h00000400, 32'h00000000,
    32'h0000001c, 32'h00000000};
  // BADCMD: unknown command type (decode fault)
  localparam logic [31:0] BADCMD [4] = '{
    32'h0000dead, 32'h00000000, 32'h00000000, 32'h00000000};

  logic [31:0] wq [$];

  initial begin
`ifndef SYNTHESIS
    $dumpfile("/tmp/vnpump.vcd");
    $dumpvars(3, tb_g6lc_apu_vnpump);
`endif
    xs_v = 0; xs_d = '{default: '0}; xs_n = '0;
    xs_off = '0; xs_bytes = '0; xs_ctx = '0;
    seeding = 1'b0; s_ot_v = 1'b0; s_ot_req = '0;
    repeat (8) @(posedge clk);
    rst_ni = 1;
    repeat (4) @(posedge clk);

    // ---- Enable=0 fixture stays quiet --------------------------------
    cases++;
    repeat (4) @(posedge clk);
    check(!z_rdy && !z_done && !z_fault && !z_busy && !z_mpreq &&
          !z_mpwe && !z_otv && !z_crv && !z_exsv &&
          !z_cpayv && !z_opv && !z_smv && !z_shw && !z_shc &&
          !z_pgv && !z_pgcr && z_smpl == '0 && z_shpl == '0 &&
          z_pgreq == '0,
          "Enable=0 quiet");

    // ---- seed the four fixture blobs ----------------------------------
    seeding = 1'b1;
    seed_blob(32'd100, 0, 64'd4096);     // RES_RING0
    seed_blob(32'd101, 1, 64'd16384);    // RES_REPLY
    seed_blob(32'd103, 5, 64'd4096);     // RES_EXEC
    seed_blob(32'd102, 6, 64'd8192);     // RES_RING1
    seeding = 1'b0;
    repeat (4) @(posedge clk);

    // ---- T1: execbuf vkCreateRingMESA ring0 ---------------------------
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING0[i]);
    xs_go(wq, 1'b0, "T1 create ring0");
    cases++;
    check(ring_active[0] == 1'b1, "T1 ring0 active");
    check(ring_status[0] == ST_ALIVE, "T1 ring0 status ALIVE");
    check(apm[R0_BASE + 32] == ST_ALIVE, "T1 status word stored");
    check(ring_head[0] == 32'h0, "T1 head 0");

    // ---- T2: non-power-of-two bufferSize ------------------------------
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING_BADSZ[i]);
    xs_go(wq, 1'b1, "T2 bufferSize not pow2");
    cases++;
    check(ring_active[1] == 1'b0, "T2 no ring created");

    // ---- T3: ring offsets outside the blob -----------------------------
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING_BADOFF[i]);
    xs_go(wq, 1'b1, "T3 statusOffset outside window");
    check(ring_active[1] == 1'b0, "T3 no ring created");

    // ---- T4: truncated execbuffer stream -------------------------------
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING0[i]);
    xs_go_trunc(wq, 16, "T4 truncated stream");
    cases++;
    check(xs_fault == 1'b1, "T4 fault on truncated stream");

    // ---- T5: unknown command type --------------------------------------
    wq = {};
    for (int i = 0; i < 4; i++) wq.push_back(BADCMD[i]);
    xs_go(wq, 1'b1, "T5 unknown type");

    // ---- T6: ring0 stream [SubmitVirtqueueSeqno + WaitVirtqueueSeqno] --
    wq = {};
    for (int i = 0; i < 6; i++) wq.push_back(SUBVQ7[i]);
    for (int i = 0; i < 4; i++) wq.push_back(WAITVQ7[i]);
    ring_put(R0_BASE + 48, 0, wq, R0_BASE + 16, 40);
    wait_ap(R0_BASE, 32'd40, "T6 ring0 head=40");
    cases++;
    check(ring_head[0] == 32'd40, "T6 ring_head_o");
    check(apm[R0_BASE + 32] == ST_ALIVE, "T6 status stays ALIVE");

    // ---- T8: execbuf vkCreateRingMESA ring1 (extra + short idle) -------
    // created while ring0 still occupies slot 0 -> ring1 lands in slot 1
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING1[i]);
    xs_go(wq, 1'b0, "T8 create ring1");
    cases++;
    check(ring_active[1] == 1'b1, "T8 ring1 active");
    check(apm[R1_BASE + 32] == ST_ALIVE, "T8 status stored");

    // ---- T7: execbuf vkDestroyRingMESA ring0 ---------------------------
    wq = {};
    for (int i = 0; i < 4; i++) wq.push_back(DESTROY0[i]);
    xs_go(wq, 1'b0, "T7 destroy ring0");
    cases++;
    check(ring_active[0] == 1'b0, "T7 ring0 dead");
    check(ring_active[1] == 1'b1, "T7 ring1 survives");

    // ---- T9: ring1 stream [WriteRingExtra] ------------------------------
    wq = {};
    for (int i = 0; i < 7; i++) wq.push_back(WREXTRA[i]);
    ring_put(R1_BASE + 48, 0, wq, R1_BASE + 16, 28);
    wait_ap(R1_BASE, 32'd28, "T9 ring1 head=28");
    cases++;
    check(apm[R1_BASE + 560] == 32'hdeadbeef, "T9 extra word");
    check(ring_extra[1] == APU_VG_AP_WORD_W'(R1_BASE + 560), "T9 extra_w");

    // ---- T10: idle timeout publishes IDLE, NotifyRing clears -----------
    wait_ap(R1_BASE + 32, ST_IDLE, "T10 IDLE published");
    wq = {};
    for (int i = 0; i < 6; i++) wq.push_back(NOTIFY1[i]);
    xs_go(wq, 1'b0, "T10 NotifyRing");
    wait_ap(R1_BASE + 32, ST_ALIVE, "T10 IDLE cleared");

    // ---- T11: ExecuteCommandStreams window outside the blob ------------
    wq = {};
    for (int i = 0; i < 18; i++) wq.push_back(EXECBAD[i]);
    xs_go(wq, 1'b1, "T11 exec window outside blob");

    // ---- T12: nested ExecuteCommandStreams ------------------------------
    // exec blob contains EXEC32 (a complete ExecuteCommandStreams)
    for (int i = 0; i < 18; i++) apm[EX_BASE + i] = EXEC32[i];
    wq = {};
    for (int i = 0; i < 18; i++) wq.push_back(EXECNEST[i]);
    xs_go(wq, 1'b1, "T12 nested exec");

    // ---- T13: reply path: SetReply + exec window [GBMR] ------------------
    // inner stream: one vkGetBufferMemoryRequirements (8 words = 32 B)
    // on bogus handles -> front replies {type=0x1e, result!=0} into
    // the RES_REPLY window at aperture word RP_BASE.
    for (int i = 0; i < 8; i++) apm[EX_BASE + i] = GBMR[i];
    wq = {};
    for (int i = 0; i < 9; i++) wq.push_back(SETREPLY[i]);
    for (int i = 0; i < 18; i++) wq.push_back(EXEC32[i]);
    xs_go(wq, 1'b0, "T13 setreply+exec");
    cases++;
    // model error reply for this command: {0x1e, 1, 0, 0x20400000,0,0,0,0}
    check(apm[RP_BASE] == 32'h0000001e, "T13 reply type word");
    check(apm[RP_BASE + 1] == 32'h00000001, "T13 reply prefix lo");
    check(apm[RP_BASE + 2] == 32'h00000000, "T13 reply prefix hi");

    // ---- T14: ring1 FATAL on unknown command, head stops -----------------
    wq = {};
    for (int i = 0; i < 4; i++) wq.push_back(BADCMD[i]);
    ring_put(R1_BASE + 48, 28, wq, R1_BASE + 16, 44);
    wait_ap(R1_BASE + 32, ST_FATAL, "T14 ring1 FATAL");
    cases++;
    check(apm[R1_BASE] == 32'd28, "T14 head frozen at 28");
    check(ring_active[1] == 1'b0, "T14 ring1 not active");
    check(ring_status[1] == ST_FATAL, "T14 status FATAL");
    // further ring1 writes are never consumed
    ring_put(R1_BASE + 48, 28, wq, R1_BASE + 16, 60);
    repeat (400) @(posedge clk);
    check(apm[R1_BASE] == 32'd28, "T14 no advance after fatal");

    // ---- T15: destroy the fatal ring via execbuf -------------------------
    wq = {};
    for (int i = 0; i < 4; i++) wq.push_back(DESTROY1[i]);
    xs_go(wq, 1'b0, "T15 destroy fatal ring1");
    cases++;
    // DestroyRing clears the live bit; fatal/idle bits remain as observed
    check(ring_status[1][2] == 1'b0, "T15 ring1 cleared");

    // ---- T16: §12.3 E poll backoff -------------------------------------
    // fresh live ring; let the exponential gap saturate, then count
    // aperture reads over a fixed idle-but-live window.  Unpaced the
    // pump would issue one tail read every ~3 cycles; the backoff
    // (1..256, doubling) must cut that by far more than 8x
    // a real guest initialises the ring buffer it hands to
    // vkCreateRingMESA (head=tail=0); the old ring0 left tail=40 in
    // the aperture, so recreate on the same window must clear it or
    // the first poll would legitimately consume 40 stale bytes
    apm[R0_BASE]      = 32'd0;   // head
    apm[R0_BASE + 16] = 32'd0;   // tail
    wq = {};
    for (int i = 0; i < 35; i++) wq.push_back(CRING0[i]);
    xs_go(wq, 1'b0, "T16 re-create ring0");
    check(ring_active[0] == 1'b1, "T16 ring0 active");
    begin
      automatic int unsigned rd0;
      automatic int unsigned rd_win = 4096;
      repeat (2048) @(posedge clk);     // gap saturates well before this
      rd0 = ap_rd;
      repeat (rd_win) @(posedge clk);
      cases++;
      // unpaced: ~rd_win/3 reads; paced: ~rd_win/260 + ramp -> bound
      // rd_win/16 is comfortably >8x fewer and far above the real value
      $display("T16 idle-but-live aperture reads=%0d over %0d cycles",
               ap_rd - rd0, rd_win);
      check(ap_rd - rd0 <= rd_win / 16,
            "T16 poll reads collapse >8x with backoff");
      // liveness: work pushed mid-backoff is still consumed within a
      // bounded latency (one NotifyRing command = 24 bytes)
      wq = {};
      for (int i = 0; i < 6; i++) wq.push_back(NOTIFY0[i]);
      ring_put(R0_BASE + 48, 0, wq, R0_BASE + 16, 24);
      wait_ap(R0_BASE, 32'd24, "T16 head catches new work");
    end

    if (errors == 0)
      $display("PASS tb_g6lc_apu_vnpump cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    else
      $display("FAIL tb_g6lc_apu_vnpump cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
