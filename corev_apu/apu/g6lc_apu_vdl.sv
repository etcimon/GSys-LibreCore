// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCreateDescriptorSetLayout CS decoder. Command type 72.
// CS is type 72, LP64 device, pCreateInfo, sType 32, one STORAGE_BUFFER compute binding, pSetLayout.
// vkCreateBuffer and a null device or guest fault. Enable=0 elaborates
// no datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusDescLayout (vdl): Mesa vn_protocol vkCreateDescriptorSetLayout CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusDescLayout (vdl) --? VenusCreateDevice (vcd) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vdl
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
  output apu_vdl_cpl_t cpl_o,
  output apu_vdl_t vdl_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vdl_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VDL_WORDS];
    apu_vdl_cpl_t cpl_q;
    apu_vdl_t rec_q;
    logic [31:0] cmd, flags, stype, bcount, bidx, dtype, dcount, stage;
    logic [63:0] dev, pinfo, pnext, allocp, guest;
    logic want_reply, decode_ok;

    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vdl_cpl_t'('0);
    assign vdl_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign bcount = cs_q[9];
    assign bidx = cs_q[10];
    assign dtype = cs_q[11];
    assign dcount = cs_q[12];
    assign stage = cs_q[13];
    assign allocp = {cs_q[15], cs_q[14]};
    assign guest = {cs_q[17], cs_q[16]};
    assign decode_ok = (cmd == APU_VDL_CMD_DSLAYOUT) &&
                       ((flags == 32'd0) || (flags == APU_VDL_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) && (dev[31:0] != 32'd0) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VDL_STYPE) &&
                       (pnext == 64'd0) &&
                       (bcount == 32'd1) &&
                       (bidx == 32'd0) &&
                       (dtype == APU_VDL_STORAGE) &&
                       (dcount == 32'd1) &&
                       (stage == APU_VDL_COMPUTE) &&
                       (allocp == 64'd0) &&
                       (guest[63:32] == 32'd0) && (guest[31:0] != 32'd0);
    assign want_reply = flags == APU_VDL_GENERATE_REPLY;

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
              cpl_q <= '{status: APU_VDL_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:     1'b1,
                reply:     want_reply,
                cmd_type:  cmd,
                cmd_flags: flags,
                device:    dev,
                guest:     guest
              };
              if (want_reply) begin
                cs_q[5'(APU_VDL_REPLY)] <= cmd;
                cs_q[5'(APU_VDL_REPLY) + 5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VDL_OK};
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

// VenusDescLayout (vdl) enable-0 fixture: Mesa vn_protocol vkCreateDescriptorSetLayout CS.
module g6lc_apu_vdl_fixture
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
  output apu_vdl_cpl_t cpl_o,
  output apu_vdl_t vdl_o
);
  g6lc_apu_vdl #(.Enable(Enable)) i_dut (.*);
endmodule
