// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One guest store of the scene used.idx. The store is the 16-bit index
// 1 at 64'h8800_E002. The scene element must already have been written.
// A failed beat can be retried. A second store does not replace it.
// This is not g6lc_apu_vgpu_uidx and it is not 64'h8800_4002.

module g6lc_apu_vgpu_sux
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sun_t sun_i,
  input  apu_vgpu_suw_t suw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sux_cpl_t cpl_o,
  output apu_vgpu_sux_t sux_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [15:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sux_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|sun_i) | (|suw_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    state_e state_q;
    apu_vgpu_sux_cpl_t cpl_q;
    apu_vgpu_sux_t sux_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sux_cpl_t'('0);
    assign sux_o = sux_q;
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = APU_VGPU_SUN_IDX;
    assign wr_data_o = 16'd1;
    assign wr_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sux_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sux_q.wrote) begin
            cpl_q <= '{status: APU_VGPU_SUX_FAULT, idx: '0, addr: '0};
            state_q <= Done;
          end else if (!sun_i.valid || !suw_i.wrote) begin
            cpl_q <= '{status: APU_VGPU_SUX_EMPTY, idx: '0, addr: '0};
            state_q <= Done;
          end else if (sun_i.idx != 16'd1 || suw_i.addr != APU_VGPU_SUN_ELEM) begin
            cpl_q <= '{status: APU_VGPU_SUX_FAULT, idx: '0, addr: '0};
            state_q <= Done;
          end else begin
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_SUN_IDX) begin
            cpl_q <= '{status: APU_VGPU_SUX_BUS, idx: '0, addr: '0};
          end else begin
            sux_q.wrote <= 1'b1;
            sux_q.idx <= 16'd1;
            sux_q.addr <= APU_VGPU_SUN_IDX;
            cpl_q <= '{status: APU_VGPU_SUX_OK, idx: 16'd1, addr: APU_VGPU_SUN_IDX};
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sux_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SUX_OK |->
        sux_o.wrote && sux_o.idx == 16'd1 && sux_o.addr == APU_VGPU_SUN_IDX);
    `endif
  end
endmodule

module g6lc_apu_vgpu_sux_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sun_t sun_i,
  input  apu_vgpu_suw_t suw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sux_cpl_t cpl_o,
  output apu_vgpu_sux_t sux_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [15:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_sux #(.Enable(Enable)) i_dut (.*);
endmodule
