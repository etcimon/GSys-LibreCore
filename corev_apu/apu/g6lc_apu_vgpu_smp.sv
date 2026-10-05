// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// One sample of the 64 by 64 ceiling from the copied band.
// s = x - 1/2 and t = y - 1/2. x = 0 clamps to texel 0. y = 0 clamps
// to row 0. Otherwise the sample blends texel x-1 with x, and row y-1
// with y, round half up per byte. A beat holds eight texels. Points
// already stored must match those words. The image is not stored.
// x or y above 63 records nothing. TEX is not executed.

// CeilingSampler (smp): Any 64 by 64 ceiling sample from the copied band.
module g6lc_apu_vgpu_smp
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
  input  apu_vgpu_vbr_t vbr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_smp_cpl_t cpl_o,
  output apu_vgpu_smp_t smp_o,
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

  // row * 2560 = (row << 11) + (row << 9). beat * 32 = beat << 5.
  function automatic logic [63:0] pix_addr(
    input logic [5:0] row,
    input logic [2:0] beat
  );
    pix_addr = {32'h0, sbk_i.addr}
             + (64'(row) << 11)
             + (64'(row) << 9)
             + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign smp_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|bcp_i) | (|sbk_i) |
                        (|tbn_i) | (|ss_i) | (|lnr_i) | (|spx_i) | (|vlr_i) |
                        (|vbr_i) | (|vsx_i) | (|y2r_i) | (|x_i) | (|y_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_smp_cpl_t cpl_q;
    apu_vgpu_smp_t smp_q;
    logic [5:0] x_q, y_q, ta_q, tb_q, ya_q, yb_q;
    logic row_q, beat_q, need_x_q, need_y_q;
    logic [31:0] a_q, b_q, top_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_smp_cpl_t'('0);
    assign smp_o = smp_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        smp_q <= '0;
        x_q <= '0;
        y_q <= '0;
        ta_q <= '0;
        tb_q <= '0;
        ya_q <= '0;
        yb_q <= '0;
        row_q <= 1'b0;
        beat_q <= 1'b0;
        need_x_q <= 1'b0;
        need_y_q <= 1'b0;
        a_q <= '0;
        b_q <= '0;
        top_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (!bcp_i.valid || !sbk_i.valid || !tbn_i.valid || !ss_i.valid ||
              !lnr_i.valid || !spx_i.valid || !vlr_i.valid || !vbr_i.valid ||
              !vsx_i.valid || !y2r_i.valid) begin
            cpl_q.status <= APU_VGPU_SMP_EMPTY;
            state_q <= Done;
          end else if (y_i > 16'd63 || x_i > 16'd63 ||
                       bcp_i.beats != APU_VGPU_SCAN_BAND_BEATS ||
                       bcp_i.bytes != APU_VGPU_SCAN_BAND_BYTES ||
                       bcp_i.word != lnr_i.origin ||
                       lnr_i.origin == lnr_i.neighbor ||
                       vlr_i.at0 == vlr_i.at1 ||
                       vlr_i.at0 == lnr_i.origin ||
                       vlr_i.at1 == lnr_i.neighbor ||
                       vbr_i.word == vlr_i.at0 ||
                       vsx_i.word == spx_i.word ||
                       y2r_i.at0 == y2r_i.at1 ||
                       y2r_i.at0 == vlr_i.at0 ||
                       sbk_i.resource_id != APU_VIRGL_RES_SCAN ||
                       sbk_i.length != APU_VGPU_SCAN_BYTES ||
                       sbk_i.addr == 32'h0 || sbk_i.addr[1:0] != 2'b00 ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       ss_i.handle != APU_VIRGL_SS_HANDLE ||
                       ss_i.s0 != APU_VIRGL_SSTATE_S0) begin
            cpl_q.status <= APU_VGPU_SMP_FAULT;
            state_q <= Done;
          end else begin
            logic [5:0] ta, tb, ya, yb;
            ta = x_i == 16'd0 ? 6'd0 : x_i[5:0] - 6'd1;
            tb = x_i == 16'd0 ? 6'd0 : x_i[5:0];
            ya = y_i == 16'd0 ? 6'd0 : y_i[5:0] - 6'd1;
            yb = y_i == 16'd0 ? 6'd0 : y_i[5:0];
            x_q <= x_i[5:0];
            y_q <= y_i[5:0];
            ta_q <= ta;
            tb_q <= tb;
            ya_q <= ya;
            yb_q <= yb;
            row_q <= 1'b0;
            beat_q <= 1'b0;
            need_x_q <= ta[5:3] != tb[5:3];
            need_y_q <= y_i != 16'd0;
            a_q <= '0;
            b_q <= '0;
            top_q <= '0;
            addr_q <= pix_addr(ya, ta[5:3]);
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
            logic [2:0] beat_now;
            logic [31:0] a, b, horiz, got;
            logic pin_bad;
            beat_now = beat_q ? tb_q[5:3] : ta_q[5:3];
            a = a_q;
            b = b_q;
            if (beat_now == ta_q[5:3]) a = lane(ta_q[2:0], rd_rsp_data_i);
            if (beat_now == tb_q[5:3]) b = lane(tb_q[2:0], rd_rsp_data_i);
            if (need_x_q && !beat_q) begin
              a_q <= a;
              b_q <= b;
              beat_q <= 1'b1;
              addr_q <= pix_addr(row_q ? yb_q : ya_q, tb_q[5:3]);
              state_q <= Issue;
            end else begin
              horiz = mix(a, b);
              if (need_y_q && !row_q) begin
                top_q <= horiz;
                a_q <= '0;
                b_q <= '0;
                row_q <= 1'b1;
                beat_q <= 1'b0;
                addr_q <= pix_addr(yb_q, ta_q[5:3]);
                state_q <= Issue;
              end else begin
                if (need_y_q) got = mix(top_q, horiz);
                else got = horiz;
                pin_bad = 1'b0;
                if (y_q == 6'd0 && x_q == 6'd0 && got != lnr_i.origin)
                  pin_bad = 1'b1;
                if (y_q == 6'd0 && x_q == 6'd1 && got != lnr_i.neighbor)
                  pin_bad = 1'b1;
                if (y_q == 6'd0 && x_q == 6'd8 && got != spx_i.word)
                  pin_bad = 1'b1;
                if (y_q == 6'd1 && x_q == 6'd0 && got != vlr_i.at0)
                  pin_bad = 1'b1;
                if (y_q == 6'd1 && x_q == 6'd1 && got != vlr_i.at1)
                  pin_bad = 1'b1;
                if (y_q == 6'd1 && x_q == 6'd2 && got != vbr_i.word)
                  pin_bad = 1'b1;
                if (y_q == 6'd1 && x_q == 6'd8 && got != vsx_i.word)
                  pin_bad = 1'b1;
                if (y_q == 6'd2 && x_q == 6'd0 && got != y2r_i.at0)
                  pin_bad = 1'b1;
                if (y_q == 6'd2 && x_q == 6'd1 && got != y2r_i.at1)
                  pin_bad = 1'b1;
                if (pin_bad) bad_q <= 1'b1;
                else begin
                  smp_q.valid <= 1'b1;
                  smp_q.x <= x_q;
                  smp_q.y <= y_q;
                  smp_q.word <= got;
                end
                state_q <= Commit;
              end
            end
          end
        end
        Commit: begin
          if (bad_q) cpl_q.status <= APU_VGPU_SMP_FAULT;
          else cpl_q.status <= APU_VGPU_SMP_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_SMP_OK |-> smp_o.valid);
    `endif
  end
endmodule

// CeilingSampler (smp) enable-0 fixture: Any 64 by 64 ceiling sample from the copied band.
module g6lc_apu_vgpu_smp_fixture
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
  input  apu_vgpu_vbr_t vbr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic [15:0] x_i,
  input  logic [15:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_smp_cpl_t cpl_o,
  output apu_vgpu_smp_t smp_o,
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
  g6lc_apu_vgpu_smp #(.Enable(Enable)) i_dut (.*);
endmodule
