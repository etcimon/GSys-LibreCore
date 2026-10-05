// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkCreateShaderModule CS decoder. Command type 59,
// LP64 handles/size_t, uint64 pointer presence, pCode array_size in
// words. GENERATE_REPLY writes type + VK_SUCCESS + handle. Enable=0
// elaborates no datapath. Not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal.

// VenusEncode (vnenc): Mesa vn_protocol vkCreateShaderModule CS. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusEncode (vnenc) --? VenusRing (vnring) --? VenusCs (vncs) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vnenc
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnenc_cpl_t cpl_o,
  output apu_vnenc_t vnenc_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vnenc_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done, Fault } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VNENC_WORDS];
    apu_vnenc_cpl_t cpl_q;
    apu_vnenc_t rec_q;
    logic [31:0] n_lo, code_lo, cmd, flags, stype, cflags;
    logic [63:0] device, pinfo, pnext, alloc, pmod, handle;
    logic [7:0] n8, aidx, pidx, hidx;
    logic n_ok, layout_ok, want_reply;

    assign cs_rdata_o = (cs_idx_i < 8'(APU_VNENC_WORDS)) ? cs_q[cs_idx_i] : 32'h0;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = (state_q == Done) || (state_q == Fault);
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vnenc_cpl_t'('0);
    assign vnenc_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign device = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign cflags = cs_q[9];
    assign code_lo = cs_q[10];
    assign n_lo = cs_q[12];
    assign n8 = n_lo[7:0];
    assign aidx = 8'(APU_VNENC_CODE0) + n8;
    assign pidx = aidx + 8'd2;
    assign hidx = aidx + 8'd4;
    assign alloc = {cs_q[aidx + 8'd1], cs_q[aidx]};
    assign pmod = {cs_q[pidx + 8'd1], cs_q[pidx]};
    assign handle = {cs_q[hidx + 8'd1], cs_q[hidx]};
    assign n_ok = (cs_q[11] == 32'd0) && (cs_q[13] == 32'd0) &&
                  (n_lo != 32'd0) && (n_lo <= 32'(APU_VNENC_MAX_WORDS)) &&
                  (n_lo[31:8] == 24'd0) &&
                  (code_lo == {n_lo[29:0], 2'b00});
    assign layout_ok = (8'(APU_VNENC_CODE0) + n8 + 8'd6) <= 8'(APU_VNENC_REPLY);
    assign want_reply = flags == APU_VNENC_GENERATE_REPLY;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && cs_idx_i < 8'(APU_VNENC_WORDS)) cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (cmd != APU_VNENC_CMD_CREATE_SHADER_MODULE ||
                (flags != 32'd0 && flags != APU_VNENC_GENERATE_REPLY) ||
                pinfo == 64'd0 ||
                stype != APU_VNENC_STYPE_SHADER_MODULE ||
                pnext != 64'd0 || cflags != 32'd0 ||
                !n_ok || !layout_ok || alloc != 64'd0 ||
                pmod == 64'd0 || handle == 64'd0) begin
              cpl_q.status <= APU_VNENC_FAULT;
              state_q <= Fault;
            end else begin
              rec_q.valid <= 1'b1;
              rec_q.cmd_type <= cmd;
              rec_q.cmd_flags <= flags;
              rec_q.device <= device;
              rec_q.code_bytes <= code_lo;
              rec_q.code_words <= n_lo;
              rec_q.first_word <= cs_q[8'(APU_VNENC_CODE0)];
              rec_q.module_id <= handle;
              rec_q.reply <= want_reply;
              if (want_reply) begin
                cs_q[8'(APU_VNENC_REPLY)] <= cmd;
                cs_q[8'(APU_VNENC_REPLY) + 8'd1] <= 32'd0;
                cs_q[8'(APU_VNENC_REPLY) + 8'd2] <= 32'd1;
                cs_q[8'(APU_VNENC_REPLY) + 8'd3] <= 32'd0;
                cs_q[8'(APU_VNENC_REPLY) + 8'd4] <= handle[31:0];
                cs_q[8'(APU_VNENC_REPLY) + 8'd5] <= handle[63:32];
              end
              cpl_q.status <= APU_VNENC_OK;
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

// VenusEncode (vnenc) enable-0 fixture: Mesa vn_protocol vkCreateShaderModule CS.
module g6lc_apu_vnenc_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vnenc_cpl_t cpl_o,
  output apu_vnenc_t vnenc_o
);
  g6lc_apu_vnenc #(.Enable(Enable)) i_dut (.*);
endmodule
