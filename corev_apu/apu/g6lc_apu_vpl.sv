// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCreatePipelineLayout CS decoder. Command type 68.
// CS is type 68, LP64 device, pCreateInfo, sType 30, one set layout, no push constants, pPipelineLayout.
// vkCreateDescriptorSetLayout and a null device or guest fault. Enable=0 elaborates
// no datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusPipeLayout (vpl): Mesa vn_protocol vkCreatePipelineLayout CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusPipeLayout (vpl) --? VenusCreateDevice (vcd) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vpl
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
  output apu_vpl_cpl_t cpl_o,
  output apu_vpl_t vpl_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vpl_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VPL_WORDS];
    apu_vpl_cpl_t cpl_q;
    apu_vpl_t rec_q;
    logic [31:0] cmd, flags, stype, nset, npush;
    logic [63:0] dev, pinfo, pnext, setl, allocp, guest;
    logic want_reply, decode_ok;

    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vpl_cpl_t'('0);
    assign vpl_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign nset = cs_q[9];
    assign setl = {cs_q[11], cs_q[10]};
    assign npush = cs_q[12];
    assign allocp = {cs_q[14], cs_q[13]};
    assign guest = {cs_q[16], cs_q[15]};
    assign decode_ok = (cmd == APU_VPL_CMD_PLAYOUT) &&
                       ((flags == 32'd0) || (flags == APU_VPL_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) && (dev[31:0] != 32'd0) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VPL_STYPE) &&
                       (pnext == 64'd0) &&
                       (nset == 32'd1) &&
                       (setl[63:32] == 32'd0) && (setl[31:0] != 32'd0) &&
                       (npush == 32'd0) &&
                       (allocp == 64'd0) &&
                       (guest[63:32] == 32'd0) && (guest[31:0] != 32'd0);
    assign want_reply = flags == APU_VPL_GENERATE_REPLY;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VPL_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:     1'b1,
                reply:     want_reply,
                cmd_type:  cmd,
                cmd_flags: flags,
                device:    dev,
                layout:    setl,
                guest:     guest
              };
              if (want_reply) begin
                cs_q[5'(APU_VPL_REPLY)] <= cmd;
                cs_q[5'(APU_VPL_REPLY) + 5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VPL_OK};
              state_q <= Done;
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
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// VenusPipeLayout (vpl) enable-0 fixture: Mesa vn_protocol vkCreatePipelineLayout CS.
module g6lc_apu_vpl_fixture
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
  output apu_vpl_cpl_t cpl_o,
  output apu_vpl_t vpl_o
);
  g6lc_apu_vpl #(.Enable(Enable)) i_dut (.*);
endmodule
