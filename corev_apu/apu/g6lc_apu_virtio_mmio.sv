// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// P1 APU virtio-mmio transport block.
//
// This module owns only the guest-visible register and queue state: modern
// feature negotiation, control/cursor queue programming, reset, notifyPending
// handoff, used-buffer interrupts and the static virtio_gpu_config words.
// Command decode, resource lifetime and virgl semantics are deliberately in the
// protected firmware seam; datapath/DMA execution is a separate APU block.

// Interplay: guest ==> QueueNotify / PFN / ISR. Backend used-ring is a separate port. See AGENTS-impl-interplays.md.
module g6lc_apu_virtio_mmio
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
#(
    parameter apu_cfg_t     ApuCfg   = ApuP1Transport,
    parameter int unsigned  AddrWidth = 16
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,

    // One-cycle register port. AXI/APB adapters live at the SoC boundary.
    input  logic                    req_i,
    input  logic                    we_i,
    input  logic [AddrWidth-1:0]    addr_i,
    input  logic [31:0]             wdata_i,
    input  logic [3:0]              wstrb_i,
    output logic [31:0]             rdata_o,
    output logic                    rvalid_o,
    output logic                    error_o,

    output logic                    irq_o,

    // Protected command-firmware seam. Queue addresses/counts are observable;
    // notify bits are set by the guest and explicitly consumed by firmware.
    output apu_vq_state_t           vq_state_o [APU_NUM_QUEUES],
    output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
    output logic [APU_NUM_QUEUES-1:0] notify_pending_o,
    input  logic [APU_NUM_QUEUES-1:0] fw_notify_clear_i,
    output logic                    fw_reset_pulse_o,
    output logic                    fw_reset_req_o,
    input  logic                    fw_reset_ack_i,
    output logic [APU_NUM_QUEUES-1:0] fw_queue_stop_req_o,
    input  logic [APU_NUM_QUEUES-1:0] fw_queue_stop_ack_i,

    // Firmware reports a used-buffer completion here. Fence/context metadata is
    // kept full width for observability even though P1 does not yet DMA the
    // used-ring entry itself.
    input  logic                    used_valid_i,
    input  logic [31:0]             used_qid_i,
    input  logic [31:0]             used_context_i,
    input  logic [63:0]             used_fence_i,
    input  logic [31:0]             used_len_i,
    output logic                    used_ready_o,
    output logic [31:0]             last_used_qid_o,
    output logic [31:0]             last_used_context_o,
    output logic [63:0]             last_used_fence_o,
    output logic [31:0]             last_used_len_o,

    // Display/config event from the future scanout adapter.
    input  logic                    cfg_display_event_i,

    output logic [31:0]             debug_status_o
);

  localparam int unsigned NumQueues = APU_NUM_QUEUES;
  localparam int unsigned QidWidth = (NumQueues > 1) ? $clog2(NumQueues) : 1;
  localparam logic [63:0] DeviceFeatures = apu_device_features(ApuCfg);
  localparam bit ShmEn = ApuCfg.ShmEn;

  // pragma translate_off
  initial begin
    assert (ApuCfg.Enable && apu_cfg_legal(ApuCfg))
      else $fatal(1, "g6lc_apu_virtio_mmio: illegal or over-granted APU config");
    assert (AddrWidth >= 12 && AddrWidth <= 64)
      else $fatal(1, "g6lc_apu_virtio_mmio: unsupported address width");
  end
  for (genvar q = 0; q < NumQueues; q++) begin : gen_queue_assert
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        queue_enable_o[q] |-> vq_q[q].ready && !stop_pending_q[q] && device_live);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        reset_pending_q |-> !queue_enable_o[q]);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        vq_q[q].ready && !reset_pending_q && !dev_reset && !queue_stop_sel
        |=> $stable(vq_q[q].desc) && $stable(vq_q[q].avail) &&
            $stable(vq_q[q].used) && $stable(vq_q[q].num));
  end
  // pragma translate_on

  apu_vq_state_t vq_q [NumQueues];
  logic [NumQueues-1:0] notify_pending_q;
  logic [NumQueues-1:0] stop_pending_q, queue_reset_pending_q;
  logic [7:0] status_q;
  logic needs_reset_q, reset_pending_q;
  logic [63:0] driver_features_q;
  logic [31:0] device_features_sel_q, driver_features_sel_q, queue_sel_q;
  logic [1:0] irq_status_q;
  logic [31:0] cfg_generation_q, events_read_q;
  logic [31:0] last_used_qid_q, last_used_context_q, last_used_len_q;
  logic [63:0] last_used_fence_q;

  logic req_write, req_read, dev_reset, invalid_access, invalid_status;
  logic device_live, config_writable, queue_writable, ring_reset_enabled;
  logic queue_stop_sel, queue_reset_sel, qsel_valid;
  logic [7:0] status_next;
  logic [QidWidth-1:0] qsel_idx;
  logic [NumQueues-1:0] notify_set;
  logic [1:0] irq_ack, irq_set;
  logic [31:0] events_clear;
  logic [31:0] read_data;
  logic stop_read_wait;
  logic [31:0] shm_sel;
  logic shm_host;

  assign req_write = req_i && we_i && (wstrb_i == 4'hf) &&
                     (addr_i[1:0] == 2'b00) && !reset_pending_q && rst_ni;
  assign req_read = req_i && !we_i && (addr_i[1:0] == 2'b00);
  assign stop_read_wait = req_read && addr_i == AddrWidth'(VREG_QUEUE_READY) &&
                          qsel_valid && stop_pending_q[qsel_idx];
  assign rvalid_o = req_i && !stop_read_wait;
  assign error_o = req_i && ((addr_i[1:0] != 2'b00) ||
                            (we_i && (wstrb_i != 4'hf)));
  assign rdata_o = rvalid_o ? read_data : 32'h0;
  assign qsel_valid = queue_sel_q < NumQueues;
  assign qsel_idx = qsel_valid ? queue_sel_q[QidWidth-1:0] : '0;
  assign ring_reset_enabled = (status_q & VSTATUS_FEATURES_OK) != 0 &&
                              driver_features_q[VIRTIO_F_RING_RESET_BIT];
  assign dev_reset = req_write && addr_i == AddrWidth'(VREG_STATUS) && wdata_i == 0;
  assign config_writable = (status_q & VSTATUS_FEATURES_OK) != 0 &&
                           (status_q & VSTATUS_FAILED) == 0 && !needs_reset_q;
  assign queue_writable = qsel_valid && config_writable &&
                          !vq_q[qsel_idx].ready && !stop_pending_q[qsel_idx];
  assign queue_reset_sel = req_write && addr_i == AddrWidth'(VREG_QUEUE_RESET) &&
                           wdata_i == 1 && ring_reset_enabled && qsel_valid;
  assign queue_stop_sel = queue_reset_sel ||
                         (req_write && addr_i == AddrWidth'(VREG_QUEUE_READY) &&
                          wdata_i == 0 && qsel_valid);
  assign device_live = rst_ni && (status_q & VSTATUS_DRIVER_OK) != 0 &&
                       (status_next & VSTATUS_FAILED) == 0 && !needs_reset_q &&
                       !reset_pending_q && !dev_reset;
  for (genvar q = 0; q < NumQueues; q++) begin : gen_queue_enable
    assign queue_enable_o[q] = device_live && vq_q[q].ready &&
                               !stop_pending_q[q] && !invalid_access &&
                               !(queue_stop_sel && qsel_idx == QidWidth'(q));
  end
  assign used_ready_o = (used_qid_i < NumQueues) &&
                        queue_enable_o[used_qid_i[QidWidth-1:0]];
  assign irq_o = |irq_status_q;
  assign vq_state_o = vq_q;
  assign notify_pending_o = notify_pending_q & queue_enable_o;
  assign fw_reset_req_o = reset_pending_q;
  assign fw_queue_stop_req_o = stop_pending_q;
  assign last_used_qid_o = last_used_qid_q;
  assign last_used_context_o = last_used_context_q;
  assign last_used_fence_o = last_used_fence_q;
  assign last_used_len_o = last_used_len_q;
  assign debug_status_o = {24'h0, apu_status_read(status_q, needs_reset_q || reset_pending_q)};
  assign irq_ack = req_write && addr_i == AddrWidth'(VREG_INTERRUPT_ACK) ? wdata_i[1:0] : 2'b00;
  assign events_clear = req_write && addr_i == AddrWidth'(VCFG_EVENTS_CLEAR) ? wdata_i : 32'h0;
  assign irq_set[0] = used_valid_i && used_ready_o;
  assign irq_set[1] = ((status_q & VSTATUS_DRIVER_OK) != 0) &&
                      ((invalid_access && !needs_reset_q) || cfg_display_event_i);
  assign shm_host = ShmEn && (shm_sel == APU_SHM_ID_HOST_VISIBLE);

  if (ShmEn) begin : gen_shm
    logic [31:0] shm_sel_q;
    assign shm_sel = shm_sel_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) shm_sel_q <= '0;
      else if (dev_reset) shm_sel_q <= '0;
      else if (req_write && !invalid_access &&
               addr_i == AddrWidth'(VREG_SHM_SEL))
        shm_sel_q <= wdata_i;
    end
  end else begin : gen_shm_off
    assign shm_sel = 32'h0;
  end

  always_comb begin
    read_data = 32'h0;
    if (req_read) begin
      unique case (addr_i)
        AddrWidth'(VREG_MAGIC): read_data = VIRTIO_MMIO_MAGIC;
        AddrWidth'(VREG_VERSION): read_data = VIRTIO_MMIO_VERSION2;
        AddrWidth'(VREG_DEVICE_ID): read_data = VIRTIO_DEVICE_GPU;
        AddrWidth'(VREG_VENDOR_ID): read_data = G6LC_VIRTIO_VENDOR;
        AddrWidth'(VREG_DEVICE_FEATURES): begin
          if (device_features_sel_q == 0) read_data = DeviceFeatures[31:0];
          else if (device_features_sel_q == 1) read_data = DeviceFeatures[63:32];
        end
        AddrWidth'(VREG_DEVICE_FEAT_SEL): read_data = device_features_sel_q;
        AddrWidth'(VREG_DRIVER_FEATURES): begin
          if (driver_features_sel_q == 0) read_data = driver_features_q[31:0];
          else if (driver_features_sel_q == 1) read_data = driver_features_q[63:32];
        end
        AddrWidth'(VREG_DRIVER_FEAT_SEL): read_data = driver_features_sel_q;
        AddrWidth'(VREG_QUEUE_SEL): read_data = queue_sel_q;
        AddrWidth'(VREG_QUEUE_NUM_MAX):
          if (qsel_valid) read_data = ApuCfg.QueueDepth;
        AddrWidth'(VREG_QUEUE_NUM):
          if (qsel_valid) read_data = {16'h0, vq_q[qsel_idx].num};
        AddrWidth'(VREG_QUEUE_READY):
          if (qsel_valid) read_data = {31'h0, vq_q[qsel_idx].ready};
        AddrWidth'(VREG_INTERRUPT_STATUS): read_data = {30'h0, irq_status_q};
        AddrWidth'(VREG_STATUS): read_data = debug_status_o;
        AddrWidth'(VREG_QUEUE_DESC_LO):
          if (qsel_valid) read_data = vq_q[qsel_idx].desc[31:0];
        AddrWidth'(VREG_QUEUE_DESC_HI):
          if (qsel_valid) read_data = vq_q[qsel_idx].desc[63:32];
        AddrWidth'(VREG_QUEUE_AVAIL_LO):
          if (qsel_valid) read_data = vq_q[qsel_idx].avail[31:0];
        AddrWidth'(VREG_QUEUE_AVAIL_HI):
          if (qsel_valid) read_data = vq_q[qsel_idx].avail[63:32];
        AddrWidth'(VREG_QUEUE_USED_LO):
          if (qsel_valid) read_data = vq_q[qsel_idx].used[31:0];
        AddrWidth'(VREG_QUEUE_USED_HI):
          if (qsel_valid) read_data = vq_q[qsel_idx].used[63:32];
        AddrWidth'(VREG_SHM_SEL): read_data = shm_sel;
        AddrWidth'(VREG_SHM_LEN_LO):
          read_data = shm_host ? APU_SHM_BYTES[31:0] : 32'hffff_ffff;
        AddrWidth'(VREG_SHM_LEN_HI):
          read_data = shm_host ? APU_SHM_BYTES[63:32] : 32'hffff_ffff;
        AddrWidth'(VREG_SHM_BASE_LO):
          read_data = shm_host ? APU_SHM_BASE[31:0] : 32'hffff_ffff;
        AddrWidth'(VREG_SHM_BASE_HI):
          read_data = shm_host ? APU_SHM_BASE[63:32] : 32'hffff_ffff;
        AddrWidth'(VREG_QUEUE_RESET):
          if (qsel_valid && ring_reset_enabled)
            read_data = {31'h0, queue_reset_pending_q[qsel_idx]};
        AddrWidth'(VREG_CONFIG_GENERATION): read_data = cfg_generation_q;
        AddrWidth'(VCFG_EVENTS_READ): read_data = events_read_q;
        AddrWidth'(VCFG_NUM_SCANOUTS): read_data = ApuCfg.NumScanouts;
        AddrWidth'(VCFG_NUM_CAPSETS): read_data = ApuCfg.NumCapsets;
        default: ;
      endcase
    end
  end

  always_comb begin
    status_next = status_q;
    invalid_status = 1'b0;
    if (req_write && !dev_reset && addr_i == AddrWidth'(VREG_STATUS)) begin
      status_next = wdata_i[7:0] & VSTATUS_DRIVER_MASK;
      if ((status_q & ~status_next) != 0 ||
          ((status_next & VSTATUS_DRIVER) != 0 &&
           (status_next & VSTATUS_ACKNOWLEDGE) == 0) ||
          ((status_next & VSTATUS_FEATURES_OK) != 0 &&
           (status_next & (VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER)) !=
           (VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER)) ||
          ((status_next & VSTATUS_DRIVER_OK) != 0 &&
           (status_q & VSTATUS_FEATURES_OK) == 0)) begin
        invalid_status = 1'b1;
        status_next = status_q;
      end else if ((status_next & VSTATUS_FEATURES_OK) != 0 &&
                   !apu_features_accepted(ApuCfg, driver_features_q))
        status_next &= ~(VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK);
    end
  end

  always_comb begin
    notify_set = '0;
    invalid_access = invalid_status;
    if (req_write && !dev_reset) begin
      unique case (addr_i)
        AddrWidth'(VREG_DRIVER_FEATURES):
          invalid_access = (status_q & (VSTATUS_FEATURES_OK | VSTATUS_DRIVER_OK |
                                       VSTATUS_FAILED)) != 0 || needs_reset_q ||
                           (status_q & VSTATUS_DRIVER) == 0 ||
                           (driver_features_sel_q > 1 && wdata_i != 0);
        AddrWidth'(VREG_QUEUE_NUM):
          invalid_access = !queue_writable || !pow2(wdata_i) ||
                           wdata_i > ApuCfg.QueueDepth;
        AddrWidth'(VREG_QUEUE_DESC_LO), AddrWidth'(VREG_QUEUE_DESC_HI),
        AddrWidth'(VREG_QUEUE_AVAIL_LO), AddrWidth'(VREG_QUEUE_AVAIL_HI),
        AddrWidth'(VREG_QUEUE_USED_LO), AddrWidth'(VREG_QUEUE_USED_HI):
          invalid_access = !queue_writable;
        AddrWidth'(VREG_QUEUE_READY):
          invalid_access = !qsel_valid || wdata_i > 1 ||
                           (wdata_i == 1 && (!queue_writable ||
                            !apu_queue_cfg_ok(vq_q[qsel_idx])));
        AddrWidth'(VREG_QUEUE_NOTIFY): begin
          if (device_live && wdata_i < NumQueues &&
              vq_q[wdata_i[QidWidth-1:0]].ready &&
              !stop_pending_q[wdata_i[QidWidth-1:0]])
            notify_set[wdata_i[QidWidth-1:0]] = 1'b1;
          else invalid_access = 1'b1;
        end
        AddrWidth'(VREG_QUEUE_RESET):
          invalid_access = !qsel_valid || wdata_i > 1 ||
                           (wdata_i == 1 && !ring_reset_enabled);
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      for (int q = 0; q < NumQueues; q++) vq_q[q] <= '0;
      notify_pending_q <= '0;
      stop_pending_q <= '0;
      queue_reset_pending_q <= '0;
      reset_pending_q <= 1'b0;
      status_q <= '0;
      needs_reset_q <= 1'b0;
      driver_features_q <= '0;
      device_features_sel_q <= '0;
      driver_features_sel_q <= '0;
      queue_sel_q <= '0;
      irq_status_q <= '0;
      cfg_generation_q <= '0;
      events_read_q <= '0;
      last_used_qid_q <= '0;
      last_used_context_q <= '0;
      last_used_fence_q <= '0;
      last_used_len_q <= '0;
      fw_reset_pulse_o <= 1'b0;
    end else begin
      fw_reset_pulse_o <= dev_reset;
      if (dev_reset) begin
        reset_pending_q <= 1'b1;
        notify_pending_q <= '0;
      end else if (reset_pending_q) begin
        if (fw_reset_ack_i) begin
          for (int q = 0; q < NumQueues; q++) vq_q[q] <= '0;
          notify_pending_q <= '0;
          stop_pending_q <= '0;
          queue_reset_pending_q <= '0;
          reset_pending_q <= 1'b0;
          status_q <= '0;
          needs_reset_q <= 1'b0;
          driver_features_q <= '0;
          device_features_sel_q <= '0;
          driver_features_sel_q <= '0;
          queue_sel_q <= '0;
          irq_status_q <= '0;
          events_read_q <= '0;
          if (events_read_q != 0) cfg_generation_q <= cfg_generation_q + 32'd1;
          last_used_qid_q <= '0;
          last_used_context_q <= '0;
          last_used_fence_q <= '0;
          last_used_len_q <= '0;
        end
      end else begin
        if (req_write && !invalid_access) begin
          unique case (addr_i)
            AddrWidth'(VREG_DEVICE_FEAT_SEL): device_features_sel_q <= wdata_i;
            AddrWidth'(VREG_DRIVER_FEAT_SEL): driver_features_sel_q <= wdata_i;
            AddrWidth'(VREG_DRIVER_FEATURES): begin
              if (driver_features_sel_q == 0) driver_features_q[31:0] <= wdata_i;
              else if (driver_features_sel_q == 1) driver_features_q[63:32] <= wdata_i;
            end
            AddrWidth'(VREG_QUEUE_SEL): queue_sel_q <= wdata_i;
            AddrWidth'(VREG_SHM_SEL): ;
            AddrWidth'(VREG_QUEUE_NUM): vq_q[qsel_idx].num <= wdata_i[15:0];
            AddrWidth'(VREG_QUEUE_READY): vq_q[qsel_idx].ready <= wdata_i[0];
            AddrWidth'(VREG_QUEUE_DESC_LO): vq_q[qsel_idx].desc[31:0] <= wdata_i;
            AddrWidth'(VREG_QUEUE_DESC_HI): vq_q[qsel_idx].desc[63:32] <= wdata_i;
            AddrWidth'(VREG_QUEUE_AVAIL_LO): vq_q[qsel_idx].avail[31:0] <= wdata_i;
            AddrWidth'(VREG_QUEUE_AVAIL_HI): vq_q[qsel_idx].avail[63:32] <= wdata_i;
            AddrWidth'(VREG_QUEUE_USED_LO): vq_q[qsel_idx].used[31:0] <= wdata_i;
            AddrWidth'(VREG_QUEUE_USED_HI): vq_q[qsel_idx].used[63:32] <= wdata_i;
            AddrWidth'(VREG_STATUS): status_q <= status_next;
            default: ;
          endcase
        end
        if (invalid_access) needs_reset_q <= 1'b1;
        for (int q = 0; q < NumQueues; q++) begin
          if (stop_pending_q[q] && fw_queue_stop_ack_i[q]) begin
            stop_pending_q[q] <= 1'b0;
            queue_reset_pending_q[q] <= 1'b0;
            if (queue_reset_pending_q[q]) vq_q[q] <= '0;
          end
        end
        notify_pending_q <= (notify_pending_q & ~fw_notify_clear_i) | notify_set;
        if (queue_stop_sel) begin
          stop_pending_q[qsel_idx] <= 1'b1;
          if (queue_reset_sel) queue_reset_pending_q[qsel_idx] <= 1'b1;
          vq_q[qsel_idx].ready <= 1'b0;
          notify_pending_q[qsel_idx] <= 1'b0;
        end
        irq_status_q <= (irq_status_q & ~irq_ack) | irq_set;
        events_read_q <= (events_read_q & ~events_clear) |
                         (cfg_display_event_i ? VGPU_EVENT_DISPLAY : 32'h0);
        if (cfg_display_event_i || (events_read_q & events_clear) != 0)
          cfg_generation_q <= cfg_generation_q + 32'd1;
        if (used_valid_i && used_ready_o) begin
          last_used_qid_q <= used_qid_i;
          last_used_context_q <= used_context_i;
          last_used_fence_q <= used_fence_i;
          last_used_len_q <= used_len_i;
        end
      end
    end
  end

  // Preserve scan observability plumbing even though P1 has no internal clock
  // gate yet; later SRAM/execution blocks consume testmode_i directly.
  logic unused_testmode;
  assign unused_testmode = testmode_i;

endmodule
