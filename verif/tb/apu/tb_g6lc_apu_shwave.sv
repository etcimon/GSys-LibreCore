// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Wave-engine test through g6lc_apu_shcore (§7a).  Two hard gates:
//
//   Gate 1 (bit-exact): every output word and the robustness count
//   must equal spirv_model.py — the reference interpreter for the
//   §7a 4a subset that replicates the RTL's own micro-sequences
//   (see "ShaderCore arithmetic definitions" in
//   g6lc_apu_vn_tables.md).  Applies to every committed case,
//   INCLUDING mutated modules (the .exp model section is the
//   mutant's own model run).
//
//   Gate 2 (oracle): RTL vs the lavapipe oracle words —
//   integer/bool-classed words bit-exact, float-classed words
//   within 2 ULP (sign-aware, ±0 equal, NaN==NaN).  Per-shader
//   max ULP and 1/2-ULP word counts are reported.  For mutated
//   modules Gate 2 is only the §7a "output differs" rule (the
//   oracle section carries the UNMUTATED oracle words).
//
// Commit-fault cases fault at commit; the Enable=0 fixture is
// monitored continuously for any output activity.  Cycles per
// dispatch are reported per case.
//
// .exp layout (shader_vectors.py v2):
//   [0] fault code  [1] fault opcode  [2] MODEL robust count
//   [3] expect_done [4] n_bindings
//   nb × {binding, size_bytes, mem_addr, is_out}
//   oracle section:  per is_out binding, size/4 lavapipe words
//   model section:   per is_out binding, size/4 spirv_model words
//   class section:   per is_out binding, size/4 class words
//                    (0 = int/bool bit-exact, 1 = float ≤2 ULP)
//
// §12.3 F5: the vector's {set,binding,size,addr} binding list is
// materialised as aperture-resident descriptor records (32 B each,
// {base,size,kind,flags} in the first two 64-bit beats) plus a
// desc sideband {set_base, boff rows, dyn_off} — matches
// g6lc_apu_shwave's LSU resolver.  Records park at RECBASE upward
// per set (512 B window each), above every buffer the vectors use.
localparam int unsigned RECBASE = 32'hF0000;   // 960 KiB, 1 KiB/set

