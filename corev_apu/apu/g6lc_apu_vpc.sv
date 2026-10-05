// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Mesa vn_protocol vkResetCommandPool CS. Command type 87, reset flags 0, compact no pool LOOKUP.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.

// VenusResetCmdPool (vpc): Mesa vn_protocol vkResetCommandPool CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusResetCmdPool (vpc) --? VenusAlloc (vac) --? VenusCreateDevice (vcd) --? GenHandle (gnh) --? ApuSys. Compact encode; command pool is not LOOKed up. See AGENTS-impl-interplays.md.
module g6lc_apu_vpc
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
  output apu_vpc_cpl_t cpl_o,
  output apu_vpc_t vpc_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vpc_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_RCP_WORDS];
    apu_vpc_cpl_t cpl_q;
    apu_vpc_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] dev, pool;
    logic [31:0] rstf;
    logic want_reply, decode_ok;
    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vpc_cpl_t'('0);
    assign vpc_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign pool = {cs_q[5], cs_q[4]};
    assign rstf = cs_q[6];
    assign want_reply = flags == APU_RCP_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_RCP_CMD_RCP) &&
                       ((flags == 32'd0) || (flags == APU_RCP_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) && (dev[31:0] != 32'd0) &&
                       (pool[63:32] == 32'd0) && (pool[31:0] != 32'd0) &&
                       (rstf == 32'd0);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; cs_q <= '{default: '0}; cpl_q <= '0; rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_RCP_FAULT}; state_q <= Done;
            end else begin
              rec_q <= '{valid: 1'b1, reply: want_reply, cmd_type: cmd, cmd_flags: flags, device: dev, obj: pool};
              if (want_reply) begin
                cs_q[4'(APU_RCP_REPLY)] <= cmd;
                cs_q[4'(APU_RCP_REPLY)+4'd1] <= 32'd0;
              end
              cpl_q <= '{status: APU_RCP_OK}; state_q <= Done;
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
module g6lc_apu_vpc_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1'b0) (
  input logic clk_i, rst_ni, cs_we_i, req_valid_i, cpl_ready_i,
  input logic [3:0] cs_idx_i, input logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o, output logic req_ready_o, cpl_valid_o,
  output apu_vpc_cpl_t cpl_o, output apu_vpc_t vpc_o
);
  g6lc_apu_vpc #(.Enable(Enable)) i_dut (.*);
endmodule
