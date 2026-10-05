// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// y = 1 blend for x = 0..7. t = y - 1/2, so the sample is halfway
// between row 0 and row 1. s = x - 1/2. Both taps of each row sit in
// beat 0. x = 0 and x = 1 must match the recorded pair. Round half up
// per byte. y other than 1, and x above 7, record nothing. TEX is not
// executed.

// VerticalBeatBlend (vbx): y = 1 blend for x = 0..7, both row beats.
module g6lc_apu_vgpu_vbx
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
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_spx_t spx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbx_cpl_t cpl_o,
  output apu_vgpu_vbx_t vbx_o,
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
    assign vbx_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|bcp_i) | (|sbk_i) |
                        (|tbn_i) | (|ss_i) | (|lnr_i) | (|spx_i) | (|vlr_i) |
                        (|x_i) | (|y_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    typedef enum logic { Row0, Row1 } phase_e;
    state_e state_q;
    phase_e phase_q;
    apu_vgpu_vbx_cpl_t cpl_q;
    apu_vgpu_vbx_t vbx_q;
    logic [2:0] x_q;
    logic [255:0] row0_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vbx_cpl_t'('0);
    assign vbx_o = vbx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        phase_q <= Row0;
        cpl_q <= '0;
        vbx_q <= '0;
        x_q <= '0;
        row0_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (!bcp_i.valid || !sbk_i.valid || !tbn_i.valid || !ss_i.valid ||
              !lnr_i.valid || !spx_i.valid || !vlr_i.valid) begin
            cpl_q.status <= APU_VGPU_VBX_EMPTY;
            state_q <= Done;
          end else if (y_i != 16'd1 || x_i > 16'd7 ||
                       bcp_i.beats != APU_VGPU_SCAN_BAND_BEATS ||
                       bcp_i.bytes != APU_VGPU_SCAN_BAND_BYTES ||
                       bcp_i.word != lnr_i.origin ||
                       lnr_i.origin == lnr_i.neighbor ||
                       vlr_i.at0 == vlr_i.at1 ||
                       vlr_i.at0 == lnr_i.origin ||
                       vlr_i.at1 == lnr_i.neighbor ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 || sbk_i.addr[1:0] != 2'b00 ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       ss_i.handle != APU_VIRGL_SS_HANDLE ||
                       ss_i.s0 != APU_VIRGL_SSTATE_S0) begin
            cpl_q.status <= APU_VGPU_VBX_FAULT;
            state_q <= Done;
          end else begin
            x_q <= x_i[2:0];
            addr_q <= {32'h0, sbk_i.addr};
            phase_q <= Row0;
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
          end else if (phase_q == Row0) begin
            row0_q <= rd_rsp_data_i;
            addr_q <= {32'h0, sbk_i.addr} + 64'(APU_VGPU_SCAN_ROW_BYTES);
            phase_q <= Row1;
            state_q <= Issue;
          end else begin
            logic [31:0] top, bot, got;
            logic [2:0] prev;
            if (x_q == 3'd0) begin
              top = lane(3'd0, row0_q);
              bot = lane(3'd0, rd_rsp_data_i);
            end else begin
              prev = x_q - 3'd1;
              top = mix(lane(prev, row0_q), lane(x_q, row0_q));
              bot = mix(lane(prev, rd_rsp_data_i), lane(x_q, rd_rsp_data_i));
            end
            got = mix(top, bot);
            if ((x_q == 3'd0 && got != vlr_i.at0) ||
                (x_q == 3'd1 && got != vlr_i.at1)) bad_q <= 1'b1;
            else begin
              vbx_q.valid <= 1'b1;
              vbx_q.x <= x_q;
              vbx_q.word <= got;
            end
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q) cpl_q.status <= APU_VGPU_VBX_FAULT;
          else cpl_q.status <= APU_VGPU_VBX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_VBX_OK |-> vbx_o.valid);
    `endif
  end
endmodule

// VerticalBeatBlend (vbx) enable-0 fixture: y = 1 blend for x = 0..7, both row beats.
module g6lc_apu_vgpu_vbx_fixture
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
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_spx_t spx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbx_cpl_t cpl_o,
  output apu_vgpu_vbx_t vbx_o,
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
  g6lc_apu_vgpu_vbx #(.Enable(Enable)) i_dut (.*);
endmodule
