// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// GenHandle plus VenusDispatch. A dispatch request decodes the Mesa
// vkCmdDispatch CS and looks up commandBuffer[31:0] as a live CMDBUF
// handle. Stale generation, wrong kind, and a high-half command
// buffer fault. Table ops (alloc/pin/retire) are forwarded to
// GenHandle. Enable=0 elaborates no datapath. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal.

// HandleDispatch (hdp): GenHandle lookup of vkCmdDispatch commandBuffer. Default-off. FeatureVirgl stays illegal.
// Interplay: HandleDispatch (hdp) --> GenHandle (gnh) --> VenusDispatch (vnd) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_hdp
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
  input  apu_hdp_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hdp_cpl_t cpl_o,
  output apu_hdp_t hdp_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign hdp_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireVnd, WaitVnd, FireGnh, WaitGnh, Done
    } state_e;
    state_e state_q;
    apu_hdp_cpl_t cpl_q;
    apu_hdp_t rec_q;
    logic disp_q, look_q;
    logic vnd_req, vnd_rdy, vnd_cpl, vnd_ack;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    apu_gnh_req_t gnh_req_q;
    apu_vnd_cpl_t vnd_c;
    apu_vnd_t vnd_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_hdp_cpl_t'('0);
    assign hdp_o = rec_q;
    assign vnd_req = state_q == FireVnd;
    assign vnd_ack = state_q == WaitVnd;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;

    g6lc_apu_vnd #(.Enable(1'b1)) i_vnd (
      .clk_i, .rst_ni, .cs_we_i, .cs_idx_i, .cs_wdata_i, .cs_rdata_o,
      .req_valid_i(vnd_req), .req_ready_o(vnd_rdy),
      .cpl_valid_o(vnd_cpl), .cpl_ready_i(vnd_ack), .cpl_o(vnd_c), .vnd_o(vnd_rec)
    );

    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c), .gnh_o(gnh_rec)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        disp_q <= 1'b0;
        look_q <= 1'b0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          disp_q <= req_i.dispatch;
          look_q <= 1'b0;
          if (req_i.dispatch) state_q <= FireVnd;
          else begin
            gnh_req_q <= req_i.gnh;
            state_q <= FireGnh;
          end
        end
        FireVnd: if (vnd_rdy) state_q <= WaitVnd;
        WaitVnd: if (vnd_cpl) begin
          if (vnd_c.status != APU_VND_OK || !vnd_rec.valid ||
              vnd_rec.command_buffer[63:32] != 32'd0) begin
            cpl_q.status <= APU_HDP_FAULT;
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
            cpl_q.status <= APU_HDP_FAULT;
          end else begin
            rec_q.valid <= gnh_rec.valid;
            rec_q.dispatch <= disp_q;
            rec_q.slot <= gnh_rec.slot;
            rec_q.gen <= gnh_rec.gen;
            rec_q.kind <= gnh_rec.kind;
            rec_q.object_id <= gnh_rec.object_id;
            rec_q.handle <= gnh_rec.handle;
            cpl_q.status <= APU_HDP_OK;
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

// HandleDispatch (hdp) enable-0 fixture: GenHandle lookup of vkCmdDispatch.
module g6lc_apu_hdp_fixture
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
  input  apu_hdp_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_hdp_cpl_t cpl_o,
  output apu_hdp_t hdp_o
);
  g6lc_apu_hdp #(.Enable(Enable)) i_dut (.*);
endmodule
