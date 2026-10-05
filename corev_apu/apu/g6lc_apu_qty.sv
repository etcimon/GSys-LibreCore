// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext peek of the first command word, then QueueCmd.
// GET_CAPSET/INFO select GrantCapset; CREATE/DISPATCH select
// QueueRun. gnh_only skips the peek. EMPTY fetches nothing.
// Child QueueCmd walks the same avail again. Enable=0 elaborates
// no datapath. Does not edit g6lc_apu_vgpu_avail. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal. NumCapsets stays 0.

// QueueType (qty): AvailNext type word selects GrantCapset or QueueRun. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueType (qty) --> AvailNext (avn) --> QueueCmd (qcm). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qty
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qty_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qty_cpl_t cpl_o,
  output apu_qty_t qty_o,
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
    assign qty_o = '0;
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
    typedef enum logic [2:0] {
      Idle, FireAvn, WaitAvn, RdType, WaitType, FireQcm, WaitQcm, Done
    } state_e;
    state_e state_q;
    apu_qty_cpl_t cpl_q;
    apu_qty_t rec_q;
    apu_qty_req_t req_q;
    apu_qcm_req_t qcm_req_q;
    logic [63:0] type_addr_q;
    logic [31:0] type_q;
    logic peek_rd, qcm_busy, avn_busy, type_ok;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic qcm_req_v, qcm_rdy, qcm_cpl, qcm_ack, qcm_irq;
    logic [31:0] qcm_isr;
    logic qcm_rd_v, qcm_rd_r, qcm_rsp_v, qcm_rsp_r;
    logic [63:0] qcm_rd_addr;
    logic [31:0] qcm_rd_len;
    logic qcm_wr_v, qcm_wr_r, qcm_wr_rsp_v, qcm_wr_rsp_r;
    logic [63:0] qcm_wr_addr;
    logic [31:0] qcm_wr_len;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] qcm_wr_data;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_qcm_cpl_t qcm_c;
    apu_qcm_t qcm_rec;

    assign req_ready_o = state_q == Idle && rst_ni && qcm_rdy && avn_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qty_cpl_t'('0);
    assign qty_o = rec_q;
    assign peek_rd = state_q == RdType;
    assign avn_busy = (state_q == FireAvn) || (state_q == WaitAvn);
    assign qcm_busy = (state_q == FireQcm) || (state_q == WaitQcm);
    assign irq_o = qcm_irq;
    assign isr_o = qcm_isr;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign qcm_req_v = state_q == FireQcm;
    assign qcm_ack = state_q == WaitQcm;
    assign avn_req.avail_base = req_q.qrn.avu.avail_base;
    assign avn_req.desc_base = req_q.qrn.avu.desc_base;
    assign avn_req.queue_size = req_q.qrn.avu.queue_size;
    assign avn_req.device_idx = req_q.qrn.avu.device_idx;
    assign avn_req.max_chain = req_q.qrn.avu.max_chain;
    assign type_ok = (avn_rec.first_len >= 32'd4) &&
                     (avn_rec.first_addr[1:0] == 2'd0);
    assign rd_valid_o = peek_rd || avn_rd_v || qcm_rd_v;
    assign rd_addr_o = peek_rd ? type_addr_q :
                       (avn_busy ? avn_rd_addr : qcm_rd_addr);
    assign rd_len_o = peek_rd ? 32'd4 :
                      (avn_busy ? avn_rd_len : qcm_rd_len);
    assign rd_rsp_ready_o = (state_q == WaitType) ||
                            (avn_busy ? avn_rsp_r : qcm_rsp_r);
    assign avn_rd_r = rd_ready_i && avn_busy;
    assign qcm_rd_r = rd_ready_i && qcm_busy;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign qcm_rsp_v = rd_rsp_valid_i && qcm_busy;
    assign wr_valid_o = qcm_wr_v;
    assign wr_addr_o = qcm_wr_addr;
    assign wr_len_o = qcm_wr_len;
    assign wr_data_o = qcm_wr_data;
    assign wr_rsp_ready_o = qcm_wr_rsp_r;
    assign qcm_wr_r = wr_ready_i;
    assign qcm_wr_rsp_v = wr_rsp_valid_i;

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(avn_req),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i
    );

    g6lc_apu_qcm #(.Enable(1'b1)) i_qcm (
      .clk_i, .rst_ni,
      .req_valid_i(qcm_req_v), .req_ready_o(qcm_rdy), .req_i(qcm_req_q),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qcm_cpl), .cpl_ready_i(qcm_ack), .cpl_o(qcm_c), .qcm_o(qcm_rec),
      .irq_o(qcm_irq), .isr_o(qcm_isr), .ack_valid_i, .ack_i,
      .rd_valid_o(qcm_rd_v), .rd_ready_i(qcm_rd_r),
      .rd_addr_o(qcm_rd_addr), .rd_len_o(qcm_rd_len),
      .rd_rsp_valid_i(qcm_rsp_v), .rd_rsp_ready_o(qcm_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o(qcm_wr_v), .wr_ready_i(qcm_wr_r),
      .wr_addr_o(qcm_wr_addr), .wr_len_o(qcm_wr_len), .wr_data_o(qcm_wr_data),
      .wr_rsp_valid_i(qcm_wr_rsp_v), .wr_rsp_ready_o(qcm_wr_rsp_r),
      .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        qcm_req_q <= '0;
        type_addr_q <= '0;
        type_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          type_q <= '0;
          if (req_i.qrn.gnh_only) begin
            qcm_req_q <= '{capset: 1'b0, qrn: req_i.qrn};
            state_q <= FireQcm;
          end else state_q <= FireAvn;
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            cpl_q <= '{status: APU_QTY_EMPTY};
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid ||
                       !type_ok) begin
            cpl_q <= '{status: APU_QTY_FAULT};
            state_q <= Done;
          end else begin
            type_addr_q <= avn_rec.first_addr;
            state_q <= RdType;
          end
        end
        RdType: if (rd_ready_i) state_q <= WaitType;
        WaitType: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != type_addr_q ||
              rd_rsp_len_i != 32'd4) begin
            cpl_q <= '{status: APU_QTY_FAULT};
            state_q <= Done;
          end else begin
            type_q <= rd_rsp_data_i[31:0];
            qcm_req_q <= '{
              capset: (rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET_INFO) ||
                      (rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET),
              qrn:    req_q.qrn
            };
            state_q <= FireQcm;
          end
        end
        FireQcm: if (qcm_rdy) state_q <= WaitQcm;
        WaitQcm: if (qcm_cpl) begin
          rec_q <= '{
            valid:      qcm_rec.valid,
            capset:     qcm_rec.capset,
            info:       qcm_rec.info,
            dispatch:   qcm_rec.dispatch,
            irq:        qcm_rec.irq,
            type_word:  type_q,
            cmd:        qcm_rec.cmd,
            result:     qcm_rec.result,
            handle:     qcm_rec.handle,
            capset_id:  qcm_rec.capset_id,
            resp_word0: qcm_rec.resp_word0,
            used_idx:   qcm_rec.used_idx,
            resp_addr:  qcm_rec.resp_addr
          };
          cpl_q <= '{status: apu_qty_status_e'(qcm_c.status)};
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

// QueueType (qty) enable-0 fixture: type word selects GrantCapset or QueueRun.
module g6lc_apu_qty_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qty_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qty_cpl_t cpl_o,
  output apu_qty_t qty_o,
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
  g6lc_apu_qty #(.Enable(Enable)) i_dut (.*);
endmodule
