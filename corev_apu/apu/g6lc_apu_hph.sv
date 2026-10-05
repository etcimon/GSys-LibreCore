// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// VenusEncode plus GenHandle plus VenusDispatch. vkCreateShaderModule
// allocates a MODULE handle from module_id[31:0]. vkCmdDispatch looks
// up commandBuffer[31:0] as a live CMDBUF. Duplicate live module ids,
// stale generation, wrong kind, and vkCreateInstance fault. Enable=0
// elaborates no datapath. Not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal.

// HandlePath (hph): vkCreateShaderModule publishes MODULE, vkCmdDispatch looks up CMDBUF. Default-off. FeatureVirgl stays illegal.
// Interplay: HandlePath (hph) --> VenusEncode (vnenc) --> GenHandle (gnh) --> VenusDispatch (vnd) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_hph
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
  input  apu_hph_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hph_cpl_t cpl_o,
  output apu_hph_t hph_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign hph_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireEnc, WaitEnc, FireVnd, WaitVnd, FireGnh, WaitGnh, Done
    } state_e;
    state_e state_q;
    apu_hph_cpl_t cpl_q;
    apu_hph_t rec_q;
    logic create_q, disp_q, look_q;
    logic enc_req, enc_rdy, enc_cpl, enc_ack, enc_we;
    logic vnd_req, vnd_rdy, vnd_cpl, vnd_ack, vnd_we;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    logic [3:0] vnd_idx;
    logic [31:0] enc_rdata, vnd_rdata;
    apu_gnh_req_t gnh_req_q;
    apu_vnenc_cpl_t enc_c;
    apu_vnenc_t enc_rec;
    apu_vnd_cpl_t vnd_c;
    apu_vnd_t vnd_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_hph_cpl_t'('0);
    assign hph_o = rec_q;
    assign cs_rdata_o = enc_rdata;
    assign enc_we = cs_we_i;
    assign vnd_we = cs_we_i && (cs_idx_i[7:4] == 4'd0);
    assign vnd_idx = cs_idx_i[3:0];
    assign enc_req = state_q == FireEnc;
    assign enc_ack = state_q == WaitEnc;
    assign vnd_req = state_q == FireVnd;
    assign vnd_ack = state_q == WaitVnd;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;

    g6lc_apu_vnenc #(.Enable(1'b1)) i_enc (
      .clk_i, .rst_ni, .cs_we_i(enc_we), .cs_idx_i(cs_idx_i),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(enc_rdata),
      .req_valid_i(enc_req), .req_ready_o(enc_rdy),
      .cpl_valid_o(enc_cpl), .cpl_ready_i(enc_ack), .cpl_o(enc_c),
      .vnenc_o(enc_rec)
    );
    g6lc_apu_vnd #(.Enable(1'b1)) i_vnd (
      .clk_i, .rst_ni, .cs_we_i(vnd_we), .cs_idx_i(vnd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vnd_rdata),
      .req_valid_i(vnd_req), .req_ready_o(vnd_rdy),
      .cpl_valid_o(vnd_cpl), .cpl_ready_i(vnd_ack), .cpl_o(vnd_c),
      .vnd_o(vnd_rec)
    );
    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c),
      .gnh_o(gnh_rec)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        create_q <= 1'b0;
        disp_q <= 1'b0;
        look_q <= 1'b0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          create_q <= req_i.op == APU_HPH_CREATE;
          disp_q <= req_i.op == APU_HPH_DISPATCH;
          look_q <= 1'b0;
          unique case (req_i.op)
            APU_HPH_GNH: begin
              gnh_req_q <= req_i.gnh;
              state_q <= FireGnh;
            end
            APU_HPH_CREATE: state_q <= FireEnc;
            APU_HPH_DISPATCH: state_q <= FireVnd;
            default: begin
              cpl_q.status <= APU_HPH_FAULT;
              state_q <= Done;
            end
          endcase
        end
        FireEnc: if (enc_rdy) state_q <= WaitEnc;
        WaitEnc: if (enc_cpl) begin
          if (enc_c.status != APU_VNENC_OK || !enc_rec.valid ||
              enc_rec.module_id[63:32] != 32'd0 ||
              enc_rec.module_id[31:0] == 32'd0) begin
            cpl_q.status <= APU_HPH_FAULT;
            state_q <= Done;
          end else begin
            rec_q.code_words <= enc_rec.code_words;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_MODULE,
              object_id: enc_rec.module_id[31:0],
              handle: '0
            };
            state_q <= FireGnh;
          end
        end
        FireVnd: if (vnd_rdy) state_q <= WaitVnd;
        WaitVnd: if (vnd_cpl) begin
          if (vnd_c.status != APU_VND_OK || !vnd_rec.valid ||
              vnd_rec.command_buffer[63:32] != 32'd0) begin
            cpl_q.status <= APU_HPH_FAULT;
            state_q <= Done;
          end else begin
            rec_q.group_x <= vnd_rec.group_x;
            rec_q.group_y <= vnd_rec.group_y;
            rec_q.group_z <= vnd_rec.group_z;
            rec_q.handle <= vnd_rec.command_buffer[31:0];
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vnd_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK ||
              (look_q && gnh_rec.kind != APU_GNH_CMDBUF)) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_HPH_FAULT;
          end else begin
            rec_q.valid <= gnh_rec.valid;
            rec_q.create <= create_q;
            rec_q.dispatch <= disp_q;
            rec_q.slot <= gnh_rec.slot;
            rec_q.gen <= gnh_rec.gen;
            rec_q.kind <= gnh_rec.kind;
            rec_q.object_id <= gnh_rec.object_id;
            rec_q.handle <= gnh_rec.handle;
            cpl_q.status <= APU_HPH_OK;
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

// HandlePath (hph) enable-0 fixture: MODULE publish and CMDBUF dispatch lookup.
module g6lc_apu_hph_fixture
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
  input  apu_hph_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hph_cpl_t cpl_o,
  output apu_hph_t hph_o
);
  g6lc_apu_hph #(.Enable(Enable)) i_dut (.*);
endmodule
