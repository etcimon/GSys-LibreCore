// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Horizontal filter on row 0 of the copied band. The texel coordinate
// is s = x - 1/2, with width 640, so u = x/640. x = 0 clamps both taps
// to texel 0. x = 1..7 blends texel x-1 and texel x at one half, round
// half up per byte. y must be 0, which clamps to row 0. x above 7 spans
// the next beat and records nothing. A second tap outside this beat is
// not read. TEX is not executed.

// LinearBlend (lin): Horizontal blend of two taps in the first beat.
module g6lc_apu_vgpu_lin
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
  input  apu_vgpu_pxc_t pxc_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_lin_cpl_t cpl_o,
  output apu_vgpu_lin_t lin_o,
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

  function automatic logic [7:0] avg(input logic [7:0] a, input logic [7:0] b);
    avg = 8'((9'(a) + 9'(b) + 9'd1) >> 1);
  endfunction

  function automatic logic [31:0] mix(input logic [31:0] a, input logic [31:0] b);
    mix = {avg(a[31:24], b[31:24]), avg(a[23:16], b[23:16]),
           avg(a[15:8], b[15:8]), avg(a[7:0], b[7:0])};
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign lin_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|bcp_i) | (|sbk_i) |
                        (|tbn_i) | (|ss_i) | (|pxc_i) | (|x_i) | (|y_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_lin_cpl_t cpl_q;
    apu_vgpu_lin_t lin_q;
    logic [2:0] x_q, i0_q, i1_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_lin_cpl_t'('0);
    assign lin_o = lin_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        lin_q <= '0;
        x_q <= '0;
        i0_q <= '0;
        i1_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (!bcp_i.valid || !sbk_i.valid || !tbn_i.valid || !ss_i.valid ||
              !pxc_i.valid) begin
            cpl_q.status <= APU_VGPU_LIN_EMPTY;
            state_q <= Done;
          end else if (y_i != 16'd0 || x_i > 16'd7 ||
                       bcp_i.beats != APU_VGPU_SCAN_BAND_BEATS ||
                       bcp_i.bytes != APU_VGPU_SCAN_BAND_BYTES ||
                       pxc_i.word != bcp_i.word ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 || sbk_i.addr[1:0] != 2'b00 ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       ss_i.handle != APU_VIRGL_SS_HANDLE ||
                       ss_i.s0 != APU_VIRGL_SSTATE_S0) begin
            cpl_q.status <= APU_VGPU_LIN_FAULT;
            state_q <= Done;
          end else begin
            x_q <= x_i[2:0];
            i0_q <= x_i == 16'd0 ? 3'd0 : x_i[2:0] - 3'd1;
            i1_q <= x_i == 16'd0 ? 3'd0 : x_i[2:0];
            addr_q <= {32'h0, sbk_i.addr};
            bad_q <= 1'b0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES)) begin
            bad_q <= 1'b1;
          end else begin
            logic [31:0] a, b, got;
            a = lane(i0_q, rd_rsp_data_i);
            b = lane(i1_q, rd_rsp_data_i);
            got = mix(a, b);
            if (x_q == 3'd0 && got != bcp_i.word) bad_q <= 1'b1;
            else begin
              lin_q.valid <= 1'b1;
              lin_q.x <= x_q;
              lin_q.word <= got;
            end
          end
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q) cpl_q.status <= APU_VGPU_LIN_FAULT;
          else cpl_q.status <= APU_VGPU_LIN_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_LIN_OK |->
        lin_o.valid);
    `endif
  end
endmodule

// LinearBlend (lin) enable-0 fixture: Horizontal blend of two taps in the first beat.
module g6lc_apu_vgpu_lin_fixture
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
  input  apu_vgpu_pxc_t pxc_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_lin_cpl_t cpl_o,
  output apu_vgpu_lin_t lin_o,
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
  g6lc_apu_vgpu_lin #(.Enable(Enable)) i_dut (.*);
endmodule
