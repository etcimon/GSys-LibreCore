// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// ShaderCore composition test (§7a): g6lc_apu_shcore wires the
// commit scanner to the wave engine on the cmdexec work-port
// record.  The wave TB (tb_g6lc_apu_shwave) already runs the full
// corpus through this composition with vkCmdDispatch records; this
// TB covers the composition-specific arms:
//   1. a real vkCmdDispatch record on slot 0 (bufcopy_1 vector),
//   2. a non-dispatch ctype completes APU_SH_DONE_UNSUPPORTED,
//   3. vkCmdDispatchIndirect completes APU_SH_DONE_UNSUPPORTED
//      (indirect group counts need a buffer read — 5-series),
//   4. a work record held while busy is NOT dropped: work_ready_o
//      stays low and the record is accepted once the in-flight
//      dispatch completes,
//   5. a second slot commits and dispatches independently,
//   6. retire frees the slot and it commits again,
//   7. a bad module faults at commit through the same port,
//   8. Enable=0 stays quiet — monitored continuously.

module tb_g6lc_apu_shcore;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_sh_pkg::*;

  localparam int unsigned MAXW = 262144;
  localparam int unsigned MEMW = 131072;
  string  shv;
  int     checks, cases, fails;
  longint cyc;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  always_ff @(posedge clk) cyc <= cyc + 1;

  logic         wr_en;  logic [2:0]  wr_slot;  logic [15:0] wr_addr;
  logic [31:0]  wr_data;
  logic         commit; apu_sh_commit_t commit_pl;
  logic         c_busy; logic c_done; apu_sh_cpl_t c_done_pl;
  logic         retire; logic [2:0]  retire_slot;
  logic         sm_req; apu_sh_sm_req_t sm_pl;
  logic         sm_cpl; apu_sh_sm_cpl_t sm_cpl_pl;
  logic         work;   logic        work_ready;
  logic [31:0]  work_ctype;
  logic [8*32-1:0] work_imm;
  logic [2:0]   disp_slot;
  apu_sh_desc_t desc;
  logic [5:0]   push_n;
  logic [1023:0] push;
  logic         busy, done; apu_sh_done_t done_pl;
  logic         mem_re, mem_we;
  logic [63:0]  mem_addr, mem_wdata;
  logic [7:0]   mem_wstrb;
  logic [63:0]  mem_rdata;

  logic         off_c_busy, off_c_done;
  apu_sh_cpl_t  off_c_pl;
  logic         off_ready, off_busy, off_done;
  apu_sh_done_t off_pl;
  logic         off_mem_re, off_mem_we;
  logic [63:0]  off_mem_addr, off_mem_wdata;
  logic [7:0]   off_mem_wstrb;

  g6lc_apu_shcore #(.Enable(1)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .c_busy_o(c_busy), .c_done_o(c_done), .c_done_pl_o(c_done_pl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .sm_req_i(sm_req), .sm_req_pl_i(sm_pl),
    .sm_cpl_o(sm_cpl), .sm_cpl_pl_o(sm_cpl_pl),
    .work_i(work), .work_ready_o(work_ready),
    .work_ctype_i(work_ctype), .work_imm_i(work_imm),
    .disp_slot_i(disp_slot), .desc_i(desc),
    .push_n_i(push_n), .push_i(push),
    .busy_o(busy), .done_o(done), .done_pl_o(done_pl),
    .mem_re_o(mem_re), .mem_we_o(mem_we), .mem_addr_o(mem_addr),
    .mem_wdata_o(mem_wdata), .mem_wstrb_o(mem_wstrb),
    .mem_ready_i(1'b1), .mem_rvalid_i(mem_rv),
    .mem_rdata_i(mem_rdata), .mem_err_i(1'b0));

  logic off_sm_cpl; apu_sh_sm_cpl_t off_sm_pl;
  g6lc_apu_shcore #(.Enable(0)) off (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .c_busy_o(off_c_busy), .c_done_o(off_c_done),
    .c_done_pl_o(off_c_pl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .sm_req_i(sm_req), .sm_req_pl_i(sm_pl),
    .sm_cpl_o(off_sm_cpl), .sm_cpl_pl_o(off_sm_pl),
    .work_i(work), .work_ready_o(off_ready),
    .work_ctype_i(work_ctype), .work_imm_i(work_imm),
    .disp_slot_i(disp_slot), .desc_i(desc),
    .push_n_i(push_n), .push_i(push),
    .busy_o(off_busy), .done_o(off_done), .done_pl_o(off_pl),
    .mem_re_o(off_mem_re), .mem_we_o(off_mem_we),
    .mem_addr_o(off_mem_addr), .mem_wdata_o(off_mem_wdata),
    .mem_wstrb_o(off_mem_wstrb),
    .mem_ready_i(1'b1), .mem_rvalid_i(1'b0),
    .mem_rdata_i('0), .mem_err_i(1'b0));

  // continuous Enable=0 quiet monitor — sticky flag (fails is
  // written from the initial process; counted once at the end)
  logic off_bad;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) off_bad <= 1'b0;
    else if (!off_bad &&
             (off_c_busy | off_c_done | (|off_c_pl) |
              off_sm_cpl | (|off_sm_pl) |
              off_ready | off_busy | off_done | (|off_pl) |
              off_mem_re | off_mem_we | (|off_mem_addr) |
              (|off_mem_wdata) | (|off_mem_wstrb))) begin
      off_bad <= 1'b1;
      $display("FAIL Enable=0 activity at cycle %0d", cyc);
    end
  end

  // guest memory: handshake port (ready=1, rvalid next cycle), same
  // model as the wave TB
  logic         mem_rv = 0;
  logic [63:0] mem [0:MEMW-1];
  always_ff @(posedge clk or negedge rst_n) begin
    logic [63:0] wm;
    if (!rst_n) begin
      mem_rv <= 1'b0; mem_rdata <= '0;
    end else begin
      mem_rv <= 1'b0;
      if (mem_we) begin
        wm = mem[mem_addr[19:3]];
        for (int b = 0; b < 8; b++)
          if (mem_wstrb[b]) wm[8*b +: 8] = mem_wdata[8*b +: 8];
        mem[mem_addr[19:3]] <= wm;
        mem_rv <= 1'b1;
      end
      if (mem_re) begin
        mem_rdata <= mem[mem_addr[19:3]];
        mem_rv <= 1'b1;
      end
    end
  end

  logic [31:0] wbuf [MAXW];
  logic [31:0] ebuf [MAXW];

  task automatic cmp(input string nm, input logic [31:0] got,
                     input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      fails++;
      $display("FAIL %s got=%08x exp=%08x", nm, got, exp);
    end
  endtask

  task automatic wr_words(input int base, input int n, input int slot);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      wr_en = 1; wr_slot = slot[2:0]; wr_addr = i[15:0];
      wr_data = wbuf[base + i];
    end
    @(negedge clk); wr_en = 0;
  endtask

  task automatic do_commit(input int nwords, input int slot,
                           output apu_sh_cpl_t pl);
    @(negedge clk);
    commit = 1;
    commit_pl = '{slot: slot[2:0], nwords: nwords[15:0]};
    @(negedge clk); commit = 0;
    for (int g = 0; g < 2000000; g++) begin
      @(negedge clk);
      if (c_done) break;
    end
    if (!c_done) begin
      fails++; $display("FAIL commit timeout slot=%0d", slot);
    end
    pl = c_done_pl;
  endtask

  // present a work record; holds it until work_ready_o accepts it
  task automatic put_work(input logic [31:0] ctype, input int gx,
                          input int gy, input int gz, input int slot);
    work = 1; work_ctype = ctype;
    work_imm = '0;
    work_imm[15:0]  = gx[15:0];
    work_imm[47:32] = gy[15:0];
    work_imm[79:64] = gz[15:0];
    disp_slot = slot[2:0];
  endtask

  task automatic wait_done(input logic [31:0] ctype,
                           output apu_sh_done_t pl);
    // UNSUPPORTED replies pulse done the cycle after accept, so
    // check before waiting another negedge
    for (int g = 0; g < 20000000; g++) begin
      if (done) break;
      @(negedge clk);
    end
    if (!done) begin
      fails++; $display("FAIL work timeout ctype=%0d", ctype);
    end
    pl = done_pl;
  endtask

  task automatic do_work(input logic [31:0] ctype, input int gx,
                         input int gy, input int gz, input int slot,
                         output apu_sh_done_t pl);
    put_work(ctype, gx, gy, gz, slot);
    // hold the record until work_ready_o accepts it
    do @(negedge clk); while (!work_ready);
    @(negedge clk); work = 0;
    wait_done(ctype, pl);
  endtask

  task automatic retire_do(input int slot);
    @(negedge clk); retire = 1; retire_slot = slot[2:0];
    @(negedge clk); retire = 0;
  endtask

  // one slot-manager request; cpl pulses on the accept cycle's next
  // clock, visible at the second negedge
  task automatic sm_op(input apu_sh_sm_op_e op, input int slot,
                       output apu_sh_sm_cpl_t pl);
    @(negedge clk);
    sm_req = 1; sm_pl = '{op: op, slot: slot[2:0]};
    @(negedge clk);
    sm_req = 0; pl = sm_cpl_pl;
    checks++;
    if (sm_cpl !== 1'b1) begin
      fails++; $display("FAIL sm no completion op=%0d", op);
    end
  endtask

  // stage vector file + bindings + buffers for one slot
  task automatic stage(input string file, input int slot,
                       output int n, output int nb, output int np,
                       output int gx, output int gy, output int gz);
    int base;
    $readmemh({shv, "/", file, ".hex"}, wbuf);
    $readmemh({shv, "/", file, ".exp"}, ebuf);
    n  = wbuf[0]; nb = wbuf[1]; np = wbuf[2];
    gx = wbuf[3]; gy = wbuf[4]; gz = wbuf[5];
    base = 8 + n;
    // §12.3 F5: bindings -> aperture descriptor records + sideband.
    // 5-word entries {set,binding,size,addr,aux={kind,dyn,idx}};
    // elements of a (set,binding) share one boff row.
    desc = '0;
    begin
      int ecnt [4];
      int dord [4];
      int nrow [4];
      int row_of [32];
      int row_cnt [4][16];
      int row_off [4][16];
      int row_dynb [4][16];
      bit row_dyn [4][16];
      for (int i = 0; i < 4; i++) begin
        ecnt[i] = 0; dord[i] = 0; nrow[i] = 0;
        desc.set_base[i] = 32'hF0000 + 32'(i) * 32'd1024;
        for (int r = 0; r < 16; r++) begin
          row_cnt[i][r] = 0; row_off[i][r] = 0;
          row_dynb[i][r] = 0; row_dyn[i][r] = 0;
        end
      end
      for (int b = 0; b < nb; b++) begin
        logic [7:0] st, bd;
        st = wbuf[base + b*5 + 0][7:0];
        bd = wbuf[base + b*5 + 1][7:0];
        row_of[b] = -1;
        for (int c = 0; c < b; c++)
          if (wbuf[base + c*5 + 0][7:0] == st &&
              wbuf[base + c*5 + 1][7:0] == bd)
            row_of[b] = row_of[c];
        if (row_of[b] < 0 && st < 4 && nrow[st] < 16) begin
          row_of[b] = nrow[st];
          row_off[st][nrow[st]] = ecnt[st];
          row_dyn[st][nrow[st]] = wbuf[base + b*5 + 4][8];
          row_dynb[st][nrow[st]] = dord[st];
          nrow[st]++;
        end
        if (row_of[b] >= 0) begin
          int r = row_of[b];
          int i2 = wbuf[base + b*5 + 4][7:0];
          row_cnt[st][r] = (i2 + 1 > row_cnt[st][r])
                           ? i2 + 1 : row_cnt[st][r];
          ecnt[st] = row_off[st][r] + row_cnt[st][r] > ecnt[st]
                     ? row_off[st][r] + row_cnt[st][r] : ecnt[st];
          if (row_dyn[st][r])
            dord[st] = (row_dynb[st][r] + i2 + 1 > dord[st])
                       ? row_dynb[st][r] + i2 + 1 : dord[st];
        end
      end
      for (int b = 0; b < nb; b++) begin
        logic [7:0] st, bd, kind;
        logic [31:0] sz;
        logic [63:0] ad;
        int        i2, r;
        longint    ra;
        st   = wbuf[base + b*5 + 0][7:0];
        bd   = wbuf[base + b*5 + 1][7:0];
        sz   = wbuf[base + b*5 + 2];
        ad   = {32'h0, wbuf[base + b*5 + 3]};
        i2   = wbuf[base + b*5 + 4][7:0];
        kind = wbuf[base + b*5 + 4][23:16];
        if (kind == 8'h00) kind = 8'h06;
        if (row_of[b] >= 0) begin
          r  = row_of[b];
          ra = 64'(desc.set_base[st[1:0]]) +
               64'(row_off[st][r] + i2) * 32;
          desc.boff[st[1:0]][r[3:0]] =
              '{binding: bd, count: 16'(row_cnt[st][r]),
                off32: 20'(row_off[st][r]), dyn: row_dyn[st][r],
                dynbase: 4'(row_dynb[st][r])};
          mem[ra >> 3]       = {sz, ad[31:0]};
          mem[(ra + 8) >> 3] = {48'h0, 8'h01, kind};
        end
      end
    end
    base += nb * 5;
    push_n = np[5:0];
    push = '0;
    for (int i = 0; i < np && i < 32; i++)
      push[i*32 +: 32] = wbuf[base + i];
    base += np;
    // dynamic-offset section: n entries {set, ord, off}
    begin
      int nd = int'(wbuf[base]);
      base += 1;
      for (int d = 0; d < nd; d++) begin
        desc.dyn_off[wbuf[base + d*3 + 0][1:0]]
                    [wbuf[base + d*3 + 1][3:0]] =
            wbuf[base + d*3 + 2];
      end
      base += nd * 3;
    end
    for (int b = 0; b < nb; b++) begin
      logic [31:0] sz;
      logic [63:0] ad;
      sz = wbuf[8 + n + b*5 + 2];
      ad = {32'h0, wbuf[8 + n + b*5 + 3]};
      for (int w2 = 0; w2 < sz/4; w2++) begin
        if ((ad + w2*4) & 7)
          mem[(ad + w2*4) >> 3][63:32] = wbuf[base + w2];
        else
          mem[(ad + w2*4) >> 3][31:0] = wbuf[base + w2];
      end
      base += sz/4;
    end
  endtask

  // compare output binding words in the aperture model against the
  // vector's model section (ebuf[4] binding records, then oracle words,
  // then model words — same layout as the shwave .exp).
  task automatic cmp_out(input string tag);
    int ebase2, mbase2, now2;
    ebase2 = 5 + ebuf[4] * 4;
    now2 = 0;
    for (int b = 0; b < ebuf[4]; b++)
      if (ebuf[5 + b*4 + 3]) now2 += int'(ebuf[5 + b*4 + 1]) / 4;
    mbase2 = ebase2 + now2;
    for (int b = 0; b < ebuf[4]; b++) begin
      logic [31:0] sz, eo;
      logic [63:0] ad;
      sz = ebuf[5 + b*4 + 1];
      ad = {32'h0, ebuf[5 + b*4 + 2]};
      eo = ebuf[5 + b*4 + 3];
      if (eo) begin
        for (int w2 = 0; w2 < sz/4; w2++) begin
          longint    aa;
          logic [31:0] got;
          aa = ad + w2*4;
          got = (aa & 7) ? mem[aa >> 3][63:32] : mem[aa >> 3][31:0];
          checks++;
          if (got !== ebuf[mbase2 + w2]) begin
            fails++;
            $display("FAIL %s.out b%0d[%0d]@%x got=%08x exp=%08x",
                     tag, b, w2, aa, got, ebuf[mbase2 + w2]);
          end
        end
        ebase2 += int'(sz) / 4;
        mbase2 += int'(sz) / 4;
      end
    end
  endtask

  initial begin
    int n, nb, np, gx, gy, gz;
    int held;
    apu_sh_cpl_t  cpl;
    apu_sh_done_t dpl;
    if (!$value$plusargs("shv=%s", shv)) shv = "verif/tb/apu/sh_vectors";
    checks = 0; cases = 0; fails = 0; cyc = 0;
    wr_en = 0; commit = 0; retire = 0; work = 0; work_ctype = 0;
    sm_req = 0; sm_pl = '0;
    work_imm = '0; disp_slot = 0; desc = '0; push_n = 0; push = '0;
    for (int i = 0; i < MEMW; i++) mem[i] = '0;
    repeat (8) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    // 1. commit bufcopy_1 on slot 0, dispatch via vkCmdDispatch
    cases++;
    stage("bufcopy_1", 0, n, nb, np, gx, gy, gz);
    wr_words(8, n, 0);
    do_commit(n, 0, cpl);
    cmp("s0.commit.ok", {31'h0, cpl.ok}, 1);
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 0, dpl);
    cmp("s0.done.code", {24'h0, dpl.code}, APU_SH_DONE_OK);

    // 2. non-dispatch ctype → UNSUPPORTED
    cases++;
    do_work(32'd999, 0, 0, 0, 0, dpl);
    cmp("unsup.code", {24'h0, dpl.code}, APU_SH_DONE_UNSUPPORTED);

    // 3. vkCmdDispatchIndirect → UNSUPPORTED in 4a (group counts live
    //    in a buffer — reading them is a 5-series integration item)
    cases++;
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_INDIRECT_EXT),
            gx, gy, gz, 0, dpl);
    cmp("ind.code", {24'h0, dpl.code}, APU_SH_DONE_UNSUPPORTED);

    // 4. work held while busy: present a record during an in-flight
    //    dispatch — work_ready_o must be low and the record must be
    //    accepted afterwards (not dropped): a second done arrives.
    cases++;
    put_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 0);
    do @(negedge clk); while (!work_ready);
    @(negedge clk);
    // the dispatch is now in flight; hold an UNSUPPORTED record and
    // verify ready stays low while busy
    work = 1; work_ctype = 32'd999; work_imm = '0;
    held = 0;
    for (int g = 0; g < 20000000; g++) begin
      if (done) break;
      if (busy) begin
        checks++;
        if (work_ready !== 1'b0) begin
          fails++;
          $display("FAIL work_ready_o high while busy");
        end
        held = 1;
      end
      @(negedge clk);
    end
    if (!done) begin
      fails++; $display("FAIL held-work dispatch timeout");
    end else begin
      cmp("held.disp.code", {24'h0, done_pl.code}, APU_SH_DONE_OK);
    end
    checks++;
    if (!held) begin
      fails++; $display("FAIL busy window never observed");
    end
    // the held record must still be accepted → UNSUPPORTED done
    do @(negedge clk); while (!work_ready);
    @(negedge clk); work = 0;
    wait_done(32'd999, dpl);
    cmp("held.code", {24'h0, dpl.code}, APU_SH_DONE_UNSUPPORTED);

    // 5. commit the same module on slot 1, dispatch there
    cases++;
    wr_words(8, n, 1);
    do_commit(n, 1, cpl);
    cmp("s1.commit.ok", {31'h0, cpl.ok}, 1);
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 1, dpl);
    cmp("s1.done.code", {24'h0, dpl.code}, APU_SH_DONE_OK);

    // 6. retire slot 0 then commit it again
    cases++;
    retire_do(0);
    wr_words(8, n, 0);
    do_commit(n, 0, cpl);
    cmp("re.commit.ok", {31'h0, cpl.ok}, 1);

    // 7. one §7c 4b vector: loopfor_1 (OpLoopMerge/OpBranchConditional
    //    control flow) commits and dispatches through the composition
    cases++;
    stage("loopfor_1", 3, n, nb, np, gx, gy, gz);
    wr_words(8, n, 3);
    do_commit(n, 3, cpl);
    cmp("s3.commit.ok", {31'h0, cpl.ok}, 1);
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 3, dpl);
    cmp("s3.done.code", {24'h0, dpl.code}, APU_SH_DONE_OK);

    // 7b. F5 descriptor array: descarr_1 indexes a 4-element SSBO
    //     array dynamically; output checked vs the model words
    cases++;
    stage("descarr_1", 4, n, nb, np, gx, gy, gz);
    wr_words(8, n, 4);
    do_commit(n, 4, cpl);
    cmp("da.commit.ok", {31'h0, cpl.ok}, 1);
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 4, dpl);
    cmp("da.done.code", {24'h0, dpl.code}, APU_SH_DONE_OK);
    cmp("da.robust", dpl.robust, ebuf[2]);
    cmp_out("da");

    // 7c. F5 four sets + dynamic offset: multiset_1 binds one SSBO per
    //     set, set 2 a dynamic descriptor with a non-zero offset
    cases++;
    stage("multiset_1", 5, n, nb, np, gx, gy, gz);
    wr_words(8, n, 5);
    do_commit(n, 5, cpl);
    cmp("ms.commit.ok", {31'h0, cpl.ok}, 1);
    do_work(32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT), gx, gy, gz, 5, dpl);
    cmp("ms.done.code", {24'h0, dpl.code}, APU_SH_DONE_OK);
    cmp("ms.robust", dpl.robust, ebuf[2]);
    cmp_out("ms");

    // 8. bad module faults at commit through the same port
    cases++;
    stage("bufcopy_bad_0", 2, n, nb, np, gx, gy, gz);
    wr_words(8, n, 2);
    do_commit(n, 2, cpl);
    cmp("bad.commit.ok", {31'h0, cpl.ok}, 0);
    cmp("bad.commit.code", {24'h0, cpl.fault.code}, ebuf[0]);
    retire_do(2);

    // 8. slot manager (§7b): ALLOC/REF/UNREF lifecycle, retire-at-0
    //    reuse, underflow/dead-ref refusal, full pool
    cases++;
    begin
      apu_sh_sm_cpl_t spl;
      sm_op(APU_SH_SM_ALLOC, 0, spl);
      cmp("sm.alloc0.ok",   {31'h0, spl.ok}, 1);
      cmp("sm.alloc0.slot", {29'h0, spl.slot}, 0);
      sm_op(APU_SH_SM_REF, 0, spl);
      cmp("sm.ref.ok",      {31'h0, spl.ok}, 1);
      sm_op(APU_SH_SM_UNREF, 0, spl);          // users 2 -> 1
      sm_op(APU_SH_SM_ALLOC, 0, spl);
      cmp("sm.alloc1.slot", {29'h0, spl.slot}, 1);
      sm_op(APU_SH_SM_UNREF, 0, spl);          // users 1 -> 0: retire
      sm_op(APU_SH_SM_UNREF, 0, spl);
      cmp("sm.underflow",   {31'h0, spl.ok}, 0);
      sm_op(APU_SH_SM_REF, 0, spl);
      cmp("sm.refdead",     {31'h0, spl.ok}, 0);
      // fill the pool: slots 0,2..7 get users=1 (slot 1 still held)
      for (int s = 0; s < 7; s++) sm_op(APU_SH_SM_ALLOC, 0, spl);
      sm_op(APU_SH_SM_ALLOC, 0, spl);
      cmp("sm.full",        {31'h0, spl.ok}, 0);
      for (int s = 0; s < 8; s++) sm_op(APU_SH_SM_UNREF, s, spl);
    end

    // 9. Enable=0 quiet (continuous monitor + final check)
    checks++;
    if (off_bad) begin
      fails++; $display("FAIL Enable=0 not quiet");
    end

    $display("PASS tb_g6lc_apu_shcore cases=%0d checks=%0d cycles=%0d",
             cases, checks, cyc);
    if (fails) begin
      $display("FAILURES=%0d", fails);
      $fatal(1);
    end
    $finish;
  end
endmodule
