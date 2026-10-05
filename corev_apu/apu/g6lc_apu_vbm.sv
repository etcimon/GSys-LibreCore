// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkGetBufferMemoryRequirements CS decoder. Command
// type 30, LP64 device, LP64 buffer, pMemoryRequirements pointer.
// Void command: GENERATE_REPLY writes type. vkUnmapMemory, a null or
// high-half device or buffer, and a null out pointer fault. Enable=0
// elaborates no datapath. Not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal.

// VenusBufReq (vbm): Mesa vn_protocol vkGetBufferMemoryRequirements CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusBufReq (vbm) --? VenusCreateBuffer (vxb) --? GenHandle (gnh) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vbm
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
  output apu_vbm_cpl_t cpl_o,
  output apu_vbm_t vbm_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbm_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VBM_WORDS];
    apu_vbm_cpl_t cpl_q;
    apu_vbm_t rec_q;
    logic [31:0] cmd, flags;
    logic [63:0] dev, bufh, pout;
    logic want_reply, decode_ok;

    assign cs_rdata_o = cs_q[cs_idx_i];
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vbm_cpl_t'('0);
    assign vbm_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign dev = {cs_q[3], cs_q[2]};
    assign bufh = {cs_q[5], cs_q[4]};
    assign pout = {cs_q[7], cs_q[6]};
    assign want_reply = flags == APU_VBM_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VBM_CMD_BUFREQ) &&
                       ((flags == 32'd0) || (flags == APU_VBM_GENERATE_REPLY)) &&
                       (dev[63:32] == 32'd0) &&
                       (dev[31:0] != 32'd0) &&
                       (bufh[63:32] == 32'd0) &&
                       (bufh[31:0] != 32'd0) &&
                       (pout != 64'd0);

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
              cpl_q <= '{status: APU_VBM_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:     1'b1,
                reply:     want_reply,
                cmd_type:  cmd,
                cmd_flags: flags,
                device:    dev,
                buffer:    bufh
              };
              if (want_reply) begin
                cs_q[4'(APU_VBM_REPLY)] <= cmd;
              end
              cpl_q <= '{status: APU_VBM_OK};
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

// VenusBufReq (vbm) enable-0 fixture: Mesa vn_protocol vkGetBufferMemoryRequirements CS.
module g6lc_apu_vbm_fixture
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
  output apu_vbm_cpl_t cpl_o,
  output apu_vbm_t vbm_o
);
  g6lc_apu_vbm #(.Enable(Enable)) i_dut (.*);
endmodule
