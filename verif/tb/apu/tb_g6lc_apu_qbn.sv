// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AvailNext CS into BeginRun ALLOC/BEGIN/CREATE/DISPATCH. NumCapsets
// stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_qbn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_qbn_req_t req;
  apu_qbn_cpl_t cpl;
  apu_qbn_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic [63:0] wr_a [0:7];
  logic [31:0] wr_l [0:7], wr_d0 [0:7];
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_qbn_cpl_t off_cpl;
  apu_qbn_t off_rec;
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

  g6lc_apu_qbn #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .qbn_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_qbn_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .qbn_o(off_rec),
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
  initial begin #2000000; $fatal(1, "qbn timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0)
      $fatal(1, "disabled qbn active");
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

  task automatic fire(input apu_qbn_req_t r);
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

  function automatic apu_qbn_req_t mk_walk(input logic [15:0] didx, input logic [15:0] uidx);
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

  task automatic load_begin_guest(input logic [31:0] h, input logic [31:0] bflags);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBG_CMD_BEGIN;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VBG_STYPE_BEGIN;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = bflags;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    pay_bytes = 32'd48;
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

  task automatic load_end_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VEN_CMD_END;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    pay_bytes = 32'd16;
  endtask

  task automatic load_submit_guest(input logic [31:0] qh, input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VQS_CMD_SUBMIT;
    guest_w[1] = 32'd0;
    guest_w[2] = qh;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = APU_VQS_STYPE_SUBMIT;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd1;
    guest_w[16] = 32'd1;
    guest_w[17] = 32'd0;
    guest_w[18] = h;
    guest_w[19] = 32'd0;
    guest_w[20] = 32'd0;
    guest_w[21] = 32'd0;
    guest_w[22] = 32'd0;
    guest_w[23] = 32'd0;
    guest_w[24] = 32'd0;
    pay_bytes = 32'd100;
  endtask

  task automatic load_queue_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VGQ_CMD_QUEUE;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd24;
  endtask

  task automatic load_device_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VCD_CMD_DEVICE;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VCD_STYPE_DEVICE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd1;
    guest_w[11] = 32'd1;
    guest_w[12] = 32'd0;
    guest_w[13] = APU_VCD_STYPE_QUEUE;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = 32'd1;
    guest_w[19] = 32'd1;
    guest_w[20] = 32'd0;
    guest_w[21] = APU_VCD_PRIORITY_ONE;
    guest_w[22] = 32'd0;
    guest_w[23] = 32'd0;
    guest_w[24] = 32'd0;
    guest_w[25] = 32'd0;
    guest_w[26] = 32'd0;
    guest_w[27] = 32'd0;
    guest_w[28] = 32'd0;
    guest_w[29] = 32'd0;
    guest_w[30] = 32'd0;
    guest_w[31] = 32'd0;
    pay_bytes = 32'd128;
  endtask

  task automatic load_instance_guest;
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VCI_CMD_INSTANCE;
    guest_w[1] = 32'd0;
    guest_w[2] = 32'hE1;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VCI_STYPE_INSTANCE;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    pay_bytes = 32'd72;
  endtask

  task automatic load_enum_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VEP_CMD_ENUM;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd1;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = 32'd0;
    pay_bytes = 32'd44;
  endtask

  task automatic load_qfam_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VQF_CMD_QFAM;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VQF_FAMILY_COUNT;
    guest_w[7] = 32'd1;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = 32'd0;
    pay_bytes = 32'd44;
  endtask

  task automatic load_feat_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VPF_CMD_FEAT;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd24;
  endtask

  task automatic load_props_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VPP_CMD_PROPS;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd24;
  endtask

  task automatic load_mem_guest(input logic [31:0] h);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VMP_CMD_MEM;
    guest_w[1] = 32'd0;
    guest_w[2] = h;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd24;
  endtask

  task automatic load_vkmem_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VAM_CMD_MEMORY;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VAM_STYPE_ALLOC;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd4096;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = guest;
    guest_w[15] = 32'd0;
    pay_bytes = 32'd64;
  endtask

  task automatic load_buffer_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VXB_CMD_BUFFER;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VXB_STYPE_BUFFER;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd4096;
    guest_w[11] = 32'd0;
    guest_w[12] = APU_VXB_USAGE_STORAGE;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = 32'd0;
    guest_w[19] = guest;
    guest_w[20] = 32'd0;
    pay_bytes = 32'd84;
  endtask

  task automatic load_bind_guest(input logic [31:0] dev, input logic [31:0] bufh,
                                 input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBB_CMD_BIND;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = bufh;
    guest_w[5] = 32'd0;
    guest_w[6] = memh;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_map_guest(input logic [31:0] dev, input logic [31:0] memh,
                                input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VMM_CMD_MAP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = memh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd4096;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd0;
    guest_w[11] = guest;
    guest_w[12] = 32'd0;
    pay_bytes = 32'd52;
  endtask

  task automatic load_unmap_guest(input logic [31:0] dev, input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VUM_CMD_UNMAP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = memh;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd24;
  endtask

  task automatic load_bufreq_guest(input logic [31:0] dev, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBM_CMD_BUFREQ;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = bufh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_flush_guest(input logic [31:0] dev, input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VFM_CMD_FLUSH;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = APU_VFM_STYPE_RANGE;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = memh;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd4096;
    guest_w[15] = 32'd0;
    pay_bytes = 32'd64;
  endtask

  task automatic load_inval_guest(input logic [31:0] dev, input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VIM_CMD_INVAL;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = APU_VIM_STYPE_RANGE;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = memh;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd4096;
    guest_w[15] = 32'd0;
    pay_bytes = 32'd64;
  endtask

  task automatic load_memc_guest(input logic [31:0] dev, input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VMC_CMD_MEMC;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = memh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dsl_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VDL_CMD_DSLAYOUT;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VDL_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = 32'd0;
    guest_w[11] = APU_VDL_STORAGE;
    guest_w[12] = 32'd1;
    guest_w[13] = APU_VDL_COMPUTE;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = guest;
    guest_w[17] = 32'd0;
    pay_bytes = 32'd72;
  endtask

  task automatic load_pl_guest(input logic [31:0] dev, input logic [31:0] setl,
                               input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VPL_CMD_PLAYOUT;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VPL_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = setl;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = guest;
    guest_w[16] = 32'd0;
    pay_bytes = 32'd68;
  endtask

  task automatic load_cp_guest(input logic [31:0] dev, input logic [31:0] shader,
                               input logic [31:0] layout, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VCP_CMD_CPIPE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd1;
    guest_w[8] = 32'd0;
    guest_w[9] = APU_VCP_STYPE;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    guest_w[12] = APU_VDL_COMPUTE;
    guest_w[13] = shader;
    guest_w[14] = 32'd0;
    guest_w[15] = layout;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = 32'd0;
    guest_w[19] = guest;
    guest_w[20] = 32'd0;
    pay_bytes = 32'd84;
  endtask

  task automatic load_dset_guest(input logic [31:0] dev, input logic [31:0] layout,
                                 input logic [31:0] poolh, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VDA_CMD_DESCSET;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VDA_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = poolh;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd1;
    guest_w[12] = layout;
    guest_w[13] = 32'd0;
    guest_w[14] = guest;
    guest_w[15] = 32'd0;
    pay_bytes = 32'd64;
  endtask

  task automatic load_pool_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VPO_CMD_POOL;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VPO_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd1;
    guest_w[11] = 32'd1;
    guest_w[12] = 32'd1;
    guest_w[13] = 32'd0;
    guest_w[14] = APU_VDL_STORAGE;
    guest_w[15] = 32'd1;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = guest;
    guest_w[19] = 32'd0;
    pay_bytes = 32'd80;
  endtask

  task automatic load_image_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VXI_CMD_IMAGE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VXI_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = APU_VXI_TYPE_2D;
    guest_w[11] = APU_VXI_FORMAT;
    guest_w[12] = APU_VXI_WIDTH;
    guest_w[13] = APU_VXI_HEIGHT;
    guest_w[14] = 32'd1;
    guest_w[15] = 32'd1;
    guest_w[16] = 32'd1;
    guest_w[17] = 32'd1;
    guest_w[18] = APU_VXI_TILING_LINEAR;
    guest_w[19] = APU_VXI_USAGE_STORAGE;
    guest_w[20] = 32'd0;
    guest_w[21] = 32'd0;
    guest_w[22] = 32'd0;
    guest_w[23] = 32'd0;
    guest_w[24] = 32'd0;
    guest_w[25] = 32'd0;
    guest_w[26] = 32'd0;
    guest_w[27] = guest;
    guest_w[28] = 32'd0;
    pay_bytes = 32'd116;
  endtask

  task automatic load_bindimg_guest(input logic [31:0] dev, input logic [31:0] imgh,
                                    input logic [31:0] memh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBI_CMD_BINDIMG;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = imgh;
    guest_w[5] = 32'd0;
    guest_w[6] = memh;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_imgreq_guest(input logic [31:0] dev, input logic [31:0] imgh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VMI_CMD_IMGREQ;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = imgh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_view_guest(input logic [31:0] dev, input logic [31:0] imgh,
                                 input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VXV_CMD_VIEW;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VXV_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = imgh;
    guest_w[11] = 32'd0;
    guest_w[12] = APU_VXV_TYPE_2D;
    guest_w[13] = APU_VXI_FORMAT;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = APU_VXV_ASPECT_COLOR;
    guest_w[19] = 32'd0;
    guest_w[20] = 32'd1;
    guest_w[21] = 32'd0;
    guest_w[22] = 32'd1;
    guest_w[23] = 32'd0;
    guest_w[24] = 32'd0;
    guest_w[25] = guest;
    guest_w[26] = 32'd0;
    pay_bytes = 32'd108;
  endtask

  task automatic load_sampler_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VSM_CMD_SAMPLER;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VSM_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = APU_VSM_LINEAR;
    guest_w[11] = APU_VSM_LINEAR;
    guest_w[12] = APU_VSM_LINEAR;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = guest;
    guest_w[19] = 32'd0;
    pay_bytes = 32'd80;
  endtask

  task automatic load_rpass_guest(input logic [31:0] dev, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VRP_CMD_RPASS;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VRP_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = 32'd1;
    guest_w[11] = APU_VXI_FORMAT;
    guest_w[12] = 32'd1;
    guest_w[13] = 32'd1;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd0;
    guest_w[18] = guest;
    guest_w[19] = 32'd0;
    pay_bytes = 32'd80;
  endtask

  task automatic load_gpipe_guest(input logic [31:0] dev, input logic [31:0] shader,
                                  input logic [31:0] layout, input logic [31:0] rpass,
                                  input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VGP_CMD_GPIPE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd1;
    guest_w[8] = 32'd0;
    guest_w[9] = APU_VGP_STYPE;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    guest_w[12] = APU_VGP_VERTEX;
    guest_w[13] = shader;
    guest_w[14] = 32'd0;
    guest_w[15] = layout;
    guest_w[16] = 32'd0;
    guest_w[17] = rpass;
    guest_w[18] = 32'd0;
    guest_w[19] = 32'd0;
    guest_w[20] = 32'd0;
    guest_w[21] = 32'd0;
    guest_w[22] = guest;
    guest_w[23] = 32'd0;
    pay_bytes = 32'd96;
  endtask

  task automatic load_fbuf_guest(input logic [31:0] dev, input logic [31:0] rpass,
                                 input logic [31:0] viewh, input logic [31:0] guest);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VFB_CMD_FBUF;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VFB_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = rpass;
    guest_w[11] = 32'd0;
    guest_w[12] = 32'd1;
    guest_w[13] = viewh;
    guest_w[14] = 32'd0;
    guest_w[15] = APU_VXI_WIDTH;
    guest_w[16] = APU_VXI_HEIGHT;
    guest_w[17] = 32'd1;
    guest_w[18] = 32'd0;
    guest_w[19] = 32'd0;
    guest_w[20] = guest;
    guest_w[21] = 32'd0;
    pay_bytes = 32'd88;
  endtask

  task automatic load_beginrp_guest(input logic [31:0] cbuf, input logic [31:0] rpass,
                                    input logic [31:0] fbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VRB_CMD_BEGINRP;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VRB_STYPE;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = rpass;
    guest_w[10] = 32'd0;
    guest_w[11] = fbuf;
    guest_w[12] = 32'd0;
    guest_w[13] = 32'd0;
    guest_w[14] = 32'd0;
    guest_w[15] = APU_VXI_WIDTH;
    guest_w[16] = APU_VXI_HEIGHT;
    guest_w[17] = 32'd1;
    guest_w[18] = APU_VRB_INLINE;
    pay_bytes = 32'd76;
  endtask

  task automatic load_draw_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VDW_CMD_DRAW;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VDW_VERTS;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_endrp_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VRE_CMD_ENDRP;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    pay_bytes = 32'd16;
  endtask

  task automatic load_setvp_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VVP_CMD_SETVP;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = APU_VVP_F64;
    guest_w[11] = APU_VVP_F64;
    guest_w[12] = 32'd0;
    guest_w[13] = APU_VVP_F1;
    pay_bytes = 32'd56;
  endtask

  task automatic load_setsc_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VSI_CMD_SETSC;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    guest_w[10] = APU_VXI_WIDTH;
    guest_w[11] = APU_VXI_HEIGHT;
    pay_bytes = 32'd48;
  endtask


  task automatic load_slw_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SLW_CMD_SLW;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VVP_F1;
    pay_bytes = 32'd20;
  endtask

  task automatic load_sdb_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SDB_CMD_SDB;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    pay_bytes = 32'd28;
  endtask

  task automatic load_sbc_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SBC_CMD_SBC;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask


  task automatic load_scm_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SCM_CMD_SCM;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_SCM_FACE;
    guest_w[5] = APU_SCM_MASK;
    pay_bytes = 32'd24;
  endtask

  task automatic load_swm_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SWM_CMD_SWM;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_SCM_FACE;
    guest_w[5] = APU_SCM_MASK;
    pay_bytes = 32'd24;
  endtask


  task automatic load_ccb_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CCB_CMD_CCB;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[6] = bufh;
    guest_w[8] = APU_CCB_COUNT;
    guest_w[11] = APU_CCB_DST_OFF;
    guest_w[13] = APU_CCB_SIZE;
    pay_bytes = 32'd64;
  endtask

  task automatic load_cci_guest(input logic [31:0] cbuf, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CCI_CMD_CCI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = img;
    guest_w[8] = APU_CCI_SRC_LAYOUT;
    guest_w[9] = APU_CCI_DST_LAYOUT;
    guest_w[10] = APU_CCI_COUNT;
    guest_w[11] = APU_CCI_ASPECT;
    guest_w[14] = 32'd1;
    guest_w[18] = APU_CCI_ASPECT;
    guest_w[21] = 32'd1;
    guest_w[22] = APU_CCI_DST_X;
    guest_w[25] = APU_CCI_EXT_W;
    guest_w[26] = APU_CCI_EXT_H;
    guest_w[27] = APU_CCI_EXT_D;
    pay_bytes = 32'd128;
  endtask

  task automatic load_bli_guest(input logic [31:0] cbuf, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_BLI_CMD_BLI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = img;
    guest_w[8] = APU_CCI_SRC_LAYOUT;
    guest_w[9] = APU_CCI_DST_LAYOUT;
    guest_w[10] = APU_CCI_COUNT;
    guest_w[11] = APU_CCI_ASPECT;
    guest_w[14] = 32'd1;
    guest_w[18] = APU_BLI_SRC1_X;
    guest_w[19] = APU_BLI_SRC1_Y;
    guest_w[20] = APU_BLI_SRC1_Z;
    guest_w[21] = APU_CCI_ASPECT;
    guest_w[24] = 32'd1;
    guest_w[25] = APU_BLI_DST0_X;
    guest_w[28] = APU_BLI_DST1_X;
    guest_w[29] = APU_BLI_DST1_Y;
    guest_w[30] = APU_BLI_DST1_Z;
    guest_w[31] = APU_BLI_FILTER;
    pay_bytes = 32'd128;
  endtask


  task automatic load_cib_guest(input logic [31:0] cbuf, input logic [31:0] img,
                                input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CIB_CMD_CIB;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = bufh;
    guest_w[8] = APU_CCI_SRC_LAYOUT;
    guest_w[9] = APU_CCI_COUNT;
    guest_w[14] = APU_CCI_ASPECT;
    guest_w[17] = 32'd1;
    guest_w[21] = APU_CBI_EXT_W;
    guest_w[22] = APU_CBI_EXT_H;
    guest_w[23] = APU_CCI_EXT_D;
    pay_bytes = 32'd128;
  endtask

  task automatic load_ubf_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_UBF_CMD_UBF;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[8] = APU_UBF_SIZE;
    guest_w[10] = APU_UBF_DATA;
    pay_bytes = 32'd44;
  endtask

  task automatic load_fil_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_FIL_CMD_FIL;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[8] = APU_VBM_SIZE;
    guest_w[10] = APU_FIL_DATA;
    pay_bytes = 32'd44;
  endtask


  task automatic load_dri_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DRI_CMD_DRI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[8] = APU_DRI_COUNT;
    guest_w[9] = APU_DRI_STRIDE;
    pay_bytes = 32'd40;
  endtask

  task automatic load_ixi_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_IXI_CMD_IXI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[8] = APU_IXI_COUNT;
    guest_w[9] = APU_IXI_STRIDE;
    pay_bytes = 32'd40;
  endtask


  task automatic load_dsi_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DSI_CMD_DSI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    pay_bytes = 32'd32;
  endtask

  task automatic load_rsi_guest(input logic [31:0] cbuf, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RSI_CMD_RSI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = img;
    guest_w[8] = APU_CCI_SRC_LAYOUT;
    guest_w[9] = APU_CCI_DST_LAYOUT;
    guest_w[10] = APU_CCI_COUNT;
    guest_w[11] = APU_CCI_ASPECT;
    guest_w[14] = 32'd1;
    guest_w[18] = APU_CCI_ASPECT;
    guest_w[21] = 32'd1;
    guest_w[22] = APU_RSI_DST_X;
    guest_w[25] = APU_RSI_EXT;
    guest_w[26] = APU_RSI_EXT;
    guest_w[27] = APU_CCI_EXT_D;
    pay_bytes = 32'd128;
  endtask

  task automatic load_cds_guest(input logic [31:0] cbuf, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CDS_CMD_CDS;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = APU_CCI_DST_LAYOUT;
    guest_w[7] = APU_VVP_F1;
    guest_w[9] = APU_CCI_COUNT;
    guest_w[10] = APU_CDS_ASPECT;
    guest_w[12] = 32'd1;
    guest_w[14] = 32'd1;
    pay_bytes = 32'd64;
  endtask

  task automatic load_cat_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CAT_CMD_CAT;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = APU_CAT_COUNT;
    guest_w[5] = APU_CAT_ASPECT;
    guest_w[11] = APU_CAT_COUNT;
    guest_w[14] = APU_CAT_EXT;
    guest_w[15] = APU_CAT_EXT;
    guest_w[17] = 32'd1;
    pay_bytes = 32'd72;
  endtask

  task automatic load_ccl_guest(input logic [31:0] cbuf, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CCL_CMD_CCL;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = img;
    guest_w[6] = APU_CCI_DST_LAYOUT;
    guest_w[11] = APU_CCI_COUNT;
    guest_w[12] = APU_CCI_ASPECT;
    guest_w[14] = 32'd1;
    guest_w[16] = 32'd1;
    pay_bytes = 32'd128;
  endtask

  task automatic load_cbi_guest(input logic [31:0] cbuf, input logic [31:0] bufh,
                                input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_CBI_CMD_CBI;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[4] = bufh;
    guest_w[6] = img;
    guest_w[8] = APU_CCI_DST_LAYOUT;
    guest_w[9] = APU_CCI_COUNT;
    guest_w[14] = APU_CCI_ASPECT;
    guest_w[17] = 32'd1;
    guest_w[21] = APU_CBI_EXT_W;
    guest_w[22] = APU_CBI_EXT_H;
    guest_w[23] = APU_CCI_EXT_D;
    pay_bytes = 32'd128;
  endtask

  task automatic load_srf_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SRF_CMD_SRF;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_SCM_FACE;
    guest_w[5] = APU_SRF_REF;
    pay_bytes = 32'd24;
  endtask

  task automatic load_sbb_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_SBB_CMD_SBB;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = APU_VVP_F1;
    pay_bytes = 32'd24;
  endtask

  task automatic load_barrier_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VPB_CMD_BARRIER;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VPB_TOP;
    guest_w[5] = APU_VPB_TOP;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_bindvtx_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VVB_CMD_BINDVTX;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd1;
    guest_w[6] = bufh;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_bindidx_guest(input logic [31:0] cbuf, input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VIB_CMD_BINDIDX;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = bufh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = APU_VIB_UINT16;
    pay_bytes = 32'd36;
  endtask

  task automatic load_drawidx_guest(input logic [31:0] cbuf);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VDI_CMD_DRAWIDX;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VDI_INDICES;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    pay_bytes = 32'd36;
  endtask

  task automatic load_update_guest(input logic [31:0] dev, input logic [31:0] dset,
                                   input logic [31:0] bufh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VUD_CMD_UPDATE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    guest_w[7] = APU_VUD_STYPE;
    guest_w[8] = dset;
    guest_w[9] = 32'd0;
    guest_w[10] = APU_VDL_STORAGE;
    guest_w[11] = 32'd1;
    guest_w[12] = 32'd0;
    guest_w[13] = bufh;
    guest_w[14] = 32'd0;
    guest_w[15] = 32'd0;
    guest_w[16] = 32'd0;
    guest_w[17] = 32'd4096;
    guest_w[18] = 32'd0;
    guest_w[19] = 32'd0;
    pay_bytes = 32'd80;
  endtask

  task automatic load_bindpipe_guest(input logic [31:0] cbuf, input logic [31:0] pipeh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBP_CMD_BINDPIPE;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VBP_COMPUTE;
    guest_w[5] = pipeh;
    guest_w[6] = 32'd0;
    pay_bytes = 32'd28;
  endtask

  task automatic load_binddesc_guest(input logic [31:0] cbuf, input logic [31:0] lay,
                                     input logic [31:0] dset);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VBD_CMD_BINDDESC;
    guest_w[1] = 32'd0;
    guest_w[2] = cbuf;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_VBP_COMPUTE;
    guest_w[5] = lay;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd1;
    guest_w[9] = dset;
    guest_w[10] = 32'd0;
    guest_w[11] = 32'd0;
    pay_bytes = 32'd48;
  endtask

  task automatic load_wait_guest(input logic [31:0] qh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_VWI_CMD_WAIT;
    guest_w[1] = 32'd0;
    guest_w[2] = qh;
    guest_w[3] = 32'd0;
    pay_bytes = 32'd16;
  endtask

  task automatic load_dfb_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DFB_CMD_DFB;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dvw_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DVW_CMD_DVW;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dsm_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DSM_CMD_DSM;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_drp_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DRP_CMD_DRP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dbf_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DBF_CMD_DBF;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dim_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DIM_CMD_DIM;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_fme_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_FME_CMD_FME;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dmd_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DMD_CMD_DMD;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dpl_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DPL_CMD_DPL;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dyo_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DYO_CMD_DYO;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dds_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DDS_CMD_DDS;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dpo_guest(input logic [31:0] dev, input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DPO_CMD_DPO;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = objh;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_fds_guest(input logic [31:0] dev, input logic [31:0] pool,
                                   input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_FDS_CMD_FDS;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = pool;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd1;
    guest_w[8] = objh;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_rcb_guest(input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RCB_CMD_RCB;
    guest_w[1] = 32'd0;
    guest_w[2] = objh;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_fcb_guest(input logic [31:0] dev, input logic [31:0] pool,
                                   input logic [31:0] objh);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_FCB_CMD_FCB;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = pool;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd1;
    guest_w[8] = objh;
    guest_w[9] = 32'd0;
    pay_bytes = 32'd40;
  endtask

  task automatic load_ddv_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DDV_CMD_DDV;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_rcp_guest(input logic [31:0] dev, input logic [31:0] pool);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RCP_CMD_RCP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = pool;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dcp_guest(input logic [31:0] dev, input logic [31:0] pool);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DCP_CMD_DCP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = pool;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_din_guest(input logic [31:0] insth);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DIN_CMD_DIN;
    guest_w[1] = 32'd0;
    guest_w[2] = insth;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_gfp_guest(input logic [31:0] phys);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_GFP_CMD_GFP;
    guest_w[1] = 32'd0;
    guest_w[2] = phys;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_GFP_FORMAT;
    guest_w[5] = 32'd1;
    guest_w[6] = 32'd0;
    pay_bytes = 32'd28;
  endtask

  task automatic load_ifp_guest(input logic [31:0] phys);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_IFP_CMD_IFP;
    guest_w[1] = 32'd0;
    guest_w[2] = phys;
    guest_w[3] = 32'd0;
    guest_w[4] = APU_GFP_FORMAT;
    guest_w[5] = APU_IFP_TYPE_2D;
    guest_w[6] = APU_IFP_TILING_LINEAR;
    guest_w[7] = APU_IFP_USAGE_STORAGE;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = 32'd0;
    pay_bytes = 32'd44;
  endtask

  task automatic load_dex_guest(input logic [31:0] phys);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DEX_CMD_DEX;
    guest_w[1] = 32'd0;
    guest_w[2] = phys;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd0;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    pay_bytes = 32'd36;
  endtask

  task automatic load_rdp_guest(input logic [31:0] dev, input logic [31:0] pool);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RDP_CMD_RDP;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = pool;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    pay_bytes = 32'd32;
  endtask

  task automatic load_iex_guest;
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_IEX_CMD_IEX;
    guest_w[1] = 32'd0;
    guest_w[2] = 32'd0;
    guest_w[3] = 32'd0;
    guest_w[4] = 32'd1;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd0;
    pay_bytes = 32'd28;
  endtask


  task automatic load_gfs_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_GFS_CMD_GFS;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[4] = 32'hF1;
    pay_bytes = 32'd24;
  endtask

  task automatic load_wfe_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_WFE_CMD_WFE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[4] = APU_WFE_COUNT;
    guest_w[5] = 32'hF1;
    guest_w[7] = APU_WFE_WAITALL;
    pay_bytes = 32'd40;
  endtask

  task automatic load_rfe_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RFE_CMD_RFE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[4] = APU_RFE_COUNT;
    guest_w[5] = 32'hF1;
    pay_bytes = 32'd28;
  endtask

  task automatic load_dfe_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DFE_CMD_DFE;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[4] = 32'hF1;
    pay_bytes = 32'd32;
  endtask

  task automatic load_dwi_guest(input logic [31:0] dev);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_DWI_CMD_DWI;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    pay_bytes = 32'd16;
  endtask

  task automatic load_isl_guest(input logic [31:0] dev, input logic [31:0] img);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_ISL_CMD_ISL;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = img;
    guest_w[5] = 32'd0;
    guest_w[6] = APU_VXV_ASPECT_COLOR;
    guest_w[7] = 32'd0;
    guest_w[8] = 32'd0;
    guest_w[9] = 32'd1;
    guest_w[10] = 32'd0;
    pay_bytes = 32'd44;
  endtask

  task automatic load_rag_guest(input logic [31:0] dev, input logic [31:0] rp);
    int unsigned i;
    for (i = 0; i < 192; i++) guest_w[i] = '0;
    guest_w[0] = APU_RAG_CMD_RAG;
    guest_w[1] = 32'd0;
    guest_w[2] = dev;
    guest_w[3] = 32'd0;
    guest_w[4] = rp;
    guest_w[5] = 32'd0;
    guest_w[6] = 32'd1;
    guest_w[7] = 32'd0;
    pay_bytes = 32'd32;
  endtask


  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] hc, hq, hd, hi, hp, hb, hm, hl, hk, hg, hs, ho, hj, hv, ha, hr, hy, hf, hu;
    int unsigned n, w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep qbn off",
          !ApuOff.QbnEn && !ApuP1Transport.QbnEn && !ApuHarness.QbnEn);
    cfg = ApuP1Transport;
    cfg.QbnEn = 1'b1;
    check("qbn does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QbnEn = 1'b1;
    check("qbn does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);
    check("mesa ids", APU_VAC_CMD_ALLOC == 32'd88 &&
          APU_VBG_CMD_BEGIN == 32'd90 &&
          APU_VNENC_CMD_CREATE_SHADER_MODULE == 32'd59 &&
          APU_VND_CMD_DISPATCH == 32'd110 &&
          APU_VEN_CMD_END == 32'd91);

    cases++;
    fill_alu(16'd128, mem, n);
    load_create_guest(mem, n, 64'hB2);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("create pub", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          !rec.dispatch && rec.cmd == APU_VNENC_CMD_CREATE_SHADER_MODULE &&
          rec.result == rec.handle && rec.used_idx == 16'd1 &&
          (nwrite - w0) == 3);
    hu = rec.handle;
    ack_cpl();
    ack_irq();
    load_instance_guest();
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd1));
    hi = rec.handle;
    check("create instance", cpl.status == APU_QBN_OK && rec.valid && rec.irq &&
          irq && rec.cmd == APU_VCI_CMD_INSTANCE && rec.result == hi &&
          rec.used_idx == 16'd2 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_enum_guest(hi);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd2));
    hp = rec.handle;
    check("enum phys", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VEP_CMD_ENUM && rec.result == hp &&
          rec.used_idx == 16'd3 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_feat_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd3));
    check("get feat", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VPF_CMD_FEAT && rec.result == APU_VPF_FRAGMENT_STORES &&
          rec.used_idx == 16'd4 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_props_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd4));
    check("get props", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VPP_CMD_PROPS &&
          rec.result == APU_VPP_MAX_BOUND_DESCRIPTOR_SETS &&
          rec.used_idx == 16'd5 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_mem_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd5));
    check("get mem", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VMP_CMD_MEM && rec.result == APU_VMP_TYPE_COUNT &&
          rec.used_idx == 16'd6 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_qfam_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd6));
    check("get qfam", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VQF_CMD_QFAM && rec.result == APU_VQF_FAMILY_COUNT &&
          rec.used_idx == 16'd7 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_device_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd7));
    hd = rec.handle;
    check("create device", cpl.status == APU_QBN_OK && rec.valid && rec.irq &&
          irq && rec.cmd == APU_VCD_CMD_DEVICE && rec.result == hd &&
          rec.used_idx == 16'd8 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_queue_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd8));
    hq = rec.handle;
    check("get queue", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VGQ_CMD_QUEUE && rec.result == hq &&
          rec.used_idx == 16'd9 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_vkmem_guest(hd, 32'hB1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd9));
    hm = rec.handle;
    check("alloc memory", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VAM_CMD_MEMORY && rec.result == rec.handle &&
          rec.handle != 32'hB1 && rec.used_idx == 16'd10 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_buffer_guest(hd, 32'hB3);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd10));
    hb = rec.handle;
    check("create buffer", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VXB_CMD_BUFFER && rec.result == rec.handle &&
          rec.handle != 32'hB3 && rec.used_idx == 16'd11 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bufreq_guest(hd, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd11));
    check("buffer req", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VBM_CMD_BUFREQ && rec.result == APU_VBM_SIZE &&
          rec.handle == hb && rec.used_idx == 16'd12 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bind_guest(hd, hb, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd12));
    check("bind buffer", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VBB_CMD_BIND && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd13 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_map_guest(hd, hm, 32'hC5);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd13));
    check("map memory", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VMM_CMD_MAP && rec.result == APU_SHM_BASE[31:0] &&
          rec.handle == hm && rec.used_idx == 16'd14 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_flush_guest(hd, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd14));
    check("flush map", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VFM_CMD_FLUSH && rec.result == 32'd0 &&
          rec.handle == hm && rec.used_idx == 16'd15 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_inval_guest(hd, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd15));
    check("invalidate map", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VIM_CMD_INVAL && rec.result == 32'd0 &&
          rec.handle == hm && rec.used_idx == 16'd16 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_unmap_guest(hd, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd16));
    check("unmap memory", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VUM_CMD_UNMAP && rec.result == 32'd0 &&
          rec.handle == hm && rec.used_idx == 16'd17 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_memc_guest(hd, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd17));
    check("memory commit", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VMC_CMD_MEMC && rec.result == APU_VMC_COMMITTED &&
          rec.handle == hm && rec.used_idx == 16'd18 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_image_guest(hd, 32'hB9);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd18));
    hj = rec.handle;
    check("create image", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VXI_CMD_IMAGE && rec.result == rec.handle &&
          rec.handle != 32'hB9 && rec.used_idx == 16'd19 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_imgreq_guest(hd, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd19));
    check("image req", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VMI_CMD_IMGREQ && rec.result == APU_VMI_SIZE &&
          rec.handle == hj && rec.used_idx == 16'd20 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bindimg_guest(hd, hj, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd20));
    check("bind image", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VBI_CMD_BINDIMG && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd21 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_view_guest(hd, hj, 32'hBA);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd21));
    hv = rec.handle;
    check("create view", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VXV_CMD_VIEW && rec.result == rec.handle &&
          rec.handle != 32'hBA && rec.used_idx == 16'd22 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dsl_guest(hd, 32'hB4);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd22));
    hl = rec.handle;
    check("desc layout", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VDL_CMD_DSLAYOUT && rec.result == rec.handle &&
          rec.handle != 32'hB4 && rec.used_idx == 16'd23 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_pool_guest(hd, 32'hB7);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd23));
    ho = rec.handle;
    check("desc pool", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VPO_CMD_POOL && rec.result == rec.handle &&
          rec.handle != 32'hB7 && rec.used_idx == 16'd24 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_sampler_guest(hd, 32'hBB);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd24));
    ha = rec.handle;
    check("create sampler", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VSM_CMD_SAMPLER && rec.result == rec.handle &&
          rec.handle != 32'hBB && rec.used_idx == 16'd25 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_pl_guest(hd, hl, 32'hB5);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd25));
    hk = rec.handle;
    check("pipe layout", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VPL_CMD_PLAYOUT && rec.result == rec.handle &&
          rec.handle != 32'hB5 && rec.used_idx == 16'd26 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rpass_guest(hd, 32'hBC);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd26));
    hr = rec.handle;
    check("create rpass", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VRP_CMD_RPASS && rec.result == rec.handle &&
          rec.handle != 32'hBC && rec.used_idx == 16'd27 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cp_guest(hd, 32'hB2, hk, 32'hB6);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd27));
    hg = rec.handle;
    check("compute pipe", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VCP_CMD_CPIPE && rec.result == rec.handle &&
          rec.handle != 32'hB6 && rec.used_idx == 16'd28 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_gpipe_guest(hd, 32'hB2, hk, hr, 32'hBD);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd28));
    hy = rec.handle;
    check("create gpipe", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VGP_CMD_GPIPE && rec.result == rec.handle &&
          rec.handle != 32'hBD && rec.used_idx == 16'd29 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_fbuf_guest(hd, hr, hv, 32'hBE);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd29));
    hf = rec.handle;
    check("create fbuf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VFB_CMD_FBUF && rec.result == rec.handle &&
          rec.handle != 32'hBE && rec.used_idx == 16'd30 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dset_guest(hd, hl, ho, 32'hB8);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd30));
    hs = rec.handle;
    check("descset", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VDA_CMD_DESCSET && rec.result == rec.handle &&
          rec.handle != 32'hB8 && rec.used_idx == 16'd31 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_update_guest(hd, hs, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd31));
    check("update desc", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VUD_CMD_UPDATE && rec.result == 32'd0 &&
          rec.handle == hs && rec.used_idx == 16'd32 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_alloc_guest(64'hC1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd32));
    hc = rec.handle;
    check("alloc pub", cpl.status == APU_QBN_OK && rec.valid && rec.alloc &&
          rec.irq && irq && rec.handle != 32'hC1 && rec.handle != 32'd0 &&
          rec.result == hc && rec.cmd == APU_VAC_CMD_ALLOC &&
          rec.used_idx == 16'd33 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dispatch_guest(hc);
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd33));
    check("dispatch before begin faults", cpl.status == APU_QBN_FAULT && !irq &&
          (nwrite - w0) == 0);
    ack_cpl();
    load_begin_guest(hc, 32'd1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd33));
    check("begin pub", cpl.status == APU_QBN_OK && rec.valid && rec.begin_cmd &&
          rec.irq && irq && rec.handle == hc && rec.result == 32'd0 &&
          rec.cmd == APU_VBG_CMD_BEGIN && rec.used_idx == 16'd34 &&
          (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dispatch_guest(hc);
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd34));
    check("dispatch before bind faults", cpl.status == APU_QBN_FAULT && !irq &&
          (nwrite - w0) == 0);
    ack_cpl();
    load_bindpipe_guest(hc, hg);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd34));
    check("bind pipe", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VBP_CMD_BINDPIPE && rec.result == 32'd0 &&
          rec.handle == hg && rec.used_idx == 16'd35 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_binddesc_guest(hc, hk, hs);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd35));
    check("bind desc", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VBD_CMD_BINDDESC && rec.result == 32'd0 &&
          rec.handle == hs && rec.used_idx == 16'd36 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bindvtx_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd36));
    check("bind vtx", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VVB_CMD_BINDVTX && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd37 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bindidx_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd37));
    check("bind idx", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VIB_CMD_BINDIDX && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd38 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_setvp_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd38));
    check("set vp", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VVP_CMD_SETVP && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd39 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_setsc_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd39));
    check("set sc", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VSI_CMD_SETSC && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd40 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_barrier_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd40));
    check("barrier", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VPB_CMD_BARRIER && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd41 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_slw_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd41));
    check("set lw", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SLW_CMD_SLW && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd42 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_sdb_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd42));
    check("set bias", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SDB_CMD_SDB && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd43 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_sbc_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd43));
    check("set blend", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SBC_CMD_SBC && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd44 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_sbb_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd44));
    check("set bounds", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SBB_CMD_SBB && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd45 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_scm_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd45));
    check("set scmp", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SCM_CMD_SCM && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd46 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_swm_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd46));
    check("set swm", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SWM_CMD_SWM && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd47 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_srf_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd47));
    check("set sref", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_SRF_CMD_SRF && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd48 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ccb_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd48));
    check("copy buf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CCB_CMD_CCB && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd49 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cci_guest(hc, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd49));
    check("copy img", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CCI_CMD_CCI && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd50 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_bli_guest(hc, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd50));
    check("blit img", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_BLI_CMD_BLI && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd51 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cbi_guest(hc, hb, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd51));
    check("copy b2i", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CBI_CMD_CBI && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd52 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cib_guest(hc, hj, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd52));
    check("copy i2b", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CIB_CMD_CIB && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd53 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ubf_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd53));
    check("update buf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_UBF_CMD_UBF && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd54 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_fil_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd54));
    check("fill buf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_FIL_CMD_FIL && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd55 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ccl_guest(hc, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd55));
    check("clear col", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CCL_CMD_CCL && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd56 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cds_guest(hc, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd56));
    check("clear ds", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CDS_CMD_CDS && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd57 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rsi_guest(hc, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd57));
    check("resolve img", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RSI_CMD_RSI && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd58 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_beginrp_guest(hc, hr, hf);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd58));
    check("begin rp", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VRB_CMD_BEGINRP && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd59 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_draw_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd59));
    check("draw", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VDW_CMD_DRAW && rec.result == APU_VDW_VERTS &&
          rec.handle == hc && rec.used_idx == 16'd60 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_drawidx_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd60));
    check("draw idx", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VDI_CMD_DRAWIDX && rec.result == APU_VDI_INDICES &&
          rec.handle == hc && rec.used_idx == 16'd61 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dri_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd61));
    check("draw indr", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DRI_CMD_DRI && rec.result == APU_DRI_COUNT &&
          rec.handle == hb && rec.used_idx == 16'd62 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ixi_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd62));
    check("draw iindr", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_IXI_CMD_IXI && rec.result == APU_IXI_COUNT &&
          rec.handle == hb && rec.used_idx == 16'd63 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_cat_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd63));
    check("clear att", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_CAT_CMD_CAT && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd64 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_endrp_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd64));
    check("end rp", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_VRE_CMD_ENDRP && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd65 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dispatch_guest(hc);
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd65));
    check("dispatch pub", cpl.status == APU_QBN_OK && rec.valid && rec.dispatch &&
          rec.irq && irq && rec.result == 32'd5 && rec.used_idx == 16'd66 &&
          rec.cmd == APU_VND_CMD_DISPATCH && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dsi_guest(hc, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd66));
    check("disp indr", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DSI_CMD_DSI && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd67 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();

    cases++;
    load_dispatch_guest(hc);
    in_a = 32'd4;
    in_b = 32'd5;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd67));
    check("second dispatch", cpl.status == APU_QBN_OK && rec.valid && irq &&
          rec.result == 32'd9 && rec.used_idx == 16'd68);
    ack_cpl();
    ack_irq();
    load_end_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd68));
    check("end pub", cpl.status == APU_QBN_OK && rec.valid && rec.end_cmd &&
          rec.irq && irq && rec.handle == hc && rec.result == 32'd0 &&
          rec.cmd == APU_VEN_CMD_END && rec.used_idx == 16'd69 &&
          (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_submit_guest(hq, hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd69));
    check("submit lookup", cpl.status == APU_QBN_OK && rec.valid && rec.submit &&
          rec.irq && irq && rec.handle == hc && rec.result == 32'd0 &&
          rec.cmd == APU_VQS_CMD_SUBMIT && rec.used_idx == 16'd70 &&
          (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_wait_guest(hq);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd70));
    check("wait idle", cpl.status == APU_QBN_OK && rec.valid && rec.wait_idle &&
          rec.irq && irq && rec.used_idx == 16'd71 && rec.cmd == APU_VWI_CMD_WAIT);
    ack_cpl();
    ack_irq();
    load_iex_guest;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd71));
    check("instance ext", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_IEX_CMD_IEX && rec.result == APU_IEX_COUNT &&
          rec.handle == 32'd0 && rec.used_idx == 16'd72 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dwi_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd72));
    check("device wait", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DWI_CMD_DWI && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd73 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_gfs_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd73));
    check("get fence", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_GFS_CMD_GFS && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd74 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_wfe_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd74));
    check("wait fence", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_WFE_CMD_WFE && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd75 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rfe_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd75));
    check("reset fence", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RFE_CMD_RFE && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd76 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dfe_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd76));
    check("dest fence", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DFE_CMD_DFE && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd77 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_isl_guest(hd, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd77));
    check("subresource layout", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_ISL_CMD_ISL && rec.result == APU_VMI_SIZE &&
          rec.handle == hj && rec.used_idx == 16'd78 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rag_guest(hd, hr);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd78));
    check("render gran", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RAG_CMD_RAG && rec.result == APU_RAG_GRAN &&
          rec.handle == hr && rec.used_idx == 16'd79 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dfb_guest(hd, hf);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd79));
    check("destroy fbuf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DFB_CMD_DFB && rec.result == 32'd0 &&
          rec.handle == hf && rec.used_idx == 16'd80 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dvw_guest(hd, hv);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd80));
    check("destroy view", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DVW_CMD_DVW && rec.result == 32'd0 &&
          rec.handle == hv && rec.used_idx == 16'd81 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dsm_guest(hd, ha);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd81));
    check("destroy sampler", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DSM_CMD_DSM && rec.result == 32'd0 &&
          rec.handle == ha && rec.used_idx == 16'd82 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_drp_guest(hd, hr);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd82));
    check("destroy rpass", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DRP_CMD_DRP && rec.result == 32'd0 &&
          rec.handle == hr && rec.used_idx == 16'd83 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dbf_guest(hd, hb);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd83));
    check("destroy buf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DBF_CMD_DBF && rec.result == 32'd0 &&
          rec.handle == hb && rec.used_idx == 16'd84 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dim_guest(hd, hj);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd84));
    check("destroy img", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DIM_CMD_DIM && rec.result == 32'd0 &&
          rec.handle == hj && rec.used_idx == 16'd85 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_fme_guest(hd, hm);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd85));
    check("free memory", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_FME_CMD_FME && rec.result == 32'd0 &&
          rec.handle == hm && rec.used_idx == 16'd86 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dmd_guest(hd, hu);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd86));
    check("destroy module", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DMD_CMD_DMD && rec.result == 32'd0 &&
          rec.handle == hu && rec.used_idx == 16'd87 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dpl_guest(hd, hy);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd87));
    check("destroy gpipe", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DPL_CMD_DPL && rec.result == 32'd0 &&
          rec.handle == hy && rec.used_idx == 16'd88 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dpl_guest(hd, hg);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd88));
    check("destroy cpipe", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DPL_CMD_DPL && rec.result == 32'd0 &&
          rec.handle == hg && rec.used_idx == 16'd89 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dyo_guest(hd, hk);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd89));
    check("destroy playout", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DYO_CMD_DYO && rec.result == 32'd0 &&
          rec.handle == hk && rec.used_idx == 16'd90 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dds_guest(hd, hl);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd90));
    check("destroy dsl", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DDS_CMD_DDS && rec.result == 32'd0 &&
          rec.handle == hl && rec.used_idx == 16'd91 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rdp_guest(hd, ho);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd91));
    check("reset desc pool", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RDP_CMD_RDP && rec.result == 32'd0 &&
          rec.handle == ho && rec.used_idx == 16'd92 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dpo_guest(hd, ho);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd92));
    check("destroy pool", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DPO_CMD_DPO && rec.result == 32'd0 &&
          rec.handle == ho && rec.used_idx == 16'd93 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_fds_guest(hd, ho, hs);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd93));
    check("free descset", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_FDS_CMD_FDS && rec.result == 32'd0 &&
          rec.handle == hs && rec.used_idx == 16'd94 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rcb_guest(hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd94));
    check("reset cmdbuf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RCB_CMD_RCB && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd95 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_fcb_guest(hd, 32'hA1, hc);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd95));
    check("free cmdbuf", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_FCB_CMD_FCB && rec.result == 32'd0 &&
          rec.handle == hc && rec.used_idx == 16'd96 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_rcp_guest(hd, 32'hA1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd96));
    check("reset cmd pool", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_RCP_CMD_RCP && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd97 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dcp_guest(hd, 32'hA1);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd97));
    check("destroy cmd pool", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DCP_CMD_DCP && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd98 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ddv_guest(hd);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd98));
    check("destroy device", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DDV_CMD_DDV && rec.result == 32'd0 &&
          rec.handle == hd && rec.used_idx == 16'd99 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_din_guest(hi);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd99));
    check("destroy instance", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DIN_CMD_DIN && rec.result == 32'd0 &&
          rec.handle == hi && rec.used_idx == 16'd100 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_gfp_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd100));
    check("format props", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_GFP_CMD_GFP && rec.result == APU_GFP_FEATURES &&
          rec.handle == hp && rec.used_idx == 16'd101 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_ifp_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd101));
    check("image format", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_IFP_CMD_IFP && rec.result == APU_IFP_MAX_EXTENT &&
          rec.handle == hp && rec.used_idx == 16'd102 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    load_dex_guest(hp);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd102));
    check("device ext", cpl.status == APU_QBN_OK && rec.valid && rec.irq && irq &&
          rec.cmd == APU_DEX_CMD_DEX && rec.result == APU_DEX_COUNT &&
          rec.handle == hp && rec.used_idx == 16'd103 && (nwrite - w0) == 3);
    ack_cpl();
    ack_irq();
    cases++;
    w0 = nwrite;
    fire(mk_walk(16'd1, 16'd103));
    check("empty", cpl.status == APU_QBN_EMPTY && !rec.valid &&
          (nwrite - w0) == 0);
    ack_cpl();

    cases++;
    do_reset;
    load_dispatch_guest(32'hB1);
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_walk(16'd0, 16'd0));
    check("dispatch before create faults", cpl.status == APU_QBN_FAULT && !irq);
    ack_cpl();

    cases++;
    do_reset;
    load_begin_guest(32'hC1, 32'd0);
    fire(mk_walk(16'd0, 16'd0));
    check("begin before alloc faults", cpl.status == APU_QBN_FAULT && !rec.valid);
    ack_cpl();

    cases++;
    do_reset;
    load_end_guest(32'hC1);
    fire(mk_walk(16'd0, 16'd0));
    check("end before alloc faults", cpl.status == APU_QBN_FAULT && !rec.valid);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU qbn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_qbn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
