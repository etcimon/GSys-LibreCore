// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCmdBindPipeline CS decoder. Command type 93,
// LP64 command buffer, compute bind point 1, LP64 pipeline.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusBindPipe (vbp): Mesa vn_protocol vkCmdBindPipeline CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusBindPipe (vbp) --? VenusComputePipe (vcp) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vbp
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
  output apu_vbp_cpl_t cpl_o,
  output apu_vbp_t vbp_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbp_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VBP_WORDS];
    apu_vbp_cpl_t cpl_q;
    apu_vbp_t rec_q;
    logic [31:0] cmd, flags, point;
    logic [63:0] cbuf, pipeh;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vbp_cpl_t'('0);
    assign vbp_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign point = cs_q[4];
    assign pipeh = {cs_q[6], cs_q[5]};
    assign want_reply = flags == APU_VBP_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VBP_CMD_BINDPIPE) &&
                       ((flags == 32'd0) || (flags == APU_VBP_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (point == APU_VBP_COMPUTE) &&
                       (pipeh[63:32] == 32'd0) && (pipeh[31:0] != 32'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VBP_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{
                valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags,
                cbuf: cbuf, pipeline: pipeh
              };
              if (want_reply) begin
                cs_q[4'(APU_VBP_REPLY)] <= cmd;
                cs_q[4'(APU_VBP_REPLY)+4'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VBP_OK}; state_q <= Done;
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
module g6lc_apu_vbp_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [3:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vbp_cpl_t cpl_o, output apu_vbp_t vbp_o
);
  g6lc_apu_vbp #(.Enable(Enable)) i_dut (.*);
endmodule
