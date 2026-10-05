// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCmdDispatch CS decoder. Command type 110,
// LP64 command-buffer handle, groupCountX/Y/Z. GENERATE_REPLY writes
// the command type. vkCreateShaderModule, vkCreateInstance, and
// vkCmdDispatchIndirect fault. Enable=0 elaborates no datapath. Not
// wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusDispatch (vnd): Mesa vn_protocol vkCmdDispatch CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusDispatch (vnd) --? VenusEncode (vnenc) --? VenusPath (vnp) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vnd
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
  output apu_vnd_cpl_t cpl_o,
  output apu_vnd_t vnd_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vnd_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done, Fault } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VND_WORDS];
    apu_vnd_cpl_t cpl_q;
    apu_vnd_t rec_q;
    logic [31:0] cmd, flags, gx, gy, gz;
    logic [63:0] cmdbuf;
    logic want_reply, layout_ok;

    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = (state_q == Done) || (state_q == Fault);
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vnd_cpl_t'('0);
    assign vnd_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign cmdbuf = {cs_q[3], cs_q[2]};
    assign gx = cs_q[4];
    assign gy = cs_q[5];
    assign gz = cs_q[6];
    assign want_reply = flags == APU_VND_GENERATE_REPLY;
    assign layout_ok = (flags == 32'd0) || (flags == APU_VND_GENERATE_REPLY);

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
            if (cmd != APU_VND_CMD_DISPATCH || !layout_ok || cmdbuf == 64'd0) begin
              cpl_q.status <= APU_VND_FAULT;
              state_q <= Fault;
            end else begin
              rec_q.valid <= 1'b1;
              rec_q.cmd_type <= cmd;
              rec_q.cmd_flags <= flags;
              rec_q.command_buffer <= cmdbuf;
              rec_q.group_x <= gx;
              rec_q.group_y <= gy;
              rec_q.group_z <= gz;
              rec_q.reply <= want_reply;
              if (want_reply) cs_q[4'(APU_VND_REPLY)] <= cmd;
              cpl_q.status <= APU_VND_OK;
              state_q <= Done;
            end
          end
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        Fault: if (cpl_ready_i) state_q <= Idle;
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

// VenusDispatch (vnd) enable-0 fixture: Mesa vn_protocol vkCmdDispatch CS.
module g6lc_apu_vnd_fixture
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
  output apu_vnd_cpl_t cpl_o,
  output apu_vnd_t vnd_o
);
  g6lc_apu_vnd #(.Enable(Enable)) i_dut (.*);
endmodule
