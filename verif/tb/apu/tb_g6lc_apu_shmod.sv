// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Directed test of g6lc_apu_shmod (commit scanner): every corpus
// module is committed and its tables are compared word-for-word
// against spirv_scan.py's --emit-tab image; then the fault matrix
// (bad magic / version / Int64 capability / bound > ShaderIds /
// two entry points / LocalSize > 64 / > ShaderRegs registers /
// injected OpSin) is exercised.  The Enable=0 fixture must stay
// quiet.
//
// Vectors: verif/tb/apu/sh_vectors/<name>_1.hex (module words at
// [8..8+n_spv)) and <name>.tab (expected table image).

module tb_g6lc_apu_shmod;
  import g6lc_apu_sh_pkg::*;

  localparam int unsigned MAXW = 65536;
  string  shv;
  int     checks, cases, fails;
  longint cyc;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  always_ff @(posedge clk) cyc <= cyc + 1;

  // DUT I/O
  logic         wr_en;   logic [2:0]  wr_slot;
  logic [15:0]  wr_addr; logic [31:0] wr_data;
  logic         commit;  apu_sh_commit_t commit_pl;
  logic         busy;    logic done;  apu_sh_cpl_t done_pl;
  logic         retire;  logic [2:0]  retire_slot;
  logic [2:0]   rd_slot;
  logic [15:0]  prog_addr; logic [31:0] prog_data;
  logic [9:0]   type_id;   logic [95:0] type_data;
  logic [9:0]   const_id;  logic [511:0] const_data;
  logic [9:0]   memb_id;   logic [63:0]  memb_data;
  logic [9:0]   decor_id;  logic [63:0]  decor_data;
  logic [9:0]   var_id;    logic [63:0]  var_data;
  logic [9:0]   rm_id;     logic [31:0]  rm_data;
  logic [9:0]   init_id;   logic [63:0]  init_data;
  logic [9:0]   blk_id;    logic [31:0]  blk_data;
  logic [9:0]   phi_id;    logic [159:0] phi_data;
  logic [127:0] entry_data;

  g6lc_apu_shmod #(.Enable(1)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .busy_o(busy), .done_o(done), .done_pl_o(done_pl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .rd_slot_i(rd_slot), .prog_addr_i(prog_addr),
    .prog_data_o(prog_data),
    .type_id_i(type_id), .type_data_o(type_data),
    .const_id_i(const_id), .const_data_o(const_data),
    .memb_id_i(memb_id), .memb_data_o(memb_data),
    .decor_id_i(decor_id), .decor_data_o(decor_data),
    .var_id_i(var_id), .var_data_o(var_data),
    .rm_id_i(rm_id), .rm_data_o(rm_data),
    .init_id_i(init_id), .init_data_o(init_data),
    .blk_id_i(blk_id), .blk_data_o(blk_data),
    .phi_id_i(phi_id), .phi_data_o(phi_data),
    .entry_data_o(entry_data));

  // Enable=0 fixture: every input toggles, outputs must stay '0 —
  // checked continuously by the sticky monitor below.
  logic         off_busy, off_done; apu_sh_cpl_t off_pl;
  logic [127:0] off_entry;
  g6lc_apu_shmod #(.Enable(0)) off (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .wr_en_i(wr_en), .wr_slot_i(wr_slot), .wr_addr_i(wr_addr),
    .wr_data_i(wr_data),
    .commit_i(commit), .commit_pl_i(commit_pl),
    .busy_o(off_busy), .done_o(off_done), .done_pl_o(off_pl),
    .retire_i(retire), .retire_slot_i(retire_slot),
    .rd_slot_i(rd_slot), .prog_addr_i(prog_addr),
    .prog_data_o(),
    .type_id_i(type_id), .type_data_o(),
    .const_id_i(const_id), .const_data_o(),
    .memb_id_i(memb_id), .memb_data_o(),
    .decor_id_i(decor_id), .decor_data_o(),
    .var_id_i(var_id), .var_data_o(),
    .rm_id_i(rm_id), .rm_data_o(),
    .init_id_i(init_id), .init_data_o(),
    .blk_id_i(blk_id), .blk_data_o(),
    .phi_id_i(phi_id), .phi_data_o(),
    .entry_data_o(off_entry));

  // continuous Enable=0 quiet monitor — sticky flag (fails is
  // written from the initial process; counted once at the end)
  logic off_bad;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) off_bad <= 1'b0;
    else if (!off_bad &&
             (off_busy | off_done | (|off_pl) | (|off_entry))) begin
      off_bad <= 1'b1;
      $display("FAIL Enable=0 activity at cycle %0d", cyc);
    end
  end

  logic [31:0] wbuf [MAXW];

  task automatic cmp(input string nm, input logic [31:0] got,
                     input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      fails++;
      if (fails < 40)
        $display("FAIL %s got=%08x exp=%08x", nm, got, exp);
    end
  endtask

  task automatic wr_words(input int base, input int n,
                          input int slot);
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
    @(negedge clk);
    commit = 0;
    for (int g = 0; g < 2000000; g++) begin
      @(negedge clk);
      if (done) break;
    end
    if (!done) begin
      fails++;
      $display("FAIL commit timeout slot=%0d", slot);
    end
    pl = done_pl;
  endtask

  task automatic retire_do(input int slot);
    @(negedge clk); retire = 1; retire_slot = slot[2:0];
    @(negedge clk); retire = 0;
  endtask

  // one read-port query per table row (1-cycle latency)
  task automatic rd_word(input string tag, input int id, input int j,
                         output logic [31:0] v);
    @(negedge clk);
    rd_slot = 0;
    type_id = id[9:0]; const_id = id[9:0]; memb_id = id[9:0];
    decor_id = id[9:0]; var_id = id[9:0]; rm_id = id[9:0];
    init_id = id[9:0]; blk_id = id[9:0]; phi_id = id[9:0];
    @(negedge clk);
    unique case (tag[0])
      "T": v = type_data[32*j +: 32];
      "C": v = const_data[32*j +: 32];
      "D": v = decor_data[32*j +: 32];
      "V": v = var_data[32*j +: 32];
      "R": v = rm_data;
      "B": v = blk_data;
      "P": v = phi_data[32*j +: 32];
      "M": v = memb_data[32*j +: 32];
      "I": v = init_data[32*j +: 32];
      default: v = entry_data[32*j +: 32];
    endcase
  endtask

  task automatic check_tab(input string name);
    int fd, rc, id, j;
    string tag;
    logic [31:0] exp_w, got;
    fd = $fopen({shv, "/", name, ".tab"}, "r");
    if (fd == 0) begin
      fails++; $display("FAIL open %s.tab", name); return;
    end
    while (!$feof(fd)) begin
      rc = $fscanf(fd, "%s %d %d %x\n", tag, id, j, exp_w);
      if (rc != 4) break;
      rd_word(tag, id, j, got);
      cmp({tag, "[", $sformatf("%0d", id), "].w", $sformatf("%0d", j)},
          got, exp_w);
    end
    $fclose(fd);
  endtask

  task automatic run_commit(input string file, input int slot,
                            input int exp_code, input int exp_opc);
    apu_sh_cpl_t pl;
    int n;
    for (int i = 0; i < MAXW; i++) wbuf[i] = '0;
    $readmemh({shv, "/", file}, wbuf);
    n = wbuf[0];
    wr_words(8, n, slot);
    do_commit(n, slot, pl);
    if (exp_code == 0) begin
      cmp({file, ".ok"}, {31'h0, pl.ok}, 1);
      if (!pl.ok)
        $display("  %s fault code=%0d opc=%0d word=%0d", file,
                 pl.fault.code, pl.fault.opcode, pl.fault.word);
    end else begin
      cmp({file, ".ok"}, {31'h0, pl.ok}, 0);
      cmp({file, ".code"}, {24'h0, pl.fault.code}, exp_code);
      cmp({file, ".opc"}, {16'h0, pl.fault.opcode}, exp_opc);
    end
  endtask

  // synthetic fault modules assembled into wbuf[]
  int m_n;
  task automatic mw(input logic [31:0] w);
    wbuf[m_n++] = w;
  endtask
  task automatic minst(input int opc, input int wc);
    wbuf[m_n++] = (wc << 16) | opc;
  endtask
  task automatic mheader(input int bound);
    m_n = 0;
    mw(32'h0723_0203); mw(32'h0001_0300); mw(0); mw(bound); mw(0);
  endtask
  task automatic mpreamble();
    minst(17, 2); mw(1);                       // Capability Shader
    minst(14, 3); mw(0); mw(1);                // Logical GLSL450
    minst(11, 6); mw(2); mw(32'h4C53_4C47);    // ExtInstImport
    mw(32'h6474_732E); mw(32'h3035_342E); mw(0);
    minst(15, 4); mw(5); mw(4); mw(32'h6E69616D);  // Entry "main"
    minst(16, 6); mw(4); mw(17); mw(8); mw(1); mw(1);
    minst(19, 2); mw(5);                       // %5 void
    minst(33, 3); mw(6); mw(5);                // %6 fn
    minst(54, 5); mw(5); mw(4); mw(0); mw(6);  // OpFunction
    minst(248, 2); mw(7);                      // OpLabel
    minst(253, 1);                             // OpReturn
    minst(56, 1);                              // OpFunctionEnd
  endtask

  task automatic run_synth(input string nm, input int exp_code,
                           input int exp_opc);
    apu_sh_cpl_t pl;
    wr_words(0, m_n, 0);
    do_commit(m_n, 0, pl);
    if (exp_code == 0) begin
      if (!pl.ok)
        $display("  %s unexpected fault code=%0d opc=%0d word=%0d",
                 nm, pl.fault.code, pl.fault.opcode, pl.fault.word);
      cmp({nm, ".ok"}, {31'h0, pl.ok}, 1);
    end else begin
      cmp({nm, ".ok"}, {31'h0, pl.ok}, 0);
      cmp({nm, ".code"}, {24'h0, pl.fault.code}, exp_code);
      if (exp_opc >= 0)
        cmp({nm, ".opc"}, {16'h0, pl.fault.opcode}, exp_opc);
    end
  endtask

  string names [27] = '{"arrlen", "bufcopy", "bufscale", "builtin_gid",
      "builtin_lid", "builtin_lindex", "compare", "composite",
      "intmix", "localsize32", "localsize64", "math450", "oob",
      "pushscale", "vec4arith",
      // §7c 4b corpus
      "ifelse", "loopfor", "loopwhile", "switchcase", "shortcircuit",
      "earlyret", "phiflow", "barrier_prefix", "barrier_reduce",
      "matvec", "matmat", "precise_dot"};

  initial begin
    checks = 0; cases = 0; fails = 0; cyc = 0;
    if (!$value$plusargs("shv=%s", shv)) shv = "verif/tb/apu/sh_vectors";
    wr_en = 0; commit = 0; retire = 0; rd_slot = 0;
    prog_addr = 0; type_id = 0; const_id = 0; memb_id = 0;
    decor_id = 0; var_id = 0; rm_id = 0; init_id = 0; blk_id = 0;
    repeat (8) @(negedge clk); rst_n = 1;
    repeat (4) @(negedge clk);

    // ---- 1. every corpus module: commit + table compare -------------
    for (int i = 0; i < 27; i++) begin
      cases++;
      run_commit({names[i], "_1.hex"}, 0, 0, 0);
      check_tab(names[i]);
      // retire then re-commit (slot reuse)
      retire_do(0);
    end

    // ---- 1b. every `spirv-opt -O` module: commit + table compare ---
    // (no phiflow — hand-assembled, no .comp/_opt twin)
    for (int i = 0; i < 27; i++) begin
      if (names[i] == "phiflow") continue;
      cases++;
      run_commit({names[i], "_opt_1.hex"}, 0, 0, 0);
      check_tab({names[i], "_opt"});
      retire_do(0);
    end

    // ---- 2. bad vectors — expected commit fault from <name>.exp -----
    // 4a bads inject OpSin (FAULT_OPCODE); 4b control-flow bads strip
    // the merge instruction (FAULT_BRANCH).  The vector's .exp words 0/1
    // carry the expected fault code and faulting opcode.
    for (int i = 0; i < 27; i++) begin
      int efd;
      logic [31:0] ec, eo;
      cases++;
      ec = 0; eo = 0;
      efd = $fopen({shv, "/", names[i], "_bad_0.exp"}, "r");
      if (efd) begin
        void'($fscanf(efd, "%x %x", ec, eo));
        $fclose(efd);
      end else
        $display("WARN %s_bad_0.exp unreadable — expect code 0",
                 names[i]);
      run_commit({names[i], "_bad_0.hex"}, 0, int'(ec), int'(eo));
      retire_do(0);
    end

    // ---- 3. synthetic fault matrix ----------------------------------
    mheader(32); wbuf[0] = 32'hDEAD_BEEF;
    cases++; run_synth("badmagic", APU_SH_FAULT_MAGIC, -1);

    mheader(32); wbuf[1] = 32'h0007_0300;       // version 1.7
    cases++; run_synth("badver", APU_SH_FAULT_VERSION, -1);

    mheader(32); minst(17, 2); mw(11);         // OpCapability Int64
    cases++; run_synth("cap64", APU_SH_FAULT_CAP, 17);

    mheader(1025);
    cases++; run_synth("bigbound", APU_SH_FAULT_BOUND, -1);

    // two entry points
    mheader(32); minst(17, 2); mw(1); minst(14, 3); mw(0); mw(1);
    minst(15, 4); mw(5); mw(4); mw(0);
    minst(15, 4); mw(5); mw(5); mw(0);
    cases++; run_synth("twoentry", APU_SH_FAULT_TWO_ENTRY, 15);

    // LocalSize 16*8*1 = 128 > 64
    mheader(32); minst(17, 2); mw(1); minst(14, 3); mw(0); mw(1);
    minst(15, 4); mw(5); mw(4); mw(0);
    minst(16, 6); mw(4); mw(17); mw(16); mw(8); mw(1);
    cases++; run_synth("biglocal", APU_SH_FAULT_LOCALSIZE, 16);

    // > ShaderRegs registers: 260 OpVariable in the function
    mheader(600); minst(17, 2); mw(1); minst(14, 3); mw(0); mw(1);
    minst(15, 4); mw(5); mw(4); mw(0);
    minst(16, 6); mw(4); mw(17); mw(8); mw(1); mw(1);
    minst(19, 2); mw(5);                       // %5 void
    minst(21, 4); mw(6); mw(32); mw(0);        // %6 int
    minst(32, 4); mw(7); mw(7); mw(6);         // %7 ptr func int
    minst(33, 3); mw(8); mw(5);                // %8 fn
    minst(54, 5); mw(5); mw(4); mw(0); mw(8);
    minst(248, 2); mw(9);
    for (int i = 0; i < 270; i++) begin
      minst(59, 4); mw(7); mw(10 + i); mw(7);  // OpVariable Function
    end
    minst(253, 1); minst(56, 1);
    cases++; run_synth("manyregs", APU_SH_FAULT_REGS, -1);

    // a valid preamble still commits after the fault sweep
    mheader(32); mpreamble();
    cases++; run_synth("preamble", 0, -1);

    // ---- Enable=0 quiet (continuous monitor + final check) --------
    checks++;
    if (off_bad) begin
      fails++; $display("FAIL Enable=0 not quiet");
    end

    $display("PASS tb_g6lc_apu_shmod cases=%0d checks=%0d cycles=%0d",
             cases, checks, cyc);
    if (fails) begin
      $display("FAILURES=%0d", fails);
      $fatal(1);
    end
    $finish;
  end
endmodule
