// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the linear sample pair as fragment color. Lane 0 is (0,0),
// the clamp texel. Lane 1 is (1,0), the half blend. One beat at
// 64'h88050000. This is later than g6lc_apu_vgpu_lnr. The clear
// window stays at 64'h88020000. The image is not kept. TEX is not
// the compiler opcode. This is not the screenshot.

// LinearPairWrite (acw): Linear sample pair written as fragment color.
module g6lc_apu_vgpu_acw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_acw_cpl_t cpl_o,
  output apu_vgpu_acw_t acw_o,
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
    assign acw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|lnr_i) | (|tbn_i) |
                        (|fbr_i) | (|cxr_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_acw_cpl_t cpl_q;
    apu_vgpu_acw_t acw_q;
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
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_acw_cpl_t'('0);
    assign acw_o = acw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        acw_q <= '0;
        origin_q <= '0;
        neighbor_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (acw_q.valid) begin
            cpl_q.status <= APU_VGPU_ACW_FAULT;
            state_q <= Done;
          end else if (!lnr_i.valid || !tbn_i.valid || !fbr_i.valid ||
                       !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_ACW_EMPTY;
            state_q <= Done;
          end else if (lnr_i.origin == APU_VGPU_CLEAR_WORD ||
                       lnr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       lnr_i.neighbor == lnr_i.origin ||
                       lnr_i.neighbor == fbr_i.word ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       fbr_i.nr_cbufs != 32'd1 ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_ACW_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            origin_q <= lnr_i.origin;
            neighbor_q <= lnr_i.neighbor;
            addr_q <= APU_VGPU_ACW_ADDR;
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
            cpl_q.status <= APU_VGPU_ACW_FAULT;
          else begin
            acw_q.valid <= 1'b1;
            acw_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            acw_q.base <= APU_VGPU_ACW_ADDR;
            acw_q.off0 <= APU_VGPU_ACW_AT0;
            acw_q.off1 <= APU_VGPU_ACW_AT1;
            acw_q.x0 <= 7'd0;
            acw_q.x1 <= 7'd1;
            acw_q.origin <= origin_q;
            acw_q.neighbor <= neighbor_q;
            cpl_q.status <= APU_VGPU_ACW_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(acw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_ACW_OK |->
        acw_o.valid && acw_o.base == APU_VGPU_ACW_ADDR &&
        acw_o.off0 == APU_VGPU_ACW_AT0 && acw_o.off1 == APU_VGPU_ACW_AT1 &&
        acw_o.x0 == 7'd0 && acw_o.x1 == 7'd1 &&
        acw_o.neighbor != APU_VGPU_CLEAR_WORD &&
        acw_o.origin != acw_o.neighbor);
    `endif
  end
endmodule

// LinearPairWrite (acw) enable-0 fixture: Linear sample pair written as fragment color.
module g6lc_apu_vgpu_acw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_acw_cpl_t cpl_o,
  output apu_vgpu_acw_t acw_o,
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
  g6lc_apu_vgpu_acw #(.Enable(Enable)) i_dut (.*);
endmodule
