// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Diagnostic Venus CS ring into SpirvSubset. Not Mesa vn_protocol.

`timescale 1ns/1ps

module tb_g6lc_apu_vncs;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic ring_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq;
  logic [6:0] ring_idx = 0;
  logic [31:0] ring_wdata = 0, ring_rdata, result;
  apu_vncs_cpl_t cpl;
  logic off_rdy, off_v, off_irq;
  apu_vncs_cpl_t off_cpl;
  logic [31:0] off_rdata, off_res;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [6:0] ResIdx = 7'd96;

  g6lc_apu_vncs #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .ring_we_i(ring_we), .ring_idx_i(ring_idx),
    .ring_wdata_i(ring_wdata), .ring_rdata_o(ring_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .irq_o(irq), .result_o(result)
  );
  g6lc_apu_vncs_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ring_we_i(ring_we), .ring_idx_i(ring_idx),
    .ring_wdata_i(ring_wdata), .ring_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .irq_o(off_irq), .result_o(off_res)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #500000; $fatal(1, "vncs timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_irq !== 1'b0 ||
        off_cpl !== '0 || off_res !== '0)
      $fatal(1, "disabled vncs active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic do_reset;
    ring_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic logic [31:0] enc(input int unsigned wc, input int unsigned op);
    return {16'(wc), 16'(op)};
  endfunction

  task automatic fill_alu(input logic [15:0] alu, ref logic [31:0] mem [0:127],
                          output int unsigned n);
    n = 0;
    mem[n++] = APU_SPIRV_MAGIC;
    mem[n++] = 32'h00010000;
    mem[n++] = 32'h0;
    mem[n++] = 32'd13;
    mem[n++] = 32'h0;
    mem[n++] = enc(2, 17); mem[n++] = 32'd1;
    mem[n++] = enc(3, 14); mem[n++] = 32'd0; mem[n++] = 32'd1;
    mem[n++] = enc(5, 15); mem[n++] = 32'd5; mem[n++] = 32'd8;
    mem[n++] = 32'h6E69616D; mem[n++] = 32'h0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd5; mem[n++] = 32'd33; mem[n++] = 32'd0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd6; mem[n++] = 32'd33; mem[n++] = 32'd1;
    mem[n++] = enc(4, 71); mem[n++] = 32'd7; mem[n++] = 32'd33; mem[n++] = 32'd2;
    mem[n++] = enc(2, 19); mem[n++] = 32'd1;
    mem[n++] = enc(4, 21); mem[n++] = 32'd2; mem[n++] = 32'd32; mem[n++] = 32'd0;
    mem[n++] = enc(4, 32); mem[n++] = 32'd3; mem[n++] = 32'd12; mem[n++] = 32'd2;
    mem[n++] = enc(3, 33); mem[n++] = 32'd4; mem[n++] = 32'd1;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd5; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd6; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(5, 54); mem[n++] = 32'd1; mem[n++] = 32'd8; mem[n++] = 32'd0;
    mem[n++] = 32'd4;
    mem[n++] = enc(2, 248); mem[n++] = 32'd9;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd10; mem[n++] = 32'd5;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd11; mem[n++] = 32'd6;
    mem[n++] = enc(5, alu); mem[n++] = 32'd2; mem[n++] = 32'd12; mem[n++] = 32'd10;
    mem[n++] = 32'd11;
    mem[n++] = enc(3, 62); mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(1, 253);
    mem[n++] = enc(1, 56);
  endtask

  task automatic poke(input logic [6:0] idx, input logic [31:0] w);
    @(negedge clk);
    ring_we = 1'b1; ring_idx = idx; ring_wdata = w;
    @(posedge clk);
    @(negedge clk);
    ring_we = 1'b0;
  endtask

  task automatic doorbell;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
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

  initial begin
    apu_cfg_t cfg;
    logic [31:0] spirv [0:127];
    int unsigned n, i, base, prod;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_irq == 1'b0 &&
          req_rdy == 1'b1);
    check("profiles keep vncs off",
          !ApuOff.VncsEn && !ApuP1Transport.VncsEn && !ApuHarness.VncsEn);
    cfg = ApuP1Transport;
    cfg.VncsEn = 1'b1;
    check("vncs does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VncsEn = 1'b1;
    check("vncs does not legalize virgl", !apu_cfg_legal(cfg));
    begin
      logic [63:0] feats;
      feats = apu_device_features(ApuP1Transport);
      check("blob/ctxinit still off",
            feats[VIRTIO_GPU_F_RESOURCE_BLOB] == 1'b0 &&
            feats[VIRTIO_GPU_F_CONTEXT_INIT] == 1'b0);
    end

    cases++;
    fill_alu(16'd128, spirv, n);
    poke(7'd1, 32'd2);
    poke(7'd2, APU_VNCS_CREATE);
    poke(7'd3, 32'(n));
    for (i = 0; i < n; i++) poke(7'(4 + i), spirv[i]);
    base = 4 + n;
    poke(7'(base), APU_VNCS_DISPATCH);
    poke(7'(base + 1), 32'd2);
    poke(7'(base + 2), 32'd3);
    poke(7'(base + 3), 32'(ResIdx));
    prod = base + 4;
    poke(7'd0, 32'(prod));
    doorbell();
    check("create+dispatch irq", irq && cpl.status == APU_VNCS_OK && result == 32'd5);
    ring_idx = ResIdx;
    @(negedge clk);
    check("result in ring", ring_rdata == 32'd5);
    ack();

    cases++;
    poke(7'(prod), APU_VNCS_DISPATCH);
    poke(7'(prod + 1), 32'd4);
    poke(7'(prod + 2), 32'd5);
    poke(7'(prod + 3), 32'(ResIdx));
    poke(7'd0, 32'(prod + 4));
    doorbell();
    check("mutate dispatch", irq && cpl.status == APU_VNCS_OK && result == 32'd9);
    ring_idx = ResIdx;
    @(negedge clk);
    check("mutated ring", ring_rdata == 32'd9);
    ack();

    do_reset;
    cases++;
    poke(7'd1, 32'd2);
    poke(7'd2, 32'h0000_00ff);
    poke(7'd0, 32'd3);
    doorbell();
    check("unknown cmd faults", cpl.status == APU_VNCS_FAULT && !irq);
    ack();

    if (errors != 0) $fatal(1, "APU vncs errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vncs cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