module tb_g6lc_apu_shwave;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_sh_pkg::*;

  localparam int unsigned MAXW = 262144;   // hex/exp word buffers
  localparam int unsigned MEMW = 131072;   // 64-bit mem words (1 MiB)
  string  shv;
  string  only;
  bit     dbg_sc, dbg_wd;
  int     checks, cases, fails;
  int     ulp1c, ulp2c, maxulp;            // Gate-2 ULP counters
  longint cyc, dcyc;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  always_ff @(posedge clk) cyc <= cyc + 1;
  // scheduler-state watchdog, one line per 100k cycles (+dbg_wd)
  always_ff @(posedge clk)
    if (dbg_wd && cyc % 100000 == 99999)
      $display("DBG cyc=%0d st=%0d wv=%0d pc=%0d cfn=%0d act=%x fin=%x bar=%x nwg=%0d",
               cyc, dut.gen_on.i_wave.gen_on.st_q,
               dut.gen_on.i_wave.gen_on.wave_q,
               dut.gen_on.i_wave.gen_on.pc_q[
                 dut.gen_on.i_wave.gen_on.wave_q],
               dut.gen_on.i_wave.gen_on.cfn_q[
                 dut.gen_on.i_wave.gen_on.wave_q],
               dut.gen_on.i_wave.gen_on.cmask_q[
                 dut.gen_on.i_wave.gen_on.wave_q],
               dut.gen_on.i_wave.gen_on.wfin_q,
               dut.gen_on.i_wave.gen_on.wbar_q,
               dut.gen_on.i_wave.gen_on.nwaves_q);

  // ---- DUT ----------------------------------------------------------
  logic         wr_en;  logic [2:0]  wr_slot;  logic [15:0] wr_addr;
  logic [31:0]  wr_data;
  logic         commit; apu_sh_commit_t commit_pl;
  logic         c_busy; logic c_done; apu_sh_cpl_t c_done_pl;
  logic         retire; logic [2:0]  retire_slot;
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

  g6lc_apu_shcore #(.Enable(1)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .c_busy_o(c_busy), .c_done_o(c_done), .c_done_pl_o(c_done_pl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .sm_req_i(1'b0), .sm_req_pl_i('0), .sm_cpl_o(), .sm_cpl_pl_o(),
    .work_i(work), .work_ready_o(work_ready),
    .work_ctype_i(work_ctype), .work_imm_i(work_imm),
    .disp_slot_i(disp_slot), .desc_i(desc),
    .push_n_i(push_n), .push_i(push),
    .busy_o(busy), .done_o(done), .done_pl_o(done_pl),
    .mem_re_o(mem_re), .mem_we_o(mem_we), .mem_addr_o(mem_addr),
    .mem_wdata_o(mem_wdata), .mem_wstrb_o(mem_wstrb),
    .mem_ready_i(1'b1), .mem_rvalid_i(mem_rv),
    .mem_rdata_i(mem_rdata), .mem_err_i(1'b0));

  // Enable=0 fixture — every externally visible output is wired and
  // monitored continuously below.
  logic        off_cbusy, off_cdone; apu_sh_cpl_t off_cpl;
  logic        off_ready, off_busy, off_done; apu_sh_done_t off_pl;
  logic        off_re, off_we;
  logic [63:0] off_addr, off_wdata;
  logic [7:0]  off_strb;
  g6lc_apu_shcore #(.Enable(0)) off (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .c_busy_o(off_cbusy), .c_done_o(off_cdone),
    .c_done_pl_o(off_cpl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .sm_req_i(1'b0), .sm_req_pl_i('0), .sm_cpl_o(), .sm_cpl_pl_o(),
    .work_i(work), .work_ready_o(off_ready),
    .work_ctype_i(work_ctype), .work_imm_i(work_imm),
    .disp_slot_i(disp_slot), .desc_i(desc),
    .push_n_i(push_n), .push_i(push),
    .busy_o(off_busy), .done_o(off_done), .done_pl_o(off_pl),
    .mem_re_o(off_re), .mem_we_o(off_we), .mem_addr_o(off_addr),
    .mem_wdata_o(off_wdata), .mem_wstrb_o(off_strb),
    .mem_ready_i(1'b1), .mem_rvalid_i(1'b0),
    .mem_rdata_i('0), .mem_err_i(1'b0));

  // continuous Enable=0 quiet monitor — sticky flag; the failure is
  // counted once at the end (fails is written from the initial
  // process, so the monitor only sets the flag).
  logic off_bad;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) off_bad <= 1'b0;
    else if (!off_bad &&
             (off_cbusy | off_cdone | (|off_cpl) |
              off_ready | off_busy | off_done | (|off_pl) |
              off_re | off_we | (|off_addr) | (|off_wdata) |
              (|off_strb))) begin
      off_bad <= 1'b1;
      $display("FAIL Enable=0 activity at cycle %0d", cyc);
    end
  end

  // ---- memory model: handshake port (ready=1, rvalid next cycle) ---
  logic         mem_rv = 0;
  logic [63:0] mem [0:MEMW-1];
  logic         dbg_dsc;  int dbg_dsc_n = 0;
  initial dbg_dsc = $test$plusargs("dbg_dsc");
  // +dbg_flt: report the state that raised a dispatch fault
  logic dbg_flt;
  logic [7:0] flt_prev;
  initial begin dbg_flt = $test$plusargs("dbg_flt"); flt_prev = '0; end
  always_ff @(posedge clk) begin
    if (dbg_flt && flt_prev != 8'hFF &&
        dut.gen_on.i_wave.gen_on.done_code_q ==
          APU_SH_DONE_FAULT) begin
      $display("FLT cyc=%0d prev_st=%0d pc=%0d opc=%0d wc=%0d lane=%0d",
               cyc, flt_prev,
               dut.gen_on.i_wave.gen_on.pc_q[
                 dut.gen_on.i_wave.gen_on.wave_q],
               dut.gen_on.i_wave.gen_on.opc_q,
               dut.gen_on.i_wave.gen_on.wc_q,
               dut.gen_on.i_wave.gen_on.ls_lane_q);
      flt_prev <= 8'hFF;
    end else if (dut.gen_on.i_wave.gen_on.done_code_q !=
                 APU_SH_DONE_FAULT)
      flt_prev <= 8'(dut.gen_on.i_wave.gen_on.st_q);
  end

  // +dbg_tx: dump the texture-path datapath for one op
  logic dbg_tx;
  initial dbg_tx = $test$plusargs("dbg_tx");
  always_ff @(posedge clk)
    if (dbg_tx) begin
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd110)    // W_TX2
        $display("TX1 cyc=%0d pc=%0d wv=%0d act=%x lane=%0d v1=%08x %08x %08x %08x iu=%0d iv=%0d",
                 cyc,
                 dut.gen_on.i_wave.gen_on.pc_q[
                   dut.gen_on.i_wave.gen_on.wave_q],
                 dut.gen_on.i_wave.gen_on.wave_q,
                 dut.gen_on.i_wave.gen_on.cmask_q[
                   dut.gen_on.i_wave.gen_on.wave_q],
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.va_q[1][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][0],
                 dut.gen_on.i_wave.gen_on.va_q[1][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][1],
                 dut.gen_on.i_wave.gen_on.va_q[1][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][2],
                 dut.gen_on.i_wave.gen_on.va_q[1][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][3],
                 dut.gen_on.i_wave.gen_on.tx_iu_q,
                 dut.gen_on.i_wave.gen_on.tx_iv_q);
    end
  always_ff @(posedge clk)
    if (dbg_tx &&
        (dut.gen_on.i_wave.gen_on.st_q == 8'd65 ||   // W_EOW
         dut.gen_on.i_wave.gen_on.st_q == 8'd68 ||   // W_WG0
         dut.gen_on.i_wave.gen_on.st_q == 8'd66 ||   // W_DONE
         dut.gen_on.i_wave.gen_on.st_q == 8'd2))     // W_ENT1
      $display("TE  cyc=%0d st=%0d gx=%0d gy=%0d gz=%0d wgx=%0d wgy=%0d wgz=%0d wfin=%x",
               cyc, dut.gen_on.i_wave.gen_on.st_q,
               dut.gen_on.i_wave.gen_on.gx_q,
               dut.gen_on.i_wave.gen_on.gy_q,
               dut.gen_on.i_wave.gen_on.gz_q,
               dut.gen_on.i_wave.gen_on.wgx_q,
               dut.gen_on.i_wave.gen_on.wgy_q,
               dut.gen_on.i_wave.gen_on.wgz_q,
               dut.gen_on.i_wave.gen_on.wfin_q);
  always_ff @(posedge clk)
    if (dbg_tx &&
        dut.gen_on.i_wave.gen_on.st_q == 8'd6) begin  // W_F1
      $display("TF  cyc=%0d pc=%04x opc=%0d wc=%0d wv=%0d", cyc,
               dut.gen_on.i_wave.gen_on.pc_q[0],
               dut.gen_on.i_wave.gen_on.prog_data_i[15:0],
               dut.gen_on.i_wave.gen_on.prog_data_i[31:16],
               dut.gen_on.i_wave.gen_on.wave_q);
    end
  always_ff @(posedge clk)
    if (dbg_tx &&
        dut.gen_on.i_wave.gen_on.st_q == 8'd63) begin // W_WB
      $display("TWB cyc=%0d pc=%04x opc=%0d", cyc,
               dut.gen_on.i_wave.gen_on.pc_q[0],
               dut.gen_on.i_wave.gen_on.opc_q);
      for (int l = 0; l < 8; l++)
        $display("TWB cyc=%0d l%0d %08x %08x %08x %08x", cyc, l,
                 dut.gen_on.i_wave.gen_on.wb_q[l][0],
                 dut.gen_on.i_wave.gen_on.wb_q[l][1],
                 dut.gen_on.i_wave.gen_on.wb_q[l][2],
                 dut.gen_on.i_wave.gen_on.wb_q[l][3]);
    end
  always_ff @(posedge clk)
    if (dbg_tx) begin
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd110)   // W_TX2
        $display("TX2 cyc=%0d opc=%0d lane=%0d set=%0d bd=%0d idx=%0d rec=%08x tg=%08x",
                 cyc,
                 dut.gen_on.i_wave.gen_on.opc_q,
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.dsc_set_q,
                 dut.gen_on.i_wave.gen_on.dsc_bd_q,
                 dut.gen_on.i_wave.gen_on.dsc_idx_q,
                 dut.gen_on.i_wave.gen_on.tx_rec_q[31:0],
                 dut.gen_on.i_wave.gen_on.va_q[0][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][1]);
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd127)   // W_TXD
        $display("TXD cyc=%0d pc=%0d wv=%0d act=%x lane=%0d gi=%0d gn=%0d td0=%x td1=%x brd=%0d ta=%x",
                 cyc,
                 dut.gen_on.i_wave.gen_on.pc_q[
                   dut.gen_on.i_wave.gen_on.wave_q],
                 dut.gen_on.i_wave.gen_on.wave_q,
                 dut.gen_on.i_wave.gen_on.cmask_q[
                   dut.gen_on.i_wave.gen_on.wave_q],
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.tx_gi_q,
                 dut.gen_on.i_wave.gen_on.tx_gn_q,
                 dut.gen_on.i_wave.gen_on.tx_td_q[0],
                 dut.gen_on.i_wave.gen_on.tx_td_q[1],
                 dut.gen_on.i_wave.gen_on.tx_brd_q,
                 dut.gen_on.i_wave.gen_on.tx_ta_q);
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd122)   // W_TXT0
        $display("TXG cyc=%0d lane=%0d smp=%016x lin=%0d gn=%0d g0=%0d,%0d,b%0d,w%0d g1=%0d,%0d,b%0d,w%0d g2=%0d,%0d,b%0d,w%0d g3=%0d,%0d,b%0d,w%0d g4=%0d,%0d,b%0d,w%0d g5=%0d,%0d,b%0d,w%0d g6=%0d,%0d,b%0d,w%0d g7=%0d,%0d,b%0d,w%0d",
                 cyc,
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.tx_smp_q,
                 dut.gen_on.i_wave.gen_on.tx_lin_q,
                 dut.gen_on.i_wave.gen_on.tx_gn_q,
                 dut.gen_on.i_wave.gen_on.tx_gu_q[0],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[0],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[0],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[0],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[1],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[1],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[1],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[1],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[2],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[2],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[2],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[2],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[3],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[3],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[3],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[3],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[4],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[4],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[4],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[4],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[5],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[5],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[5],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[5],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[6],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[6],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[6],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[6],
                 dut.gen_on.i_wave.gen_on.tx_gu_q[7],
                 dut.gen_on.i_wave.gen_on.tx_gv_q[7],
                 dut.gen_on.i_wave.gen_on.tx_gb_q[7],
                 dut.gen_on.i_wave.gen_on.tx_gw_q[7]);
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd132)   // W_TXR0
        $display("TXR cyc=%0d pc=%0d lane=%0d acc=%x %x %x %x bad=%0d int=%0d flt=%0d",
                 cyc,
                 dut.gen_on.i_wave.gen_on.pc_q[
                   dut.gen_on.i_wave.gen_on.wave_q],
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.tx_acc_q[0],
                 dut.gen_on.i_wave.gen_on.tx_acc_q[1],
                 dut.gen_on.i_wave.gen_on.tx_acc_q[2],
                 dut.gen_on.i_wave.gen_on.tx_acc_q[3],
                 dut.gen_on.i_wave.gen_on.tx_bad_q,
                 dut.gen_on.i_wave.gen_on.tx_isint_q,
                 dut.gen_on.i_wave.gen_on.tx_isflt_q);
      if (dut.gen_on.i_wave.gen_on.st_q == 8'd54)    // W_LS0
        $display("LS0 cyc=%0d pc=%04x opc=%0d lane=%0d comp=%0d ptr=%08x tg=%08x v1=%08x",
                 cyc,
                 dut.gen_on.i_wave.gen_on.pc_q[0],
                 dut.gen_on.i_wave.gen_on.opc_q,
                 dut.gen_on.i_wave.gen_on.ls_lane_q,
                 dut.gen_on.i_wave.gen_on.ls_comp_q,
                 dut.gen_on.i_wave.gen_on.va_q[0][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][0],
                 dut.gen_on.i_wave.gen_on.va_q[0][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][1],
                 dut.gen_on.i_wave.gen_on.va_q[1][
                   dut.gen_on.i_wave.gen_on.ls_lane_q[2:0]][
                   dut.gen_on.i_wave.gen_on.ls_comp_q[1:0]]);
      if (dut.gen_on.i_wave.gen_on.sc_req)
        $display("SC  cyc=%0d we=%0d addr=%x wd=%x",
                 cyc,
                 dut.gen_on.i_wave.gen_on.sc_we,
                 dut.gen_on.i_wave.gen_on.sc_addr,
                 dut.gen_on.i_wave.gen_on.sc_wdata);
    end
  always_ff @(posedge clk or negedge rst_n) begin
    logic [63:0] wm;
    if (!rst_n) begin
      mem_rv <= 1'b0; mem_rdata <= '0;
    end else begin
      mem_rv <= 1'b0;
      if (mem_we || mem_re) begin
        if (mem_addr >= 64'(MEMW) * 8)
          $fatal(1, "mem access out of bounds: %x", mem_addr);
      end
      if (mem_we) begin
        wm = mem[mem_addr[19:3]];
        for (int b = 0; b < 8; b++)
          if (mem_wstrb[b]) wm[8*b +: 8] = mem_wdata[8*b +: 8];
        if (dbg_tx)
          $display("MEMW cyc=%0d addr=%x wd=%x strb=%x", cyc, mem_addr,
                   mem_wdata, mem_wstrb);
        mem[mem_addr[19:3]] <= wm;
        mem_rv <= 1'b1;
      end
      if (mem_re) begin
        mem_rdata <= mem[mem_addr[19:3]];
        mem_rv <= 1'b1;
        if (dbg_dsc && dbg_dsc_n < 40) begin
          dbg_dsc_n <= dbg_dsc_n + 1;
          $display("DSCRD cyc=%0d addr=%x -> %x", cyc, mem_addr,
                   mem[mem_addr[19:3]]);
        end
      end
      if (dbg_dsc && mem_we && mem_addr >= 64'hF0000)
        $display("DSCWR cyc=%0d addr=%x data=%x", cyc, mem_addr,
                 mem_wdata);
    end
  end

  logic [31:0] wbuf [MAXW];
  logic [31:0] ebuf [MAXW];

  task automatic cmp(input string nm, input logic [31:0] got,
                     input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      fails++;
      if (fails < 3000)
        $display("FAIL %s got=%08x exp=%08x", nm, got, exp);
    end
  endtask

  // Gate-2 float compare: returns the sign-aware ULP distance
  // (0 = equal incl. ±0 and NaN==NaN), capped at 32'h7FFF_FFFF.
  function automatic int unsigned ulpd(input logic [31:0] a,
                                       input logic [31:0] b);
    logic [31:0] d;
    begin
      if (a === b) return 0;
      if ((a & 32'h7FFF_FFFF) == 0 && (b & 32'h7FFF_FFFF) == 0)
        return 0;
      if (a[30:23] == 8'hFF && a[22:0] != 0 &&
          b[30:23] == 8'hFF && b[22:0] != 0)
        return 0;                          // any NaN equals any NaN
      if (a[31] != b[31]) return 32'h7FFF_FFFF;
      d = (a > b) ? a - b : b - a;
      return int'(d);
    end
  endfunction

  // fp32 bits -> real (Gate-2 'u' class; Verilator-safe manual unpack)
  function automatic real f32r(input logic [31:0] b);
    int e;
    real m;
    e = b[30:23];
    if (e == 0)
      m = b[22:0] * (2.0 ** (-149));
    else if (e == 255)
      m = 0.0;                        // inf/NaN never in unorm data
    else
      m = (1.0 + b[22:0] * (2.0 ** (-23))) * (2.0 ** (e - 127));
    return b[31] ? -m : m;
  endfunction

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

  task automatic do_dispatch(input int gx, input int gy, input int gz,
                             input int slot, output apu_sh_done_t pl);
    longint t0;
    // valid/ready: assert only after the engine is observed idle —
    // holding work high across the ready-wait lets a second accept
    // slip through on the posedge between the first observed ready
    // and deassertion (the whole dispatch ran twice).
    work_ctype = 32'(APU_VN_TYPE_VK_CMD_DISPATCH_EXT);
    work_imm = '0;
    work_imm[15:0]  = gx[15:0];
    work_imm[47:32] = gy[15:0];
    work_imm[79:64] = gz[15:0];
    disp_slot = slot[2:0];
    t0 = cyc;
    do @(negedge clk); while (!work_ready);
    work = 1;
    @(negedge clk); work = 0;
    for (int g = 0; g < 20000000; g++) begin
      @(negedge clk);
      if (done) break;
    end
    if (!done) begin
      fails++; $display("FAIL dispatch timeout");
    end
    pl = done_pl;
    dcyc = cyc - t0;
  endtask

  task automatic retire_do(input int slot);
    @(negedge clk); retire = 1; retire_slot = slot[2:0];
    @(negedge clk); retire = 0;
  endtask

  // run one vector: commit, load buffers, dispatch, compare
  // 4b-opt: saved unopt output words for the unopt==opt bit-exact
  // check — uout[name idx][seed][word pos over out bindings].
  logic [31:0] uout [38][4][2048];
  int          cur_nidx, cur_seed, ou_mism, ou_mism_t, ou_words;
  bit          is_opt;

  task automatic run_vec(input string nm, input string file);
    int n, nb, np, gx, gy, gz, flags;
    int base, ebase, mbase, cbase, now;
    int boff_w [32];                 // bind entry -> .hex word off
    apu_sh_cpl_t cpl;
    apu_sh_done_t dpl;
    int mut, diffs;
    int cmax, cn1, cn2;
    int wpos;
    int f0 = fails;
    for (int i = 0; i < MAXW; i++) begin
      wbuf[i] = '0; ebuf[i] = '0;
    end
    $readmemh({shv, "/", file, ".hex"}, wbuf);
    $readmemh({shv, "/", file, ".exp"}, ebuf);
    n  = wbuf[0]; nb = wbuf[1]; np = wbuf[2];
    gx = wbuf[3]; gy = wbuf[4]; gz = wbuf[5];
    flags = wbuf[6];
    mut = flags[1];

    // commit module words at [8..8+n)
    wr_words(8, n, 0);
    do_commit(n, 0, cpl);
    if (ebuf[0] != 0) begin                 // expected commit fault
      cmp({file, ".ok"}, {31'h0, cpl.ok}, 0);
      cmp({file, ".code"}, {24'h0, cpl.fault.code}, ebuf[0]);
      if (ebuf[1] != 0)
        cmp({file, ".opc"}, {16'h0, cpl.fault.opcode}, ebuf[1]);
      retire_do(0);
      return;
    end
    cmp({file, ".ok"}, {31'h0, cpl.ok}, 1);
    if (!cpl.ok) begin
      $display("  %s commit fault code=%0d opc=%0d word=%0d", file,
               cpl.fault.code, cpl.fault.opcode, cpl.fault.word);
      retire_do(0);
      return;
    end

    // bindings → F5 aperture descriptor records + desc sideband.
    // Each entry is 5 words {set,binding,size,addr,aux} where
    // aux = {kind[23:16], dyn[8], elem_idx[7:0]}; elements of one
    // (set,binding) share a boff row.  §12.3 C/5b: aux bit24 marks
    // an image/sampler bind — 5 meta words follow carrying the
    // record's bytes 10..27 ({h,w},{layers,mdim,fmt},swz,smp0,smp1).
    base = 8 + n;
    desc = '0;
    begin
      int ecnt [4];                    // record cursor (32 B units)
      int dord [4];                    // dynamic-element ordinal
      int nrow [4];                    // binding-row cursor
      int row_of [32];                 // bind entry -> row index
      int row_cnt [4][16];
      int row_off [4][16];
      int row_dynb [4][16];
      bit row_dyn [4][16];
      int q;
      q = base;
      for (int b = 0; b < nb; b++) begin
        boff_w[b] = q;
        q += wbuf[q + 4][24] ? 10 : 5;
      end
      for (int i = 0; i < 4; i++) begin
        ecnt[i] = 0; dord[i] = 0; nrow[i] = 0;
        desc.set_base[i] = RECBASE + 32'(i) * 32'd1024;
        for (int r = 0; r < 16; r++) begin
          row_cnt[i][r] = 0; row_off[i][r] = 0;
          row_dynb[i][r] = 0; row_dyn[i][r] = 0;
        end
      end
      // pass 1: assign each bind entry a row within its set
      for (int b = 0; b < nb; b++) begin
        logic [7:0] st, bd;
        st = wbuf[boff_w[b] + 0][7:0];
        bd = wbuf[boff_w[b] + 1][7:0];
        row_of[b] = -1;
        for (int c = 0; c < b; c++)
          if (wbuf[boff_w[c] + 0][7:0] == st &&
              wbuf[boff_w[c] + 1][7:0] == bd)
            row_of[b] = row_of[c];
        if (row_of[b] < 0 && st < 4 && nrow[st] < 16) begin
          row_of[b] = nrow[st];
          row_off[st][nrow[st]] = ecnt[st];
          row_dyn[st][nrow[st]] = wbuf[boff_w[b] + 4][8];
          row_dynb[st][nrow[st]] = dord[st];
          nrow[st]++;
        end
        if (row_of[b] >= 0) begin
          int r = row_of[b];
          int i2 = wbuf[boff_w[b] + 4][7:0];
          row_cnt[st][r] = (i2 + 1 > row_cnt[st][r])
                           ? i2 + 1 : row_cnt[st][r];
          ecnt[st] = row_off[st][r] + row_cnt[st][r] > ecnt[st]
                     ? row_off[st][r] + row_cnt[st][r] : ecnt[st];
          if (row_dyn[st][r])
            dord[st] = (row_dynb[st][r] + i2 + 1 > dord[st])
                       ? row_dynb[st][r] + i2 + 1 : dord[st];
        end
      end
      // pass 2: rows into desc.boff + records into aperture mem
      for (int b = 0; b < nb; b++) begin
        logic [7:0] st, bd, kind;
        logic [31:0] sz;
        logic [63:0] ad;
        int        i2, r;
        longint    ra;
        st   = wbuf[boff_w[b] + 0][7:0];
        bd   = wbuf[boff_w[b] + 1][7:0];
        sz   = wbuf[boff_w[b] + 2];
        ad   = {32'h0, wbuf[boff_w[b] + 3]};
        i2   = wbuf[boff_w[b] + 4][7:0];
        kind = wbuf[boff_w[b] + 4][23:16];
        if (kind == 8'h00) kind = 8'h06;
        if (row_of[b] >= 0) begin
          r  = row_of[b];
          ra = 64'(desc.set_base[st[1:0]]) +
               64'(row_off[st][r] + i2) * 32;
          desc.boff[st[1:0]][r[3:0]] =
              '{binding: bd, count: 16'(row_cnt[st][r]),
                off32: 20'(row_off[st][r]), dyn: row_dyn[st][r],
                dynbase: 4'(row_dynb[st][r])};
          // record beat 0 {size,base}; beat 1 {kind, flags=1}
          mem[ra >> 3]        = {sz, ad[31:0]};
          if (wbuf[boff_w[b] + 4][24]) begin
            // image record: meta words carry bytes 10..27
            logic [31:0] hw, mlf, swz, s0, s1;
            hw  = wbuf[boff_w[b] + 5];
            mlf = wbuf[boff_w[b] + 6];
            swz = wbuf[boff_w[b] + 7];
            s0  = wbuf[boff_w[b] + 8];
            s1  = wbuf[boff_w[b] + 9];
            mem[(ra + 8) >> 3]  = {{mlf[15:0], hw[31:16]},
                                   {hw[15:0], 8'h01, kind}};
            mem[(ra + 16) >> 3] = {s0, {4'h0, swz[11:0],
                                        mlf[31:16]}};
            mem[(ra + 24) >> 3] = {32'h0, s1};
          end else begin
            mem[(ra + 8) >> 3]  = {48'h0, 8'h01, kind};
          end
        end
      end
      base = q;
    end
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
      sz = wbuf[boff_w[b] + 2];
      ad = {32'h0, wbuf[boff_w[b] + 3]};
      for (int w2 = 0; w2 < sz/4; w2++) begin
        if ((ad + w2*4) & 7)
          mem[(ad + w2*4) >> 3][63:32] = wbuf[base + w2];
        else
          mem[(ad + w2*4) >> 3][31:0] = wbuf[base + w2];
      end
      base += sz/4;
    end

    // dispatch
    do_dispatch(gx, gy, gz, 0, dpl);
    if (ebuf[3] == 1) begin
      cmp({file, ".done"}, {24'h0, dpl.code}, APU_SH_DONE_OK);
    end else if (ebuf[3] == 2) begin
      cmp({file, ".done"}, {24'h0, dpl.code}, APU_SH_DONE_FAULT);
    end
    // Gate 1 robust: model predicts the count for every committed
    // module (including mutants — the .exp robust is the mutant's own
    // model count).
    cmp({file, ".robust"}, dpl.robust, ebuf[2]);

    // section offsets: oracle words, model words, class words
    ebase = 5 + ebuf[4] * 4;
    now = 0;
    for (int b = 0; b < ebuf[4]; b++)
      if (ebuf[5 + b*4 + 3]) now += int'(ebuf[5 + b*4 + 1]) / 4;
    mbase = ebase + now;
    cbase = mbase + now;

    diffs = 0; cmax = 0; cn1 = 0; cn2 = 0; wpos = 0; ou_mism = 0;
    for (int b = 0; b < ebuf[4]; b++) begin
      logic [31:0] sz, eo;
      logic [63:0] ad;
      sz = ebuf[5 + b*4 + 1];
      ad = {32'h0, ebuf[5 + b*4 + 2]};
      eo = ebuf[5 + b*4 + 3];
      if (eo) begin
        for (int w2 = 0; w2 < sz/4; w2++) begin
          logic [31:0] got, xo, xm, xc;
          longint    aa;
          int unsigned u;
          aa = ad + w2*4;
          got = (aa & 7) ? mem[aa >> 3][63:32]
                         : mem[aa >> 3][31:0];
          xo = ebuf[ebase + w2];            // lavapipe oracle
          xm = ebuf[mbase + w2];            // spirv_model
          xc = ebuf[cbase + w2];            // 0=int/bool 1=float
          // ---- Gate 1: bit-exact vs model -----------------------
          checks++;
          if (got !== xm) begin
            fails++;
            if (fails < 3000)
              $display("FAIL-G1 %s b%0d[%0d]@%x got=%08x model=%08x",
                       file, b, w2, aa, got, xm);
          end
          // ---- Gate 2: vs lavapipe --------------------------------
          if (!mut) begin
            checks++;
            if (xc == 0) begin              // integer/bool: bit-exact
              if (got !== xo) begin
                fails++;
                if (fails < 3000)
                  $display(
                    "FAIL-G2i %s b%0d[%0d]@%x got=%08x orc=%08x",
                    file, b, w2, aa, got, xo);
              end
            end else if (xc == 2) begin
              // §12.3 C/5b: unorm-sampled float — |d| <= ~2/255
              // (8-bit fractional weights vs lavapipe's float mul).
              // f32r: $bitstoshortreal has 64-bit semantics under
              // this simulator, so unpack the fp32 by hand.
              real rg, ro, rd;
              rg = f32r(got);
              ro = f32r(xo);
              rd = rg - ro;
              if (rd < 0.0) rd = -rd;
              if (rd > 0.005) begin
                fails++;
                if (fails < 3000)
                  $display(
                    "FAIL-G2u %s b%0d[%0d]@%x got=%08x orc=%08x d=%f",
                    file, b, w2, aa, got, xo, rd);
              end
            end else if (xc == 3) begin
              // packed unorm/sRGB byte lanes: +-1 code per byte
              for (int bb = 0; bb < 4; bb++) begin
                int dg, do_;
                dg = got[bb*8 +: 8]; do_ = xo[bb*8 +: 8];
                if ((dg > do_ ? dg - do_ : do_ - dg) > 1) begin
                  fails++;
                  if (fails < 3000)
                    $display(
                      "FAIL-G2p %s b%0d[%0d]@%x got=%08x orc=%08x",
                      file, b, w2, aa, got, xo);
                  break;
                end
              end
            end else begin                  // float: <=2 ULP
              u = ulpd(got, xo);
              if (u > 2) begin
                fails++;
                if (fails < 3000)
                  $display(
                    "FAIL-G2f %s b%0d[%0d]@%x got=%08x orc=%08x ulp=%0d",
                    file, b, w2, aa, got, xo, u);
              end else begin
                if (u == 1) begin ulp1c++; cn1++; end
                if (u == 2) begin ulp2c++; cn2++; end
                if (u > cmax) cmax = u;
              end
            end
          end
          if (got !== xo) diffs++;
          // ---- unopt==opt: stash/compare per-word ------------------
          if (!is_opt && cur_nidx >= 0 && cur_seed >= 1)
            uout[cur_nidx][cur_seed][wpos] = got;
          else if (is_opt) begin
            ou_words++;
            if (got !== uout[cur_nidx][cur_seed][wpos]) begin
              ou_mism++;
              if (ou_mism <= 16)
                $display(
                  "FAIL-OU %s b%0d[%0d]@%x opt=%08x unopt=%08x",
                  file, b, w2, aa, got,
                  uout[cur_nidx][cur_seed][wpos]);
            end
          end
          wpos++;
        end
        ebase += int'(sz) / 4;
        mbase += int'(sz) / 4;
        cbase += int'(sz) / 4;
      end
    end
    // opt case: the whole output must equal the unoptimized build's
    // RTL output bit-exact (spirv-opt -O preserves IEEE semantics).
    if (is_opt) begin
      checks++;
      ou_mism_t += ou_mism;
      if (ou_mism != 0) begin
        fails++;
        $display("FAIL %s opt output differs from unopt on %0d words",
                 file, ou_mism);
      end
      $display("OU %s words=%0d mism=%0d", file, wpos, ou_mism);
    end
    if (mut) begin
      checks++;
      if (diffs == 0) begin
        fails++;
        $display("FAIL %s mutated module did not differ", file);
      end
    end
    $display("CYC %s cycles=%0d code=%0d pc=%0d wave=%0d robust=%0d wsw=%0d nwaves=%0d",
             file, dcyc, dpl.code, dpl.pc, dpl.wave, dpl.robust,
             dut.gen_on.i_wave.gen_on.wsw_q,
             dut.gen_on.i_wave.gen_on.nwaves_q);
    // §7c: a multi-wave workgroup must have actually interleaved the
    // round-robin scheduler at least once during the dispatch.
    checks++;
    if (dpl.code == APU_SH_DONE_OK &&
        dut.gen_on.i_wave.gen_on.nwaves_q > 1 &&
        dut.gen_on.i_wave.gen_on.wsw_q == 0) begin
      fails++;
      $display("FAIL %s multi-wave dispatch never switched waves", file);
    end
    if (!mut)
      $display("ULP %s max=%0d ulp1=%0d ulp2=%0d", file, cmax,
               cn1, cn2);
    // +dbg_sc: per-case scratch slab and RF dump for bring-up debug
    if (dbg_sc) begin
      for (int w = 0; w < 128; w++)
        $display("DSC %s sc[%3d] = %08x", file, w,
                 dut.gen_on.i_wave.gen_on.i_scratch.sram[w]);
      for (int r = 30; r < 80; r++)
        $display("DRF %s rf[%2d] = %08x %08x %08x %08x", file, r,
                 dut.gen_on.i_wave.gen_on.i_rf_lo.sram[r][31:0],
                 dut.gen_on.i_wave.gen_on.i_rf_lo.sram[r][63:32],
                 dut.gen_on.i_wave.gen_on.i_rf_lo.sram[r][95:64],
                 dut.gen_on.i_wave.gen_on.i_rf_lo.sram[r][127:96]);
    end
    if (cmax > maxulp) maxulp = cmax;
    if (fails != f0)
      $display("CASE %s fails=%0d", file, fails - f0);
    retire_do(0);
  endtask

  string names [38] = '{"arrlen", "bufcopy", "bufscale", "builtin_gid",
      "builtin_lid", "builtin_lindex", "compare", "composite",
      "intmix", "localsize32", "localsize64", "math450", "oob",
      "pushscale", "vec4arith",
      // §7c 4b corpus
      "ifelse", "loopfor", "loopwhile", "switchcase", "shortcircuit",
      "earlyret", "phiflow", "barrier_prefix", "barrier_reduce",
      "matvec", "matmat", "precise_dot",
      // §12.3 F5 memory-resident descriptor corpus
      "descarr", "multiset", "arroob",
      // §12.3 C/5b image corpus (texelFetch/imageLoad/imageStore/
      // textureLod bilinear+mip/address modes, sRGB, 2D-array, query)
      "texfetch", "texfetch_mip", "texlod_lin", "texlod_mip",
      "imgloadstore", "texarr", "texsrgb", "texquery"};

  initial begin
    checks = 0; cases = 0; fails = 0; cyc = 0; dcyc = 0;
    ulp1c = 0; ulp2c = 0; maxulp = 0; ou_mism_t = 0;
    if (!$value$plusargs("shv=%s", shv)) shv = "verif/tb/apu/sh_vectors";
    dbg_sc = $test$plusargs("dbg_sc");
    dbg_wd = $test$plusargs("dbg_wd");
    if (!$value$plusargs("only=%s", only)) only = "";
    wr_en = 0; commit = 0; retire = 0; work = 0; work_ctype = 0;
    work_imm = '0; disp_slot = 0; desc = '0; push_n = 0; push = '0;
    for (int i = 0; i < MEMW; i++) mem[i] = '0;
    repeat (8) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    is_opt = 0; cur_nidx = -1; cur_seed = 0; ou_words = 0;
    for (int i = 0; i < $size(names); i++) begin
      for (int s = 1; s <= 3; s++) begin
        if (only != "" && names[i] != only) continue;
        cases++;
        cur_nidx = i; cur_seed = s;
        run_vec(names[i],
                {names[i], "_", $sformatf("%0d", s)});
      end
    end
    cur_nidx = -1; cur_seed = 0;
    for (int i = 0; i < $size(names); i++) begin
      if (only != "" && names[i] != only) continue;
      cases++;
      run_vec(names[i], {names[i], "_mut_0"});
    end
    for (int i = 0; i < $size(names); i++) begin
      if (only != "" && names[i] != only) continue;
      cases++;
      run_vec(names[i], {names[i], "_bad_0"});
    end

    // 4b-opt: the `spirv-opt -O` build of every .comp shader (no
    // phiflow — it is hand-assembled, no .comp source).  Gates 1+2
    // plus the unopt==opt bit-exact check against the outputs stashed
    // during the base runs above.
    is_opt = 1;
    for (int i = 0; i < $size(names); i++) begin
      if (names[i] == "phiflow") continue;
      for (int s = 1; s <= 3; s++) begin
        if (only != "" && names[i] != only) continue;
        cases++;
        cur_nidx = i; cur_seed = s;
        run_vec(names[i],
                {names[i], "_opt_", $sformatf("%0d", s)});
      end
    end
    is_opt = 0; cur_nidx = -1; cur_seed = 0;

    checks++;
    if (off_bad) begin
      fails++; $display("FAIL Enable=0 not quiet");
    end

    if (fails == 0)
      $display("PASS tb_g6lc_apu_shwave cases=%0d checks=%0d ulp1=%0d ulp2=%0d maxulp=%0d ouw=%0d oum=%0d cycles=%0d",
               cases, checks, ulp1c, ulp2c, maxulp, ou_words,
               ou_mism_t, cyc);
    else begin
      $display("FAILURES=%0d (no PASS)", fails);
      $fatal(1);
    end
    $finish;
  end
endmodule
