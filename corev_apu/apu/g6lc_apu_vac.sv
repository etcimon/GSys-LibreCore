// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Mesa vn_protocol vkAllocateCommandBuffers CS decoder, then ALLOC
// CMDBUF. Command type 88, sType 40, LP64 handles, count 1, PRIMARY.
// GENERATE_REPLY writes type + VK_SUCCESS + published handle.
// vkCreateShaderModule, vkCreateInstance, vkCmdDispatch, secondary
// level, and a zero guest id fault. Enable=0 elaborates no datapath.
// Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// VenusAlloc (vac): Mesa vn_protocol vkAllocateCommandBuffers ALLOC CMDBUF. Default-off. FeatureVirgl stays illegal.
// Interplay: VenusAlloc (vac) --> GenHandle (gnh) --? VenusDispatch (vnd) --? ApuSys. Stock encode. See AGENTS-impl-interplays.md.
module g6lc_apu_vac
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
  output apu_vac_cpl_t cpl_o,
  output apu_vac_t vac_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vac_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, FireGnh, WaitGnh, Done } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VAC_WORDS];
    apu_vac_cpl_t cpl_q;
    apu_vac_t rec_q;
    logic [31:0] cmd, flags, stype, level, count;
    logic [63:0] device, pinfo, pnext, pool, asz, guest;
    logic want_reply, decode_ok;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    apu_gnh_req_t gnh_req_q;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign cs_rdata_o = (cs_idx_i < 5'(APU_VAC_WORDS)) ? cs_q[cs_idx_i] : 32'h0;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vac_cpl_t'('0);
    assign vac_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign device = {cs_q[3], cs_q[2]};
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign pool = {cs_q[10], cs_q[9]};
    assign level = cs_q[11];
    assign count = cs_q[12];
    assign asz = {cs_q[14], cs_q[13]};
    assign guest = {cs_q[16], cs_q[15]};
    assign want_reply = flags == APU_VAC_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VAC_CMD_ALLOC) &&
                       ((flags == 32'd0) || (flags == APU_VAC_GENERATE_REPLY)) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VAC_STYPE_ALLOC) &&
                       (pnext == 64'd0) &&
                       (pool != 64'd0) &&
                       (level == APU_VAC_LEVEL_PRIMARY) &&
                       (count == 32'd1) &&
                       (asz == 64'd1) &&
                       (guest[63:32] == 32'd0) &&
                       (guest[31:0] != 32'd0);
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;

    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c), .gnh_o(gnh_rec)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 5'(APU_VAC_WORDS)))
            cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            if (!decode_ok) begin
              cpl_q <= '{status: APU_VAC_FAULT};
              state_q <= Done;
            end else begin
              rec_q <= '{
                valid:     1'b0,
                reply:     want_reply,
                cmd_type:  cmd,
                cmd_flags: flags,
                device:    device,
                pool:      pool,
                level:     level,
                count:     count,
                object_id: guest[31:0],
                handle:    '0,
                slot:      '0,
                gen:       '0,
                kind:      APU_GNH_CMDBUF
              };
              gnh_req_q <= '{
                op: APU_GNH_ALLOC,
                kind: APU_GNH_CMDBUF,
                object_id: guest[31:0],
                handle: '0
              };
              state_q <= FireGnh;
            end
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK || !gnh_rec.valid ||
              gnh_rec.kind != APU_GNH_CMDBUF) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VAC_FAULT};
          end else begin
            rec_q <= '{
              valid:     1'b1,
              reply:     rec_q.reply,
              cmd_type:  rec_q.cmd_type,
              cmd_flags: rec_q.cmd_flags,
              device:    rec_q.device,
              pool:      rec_q.pool,
              level:     rec_q.level,
              count:     rec_q.count,
              object_id: gnh_rec.object_id,
              handle:    gnh_rec.handle,
              slot:      gnh_rec.slot,
              gen:       gnh_rec.gen,
              kind:      gnh_rec.kind
            };
            if (rec_q.reply) begin
              cs_q[5'(APU_VAC_REPLY)] <= rec_q.cmd_type;
              cs_q[5'(APU_VAC_REPLY) + 5'd1] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd2] <= 32'd1;
              cs_q[5'(APU_VAC_REPLY) + 5'd3] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd4] <= gnh_rec.handle;
              cs_q[5'(APU_VAC_REPLY) + 5'd5] <= 32'd0;
            end
            cpl_q <= '{status: APU_VAC_OK};
          end
          state_q <= Done;
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

// VenusAlloc (vac) enable-0 fixture: Mesa vn_protocol vkAllocateCommandBuffers ALLOC CMDBUF.
module g6lc_apu_vac_fixture
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
  output apu_vac_cpl_t cpl_o,
  output apu_vac_t vac_o
);
  g6lc_apu_vac #(.Enable(Enable)) i_dut (.*);
endmodule
