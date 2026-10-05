// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCmdSetDepthBounds CS. Command type 99, min 0 max 1.0.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusSetDepthBounds (vbo): Mesa vn_protocol vkCmdSetDepthBounds CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusSetDepthBounds (vbo) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Compact min 0 max 1.0. See AGENTS-impl-interplays.md.
module g6lc_apu_vbo
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
  output apu_vbo_cpl_t cpl_o,
  output apu_vbo_t vbo_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbo_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_SBB_WORDS];
    apu_vbo_cpl_t cpl_q;
    apu_vbo_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] cbuf;
    logic [31:0] zmin, zmax;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vbo_cpl_t'('0);
    assign vbo_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign zmin = cs_q[4];
    assign zmax = cs_q[5];
    assign want_reply = flags == APU_SBB_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_SBB_CMD_SBB) &&
                       ((flags == 32'd0) || (flags == APU_SBB_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (zmin == 32'd0) && (zmax == APU_VVP_F1);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_SBB_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, cbuf: cbuf};
              if (want_reply) begin
                cs_q[4'(APU_SBB_REPLY)] <= cmd;
                cs_q[4'(APU_SBB_REPLY)+4'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_SBB_OK}; state_q <= Done;
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
module g6lc_apu_vbo_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [3:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vbo_cpl_t cpl_o, output apu_vbo_t vbo_o
);
  g6lc_apu_vbo #(.Enable(Enable)) i_dut (.*);
endmodule
