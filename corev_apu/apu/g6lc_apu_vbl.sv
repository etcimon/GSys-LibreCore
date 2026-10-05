// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCmdBlitImage CS. Command type 114, TRANSFER layouts, NEAREST filter.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusBlitImage (vbl): Mesa vn_protocol vkCmdBlitImage CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusBlitImage (vbl) --? VenusCreateImage (vxi) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Compact NEAREST 32x64 blit. See AGENTS-impl-interplays.md.
module g6lc_apu_vbl
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [4:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vbl_cpl_t cpl_o,
  output apu_vbl_t vbl_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbl_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_BLI_WORDS];
    apu_vbl_cpl_t cpl_q;
    apu_vbl_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] cbuf, src, dst;
    logic [31:0] src_lo, dst_lo, nreg, src_asp, src_mip, src_base, src_layers;
    logic [31:0] s0x, s0y, s0z, s1x, s1y, s1z, dst_asp, dst_mip, dst_base, dst_layers;
    logic [31:0] d0x, d0y, d0z, d1x, d1y, d1z, filt;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vbl_cpl_t'('0);
    assign vbl_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign src = {cs_q[5], cs_q[4]};
    assign dst = {cs_q[7], cs_q[6]};
    assign src_lo = cs_q[8];
    assign dst_lo = cs_q[9];
    assign nreg = cs_q[10];
    assign src_asp = cs_q[11];
    assign src_mip = cs_q[12];
    assign src_base = cs_q[13];
    assign src_layers = cs_q[14];
    assign s0x = cs_q[15];
    assign s0y = cs_q[16];
    assign s0z = cs_q[17];
    assign s1x = cs_q[18];
    assign s1y = cs_q[19];
    assign s1z = cs_q[20];
    assign dst_asp = cs_q[21];
    assign dst_mip = cs_q[22];
    assign dst_base = cs_q[23];
    assign dst_layers = cs_q[24];
    assign d0x = cs_q[25];
    assign d0y = cs_q[26];
    assign d0z = cs_q[27];
    assign d1x = cs_q[28];
    assign d1y = cs_q[29];
    assign d1z = cs_q[30];
    assign filt = cs_q[31];
    assign want_reply = flags == APU_BLI_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_BLI_CMD_BLI) &&
                       ((flags == 32'd0) || (flags == APU_BLI_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (src[63:32] == 32'd0) && (src[31:0] != 32'd0) &&
                       (dst[63:32] == 32'd0) && (dst[31:0] != 32'd0) &&
                       (src_lo == APU_CCI_SRC_LAYOUT) && (dst_lo == APU_CCI_DST_LAYOUT) &&
                       (nreg == APU_CCI_COUNT) &&
                       (src_asp == APU_CCI_ASPECT) && (src_mip == 32'd0) &&
                       (src_base == 32'd0) && (src_layers == 32'd1) &&
                       (s0x == 32'd0) && (s0y == 32'd0) && (s0z == 32'd0) &&
                       (s1x == APU_BLI_SRC1_X) && (s1y == APU_BLI_SRC1_Y) &&
                       (s1z == APU_BLI_SRC1_Z) &&
                       (dst_asp == APU_CCI_ASPECT) && (dst_mip == 32'd0) &&
                       (dst_base == 32'd0) && (dst_layers == 32'd1) &&
                       (d0x == APU_BLI_DST0_X) && (d0y == 32'd0) && (d0z == 32'd0) &&
                       (d1x == APU_BLI_DST1_X) && (d1y == APU_BLI_DST1_Y) &&
                       (d1z == APU_BLI_DST1_Z) && (filt == APU_BLI_FILTER);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_BLI_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, cbuf: cbuf, src: src, dst: dst};
              if (want_reply) begin
                cs_q[5'(APU_BLI_REPLY)] <= cmd;
                cs_q[5'(APU_BLI_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_BLI_OK}; state_q <= Done;
            end
          end
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end
    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    `endif
  end
endmodule
module g6lc_apu_vbl_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vbl_cpl_t cpl_o, output apu_vbl_t vbl_o
);
  g6lc_apu_vbl #(.Enable(Enable)) i_dut (.*);
endmodule
