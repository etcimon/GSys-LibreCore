// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCmdBindVertexBuffers CS. Command type 105, one binding, offset 0.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusBindVtx (vvb): Mesa vn_protocol vkCmdBindVertexBuffers CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusBindVtx (vvb) --? VenusCreateBuffer (vxb) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vvb
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [3:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vvb_cpl_t cpl_o,
  output apu_vvb_t vvb_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vvb_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VVB_WORDS];
    apu_vvb_cpl_t cpl_q;
    apu_vvb_t rec_q;
    logic [31:0] cmd, flags;
    logic [31:0] firstb, nbinding;
    logic [63:0] cbuf, bufh, off;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vvb_cpl_t'('0);
    assign vvb_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign firstb = cs_q[4];
    assign nbinding = cs_q[5];
    assign bufh = {cs_q[7], cs_q[6]};
    assign off = {cs_q[9], cs_q[8]};
    assign want_reply = flags == APU_VVB_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VVB_CMD_BINDVTX) &&
                       ((flags == 32'd0) || (flags == APU_VVB_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (firstb == 32'd0) && (nbinding == 32'd1) &&
                       (bufh[63:32] == 32'd0) && (bufh[31:0] != 32'd0) &&
                       (off == 64'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VVB_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, cbuf: cbuf, buffer: bufh};
              if (want_reply) begin
                cs_q[4'(APU_VVB_REPLY)] <= cmd;
                cs_q[4'(APU_VVB_REPLY)+4'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VVB_OK}; state_q <= Done;
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
module g6lc_apu_vvb_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [3:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vvb_cpl_t cpl_o, output apu_vvb_t vvb_o
);
  g6lc_apu_vvb #(.Enable(Enable)) i_dut (.*);
endmodule
