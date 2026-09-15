// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Independently gated APU integration top. With ApuOff this is an inert register
// endpoint: no IRQ, DMA, queue or firmware activity. With ApuP1Transport it
// exposes the modern virtio-mmio transport state only; memory/execution blocks
// attach below this seam as their own gated units.

module g6lc_apu_top
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
#(
    parameter apu_cfg_t     ApuCfg   = ApuOff,
    parameter int unsigned  AddrWidth = 16
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,

    input  logic                    req_i,
    input  logic                    we_i,
    input  logic [AddrWidth-1:0]    addr_i,
    input  logic [31:0]             wdata_i,
    input  logic [3:0]              wstrb_i,
    output logic [31:0]             rdata_o,
    output logic                    rvalid_o,
    output logic                    error_o,

    output logic                    irq_o,

    output apu_vq_state_t           vq_state_o [APU_NUM_QUEUES],
    output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
    output logic [APU_NUM_QUEUES-1:0] notify_pending_o,
    input  logic [APU_NUM_QUEUES-1:0] fw_notify_clear_i,
    output logic                    fw_reset_pulse_o,
    output logic                    fw_reset_req_o,
    input  logic                    fw_reset_ack_i,
    output logic [APU_NUM_QUEUES-1:0] fw_queue_stop_req_o,
    input  logic [APU_NUM_QUEUES-1:0] fw_queue_stop_ack_i,

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

    input  logic                    cfg_display_event_i,
    output logic [31:0]             debug_status_o
);

  if (!ApuCfg.Enable) begin : gen_disabled
    for (genvar q = 0; q < APU_NUM_QUEUES; q++) begin : gen_vq_off
      assign vq_state_o[q] = '0;
    end
    assign rdata_o           = 32'h0;
    assign rvalid_o          = req_i;
    assign error_o           = 1'b0;
    assign irq_o             = 1'b0;
    assign notify_pending_o  = '0;
    assign queue_enable_o    = '0;
    assign fw_queue_stop_req_o = '0;
    assign fw_reset_req_o    = 1'b0;
    assign fw_reset_pulse_o  = 1'b0;
    assign last_used_context_o = '0;
    assign used_ready_o      = 1'b0;
    assign last_used_qid_o   = 32'h0;
    assign last_used_fence_o = 64'h0;
    assign last_used_len_o   = 32'h0;
    assign debug_status_o    = 32'h0;

    logic unused_inputs;
    assign unused_inputs = clk_i & rst_ni & testmode_i & we_i &
                           (|addr_i) & (|wdata_i) & (|wstrb_i) &
                           (|fw_notify_clear_i) & used_valid_i &
                           (|used_qid_i) & (|used_fence_i) &
                           (|used_len_i) & cfg_display_event_i &
                           (|used_context_i) & fw_reset_ack_i & (|fw_queue_stop_ack_i);
  end else begin : gen_enabled
    g6lc_apu_virtio_mmio #(
        .ApuCfg   (ApuCfg),
        .AddrWidth(AddrWidth)
    ) i_transport (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .req_i,
        .we_i,
        .addr_i,
        .wdata_i,
        .wstrb_i,
        .rdata_o,
        .rvalid_o,
        .error_o,
        .irq_o,
        .vq_state_o,
        .queue_enable_o,
        .notify_pending_o,
        .fw_notify_clear_i,
        .fw_reset_pulse_o,
        .fw_reset_req_o,
        .fw_reset_ack_i,
        .fw_queue_stop_req_o,
        .fw_queue_stop_ack_i,
        .used_context_i,
        .last_used_context_o,
        .used_valid_i,
        .used_qid_i,
        .used_fence_i,
        .used_len_i,
        .used_ready_o,
        .last_used_qid_o,
        .last_used_fence_o,
        .last_used_len_o,
        .cfg_display_event_i,
        .debug_status_o
    );
  end

endmodule
