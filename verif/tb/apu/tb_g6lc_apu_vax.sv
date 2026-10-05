// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// VqTake guest beats on 64-bit AXI. NumCapsets stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_vax;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq, ack_v = 0;
  logic [31:0] in_a = 0, in_b = 0, isr, ack_w = 0;
  apu_vax_req_t req;
  apu_vax_cpl_t cpl;
  apu_vax_t rec;
  apu_vq_state_t vq0, vq1;
  logic [APU_NUM_QUEUES-1:0] pend = '0, nclr;
  logic set0, set1;
  apu_dma_axi_req_t axi_req, off_axi;
  apu_dma_axi_resp_t axi_rsp, off_rsp;
  logic r_busy, r_valid, w_busy, b_valid, aw_got;
  logic [63:0] r_addr, w_addr, wr_a [0:15];
  logic [7:0] r_left, w_left;
  logic [2:0] r_size, w_size;
  logic [31:0] wr_d0 [0:15];
  logic off_rdy, off_v, off_irq;
  logic [31:0] off_isr;
  apu_vax_cpl_t off_cpl;
  apu_vax_t off_rec;
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

  g6lc_apu_vax #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .vq0_i(vq0), .vq1_i(vq1),
    .notify_pending_i(pend), .notify_clear_o(nclr),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vax_o(rec),
    .irq_o(irq), .isr_o(isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .axi_req_o(axi_req), .axi_rsp_i(axi_rsp)
  );
  g6lc_apu_vax_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .vq0_i(vq0), .vq1_i(vq1),
    .notify_pending_i(pend), .notify_clear_o(),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vax_o(off_rec),
    .irq_o(off_irq), .isr_o(off_isr), .ack_valid_i(ack_v), .ack_i(ack_w),
    .axi_req_o(off_axi), .axi_rsp_i(axi_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "vax timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_irq !== 1'b0 ||
        off_isr !== '0 || off_axi !== '0)
      $fatal(1, "disabled vax active");
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

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] lookup32(input logic [63:0] addr);
    lookup32 = '0;
    if (addr == Avail1)
      lookup32 = pack_word({avail_idx, 16'h0});
    else if (addr == Avail1 + 64'd4)
      lookup32 = pack_word({ring1, 16'h0});
    else if (addr == BaseA)
      lookup32 = pack_desc(Pay0, pay_bytes, VIRTQ_DESC_F_NEXT, 16'd1);
    else if (addr == BaseA + 64'd16)
      lookup32 = pack_desc(Pay1, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (addr == BaseA + 64'd32)
      lookup32 = pack_desc(Pay0b, pay_bytes, VIRTQ_DESC_F_NEXT, 16'd3);
    else if (addr == BaseA + 64'd48)
      lookup32 = pack_desc(Pay1b, write_len, VIRTQ_DESC_F_WRITE, 16'd0);
    else if (capset_mem && (addr == Pay0 || addr == Pay0b))
      lookup32 = pack_cmd();
  endfunction

  function automatic logic [31:0] mem32(input logic [63:0] addr);
    logic [APU_VGPU_BEAT_BYTES*8-1:0] b;
    logic [63:0] a4, a16, a32;
    a4 = {addr[63:2], 2'b0};
    a16 = {addr[63:4], 4'b0};
    a32 = {addr[63:5], 5'b0};
    b = lookup32(a4);
    if (b != '0) mem32 = b[31:0];
    else begin
      b = lookup32(a16);
      if (b != '0) mem32 = b[{a4[3:0], 3'b0} +: 32];
      else begin
        b = lookup32(a32);
        mem32 = b[{a4[4:0], 3'b0} +: 32];
      end
    end
  endfunction

  function automatic logic [63:0] axi_rdata(input logic [63:0] addr);
    logic [63:0] a8;
    a8 = {addr[63:3], 3'b0};
    axi_rdata = {mem32(a8 + 64'd4), mem32(a8)};
  endfunction

  always_comb begin
    axi_rsp = '0;
    axi_rsp.ar_ready = rst_ni && !r_busy && !r_valid;
    axi_rsp.r_valid = r_valid;
    axi_rsp.r.last = r_valid && (r_left == 8'd1);
    axi_rsp.r.resp = axi_pkg::RESP_OKAY;
    axi_rsp.r.data = axi_rdata(r_addr);
    axi_rsp.aw_ready = rst_ni && !w_busy && !aw_got;
    axi_rsp.w_ready = aw_got && w_busy;
    axi_rsp.b_valid = b_valid;
    axi_rsp.b.resp = axi_pkg::RESP_OKAY;
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      pend <= '0;
      r_busy <= 1'b0;
      r_valid <= 1'b0;
      w_busy <= 1'b0;
      b_valid <= 1'b0;
      aw_got <= 1'b0;
      r_left <= '0;
      w_left <= '0;
      r_addr <= '0;
      w_addr <= '0;
      nwrite <= 0;
    end else begin
      if (set0) pend[0] <= 1'b1;
      else if (nclr[0]) pend[0] <= 1'b0;
      if (set1) pend[1] <= 1'b1;
      else if (nclr[1]) pend[1] <= 1'b0;
      if (axi_req.ar_valid && axi_rsp.ar_ready) begin
        r_busy <= 1'b1;
        r_addr <= axi_req.ar.addr;
        r_size <= axi_req.ar.size;
        r_left <= axi_req.ar.len + 8'd1;
      end
      if (r_busy && !r_valid) r_valid <= 1'b1;
      if (r_valid && axi_req.r_ready) begin
        r_valid <= 1'b0;
        r_left <= r_left - 8'd1;
        r_addr <= r_addr + (64'd1 << r_size);
        if (r_left == 8'd1) r_busy <= 1'b0;
      end
      if (axi_req.aw_valid && axi_rsp.aw_ready) begin
        aw_got <= 1'b1;
        w_busy <= 1'b1;
        w_addr <= axi_req.aw.addr;
        w_size <= axi_req.aw.size;
        w_left <= axi_req.aw.len + 8'd1;
      end
      if (aw_got && axi_req.w_valid && axi_rsp.w_ready) begin
        if (nwrite < 16) begin
          wr_a[nwrite] <= w_addr;
          wr_d0[nwrite] <= w_addr[2] ? axi_req.w.data[63:32] : axi_req.w.data[31:0];
        end
        nwrite <= nwrite + 1;
        w_addr <= w_addr + (64'd1 << w_size);
        w_left <= w_left - 8'd1;
        if (axi_req.w.last || w_left == 8'd1) begin
          w_busy <= 1'b0;
          aw_got <= 1'b0;
          b_valid <= 1'b1;
        end
      end
      if (b_valid && axi_req.b_ready) b_valid <= 1'b0;
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d nw=%0d st=%0d cnt=%0d",
               name, cases, cycles, nwrite, cpl.status, rec.count);
    end
  endtask

  task automatic fire(input apu_vax_req_t r);
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
    vq0 = '0; vq1 = '0;
    pay_bytes = 32'd32; write_len = 32'd4; capset_mem = 1'b0;
    req_type = '0; req_arg = '0; req_ver = '0;
    avail_idx = 16'd1; ring1 = 16'd0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic load_vq;
    vq0.desc = BaseA;
    vq0.avail = Avail1;
    vq0.used = UsedA;
    vq0.num = 16'd4;
    vq0.ready = 1'b1;
    vq1 = '0;
  endtask

  function automatic apu_vax_req_t mk_cfg(input logic [15:0] addr);
    mk_cfg = '0;
    mk_cfg.vqt.ntk.qpu.vct.op = APU_VCT_CFG;
    mk_cfg.vqt.ntk.qpu.vct.cfg_addr = addr;
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
    check("profiles keep vax off",
          !ApuOff.VaxEn && !ApuP1Transport.VaxEn && !ApuHarness.VaxEn);
    cfg = ApuP1Transport;
    cfg.VaxEn = 1'b1;
    check("vax does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VaxEn = 1'b1;
    check("vax does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    ring0();
    check("pending before ready faults", cpl.status == APU_VAX_FAULT &&
          pend[0] == 1'b0);
    ack_cpl();

    cases++;
    load_vq();
    fire(mk_cfg(VCFG_NUM_CAPSETS));
    check("cfg num capsets", cpl.status == APU_VAX_OK && rec.valid &&
          rec.cfg_rdata == 32'(APU_VCT_NUM_CAPSETS));
    ack_cpl();

    cases++;
    avail_idx = 16'd2;
    ring1 = 16'd2;
    load_capset(VGPU_CMD_GET_CAPSET_INFO, 32'd0, 32'(APU_GCS_INFO_BYTES));
    w0 = nwrite;
    ring0();
    check("axi doorbell drain", cpl.status == APU_VAX_OK && rec.valid && rec.capset &&
          rec.info && rec.irq && irq && rec.count == 8'd2 && rec.bound &&
          pend[0] == 1'b0 && rec.used_idx == 16'd2 && rec.resp_addr == Pay1b);
    check("axi doorbell writes", (nwrite - w0) != 0 && wr_a[0] == Pay1);
    ack_cpl();
    ack_irq();

    cases++;
    @(negedge clk);
    set1 = 1'b1;
    @(posedge clk);
    @(negedge clk);
    set1 = 1'b0;
    while (!cpl_v) @(negedge clk);
    check("cursor pending faults", cpl.status == APU_VAX_FAULT && rec.bound &&
          pend[1] == 1'b0);
    ack_cpl();

    cases++;
    avail_idx = 16'd2;
    ring1 = 16'd2;
    w0 = nwrite;
    ring0();
    check("empty after drain", cpl.status == APU_VAX_EMPTY && rec.bound &&
          rec.count == 8'd0 && (nwrite - w0) == 0 && pend[0] == 1'b0);
    ack_cpl();

    if (errors != 0) $fatal(1, "APU vax errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vax cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
