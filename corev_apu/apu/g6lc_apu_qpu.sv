// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// QueueNotify of control queue 0 fires VenusCtrl until AvailNext is
// EMPTY. CFG and INFO pass through once. gnh_only fires once.
// Cursor queue 1 faults. Enable=0 elaborates no datapath. Does not
// edit g6lc_apu_vgpu_avail or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// QueuePump (qpu): QueueNotify drains AvailNext until EMPTY. Default-off. FeatureVirgl stays illegal.
// Interplay: QueuePump (qpu) --> VenusCtrl (vct). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qpu
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qpu_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qpu_cpl_t cpl_o,
  output apu_qpu_t qpu_o,
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
    assign qpu_o = '0;
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
    typedef enum logic [1:0] { Idle, FireVct, WaitVct, Done } state_e;
    state_e state_q;
    apu_qpu_cpl_t cpl_q;
    apu_qpu_t rec_q;
    apu_qpu_req_t req_q;
    logic [15:0] didx_q, uidx_q;
    logic [7:0] count_q, qsize;
    logic once, vct_req_v, vct_rdy, vct_cpl, vct_ack, vct_irq;
    logic [31:0] vct_isr;
    apu_vct_req_t vct_req;
    apu_vct_cpl_t vct_c;
    apu_vct_t vct_rec;

    assign req_ready_o = state_q == Idle && rst_ni && vct_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qpu_cpl_t'('0);
    assign qpu_o = rec_q;
    assign irq_o = vct_irq;
    assign isr_o = vct_isr;
    assign vct_req_v = state_q == FireVct;
    assign vct_ack = state_q == WaitVct;
    assign qsize = req_q.vct.qty.qrn.avu.queue_size;
    assign once = (req_q.vct.op != APU_VCT_NOTIFY) ||
                  req_q.vct.qty.qrn.gnh_only ||
                  (req_q.vct.queue_sel != 32'd0);
    always_comb begin
      vct_req = req_q.vct;
      vct_req.qty.qrn.avu.device_idx = didx_q;
      vct_req.qty.qrn.avu.used_idx = uidx_q;
    end

    g6lc_apu_vct #(.Enable(1'b1)) i_vct (
      .clk_i, .rst_ni,
      .req_valid_i(vct_req_v), .req_ready_o(vct_rdy), .req_i(vct_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(vct_cpl), .cpl_ready_i(vct_ack), .cpl_o(vct_c), .vct_o(vct_rec),
      .irq_o(vct_irq), .isr_o(vct_isr), .ack_valid_i, .ack_i,
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
          didx_q <= req_i.vct.qty.qrn.avu.device_idx;
          uidx_q <= req_i.vct.qty.qrn.avu.used_idx;
          count_q <= '0;
          state_q <= FireVct;
        end
        FireVct: if (vct_rdy) state_q <= WaitVct;
        WaitVct: if (vct_cpl) begin
          if (vct_c.status == APU_VCT_FAULT) begin
            rec_q <= '{
              valid:       1'b0,
              capset:      1'b0,
              info:        1'b0,
              dispatch:    1'b0,
              irq:         vct_rec.irq,
              count:       count_q,
              cfg_rdata:   32'd0,
              num_capsets: vct_rec.num_capsets,
              capset_id:   32'd0,
              max_version: 32'd0,
              max_size:    32'd0,
              type_word:   32'd0,
              cmd:         32'd0,
              result:      32'd0,
              handle:      32'd0,
              resp_word0:  32'd0,
              used_idx:    vct_rec.used_idx,
              resp_addr:   64'd0
            };
            cpl_q <= '{status: APU_QPU_FAULT};
            state_q <= Done;
          end else if (vct_c.status == APU_VCT_EMPTY) begin
            rec_q <= '{
              valid:       count_q != 8'd0,
              capset:      rec_q.capset,
              info:        rec_q.info,
              dispatch:    rec_q.dispatch,
              irq:         rec_q.irq,
              count:       count_q,
              cfg_rdata:   rec_q.cfg_rdata,
              num_capsets: vct_rec.num_capsets,
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
            cpl_q <= '{status: (count_q == 8'd0) ? APU_QPU_EMPTY : APU_QPU_OK};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       vct_rec.valid,
              capset:      vct_rec.capset,
              info:        vct_rec.info,
              dispatch:    vct_rec.dispatch,
              irq:         vct_rec.irq,
              count:       count_q + 8'd1,
              cfg_rdata:   vct_rec.cfg_rdata,
              num_capsets: vct_rec.num_capsets,
              capset_id:   vct_rec.capset_id,
              max_version: vct_rec.max_version,
              max_size:    vct_rec.max_size,
              type_word:   vct_rec.type_word,
              cmd:         vct_rec.cmd,
              result:      vct_rec.result,
              handle:      vct_rec.handle,
              resp_word0:  vct_rec.resp_word0,
              used_idx:    vct_rec.used_idx,
              resp_addr:   vct_rec.resp_addr
            };
            if (once || (count_q + 8'd1) == qsize) begin
              cpl_q <= '{status: APU_QPU_OK};
              state_q <= Done;
            end else begin
              didx_q <= didx_q + 16'd1;
              uidx_q <= vct_rec.used_idx;
              count_q <= count_q + 8'd1;
              state_q <= FireVct;
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

// QueuePump (qpu) enable-0 fixture: QueueNotify drains until EMPTY.
module g6lc_apu_qpu_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qpu_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qpu_cpl_t cpl_o,
  output apu_qpu_t qpu_o,
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
  g6lc_apu_qpu #(.Enable(Enable)) i_dut (.*);
endmodule
