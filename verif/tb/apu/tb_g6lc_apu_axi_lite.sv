// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module g6lc_apu_axi_fixture
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
  input logic cfg_display_event_i
);
  function automatic apu_cfg_t test_apu_cfg();
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = Enable;
    cfg.FirmwareHart = 1;
    cfg.FirmwareRamBase = 64'h9000_0000;
    cfg.FirmwareRamBytes = 64'h40000;
    return cfg;
  endfunction
  function automatic config_pkg::cva6_cfg_t test_core_cfg();
    config_pkg::cva6_cfg_t cfg = config_pkg::cva6_cfg_t'(0);
    cfg.NrCores = 2;
    cfg.NrHarts = 1;
    return cfg;
  endfunction
  apu_reg_req_t mbox_req;
  apu_reg_rsp_t mbox_rsp;
  assign mbox_rsp = '{rdata: '0, error: 1'b1, ready: mbox_req.valid};
  logic guest_hold_i, ctrl_hold_i;
  logic [31:0] guest_epoch_i, ctrl_epoch_i, epoch_o;
  assign guest_hold_i = 1'b0;
  assign ctrl_hold_i = 1'b0;
  assign guest_epoch_i = '0;
  assign ctrl_epoch_i = '0;
  g6lc_apu_axi_lite #(.ApuCfg(test_apu_cfg()), .CoreCfg(test_core_cfg())) i_dut (
    .*,
    .mbox_req_o(mbox_req),
    .mbox_rsp_i(mbox_rsp)
  );
endmodule

