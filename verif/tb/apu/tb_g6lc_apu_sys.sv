// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_sys_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  localparam logic [63:0] WindowBase = 64'h8000_0000;
  function automatic apu_cfg_t sys_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.MaxResources = enabled ? 8 : 0;
    cfg.MaxCmdBytes = enabled ? 256 : 0;
    cfg.DmaReadEn = enabled;
    cfg.DmaReadBurstBeats = 1;
    cfg.DmaWriteEn = enabled;
    cfg.SgEn = enabled;
    cfg.SgMaxEntries = 64;
    cfg.SgMaxTransferBytes = 65536;
    cfg.DmaReadMaxBytes = 65536;
    cfg.DmaWindowBase = WindowBase;
    cfg.DmaWindowBytes = 64'h1000_0000;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = WindowBase + 64'h1000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t sys_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_sys_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_axi_req_t guest_req_i, control_req_i,
  output apu_axi_resp_t guest_rsp_o, control_rsp_o,
  input logic control_aw_authorized_i, control_ar_authorized_i,
  output logic guest_irq_o, control_irq_o,
  output apu_vq_state_t vq_state_o [APU_NUM_QUEUES],
  output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  input logic backend_reset_done_i,
  input logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  input logic used_valid_i,
  input logic [31:0] used_qid_i, used_context_i, used_len_i,
  input logic [63:0] used_fence_i,
  output logic used_ready_o,
  input logic cfg_display_event_i,
  output logic bus_fault_o,
  output apu_dma_axi_req_t dma_req_o,
  input apu_dma_axi_resp_t dma_rsp_i
);
  g6lc_apu_sys #(
    .ApuCfg(g6lc_sys_test_pkg::sys_cfg(Enable)),
    .CoreCfg(g6lc_sys_test_pkg::sys_core())
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_sys;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_sys_test_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_axi_req_t [3:0] req;
  apu_axi_resp_t [3:0] rsp;
  logic aw_auth, ar_auth;
  logic guest_irq, control_irq, reset_req, bus_fault, used_valid, used_ready;
  logic [1:0] queue_enable, stop_req, backend_idle;
  logic backend_done;
  apu_vq_state_t vq [2];
  logic [31:0] used_qid, used_context, used_len;
  logic [63:0] used_fence;
  logic cfg_event;
  logic off_guest_irq, off_control_irq, off_reset, off_ready, off_fault;
  logic [1:0] off_enable, off_stop;
  apu_vq_state_t off_vq [2];
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  logic [7:0] memory [0:8191];
  logic r_active, rvalid, aw_seen, w_seen, bvalid, executed;
  logic [63:0] raddr;
  int rleft, rstep;
  apu_dma_axi_r_chan_t rch;
  apu_dma_axi_aw_chan_t waw;
  apu_dma_axi_w_chan_t ww;

  g6lc_apu_sys_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[0]), .guest_rsp_o(rsp[0]),
    .control_req_i(req[1]), .control_rsp_o(rsp[1]),
    .control_aw_authorized_i(aw_auth), .control_ar_authorized_i(ar_auth),
    .guest_irq_o(guest_irq), .control_irq_o(control_irq),
    .vq_state_o(vq), .queue_enable_o(queue_enable),
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .backend_reset_done_i(backend_done), .backend_idle_i(backend_idle),
    .used_valid_i(used_valid), .used_qid_i(used_qid), .used_context_i(used_context),
    .used_len_i(used_len), .used_fence_i(used_fence), .used_ready_o(used_ready),
    .cfg_display_event_i(cfg_event), .bus_fault_o(bus_fault),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_sys_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[2]), .guest_rsp_o(rsp[2]),
    .control_req_i(req[3]), .control_rsp_o(rsp[3]),
    .control_aw_authorized_i(aw_auth), .control_ar_authorized_i(ar_auth),
    .guest_irq_o(off_guest_irq), .control_irq_o(off_control_irq),
    .vq_state_o(off_vq), .queue_enable_o(off_enable),
    .backend_reset_req_o(off_reset), .backend_queue_stop_req_o(off_stop),
    .backend_reset_done_i(backend_done), .backend_idle_i(backend_idle),
    .used_valid_i(used_valid), .used_qid_i(used_qid), .used_context_i(used_context),
    .used_len_i(used_len), .used_fence_i(used_fence), .used_ready_o(off_ready),
    .cfg_display_event_i(cfg_event), .bus_fault_o(off_fault),
    .dma_req_o(off_dma), .dma_rsp_i(dma_rsp)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #20000000; $fatal(1, "sys timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_guest_irq, off_control_irq, off_reset, off_ready, off_enable,
         off_stop, off_fault, off_vq[0], off_vq[1], off_dma} !== '0)
      $fatal(1, "disabled APU sys active");
  end
  always_comb begin
    dma_rsp = '0;
    dma_rsp.ar_ready = !r_active && !rvalid && cycles % 4 != 0;
    dma_rsp.r_valid = rvalid;
    dma_rsp.r = rch;
    dma_rsp.aw_ready = !aw_seen && !bvalid;
    dma_rsp.w_ready = !w_seen && !bvalid && cycles % 3 != 0;
    dma_rsp.b_valid = bvalid;
    dma_rsp.b.id = 1;
  end
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_active <= 0; rvalid <= 0; raddr <= 0; rleft <= 0; rstep <= 0; rch <= '0;
      aw_seen <= 0; w_seen <= 0; bvalid <= 0; executed <= 0; waw <= '0; ww <= '0;
    end else begin
      if (dma_req.ar_valid && dma_rsp.ar_ready) begin
        r_active <= 1; raddr <= dma_req.ar.addr; rleft <= 32'(dma_req.ar.len) + 1;
        rstep <= 1 << dma_req.ar.size;
      end
      if (r_active && !rvalid && cycles % 3 != 0) begin
        rvalid <= 1;
        for (int b = 0; b < 8; b++)
          rch.data[8*b +: 8] <= memory[int'(((raddr & ~64'd7) + 64'(b)) - WindowBase)];
        rch.id <= 0; rch.last <= rleft == 1; rch.resp <= 2'b00;
      end
      if (rvalid && dma_req.r_ready) begin
        rvalid <= 0; raddr <= raddr + 64'(rstep); rleft <= rleft - 1;
        if (rch.last) r_active <= 0;
      end
      if (dma_req.aw_valid && dma_rsp.aw_ready) begin aw_seen <= 1; waw <= dma_req.aw; end
      if (dma_req.w_valid && dma_rsp.w_ready) begin w_seen <= 1; ww <= dma_req.w; end
      if (aw_seen && w_seen && !executed) begin
        executed <= 1;
        for (int b = 0; b < 8; b++) if (ww.strb[b])
          memory[int'((waw.addr & ~64'd7) + 64'(b) - WindowBase)] <= ww.data[8*b +: 8];
      end
      if (executed && !bvalid && cycles % 4 != 0) bvalid <= 1;
      if (bvalid && dma_req.b_ready) begin
        bvalid <= 0; aw_seen <= 0; w_seen <= 0; executed <= 0;
      end
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  function automatic logic [7:0] pattern(input logic [63:0] addr);
    return 8'(addr ^ (addr >> 8) ^ 64'h3c);
  endfunction
  task automatic send_write(input int p, input logic [63:0] a, input logic [31:0] d,
      input bit auth = 1, input logic [3:0] strb = 4'hf);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(negedge clk);
    aw_auth = auth;
    req[p].aw.addr = a; req[p].aw.prot = 3'b111;
    req[p].w.data = d; req[p].w.strb = strb;
    req[p].aw_valid = 1; req[p].w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (req[p].aw_valid && rsp[p].aw_ready) aw_done = 1;
      if (req[p].w_valid && rsp[p].w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) req[p].aw_valid = 0;
      if (w_done) req[p].w_valid = 0;
    end
  endtask
  task automatic receive_write(input int p, input logic [1:0] expected = 0);
    @(posedge clk);
    while (!rsp[p].b_valid) @(posedge clk);
    check("AXI B", rsp[p].b.resp == expected);
    @(negedge clk); req[p].b_ready = 1;
    @(posedge clk); @(negedge clk); req[p].b_ready = 0;
  endtask
  task automatic write_reg(input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [1:0] expected = 0, input bit auth = 1);
    send_write(p, a, d, auth);
    receive_write(p, expected);
  endtask
  task automatic send_read(input int p, input logic [63:0] a, input bit auth = 1);
    @(negedge clk);
    ar_auth = auth;
    req[p].ar.addr = a; req[p].ar.prot = 3'b111; req[p].ar_valid = 1;
    @(posedge clk);
    while (!rsp[p].ar_ready) @(posedge clk);
    @(negedge clk); req[p].ar_valid = 0;
  endtask
  task automatic receive_read(input int p, output logic [31:0] data,
      input logic [1:0] expected = 0);
    @(posedge clk);
    while (!rsp[p].r_valid) @(posedge clk);
    data = rsp[p].r.data;
    check("AXI R", rsp[p].r.resp == expected);
    @(negedge clk); req[p].r_ready = 1;
    @(posedge clk); @(negedge clk); req[p].r_ready = 0;
  endtask
  task automatic read_reg(input int p, input logic [63:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0, input bit auth = 1);
    send_read(p, a, auth);
    receive_read(p, data, expected);
  endtask
  task automatic ctrl_write(input logic [15:0] a, input logic [31:0] d,
      input logic [1:0] expected = 0);
    write_reg(1, APU_CONTROL_BASE + 64'(a), d, expected);
  endtask
  task automatic ctrl_read(input logic [15:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0);
    read_reg(1, APU_CONTROL_BASE + 64'(a), data, expected);
  endtask
  task automatic mail_word(input int unsigned idx, input logic [31:0] data);
    ctrl_write(ACTRL_MAIL_IDX, idx);
    ctrl_write(ACTRL_MAIL_DATA, data);
  endtask
  task automatic mail_go(input apu_mem_op_e op, input apu_dma_status_e st);
    logic [31:0] stat;
    int spins;
    cases++;
    ctrl_write(ACTRL_MAIL_GO, 32'(op));
    spins = 0;
    do begin
      ctrl_read(ACTRL_MAIL_STAT, stat);
      spins++;
      if (spins > 4000) $fatal(1, "mail busy timeout op=%0d", op);
    end while ((stat & ACTRL_MAIL_BUSY) != 0);
    check("mail status", stat[3:0] == 4'(st));
  endtask

  initial begin
    logic [31:0] r, lo, hi;
    integer i;
    for (int p = 0; p < 4; p++) req[p] = '0;
    aw_auth = 0; ar_auth = 0;
    backend_idle = 2'b11; backend_done = 1;
    used_valid = 0; used_qid = 0; used_context = 0; used_len = 0; used_fence = 0;
    cfg_event = 0;
    for (i = 0; i < 8192; i++) memory[i] = pattern(WindowBase + 64'(i));
    repeat (4) @(negedge clk);
    rst_ni = 1;

    read_reg(0, APU_MMIO_BASE, r);
    check("guest virtio magic", r == VIRTIO_MMIO_MAGIC);
    read_reg(1, APU_CONTROL_BASE, r, 2, 0);
    check("unauthorized control is empty", r == 0);
    read_reg(1, APU_CONTROL_BASE, r);
    check("control magic", r == APU_CONTROL_MAGIC);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_MAIL_IDX), 1, 2, 0);
    ctrl_read(ACTRL_MAIL_IDX, r);
    check("denied mailbox write is ignored", r == 0);
    write_reg(0, APU_CONTROL_BASE + 64'(ACTRL_MAIL_IDX), 1, 2);
    read_reg(2, APU_MMIO_BASE, r);
    check("disabled guest discovery", r == 0);
    read_reg(3, APU_CONTROL_BASE, r);
    check("disabled control discovery", r == 0);

    mail_word(0, 1);
    mail_word(1, 11);
    mail_word(2, 3);
    mail_word(3, 5);
    mail_word(4, 32'h7);
    mail_word(5, 32'(WindowBase + 64'h100));
    mail_word(6, 0);
    mail_word(7, 4096);
    mail_word(8, 0);
    mail_word(9, 1);
    mail_word(10, 0);
    mail_go(APU_MEM_MAP_INSERT, APU_DMA_OK);

    mail_word(1, 11);
    mail_word(2, 3);
    mail_word(3, 5);
    mail_word(4, 32'h8);
    mail_word(9, 2);
    mail_word(10, 0);
    mail_go(APU_MEM_MAP_LOOKUP, APU_DMA_OK);
    ctrl_write(ACTRL_MAIL_IDX, 5);
    ctrl_read(ACTRL_MAIL_DATA, lo);
    ctrl_write(ACTRL_MAIL_IDX, 6);
    ctrl_read(ACTRL_MAIL_DATA, hi);
    check("lookup base", {hi, lo} == WindowBase + 64'h100);

    mail_word(0, 32'h40);
    mail_word(1, 7);
    mail_word(2, 9);
    mail_word(3, 5);
    mail_word(4, 32'h7);
    mail_word(5, 32'(WindowBase));
    mail_word(6, 0);
    mail_word(7, 32'h1000);
    mail_word(8, 0);
    mail_word(9, 4);
    mail_word(10, 0);
    mail_word(11, 32'h40);
    mail_word(12, 0);
    mail_word(14, 32'h21);
    mail_word(15, 32'h10);
    mail_word(16, 0);
    mail_word(17, 32'h55);
    mail_word(18, 0);
    mail_go(APU_MEM_USED, APU_DMA_OK);
    check("used id", {memory[71], memory[70], memory[69], memory[68]} == 32'h21);

    mail_word(1, 11);
    mail_word(2, 3);
    mail_word(3, 5);
    mail_word(4, 32'h7);
    mail_word(5, 32'(WindowBase + 64'h200));
    mail_word(6, 0);
    mail_word(7, 64);
    mail_word(8, 0);
    mail_word(9, 7);
    mail_word(10, 0);
    mail_word(11, 0);
    mail_word(12, 0);
    mail_word(13, 16);
    mail_go(APU_MEM_CMD_DMA, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_STAT, r);
    check("cmd held", (r & ACTRL_MAIL_HELD) != 0);
    mail_go(APU_MEM_CMD_RELEASE, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_STAT, r);
    check("released", (r & ACTRL_MAIL_HELD) == 0);

    if (errors != 0) $fatal(1, "APU sys errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_sys cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
