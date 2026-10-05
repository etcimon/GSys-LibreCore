// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// HandleRun dispatch then WRITE result, used.idx, ISR. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_rdn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [7:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata, in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_rdn_req_t req;
  apu_rdn_cpl_t cpl;
  apu_rdn_t rec;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] wr_addr;
  logic [31:0] wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data;
  logic [63:0] wr_a [0:7];
  logic [31:0] wr_l [0:7], wr_d0 [0:7];
  logic off_rdy, off_v, off_wr, off_irq, off_wr_r;
  logic [31:0] off_isr, off_rdata;
  apu_rdn_cpl_t off_cpl;
  apu_rdn_t off_rec;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;

  localparam logic [63:0] UsedA = 64'h0000_0000_0000_0600;
  localparam logic [63:0] Pay2  = 64'h0000_0000_8800_A800;

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_rdn #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .rdn_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_rdn_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .rdn_o(off_rec),
    .irq_o(off_irq), .isr_o(off_isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(), .wr_len_o(),
    .wr_data_o(), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_r),
    .wr_rsp_ok_i(wr_ok)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "rdn timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0 || off_isr !== '0)
      $fatal(1, "disabled rdn active");
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
    end else begin
      if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
      else if (wr_v && wr_rdy) begin
        if (nwrite < 8) begin
          wr_a[nwrite] <= wr_addr;
          wr_l[nwrite] <= wr_len;
          wr_d0[nwrite] <= wr_data[31:0];
        end
        wr_ok <= 1'b1;
        nwrite <= nwrite + 1;
        wr_rsp_v <= 1'b1;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d nw=%0d", name, cases, cycles, nwrite);
    end
  endtask

  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk);
    cs_we = 1'b1;
    cs_idx = 8'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire(input apu_rdn_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack_cpl;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  task automatic ack_irq;
    @(negedge clk);
    ack_v = 1'b1;
    ack_w = APU_UIR_ISR_VRING;
    @(posedge clk);
    @(negedge clk);
    ack_v = 1'b0;
    ack_w = '0;
    @(posedge clk);
  endtask

  task automatic do_reset;
    cs_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0; ack_v = 1'b0; req = '0;
    in_a = '0; in_b = '0; ack_w = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_rdn_req_t mk(
      input apu_hrn_op_e op, input apu_gnh_op_e gop, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h, input logic [15:0] uidx);
    mk = '0;
    mk.hrn.op = op;
    mk.hrn.gnh.op = gop;
    mk.hrn.gnh.kind = kind;
    mk.hrn.gnh.object_id = oid;
    mk.hrn.gnh.handle = h;
    mk.used_base = UsedA;
    mk.resp_addr = Pay2;
    mk.used_idx = uidx;
    mk.desc_id = 16'd0;
    mk.queue_size = 8'd4;
  endfunction

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
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'(n * 4));
    poke64(12, 64'(n));
    for (i = 0; i < n; i++) poke(APU_VNENC_CODE0 + i, mem[i]);
    poke64(APU_VNENC_CODE0 + n, 64'd0);
    poke64(APU_VNENC_CODE0 + n + 2, 64'd1);
    poke64(APU_VNENC_CODE0 + n + 4, module_id);
  endtask

  task automatic load_dispatch(input logic [63:0] cmdbuf);
    poke(0, APU_VND_CMD_DISPATCH);
    poke(1, 32'd0);
    poke64(2, cmdbuf);
    poke(4, 32'd1);
    poke(5, 32'd1);
    poke(6, 32'd1);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] hc;
    int unsigned n, w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep rdn off",
          !ApuOff.RdnEn && !ApuP1Transport.RdnEn && !ApuHarness.RdnEn);
    cfg = ApuP1Transport;
    cfg.RdnEn = 1'b1;
    check("rdn does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RdnEn = 1'b1;
    check("rdn does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    w0 = nwrite;
    fire(mk(APU_HRN_CREATE, APU_GNH_ALLOC, APU_GNH_MODULE, 32'd0, 32'd0, 16'd0));
    check("create quiet", cpl.status == APU_RDN_OK && rec.valid && !rec.dispatch &&
          !irq && (nwrite - w0) == 0);
    ack_cpl();
    fire(mk(APU_HRN_GNH, APU_GNH_ALLOC, APU_GNH_CMDBUF, 32'd1, 32'd0, 16'd0));
    hc = rec.handle;
    ack_cpl();
    load_dispatch(64'(hc));
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk(APU_HRN_DISPATCH, APU_GNH_LOOKUP, APU_GNH_CMDBUF, 32'd0, hc, 16'd0));
    check("dispatch pub", cpl.status == APU_RDN_OK && rec.valid && rec.dispatch &&
          rec.irq && irq && rec.result == 32'd5 && rec.resp_word0 == 32'd5 &&
          rec.resp_addr == Pay2 && rec.used_idx == 16'd1);
    check("order", (nwrite - w0) == 3 && wr_a[0] == Pay2 && wr_l[0] == 32'd4 &&
          wr_d0[0] == 32'd5 && wr_a[1] == UsedA + 64'd4 && wr_l[1] == 32'd8 &&
          wr_a[2] == UsedA && wr_l[2] == 32'd4);
    ack_cpl();
    ack_irq();
    check("ack lowers", !irq && isr == 32'd0);

    cases++;
    in_a = 32'd4;
    in_b = 32'd5;
    w0 = nwrite;
    fire(mk(APU_HRN_DISPATCH, APU_GNH_LOOKUP, APU_GNH_CMDBUF, 32'd0, hc, 16'd1));
    check("second pub", cpl.status == APU_RDN_OK && rec.result == 32'd9 &&
          rec.used_idx == 16'd2 && wr_d0[w0] == 32'd9);
    ack_cpl();
    ack_irq();

    cases++;
    do_reset;
    w0 = nwrite;
    fire(mk(APU_HRN_DISPATCH, APU_GNH_LOOKUP, APU_GNH_CMDBUF, 32'd0, 32'd1, 16'd0));
    check("before create", cpl.status == APU_RDN_FAULT && !irq &&
          (nwrite - w0) == 0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU rdn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_rdn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
