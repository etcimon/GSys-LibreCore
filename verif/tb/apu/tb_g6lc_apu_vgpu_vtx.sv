// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vtx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  apu_vgpu_sh_t sh, fs;
  apu_vgpu_cv_t cv;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] vst_addr, fst_addr;
  logic [31:0] vst_peek, fst_peek;
  logic vst_req = 0, vst_rdy, vst_cpl_v, vst_cpl_r = 0;
  apu_vgpu_vst_cpl_t vst_cpl;
  apu_vgpu_vst_t vst;
  logic fst_req = 0, fst_rdy, fst_cpl_v, fst_cpl_r = 0;
  apu_vgpu_fst_cpl_t fst_cpl;
  apu_vgpu_fst_t fst;
  logic [15:0] hx_i, hy_i;
  logic hld_req = 0, hld_rdy, hld_cpl_v, hld_cpl_r = 0;
  apu_vgpu_hld_cpl_t hld_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam int unsigned VsBase = 12;
  localparam int unsigned FsBase = 50;

  assign vst_peek = mem[vst_addr[9:2]];
  assign fst_peek = mem[fst_addr[9:2]];

  g6lc_apu_vgpu_vst #(.Enable(1'b1)) i_vst (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .sh_i(sh),
    .req_valid_i(vst_req), .req_ready_o(vst_rdy),
    .cpl_valid_o(vst_cpl_v), .cpl_ready_i(vst_cpl_r), .cpl_o(vst_cpl), .vst_o(vst),
    .peek_addr_o(vst_addr), .peek_word_i(vst_peek)
  );
  g6lc_apu_vgpu_fst #(.Enable(1'b1)) i_fst (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .fs_i(fs), .vst_i(vst),
    .req_valid_i(fst_req), .req_ready_o(fst_rdy),
    .cpl_valid_o(fst_cpl_v), .cpl_ready_i(fst_cpl_r), .cpl_o(fst_cpl), .fst_o(fst),
    .peek_addr_o(fst_addr), .peek_word_i(fst_peek)
  );
  g6lc_apu_vgpu_hld #(.Enable(1'b1)) i_hld (
    .clk_i(clk), .rst_ni, .fst_i(fst), .cv_i(cv), .x_i(hx_i), .y_i(hy_i),
    .req_valid_i(hld_req), .req_ready_o(hld_rdy),
    .cpl_valid_o(hld_cpl_v), .cpl_ready_i(hld_cpl_r), .cpl_o(hld_cpl)
  );
  g6lc_apu_vgpu_hld_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .fst_i(fst), .cv_i(cv), .x_i(hx_i), .y_i(hy_i),
    .req_valid_i(hld_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(hld_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu vtx timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  function automatic logic [31:0] vs_word(input int unsigned i);
    case (i)
      0: vs_word = 32'h5452_4556;
      1: vs_word = 32'h4c43_440a;
      2: vs_word = 32'h5b4e_4920;
      3: vs_word = 32'h440a_5d30;
      4: vs_word = 32'h4920_4c43;
      5: vs_word = 32'h5d31_5b4e;
      6: vs_word = 32'h4c43_440a;
      7: vs_word = 32'h5455_4f20;
      8: vs_word = 32'h2c5d_305b;
      9: vs_word = 32'h534f_5020;
      10: vs_word = 32'h4f49_5449;
      11: vs_word = 32'h4344_0a4e;
      12: vs_word = 32'h554f_204c;
      13: vs_word = 32'h5d31_5b54;
      14: vs_word = 32'h4547_202c;
      15: vs_word = 32'h4952_454e;
      16: vs_word = 32'h5d30_5b43;
      17: vs_word = 32'h3020_200a;
      18: vs_word = 32'h4f4d_203a;
      19: vs_word = 32'h554f_2056;
      20: vs_word = 32'h5d30_5b54;
      21: vs_word = 32'h4e49_202c;
      22: vs_word = 32'h0a5d_305b;
      23: vs_word = 32'h3a31_2020;
      24: vs_word = 32'h564f_4d20;
      25: vs_word = 32'h5455_4f20;
      26: vs_word = 32'h2c5d_315b;
      27: vs_word = 32'h5b4e_4920;
      28: vs_word = 32'h200a_5d31;
      29: vs_word = 32'h203a_3220;
      30: vs_word = 32'h0a44_4e45;
      31: vs_word = 32'h0000_0000;
      default: vs_word = 32'h0;
    endcase
  endfunction

  function automatic logic [31:0] fs_word(input int unsigned i);
    case (i)
      0: fs_word = 32'h4741_5246;
      1: fs_word = 32'h4c43_440a;
      2: fs_word = 32'h5b4e_4920;
      3: fs_word = 32'h202c_5d30;
      4: fs_word = 32'h454e_4547;
      5: fs_word = 32'h5b43_4952;
      6: fs_word = 32'h202c_5d30;
      7: fs_word = 32'h5352_4550;
      8: fs_word = 32'h5443_4550;
      9: fs_word = 32'h0a45_5649;
      10: fs_word = 32'h204c_4344;
      11: fs_word = 32'h5b54_554f;
      12: fs_word = 32'h202c_5d30;
      13: fs_word = 32'h4f4c_4f43;
      14: fs_word = 32'h4344_0a52;
      15: fs_word = 32'h4153_204c;
      16: fs_word = 32'h305b_504d;
      17: fs_word = 32'h4344_0a5d;
      18: fs_word = 32'h5653_204c;
      19: fs_word = 32'h5b57_4549;
      20: fs_word = 32'h202c_5d30;
      21: fs_word = 32'h202c_4432;
      22: fs_word = 32'h524f_4e55;
      23: fs_word = 32'h2020_0a4d;
      24: fs_word = 32'h5420_3a30;
      25: fs_word = 32'h4f20_5845;
      26: fs_word = 32'h305b_5455;
      27: fs_word = 32'h4920_2c5d;
      28: fs_word = 32'h5d30_5b4e;
      29: fs_word = 32'h4153_202c;
      30: fs_word = 32'h305b_504d;
      31: fs_word = 32'h3220_2c5d;
      32: fs_word = 32'h2020_0a44;
      33: fs_word = 32'h4520_3a31;
      34: fs_word = 32'h000a_444e;
      default: fs_word = 32'h0;
    endcase
  endfunction

  task automatic load_text;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    for (int i = 0; i < 32; i++) mem[VsBase + i] = vs_word(i);
    for (int i = 0; i < 35; i++) mem[FsBase + i] = fs_word(i);
  endtask

  task automatic good_sh;
    bufi = '0;
    bufi.valid = 1'b1;
    bufi.size = 32'd960;
    sh = '0;
    sh.valid = 1'b1;
    sh.handle = APU_VIRGL_VS_HANDLE;
    sh.stage = APU_VIRGL_SHADER_VERTEX;
    sh.offlen = APU_VIRGL_VS_OFFLEN;
    sh.tokens = APU_VIRGL_VS_TOKENS;
    sh.text_at = APU_VIRGL_VS_TEXT_AT;
    sh.next = APU_VIRGL_VS_NEXT;
    sh.text0 = APU_VIRGL_VS_TEXT0;
  endtask

  task automatic good_fs;
    fs = '0;
    fs.valid = 1'b1;
    fs.handle = APU_VIRGL_FS_HANDLE;
    fs.stage = APU_VIRGL_SHADER_FRAGMENT;
    fs.offlen = APU_VIRGL_FS_OFFLEN;
    fs.tokens = APU_VIRGL_FS_TOKENS;
    fs.text_at = APU_VIRGL_FS_TEXT_AT;
    fs.next = APU_VIRGL_FS_NEXT;
    fs.text0 = APU_VIRGL_FS_TEXT0;
  endtask

  task automatic good_cv;
    cv = '0;
    cv.valid = 1'b1;
    cv.covered = 1'b1;
    cv.word = APU_VGPU_CLEAR_WORD;
    cv.samples = APU_VGPU_FILL_N;
  endtask

  task automatic vst_step(input apu_vgpu_vst_status_e st, input string name);
    @(negedge clk);
    while (!vst_rdy) @(negedge clk);
    cases++;
    vst_req = 1;
    @(posedge clk); @(negedge clk); vst_req = 0;
    while (!vst_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vst_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), vst_cpl_v);
    vst_cpl_r = 1;
    @(posedge clk); @(negedge clk); vst_cpl_r = 0;
    while (vst_cpl_v) @(negedge clk);
  endtask

  task automatic fst_step(input apu_vgpu_fst_status_e st, input string name);
    @(negedge clk);
    while (!fst_rdy) @(negedge clk);
    cases++;
    fst_req = 1;
    @(posedge clk); @(negedge clk); fst_req = 0;
    while (!fst_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fst_cpl.status == st);
    if (st == APU_VGPU_FST_OK)
      check($sformatf("%s tex", name), fst.valid && fst.tex);
    @(negedge clk);
    check($sformatf("%s held", name), fst_cpl_v);
    fst_cpl_r = 1;
    @(posedge clk); @(negedge clk); fst_cpl_r = 0;
    while (fst_cpl_v) @(negedge clk);
  endtask

  task automatic hld_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_hld_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!hld_rdy) @(negedge clk);
    cases++;
    hx_i = x;
    hy_i = y;
    hld_req = 1;
    @(posedge clk); @(negedge clk); hld_req = 0;
    while (!hld_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), hld_cpl.status == st);
    if (st == APU_VGPU_HLD_OK)
      check($sformatf("%s sample", name), hld_cpl.held &&
            hld_cpl.word == APU_VGPU_CLEAR_WORD && hld_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), !hld_cpl.held && hld_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), hld_cpl_v);
    hld_cpl_r = 1;
    @(posedge clk); @(negedge clk); hld_cpl_r = 0;
    while (hld_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    vst_req = 0;
    fst_req = 0;
    hld_req = 0;
    vst_cpl_r = 0;
    fst_cpl_r = 0;
    hld_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    sh = '0;
    fs = '0;
    cv = '0;
    hx_i = '0;
    hy_i = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && vst == '0 && fst == '0);
    check("profiles keep text off",
          !ApuOff.VstEn && !ApuOff.FstEn && !ApuOff.HldEn &&
          !ApuP1Transport.VstEn && !ApuP1Transport.FstEn && !ApuP1Transport.HldEn &&
          !ApuHarness.VstEn && !ApuHarness.FstEn && !ApuHarness.HldEn &&
          !ApuSchedBoth.VstEn && !ApuSchedBoth.FstEn && !ApuSchedBoth.HldEn &&
          !ApuBadVirglGrant.VstEn && !ApuBadVirglGrant.FstEn && !ApuBadVirglGrant.HldEn);
    cfg = ApuP1Transport;
    cfg.VstEn = 1'b1;
    cfg.FstEn = 1'b1;
    cfg.HldEn = 1'b1;
    check("text does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VstEn = 1'b1;
    cfg.FstEn = 1'b1;
    cfg.HldEn = 1'b1;
    check("text does not legalize virgl", !apu_cfg_legal(cfg));
    check("vs length", APU_VIRGL_VS_OFFLEN == 32'd125 &&
          APU_VIRGL_VS_TEXT_AT == 32'd48 && APU_VIRGL_VS_NEXT == 32'd176 &&
          APU_VIRGL_VS_TEXT0 == 32'h54524556);
    check("fs length", APU_VIRGL_FS_OFFLEN == 32'd140 &&
          APU_VIRGL_FS_TEXT_AT == 32'd200 && APU_VIRGL_FS_NEXT == 32'd340 &&
          APU_VIRGL_FS_TEXT0 == 32'h47415246);

    vst_step(APU_VGPU_VST_EMPTY, "vst empty");
    good_sh();
    sh.offlen = 32'd124;
    vst_step(APU_VGPU_VST_FAULT, "bad length");
    check("length keeps", !vst.valid);
    good_sh();
    sh.text0 = 32'h0;
    vst_step(APU_VGPU_VST_FAULT, "bad text0");
    load_text();
    check("vert anchor", mem[VsBase] == 32'h54524556);
    check("frag anchor", mem[FsBase] == 32'h47415246);
    check("tex anchor", mem[FsBase + 24] == 32'h54203a30 &&
          mem[FsBase + 25] == 32'h4f205845);
    good_sh();
    mem[VsBase + 1] = 32'h0;
    vst_step(APU_VGPU_VST_FAULT, "bad dword");
    check("dword keeps", !vst.valid);
    mem[VsBase + 1] = vs_word(1);
    vst_step(APU_VGPU_VST_OK, "vertex text");
    check("vertex kept", vst.valid);
    vst_step(APU_VGPU_VST_FAULT, "vertex again");
    check("vertex stays", vst.valid);

    fst_step(APU_VGPU_FST_EMPTY, "fst empty");
    good_fs();
    fs.offlen = 32'd139;
    fst_step(APU_VGPU_FST_FAULT, "bad fs length");
    mem[FsBase + 1] = 32'h0;
    good_fs();
    fst_step(APU_VGPU_FST_FAULT, "bad fs dword");
    check("fs keeps", !fst.valid && !fst.tex);
    mem[FsBase + 1] = fs_word(1);
    good_cv();
    hld_step(16'd1, 16'd0, APU_VGPU_HLD_EMPTY, 14'd0, "hold waits");
    fst_step(APU_VGPU_FST_OK, "fragment text");
    check("fragment tex", fst.valid && fst.tex);
    fst_step(APU_VGPU_FST_FAULT, "fragment again");
    check("fragment stays", fst.valid && fst.tex);
    cv.word = 32'h0;
    hld_step(16'd1, 16'd0, APU_VGPU_HLD_FAULT, 14'd0, "bad color");
    good_cv();
    hld_step(16'd1, 16'd0, APU_VGPU_HLD_OK, 14'd4, "interior");
    hld_step(16'd2, 16'd3, APU_VGPU_HLD_OK, 14'd776, "sample 2,3");
    hld_step(16'd63, 16'd63, APU_VGPU_HLD_OK, APU_VGPU_PIX_XY, "corner");
    hld_step(16'd64, 16'd0, APU_VGPU_HLD_FAULT, 14'd0, "outside");
    hld_step(16'd1, 16'd0, APU_VGPU_HLD_OK, 14'd4, "reread");
    check("color stays clear", cv.word == 32'hFF1A0D0D && cv.samples == 32'd4096);

    pulse_reset();
    check("reset clears", vst == '0 && fst == '0);
    fst_step(APU_VGPU_FST_EMPTY, "fst after reset");
    hld_step(16'd1, 16'd0, APU_VGPU_HLD_EMPTY, 14'd0, "hold after reset");

    if (errors != 0) $fatal(1, "APU vgpu vtx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vtx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
