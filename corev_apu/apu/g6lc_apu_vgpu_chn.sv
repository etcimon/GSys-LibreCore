// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The scene submit as descriptors 0, 1, and 2. The driver may publish
// only the next avail index, and that index names descriptor 0.
// Descriptor 1 is the 960-byte execbuffer. Descriptor 2 is the 24-byte
// response. INDIRECT, a jumped index, and a broken link do not consume
// the slot. This does not read guest memory and it is not
// g6lc_apu_vgpu_avail.

module g6lc_apu_vgpu_chn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_chn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_chn_cpl_t cpl_o,
  output apu_vgpu_chn_t chn_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign chn_o = '0;
    assign avail_idx_o = '0;
    assign device_idx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|req_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_chn_cpl_t cpl_q;
    apu_vgpu_chn_t chn_q;
    apu_vgpu_desc_t d0_q, d1_q, d2_q;
    logic got0_q, got1_q, got2_q, avail_arm_q, armed_q;
    logic [15:0] avail_q, dev_q;

    assign avail_idx_o = avail_q;
    assign device_idx_o = dev_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_chn_cpl_t'('0);
    assign chn_o = chn_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        chn_q <= '0;
        d0_q <= '0;
        d1_q <= '0;
        d2_q <= '0;
        got0_q <= 1'b0;
        got1_q <= 1'b0;
        got2_q <= 1'b0;
        avail_arm_q <= 1'b0;
        armed_q <= 1'b0;
        avail_q <= '0;
        dev_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          apu_vgpu_chn_status_e st;
          logic scene;
          scene = d0_q.flags == VIRTQ_DESC_F_NEXT && d0_q.next == 16'd1 &&
                  d0_q.len == VGPU_SUBMIT_BYTES && d0_q.addr == APU_VGPU_HDR_ADDR &&
                  d1_q.flags == VIRTQ_DESC_F_NEXT && d1_q.next == 16'd2 &&
                  d1_q.len == APU_VGPU_SCENE_BYTES && d1_q.addr == APU_VGPU_EXEC_ADDR &&
                  d2_q.flags == VIRTQ_DESC_F_WRITE && d2_q.next == 16'd0 &&
                  d2_q.len == VGPU_RESP_HDR_BYTES && d2_q.addr == APU_VGPU_RSP_ADDR;
          st = APU_VGPU_CHN_FAULT;
          if (chn_q.valid) begin
            st = APU_VGPU_CHN_FAULT;
          end else if (req_i.op == APU_VGPU_CHN_POST) begin
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
              st = APU_VGPU_CHN_OK;
            end
          end else if (req_i.op == APU_VGPU_CHN_AVAIL) begin
            if (!got0_q || !got1_q || !got2_q) begin
              st = APU_VGPU_CHN_EMPTY;
            end else if (!avail_arm_q && req_i.avail_idx == dev_q + 16'd1 &&
                         req_i.desc_id == 16'd0) begin
              avail_q <= req_i.avail_idx;
              avail_arm_q <= 1'b1;
              st = APU_VGPU_CHN_OK;
            end
          end else if (!avail_arm_q || avail_q == dev_q) begin
            st = APU_VGPU_CHN_EMPTY;
          end else if (got0_q && got1_q && got2_q && scene) begin
            chn_q.valid <= 1'b1;
            chn_q.head <= 16'd0;
            chn_q.buf_len <= d1_q.len;
            chn_q.buf_addr <= d1_q.addr;
            chn_q.rsp_addr <= d2_q.addr;
            chn_q.device_idx <= dev_q + 16'd1;
            dev_q <= dev_q + 16'd1;
            st = APU_VGPU_CHN_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(chn_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_chn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_chn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_chn_cpl_t cpl_o,
  output apu_vgpu_chn_t chn_o,
  output logic [15:0] avail_idx_o,
  output logic [15:0] device_idx_o
);
  g6lc_apu_vgpu_chn #(.Enable(Enable)) i_dut (.*);
endmodule
