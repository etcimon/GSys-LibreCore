// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// QueueNotify of control queue 0 fires VenusCtrlAlloc until AvailNext is
// EMPTY. CFG and INFO pass through once. gnh_only fires once.
// Cursor queue 1 faults. Enable=0 elaborates no datapath. Does not
// edit g6lc_apu_vgpu_avail or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// QueuePumpAlloc (qpa): QueueNotify drains AvailNext until EMPTY. Default-off. FeatureVirgl stays illegal.
// Interplay: QueuePumpAlloc (qpa) --> VenusCtrlAlloc (vca). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qpa
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qpa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qpa_cpl_t cpl_o,
  output apu_qpa_t qpa_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qpa_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|in_a_i) |
                    (|in_b_i) | (|ack_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, FireVca, WaitVca, Done } state_e;
    state_e state_q;
    apu_qpa_cpl_t cpl_q;
    apu_qpa_t rec_q;
    apu_qpa_req_t req_q;
    logic [15:0] didx_q, uidx_q;
    logic [7:0] count_q, qsize;
    logic once, vca_req_v, vca_rdy, vca_cpl, vca_ack, vca_irq;
    logic [31:0] vca_isr;
    apu_vca_req_t vca_req;
    apu_vca_cpl_t vca_c;
    apu_vca_t vca_rec;

    assign req_ready_o = state_q == Idle && rst_ni && vca_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qpa_cpl_t'('0);
    assign qpa_o = rec_q;
    assign irq_o = vca_irq;
    assign isr_o = vca_isr;
    assign vca_req_v = state_q == FireVca;
    assign vca_ack = state_q == WaitVca;
    assign qsize = req_q.vca.qta.qal.avu.queue_size;
    assign once = (req_q.vca.op != APU_VCA_NOTIFY) ||
                  req_q.vca.qta.qal.gnh_only ||
                  (req_q.vca.queue_sel != 32'd0);
    always_comb begin
      vca_req = req_q.vca;
      vca_req.qta.qal.avu.device_idx = didx_q;
      vca_req.qta.qal.avu.used_idx = uidx_q;
    end

    g6lc_apu_vca #(.Enable(1'b1)) i_vca (
      .clk_i, .rst_ni,
      .req_valid_i(vca_req_v), .req_ready_o(vca_rdy), .req_i(vca_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(vca_cpl), .cpl_ready_i(vca_ack), .cpl_o(vca_c), .vca_o(vca_rec),
      .irq_o(vca_irq), .isr_o(vca_isr), .ack_valid_i, .ack_i,
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o,
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o, .wr_ready_i, .wr_addr_o, .wr_len_o, .wr_data_o,
      .wr_rsp_valid_i, .wr_rsp_ready_o, .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        didx_q <= '0;
        uidx_q <= '0;
        count_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          didx_q <= req_i.vca.qta.qal.avu.device_idx;
          uidx_q <= req_i.vca.qta.qal.avu.used_idx;
          count_q <= '0;
          state_q <= FireVca;
        end
        FireVca: if (vca_rdy) state_q <= WaitVca;
        WaitVca: if (vca_cpl) begin
          if (vca_c.status == APU_VCA_FAULT) begin
            rec_q <= '{
              valid:       1'b0,
              capset:      1'b0,
              info:        1'b0,
              alloc:       1'b0,
              dispatch:    1'b0,
              irq:         vca_rec.irq,
              count:       count_q,
              cfg_rdata:   32'd0,
              num_capsets: vca_rec.num_capsets,
              capset_id:   32'd0,
              max_version: 32'd0,
              max_size:    32'd0,
              type_word:   32'd0,
              cmd:         32'd0,
              result:      32'd0,
              handle:      32'd0,
              resp_word0:  32'd0,
              used_idx:    vca_rec.used_idx,
              resp_addr:   64'd0
            };
            cpl_q <= '{status: APU_QPA_FAULT};
            state_q <= Done;
          end else if (vca_c.status == APU_VCA_EMPTY) begin
            rec_q <= '{
              valid:       count_q != 8'd0,
              capset:      rec_q.capset,
              info:        rec_q.info,
              alloc:       rec_q.alloc,
              dispatch:    rec_q.dispatch,
              irq:         rec_q.irq,
              count:       count_q,
              cfg_rdata:   rec_q.cfg_rdata,
              num_capsets: vca_rec.num_capsets,
              capset_id:   rec_q.capset_id,
              max_version: rec_q.max_version,
              max_size:    rec_q.max_size,
              type_word:   rec_q.type_word,
              cmd:         rec_q.cmd,
              result:      rec_q.result,
              handle:      rec_q.handle,
              resp_word0:  rec_q.resp_word0,
              used_idx:    rec_q.used_idx,
              resp_addr:   rec_q.resp_addr
            };
            cpl_q <= '{status: (count_q == 8'd0) ? APU_QPA_EMPTY : APU_QPA_OK};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       vca_rec.valid,
              capset:      vca_rec.capset,
              info:        vca_rec.info,
              alloc:       vca_rec.alloc,
              dispatch:    vca_rec.dispatch,
              irq:         vca_rec.irq,
              count:       count_q + 8'd1,
              cfg_rdata:   vca_rec.cfg_rdata,
              num_capsets: vca_rec.num_capsets,
              capset_id:   vca_rec.capset_id,
              max_version: vca_rec.max_version,
              max_size:    vca_rec.max_size,
              type_word:   vca_rec.type_word,
              cmd:         vca_rec.cmd,
              result:      vca_rec.result,
              handle:      vca_rec.handle,
              resp_word0:  vca_rec.resp_word0,
              used_idx:    vca_rec.used_idx,
              resp_addr:   vca_rec.resp_addr
            };
            if (once || (count_q + 8'd1) == qsize) begin
              cpl_q <= '{status: APU_QPA_OK};
              state_q <= Done;
            end else begin
              didx_q <= didx_q + 16'd1;
              uidx_q <= vca_rec.used_idx;
              count_q <= count_q + 8'd1;
              state_q <= FireVca;
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

// QueuePumpAlloc (qpa) enable-0 fixture: QueueNotify drains until EMPTY.
module g6lc_apu_qpa_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qpa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qpa_cpl_t cpl_o,
  output apu_qpa_t qpa_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  g6lc_apu_qpa #(.Enable(Enable)) i_dut (.*);
endmodule
