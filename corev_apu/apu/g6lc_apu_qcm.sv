// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mux GrantCapset and QueueRun on one request. capset=1 walks
// GET_CAPSET/INFO through Venus; capset=0 walks CREATE/DISPATCH
// through RunDone. Shared AvailNext is the child's walker, not a
// third copy. Enable=0 elaborates no datapath. Does not edit
// g6lc_apu_vgpu_avail. Not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal. NumCapsets stays 0.

// QueueCmd (qcm): GrantCapset or QueueRun on one request port. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueCmd (qcm) --> GrantCapset (gcs) --> QueueRun (qrn). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qcm
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qcm_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qcm_cpl_t cpl_o,
  output apu_qcm_t qcm_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qcm_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|in_a_i) |
                    (|in_b_i) | (|ack_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireGcs, WaitGcs, FireQrn, WaitQrn, Done
    } state_e;
    state_e state_q;
    apu_qcm_cpl_t cpl_q;
    apu_qcm_t rec_q;
    apu_qcm_req_t req_q;
    logic capset_q;
    logic gcs_req_v, gcs_rdy, gcs_cpl, gcs_ack;
    logic qrn_req_v, qrn_rdy, qrn_cpl, qrn_ack;
    logic gcs_irq, qrn_irq;
    logic [31:0] gcs_isr, qrn_isr;
    logic gcs_rd_v, gcs_rd_r, gcs_rsp_v, gcs_rsp_r;
    logic qrn_rd_v, qrn_rd_r, qrn_rsp_v, qrn_rsp_r;
    logic [63:0] gcs_rd_addr, qrn_rd_addr;
    logic [31:0] gcs_rd_len, qrn_rd_len;
    logic gcs_wr_v, gcs_wr_r, gcs_wr_rsp_v, gcs_wr_rsp_r;
    logic qrn_wr_v, qrn_wr_r, qrn_wr_rsp_v, qrn_wr_rsp_r;
    logic [63:0] gcs_wr_addr, qrn_wr_addr;
    logic [31:0] gcs_wr_len, qrn_wr_len;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] gcs_wr_data, qrn_wr_data;
    logic gcs_ack_v, qrn_ack_v;
    apu_avu_req_t gcs_req;
    apu_qrn_req_t qrn_req;
    apu_gcs_cpl_t gcs_c;
    apu_gcs_t gcs_rec;
    apu_qrn_cpl_t qrn_c;
    apu_qrn_t qrn_rec;

    assign req_ready_o = state_q == Idle && rst_ni && gcs_rdy && qrn_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qcm_cpl_t'('0);
    assign qcm_o = rec_q;
    assign irq_o = capset_q ? gcs_irq : qrn_irq;
    assign isr_o = capset_q ? gcs_isr : qrn_isr;
    assign gcs_req_v = state_q == FireGcs;
    assign qrn_req_v = state_q == FireQrn;
    assign gcs_ack = state_q == WaitGcs;
    assign qrn_ack = state_q == WaitQrn;
    assign gcs_req = req_q.qrn.avu;
    assign qrn_req = req_q.qrn;
    assign gcs_ack_v = ack_valid_i && capset_q;
    assign qrn_ack_v = ack_valid_i && !capset_q;
    assign rd_valid_o = capset_q ? gcs_rd_v : qrn_rd_v;
    assign rd_addr_o = capset_q ? gcs_rd_addr : qrn_rd_addr;
    assign rd_len_o = capset_q ? gcs_rd_len : qrn_rd_len;
    assign rd_rsp_ready_o = capset_q ? gcs_rsp_r : qrn_rsp_r;
    assign gcs_rd_r = rd_ready_i && capset_q;
    assign qrn_rd_r = rd_ready_i && !capset_q;
    assign gcs_rsp_v = rd_rsp_valid_i && capset_q;
    assign qrn_rsp_v = rd_rsp_valid_i && !capset_q;
    assign wr_valid_o = capset_q ? gcs_wr_v : qrn_wr_v;
    assign wr_addr_o = capset_q ? gcs_wr_addr : qrn_wr_addr;
    assign wr_len_o = capset_q ? gcs_wr_len : qrn_wr_len;
    assign wr_data_o = capset_q ? gcs_wr_data : qrn_wr_data;
    assign wr_rsp_ready_o = capset_q ? gcs_wr_rsp_r : qrn_wr_rsp_r;
    assign gcs_wr_r = wr_ready_i && capset_q;
    assign qrn_wr_r = wr_ready_i && !capset_q;
    assign gcs_wr_rsp_v = wr_rsp_valid_i && capset_q;
    assign qrn_wr_rsp_v = wr_rsp_valid_i && !capset_q;

    g6lc_apu_gcs #(.Enable(1'b1)) i_gcs (
      .clk_i, .rst_ni,
      .req_valid_i(gcs_req_v), .req_ready_o(gcs_rdy), .req_i(gcs_req),
      .cpl_valid_o(gcs_cpl), .cpl_ready_i(gcs_ack), .cpl_o(gcs_c), .gcs_o(gcs_rec),
      .irq_o(gcs_irq), .isr_o(gcs_isr), .ack_valid_i(gcs_ack_v), .ack_i,
      .rd_valid_o(gcs_rd_v), .rd_ready_i(gcs_rd_r),
      .rd_addr_o(gcs_rd_addr), .rd_len_o(gcs_rd_len),
      .rd_rsp_valid_i(gcs_rsp_v), .rd_rsp_ready_o(gcs_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o(gcs_wr_v), .wr_ready_i(gcs_wr_r),
      .wr_addr_o(gcs_wr_addr), .wr_len_o(gcs_wr_len), .wr_data_o(gcs_wr_data),
      .wr_rsp_valid_i(gcs_wr_rsp_v), .wr_rsp_ready_o(gcs_wr_rsp_r),
      .wr_rsp_ok_i
    );

    g6lc_apu_qrn #(.Enable(1'b1)) i_qrn (
      .clk_i, .rst_ni,
      .req_valid_i(qrn_req_v), .req_ready_o(qrn_rdy), .req_i(qrn_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qrn_cpl), .cpl_ready_i(qrn_ack), .cpl_o(qrn_c), .qrn_o(qrn_rec),
      .irq_o(qrn_irq), .isr_o(qrn_isr), .ack_valid_i(qrn_ack_v), .ack_i,
      .rd_valid_o(qrn_rd_v), .rd_ready_i(qrn_rd_r),
      .rd_addr_o(qrn_rd_addr), .rd_len_o(qrn_rd_len),
      .rd_rsp_valid_i(qrn_rsp_v), .rd_rsp_ready_o(qrn_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o(qrn_wr_v), .wr_ready_i(qrn_wr_r),
      .wr_addr_o(qrn_wr_addr), .wr_len_o(qrn_wr_len), .wr_data_o(qrn_wr_data),
      .wr_rsp_valid_i(qrn_wr_rsp_v), .wr_rsp_ready_o(qrn_wr_rsp_r),
      .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        capset_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          capset_q <= req_i.capset;
          if (req_i.capset) state_q <= FireGcs;
          else state_q <= FireQrn;
        end
        FireGcs: if (gcs_rdy) state_q <= WaitGcs;
        WaitGcs: if (gcs_cpl) begin
          rec_q <= '{
            valid:      gcs_rec.valid,
            capset:     1'b1,
            info:       gcs_rec.info,
            dispatch:   1'b0,
            irq:        gcs_rec.irq,
            cmd:        32'd0,
            result:     32'd0,
            handle:     32'd0,
            capset_id:  gcs_rec.capset_id,
            resp_word0: gcs_rec.resp_word0,
            used_idx:   gcs_rec.used_idx,
            resp_addr:  gcs_rec.resp_addr
          };
          cpl_q <= '{status: apu_qcm_status_e'(gcs_c.status)};
          state_q <= Done;
        end
        FireQrn: if (qrn_rdy) state_q <= WaitQrn;
        WaitQrn: if (qrn_cpl) begin
          rec_q <= '{
            valid:      qrn_rec.valid,
            capset:     1'b0,
            info:       1'b0,
            dispatch:   qrn_rec.dispatch,
            irq:        qrn_rec.irq,
            cmd:        qrn_rec.cmd,
            result:     qrn_rec.result,
            handle:     qrn_rec.handle,
            capset_id:  32'd0,
            resp_word0: 32'd0,
            used_idx:   qrn_rec.used_idx,
            resp_addr:  qrn_rec.resp_addr
          };
          cpl_q <= '{status: apu_qcm_status_e'(qrn_c.status)};
          state_q <= Done;
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// QueueCmd (qcm) enable-0 fixture: GrantCapset or QueueRun on one port.
module g6lc_apu_qcm_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qcm_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qcm_cpl_t cpl_o,
  output apu_qcm_t qcm_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  g6lc_apu_qcm #(.Enable(Enable)) i_dut (.*);
endmodule
