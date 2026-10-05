// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailNext CS into AllocRun ALLOC/CREATE/DISPATCH. NumCapsets stays
// 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_qal;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_qal_req_t req;
  apu_qal_cpl_t cpl;
  apu_qal_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic [63:0] wr_a [0:7];
  logic [31:0] wr_l [0:7], wr_d0 [0:7];
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_qal_cpl_t off_cpl;
  apu_qal_t off_rec;
  logic [31:0] guest_w [0:191];
  logic [31:0] pay_bytes;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] UsedA  = 64'h0000_0000_0000_0600;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay2   = 64'h0000_0000_8800_A800;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_qal #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .qal_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_qal_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .qal_o(off_rec),
    .irq_o(off_irq), .isr_o(off_isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(off_rd), .rd_ready_i(rd_rdy), .rd_addr_o(), .rd_len_o(),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(off_rr), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(off_wr), .wr_ready_i(wr_rdy), .wr_addr_o(), .wr_len_o(),
    .wr_data_o(), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(off_wr_r),
    .wr_rsp_ok_i(wr_ok)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "qal timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0)
      $fatal(1, "disabled qal active");
  end

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_desc(
      input logic [63:0] addr, input logic [31:0] len,
      input logic [15:0] flags, input logic [15:0] nxt);
    pack_desc = '0;
    pack_desc[63:0] = addr;
    pack_desc[95:64] = len;
    pack_desc[111:96] = flags;
    pack_desc[127:112] = nxt;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_word(input logic [31:0] w);
    pack_word = '0;
    pack_word[31:0] = w;
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup(input logic [63:0] addr);
    logic [31:0] wbase;
    int unsigned i;
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word(32'h0001_0000);
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word(32'h0000_0000);
    else if (addr == BaseA)
      lookup = pack_desc(Pay0, pay_bytes, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay2, 32'd4, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr >= Pay0 && addr < Pay0 + 64'd768) begin
      wbase = 32'((addr - Pay0) >> 2);
      for (i = 0; i < 8; i++)
        if (wbase + 32'(i) < 32'd192)
          lookup[32*i +: 32] = guest_w[wbase + 32'(i)];
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
    end else begin
      if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
      else if (rd_v && rd_rdy) begin
        rsp_addr <= rd_addr;
        rsp_len <= rd_len;
        rsp_data <= lookup(rd_addr);
        rsp_ok <= (rd_len != 32'd0) && (rd_len <= 32'(APU_VGPU_BEAT_BYTES)) &&
                  (rd_len[1:0] == 2'd0);
        rsp_v <= 1'b1;
      end
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
      $display("FAIL %s case=%0d cycle=%0d nw=%0d st=%0d",
               name, cases, cycles, nwrite, cpl.status);
    end
  endtask

  task automatic fire(input apu_qal_req_t r);
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
    req_v = 1'b0; cpl_r = 1'b0; ack_v = 1'b0; req = '0;
    in_a = '0; in_b = '0; ack_w = '0; pay_bytes = 32'd32;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_qal_req_t mk_walk(input logic [15:0] didx, input logic [15:0] uidx);
    mk_walk = '0;
    mk_walk.gnh_only = 1'b0;
    mk_walk.avu.avail_base = Avail1;
    mk_walk.avu.desc_base = BaseA;
    mk_walk.avu.used_base = UsedA;
    mk_walk.avu.queue_size = 8'd4;
    mk_walk.avu.device_idx = didx;
    mk_walk.avu.used_idx = uidx;
    mk_walk.avu.max_chain = 4'd8;
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

  task automatic load_create_guest(input logic [31:0] mem [0:127], input int unsigned n,
                                   input logic [63:0] module_id);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VNENC_CMD_CREATE_SHADER_MODULE;
    guest_w[1] = 32'd0;
    guest_w[2] = 32'hA1;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VNENC_STYPE_SHADER_MODULE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'(n * 4);
    guest_w[11] = 32'd0;
    guest_w[12] = 32'(n);
    guest_w[13] = 32'd0;
    for (i = 0; i < n; i++) guest_w[APU_VNENC_CODE0 + i] = mem[i];
    guest_w[APU_VNENC_CODE0 + n] = 32'd0;
    guest_w[APU_VNENC_CODE0 + n + 1] = 32'd0;
    guest_w[APU_VNENC_CODE0 + n + 2] = 32'd1;
    guest_w[APU_VNENC_CODE0 + n + 3] = 32'd0;
    guest_w[APU_VNENC_CODE0 + n + 4] = module_id[31:0];
    guest_w[APU_VNENC_CODE0 + n + 5] = module_id[63:32];
    pay_bytes = 32'((APU_VNENC_CODE0 + n + 6) * 4);
  endtask

  task automatic load_alloc_guest(input logic [63:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VAC_CMD_ALLOC;
    guest_w[1] = 32'd0;
    guest_w[2] = 32'hD1;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VAC_STYPE_ALLOC;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'hA1;
    guest_w[10] = 32'd0;
    guest_w[11] = APU_VAC_LEVEL_PRIMARY;
    guest_w[12] = 32'd1;
    guest_w[13] = 32'd1;
    guest_w[14] = 32'd0;
    guest_w[15] = guest[31:0];
    guest_w[16] = guest[63:32];
    pay_bytes = 32'd68;
  endtask

  task automatic load_dispatch_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VND_CMD_DISPATCH;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd1;
    pay_bytes = 32'd32;
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] hc;
    int unsigned n, w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep qal off",
          !ApuOff.QalEn && !ApuP1Transport.QalEn && !ApuHarness.QalEn);
    cfg = ApuP1Transport;
    cfg.QalEn = 1'b1;
    check("qal does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QalEn = 1'b1;
    check("qal does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    fill_alu(16'd128, mem, n);
    load_create_guest(mem, n, 64'hB2);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("create quiet", cpl.status == APU_QAL_OK && rec.valid && !rec.dispatch &&
          !rec.alloc && !irq && rec.cmd == APU_VNENC_CMD_CREATE_SHADER_MODULE &&
          (nwrite - w0) == 0);
    ack_cpl();
    load_alloc_guest(64'hC1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    hc = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_QAL_OK && rec.valid && rec.alloc &&
          rec.handle != 32'hC1 && rec.handle != 32'd0 &&
          rec.cmd == APU_VAC_CMD_ALLOC && (nwrite - w0) == 0);
    ack_cpl();
    load_dispatch_guest(hc);
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("dispatch pub", cpl.status == APU_QAL_OK && rec.valid && rec.dispatch &&
          rec.irq && irq && rec.result == 32'd5 && rec.used_idx == 16'd1 &&
          rec.cmd == APU_VND_CMD_DISPATCH);
    check("order", (nwrite - w0) == 3 && wr_a[0] == Pay2 && wr_l[0] == 32'd4 &&
          wr_d0[0] == 32'd5 && wr_a[1] == UsedA + 64'd4 && wr_a[2] == UsedA);
    ack_cpl();
    ack_irq();

    cases++;
    w0 = nwrite;
    fire(mk_walk(16'd1, 16'd1));
    check("empty", cpl.status == APU_QAL_EMPTY && !rec.valid &&
          (nwrite - w0) == 0);
    ack_cpl();

    cases++;
    do_reset;
    load_dispatch_guest(32'hB1);
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_walk(16'd0, 16'd0));
    check("dispatch before create faults", cpl.status == APU_QAL_FAULT && !irq);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU qal errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_qal cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
