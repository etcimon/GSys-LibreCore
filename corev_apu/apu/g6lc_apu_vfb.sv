// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCreateFramebuffer CS. Command type 80, sType 37, one color view 64x64.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusFramebuffer (vfb): Mesa vn_protocol vkCreateFramebuffer CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusFramebuffer (vfb) --? VenusRenderPass (vrp) --? VenusImageView (vxv) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vfb
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
  output apu_vfb_cpl_t cpl_o,
  output apu_vfb_t vfb_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vfb_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VFB_WORDS];
    apu_vfb_cpl_t cpl_q;
    apu_vfb_t rec_q;
    logic [31:0] cmd, flags;
    logic [31:0] stype, fflags, natt, width, height, layers;
    logic [63:0] dev, pinfo, pnext, rpass, viewh, allocp, guest;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vfb_cpl_t'('0);
    assign vfb_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign fflags = cs_q[9];
    assign rpass = {cs_q[11], cs_q[10]};
    assign natt = cs_q[12];
    assign viewh = {cs_q[14], cs_q[13]};
    assign width = cs_q[15];
    assign height = cs_q[16];
    assign layers = cs_q[17];
    assign allocp = {cs_q[19], cs_q[18]};
    assign guest = {cs_q[21], cs_q[20]};
    assign want_reply = flags == APU_VFB_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VFB_CMD_FBUF) &&
                       ((flags == 32'd0) || (flags == APU_VFB_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) && (dev[31:0] != 32'd0) &&
                       (pinfo != 64'd0) && (stype == APU_VFB_STYPE) &&
                       (pnext == 64'd0) && (fflags == 32'd0) &&
                       (rpass[63:32] == 32'd0) && (rpass[31:0] != 32'd0) &&
                       (natt == 32'd1) &&
                       (viewh[63:32] == 32'd0) && (viewh[31:0] != 32'd0) &&
                       (width == APU_VXI_WIDTH) && (height == APU_VXI_HEIGHT) &&
                       (layers == 32'd1) && (allocp == 64'd0) &&
                       (guest[63:32] == 32'd0) && (guest[31:0] != 32'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VFB_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, device: dev, rpass: rpass, view: viewh, guest: guest};
              if (want_reply) begin
                cs_q[5'(APU_VFB_REPLY)] <= cmd;
                cs_q[5'(APU_VFB_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VFB_OK}; state_q <= Done;
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
module g6lc_apu_vfb_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vfb_cpl_t cpl_o, output apu_vfb_t vfb_o
);
  g6lc_apu_vfb #(.Enable(Enable)) i_dut (.*);
endmodule
