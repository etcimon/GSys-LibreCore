// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One guest store of the scene used element. The store is 8 bytes:
// descriptor 0 in the low half and length 24 in the high half, at
// 64'h8800_D000. A failed beat can be retried. A second store does not
// replace the first. This is not g6lc_apu_vgpu_uwr and it is not the
// element at 64'h8800_3000.

// SceneUsedWrite (suw): Guest store of that element. Default-off. Not the CREATE_2D element.
module g6lc_apu_vgpu_suw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sun_t sun_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_suw_cpl_t cpl_o,
  output apu_vgpu_suw_t suw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [63:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign suw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|sun_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    state_e state_q;
    apu_vgpu_suw_cpl_t cpl_q;
    apu_vgpu_suw_t suw_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_suw_cpl_t'('0);
    assign suw_o = suw_q;
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = APU_VGPU_SUN_ELEM;
    assign wr_data_o = {VGPU_RESP_HDR_BYTES, 32'd0};
    assign wr_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        suw_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (suw_q.wrote) begin
            cpl_q <= '{status: APU_VGPU_SUW_FAULT, elem_id: '0, elem_len: '0, addr: '0};
            state_q <= Done;
          end else if (!sun_i.valid) begin
            cpl_q <= '{status: APU_VGPU_SUW_EMPTY, elem_id: '0, elem_len: '0, addr: '0};
            state_q <= Done;
          end else if (sun_i.idx != 16'd1 || sun_i.desc_id != 32'd0 ||
                       sun_i.len != VGPU_RESP_HDR_BYTES) begin
            cpl_q <= '{status: APU_VGPU_SUW_FAULT, elem_id: '0, elem_len: '0, addr: '0};
            state_q <= Done;
          end else begin
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_SUN_ELEM) begin
            cpl_q <= '{status: APU_VGPU_SUW_BUS, elem_id: '0, elem_len: '0, addr: '0};
          end else begin
            suw_q.wrote <= 1'b1;
            suw_q.addr <= APU_VGPU_SUN_ELEM;
            cpl_q <= '{status: APU_VGPU_SUW_OK, elem_id: 32'd0,
                       elem_len: VGPU_RESP_HDR_BYTES, addr: APU_VGPU_SUN_ELEM};
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
      cpl_valid_o && !cpl_ready_i |=> $stable(suw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SUW_OK |->
        suw_o.wrote && suw_o.addr == APU_VGPU_SUN_ELEM &&
        cpl_o.elem_id == 32'd0 && cpl_o.elem_len == VGPU_RESP_HDR_BYTES);
    `endif
  end
endmodule

// SceneUsedWrite (suw) enable-0 fixture: Guest store of that element. Default-off. Not the CREATE_2D element.
module g6lc_apu_vgpu_suw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sun_t sun_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_suw_cpl_t cpl_o,
  output apu_vgpu_suw_t suw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [63:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_suw #(.Enable(Enable)) i_dut (.*);
endmodule
