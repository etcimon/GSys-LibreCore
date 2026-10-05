// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Private Venus num_capsets=1 and QueueNotify into QueueTypeAlloc. NumCapsets stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_vca;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_vca_req_t req;
  apu_vca_cpl_t cpl;
  apu_vca_t rec;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic [63:0] wr_a [0:15];
  logic [31:0] wr_l [0:15], wr_d0 [0:15], wr_d6 [0:15];
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_vca_cpl_t off_cpl;
  apu_vca_t off_rec;
  logic [31:0] guest_w [0:191];
  logic [31:0] pay_bytes, write_len, req_type, req_arg, req_ver;
  logic capset_mem;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] UsedA  = 64'h0000_0000_0000_0600;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A800;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_vca #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vca_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_vca_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vca_o(off_rec),
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
  initial begin #2000000; $fatal(1, "vca timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0 || off_isr !== '0)
      $fatal(1, "disabled vca active");
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

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] pack_cmd;
    pack_cmd = '0;
    pack_cmd[31:0]    = req_type;
    pack_cmd[63:32]   = 32'd1;
    pack_cmd[95:64]   = 32'h5566_7788;
    pack_cmd[127:96]  = 32'h1122_3344;
    pack_cmd[159:128] = 32'd0;
    pack_cmd[191:160] = 32'd0;
    pack_cmd[223:192] = req_arg;
    pack_cmd[255:224] = req_ver;
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
      lookup = pack_desc(Pay1, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (capset_mem && addr == Pay0)
      lookup = pack_cmd();
    else if (!capset_mem && addr >= Pay0 && addr < Pay0 + 64'd768) begin
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
        if (nwrite < 16) begin
          wr_a[nwrite] <= wr_addr;
          wr_l[nwrite] <= wr_len;
          wr_d0[nwrite] <= wr_data[31:0];
          wr_d6[nwrite] <= wr_data[223:192];
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

  task automatic fire(input apu_vca_req_t r);
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
    in_a = '0; in_b = '0; ack_w = '0;
    pay_bytes = 32'd32; write_len = 32'd4; capset_mem = 1'b0;
    req_type = '0; req_arg = '0; req_ver = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_vca_req_t mk_walk(input logic [15:0] didx,
                                           input logic [15:0] uidx);
    mk_walk = '0;
    mk_walk.op = APU_VCA_NOTIFY;
    mk_walk.queue_sel = 32'd0;
    mk_walk.qta.qal.gnh_only = 1'b0;
    mk_walk.qta.qal.avu.avail_base = Avail1;
    mk_walk.qta.qal.avu.desc_base = BaseA;
    mk_walk.qta.qal.avu.used_base = UsedA;
    mk_walk.qta.qal.avu.queue_size = 8'd4;
    mk_walk.qta.qal.avu.device_idx = didx;
    mk_walk.qta.qal.avu.used_idx = uidx;
    mk_walk.qta.qal.avu.max_chain = 4'd8;
  endfunction

  function automatic apu_vca_req_t mk_cfg(input logic [15:0] addr);
    mk_cfg = '0;
    mk_cfg.op = APU_VCA_CFG;
    mk_cfg.cfg_addr = addr;
  endfunction

  function automatic apu_vca_req_t mk_info(input logic [31:0] idx);
    mk_info = '0;
    mk_info.op = APU_VCA_INFO;
    mk_info.capset_index = idx;
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
    write_len = 32'd4;
    capset_mem = 1'b0;
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
    write_len = 32'd4;
    capset_mem = 1'b0;
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
    write_len = 32'd4;
    capset_mem = 1'b0;
  endtask

  task automatic load_capset(input logic [31:0] typ, input logic [31:0] arg,
                             input logic [31:0] wlen);
    req_type = typ;
    req_arg = arg;
    req_ver = 32'd0;
    pay_bytes = 32'(APU_CMS_BYTES);
    write_len = wlen;
    capset_mem = 1'b1;
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    logic [31:0] hc;
    int unsigned n, w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vca off",
          !ApuOff.VcaEn && !ApuP1Transport.VcaEn && !ApuHarness.VcaEn);
    cfg = ApuP1Transport;
    cfg.VcaEn = 1'b1;
    check("vca does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VcaEn = 1'b1;
    check("vca does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    fire(mk_cfg(VCFG_NUM_CAPSETS));
    check("cfg num capsets", cpl.status == APU_VCA_OK && rec.valid &&
          rec.cfg_rdata == 32'(APU_VCA_NUM_CAPSETS) && rec.num_capsets == 32'd1 &&
          rec.capset_id == APU_VGPU_CAPSET_VENUS && !irq);
    ack_cpl();
    fire(mk_cfg(VCFG_NUM_SCANOUTS));
    check("cfg scanouts", cpl.status == APU_VCA_OK && rec.valid &&
          rec.cfg_rdata == 32'd0 && rec.num_capsets == 32'd1);
    ack_cpl();
    fire(mk_cfg(16'h110));
    check("cfg unknown faults", cpl.status == APU_VCA_FAULT && !rec.valid);
    ack_cpl();

    cases++;
    fire(mk_info(32'd0));
    check("info0 venus", cpl.status == APU_VCA_OK && rec.valid && rec.info &&
          rec.capset_id == APU_VGPU_CAPSET_VENUS && rec.max_version == 32'd1 &&
          rec.max_size == 32'(APU_VCAP_BYTES) && rec.num_capsets == 32'd1);
    ack_cpl();
    fire(mk_info(32'd1));
    check("info1 faults", cpl.status == APU_VCA_FAULT && !rec.valid);
    ack_cpl();

    cases++;
    load_capset(VGPU_CMD_GET_CAPSET_INFO, 32'd0, 32'(APU_GCS_INFO_BYTES));
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("info ok", cpl.status == APU_VCA_OK && rec.valid && rec.capset &&
          rec.info && rec.irq && irq && rec.used_idx == 16'd1 &&
          rec.resp_addr == Pay1 && rec.capset_id == APU_VGPU_CAPSET_VENUS &&
          rec.resp_word0 == VGPU_RESP_OK_CAPSET_INFO &&
          rec.type_word == VGPU_CMD_GET_CAPSET_INFO);
    check("info order", (nwrite - w0) == 4 && wr_a[0] == Pay1 &&
          wr_l[0] == 32'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[0] == VGPU_RESP_OK_CAPSET_INFO &&
          wr_d6[0] == APU_VGPU_CAPSET_VENUS &&
          wr_a[1] == Pay1 + 64'(APU_VGPU_BEAT_BYTES) && wr_l[1] == 32'd8 &&
          wr_d0[1] == 32'(APU_VCAP_BYTES) &&
          wr_a[2] == UsedA + 64'd4 && wr_l[2] == 32'd8 &&
          wr_a[3] == UsedA && wr_l[3] == 32'd4);
    ack_cpl();
    ack_irq();
    check("info ack lowers", !irq && isr == 32'd0);

    cases++;
    do_reset;
    fill_alu(16'd128, mem, n);
    load_create_guest(mem, n, 64'hB2);
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("create quiet", cpl.status == APU_VCA_OK && rec.valid && !rec.capset &&
          !rec.dispatch && !irq && rec.cmd == APU_VNENC_CMD_CREATE_SHADER_MODULE &&
          rec.type_word == APU_VNENC_CMD_CREATE_SHADER_MODULE &&
          (nwrite - w0) == 0);
    ack_cpl();
    load_alloc_guest(64'hC1);
    fire(mk_walk(16'd0, 16'd0));
    hc = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_VCA_OK && rec.valid && rec.alloc &&
          rec.handle != 32'hC1 && rec.cmd == APU_VAC_CMD_ALLOC);
    ack_cpl();
    load_dispatch_guest(hc);
    in_a = 32'd2;
    in_b = 32'd3;
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("dispatch pub", cpl.status == APU_VCA_OK && rec.valid && rec.dispatch &&
          rec.irq && irq && rec.result == 32'd5 && rec.used_idx == 16'd1 &&
          rec.cmd == APU_VND_CMD_DISPATCH);
    check("order", (nwrite - w0) == 3 && wr_a[0] == Pay1 && wr_l[0] == 32'd4 &&
          wr_d0[0] == 32'd5 && wr_a[1] == UsedA + 64'd4 && wr_a[2] == UsedA);
    ack_cpl();
    ack_irq();

    cases++;
    do_reset;
    load_capset(VGPU_CMD_GET_CAPSET, APU_VGPU_CAPSET_VENUS, 32'(APU_GCS_GET_BYTES));
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("get ok", cpl.status == APU_VCA_OK && rec.valid && rec.capset &&
          !rec.info && rec.irq && irq && rec.used_idx == 16'd1 &&
          rec.resp_addr == Pay1 && rec.capset_id == APU_VGPU_CAPSET_VENUS &&
          rec.resp_word0 == VGPU_RESP_OK_CAPSET &&
          rec.type_word == VGPU_CMD_GET_CAPSET);
    check("get blob", (nwrite - w0) == 8 && wr_a[0] == Pay1 &&
          wr_l[0] == 32'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[0] == VGPU_RESP_OK_CAPSET &&
          wr_d6[0] == APU_VCAP_WIRE_FMT &&
          wr_a[1] == Pay1 + 64'(APU_VGPU_BEAT_BYTES) &&
          wr_d0[1] == APU_VCAP_CMD_SER &&
          wr_a[5] == Pay1 + 64'd160 && wr_l[5] == 32'd24 &&
          wr_a[6] == UsedA + 64'd4 && wr_a[7] == UsedA);
    ack_cpl();
    ack_irq();

    cases++;
    do_reset;
    load_capset(VGPU_CMD_GET_CAPSET, APU_VGPU_CAPSET_VIRGL, 32'(APU_GCS_GET_BYTES));
    w0 = nwrite;
    fire(mk_walk(16'd0, 16'd0));
    check("virgl faults", cpl.status == APU_VCA_FAULT && !rec.valid &&
          !irq && (nwrite - w0) == 0);
    ack_cpl();

    cases++;
    do_reset;
    w0 = nwrite;
    begin
      apu_vca_req_t n1;
      n1 = mk_walk(16'd0, 16'd0);
      n1.queue_sel = 32'd1;
      fire(n1);
    end
    check("cursor faults", cpl.status == APU_VCA_FAULT && !rec.valid &&
          (nwrite - w0) == 0);
    ack_cpl();

    cases++;
    do_reset;
    w0 = nwrite;
    fire(mk_walk(16'd1, 16'd1));
    check("empty", cpl.status == APU_VCA_EMPTY && !rec.valid &&
          (nwrite - w0) == 0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU vca errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vca cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
