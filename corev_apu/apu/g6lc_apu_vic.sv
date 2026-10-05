// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCmdCopyImageToBuffer CS. Command type 116, TRANSFER_SRC, 32x32 extent.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusCopyImgToBuf (vic): Mesa vn_protocol vkCmdCopyImageToBuffer CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCopyImgToBuf (vic) --? VenusCreateImage (vxi) --? VenusCreateBuffer (vxb) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Compact 32x32 color window. See AGENTS-impl-interplays.md.
module g6lc_apu_vic
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
  output apu_vic_cpl_t cpl_o,
  output apu_vic_t vic_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vic_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_CIB_WORDS];
    apu_vic_cpl_t cpl_q;
    apu_vic_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] cbuf, src, dst, off;
    logic [31:0] src_lo, nreg, row, img_h, asp, mip, basea, layers;
    logic [31:0] ox, oy, oz, ext_w, ext_h, ext_d;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vic_cpl_t'('0);
    assign vic_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign src = {cs_q[5], cs_q[4]};
    assign dst = {cs_q[7], cs_q[6]};
    assign src_lo = cs_q[8];
    assign nreg = cs_q[9];
    assign off = {cs_q[11], cs_q[10]};
    assign row = cs_q[12];
    assign img_h = cs_q[13];
    assign asp = cs_q[14];
    assign mip = cs_q[15];
    assign basea = cs_q[16];
    assign layers = cs_q[17];
    assign ox = cs_q[18];
    assign oy = cs_q[19];
    assign oz = cs_q[20];
    assign ext_w = cs_q[21];
    assign ext_h = cs_q[22];
    assign ext_d = cs_q[23];
    assign want_reply = flags == APU_CIB_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_CIB_CMD_CIB) &&
                       ((flags == 32'd0) || (flags == APU_CIB_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (src[63:32] == 32'd0) && (src[31:0] != 32'd0) &&
                       (dst[63:32] == 32'd0) && (dst[31:0] != 32'd0) &&
                       (src_lo == APU_CCI_SRC_LAYOUT) && (nreg == APU_CCI_COUNT) &&
                       (off == 64'd0) && (row == 32'd0) && (img_h == 32'd0) &&
                       (asp == APU_CCI_ASPECT) && (mip == 32'd0) &&
                       (basea == 32'd0) && (layers == 32'd1) &&
                       (ox == 32'd0) && (oy == 32'd0) && (oz == 32'd0) &&
                       (ext_w == APU_CBI_EXT_W) && (ext_h == APU_CBI_EXT_H) &&
                       (ext_d == APU_CCI_EXT_D);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_CIB_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, cbuf: cbuf, src: src, dst: dst};
              if (want_reply) begin
                cs_q[5'(APU_CIB_REPLY)] <= cmd;
                cs_q[5'(APU_CIB_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_CIB_OK}; state_q <= Done;
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
module g6lc_apu_vic_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vic_cpl_t cpl_o, output apu_vic_t vic_o
);
  g6lc_apu_vic #(.Enable(Enable)) i_dut (.*);
endmodule
