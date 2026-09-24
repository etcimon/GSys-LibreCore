// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// One texel from the copied 640 by 64 band. x clamps to 639.
// y above 63 is outside the copy and records nothing. At (0,0),
// clamp-to-edge linear uses this texel alone, and the word must match
// the band copy. TEX is not executed.

module g6lc_apu_vgpu_tap
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_ss_t ss_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tap_cpl_t cpl_o,
  output apu_vgpu_tap_t tap_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  function automatic logic [31:0] lane(
    input logic [2:0] sel,
    input logic [255:0] data
  );
    case (sel)
      3'd0: lane = data[31:0];
      3'd1: lane = data[63:32];
      3'd2: lane = data[95:64];
      3'd3: lane = data[127:96];
      3'd4: lane = data[159:128];
      3'd5: lane = data[191:160];
      3'd6: lane = data[223:192];
      default: lane = data[255:224];
    endcase
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tap_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|bcp_i) | (|sbk_i) |
                        (|tbn_i) | (|ss_i) | (|x_i) | (|y_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_tap_cpl_t cpl_q;
    apu_vgpu_tap_t tap_q;
    logic [9:0] cx_q;
    logic [5:0] cy_q;
    logic [2:0] sel_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;
    logic [63:0] issue_addr;

    assign issue_addr = addr_q;
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = issue_addr;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tap_cpl_t'('0);
    assign tap_o = tap_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tap_q <= '0;
        cx_q <= '0;
        cy_q <= '0;
        sel_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [9:0] cx;
          logic [5:0] cy;
          logic [15:0] row, pix;
          logic [17:0] bytes;
          cx = x_i > 16'd639 ? 10'd639 : x_i[9:0];
          cy = y_i[5:0];
          row = (16'(cy) << 9) + (16'(cy) << 7);
          pix = row + {6'b0, cx};
          bytes = {pix, 2'b0};
          if (!bcp_i.valid || !sbk_i.valid || !tbn_i.valid || !ss_i.valid) begin
            cpl_q.status <= APU_VGPU_TAP_EMPTY;
            state_q <= Done;
          end else if (y_i > 16'd63 ||
                       bcp_i.beats != APU_VGPU_SCAN_BAND_BEATS ||
                       bcp_i.bytes != APU_VGPU_SCAN_BAND_BYTES ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 || sbk_i.addr[1:0] != 2'b00 ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       ss_i.handle != APU_VIRGL_SS_HANDLE ||
                       ss_i.s0 != APU_VIRGL_SSTATE_S0) begin
            cpl_q.status <= APU_VGPU_TAP_FAULT;
            state_q <= Done;
          end else begin
            cx_q <= cx;
            cy_q <= cy;
            sel_q <= bytes[4:2];
            addr_q <= {32'h0, sbk_i.addr} + {46'b0, bytes[17:5], 5'b0};
            bad_q <= 1'b0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else begin
            logic [31:0] got;
            got = lane(sel_q, rd_rsp_data_i);
            if (cx_q == 10'd0 && cy_q == 6'd0 && got != bcp_i.word) begin
              bad_q <= 1'b1;
            end else begin
              tap_q.valid <= 1'b1;
              tap_q.x <= cx_q;
              tap_q.y <= cy_q;
              tap_q.word <= got;
            end
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q) cpl_q.status <= APU_VGPU_TAP_FAULT;
          else cpl_q.status <= APU_VGPU_TAP_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_TAP_OK |->
        tap_o.valid && tap_o.x <= 10'd639);
    `endif
  end
endmodule

module g6lc_apu_vgpu_tap_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_ss_t ss_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tap_cpl_t cpl_o,
  output apu_vgpu_tap_t tap_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_tap #(.Enable(Enable)) i_dut (.*);
endmodule
