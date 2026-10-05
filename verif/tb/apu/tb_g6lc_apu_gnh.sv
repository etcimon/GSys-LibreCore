// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Generational context/resource/program table. Stale gen faults.

`timescale 1ns/1ps

module tb_g6lc_apu_gnh;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_gnh_req_t req;
  apu_gnh_cpl_t cpl;
  apu_gnh_t rec;
  logic off_rdy, off_v;
  apu_gnh_cpl_t off_cpl;
  apu_gnh_t off_rec;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_gnh #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .gnh_o(rec)
  );
  g6lc_apu_gnh_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .gnh_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #400000; $fatal(1, "gnh timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled gnh active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic fire(input apu_gnh_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_gnh_req_t mk(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk = '0;
    mk.op = op;
    mk.kind = kind;
    mk.object_id = oid;
    mk.handle = h;
  endfunction

  initial begin
    apu_cfg_t cfg;
    apu_gnh_req_t r;
    logic [31:0] h0, h1, old_h;
    int unsigned i;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep gnh off",
          !ApuOff.GnhEn && !ApuP1Transport.GnhEn && !ApuHarness.GnhEn);
    cfg = ApuP1Transport;
    cfg.GnhEn = 1'b1;
    check("gnh does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.GnhEn = 1'b1;
    check("gnh does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    fire(mk(APU_GNH_ALLOC, APU_GNH_MODULE, 32'hB2, 32'd0));
    h0 = rec.handle;
    check("alloc module", cpl.status == APU_GNH_OK && rec.valid &&
          rec.kind == APU_GNH_MODULE && rec.object_id == 32'hB2 &&
          rec.slot == 5'd0 && rec.gen == 16'd1 && rec.pin == 8'd0 &&
          h0 == apu_gnh_handle(16'd1, 5'd0));
    ack();
    fire(mk(APU_GNH_LOOKUP, APU_GNH_MODULE, 32'd0, h0));
    check("lookup module", cpl.status == APU_GNH_OK && rec.valid &&
          rec.object_id == 32'hB2 && rec.kind == APU_GNH_MODULE);
    ack();

    cases++;
    fire(mk(APU_GNH_PIN, APU_GNH_MODULE, 32'd0, h0));
    check("pin", cpl.status == APU_GNH_OK && rec.pin == 8'd1);
    ack();
    fire(mk(APU_GNH_RETIRE, APU_GNH_MODULE, 32'd0, h0));
    check("retire while pinned faults", cpl.status == APU_GNH_FAULT && !rec.valid);
    ack();
    fire(mk(APU_GNH_UNPIN, APU_GNH_MODULE, 32'd0, h0));
    check("unpin", cpl.status == APU_GNH_OK && rec.pin == 8'd0);
    ack();
    fire(mk(APU_GNH_RETIRE, APU_GNH_MODULE, 32'd0, h0));
    check("retire", cpl.status == APU_GNH_OK && !rec.valid);
    ack();
    fire(mk(APU_GNH_LOOKUP, APU_GNH_MODULE, 32'd0, h0));
    check("stale gen faults", cpl.status == APU_GNH_FAULT);
    ack();

    cases++;
    old_h = h0;
    fire(mk(APU_GNH_ALLOC, APU_GNH_MODULE, 32'hB2, 32'd0));
    h1 = rec.handle;
    check("realloc gen 2", cpl.status == APU_GNH_OK && rec.valid &&
          rec.gen == 16'd2 && rec.slot == 5'd0 && h1 != old_h);
    ack();
    fire(mk(APU_GNH_LOOKUP, APU_GNH_MODULE, 32'd0, old_h));
    check("old handle faults", cpl.status == APU_GNH_FAULT);
    ack();
    fire(mk(APU_GNH_LOOKUP, APU_GNH_MODULE, 32'd0, h1));
    check("new handle ok", cpl.status == APU_GNH_OK && rec.object_id == 32'hB2);
    ack();

    cases++;
    do_reset;
    for (i = 0; i < APU_GNH_SLOTS; i++) begin
      fire(mk(APU_GNH_ALLOC, APU_GNH_RES, 32'(i + 1), 32'd0));
      check("fill", cpl.status == APU_GNH_OK && rec.slot == 5'(i));
      ack();
    end
    fire(mk(APU_GNH_ALLOC, APU_GNH_RES, 32'(APU_GNH_SLOTS + 1), 32'd0));
    check("full faults", cpl.status == APU_GNH_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    fire(mk(APU_GNH_ALLOC, APU_GNH_CTX, 32'd0, 32'd0));
    check("zero id faults", cpl.status == APU_GNH_FAULT);
    ack();
    fire(mk(APU_GNH_ALLOC, APU_GNH_CTX, 32'd1, 32'd0));
    h0 = rec.handle;
    ack();
    fire(mk(APU_GNH_ALLOC, APU_GNH_CTX, 32'd1, 32'd0));
    check("duplicate live faults", cpl.status == APU_GNH_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU gnh errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_gnh cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
