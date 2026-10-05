// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vn_ring buffer_size 512 feeds Mesa vkCreateShaderModule into SpirvSubset.

`timescale 1ns/1ps

module tb_g6lc_apu_vnp;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic shm_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq;
  logic [7:0] shm_idx = 0;
  logic [31:0] shm_wdata = 0, shm_rdata, in_a = 0, in_b = 0, result;
  apu_vnp_cpl_t cpl;
  apu_vnp_t rec;
  logic off_rdy, off_v, off_irq;
  apu_vnp_cpl_t off_cpl;
  apu_vnp_t off_rec;
  logic [31:0] off_rdata, off_res;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vnp #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .shm_we_i(shm_we), .shm_idx_i(shm_idx),
    .shm_wdata_i(shm_wdata), .shm_rdata_o(shm_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vnp_o(rec),
    .irq_o(irq), .result_o(result)
  );
  g6lc_apu_vnp_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .shm_we_i(shm_we), .shm_idx_i(shm_idx),
    .shm_wdata_i(shm_wdata), .shm_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vnp_o(off_rec),
    .irq_o(off_irq), .result_o(off_res)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "vnp timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 ||
        off_irq !== 1'b0 || off_res !== '0)
      $fatal(1, "disabled vnp active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic poke(input logic [15:0] byte_off, input logic [31:0] w);
    @(negedge clk);
    shm_we = 1'b1;
    shm_idx = 8'(byte_off >> 2);
    shm_wdata = w;
    @(posedge clk);
    @(negedge clk);
    shm_we = 1'b0;
  endtask

  task automatic poke64(input logic [15:0] byte_off, input logic [63:0] v);
    poke(byte_off, v[31:0]);
    poke(byte_off + 16'd4, v[63:32]);
  endtask

  task automatic peek(input logic [15:0] byte_off, output logic [31:0] w);
    shm_idx = 8'(byte_off >> 2);
    @(negedge clk);
    w = shm_rdata;
  endtask

  task automatic fire;
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

  task automatic do_reset;
    shm_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0;
    in_a = '0; in_b = '0;
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

  task automatic load_create(input logic [31:0] mem [0:127], input int unsigned n,
                             input logic [63:0] module_id);
    int unsigned i;
    logic [15:0] base;
    base = APU_VNP_BUF_OFF;
    poke(base + 16'd0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(base + 16'd4, 32'd0);
    poke64(base + 16'd8, 64'hA1);
    poke64(base + 16'd16, 64'd1);
    poke(base + 16'd24, APU_VNENC_STYPE_SHADER_MODULE);
    poke64(base + 16'd28, 64'd0);
    poke(base + 16'd36, 32'd0);
    poke64(base + 16'd40, 64'(n * 4));
    poke64(base + 16'd48, 64'(n));
    for (i = 0; i < n; i++) poke(base + 16'(APU_VNENC_CODE0 * 4) + 16'(i * 4), mem[i]);
    poke64(base + 16'(APU_VNENC_CODE0 * 4) + 16'(n * 4), 64'd0);
    poke64(base + 16'(APU_VNENC_CODE0 * 4) + 16'(n * 4) + 16'd8, 64'd1);
    poke64(base + 16'(APU_VNENC_CODE0 * 4) + 16'(n * 4) + 16'd16, module_id);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    poke(APU_VNRING_HEAD_OFF, 32'((APU_VNENC_CODE0 + n + 6) * 4));
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] t;
    int unsigned n;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vnp off",
          !ApuOff.VnpEn && !ApuP1Transport.VnpEn && !ApuHarness.VnpEn);
    cfg = ApuP1Transport;
    cfg.VnpEn = 1'b1;
    check("vnp does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VnpEn = 1'b1;
    check("vnp does not legalize virgl", !apu_cfg_legal(cfg));
    check("ring buffer 512", APU_VNP_BUF_OFF == 16'd192 &&
          APU_VNP_BUF_BYTES == 512 && APU_VNENC_MAX_WORDS == 128);

    cases++;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    in_a = 32'd2;
    in_b = 32'd3;
    fire();
    check("create add", cpl.status == APU_VNP_OK && rec.valid && irq &&
          result == 32'd5 && rec.module_id == 64'hB2 && rec.loaded);
    peek(APU_VNRING_TAIL_OFF, t);
    check("tail consumed", t == 32'((APU_VNENC_CODE0 + n + 6) * 4));
    ack();

    cases++;
    in_a = 32'd4;
    in_b = 32'd5;
    fire();
    check("retain add", cpl.status == APU_VNP_OK && rec.valid &&
          result == 32'd9 && rec.module_id == 64'hB2);
    ack();

    cases++;
    do_reset;
    poke(APU_VNRING_HEAD_OFF, 32'd0);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    fire();
    check("empty ok", cpl.status == APU_VNP_OK && !rec.valid);
    ack();

    cases++;
    do_reset;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    poke(APU_VNP_BUF_OFF, 32'd0);
    in_a = 32'd2;
    in_b = 32'd3;
    fire();
    check("instance faults", cpl.status == APU_VNP_FAULT);
    ack();

    cases++;
    do_reset;
    poke(APU_VNRING_HEAD_OFF, 32'd1);
    poke(APU_VNRING_TAIL_OFF, 32'd0);
    fire();
    check("unaligned faults", cpl.status == APU_VNP_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vnp errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vnp cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
