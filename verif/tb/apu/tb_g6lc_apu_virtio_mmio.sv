// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Standalone P1 virtio-mmio transport smoke. This checks register discovery,
// modern feature negotiation, queue programming/reset, notification handoff,
// full-width used metadata and device reset. It is intentionally not a virgl
// rendering test: no command execution is advertised by ApuP1Transport.

`timescale 1ns/1ps

module tb_g6lc_apu_virtio_mmio;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk;
  logic rst_ni;
  logic req;
  logic we;
  logic [15:0] addr;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic [31:0] rdata;
  logic        rvalid;
  logic        error;
  logic        irq;
  logic        fw_reset_pulse, fw_reset_req, fw_reset_ack;
  logic [APU_NUM_QUEUES-1:0] queue_enable, fw_queue_stop_req, fw_queue_stop_ack;
  logic [31:0] used_context, last_used_context;
  logic [APU_NUM_QUEUES-1:0] notify_pending;
  logic [APU_NUM_QUEUES-1:0] fw_notify_clear;
  logic        used_valid;
  logic [31:0] used_qid;
  logic [63:0] used_fence;
  logic [31:0] used_len;
  logic        used_ready;
  logic [31:0] last_used_qid;
  logic [63:0] last_used_fence;
  logic [31:0] last_used_len;
  logic        cfg_display_event;
  logic [31:0] debug_status;
  apu_vq_state_t vq_state [APU_NUM_QUEUES];

  int unsigned errors;
  int unsigned cycles;
  int unsigned checks;

  logic [31:0] off_rdata, off_qid, off_len, off_status;
  logic [63:0] off_fence;
  logic off_rvalid, off_error, off_irq, off_reset, off_ready;
  logic [APU_NUM_QUEUES-1:0] off_notify, off_enable, off_stop;
  logic off_reset_req;
  logic [31:0] off_context;
  apu_vq_state_t off_vq [APU_NUM_QUEUES];

  g6lc_apu_top i_off (
      .clk_i(clk), .rst_ni, .testmode_i(1'b1),
      .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .wstrb_i(wstrb),
      .rdata_o(off_rdata), .rvalid_o(off_rvalid), .error_o(off_error),
      .irq_o(off_irq), .vq_state_o(off_vq), .notify_pending_o(off_notify),
      .fw_notify_clear_i(fw_notify_clear), .fw_reset_pulse_o(off_reset),
      .queue_enable_o(off_enable), .fw_reset_req_o(off_reset_req),
      .fw_reset_ack_i(fw_reset_ack), .fw_queue_stop_req_o(off_stop),
      .fw_queue_stop_ack_i(fw_queue_stop_ack),
      .used_context_i(used_context), .last_used_context_o(off_context),
      .used_valid_i(used_valid), .used_qid_i(used_qid), .used_fence_i(used_fence),
      .used_len_i(used_len), .used_ready_o(off_ready), .last_used_qid_o(off_qid),
      .last_used_fence_o(off_fence), .last_used_len_o(off_len),
      .cfg_display_event_i(cfg_display_event), .debug_status_o(off_status)
  );

  always @(negedge clk) begin
    #1;
    if ({off_rdata, off_error, off_irq, off_notify, off_reset, off_ready,
         off_qid, off_fence, off_len, off_status, off_vq[0], off_vq[1],
         off_enable, off_reset_req, off_stop, off_context} !== '0 ||
        off_rvalid !== req)
      $fatal(1, "APU-off endpoint is not inert");
  end

  g6lc_apu_top #(
      .ApuCfg(ApuP1Transport)
  ) i_dut (
      .clk_i              (clk),
      .rst_ni             (rst_ni),
      .testmode_i         (1'b0),
      .req_i              (req),
      .we_i               (we),
      .addr_i             (addr),
      .wdata_i            (wdata),
      .wstrb_i            (wstrb),
      .rdata_o            (rdata),
      .rvalid_o           (rvalid),
      .error_o            (error),
      .irq_o              (irq),
      .vq_state_o         (vq_state),
      .notify_pending_o   (notify_pending),
      .fw_notify_clear_i  (fw_notify_clear),
      .fw_reset_pulse_o   (fw_reset_pulse),
      .queue_enable_o(queue_enable),
      .fw_reset_req_o(fw_reset_req), .fw_reset_ack_i(fw_reset_ack),
      .fw_queue_stop_req_o(fw_queue_stop_req), .fw_queue_stop_ack_i(fw_queue_stop_ack),
      .used_context_i(used_context), .last_used_context_o(last_used_context),
      .used_valid_i       (used_valid),
      .used_qid_i         (used_qid),
      .used_fence_i       (used_fence),
      .used_len_i         (used_len),
      .used_ready_o       (used_ready),
      .last_used_qid_o    (last_used_qid),
      .last_used_fence_o  (last_used_fence),
      .last_used_len_o    (last_used_len),
      .cfg_display_event_i(cfg_display_event),
      .debug_status_o     (debug_status)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin
    #1000000;
    $fatal(1, "APU transport test timeout");
  end

  task automatic tick;
    @(posedge clk);
  endtask

  task automatic idle_inputs;
    req              = 1'b0;
    we               = 1'b0;
    addr             = 16'h0;
    wdata            = 32'h0;
    wstrb            = 4'hf;
    fw_notify_clear  = '0;
    fw_reset_ack = 1'b1;
    fw_queue_stop_ack = '1;
    used_context = 32'hffff_1234;
    used_valid       = 1'b0;
    used_qid         = 32'h0;
    used_fence       = 64'h0;
    used_len         = 32'h0;
    cfg_display_event = 1'b0;
  endtask

  task automatic expect_eq(
      input string name,
      input logic [63:0] got,
      input logic [63:0] want
  );
    checks++;
    if (got !== want) begin
      $display("FAIL: %s: got %h want %h", name, got, want);
      errors++;
    end
  endtask

  task automatic expect_bit(input string name, input logic got);
    checks++;
    if (got !== 1'b1) begin
      $display("FAIL: %s", name);
      errors++;
    end
  endtask

  task automatic reg_write(input logic [15:0] a, input logic [31:0] d);
    @(negedge clk);
    req   = 1'b1;
    we    = 1'b1;
    addr  = a;
    wdata = d;
    wstrb = 4'hf;
    @(posedge clk);
    if (error) begin
      $display("FAIL: ","write error at %h", a);
      errors++;
    end
    @(negedge clk);
    req = 1'b0;
    we  = 1'b0;
    #1;
  endtask

  task automatic reg_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk);
    req   = 1'b1;
    we    = 1'b0;
    addr  = a;
    wstrb = 4'hf;
    @(posedge clk);
    d = rdata;
    if (!rvalid || error) begin
      $display("FAIL: ","read response error at %h", a);
      errors++;
    end
    @(negedge clk);
    req = 1'b0;
  endtask

  task automatic program_queue(
      input int unsigned q,
      input logic [63:0] desc,
      input logic [63:0] avail,
      input logic [63:0] used
  );
    reg_write(VREG_QUEUE_SEL, q);
    reg_write(VREG_QUEUE_NUM, 32'd16);
    reg_write(VREG_QUEUE_DESC_LO, desc[31:0]);
    reg_write(VREG_QUEUE_DESC_HI, desc[63:32]);
    reg_write(VREG_QUEUE_AVAIL_LO, avail[31:0]);
    reg_write(VREG_QUEUE_AVAIL_HI, avail[63:32]);
    reg_write(VREG_QUEUE_USED_LO, used[31:0]);
    reg_write(VREG_QUEUE_USED_HI, used[63:32]);
    reg_write(VREG_QUEUE_READY, 32'h1);
  endtask

  task automatic negotiate_transport;
    reg_write(VREG_STATUS, 32'h1);
    reg_write(VREG_STATUS, 32'h3);
    reg_write(VREG_DEVICE_FEAT_SEL, 32'd1);
    reg_write(VREG_DRIVER_FEAT_SEL, 32'd1);
    reg_write(VREG_DRIVER_FEATURES, 32'h0000_0101);
    reg_write(VREG_DRIVER_FEAT_SEL, 32'd0);
    reg_write(VREG_DRIVER_FEATURES, 32'h0);
    reg_write(VREG_STATUS, VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
              VSTATUS_FEATURES_OK);
  endtask

  initial begin
    logic [31:0] r;
    logic [31:0] gen0;

    errors = 0;
    cycles = 0;
    checks = 0;
    idle_inputs();
    rst_ni = 1'b0;
    repeat (5) tick();
    @(negedge clk);
    rst_ni = 1'b1;
    repeat (2) tick();

    reg_read(VREG_MAGIC, r);
    expect_eq("magic", r, VIRTIO_MMIO_MAGIC);
    reg_read(VREG_VERSION, r);
    expect_eq("mmio version", r, VIRTIO_MMIO_VERSION2);
    reg_read(VREG_DEVICE_ID, r);
    expect_eq("device id", r, VIRTIO_DEVICE_GPU);
    reg_read(VREG_VENDOR_ID, r);
    expect_eq("vendor id", r, G6LC_VIRTIO_VENDOR);
    reg_read(VREG_STATUS, r);
    expect_eq("reset status", r, 32'h0);

    reg_read(VREG_DEVICE_FEATURES, r);
    expect_eq("transport feature low", r, 32'h0);
    reg_write(VREG_DEVICE_FEAT_SEL, 32'd1);
    reg_read(VREG_DEVICE_FEATURES, r);
    expect_eq("transport feature high", r, 32'h0000_0101);
    reg_read(VCFG_NUM_SCANOUTS, r);
    expect_eq("P1 scanouts", r, 32'h0);
    reg_read(VCFG_NUM_CAPSETS, r);
    expect_eq("P1 capsets", r, 32'h0);

    negotiate_transport();
    reg_read(VREG_STATUS, r);
    expect_eq("features_ok", r, 32'h0000_000b);

    program_queue(0, 64'h0000_0000_8001_0000,
                  64'h0000_0000_8001_1000,
                  64'h0000_0000_8001_2000);
    program_queue(1, 64'h0000_0000_8001_4000,
                  64'h0000_0000_8001_5000,
                  64'h0000_0000_8001_6000);
    expect_bit("queue0 ready", vq_state[0].ready);
    expect_bit("queue1 ready", vq_state[1].ready);
    expect_eq("queue0 num", vq_state[0].num, 16'd16);
    expect_eq("queue1 used", vq_state[1].used, 64'h8001_6000);

    reg_write(VREG_STATUS, VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
              VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK);
    reg_read(VREG_STATUS, r);
    expect_eq("driver_ok", r, 32'h0000_000f);

    reg_write(VREG_QUEUE_NOTIFY, 32'h0);
    @(posedge clk);
    expect_bit("queue0 notify", notify_pending[0]);
    @(negedge clk);
    fw_notify_clear = 2'b01;
    @(posedge clk);
    @(negedge clk);
    fw_notify_clear = 2'b00;
    expect_eq("notify consumed", notify_pending, 2'b00);

    @(negedge clk);
    used_valid = 1'b1;
    used_qid   = 32'h0;
    used_fence = 64'h0123_4567_89ab_cdef;
    used_len   = 32'd24;
    @(posedge clk);
    @(negedge clk);
    used_valid = 1'b0;
    expect_bit("used irq", irq);
    reg_read(VREG_INTERRUPT_STATUS, r);
    expect_eq("used irq bit", r, 32'h1);
    expect_eq("used qid", last_used_qid, 32'h0);
    expect_eq("used fence", last_used_fence, 64'h0123_4567_89ab_cdef);
    expect_eq("used context", last_used_context, 32'hffff_1234);
    expect_eq("used len", last_used_len, 32'd24);
    reg_write(VREG_INTERRUPT_ACK, 32'h1);
    @(posedge clk);
    expect_eq("irq acked", irq, 1'b0);

    reg_read(VREG_CONFIG_GENERATION, gen0);
    @(negedge clk);
    cfg_display_event = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cfg_display_event = 1'b0;
    reg_read(VREG_INTERRUPT_STATUS, r);
    expect_eq("config irq bit", r, 32'h2);
    reg_read(VCFG_EVENTS_READ, r);
    expect_eq("display event", r, VGPU_EVENT_DISPLAY);
    reg_read(VREG_CONFIG_GENERATION, r);
    expect_eq("config generation", r, gen0 + 32'd1);
    reg_write(VREG_INTERRUPT_ACK, 32'h2);

    reg_write(VREG_QUEUE_SEL, 32'h0);
    reg_write(VREG_QUEUE_RESET, 32'h1);
    reg_read(VREG_QUEUE_RESET, r);
    expect_eq("queue0 reset ready", vq_state[0].ready, 1'b0);
    expect_eq("queue0 reset num", vq_state[0].num, 16'h0);

    reg_write(VREG_STATUS, 32'h0);
    @(posedge clk);
    expect_bit("firmware reset pulse", fw_reset_pulse);
    reg_read(VREG_STATUS, r);
    expect_eq("device reset status", r, 32'h0);
    expect_eq("queues cleared", {vq_state[1].ready, vq_state[0].ready}, 2'b00);
    reg_read(VREG_DRIVER_FEAT_SEL, r);
    expect_eq("driver sel reset", r, 32'h0);

    // Unsupported virgl bit must fail FEATURES_OK, not be silently accepted.
    reg_write(VREG_STATUS, 32'h1);
    reg_write(VREG_STATUS, 32'h3);
    reg_write(VREG_DRIVER_FEAT_SEL, 32'd1);
    reg_write(VREG_DRIVER_FEATURES, 32'h1);
    reg_write(VREG_DRIVER_FEAT_SEL, 32'd0);
    reg_write(VREG_DRIVER_FEATURES, 32'h1);
    reg_write(VREG_STATUS, VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER |
              VSTATUS_FEATURES_OK);
    reg_read(VREG_STATUS, r);
    expect_eq("unsupported feature rejected", r, 32'h3);
    reg_write(VREG_STATUS, 32'h0);

    // QueueNum above the configured depth is a protocol violation and raises
    // DEVICE_NEEDS_RESET rather than clamping the ring size.
    reg_write(VREG_QUEUE_SEL, 32'h0);
    reg_write(VREG_QUEUE_NUM, 32'd80);
    reg_read(VREG_STATUS, r);
    expect_eq("bad queue needs reset", r, VSTATUS_DEVICE_NEEDS_RESET);
    reg_write(VREG_STATUS, 32'h0);

    reg_write(16'h0ac, 32'd7);
    reg_read(16'h0b0, r);
    expect_eq("absent SHM length low", r, 32'hffff_ffff);
    reg_read(16'h0b4, r);
    expect_eq("absent SHM length high", r, 32'hffff_ffff);
    reg_read(16'h0b8, r);
    expect_eq("absent SHM base low", r, 32'hffff_ffff);
    reg_read(16'h0bc, r);
    expect_eq("absent SHM base high", r, 32'hffff_ffff);

    negotiate_transport();
    program_queue(0, 64'h1_8001_0000, 64'h2_8001_1000, 64'h3_8001_2000);
    expect_eq("64-bit descriptor address", vq_state[0].desc, 64'h1_8001_0000);
    reg_read(VREG_QUEUE_RESET, r);
    expect_eq("ready is not resetting", r, 32'h0);
    reg_write(VREG_STATUS, 32'hf);
    used_qid = 32'd1;
    #1;
    expect_eq("unready queue cannot complete", used_ready, 1'b0);
    reg_write(VREG_QUEUE_READY, 32'h0);
    reg_read(VREG_QUEUE_READY, r);
    expect_eq("QueueReady zero stops queue", r, 32'h0);
    used_qid = 32'd0;
    #1;
    expect_eq("stopped queue cannot complete", used_ready, 1'b0);
    reg_write(VREG_QUEUE_RESET, 32'h1);
    reg_read(VREG_QUEUE_RESET, r);
    expect_eq("queue reset finishes", r, 32'h0);
    program_queue(0, 64'h8002_0000, 64'h8002_1000, 64'h8002_2000);
    expect_eq("queue re-enabled with DRIVER_OK", vq_state[0].ready, 1'b1);
    reg_read(VREG_STATUS, r);
    expect_eq("queue reset does not require device reset", r, 32'hf);
    reg_write(VREG_STATUS, 32'h8f);
    #1;
    expect_eq("FAILED blocks completion", used_ready, 1'b0);
    reg_write(VREG_QUEUE_NOTIFY, 32'h0);
    expect_eq("FAILED blocks notification", notify_pending, 2'b00);
    reg_write(VREG_STATUS, 32'h0);

    negotiate_transport();
    reg_write(VREG_QUEUE_NUM, 32'd3);
    reg_read(VREG_STATUS, r);
    expect_bit("non-power-of-two queue rejected", (r & 32'h40) != 0);
    expect_eq("bad queue size not committed", vq_state[0].num, 16'h0);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    program_queue(0, 64'h8001_0001, 64'h8001_1000, 64'h8001_2000);
    expect_eq("misaligned descriptor rejected", vq_state[0].ready, 1'b0);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    program_queue(0, 64'h8001_0000, 64'h8001_1001, 64'h8001_2000);
    expect_eq("misaligned available ring rejected", vq_state[0].ready, 1'b0);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    program_queue(0, 64'h8001_0000, 64'h8001_1000, 64'h8001_2002);
    expect_eq("misaligned used ring rejected", vq_state[0].ready, 1'b0);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    program_queue(0, 64'hffff_ffff_ffff_fff0, 64'h8001_1000, 64'h8001_2000);
    expect_eq("descriptor extent overflow rejected", vq_state[0].ready, 1'b0);
    reg_write(VREG_STATUS, 32'h0);

    negotiate_transport();
    program_queue(0, 64'h8001_0000, 64'h8001_1000, 64'h8001_2000);
    reg_write(VREG_QUEUE_NOTIFY, 32'h0);
    expect_eq("pre DRIVER_OK notification blocked", notify_pending, 2'b00);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    program_queue(0, 64'h8001_0000, 64'h8001_1000, 64'h8001_2000);
    reg_write(VREG_STATUS, 32'hf);
    reg_write(VREG_QUEUE_NUM, 32'd8);
    reg_read(VREG_INTERRUPT_STATUS, r);
    expect_eq("NEEDS_RESET configuration interrupt", r, 32'h2);
    #1;
    expect_eq("NEEDS_RESET blocks completion", used_ready, 1'b0);
    reg_write(VREG_STATUS, 32'h0);
    negotiate_transport();
    reg_write(VREG_STATUS, 32'h1);
    reg_read(VREG_STATUS, r);
    expect_eq("status cannot clear negotiated bits", r, 32'h4b);
    reg_write(VREG_STATUS, 32'h0);

    begin
      apu_cfg_t cfg;
      config_pkg::cva6_cfg_t core_cfg;
      cfg = ApuP1Transport;
      core_cfg = config_pkg::cva6_cfg_t'(1'b0);
      core_cfg.NrCores = 1;
      core_cfg.NrHarts = 1;
      expect_bit("off config legal", apu_cfg_legal(ApuOff));
      expect_bit("transport config legal", apu_soc_legal(cfg, core_cfg));
      for (int matrix_en = 0; matrix_en < 2; matrix_en++) begin
        for (int issue_ports = 1; issue_ports <= 2; issue_ports++) begin
          core_cfg.AiCfg.MatrixEn = 1'(matrix_en);
          core_cfg.NrIssuePorts = issue_ports;
          expect_bit("APU legality independent of AI and issue width",
                     apu_soc_legal(cfg, core_cfg));
        end
      end
      for (int depth = 0; depth <= 2048; depth++) begin
        bit legal_depth;
        cfg.QueueDepth = depth;
        legal_depth = 1'b0;
        for (int bit_idx = 3; bit_idx <= 10; bit_idx++)
          if (depth == (1 << bit_idx)) legal_depth = 1'b1;
        expect_eq("configured depth legality", apu_cfg_legal(cfg), legal_depth);
      end
      cfg = ApuP1Transport;
      expect_bit("virgl grant illegal", !apu_cfg_legal(ApuBadVirglGrant));
      cfg.ControlBase = cfg.MmioBase;
      expect_bit("private and public apertures must not overlap", !apu_cfg_legal(cfg));
      cfg = ApuP1Transport;
      cfg.ControlLength = 0;
      expect_bit("private aperture must exist", !apu_cfg_legal(cfg));
      cfg = ApuP1Transport;
      cfg.ControlBase += 1;
      expect_bit("private aperture alignment enforced", !apu_cfg_legal(cfg));
      cfg = ApuP1Transport;
      cfg.ControlBase = 64'h9000_0000;
      cfg.FirmwareRamBase = 64'h9000_0000;
      cfg.FirmwareRamBytes = 64'h40000;
      cfg.FirmwareHart = 1;
      expect_bit("private RAM must not overlap control", !apu_cfg_legal(cfg));
      cfg = ApuP1Transport;
      cfg.NumScanouts = 1;
      expect_bit("unimplemented scanout illegal", !apu_cfg_legal(cfg));
      cfg = ApuP1Transport;
      cfg.FirmwareHart = 1;
      cfg.FirmwareRamBase = 64'h9000_0000;
      cfg.FirmwareRamBytes = 64'h40000;
      expect_bit("single physical core refused", !apu_soc_legal(cfg, core_cfg));
      core_cfg.NrHarts = 2;
      expect_bit("SMT sibling is not a service core", !apu_soc_legal(cfg, core_cfg));
      core_cfg.NrCores = 2;
      core_cfg.NrHarts = 1;
      expect_bit("separate physical core permitted", apu_soc_legal(cfg, core_cfg));
      cfg.FirmwareHart = 2;
      expect_bit("out of range service hart refused", !apu_soc_legal(cfg, core_cfg));
      expect_bit("64-bit non-power-of-two length refused",
                 !addr_aligned(64'h0, 64'h1_0000_1000));
    end

    negotiate_transport();
    program_queue(0, 64'h8001_0000, 64'h8001_1000, 64'h8001_2000);
    program_queue(1, 64'h8001_4000, 64'h8001_5000, 64'h8001_6000);
    reg_write(VREG_STATUS, 32'hf);
    reg_write(VREG_QUEUE_SEL, 32'h0);
    fw_queue_stop_ack = 2'b10;
    reg_write(VREG_QUEUE_RESET, 32'h1);
    repeat (4) begin
      reg_read(VREG_QUEUE_RESET, r);
      expect_eq("queue reset waits for backend", r, 32'h1);
      expect_eq("queue reset request held", fw_queue_stop_req, 2'b01);
      expect_eq("other queue remains enabled", queue_enable, 2'b10);
      expect_eq("reset preserves mapping until drain", vq_state[0].desc, 64'h8001_0000);
    end
    used_qid = 32'd0;
    used_valid = 1'b1;
    used_fence = 64'hffff_ffff_0000_0001;
    #1;
    expect_eq("stale completion blocked while resetting", used_ready, 1'b0);
    @(negedge clk);
    used_valid = 1'b0;
    fw_queue_stop_ack = '1;
    reg_read(VREG_QUEUE_RESET, r);
    expect_eq("queue reset acknowledged", r, 32'h0);
    expect_eq("mapping released after drain", vq_state[0].desc, 64'h0);
    program_queue(0, 64'h8002_0000, 64'h8002_1000, 64'h8002_2000);

    fw_queue_stop_ack = 2'b10;
    reg_write(VREG_QUEUE_READY, 32'h0);
    @(negedge clk);
    req = 1'b1;
    we = 1'b0;
    addr = VREG_QUEUE_READY;
    repeat (4) begin
      @(posedge clk);
      #1;
      expect_eq("QueueReady read synchronizes with drain", rvalid, 1'b0);
      expect_eq("stopped queue disabled immediately", queue_enable, 2'b10);
    end
    @(negedge clk);
    fw_queue_stop_ack = '1;
    @(posedge clk);
    #1;
    expect_eq("QueueReady read released after drain", rvalid, 1'b1);
    expect_eq("QueueReady synchronized value", rdata, 32'h0);
    @(negedge clk);
    req = 1'b0;
    reg_write(VREG_QUEUE_READY, 32'h1);
    expect_eq("stop preserves configuration for resume", queue_enable, 2'b11);

    @(negedge clk);
    fw_notify_clear = 2'b01;
    reg_write(VREG_QUEUE_NOTIFY, 32'h0);
    expect_eq("new notify wins simultaneous clear", notify_pending, 2'b01);
    fw_notify_clear = '0;
    @(negedge clk);
    used_valid = 1'b1;
    used_qid = 32'd0;
    used_fence = 64'hffff_ffff_ffff_ffff;
    used_len = 32'hffff_ffff;
    req = 1'b1;
    we = 1'b1;
    addr = VREG_INTERRUPT_ACK;
    wdata = 32'h3;
    cfg_display_event = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req = 1'b0;
    we = 1'b0;
    used_valid = 1'b0;
    cfg_display_event = 1'b0;
    reg_read(VREG_INTERRUPT_STATUS, r);
    expect_eq("new interrupts win simultaneous ACK", r, 32'h3);
    expect_eq("maximum fence retained", last_used_fence, 64'hffff_ffff_ffff_ffff);
    expect_eq("maximum length retained", last_used_len, 32'hffff_ffff);
    reg_read(VREG_CONFIG_GENERATION, gen0);
    reg_write(VCFG_EVENTS_CLEAR, 32'h1);
    reg_read(VCFG_EVENTS_READ, r);
    expect_eq("event cleared", r, 32'h0);
    reg_read(VREG_CONFIG_GENERATION, r);
    expect_eq("event clear changes generation", r, gen0 + 32'd1);
    reg_write(VREG_INTERRUPT_ACK, 32'h3);

    fw_reset_ack = 1'b0;
    @(negedge clk);
    used_valid = 1'b1;
    used_fence = 64'h0;
    req = 1'b1;
    we = 1'b1;
    addr = VREG_STATUS;
    wdata = 32'h0;
    #1;
    expect_eq("reset write blocks same-cycle completion", used_ready, 1'b0);
    @(posedge clk);
    @(negedge clk);
    req = 1'b0;
    we = 1'b0;
    repeat (4) begin
      reg_read(VREG_STATUS, r);
      expect_bit("device status nonzero until reset ACK", r != 0);
      expect_eq("device reset request held", fw_reset_req, 1'b1);
      expect_eq("device reset blocks all queues", queue_enable, 2'b00);
      expect_eq("device reset blocks completions", used_ready, 1'b0);
      expect_eq("reset cannot publish stale fence", last_used_fence, 64'hffff_ffff_ffff_ffff);
    end
    @(negedge clk);
    used_valid = 1'b0;
    fw_reset_ack = 1'b1;
    reg_read(VREG_STATUS, r);
    expect_eq("device reset completed after ACK", r, 32'h0);
    expect_eq("device reset request released", fw_reset_req, 1'b0);
    expect_eq("device reset clears metadata", last_used_fence, 64'h0);
    expect_eq("device reset clears context", last_used_context, 32'h0);

    reg_write(VREG_QUEUE_SEL, 32'hffff_ffff);
    reg_read(VREG_QUEUE_NUM_MAX, r);
    expect_eq("unknown queue does not alias queue zero", r, 32'h0);
    reg_write(VREG_DEVICE_FEAT_SEL, 32'hffff_ffff);
    reg_read(VREG_DEVICE_FEATURES, r);
    expect_eq("unknown feature selector returns zero", r, 32'h0);
    @(negedge clk);
    req = 1'b1;
    we = 1'b1;
    addr = VREG_QUEUE_SEL;
    wdata = 0;
    wstrb = 4'h1;
    #1;
    expect_bit("partial register write errors", error);
    @(posedge clk);
    @(negedge clk);
    addr = VREG_STATUS + 16'd1;
    wstrb = 4'hf;
    #1;
    expect_bit("misaligned register write errors", error);
    @(posedge clk);
    @(negedge clk);
    req = 1'b0;
    we = 1'b0;
    reg_read(VREG_QUEUE_SEL, r);
    expect_eq("partial write did not mutate selector", r, 32'hffff_ffff);
    reg_read(VREG_STATUS, r);
    expect_eq("invalid bus access did not mutate status", r, 32'h0);

    for (int n = 0; n < 2048; n++) begin
      apu_vq_state_t vq;
      bit valid_size;
      vq = '0;
      vq.num = 16'(n);
      vq.desc = 64'h8001_0000;
      vq.avail = 64'h8002_0000;
      vq.used = 64'h8003_0000;
      valid_size = 1'b0;
      for (int bit_idx = 0; bit_idx < 16; bit_idx++)
        if (n == (1 << bit_idx)) valid_size = 1'b1;
      expect_eq("queue geometry size sweep", apu_queue_cfg_ok(vq), valid_size);
    end

    if (errors == 0) begin
      $display("PASS tb_g6lc_apu_virtio_mmio cycles=%0d checks=%0d errors=%0d",
               cycles, checks, errors);
      $finish;
    end else begin
      $fatal(1, "tb_g6lc_apu_virtio_mmio errors=%0d", errors);
    end
  end
endmodule
