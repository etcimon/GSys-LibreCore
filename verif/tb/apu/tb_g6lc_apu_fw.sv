// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_fw_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t fw_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.ExecEn = enabled;
    cfg.ExecQuadThreads = 4;
    cfg.ExecRegs = 8;
    cfg.ExecMemWords = 64;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t fw_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_fw_fixture
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
  g6lc_apu_fw #(
    .ApuCfg(g6lc_fw_test_pkg::fw_cfg(Enable)),
    .CoreCfg(g6lc_fw_test_pkg::fw_core())
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_fw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_fw_test_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_axi_req_t [3:0] req;
  apu_axi_resp_t [3:0] rsp;
  logic aw_auth, ar_auth;
  logic guest_irq, control_irq, reset_req, bus_fault, used_valid, used_ready;
  logic [1:0] queue_enable, stop_req, backend_idle;
  logic backend_done, cfg_event;
  apu_vq_state_t vq [2];
  logic [31:0] used_qid, used_context, used_len;
  logic [63:0] used_fence;
  logic off_guest_irq, off_control_irq, off_reset, off_ready, off_fault;
  logic [1:0] off_enable, off_stop;
  apu_vq_state_t off_vq [2];
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_fw_fixture i_on (
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
  g6lc_apu_fw_fixture #(.Enable(0)) i_off (
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
  initial begin #2000000; $fatal(1, "fw timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_guest_irq, off_control_irq, off_reset, off_ready, off_enable,
         off_stop, off_fault, off_vq[0], off_vq[1], off_dma} !== '0)
      $fatal(1, "disabled APU fw active");
  end
  assign dma_rsp = '0;

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic send_write(input int p, input logic [63:0] a, input logic [31:0] d,
      input bit auth = 1);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
    @(negedge clk);
    aw_auth = auth;
    req[p].aw.addr = a; req[p].aw.prot = 3'b000;
    req[p].w.data = d; req[p].w.strb = 4'hf;
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
    req[p].ar.addr = a; req[p].ar.prot = 3'b000; req[p].ar_valid = 1;
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
    logic [31:0] r;
    integer i;
    for (int p = 0; p < 4; p++) req[p] = '0;
    aw_auth = 1; ar_auth = 1;
    backend_idle = 2'b11; backend_done = 1;
    used_valid = 0; used_qid = 0; used_context = 0; used_len = 0; used_fence = 0;
    cfg_event = 0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    read_reg(0, APU_MMIO_BASE, r);
    check("guest virtio magic", r == VIRTIO_MMIO_MAGIC);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_MAIL_IDX), 1, 2, 0);
    read_reg(2, APU_MMIO_BASE, r);
    check("disabled guest discovery", r == 0);

    for (i = 0; i < APU_EXEC_IMEM; i++) begin
      mail_word(0, 32'(i));
      mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
      mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    end
    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_TID, 1, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd10));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 2);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 3, 1, 2, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 3);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);

    mail_word(0, 0);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_OK);

    mail_word(0, 0);
    mail_word(1, 3);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("micro t0 r3", r == 32'd10);
    mail_word(0, 1);
    mail_word(1, 3);
    mail_go(APU_MEM_EXEC_PEEK, APU_DMA_OK);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("micro t1 r3", r == 32'd11);

    mail_word(0, 0);
    mail_word(1, apu_exec_enc(APU_EX_IADD, 1, 1, 1, 0, 0, 1, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_word(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    mail_go(APU_MEM_EXEC_IMEM, APU_DMA_OK);
    mail_word(0, 1);
    mail_go(APU_MEM_EXEC_RUN, APU_DMA_PROTOCOL);
    ctrl_read(ACTRL_MAIL_CPL0, r);
    check("shader micro-op fault flag", r[0]);

    mail_go(APU_MEM_MAP_INSERT, APU_DMA_PERMISSION);

    check("dma idle", dma_req == '0);

    if (errors != 0) $fatal(1, "APU fw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_fw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
