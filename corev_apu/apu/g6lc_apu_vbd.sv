// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCmdBindDescriptorSets CS decoder. Command type 103,
// compute bind point 1, one set, no dynamic offsets.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusBindDesc (vbd): Mesa vn_protocol vkCmdBindDescriptorSets CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusBindDesc (vbd) --? VenusDescAlloc (vda) --? VenusBegin (vbg) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vbd
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
  output apu_vbd_cpl_t cpl_o,
  output apu_vbd_t vbd_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbd_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VBD_WORDS];
    apu_vbd_cpl_t cpl_q;
    apu_vbd_t rec_q;
    logic [31:0] cmd, flags, point, first, nset, ndyn;
    logic [63:0] cbuf, lay, dset;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vbd_cpl_t'('0);
    assign vbd_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cbuf = {cs_q[3], cs_q[2]};
    assign point = cs_q[4];
    assign lay = {cs_q[6], cs_q[5]};
    assign first = cs_q[7];
    assign nset = cs_q[8];
    assign dset = {cs_q[10], cs_q[9]};
    assign ndyn = cs_q[11];
    assign want_reply = flags == APU_VBD_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VBD_CMD_BINDDESC) &&
                       ((flags == 32'd0) || (flags == APU_VBD_GENERATE_REPLY)) &&
                       (cbuf[63:32] == 32'd0) && (cbuf[31:0] != 32'd0) &&
                       (point == APU_VBP_COMPUTE) &&
                       (lay[63:32] == 32'd0) && (lay[31:0] != 32'd0) &&
                       (first == 32'd0) && (nset == 32'd1) &&
                       (dset[63:32] == 32'd0) && (dset[31:0] != 32'd0) &&
                       (ndyn == 32'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VBD_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{
                valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags,
                cbuf: cbuf, layout: lay, dset: dset
              };
              if (want_reply) begin
                cs_q[5'(APU_VBD_REPLY)] <= cmd;
                cs_q[5'(APU_VBD_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VBD_OK}; state_q <= Done;
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
module g6lc_apu_vbd_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vbd_cpl_t cpl_o, output apu_vbd_t vbd_o
);
  g6lc_apu_vbd #(.Enable(Enable)) i_dut (.*);
endmodule
