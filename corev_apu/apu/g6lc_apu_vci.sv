// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCreateInstance CS decoder. Command type 0,
// pCreateInfo, sType 1 INSTANCE_CREATE_INFO, no application info, no
// layers/extensions, null allocator. GENERATE_REPLY writes type +
// VK_SUCCESS. vkCreateDevice, vkGetDeviceQueue, a null info, and a
// wrong sType fault. Enable=0 elaborates no datapath. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusCreateInstance (vci): Mesa vn_protocol vkCreateInstance CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCreateInstance (vci) --? VenusCreateDevice (vcd) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vci
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
  output apu_vci_cpl_t cpl_o,
  output apu_vci_t vci_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vci_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VCI_WORDS];
    apu_vci_cpl_t cpl_q;
    apu_vci_t rec_q;
    logic [31:0] cmd, flags, stype, cflags, nlayers, nexts;
    logic [63:0] pinfo, pnext, papp, lasz, easz, allocp;
    logic want_reply, decode_ok;

    assign cs_rdata_o = (cs_idx_i < 5'(APU_VCI_WORDS)) ? cs_q[cs_idx_i] : 32'h0;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vci_cpl_t'('0);
    assign vci_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign pinfo = {cs_q[3], cs_q[2]};
    assign stype = cs_q[4];
    assign pnext = {cs_q[6], cs_q[5]};
    assign cflags = cs_q[7];
    assign papp = {cs_q[9], cs_q[8]};
    assign nlayers = cs_q[10];
    assign lasz = {cs_q[12], cs_q[11]};
    assign nexts = cs_q[13];
    assign easz = {cs_q[15], cs_q[14]};
    assign allocp = {cs_q[17], cs_q[16]};
    assign want_reply = flags == APU_VCI_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VCI_CMD_INSTANCE) &&
                       ((flags == 32'd0) || (flags == APU_VCI_GENERATE_REPLY)) &&
                       (pinfo != 64'd0) &&
                       (pinfo[63:32] == 32'd0) &&
                       (pinfo[31:0] != 32'd0) &&
                       (stype == APU_VCI_STYPE_INSTANCE) &&
                       (pnext == 64'd0) &&
                       (cflags == 32'd0) &&
                       (papp == 64'd0) &&
                       (nlayers == 32'd0) &&
                       (lasz == 64'd0) &&
                       (nexts == 32'd0) &&
                       (easz == 64'd0) &&
                       (allocp == 64'd0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 5'(APU_VCI_WORDS)))
            cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VCI_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:      1'b1,
                reply:      want_reply,
                cmd_type:   cmd,
                cmd_flags:  flags,
                info:       pinfo
              };
              if (want_reply) begin
                cs_q[5'(APU_VCI_REPLY)] <= cmd;
                cs_q[5'(APU_VCI_REPLY) + 5'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VCI_OK};
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

// VenusCreateInstance (vci) enable-0 fixture: Mesa vn_protocol vkCreateInstance CS.
module g6lc_apu_vci_fixture
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
  output apu_vci_cpl_t cpl_o,
  output apu_vci_t vci_o
);
  g6lc_apu_vci #(.Enable(Enable)) i_dut (.*);
endmodule
