// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One GenHandle table: vkAllocateCommandBuffers ALLOCs CMDBUF, then
// vkBeginCommandBuffer looks up that published handle, then
// vkEndCommandBuffer looks up the begun handle. Table ops are
// forwarded. End before allocate or begin, MODULE-as-cmdbuf, and
// vkCreateInstance fault. Enable=0 elaborates no datapath. Not wired
// into g6lc_apu_sys. FeatureVirgl stays illegal.

// EndAlloc (eal): ALLOC CMDBUF then BEGIN LOOKUP then END LOOKUP on one table. Default-off. FeatureVirgl stays illegal.
// Interplay: EndAlloc (eal) --> GenHandle (gnh) --> VenusBegin (vbg) --> VenusEnd (ven) --? VenusAlloc (vac) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_eal
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
  input  apu_eal_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_eal_cpl_t cpl_o,
  output apu_eal_t eal_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign eal_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireVbg, WaitVbg, FireVen, WaitVen, FireGnh, WaitGnh, Done
    } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VAC_WORDS];
    apu_eal_cpl_t cpl_q;
    apu_eal_t rec_q;
    logic alloc_q, begin_q, end_q, look_q, begun_q;
    logic [31:0] begun_handle_q;
    logic [31:0] cmd, flags, stype, level, count;
    logic [63:0] pinfo, pnext, pool, asz, guest;
    logic decode_ok, want_reply;
    logic vbg_we, vbg_req, vbg_rdy, vbg_cpl, vbg_ack;
    logic ven_we, ven_req, ven_rdy, ven_cpl, ven_ack;
    logic [3:0] vbg_idx, ven_idx;
    logic [31:0] vbg_rdata, ven_rdata;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    apu_gnh_req_t gnh_req_q;
    apu_vbg_cpl_t vbg_c;
    apu_vbg_t vbg_rec;
    apu_ven_cpl_t ven_c;
    apu_ven_t ven_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign cs_rdata_o = (!cs_idx_i[4] && !cs_idx_i[3]) ? ven_rdata :
                        (!cs_idx_i[4]) ? vbg_rdata :
                        ((cs_idx_i < 5'(APU_VAC_WORDS)) ? cs_q[cs_idx_i] : 32'h0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_eal_cpl_t'('0);
    assign eal_o = rec_q;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
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
    assign vbg_we = cs_we_i && (state_q == Idle) && (cs_idx_i[4] == 1'b0);
    assign ven_we = cs_we_i && (state_q == Idle) && (cs_idx_i[4] == 1'b0);
    assign vbg_idx = cs_idx_i[3:0];
    assign ven_idx = cs_idx_i[3:0];
    assign vbg_req = state_q == FireVbg;
    assign vbg_ack = state_q == WaitVbg;
    assign ven_req = state_q == FireVen;
    assign ven_ack = state_q == WaitVen;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;

    g6lc_apu_vbg #(.Enable(1'b1)) i_vbg (
      .clk_i, .rst_ni, .cs_we_i(vbg_we), .cs_idx_i(vbg_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbg_rdata),
      .req_valid_i(vbg_req), .req_ready_o(vbg_rdy),
      .cpl_valid_o(vbg_cpl), .cpl_ready_i(vbg_ack), .cpl_o(vbg_c), .vbg_o(vbg_rec)
    );

    g6lc_apu_ven #(.Enable(1'b1)) i_ven (
      .clk_i, .rst_ni, .cs_we_i(ven_we), .cs_idx_i(ven_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(ven_rdata),
      .req_valid_i(ven_req), .req_ready_o(ven_rdy),
      .cpl_valid_o(ven_cpl), .cpl_ready_i(ven_ack), .cpl_o(ven_c), .ven_o(ven_rec)
    );

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
        alloc_q <= 1'b0;
        begin_q <= 1'b0;
        end_q <= 1'b0;
        look_q <= 1'b0;
        begun_q <= 1'b0;
        begun_handle_q <= '0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 5'(APU_VAC_WORDS)))
            cs_q[cs_idx_i] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            alloc_q <= req_i.op == APU_EAL_ALLOC;
            begin_q <= req_i.op == APU_EAL_BEGIN;
            end_q <= req_i.op == APU_EAL_END;
            look_q <= 1'b0;
            unique case (req_i.op)
              APU_EAL_GNH: begin
                gnh_req_q <= req_i.gnh;
                state_q <= FireGnh;
              end
              APU_EAL_ALLOC: begin
                if (!decode_ok) begin
                  cpl_q <= '{status: APU_EAL_FAULT};
                  state_q <= Done;
                end else begin
                  rec_q <= '{
                    valid:       1'b0,
                    alloc:       1'b1,
                    begin_cmd:   1'b0,
                    end_cmd:     1'b0,
                    reply:       want_reply,
                    slot:        '0,
                    gen:         '0,
                    kind:        APU_GNH_CMDBUF,
                    object_id:   guest[31:0],
                    handle:      '0,
                    begin_flags: '0
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
              APU_EAL_BEGIN: state_q <= FireVbg;
              APU_EAL_END: state_q <= FireVen;
              default: begin
                cpl_q <= '{status: APU_EAL_FAULT};
                state_q <= Done;
              end
            endcase
          end
        end
        FireVbg: if (vbg_rdy) state_q <= WaitVbg;
        WaitVbg: if (vbg_cpl) begin
          if (vbg_c.status != APU_VBG_OK || !vbg_rec.valid ||
              vbg_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_EAL_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b1,
              end_cmd:     1'b0,
              reply:       vbg_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      vbg_rec.command_buffer[31:0],
              begin_flags: vbg_rec.begin_flags
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vbg_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVen: if (ven_rdy) state_q <= WaitVen;
        WaitVen: if (ven_cpl) begin
          if (ven_c.status != APU_VEN_OK || !ven_rec.valid ||
              ven_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_EAL_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b1,
              reply:       ven_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      ven_rec.command_buffer[31:0],
              begin_flags: rec_q.begin_flags
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: ven_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK ||
              (look_q && gnh_rec.kind != APU_GNH_CMDBUF) ||
              (end_q && (!begun_q || gnh_rec.handle != begun_handle_q))) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_EAL_FAULT};
          end else begin
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       alloc_q,
              begin_cmd:   begin_q,
              end_cmd:     end_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags
            };
            if (begin_q) begin
              begun_q <= 1'b1;
              begun_handle_q <= gnh_rec.handle;
            end else if (end_q) begun_q <= 1'b0;
            if (alloc_q && rec_q.reply) begin
              cs_q[5'(APU_VAC_REPLY)] <= APU_VAC_CMD_ALLOC;
              cs_q[5'(APU_VAC_REPLY) + 5'd1] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd2] <= 32'd1;
              cs_q[5'(APU_VAC_REPLY) + 5'd3] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd4] <= gnh_rec.handle;
              cs_q[5'(APU_VAC_REPLY) + 5'd5] <= 32'd0;
            end
            cpl_q <= '{status: APU_EAL_OK};
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

// EndAlloc (eal) enable-0 fixture: ALLOC then begin LOOKUP then end LOOKUP.
module g6lc_apu_eal_fixture
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
  input  apu_eal_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_eal_cpl_t cpl_o,
  output apu_eal_t eal_o
);
  g6lc_apu_eal #(.Enable(Enable)) i_dut (.*);
endmodule
