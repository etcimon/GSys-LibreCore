// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the TEX sample pair into beat 0 of the guest readback at
// 64'h88030000. Lane 0 is (0,0), the clamp texel. Lane 1 is (1,0),
// the half blend. The rest of the buffer is not stored. A 64-high
// scissor records nothing. This is later than g6lc_apu_vgpu_ocx
// and later than g6lc_apu_vgpu_gbw. This is not g6lc_apu_vgpu_ocw.
// The compiler TEX opcode still returns -26. The image is not kept.
// This is not Mesa glReadPixels.

// ReadbackTexWrite (pbw): TEX pair written into the guest readback.
module g6lc_apu_vgpu_pbw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ocx_t ocx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pbw_cpl_t cpl_o,
  output apu_vgpu_pbw_t pbw_o,
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
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign pbw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|ocx_i) | (|cxr_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_pbw_cpl_t cpl_q;
    apu_vgpu_pbw_t pbw_q;
    logic [31:0] origin_q, neighbor_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign wr_data_o = {192'b0, neighbor_q, origin_q};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_pbw_cpl_t'('0);
    assign pbw_o = pbw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        pbw_q <= '0;
        origin_q <= '0;
        neighbor_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (pbw_q.valid) begin
            cpl_q.status <= APU_VGPU_PBW_FAULT;
            state_q <= Done;
          end else if (!ocx_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_PBW_EMPTY;
            state_q <= Done;
          end else if (ocx_i.origin != APU_VGPU_FTX_ORIGIN ||
                       ocx_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       ocx_i.origin == APU_VGPU_CLEAR_WORD ||
                       ocx_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       ocx_i.origin == ocx_i.neighbor ||
                       ocx_i.b0 != ocx_i.origin[7:0] ||
                       ocx_i.b0 == APU_VGPU_CLEAR_R ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_PBW_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            origin_q <= ocx_i.origin;
            neighbor_q <= ocx_i.neighbor;
            addr_q <= APU_VGPU_PBW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q ||
              wr_rsp_addr_i == APU_VGPU_OCW_ADDR ||
              wr_rsp_addr_i == APU_VGPU_ACW_ADDR)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_PBW_FAULT;
          else begin
            pbw_q.valid <= 1'b1;
            pbw_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            pbw_q.base <= APU_VGPU_PBW_ADDR;
            pbw_q.off0 <= APU_VGPU_ACW_AT0;
            pbw_q.off1 <= APU_VGPU_ACW_AT1;
            pbw_q.x0 <= 7'd0;
            pbw_q.x1 <= 7'd1;
            pbw_q.origin <= origin_q;
            pbw_q.neighbor <= neighbor_q;
            cpl_q.status <= APU_VGPU_PBW_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(pbw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_PBW_OK |->
        pbw_o.valid && pbw_o.base == APU_VGPU_GBW_ADDR &&
        pbw_o.base != APU_VGPU_GPW_ADDR &&
        pbw_o.origin == APU_VGPU_FTX_ORIGIN &&
        pbw_o.origin != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ReadbackTexWrite (pbw) enable-0 fixture: TEX pair written into the guest readback.
module g6lc_apu_vgpu_pbw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ocx_t ocx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pbw_cpl_t cpl_o,
  output apu_vgpu_pbw_t pbw_o,
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
  g6lc_apu_vgpu_pbw #(.Enable(Enable)) i_dut (.*);
endmodule
