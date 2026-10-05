// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext peek of the first command word, then GrantCapset or
// QueueBegin. GET_CAPSET/INFO select Venus; ALLOC/BEGIN/CREATE/DISPATCH/END
// select QueueBegin. Idle holds capset_q except gnh_only. EMPTY fetches
// nothing. Enable=0 elaborates no datapath. Does not edit
// g6lc_apu_vgpu_avail. Not wired into g6lc_apu_sys. FeatureVirgl stays
// illegal. NumCapsets stays 0.

// QueueTypeBegin (qtb): AvailNext type word selects GrantCapset or QueueBegin. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueTypeBegin (qtb) --> AvailNext (avn) --> GrantCapset (gcs) --> QueueBegin (qbn). --? QueueTypeAlloc (qta) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qtb
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qtb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qtb_cpl_t cpl_o,
  output apu_qtb_t qtb_o,
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
    assign qtb_o = '0;
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
    typedef enum logic [3:0] {
      Idle, FireAvn, WaitAvn, RdType, WaitType, FireGcs, WaitGcs,
      FireQbn, WaitQbn, Done
    } state_e;
    state_e state_q;
    apu_qtb_cpl_t cpl_q;
    apu_qtb_t rec_q;
    apu_qtb_req_t req_q;
    logic [63:0] type_addr_q;
    logic [31:0] type_q;
    logic capset_q, peek_rd, avn_busy, child_busy, type_ok;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic gcs_req_v, gcs_rdy, gcs_cpl, gcs_ack, gcs_irq;
    logic qbn_req_v, qbn_rdy, qbn_cpl, qbn_ack, qbn_irq;
    logic [31:0] gcs_isr, qbn_isr;
    logic gcs_rd_v, gcs_rd_r, gcs_rsp_v, gcs_rsp_r;
    logic qbn_rd_v, qbn_rd_r, qbn_rsp_v, qbn_rsp_r;
    logic [63:0] gcs_rd_addr, qbn_rd_addr;
    logic [31:0] gcs_rd_len, qbn_rd_len;
    logic gcs_wr_v, gcs_wr_r, gcs_wr_rsp_v, gcs_wr_rsp_r;
    logic qbn_wr_v, qbn_wr_r, qbn_wr_rsp_v, qbn_wr_rsp_r;
    logic [63:0] gcs_wr_addr, qbn_wr_addr;
    logic [31:0] gcs_wr_len, qbn_wr_len;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] gcs_wr_data, qbn_wr_data;
    logic gcs_ack_v, qbn_ack_v;
    apu_avn_req_t avn_req;
    apu_avu_req_t gcs_req;
    apu_qbn_req_t qbn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_gcs_cpl_t gcs_c;
    apu_gcs_t gcs_rec;
    apu_qbn_cpl_t qbn_c;
    apu_qbn_t qbn_rec;

    assign req_ready_o = state_q == Idle && rst_ni && gcs_rdy && qbn_rdy && avn_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qtb_cpl_t'('0);
    assign qtb_o = rec_q;
    assign peek_rd = state_q == RdType;
    assign avn_busy = (state_q == FireAvn) || (state_q == WaitAvn);
    assign child_busy = (state_q == FireGcs) || (state_q == WaitGcs) ||
                        (state_q == FireQbn) || (state_q == WaitQbn);
    assign irq_o = capset_q ? gcs_irq : qbn_irq;
    assign isr_o = capset_q ? gcs_isr : qbn_isr;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign gcs_req_v = state_q == FireGcs;
    assign qbn_req_v = state_q == FireQbn;
    assign gcs_ack = state_q == WaitGcs;
    assign qbn_ack = state_q == WaitQbn;
    assign avn_req.avail_base = req_q.qbn.avu.avail_base;
    assign avn_req.desc_base = req_q.qbn.avu.desc_base;
    assign avn_req.queue_size = req_q.qbn.avu.queue_size;
    assign avn_req.device_idx = req_q.qbn.avu.device_idx;
    assign avn_req.max_chain = req_q.qbn.avu.max_chain;
    assign gcs_req = req_q.qbn.avu;
    assign qbn_req = req_q.qbn;
    assign type_ok = (avn_rec.first_len >= 32'd4) &&
                     (avn_rec.first_addr[1:0] == 2'd0);
    assign gcs_ack_v = ack_valid_i && capset_q;
    assign qbn_ack_v = ack_valid_i && !capset_q;
    assign rd_valid_o = peek_rd || avn_rd_v || (capset_q ? gcs_rd_v : qbn_rd_v);
    assign rd_addr_o = peek_rd ? type_addr_q :
                       (avn_busy ? avn_rd_addr : (capset_q ? gcs_rd_addr : qbn_rd_addr));
    assign rd_len_o = peek_rd ? 32'd4 :
                      (avn_busy ? avn_rd_len : (capset_q ? gcs_rd_len : qbn_rd_len));
    assign rd_rsp_ready_o = (state_q == WaitType) ||
                            (avn_busy ? avn_rsp_r : (capset_q ? gcs_rsp_r : qbn_rsp_r));
    assign avn_rd_r = rd_ready_i && avn_busy;
    assign gcs_rd_r = rd_ready_i && child_busy && capset_q;
    assign qbn_rd_r = rd_ready_i && child_busy && !capset_q;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign gcs_rsp_v = rd_rsp_valid_i && child_busy && capset_q;
    assign qbn_rsp_v = rd_rsp_valid_i && child_busy && !capset_q;
    assign wr_valid_o = capset_q ? gcs_wr_v : qbn_wr_v;
    assign wr_addr_o = capset_q ? gcs_wr_addr : qbn_wr_addr;
    assign wr_len_o = capset_q ? gcs_wr_len : qbn_wr_len;
    assign wr_data_o = capset_q ? gcs_wr_data : qbn_wr_data;
    assign wr_rsp_ready_o = capset_q ? gcs_wr_rsp_r : qbn_wr_rsp_r;
    assign gcs_wr_r = wr_ready_i && capset_q;
    assign qbn_wr_r = wr_ready_i && !capset_q;
    assign gcs_wr_rsp_v = wr_rsp_valid_i && capset_q;
    assign qbn_wr_rsp_v = wr_rsp_valid_i && !capset_q;

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(avn_req),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i
    );

    g6lc_apu_gcs #(.Enable(1'b1)) i_gcs (
      .clk_i, .rst_ni,
      .req_valid_i(gcs_req_v), .req_ready_o(gcs_rdy), .req_i(gcs_req),
      .cpl_valid_o(gcs_cpl), .cpl_ready_i(gcs_ack), .cpl_o(gcs_c), .gcs_o(gcs_rec),
      .irq_o(gcs_irq), .isr_o(gcs_isr), .ack_valid_i(gcs_ack_v), .ack_i,
      .rd_valid_o(gcs_rd_v), .rd_ready_i(gcs_rd_r),
      .rd_addr_o(gcs_rd_addr), .rd_len_o(gcs_rd_len),
      .rd_rsp_valid_i(gcs_rsp_v), .rd_rsp_ready_o(gcs_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o(gcs_wr_v), .wr_ready_i(gcs_wr_r),
      .wr_addr_o(gcs_wr_addr), .wr_len_o(gcs_wr_len), .wr_data_o(gcs_wr_data),
      .wr_rsp_valid_i(gcs_wr_rsp_v), .wr_rsp_ready_o(gcs_wr_rsp_r),
      .wr_rsp_ok_i
    );

    g6lc_apu_qbn #(.Enable(1'b1)) i_qbn (
      .clk_i, .rst_ni,
      .req_valid_i(qbn_req_v), .req_ready_o(qbn_rdy), .req_i(qbn_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qbn_cpl), .cpl_ready_i(qbn_ack), .cpl_o(qbn_c), .qbn_o(qbn_rec),
      .irq_o(qbn_irq), .isr_o(qbn_isr), .ack_valid_i(qbn_ack_v), .ack_i,
      .rd_valid_o(qbn_rd_v), .rd_ready_i(qbn_rd_r),
      .rd_addr_o(qbn_rd_addr), .rd_len_o(qbn_rd_len),
      .rd_rsp_valid_i(qbn_rsp_v), .rd_rsp_ready_o(qbn_rsp_r),
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o(qbn_wr_v), .wr_ready_i(qbn_wr_r),
      .wr_addr_o(qbn_wr_addr), .wr_len_o(qbn_wr_len), .wr_data_o(qbn_wr_data),
      .wr_rsp_valid_i(qbn_wr_rsp_v), .wr_rsp_ready_o(qbn_wr_rsp_r),
      .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        type_addr_q <= '0;
        type_q <= '0;
        capset_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          type_q <= '0;
          if (req_i.qbn.gnh_only) begin
            capset_q <= 1'b0;
            state_q <= FireQbn;
          end else state_q <= FireAvn;
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            cpl_q <= '{status: APU_QTB_EMPTY};
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid || !type_ok) begin
            cpl_q <= '{status: APU_QTB_FAULT};
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
            cpl_q <= '{status: APU_QTB_FAULT};
            state_q <= Done;
          end else begin
            type_q <= rd_rsp_data_i[31:0];
            capset_q <= (rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET_INFO) ||
                        (rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET);
            if ((rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET_INFO) ||
                (rd_rsp_data_i[31:0] == VGPU_CMD_GET_CAPSET))
              state_q <= FireGcs;
            else state_q <= FireQbn;
          end
        end
        FireGcs: if (gcs_rdy) state_q <= WaitGcs;
        WaitGcs: if (gcs_cpl) begin
          rec_q <= '{
            valid:      gcs_rec.valid,
            capset:     1'b1,
            info:       gcs_rec.info,
            alloc:      1'b0,
            begin_cmd:  1'b0,
            dispatch:   1'b0,
            irq:        gcs_rec.irq,
            type_word:  type_q,
            cmd:        32'd0,
            result:     32'd0,
            handle:     32'd0,
            capset_id:  gcs_rec.capset_id,
            resp_word0: gcs_rec.resp_word0,
            used_idx:   gcs_rec.used_idx,
            resp_addr:  gcs_rec.resp_addr
          };
          cpl_q <= '{status: apu_qtb_status_e'(gcs_c.status)};
          state_q <= Done;
        end
        FireQbn: if (qbn_rdy) state_q <= WaitQbn;
        WaitQbn: if (qbn_cpl) begin
          rec_q <= '{
            valid:      qbn_rec.valid,
            capset:     1'b0,
            info:       1'b0,
            alloc:      qbn_rec.alloc,
            begin_cmd:  qbn_rec.begin_cmd,
            dispatch:   qbn_rec.dispatch,
            irq:        qbn_rec.irq,
            type_word:  type_q,
            cmd:        qbn_rec.cmd,
            result:     qbn_rec.result,
            handle:     qbn_rec.handle,
            capset_id:  32'd0,
            resp_word0: 32'd0,
            used_idx:   qbn_rec.used_idx,
            resp_addr:  qbn_rec.resp_addr
          };
          cpl_q <= '{status: apu_qtb_status_e'(qbn_c.status)};
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

// QueueTypeBegin (qtb) enable-0 fixture: type word selects GrantCapset or QueueBegin.
module g6lc_apu_qtb_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qtb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qtb_cpl_t cpl_o,
  output apu_qtb_t qtb_o,
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
  g6lc_apu_qtb #(.Enable(Enable)) i_dut (.*);
endmodule
