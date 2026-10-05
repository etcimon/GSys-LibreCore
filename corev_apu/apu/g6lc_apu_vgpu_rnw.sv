// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Posted walker of the 64 by 64 transfer chain after scene guest
// ack. Descriptors 0 and 1 carry NEXT. Descriptor 2 is WRITE.
// Avail index 2 names descriptor 0. The scene chain at avail
// index 1 records nothing. Device index starts at 1. This is
// later than g6lc_apu_vgpu_sgx. This is not g6lc_apu_vgpu_tnw,
// not g6lc_apu_vgpu_snw, not g6lc_apu_vgpu_avail, not
// g6lc_apu_vgpu_chn, and not g6lc_apu_vgpu_txc.
// g6lc_apu_vgpu_avail still rejects NEXT. This does not read
// guest memory. The image is not kept. The compiler TEX opcode
// still returns -26. This is not Mesa glReadPixels.

// TransferNextAfterAckWalk (rnw): Posted NEXT walker of the transfer chain after scene guest ack.
// Interplay: SceneAckAfterNotify (sga) <-> TransferNextAfterAck (rnw). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_rnw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_rnw_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnw_cpl_t cpl_o,
  output apu_vgpu_rnw_t rnw_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rnw_o = '0;
    assign avail_idx_o = '0;
    assign device_idx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sgx_i) | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rnw_cpl_t cpl_q;
    apu_vgpu_rnw_t rnw_q;
    apu_vgpu_desc_t d0_q, d1_q, d2_q;
    logic got0_q, got1_q, got2_q, avail_arm_q, armed_q;
    logic [15:0] avail_q, dev_q;

    assign avail_idx_o = avail_q;
    assign device_idx_o = dev_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rnw_cpl_t'('0);
    assign rnw_o = rnw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rnw_q <= '0;
        d0_q <= '0;
        d1_q <= '0;
        d2_q <= '0;
        got0_q <= 1'b0;
        got1_q <= 1'b0;
        got2_q <= 1'b0;
        avail_arm_q <= 1'b0;
        armed_q <= 1'b0;
        avail_q <= 16'd1;
        dev_q <= 16'd1;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          apu_vgpu_rnw_status_e st;
          logic xfer;
          xfer = d0_q.flags == VIRTQ_DESC_F_NEXT && d0_q.next == 16'd1 &&
                 d0_q.len == APU_VGPU_RAB_BYTES && d0_q.addr == APU_VGPU_RAB_CMD &&
                 d1_q.flags == VIRTQ_DESC_F_NEXT && d1_q.next == 16'd2 &&
                 d1_q.len == APU_VGPU_TFB_BYTES && d1_q.addr == APU_VGPU_TFB_CMD &&
                 d2_q.flags == VIRTQ_DESC_F_WRITE && d2_q.next == 16'd0 &&
                 d2_q.len == VGPU_RESP_HDR_BYTES && d2_q.addr == APU_VGPU_RFW_ADDR;
          st = APU_VGPU_RNW_FAULT;
          if (rnw_q.valid) begin
            st = APU_VGPU_RNW_FAULT;
          end else if (req_i.op == APU_VGPU_RNW_POST) begin
            if (req_i.desc_id == 16'd0 ||
                (req_i.desc_id == 16'd1 && got0_q) ||
                (req_i.desc_id == 16'd2 && got0_q && got1_q)) begin
              if (req_i.desc_id == 16'd0) begin
                d0_q <= req_i.desc;
                got0_q <= 1'b1;
              end else if (req_i.desc_id == 16'd1) begin
                d1_q <= req_i.desc;
                got1_q <= 1'b1;
              end else begin
                d2_q <= req_i.desc;
                got2_q <= 1'b1;
              end
              st = APU_VGPU_RNW_OK;
            end
          end else if (req_i.op == APU_VGPU_RNW_AVAIL) begin
            if (!got0_q || !got1_q || !got2_q) begin
              st = APU_VGPU_RNW_EMPTY;
            end else if (req_i.avail_idx == 16'd1 ||
                         req_i.desc_id != 16'd0) begin
              st = APU_VGPU_RNW_FAULT;
            end else if (!avail_arm_q && req_i.avail_idx == dev_q + 16'd1) begin
              avail_q <= req_i.avail_idx;
              avail_arm_q <= 1'b1;
              st = APU_VGPU_RNW_OK;
            end
          end else if (!sgx_i.valid) begin
            st = APU_VGPU_RNW_EMPTY;
          end else if (!avail_arm_q || avail_q == dev_q) begin
            st = APU_VGPU_RNW_EMPTY;
          end else if (got0_q && got1_q && got2_q && xfer &&
                       sgx_i.ack == APU_VGPU_QSI_REASON &&
                       sgx_i.remain == APU_VGPU_VAW_CLEAR &&
                       sgx_i.used_idx == APU_VGPU_QSU_IDXV &&
                       sgx_i.used_idx != APU_VGPU_TUW_IDXV) begin
            rnw_q.valid <= 1'b1;
            rnw_q.head <= 16'd0;
            rnw_q.avail_idx <= avail_q;
            rnw_q.device_idx <= dev_q + 16'd1;
            rnw_q.att_addr <= d0_q.addr;
            rnw_q.xfer_addr <= d1_q.addr;
            rnw_q.rsp_addr <= d2_q.addr;
            dev_q <= dev_q + 16'd1;
            st = APU_VGPU_RNW_OK;
          end
          cpl_q <= '{status: st};
          state_q <= Done;
        end
        Done: begin
          if (!armed_q) armed_q <= 1'b1;
          else if (cpl_ready_i) begin
            armed_q <= 1'b0;
            state_q <= Idle;
          end
        end
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(rnw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RNW_OK && rnw_o.valid |->
        rnw_o.avail_idx == APU_VGPU_TUW_IDXV &&
        rnw_o.att_addr != APU_VGPU_NXC_DESC &&
        rnw_o.head == 16'd0);
    `endif
  end
endmodule

// TransferNextAfterAckWalk (rnw) enable-0 fixture: Posted NEXT walker of the transfer chain after scene guest ack.
module g6lc_apu_vgpu_rnw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sgx_t sgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_rnw_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnw_cpl_t cpl_o,
  output apu_vgpu_rnw_t rnw_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  g6lc_apu_vgpu_rnw #(.Enable(Enable)) i_dut (.*);
endmodule
