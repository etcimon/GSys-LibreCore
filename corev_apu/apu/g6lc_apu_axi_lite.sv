// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Interplay: ApuSys --> AxiLiteTransport --> VirtioTop + ApuControl. See AGENTS-impl-interplays.md.
module g6lc_apu_axi_lite
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff,
  parameter config_pkg::cva6_cfg_t CoreCfg = config_pkg::cva6_cfg_t'(0),
  parameter type axi_req_t = apu_axi_req_t,
  parameter type axi_rsp_t = apu_axi_resp_t
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input axi_req_t guest_req_i,
  output axi_rsp_t guest_rsp_o,
  input axi_req_t control_req_i,
  output axi_rsp_t control_rsp_o,
  input logic control_aw_authorized_i,
  input logic control_ar_authorized_i,
  output logic guest_irq_o,
  output logic control_irq_o,
  output apu_vq_state_t vq_state_o [APU_NUM_QUEUES],
  output logic [APU_NUM_QUEUES-1:0] queue_enable_o,
  output logic backend_reset_req_o,
  output logic [APU_NUM_QUEUES-1:0] backend_queue_stop_req_o,
  input logic backend_reset_done_i,
  input logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  input logic used_valid_i,
  input logic [31:0] used_qid_i,
  input logic [31:0] used_context_i,
  input logic [63:0] used_fence_i,
  input logic [31:0] used_len_i,
  output logic used_ready_o,
  input logic cfg_display_event_i,
  // Protected mailbox window at ControlBase+0x80. Transport-only users
  // (APU_AXI=1) tie mbox_rsp_i to SLVERR so the existing control map is
  // unchanged. g6lc_apu_sys attaches the firmware backend here.
  output apu_reg_req_t mbox_req_o,
  input  apu_reg_rsp_t mbox_rsp_i,
  // When a hold is set, that port's AW/AR were admitted upstream. Stamp the
  // saved epoch instead of the live one. Direct lite masters leave both low.
  input  logic guest_hold_i,
  input  logic [31:0] guest_epoch_i,
  input  logic ctrl_hold_i,
  input  logic [31:0] ctrl_epoch_i,
  output logic [31:0] epoch_o,
  // §6c F1 Venus backend seam. Under ApuCfg.VenusEn the control block is
  // not elaborated and g6lc_apu_sys carries these handshakes straight to
  // g6lc_apu_vgsys: doorbell levels out, clears and reset/queue-stop
  // acknowledgments back in. Tied off for the firmware backends.
  output logic [APU_NUM_QUEUES-1:0] be_notify_pending_o,
  input  logic [APU_NUM_QUEUES-1:0] be_notify_clear_i,
  input  logic                      be_reset_ack_i,
  input  logic [APU_NUM_QUEUES-1:0] be_queue_stop_ack_i
);
  apu_tagged_axi_req_t tagged_req [2];
  apu_tagged_axi_resp_t tagged_rsp [2];
  apu_tagged_reg_req_t reg_req [2];
  apu_reg_rsp_t reg_rsp [2];
  logic [31:0] epoch;
  assign epoch_o = epoch;

  `ifndef SYNTHESIS
  initial begin
    assert (apu_soc_legal(ApuCfg, CoreCfg)) else $fatal(1, "APU AXI: illegal SoC configuration");
    assert (!ApuCfg.Enable || ApuCfg.VenusEn ||
            ApuCfg.FirmwareHart != APU_FW_HART_UNASSIGNED)
      else $fatal(1, "APU AXI: protected service hart must be assigned");
    assert ($bits(guest_req_i.aw.addr) == 64 && $bits(guest_req_i.w.data) == 32)
      else $fatal(1, "APU AXI: requires 64-bit address / 32-bit data AXI-Lite");
  end
  `endif

  for (genvar p = 0; p < 2; p++) begin : gen_bridge
    axi_req_t bus_req;
    logic aw_auth, ar_auth;
    logic [31:0] use_epoch;
    assign bus_req = p == 0 ? guest_req_i : control_req_i;
    assign use_epoch = (p == 0 ? guest_hold_i : ctrl_hold_i) ?
                       (p == 0 ? guest_epoch_i : ctrl_epoch_i) : epoch;
    assign aw_auth = p == 0 ? 1'b1 : control_aw_authorized_i;
    assign ar_auth = p == 0 ? 1'b1 : control_ar_authorized_i;
    always_comb begin
      tagged_req[p] = '0;
      tagged_req[p].aw.addr = {use_epoch, aw_auth, bus_req.aw.addr};
      tagged_req[p].aw.prot = bus_req.aw.prot;
      tagged_req[p].aw_valid = bus_req.aw_valid;
      tagged_req[p].w = bus_req.w;
      tagged_req[p].w_valid = bus_req.w_valid;
      tagged_req[p].b_ready = bus_req.b_ready;
      tagged_req[p].ar.addr = {use_epoch, ar_auth, bus_req.ar.addr};
      tagged_req[p].ar.prot = bus_req.ar.prot;
      tagged_req[p].ar_valid = bus_req.ar_valid;
      tagged_req[p].r_ready = bus_req.r_ready;
    end
    axi_lite_to_reg #(
      .ADDR_WIDTH(97), .DATA_WIDTH(32), .BUFFER_DEPTH(2), .DECOUPLE_W(1),
      .axi_lite_req_t(apu_tagged_axi_req_t), .axi_lite_rsp_t(apu_tagged_axi_resp_t),
      .reg_req_t(apu_tagged_reg_req_t), .reg_rsp_t(apu_reg_rsp_t)
    ) i_bridge (
      .clk_i, .rst_ni, .axi_lite_req_i(tagged_req[p]), .axi_lite_rsp_o(tagged_rsp[p]),
      .reg_req_o(reg_req[p]), .reg_rsp_i(reg_rsp[p])
    );
  end
  assign guest_rsp_o = tagged_rsp[0];
  assign control_rsp_o = tagged_rsp[1];

  if (!ApuCfg.Enable) begin : gen_off
    logic unused_mbox;
    assign unused_mbox = |mbox_rsp_i | (|be_notify_clear_i) | be_reset_ack_i |
                         (|be_queue_stop_ack_i);
    assign epoch = '0;
    for (genvar p = 0; p < 2; p++) begin : gen_resp
      assign reg_rsp[p] = '{rdata: '0, error: 1'b0, ready: reg_req[p].valid};
    end
    for (genvar q = 0; q < APU_NUM_QUEUES; q++) begin : gen_queue
      assign vq_state_o[q] = '0;
    end
    assign guest_irq_o = 1'b0;
    assign control_irq_o = 1'b0;
    assign queue_enable_o = '0;
    assign backend_reset_req_o = 1'b0;
    assign backend_queue_stop_req_o = '0;
    assign used_ready_o = 1'b0;
    assign mbox_req_o = '0;
    assign be_notify_pending_o = '0;
  end else begin : gen_on
    logic [31:0] epoch_q;
    logic epoch_exhausted_q, epoch_event;
    logic reset_prev_q;
    logic [APU_NUM_QUEUES-1:0] stop_prev_q;
    logic guest_hit, control_hit, control_allowed, epoch_valid, mbox_sel;
    apu_reg_req_t control_reg_req;
    apu_reg_rsp_t control_reg_rsp;
    logic [63:0] guest_offset;
    logic [APU_NUM_QUEUES-1:0] notify_pending, notify_clear, stop_ack;
    logic reset_ack, reset_pulse;
    logic [31:0] device_status, last_qid, last_context, last_len;
    logic [63:0] last_fence;
    logic [31:0] guest_data;
    logic guest_valid, guest_error, fw_irq;

    assign epoch_event = (backend_reset_req_o && !reset_prev_q) ||
                         (|(backend_queue_stop_req_o & ~stop_prev_q));
    assign epoch = epoch_q + 32'(epoch_event && !epoch_exhausted_q && epoch_q != 32'hffff_ffff);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        epoch_q <= '0;
        epoch_exhausted_q <= 1'b0;
        reset_prev_q <= 1'b0;
        stop_prev_q <= '0;
      end else begin
        reset_prev_q <= backend_reset_req_o;
        stop_prev_q <= backend_queue_stop_req_o;
        if (epoch_event && !epoch_exhausted_q) begin
          if (epoch_q == 32'hffff_ffff) epoch_exhausted_q <= 1'b1;
          else epoch_q <= epoch;
        end
      end
    end
    assign guest_offset = reg_req[0].addr[63:0] - ApuCfg.MmioBase;
    assign guest_hit = reg_req[0].addr[63:0] >= ApuCfg.MmioBase &&
                       guest_offset < ApuCfg.MmioLength;
    assign control_hit = reg_req[1].addr[63:0] >= ApuCfg.ControlBase &&
                         reg_req[1].addr[63:0] - ApuCfg.ControlBase < ApuCfg.ControlLength;
    assign epoch_valid = !epoch_exhausted_q && !(epoch_event && epoch_q == 32'hffff_ffff);
    assign control_allowed = control_hit && reg_req[1].addr[64] &&
                             reg_req[1].addr[96:65] == epoch && epoch_valid;
    assign mbox_sel = (reg_req[1].addr[63:0] - ApuCfg.ControlBase) >= 64'(ACTRL_MAIL_IDX) &&
                      (reg_req[1].addr[63:0] - ApuCfg.ControlBase) < 64'(ACTRL_MAIL_END);
    always_comb begin
      control_reg_req = '0;
      control_reg_req.addr = reg_req[1].addr[63:0] - ApuCfg.ControlBase;
      control_reg_req.write = reg_req[1].write;
      control_reg_req.wdata = reg_req[1].wdata;
      control_reg_req.wstrb = reg_req[1].wstrb;
      control_reg_req.valid = reg_req[1].valid && control_allowed && !mbox_sel;
      mbox_req_o = control_reg_req;
      mbox_req_o.valid = !ApuCfg.VenusEn && reg_req[1].valid &&
                         control_allowed && mbox_sel;
      reg_rsp[0] = '{rdata: '0, error: 1'b1, ready: reg_req[0].valid};
      if (guest_hit) reg_rsp[0] = '{rdata: guest_data, error: guest_error, ready: guest_valid};
      reg_rsp[1] = '{rdata: '0, error: 1'b1, ready: reg_req[1].valid};
      if (control_allowed && mbox_sel) reg_rsp[1] = mbox_rsp_i;
      else if (control_allowed) reg_rsp[1] = control_reg_rsp;
    end
    assign control_irq_o = fw_irq || epoch_exhausted_q;

    g6lc_apu_top #(.ApuCfg(ApuCfg), .AddrWidth(64)) i_apu (
      .clk_i, .rst_ni, .testmode_i,
      .req_i(reg_req[0].valid && guest_hit), .we_i(reg_req[0].write),
      .addr_i(guest_offset), .wdata_i(reg_req[0].wdata), .wstrb_i(reg_req[0].wstrb),
      .rdata_o(guest_data), .rvalid_o(guest_valid), .error_o(guest_error),
      .irq_o(guest_irq_o), .vq_state_o, .queue_enable_o,
      .notify_pending_o(notify_pending), .fw_notify_clear_i(notify_clear),
      .fw_reset_req_o(backend_reset_req_o), .fw_reset_ack_i(reset_ack && epoch_valid),
      .fw_reset_pulse_o(reset_pulse), .fw_queue_stop_req_o(backend_queue_stop_req_o),
      .fw_queue_stop_ack_i(stop_ack & {APU_NUM_QUEUES{epoch_valid}}),
      .used_valid_i, .used_qid_i, .used_context_i,
      .used_fence_i, .used_len_i, .used_ready_o, .last_used_qid_o(last_qid),
      .last_used_context_o(last_context), .last_used_fence_o(last_fence),
      .last_used_len_o(last_len), .cfg_display_event_i, .debug_status_o(device_status)
    );
    if (ApuCfg.VenusEn) begin : gen_venus
      // F1: no g6lc_apu_control — the Venus hardware backend owns the
      // notify/reset/queue-stop seam directly. The control window and
      // the mailbox window answer SLVERR (mbox_req_o.valid is gated
      // off above), the firmware IRQ stays low.
      assign notify_clear = be_notify_clear_i;
      assign reset_ack    = be_reset_ack_i;
      assign stop_ack     = be_queue_stop_ack_i;
      assign control_reg_rsp = '{rdata: '0, error: 1'b1,
                                 ready: control_reg_req.valid};
      assign fw_irq = 1'b0;
      assign be_notify_pending_o = notify_pending;
      logic unused_venus;
      assign unused_venus = (|control_reg_req.addr) | control_reg_req.write |
                            (|control_reg_req.wdata) | (|control_reg_req.wstrb) |
                            (|device_status) | (|last_qid) | (|last_context) |
                            (|last_len) | (|last_fence) | reset_pulse |
                            backend_reset_done_i | (|backend_idle_i);
    end else begin : gen_ctl
      assign be_notify_pending_o = '0;
      logic unused_be;
      assign unused_be = (|be_notify_clear_i) | be_reset_ack_i |
                         (|be_queue_stop_ack_i);
      g6lc_apu_control i_control (
        .clk_i, .rst_ni, .testmode_i, .req_i(control_reg_req), .rsp_o(control_reg_rsp),
        .epoch_i(epoch), .device_status_i(device_status), .vq_state_i(vq_state_o),
        .queue_enable_i(queue_enable_o), .notify_pending_i(notify_pending),
        .notify_clear_o(notify_clear), .reset_req_i(backend_reset_req_o),
        .reset_ack_o(reset_ack), .queue_stop_req_i(backend_queue_stop_req_o),
        .queue_stop_ack_o(stop_ack), .backend_reset_done_i, .backend_idle_i,
        .last_used_qid_i(last_qid), .last_used_context_i(last_context),
        .last_used_fence_i(last_fence), .last_used_len_i(last_len), .irq_o(fw_irq)
      );
    end
  end
endmodule
