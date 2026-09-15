// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_th_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t th_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t th_core();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
endpackage

module g6lc_apu_th_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1, parameter int unsigned NumSources = 30) (
  input logic clk_i, rst_ni, testmode_i,
  input apu_dma_axi_req_t guest_req_i, control_req_i,
  output apu_dma_axi_resp_t guest_rsp_o, control_rsp_o,
  input logic [31:0] control_aw_hart_i, control_ar_hart_i,
  input logic [NumSources-1:0] irq_sources_i,
  output logic [NumSources-1:0] irq_sources_o,
  output logic guest_irq_o, control_irq_o, plic_irq_o,
  output logic [31:0] plic_source_o,
  output logic [63:0] guest_base_o, guest_end_o, control_base_o, control_end_o,
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
  g6lc_apu_th #(
    .ApuCfg(g6lc_th_test_pkg::th_cfg(Enable)),
    .CoreCfg(g6lc_th_test_pkg::th_core()),
    .NumSources(NumSources)
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_th;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_th_test_pkg::*;
  import axi_pkg::*;
  localparam int unsigned NumSources = 30;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t [3:0] req;
  apu_dma_axi_resp_t [3:0] rsp;
  logic [31:0] aw_hart, ar_hart;
  logic [NumSources-1:0] irq_in, irq_out, off_irq_out;
  logic guest_irq, control_irq, plic_irq, reset_req, bus_fault, used_valid, used_ready;
  logic [31:0] plic_source;
  logic [63:0] guest_base, guest_end, control_base, control_end;
  logic [63:0] off_guest_base, off_control_base;
  logic [1:0] queue_enable, stop_req, backend_idle;
  logic backend_done, cfg_event;
  apu_vq_state_t vq [2];
  logic [31:0] used_qid, used_context, used_len;
  logic [63:0] used_fence;
  logic off_guest_irq, off_control_irq, off_plic, off_reset, off_ready, off_fault;
  logic [1:0] off_enable, off_stop;
  logic [31:0] off_src;
  apu_vq_state_t off_vq [2];
  apu_dma_axi_req_t dma_req, off_dma;
  apu_dma_axi_resp_t dma_rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_th_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[0]), .guest_rsp_o(rsp[0]),
    .control_req_i(req[1]), .control_rsp_o(rsp[1]),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(irq_out),
    .guest_irq_o(guest_irq), .control_irq_o(control_irq), .plic_irq_o(plic_irq),
    .plic_source_o(plic_source),
    .guest_base_o(guest_base), .guest_end_o(guest_end),
    .control_base_o(control_base), .control_end_o(control_end),
    .vq_state_o(vq), .queue_enable_o(queue_enable),
    .backend_reset_req_o(reset_req), .backend_queue_stop_req_o(stop_req),
    .backend_reset_done_i(backend_done), .backend_idle_i(backend_idle),
    .used_valid_i(used_valid), .used_qid_i(used_qid), .used_context_i(used_context),
    .used_len_i(used_len), .used_fence_i(used_fence), .used_ready_o(used_ready),
    .cfg_display_event_i(cfg_event), .bus_fault_o(bus_fault),
    .dma_req_o(dma_req), .dma_rsp_i(dma_rsp)
  );
  g6lc_apu_th_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .guest_req_i(req[2]), .guest_rsp_o(rsp[2]),
    .control_req_i(req[3]), .control_rsp_o(rsp[3]),
    .control_aw_hart_i(aw_hart), .control_ar_hart_i(ar_hart),
    .irq_sources_i(irq_in), .irq_sources_o(off_irq_out),
    .guest_irq_o(off_guest_irq), .control_irq_o(off_control_irq),
    .plic_irq_o(off_plic), .plic_source_o(off_src),
    .guest_base_o(off_guest_base), .guest_end_o(),
    .control_base_o(off_control_base), .control_end_o(),
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
  initial begin #500000; $fatal(1, "APU th timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_guest_irq, off_control_irq, off_plic, off_reset, off_ready, off_enable,
         off_stop, off_fault, off_src, off_vq[0], off_vq[1], off_dma} !== '0)
      $fatal(1, "disabled APU th active");
    if (off_irq_out !== irq_in)
      $fatal(1, "disabled th must pass PLIC sources through");
  end
  assign dma_rsp = '0;

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic pack32(input logic [63:0] a, input logic [31:0] d,
      output logic [63:0] data, output logic [7:0] strb);
    if (a[2]) begin data = {d, 32'h0}; strb = 8'hf0; end
    else begin data = {32'h0, d}; strb = 8'h0f; end
  endtask
  task automatic unpack32(input logic [63:0] a, input logic [63:0] data,
      output logic [31:0] d);
    d = a[2] ? data[63:32] : data[31:0];
  endtask
  task automatic send_write(input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [31:0] hart = 1, input logic [2:0] size = 3'd2);
    logic [63:0] wdata;
    logic [7:0] strb;
    bit aw_done, w_done;
    pack32(a, d, wdata, strb);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    aw_hart = hart;
    req[p].aw.addr = a; req[p].aw.size = size; req[p].aw.len = '0;
    req[p].aw.burst = axi_pkg::BURST_INCR; req[p].aw.id = '0;
    req[p].w.data = wdata; req[p].w.strb = strb; req[p].w.last = 1'b1;
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
      input logic [1:0] expected = 0, input logic [31:0] hart = 1,
      input logic [2:0] size = 3'd2);
    send_write(p, a, d, hart, size);
    receive_write(p, expected);
  endtask
  task automatic send_read(input int p, input logic [63:0] a,
      input logic [31:0] hart = 1, input logic [2:0] size = 3'd2);
    @(negedge clk);
    ar_hart = hart;
    req[p].ar.addr = a; req[p].ar.size = size; req[p].ar.len = '0;
    req[p].ar.burst = axi_pkg::BURST_INCR; req[p].ar.id = '0;
    req[p].ar_valid = 1;
    @(posedge clk);
    while (!rsp[p].ar_ready) @(posedge clk);
    @(negedge clk); req[p].ar_valid = 0;
  endtask
  task automatic receive_read(input int p, input logic [63:0] a,
      output logic [31:0] data, input logic [1:0] expected = 0);
    @(posedge clk);
    while (!rsp[p].r_valid) @(posedge clk);
    unpack32(a, rsp[p].r.data, data);
    check("AXI R", rsp[p].r.resp == expected && rsp[p].r.last);
    @(negedge clk); req[p].r_ready = 1;
    @(posedge clk); @(negedge clk); req[p].r_ready = 0;
  endtask
  task automatic read_reg(input int p, input logic [63:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0, input logic [31:0] hart = 1,
      input logic [2:0] size = 3'd2);
    send_read(p, a, hart, size);
    receive_read(p, a, data, expected);
  endtask
  task automatic guest_write(input logic [15:0] a, input logic [31:0] d);
    write_reg(0, APU_MMIO_BASE + 64'(a), d);
  endtask
  task automatic guest_read(input logic [15:0] a, output logic [31:0] data);
    read_reg(0, APU_MMIO_BASE + 64'(a), data);
  endtask

  initial begin
    logic [31:0] r;
    for (int p = 0; p < 4; p++) req[p] = '0;
    aw_hart = 0; ar_hart = 0;
    irq_in = '0;
    backend_idle = 2'b11; backend_done = 1;
    used_valid = 0; used_qid = 0; used_context = 0; used_len = 0; used_fence = 0;
    cfg_event = 0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    cases = 1;
    check("PLIC source is 9", plic_source == 9);
    check("guest window after GPIO/AI", guest_base == 64'h4000_1000 &&
          guest_end == 64'h4000_2000);
    check("control window is private", control_base == 64'h4000_2000 &&
          control_end == 64'h4000_3000);
    check("disabled still publishes placement",
          off_guest_base == guest_base && off_control_base == control_base);

    cases = 2;
    read_reg(0, APU_MMIO_BASE, r);
    check("guest virtio magic via AXI4-64", r == VIRTIO_MMIO_MAGIC);
    read_reg(0, APU_MMIO_BASE + 64'(VREG_VERSION), r);
    check("version on high 32-bit lane", r == VIRTIO_MMIO_VERSION2);
    read_reg(1, APU_CONTROL_BASE, r, 2, 0);
    check("hart 0 cannot read control", r == 0);
    read_reg(1, APU_CONTROL_BASE, r, 0, 1);
    check("firmware hart reads control magic", r == APU_CONTROL_MAGIC);

    cases = 3;
    read_reg(0, APU_MMIO_BASE, r, 2, 1, 3'd3);
    check("64-bit size is rejected", 1'b1);

    cases = 4;
    irq_in[7] = 1'b1; irq_in[0] = 1'b1;
    @(negedge clk);
    check("AI source 8 is untouched", irq_out[7] == 1'b1);
    check("APU source quiet", irq_out[8] == 1'b0);
    check("disabled splice is identity", off_irq_out == irq_in);

    cases = 5;
    guest_write(VREG_STATUS, 32'h1);
    guest_write(VREG_STATUS, 32'h3);
    guest_write(VREG_DEVICE_FEAT_SEL, 32'd1);
    guest_write(VREG_DRIVER_FEAT_SEL, 32'd1);
    guest_write(VREG_DRIVER_FEATURES, 32'h0000_0101);
    guest_write(VREG_DRIVER_FEAT_SEL, 32'd0);
    guest_write(VREG_DRIVER_FEATURES, 32'h0);
    guest_write(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
                                 VSTATUS_FEATURES_OK));
    guest_write(VREG_STATUS, 32'(VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
                                 VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK));
    guest_read(VREG_STATUS, r);
    check("driver_ok", r[7:0] == 8'h0f);
    cfg_event = 1;
    @(negedge clk); @(negedge clk);
    check("guest irq becomes PLIC source 9", irq_out[8] == 1'b1 && plic_irq);
    check("AI source 8 survives APU irq", irq_out[7] == 1'b1);
    cfg_event = 0;

    cases = 6;
    read_reg(2, APU_MMIO_BASE, r, 2);
    check("disabled AXI4 guest is SLVERR", 1'b1);

    if (errors != 0) $fatal(1, "APU th errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_th cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