module tb_g6lc_apu_axi_lite;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
  logic clk = 0;
  logic rst_ni = 0;
  apu_axi_req_t [3:0] req;
  apu_axi_resp_t [3:0] rsp;
  logic aw_auth, ar_auth;
  logic guest_irq, control_irq, reset_req;
  logic [1:0] queue_enable, stop_req, backend_idle;
  logic backend_done;
  apu_vq_state_t vq [2];
  logic used_valid, used_ready;
  logic [31:0] used_qid, used_context, used_len;
  logic [63:0] used_fence;
  logic cfg_event;
  logic off_guest_irq, off_control_irq, off_reset, off_ready;
  logic [1:0] off_enable, off_stop;
  apu_vq_state_t off_vq [2];
  int errors = 0, checks = 0, cycles = 0;

  g6lc_apu_axi_fixture i_on (
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
    .cfg_display_event_i(cfg_event)
  );
  g6lc_apu_axi_fixture #(.Enable(0)) i_off (
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
    .cfg_display_event_i(cfg_event)
  );
  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if ($test$plusargs("trace_axi") && cycles < 25)
      $display("AXI cycle=%0d rv=%b rr=%b rd=%h pop=%b", cycles,
               rsp[0].r_valid, req[0].r_ready, rsp[0].r.data,
               i_on.i_dut.gen_bridge[0].i_bridge.read_resp_fifo_pop);
  end
  initial begin
    #500000;
    $fatal(1, "APU AXI test timeout");
  end
  for (genvar p = 0; p < 4; p++) begin : gen_stability
    assert property (@(posedge clk) disable iff (!rst_ni)
      rsp[p].r_valid && !req[p].r_ready |=> rsp[p].r_valid && $stable(rsp[p].r))
      else $error("R stall p=%0d cycle=%0d valid=%b ready=%b data=%h prev_valid=%b prev_ready=%b prev_data=%h",
                  p, cycles, rsp[p].r_valid, req[p].r_ready, rsp[p].r.data,
                  $past(rsp[p].r_valid), $past(req[p].r_ready), $past(rsp[p].r.data));
    assert property (@(posedge clk) disable iff (!rst_ni)
      rsp[p].b_valid && !req[p].b_ready |=> rsp[p].b_valid && $stable(rsp[p].b));
  end
  always @(negedge clk) begin
    #1;
    if ({off_guest_irq, off_control_irq, off_reset, off_ready, off_enable,
         off_stop, off_vq[0], off_vq[1]} !== '0) $fatal(1, "disabled APU active");
  end
  task automatic check(input string name, input logic [63:0] got, want);
    checks++;
    if (got !== want) begin
      $display("FAIL %s got=%h want=%h", name, got, want);
      errors++;
    end
  endtask
  task automatic send_write(input int p, input logic [63:0] a,
      input logic [31:0] d, input bit auth = 1, input logic [3:0] strb = 4'hf,
      input int skew = 0);
    bit aw_done, w_done;
    aw_done = 0;
    w_done = 0;
    @(negedge clk);
    aw_auth = auth;
    req[p].aw.addr = a;
    req[p].aw.prot = 3'b111;
    req[p].w.data = d;
    req[p].w.strb = strb;
    req[p].aw_valid = skew >= 0;
    req[p].w_valid = skew <= 0;
    repeat (skew < 0 ? -skew : skew) @(negedge clk);
    req[p].aw_valid = 1;
    req[p].w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (req[p].aw_valid && rsp[p].aw_ready) aw_done = 1;
      if (req[p].w_valid && rsp[p].w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) req[p].aw_valid = 0;
      if (w_done) req[p].w_valid = 0;
    end
  endtask
  task automatic receive_write(input int p, input logic [1:0] expected = 0,
      input int hold_cycles = 0);
    @(posedge clk);
    while (!rsp[p].b_valid) @(posedge clk);
    check("AXI B response", rsp[p].b.resp, expected);
    repeat (hold_cycles) @(posedge clk);
    @(negedge clk);
    req[p].b_ready = 1;
    @(posedge clk);
    @(negedge clk);
    req[p].b_ready = 0;
  endtask
  task automatic write_reg(input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [1:0] expected = 0, input bit auth = 1,
      input logic [3:0] strb = 4'hf, input int skew = 0);
    send_write(p, a, d, auth, strb, skew);
    receive_write(p, expected, 2);
  endtask
  task automatic send_read(input int p, input logic [63:0] a, input bit auth = 1);
    @(negedge clk);
    ar_auth = auth;
    req[p].ar.addr = a;
    req[p].ar.prot = 3'b111;
    req[p].ar_valid = 1;
    @(posedge clk);
    while (!rsp[p].ar_ready) @(posedge clk);
    @(negedge clk);
    req[p].ar_valid = 0;
  endtask
  task automatic receive_read(input int p, output logic [31:0] data,
      input logic [1:0] expected = 0, input int hold_cycles = 2);
    @(posedge clk);
    while (!rsp[p].r_valid) @(posedge clk);
    data = rsp[p].r.data;
    check("AXI R response", rsp[p].r.resp, expected);
    repeat (hold_cycles) @(posedge clk);
    @(negedge clk);
    req[p].r_ready = 1;
    @(posedge clk);
    @(negedge clk);
    req[p].r_ready = 0;
  endtask
  task automatic read_reg(input int p, input logic [63:0] a,
      output logic [31:0] data, input logic [1:0] expected = 0, input bit auth = 1);
    send_read(p, a, auth);
    receive_read(p, data, expected);
  endtask
  task automatic guest_write(input logic [15:0] a, input logic [31:0] d);
    write_reg(0, APU_MMIO_BASE + 64'(a), d);
  endtask
  task automatic ctrl_write(input logic [15:0] a, input logic [31:0] d);
    write_reg(1, APU_CONTROL_BASE + 64'(a), d);
  endtask
  task automatic program_queue(input int q);
    guest_write(VREG_QUEUE_SEL, 32'(q));
    guest_write(VREG_QUEUE_NUM, 16);
    guest_write(VREG_QUEUE_DESC_LO, 32'h8001_0000 + 32'(q) * 32'h4000);
    guest_write(VREG_QUEUE_DESC_HI, 1);
    guest_write(VREG_QUEUE_AVAIL_LO, 32'h8001_1000 + 32'(q) * 32'h4000);
    guest_write(VREG_QUEUE_AVAIL_HI, 2);
    guest_write(VREG_QUEUE_USED_LO, 32'h8001_2000 + 32'(q) * 32'h4000);
    guest_write(VREG_QUEUE_USED_HI, 3);
    guest_write(VREG_QUEUE_READY, 1);
  endtask
  initial begin
    logic [31:0] r, epoch0;
    for (int p = 0; p < 4; p++) req[p] = '0;
    aw_auth = 0;
    ar_auth = 0;
    backend_idle = 2'b11;
    backend_done = 1;
    used_valid = 0;
    used_qid = 0;
    used_context = 32'hfedc_ba98;
    used_fence = 64'h0123_4567_89ab_cdef;
    used_len = 32'd24;
    cfg_event = 0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    read_reg(0, APU_MMIO_BASE, r);
    check("virtio discovery through AXI", r, 32'h7472_6976);
    read_reg(1, APU_CONTROL_BASE, r, 2, 0);
    check("unauthorized read has no data", r, 0);
    read_reg(0, APU_CONTROL_BASE, r, 2);
    check("guest cannot read private port", r, 0);
    write_reg(0, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 1, 2);
    read_reg(1, APU_MMIO_BASE, r, 2);
    check("private port cannot alias guest aperture", r, 0);
    read_reg(0, APU_MMIO_BASE + 64'h1_0000_0000, r, 2);
    check("high address does not alias", r, 0);
    read_reg(1, APU_CONTROL_BASE, r);
    check("private discovery", r, APU_CONTROL_MAGIC);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 1, 2, 1, 4'h1);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_RESET_ACK), 1, 2);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL) + 1, 1, 2);

    send_read(1, APU_CONTROL_BASE);
    send_read(1, APU_CONTROL_BASE + 4);
    send_read(1, APU_CONTROL_BASE, 0);
    ar_auth = 1;
    receive_read(1, r); check("first buffered read", r, APU_CONTROL_MAGIC);
    receive_read(1, r); check("second buffered read", r, 1);
    receive_read(1, r, 2); check("buffered authorization preserved", r, 0);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 1);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 0);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 1, 0);
    aw_auth = 1;
    receive_write(1); receive_write(1); receive_write(1, 2);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), r);
    check("buffered denied write cannot mutate state", r, 0);

    begin
      logic [31:0] selected;
      bit allowed;
      logic [3:0] strb;
      selected = 0;
      for (int i = 0; i < 64; i++) begin
        allowed = i % 3 != 0;
        strb = i % 5 == 0 ? 4'h1 : 4'hf;
        write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 32'(i % 4),
                  allowed && strb == 4'hf && i % 4 < 2 ? 2'b00 : 2'b10,
                  allowed, strb, i % 7 - 3);
        if (allowed && strb == 4'hf && i % 4 < 2) selected = 32'(i % 4);
        read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), r);
        check("authorization/strobe/skew sweep preserves state", r, selected);
      end
      ctrl_write(ACTRL_QUEUE_SEL, 0);
    end

    write_reg(0, APU_MMIO_BASE + 64'(VREG_STATUS), 1, 0, 1, 4'hf, 3);
    write_reg(0, APU_MMIO_BASE + 64'(VREG_STATUS), 3, 0, 1, 4'hf, -3);
    guest_write(VREG_DRIVER_FEAT_SEL, 1);
    guest_write(VREG_DRIVER_FEATURES, 32'h101);
    guest_write(VREG_STATUS, 11);
    program_queue(0);
    program_queue(1);
    guest_write(VREG_STATUS, 15);
    guest_write(VREG_QUEUE_NOTIFY, 0);
    check("notification reaches firmware IRQ", control_irq, 1);
    write_reg(1, APU_CONTROL_BASE + 64'(ACTRL_NOTIFY_CLEAR), 1, 2, 0);
    check("denied notify clear has no effect", control_irq, 1);
    ctrl_write(ACTRL_NOTIFY_CLEAR, 1);
    check("authorized notify clear", control_irq, 0);

    @(negedge clk);
    used_valid = 1;
    @(posedge clk);
    check("completion accepted", used_ready, 1);
    @(negedge clk);
    used_valid = 0;
    ctrl_write(ACTRL_SNAPSHOT, 1);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_SNAP_DESC_HI), r);
    check("snapshot full descriptor address", r, 1);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_SNAP_CPL_FENCE_HI), r);
    check("snapshot fence high", r, 32'h0123_4567);
    @(negedge clk);
    used_fence = 64'hffff_ffff_0000_0001;
    used_context = 32'h1234_5678;
    used_valid = 1;
    @(negedge clk);
    used_valid = 0;
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_SNAP_CPL_FENCE_LO), r);
    check("snapshot does not tear", r, 32'h89ab_cdef);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_SNAP_CPL_CONTEXT), r);
    check("snapshot context does not tear", r, 32'hfedc_ba98);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_EPOCH), epoch0);

    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 0);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 0);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_NOTIFY_CLEAR), 1);
    backend_idle = 2'b10;
    guest_write(VREG_QUEUE_SEL, 0);
    guest_write(VREG_QUEUE_RESET, 1);
    receive_write(1); receive_write(1); receive_write(1, 2);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_EPOCH), r);
    check("queue reset changes control epoch", r, epoch0 + 1);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_SNAP_DESC_LO), r, 2);
    check("reset invalidates snapshot", r, 0);
    ctrl_write(ACTRL_QUEUE_STOP_ACK, 1);
    repeat (5) @(negedge clk);
    check("firmware alone cannot finish queue reset", stop_req, 1);
    check("mapping held until backend drain", vq[0].desc, 64'h1_8001_0000);
    check("other queue remains active", queue_enable, 2);
    backend_idle = 3;
    repeat (4) @(negedge clk);
    check("queue reset finishes after drain", stop_req, 0);
    check("queue mapping retired", vq[0].desc, 0);
    program_queue(0);

    backend_idle = 2;
    guest_write(VREG_QUEUE_READY, 0);
    send_read(0, APU_MMIO_BASE + 64'(VREG_QUEUE_READY));
    repeat (4) @(negedge clk);
    check("guest QueueReady read stalls", rsp[0].r_valid, 0);
    ctrl_write(ACTRL_QUEUE_STOP_ACK, 1);
    check("separate control port progresses during guest stall", stop_req, 1);
    backend_idle = 3;
    receive_read(0, r);
    check("guest stop read synchronized", r, 0);
    guest_write(VREG_QUEUE_READY, 1);

    backend_done = 0;
    backend_idle = 0;
    guest_write(VREG_STATUS, 0);
    check("reset request reaches backend", reset_req, 1);
    ctrl_write(ACTRL_RESET_ACK, 1);
    repeat (4) @(negedge clk);
    check("firmware reset ACK cannot bypass busy DMA", reset_req, 1);
    check("device reset disables queues", queue_enable, 0);
    check("device reset blocks completions", used_ready, 0);
    backend_idle = 3;
    repeat (3) @(negedge clk);
    check("device reset also requires resource teardown", reset_req, 1);
    backend_done = 1;
    repeat (4) @(negedge clk);
    read_reg(0, APU_MMIO_BASE + 64'(VREG_STATUS), r);
    check("device reset completed", r, 0);
    check("guest IRQ reset", guest_irq, 0);

    write_reg(2, APU_MMIO_BASE + 64'(VREG_STATUS), 15);
    write_reg(3, APU_CONTROL_BASE + 64'(ACTRL_RESET_ACK), 1);
    read_reg(2, APU_MMIO_BASE, r); check("disabled guest discovery", r, 0);
    read_reg(3, APU_CONTROL_BASE, r); check("disabled control discovery", r, 0);
    send_read(1, APU_CONTROL_BASE);
    send_write(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), 1);
    repeat (3) @(negedge clk);
    check("read pending before hardware reset", rsp[1].r_valid, 1);
    check("write pending before hardware reset", rsp[1].b_valid, 1);
    rst_ni = 0;
    repeat (2) @(negedge clk);
    for (int p = 0; p < 4; p++)
      check("hardware reset cancels bus responses", {rsp[p].r_valid, rsp[p].b_valid}, 0);
    rst_ni = 1;
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_QUEUE_SEL), r);
    check("hardware reset clears control state", r, 0);
    read_reg(1, APU_CONTROL_BASE + 64'(ACTRL_EPOCH), r);
    check("hardware reset clears control epoch", r, 0);
    if (errors != 0) $fatal(1, "APU AXI errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_axi_lite cycles=%0d checks=%0d errors=0", cycles, checks);
      $finish;
    end
  end
endmodule
