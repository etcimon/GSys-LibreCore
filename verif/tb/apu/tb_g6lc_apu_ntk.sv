// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// virtio notify_pending[0] consumes QueuePump. NumCapsets stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_ntk;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_ntk_req_t req;
  apu_ntk_cpl_t cpl;
  apu_ntk_t rec;
  logic [APU_NUM_QUEUES-1:0] pend = '0, nclr;
  logic set0, set1, seen_clr0, seen_clr1;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, wr_addr;
  logic [31:0] rd_len, rsp_len = 0, wr_len;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] rsp_data = 0, wr_data;
  logic [63:0] wr_a [0:15];
  logic [31:0] wr_l [0:15], wr_d0 [0:15], wr_d6 [0:15];
  logic off_rdy, off_v, off_rd, off_wr, off_irq, off_rr, off_wr_r;
  logic [31:0] off_isr;
  apu_ntk_cpl_t off_cpl;
  apu_ntk_t off_rec;
  logic [31:0] pay_bytes, write_len, req_type, req_arg, req_ver;
  logic capset_mem;
  logic [15:0] avail_idx, ring1;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0;

  localparam logic [63:0] Avail1 = 64'h0000_0000_0000_0200;
  localparam logic [63:0] BaseA  = 64'h0000_0000_0000_1000;
  localparam logic [63:0] UsedA  = 64'h0000_0000_0000_0600;
  localparam logic [63:0] Pay0   = 64'h0000_0000_8800_B000;
  localparam logic [63:0] Pay0b  = 64'h0000_0000_8800_B200;
  localparam logic [63:0] Pay1   = 64'h0000_0000_8800_A800;
  localparam logic [63:0] Pay1b  = 64'h0000_0000_8800_AC00;

  assign rd_rdy = rd_v && rst_ni && !rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;

  g6lc_apu_ntk #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .notify_pending_i(pend), .notify_clear_o(nclr),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .ntk_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_ok)
  );
  g6lc_apu_ntk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .notify_pending_i(pend), .notify_clear_o(),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .ntk_o(off_rec),
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
  initial begin #2000000; $fatal(1, "ntk timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rd !== 1'b0 || off_wr !== 1'b0 ||
        off_irq !== 1'b0 || off_isr !== '0)
      $fatal(1, "disabled ntk active");
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
    lookup = '0;
    if (addr == Avail1)
      lookup = pack_word({avail_idx, 16'h0});
    else if (addr == Avail1 + 64'd4)
      lookup = pack_word({ring1, 16'h0});
    else if (addr == BaseA)
      lookup = pack_desc(Pay0, pay_bytes, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup = pack_desc(Pay1, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseA + 64'd32)
      lookup = pack_desc(Pay0b, pay_bytes, VIRTQ_DESC_F_NEXT, 16'd3);
    else if (addr == BaseA + 64'd48)
      lookup = pack_desc(Pay1b, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (capset_mem && (addr == Pay0 || addr == Pay0b))
      lookup = pack_cmd();
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      pend <= '0;
      seen_clr0 <= 1'b0;
      seen_clr1 <= 1'b0;
      rsp_v <= 1'b0;
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
    end else begin
      if (set0) pend[0] <= 1'b1;
      else if (nclr[0]) begin
        pend[0] <= 1'b0;
        seen_clr0 <= 1'b1;
      end
      if (set1) pend[1] <= 1'b1;
      else if (nclr[1]) begin
        pend[1] <= 1'b0;
        seen_clr1 <= 1'b1;
      end
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

  task automatic fire(input apu_ntk_req_t r);
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
    set0 = 1'b0; set1 = 1'b0;
    pay_bytes = 32'd32; write_len = 32'd4; capset_mem = 1'b0;
    req_type = '0; req_arg = '0; req_ver = '0;
    avail_idx = 16'd1; ring1 = 16'd0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_ntk_req_t mk_walk(input logic [15:0] didx,
                                           input logic [15:0] uidx);
    mk_walk = '0;
    mk_walk.qpu.vct.op = APU_VCT_NOTIFY;
    mk_walk.qpu.vct.qty.qrn.avu.avail_base = Avail1;
    mk_walk.qpu.vct.qty.qrn.avu.desc_base = BaseA;
    mk_walk.qpu.vct.qty.qrn.avu.used_base = UsedA;
    mk_walk.qpu.vct.qty.qrn.avu.queue_size = 8'd4;
    mk_walk.qpu.vct.qty.qrn.avu.device_idx = didx;
    mk_walk.qpu.vct.qty.qrn.avu.used_idx = uidx;
    mk_walk.qpu.vct.qty.qrn.avu.max_chain = 4'd8;
  endfunction

  function automatic apu_ntk_req_t mk_cfg(input logic [15:0] addr);
    mk_cfg = '0;
    mk_cfg.qpu.vct.op = APU_VCT_CFG;
    mk_cfg.qpu.vct.cfg_addr = addr;
  endfunction

  function automatic apu_ntk_req_t mk_bind();
    mk_bind = mk_walk(16'd0, 16'd0);
    mk_bind.arm = 1'b1;
  endfunction

  task automatic load_capset(input logic [31:0] typ, input logic [31:0] arg,
                             input logic [31:0] wlen);
    req_type = typ;
    req_arg = arg;
    req_ver = 32'd0;
    pay_bytes = 32'(APU_CMS_BYTES);
    write_len = wlen;
    capset_mem = 1'b1;
  endtask

  task automatic ring0;
    @(negedge clk);
    set0 = 1'b1;
    @(posedge clk);
    @(negedge clk);
    set0 = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    int unsigned w0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_irq == 1'b0 && req_rdy == 1'b1);
    check("profiles keep ntk off",
          !ApuOff.NtkEn && !ApuP1Transport.NtkEn && !ApuHarness.NtkEn);
    cfg = ApuP1Transport;
    cfg.NtkEn = 1'b1;
    check("ntk does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.NtkEn = 1'b1;
    check("ntk does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    ring0();
    check("pending before bind faults", cpl.status == APU_NTK_FAULT &&
          pend[0] == 1'b0);
    ack_cpl();

    cases++;
    fire(mk_bind());
    check("bind", cpl.status == APU_NTK_OK && rec.valid && rec.bound);
    ack_cpl();
    fire(mk_cfg(VCFG_NUM_CAPSETS));
    check("cfg num capsets", cpl.status == APU_NTK_OK && rec.valid &&
          rec.cfg_rdata == 32'(APU_VCT_NUM_CAPSETS) && rec.bound);
    ack_cpl();

    cases++;
    avail_idx = 16'd2;
    ring1 = 16'd2;
    load_capset(VGPU_CMD_GET_CAPSET_INFO, 32'd0, 32'(APU_GCS_INFO_BYTES));
    w0 = nwrite;
    ring0();
    check("doorbell drain", cpl.status == APU_NTK_OK && rec.valid && rec.capset &&
          rec.info && rec.irq && irq && rec.count == 8'd2 && rec.bound &&
          rec.clear[0] && pend[0] == 1'b0 && rec.used_idx == 16'd2 &&
          rec.resp_addr == Pay1b);
    check("doorbell writes", (nwrite - w0) == 8 && wr_a[0] == Pay1 &&
          wr_a[4] == Pay1b && wr_a[7] == UsedA);
    ack_cpl();
    ack_irq();

    cases++;
    seen_clr1 = 1'b0;
    @(negedge clk);
    set1 = 1'b1;
    @(posedge clk);
    @(negedge clk);
    set1 = 1'b0;
    while (!cpl_v) @(negedge clk);
    check("cursor pending faults", cpl.status == APU_NTK_FAULT && rec.bound &&
          pend[1] == 1'b0);
    ack_cpl();

    cases++;
    avail_idx = 16'd2;
    ring1 = 16'd2;
    w0 = nwrite;
    ring0();
    check("empty after drain", cpl.status == APU_NTK_EMPTY && rec.bound &&
          rec.count == 8'd0 && (nwrite - w0) == 0 && pend[0] == 1'b0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU ntk errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_ntk cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
