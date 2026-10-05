// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkCreateImage CS. Command type 54, sType 14, 64x64 2D STORAGE linear R8G8B8A8.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusCreateImage (vxi): Mesa vn_protocol vkCreateImage CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCreateImage (vxi) --? VenusCreateDevice (vcd) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vxi
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
  output apu_vxi_cpl_t cpl_o,
  output apu_vxi_t vxi_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vxi_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VXI_WORDS];
    apu_vxi_cpl_t cpl_q;
    apu_vxi_t rec_q;
    logic [31:0] cmd, flags;
    logic [31:0] stype, iflags, itype, fmt, width, height, depth, mip, layers;
    logic [31:0] samples, tiling, usage, share, nfam, ilayout;
    logic [63:0] dev, pinfo, pnext, pfam, allocp, guest;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vxi_cpl_t'('0);
    assign vxi_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign iflags = cs_q[9];
    assign itype = cs_q[10];
    assign fmt = cs_q[11];
    assign width = cs_q[12];
    assign height = cs_q[13];
    assign depth = cs_q[14];
    assign mip = cs_q[15];
    assign layers = cs_q[16];
    assign samples = cs_q[17];
    assign tiling = cs_q[18];
    assign usage = cs_q[19];
    assign share = cs_q[20];
    assign nfam = cs_q[21];
    assign pfam = {cs_q[23], cs_q[22]};
    assign ilayout = cs_q[24];
    assign allocp = {cs_q[26], cs_q[25]};
    assign guest = {cs_q[28], cs_q[27]};
    assign want_reply = flags == APU_VXI_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VXI_CMD_IMAGE) &&
                       ((flags == 32'd0) || (flags == APU_VXI_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) && (dev[31:0] != 32'd0) &&
                       (pinfo != 64'd0) && (stype == APU_VXI_STYPE) &&
                       (pnext == 64'd0) && (iflags == 32'd0) &&
                       (itype == APU_VXI_TYPE_2D) && (fmt == APU_VXI_FORMAT) &&
                       (width == APU_VXI_WIDTH) && (height == APU_VXI_HEIGHT) &&
                       (depth == 32'd1) && (mip == 32'd1) && (layers == 32'd1) &&
                       (samples == 32'd1) && (tiling == APU_VXI_TILING_LINEAR) &&
                       (usage == APU_VXI_USAGE_STORAGE) && (share == 32'd0) &&
                       (nfam == 32'd0) && (pfam == 64'd0) && (ilayout == 32'd0) &&
                       (allocp == 64'd0) &&
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
              cpl_q <= '{status: APU_VXI_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, device: dev, guest: guest};
              if (want_reply) begin
                cs_q[5'(APU_VXI_REPLY)] <= cmd;
                cs_q[5'(APU_VXI_REPLY)+5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VXI_OK}; state_q <= Done;
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
module g6lc_apu_vxi_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [4:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vxi_cpl_t cpl_o, output apu_vxi_t vxi_o
);
  g6lc_apu_vxi #(.Enable(Enable)) i_dut (.*);
endmodule
