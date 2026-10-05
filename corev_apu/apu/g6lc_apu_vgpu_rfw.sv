// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the 24-byte virtio OK_NODATA of the 64 by 64
// TRANSFER_FROM_HOST_3D at 64'h880A0000. The fence is 2, not the
// scene fence. This is later than g6lc_apu_vgpu_rax. This is not
// g6lc_apu_vgpu_gcw and not g6lc_apu_vgpu_rsp. The image is not
// kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// TransferFence (rfw): virtio OK_NODATA fence response of the 64 by 64 transfer.
module g6lc_apu_vgpu_rfw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rax_t rax_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  apu_vgpu_rpw_t rpw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfw_cpl_t cpl_o,
  output apu_vgpu_rfw_t rfw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_RFW_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rfw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|rax_i) | (|tfx_i) |
                        (|rpw_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rfw_cpl_t cpl_q;
    apu_vgpu_rfw_t rfw_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = VGPU_RESP_HDR_BYTES;
    assign wr_data_o = RespBeat;
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rfw_cpl_t'('0);
    assign rfw_o = rfw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rfw_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rfw_q.valid) begin
            cpl_q.status <= APU_VGPU_RFW_FAULT;
            state_q <= Done;
          end else if (!rax_i.valid || !tfx_i.valid || !rpw_i.valid) begin
            cpl_q.status <= APU_VGPU_RFW_EMPTY;
            state_q <= Done;
          end else if (rax_i.addr != APU_VGPU_RPW_DST ||
                       rax_i.length != APU_VGPU_GBD_BYTES ||
                       rax_i.resource_id != APU_VIRGL_RES_RT ||
                       tfx_i.stride != APU_VGPU_TFB_STRIDE ||
                       tfx_i.x != 16'd0 ||
                       rpw_i.dst != APU_VGPU_RPW_DST ||
                       rpw_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D) begin
            cpl_q.status <= APU_VGPU_RFW_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_RFW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_RFW_FAULT;
          else begin
            rfw_q.valid <= 1'b1;
            rfw_q.resp <= VGPU_RESP_OK_NODATA;
            rfw_q.flags <= VGPU_FLAG_FENCE;
            rfw_q.fence <= APU_VGPU_RFW_FENCE;
            rfw_q.ctx_id <= APU_VGPU_CTX_ID;
            rfw_q.addr <= APU_VGPU_RFW_ADDR;
            cpl_q.status <= APU_VGPU_RFW_OK;
          end
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
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(rfw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RFW_OK |->
        rfw_o.valid && rfw_o.addr == APU_VGPU_RFW_ADDR &&
        rfw_o.addr != APU_VGPU_RSP_ADDR &&
        rfw_o.fence == APU_VGPU_RFW_FENCE &&
        rfw_o.fence != APU_VGPU_SCENE_FENCE &&
        rfw_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// TransferFence (rfw) enable-0 fixture: virtio OK_NODATA fence response of the 64 by 64 transfer.
module g6lc_apu_vgpu_rfw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rax_t rax_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  apu_vgpu_rpw_t rpw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfw_cpl_t cpl_o,
  output apu_vgpu_rfw_t rfw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_rfw #(.Enable(Enable)) i_dut (.*);
endmodule
