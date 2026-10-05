// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCreateDevice CS decoder. Command type 11, LP64
// physicalDevice, pCreateInfo, sType 3 DEVICE_CREATE_INFO, one queue
// family 0 count 1 priority 1.0, no layers/extensions/features, null
// allocator. GENERATE_REPLY writes type + VK_SUCCESS. vkGetDeviceQueue,
// vkCreateInstance, a null or high-half physicalDevice, a null info,
// a nonzero family, and a zero queue count fault. Enable=0 elaborates
// no datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusCreateDevice (vcd): Mesa vn_protocol vkCreateDevice CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusCreateDevice (vcd) --? VenusGetQueue (vgq) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vcd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [5:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcd_cpl_t cpl_o,
  output apu_vcd_t vcd_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vcd_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VCD_WORDS];
    apu_vcd_cpl_t cpl_q;
    apu_vcd_t rec_q;
    logic [31:0] cmd, flags, stype, cflags, qcount, qstype, qflags, family, qnum;
    logic [31:0] prio, nlayers, nexts;
    logic [63:0] phys, pinfo, pnext, qasz, qpnext, pasz, lasz, easz, feat, allocp;
    logic want_reply, decode_ok;

    assign cs_rdata_o = (cs_idx_i < 6'(APU_VCD_WORDS)) ? cs_q[cs_idx_i] : 32'h0;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vcd_cpl_t'('0);
    assign vcd_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign phys = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign cflags = cs_q[9];
    assign qcount = cs_q[10];
    assign qasz = {cs_q[12], cs_q[11]};
    assign qstype = cs_q[13];
    assign qpnext = {cs_q[15], cs_q[14]};
    assign qflags = cs_q[16];
    assign family = cs_q[17];
    assign qnum = cs_q[18];
    assign pasz = {cs_q[20], cs_q[19]};
    assign prio = cs_q[21];
    assign nlayers = cs_q[22];
    assign lasz = {cs_q[24], cs_q[23]};
    assign nexts = cs_q[25];
    assign easz = {cs_q[27], cs_q[26]};
    assign feat = {cs_q[29], cs_q[28]};
    assign allocp = {cs_q[31], cs_q[30]};
    assign want_reply = flags == APU_VCD_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VCD_CMD_DEVICE) &&
                       ((flags == 32'd0) || (flags == APU_VCD_GENERATE_REPLY)) &&
                       (phys[63:32] == 32'd0) &&
                       (phys[31:0] != 32'd0) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VCD_STYPE_DEVICE) &&
                       (pnext == 64'd0) &&
                       (cflags == 32'd0) &&
                       (qcount == 32'd1) &&
                       (qasz == 64'd1) &&
                       (qstype == APU_VCD_STYPE_QUEUE) &&
                       (qpnext == 64'd0) &&
                       (qflags == 32'd0) &&
                       (family == 32'd0) &&
                       (qnum == 32'd1) &&
                       (pasz == 64'd1) &&
                       (prio == APU_VCD_PRIORITY_ONE) &&
                       (nlayers == 32'd0) &&
                       (lasz == 64'd0) &&
                       (nexts == 32'd0) &&
                       (easz == 64'd0) &&
                       (feat == 64'd0) &&
                       (allocp == 64'd0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 6'(APU_VCD_WORDS)))
            cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VCD_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:            1'b1,
                reply:            want_reply,
                cmd_type:         cmd,
                cmd_flags:        flags,
                physical_device:  phys
              };
              if (want_reply) begin
                cs_q[6'(APU_VCD_REPLY)] <= cmd;
                cs_q[6'(APU_VCD_REPLY) + 6'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_VCD_OK};
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

// VenusCreateDevice (vcd) enable-0 fixture: Mesa vn_protocol vkCreateDevice CS.
module g6lc_apu_vcd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [5:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vcd_cpl_t cpl_o,
  output apu_vcd_t vcd_o
);
  g6lc_apu_vcd #(.Enable(Enable)) i_dut (.*);
endmodule
