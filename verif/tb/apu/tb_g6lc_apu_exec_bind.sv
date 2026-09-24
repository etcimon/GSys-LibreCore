// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Accepted exec ops still complete when cancelled. A held completion stays
// until acknowledged. Disabled exec ops are not marked ready.

`timescale 1ns/1ps

module g6lc_apu_exec_bind_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b1) (
  input  logic clk_i, rst_ni, testmode_i, enable_i, cancel_i,
  input  logic op_valid_i,
  output logic op_ready_o,
  input  apu_mem_op_e op_i,
  input  apu_exec_job_t exec_i,
  output logic op_cpl_valid_o,
  input  logic op_cpl_ready_i,
  output apu_map_cpl_t op_cpl_o,
  output logic idle_o
);
  g6lc_apu_exec_bind #(.ApuCfg(g6lc_exec_test_pkg::ex_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_exec_bind;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_exec_test_pkg::*;
  logic clk = 0, rst_ni = 0, enable, cancel, op_valid, op_ready, cpl_valid, cpl_ready;
  logic idle;
  apu_mem_op_e op;
  apu_exec_job_t job;
  apu_map_cpl_t cpl;
  logic off_ready, off_cpl, off_idle;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  logic mail_cancel, m_op_v, m_op_r, m_cpl_v, m_cpl_r, m_idle;
  apu_mem_op_e m_op;
  apu_exec_job_t m_job;
  apu_map_cpl_t m_cpl;
  apu_reg_req_t mreq;
  apu_reg_rsp_t mrsp;

  g6lc_apu_exec_bind_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .op_valid_i(op_valid), .op_ready_o(op_ready), .op_i(op), .exec_i(job),
    .op_cpl_valid_o(cpl_valid), .op_cpl_ready_i(cpl_ready), .op_cpl_o(cpl),
    .idle_o(idle)
  );
  g6lc_apu_exec_bind_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .op_valid_i(op_valid), .op_ready_o(off_ready), .op_i(op), .exec_i(job),
    .op_cpl_valid_o(off_cpl), .op_cpl_ready_i(cpl_ready), .op_cpl_o(),
    .idle_o(off_idle)
  );
  g6lc_apu_mbox #(.ApuCfg(g6lc_exec_test_pkg::ex_cfg(1))) i_mbox (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(1'b1), .cancel_i(mail_cancel),
    .req_i(mreq), .rsp_o(mrsp),
    .op_valid_o(m_op_v), .op_ready_i(m_op_r), .op_o(m_op),
    .insert_o(), .lookup_o(), .inval_o(),
    .sg_load_o(), .sg_list_o(), .sg_backing_o(), .sg_query_o(),
    .cmd_o(), .cmd_dma_o(), .cmd_map_o(), .used_o(), .exec_o(m_job),
    .op_cpl_valid_i(m_cpl_v), .op_cpl_ready_o(m_cpl_r), .op_cpl_i(m_cpl),
    .lookup_mapping_i('0),
    .cmd_rd_valid_o(), .cmd_rd_ready_i(1'b0), .cmd_rd_offset_o(),
    .cmd_rd_data_valid_i(1'b0), .cmd_rd_data_ready_o(), .cmd_rd_data_i('0),
    .idle_i(m_idle), .cmd_held_i(1'b0)
  );
  g6lc_apu_exec_bind #(.ApuCfg(g6lc_exec_test_pkg::ex_cfg(1))) i_mail (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(1'b1), .cancel_i(mail_cancel),
    .op_valid_i(m_op_v), .op_ready_o(m_op_r), .op_i(m_op), .exec_i(m_job),
    .op_cpl_valid_o(m_cpl_v), .op_cpl_ready_i(m_cpl_r), .op_cpl_o(m_cpl),
    .idle_o(m_idle)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "exec bind timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_ready, off_cpl} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled exec bind active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic reset_all;
    @(negedge clk);
    rst_ni = 0; enable = 1; cancel = 0; mail_cancel = 0;
    op_valid = 0; cpl_ready = 0; op = APU_MEM_NONE; job = '0; mreq = '0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
  endtask
  task automatic ack;
    @(negedge clk); cpl_ready = 1;
    @(posedge clk); @(negedge clk); cpl_ready = 0;
  endtask
  task automatic mail_write(input logic [15:0] addr, input logic [31:0] data);
    @(negedge clk);
    mreq = '{addr: 64'(addr), write: 1'b1, wdata: data, wstrb: 4'hf, valid: 1'b1};
    @(posedge clk);
    check("mail write ready", mrsp.ready && !mrsp.error);
    @(negedge clk);
    mreq = '0;
  endtask
  task automatic mail_read(input logic [15:0] addr, output logic [31:0] data);
    @(negedge clk);
    mreq = '{addr: 64'(addr), write: 1'b0, wdata: '0, wstrb: '0, valid: 1'b1};
    @(posedge clk);
    data = mrsp.rdata;
    check("mail read ready", mrsp.ready && !mrsp.error);
    @(negedge clk);
    mreq = '0;
  endtask

  initial begin
    logic [31:0] stat;
    int spins;
    reset_all();

    cases = 1;
    enable = 0; op = APU_MEM_EXEC_RUN; op_valid = 1;
    repeat (4) begin
      @(negedge clk);
      check("disabled exec op is not ready", !op_ready && !cpl_valid);
    end
    op_valid = 0; enable = 1;

    cases = 2;
    @(negedge clk);
    op = APU_MEM_MAP_LOOKUP; op_valid = 1;
    @(posedge clk);
    check("non-exec op is accepted", op_ready);
    @(negedge clk); op_valid = 0;
    spins = 0;
    while (!cpl_valid) begin
      @(negedge clk);
      if (spins > 20) $fatal(1, "permission completion missing");
      spins++;
    end
    check("non-exec op is permission", cpl.status == APU_DMA_PERMISSION);
    ack();

    cases = 3;
    @(negedge clk);
    op = APU_MEM_EXEC_RUN; job = '0; op_valid = 1;
    @(posedge clk);
    check("run is accepted", op_ready);
    @(negedge clk); op_valid = 0; cancel = 1;
    spins = 0;
    while (!cpl_valid) begin
      @(negedge clk);
      if (spins > 20) $fatal(1, "cancel completion missing");
      spins++;
    end
    check("accepted run completes as cancelled", cpl.status == APU_DMA_CANCELLED);
    repeat (4) begin
      @(negedge clk);
      check("cancel holds the completion", cpl_valid && cpl.status == APU_DMA_CANCELLED);
    end
    cancel = 0;
    ack();
    @(negedge clk);
    check("bind idle after cancel ack", idle);

    cases = 4;
    @(negedge clk);
    job = '0;
    job.inst = apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0);
    op = APU_MEM_EXEC_IMEM; op_valid = 1;
    @(posedge clk);
    check("halt load is accepted", op_ready);
    @(negedge clk); op_valid = 0;
    spins = 0;
    while (!cpl_valid) begin
      @(negedge clk);
      if (spins > 20) $fatal(1, "halt load completion missing");
      spins++;
    end
    check("halt load completes", cpl.status == APU_DMA_OK);
    ack();
    @(negedge clk);
    op = APU_MEM_EXEC_RUN; job = '0; op_valid = 1;
    @(posedge clk);
    check("halt run is accepted", op_ready);
    @(negedge clk); op_valid = 0;
    spins = 0;
    while (!cpl_valid) begin
      @(negedge clk);
      if (spins > 40) $fatal(1, "halt completion missing");
      spins++;
    end
    check("finished run is ok", cpl.status == APU_DMA_OK);
    cancel = 1;
    repeat (4) begin
      @(negedge clk);
      check("cancel leaves a finished completion", cpl_valid && cpl.status == APU_DMA_OK);
    end
    cancel = 0;
    ack();

    cases = 5;
    mail_write(ACTRL_MAIL_GO, 32'(APU_MEM_EXEC_RUN));
    spins = 0;
    while (!(m_op_v && m_op_r)) begin
      @(posedge clk);
      if (spins > 20) $fatal(1, "mailbox run not accepted");
      spins++;
    end
    @(negedge clk); mail_cancel = 1;
    spins = 0;
    stat = '1;
    while (stat[31] || stat[3:0] != 4'(APU_DMA_CANCELLED)) begin
      mail_read(ACTRL_MAIL_STAT, stat);
      if (spins > 40) $fatal(1, "mailbox cancel did not complete");
      spins++;
    end
    check("mailbox records the cancel completion", 1'b1);
    @(negedge clk);
    check("mailbox bind idle after cancel", m_idle);
    mail_cancel = 0;

    if (errors != 0) $fatal(1, "APU exec bind errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_exec_bind cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
