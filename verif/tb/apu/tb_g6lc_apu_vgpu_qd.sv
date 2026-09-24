// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  apu_vgpu_iw_t iw;
  apu_vgpu_vp_t vp;
  apu_vgpu_fil_t fil;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr;
  logic [31:0] peek_word;
  logic qd_req = 0, qd_rdy, qd_cpl_v, qd_cpl_r = 0;
  apu_vgpu_qd_cpl_t qd_cpl;
  apu_vgpu_qd_t qd;
  logic cv_req = 0, cv_rdy, cv_cpl_v, cv_cpl_r = 0;
  apu_vgpu_cv_cpl_t cv_cpl;
  apu_vgpu_cv_t cv;
  logic [15:0] cx, cy;
  logic cvr_req = 0, cvr_rdy, cvr_cpl_v, cvr_cpl_r = 0;
  apu_vgpu_cvr_cpl_t cvr_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam int unsigned QuadBase = 174;

  assign peek_word = mem[peek_addr[9:2]];

  g6lc_apu_vgpu_qd #(.Enable(1'b1)) i_qd (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .iw_i(iw),
    .req_valid_i(qd_req), .req_ready_o(qd_rdy),
    .cpl_valid_o(qd_cpl_v), .cpl_ready_i(qd_cpl_r), .cpl_o(qd_cpl), .qd_o(qd),
    .peek_addr_o(peek_addr), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_cv #(.Enable(1'b1)) i_cv (
    .clk_i(clk), .rst_ni, .qd_i(qd), .vp_i(vp), .fil_i(fil),
    .req_valid_i(cv_req), .req_ready_o(cv_rdy),
    .cpl_valid_o(cv_cpl_v), .cpl_ready_i(cv_cpl_r), .cpl_o(cv_cpl), .cv_o(cv)
  );
  g6lc_apu_vgpu_cvr #(.Enable(1'b1)) i_cvr (
    .clk_i(clk), .rst_ni, .cv_i(cv), .x_i(cx), .y_i(cy),
    .req_valid_i(cvr_req), .req_ready_o(cvr_rdy),
    .cpl_valid_o(cvr_cpl_v), .cpl_ready_i(cvr_cpl_r), .cpl_o(cvr_cpl)
  );
  g6lc_apu_vgpu_cvr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cv_i(cv), .x_i(cx), .y_i(cy),
    .req_valid_i(cvr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cvr_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu qd timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  function automatic logic [31:0] qf(input int unsigned i);
    case (i)
      0, 1, 7, 12: qf = APU_VIRGL_F32_NEG_ONE;
      3, 6, 9, 10, 13, 15, 17, 18, 19, 21, 22, 23: qf = APU_VIRGL_F32_ONE;
      default: qf = 32'h0;
    endcase
  endfunction

  task automatic load_quad;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    for (int i = 0; i < 24; i++) mem[QuadBase + i] = qf(i);
  endtask

  task automatic good_iw;
    bufi = '0;
    bufi.valid = 1'b1;
    bufi.size = 32'd960;
    iw = '0;
    iw.valid = 1'b1;
    iw.resource = APU_VIRGL_RES_VBO;
    iw.nbytes = APU_VIRGL_VBO_BYTES;
    iw.next = 32'd792;
  endtask

  task automatic good_map;
    vp = '0;
    vp.valid = 1'b1;
    vp.scale_x = APU_VIRGL_F32_HALF_W;
    vp.scale_y = APU_VIRGL_F32_HALF_H;
    fil = '0;
    fil.valid = 1'b1;
    fil.word = APU_VGPU_CLEAR_WORD;
    fil.samples = APU_VGPU_FILL_N;
  endtask

  task automatic qd_step(input apu_vgpu_qd_status_e st, input string name);
    @(negedge clk);
    while (!qd_rdy) @(negedge clk);
    cases++;
    qd_req = 1;
    @(posedge clk); @(negedge clk); qd_req = 0;
    while (!qd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qd_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), qd_cpl_v);
    qd_cpl_r = 1;
    @(posedge clk); @(negedge clk); qd_cpl_r = 0;
    while (qd_cpl_v) @(negedge clk);
  endtask

  task automatic cv_step(input apu_vgpu_cv_status_e st, input string name);
    @(negedge clk);
    while (!cv_rdy) @(negedge clk);
    cases++;
    cv_req = 1;
    @(posedge clk); @(negedge clk); cv_req = 0;
    while (!cv_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cv_cpl.status == st);
    if (st == APU_VGPU_CV_OK)
      check($sformatf("%s cover", name), cv.valid && cv.covered &&
            cv.word == APU_VGPU_CLEAR_WORD && cv.samples == APU_VGPU_FILL_N);
    @(negedge clk);
    check($sformatf("%s held", name), cv_cpl_v);
    cv_cpl_r = 1;
    @(posedge clk); @(negedge clk); cv_cpl_r = 0;
    while (cv_cpl_v) @(negedge clk);
  endtask

  task automatic cvr_step(
    input logic [15:0] x,
    input logic [15:0] y,
    input apu_vgpu_cvr_status_e st,
    input logic [13:0] addr,
    input string name
  );
    @(negedge clk);
    while (!cvr_rdy) @(negedge clk);
    cases++;
    cx = x;
    cy = y;
    cvr_req = 1;
    @(posedge clk); @(negedge clk); cvr_req = 0;
    while (!cvr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cvr_cpl.status == st);
    if (st == APU_VGPU_CVR_OK)
      check($sformatf("%s sample", name), cvr_cpl.covered &&
            cvr_cpl.word == APU_VGPU_CLEAR_WORD && cvr_cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), !cvr_cpl.covered && cvr_cpl.word == 32'h0);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), cvr_cpl_v);
    cvr_cpl_r = 1;
    @(posedge clk); @(negedge clk); cvr_cpl_r = 0;
    while (cvr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    qd_req = 0;
    cv_req = 0;
    cvr_req = 0;
    qd_cpl_r = 0;
    cv_cpl_r = 0;
    cvr_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    iw = '0;
    vp = '0;
    fil = '0;
    cx = '0;
    cy = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && qd == '0 && cv == '0);
    check("profiles keep quad off",
          !ApuOff.QdEn && !ApuOff.CvEn && !ApuOff.CvrEn &&
          !ApuP1Transport.QdEn && !ApuP1Transport.CvEn && !ApuP1Transport.CvrEn &&
          !ApuHarness.QdEn && !ApuHarness.CvEn && !ApuHarness.CvrEn &&
          !ApuSchedBoth.QdEn && !ApuSchedBoth.CvEn && !ApuSchedBoth.CvrEn &&
          !ApuBadVirglGrant.QdEn && !ApuBadVirglGrant.CvEn && !ApuBadVirglGrant.CvrEn);
    cfg = ApuP1Transport;
    cfg.QdEn = 1'b1;
    cfg.CvEn = 1'b1;
    cfg.CvrEn = 1'b1;
    check("quad does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.QdEn = 1'b1;
    cfg.CvEn = 1'b1;
    cfg.CvrEn = 1'b1;
    check("quad does not legalize virgl", !apu_cfg_legal(cfg));

    qd_step(APU_VGPU_QD_EMPTY, "qd empty");
    load_quad();
    good_iw();
    mem[QuadBase + 1] = 32'h0;
    qd_step(APU_VGPU_QD_FAULT, "bad y");
    check("bad keeps", !qd.valid);
    mem[QuadBase + 1] = qf(1);
    qd_step(APU_VGPU_QD_OK, "quad");
    check("quad kept flag", qd.valid);
    qd_step(APU_VGPU_QD_FAULT, "quad again");
    check("quad stays", qd.valid);

    cv_step(APU_VGPU_CV_EMPTY, "cv empty");
    good_map();
    vp.scale_x = 32'h0;
    cv_step(APU_VGPU_CV_FAULT, "bad scale");
    check("scale keeps", !cv.valid);
    good_map();
    cv_step(APU_VGPU_CV_OK, "cover");
    check("still clear", cv.covered && cv.word == 32'hFF1A_0D0D && cv.samples == 32'd4096);
    cv_step(APU_VGPU_CV_FAULT, "cover again");
    check("cover kept", cv.valid && cv.covered && cv.word == APU_VGPU_CLEAR_WORD);

    cvr_step(16'd1, 16'd0, APU_VGPU_CVR_OK, 14'd4, "interior");
    cvr_step(16'd2, 16'd3, APU_VGPU_CVR_OK, 14'd776, "sample 2,3");
    cvr_step(16'd63, 16'd63, APU_VGPU_CVR_OK, APU_VGPU_PIX_XY, "corner");
    cvr_step(16'd64, 16'd0, APU_VGPU_CVR_FAULT, 14'd0, "outside");
    cvr_step(16'd1, 16'd0, APU_VGPU_CVR_OK, 14'd4, "reread");

    pulse_reset();
    check("reset clears", qd == '0 && cv == '0);
    cvr_step(16'd1, 16'd0, APU_VGPU_CVR_EMPTY, 14'd0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu qd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
