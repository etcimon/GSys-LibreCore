// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkGetPhysicalDeviceImageFormatProperties CS. Command type 5, 2D linear STORAGE format 37.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusImageFormat (vip): Mesa vn_protocol vkGetPhysicalDeviceImageFormatProperties CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusImageFormat (vip) --? VenusEnumeratePhys (vep) --? VenusCreateImage (vxi) --? GenHandle (gnh) --? ApuSys. Compact 64x64 STORAGE linear. See AGENTS-impl-interplays.md.
module g6lc_apu_vip
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
  output apu_vip_cpl_t cpl_o,
  output apu_vip_t vip_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vip_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_IFP_WORDS];
    apu_vip_cpl_t cpl_q;
    apu_vip_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] phys, pout;
    logic [31:0] fmt, itype, tiling, usage, cflags;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vip_cpl_t'('0);
    assign vip_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign phys = {cs_q[3], cs_q[2]};
    assign fmt = cs_q[4];
    assign itype = cs_q[5];
    assign tiling = cs_q[6];
    assign usage = cs_q[7];
    assign cflags = cs_q[8];
    assign pout = {cs_q[10], cs_q[9]};
    assign want_reply = flags == APU_IFP_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_IFP_CMD_IFP) &&
                       ((flags == 32'd0) || (flags == APU_IFP_GENERATE_REPLY)) &&
                       (phys[63:32] == 32'd0) && (phys[31:0] != 32'd0) &&
                       (fmt == APU_GFP_FORMAT) && (itype == APU_IFP_TYPE_2D) &&
                       (tiling == APU_IFP_TILING_LINEAR) &&
                       (usage == APU_IFP_USAGE_STORAGE) && (cflags == 32'd0) &&
                       (pout != 64'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_IFP_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, phys_handle: phys, format: fmt};
              if (want_reply) begin
                cs_q[4'(APU_IFP_REPLY)] <= cmd;
                cs_q[4'(APU_IFP_REPLY)+4'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_IFP_OK}; state_q <= Done;
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
module g6lc_apu_vip_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [3:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vip_cpl_t cpl_o, output apu_vip_t vip_o
);
  g6lc_apu_vip #(.Enable(Enable)) i_dut (.*);
endmodule
