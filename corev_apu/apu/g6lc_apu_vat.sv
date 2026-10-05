// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCmdClearAttachments CS. Command type 121, one COLOR attach, 64x64 rect.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusClearAttach (vat): Mesa vn_protocol vkCmdClearAttachments CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusClearAttach (vat) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Compact one COLOR attachment, 64x64 rect. See AGENTS-impl-interplays.md.
module g6lc_apu_vat
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
  output apu_vat_cpl_t cpl_o,
  output apu_vat_t vat_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vat_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_CAT_WORDS];
    apu_vat_cpl_t cpl_q;
    apu_vat_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] cbuf;
    logic [31:0] natt, asp, att, c0, c1, c2, c3, nrect, ox, oy, ow, oh, basea, layers;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vat_cpl_t'('0);
    assign vat_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign natt = cs_q[4];
    assign asp = cs_q[5];
    assign att = cs_q[6];
    assign c0 = cs_q[7];
    assign c1 = cs_q[8];
    assign c2 = cs_q[9];
    assign c3 = cs_q[10];
    assign nrect = cs_q[11];
    assign ox = cs_q[12];
    assign oy = cs_q[13];
    assign ow = cs_q[14];
    assign oh = cs_q[15];
    assign basea = cs_q[16];
    assign layers = cs_q[17];
    assign want_reply = flags == APU_CAT_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_CAT_CMD_CAT) &&
                       ((flags == 32'd0) || (flags == APU_CAT_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (natt == APU_CAT_COUNT) && (asp == APU_CAT_ASPECT) &&
                       (att == 32'd0) && (c0 == 32'd0) && (c1 == 32'd0) &&
                       (c2 == 32'd0) && (c3 == 32'd0) && (nrect == APU_CAT_COUNT) &&
                       (ox == 32'd0) && (oy == 32'd0) &&
                       (ow == APU_CAT_EXT) && (oh == APU_CAT_EXT) &&
                       (basea == 32'd0) && (layers == 32'd1);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_CAT_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, cbuf: cbuf};
              if (want_reply) begin
                cs_q[5'(APU_CAT_REPLY)] <= cmd;
                cs_q[5'(APU_CAT_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_CAT_OK}; state_q <= Done;
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
module g6lc_apu_vat_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vat_cpl_t cpl_o, output apu_vat_t vat_o
);
  g6lc_apu_vat #(.Enable(Enable)) i_dut (.*);
endmodule
