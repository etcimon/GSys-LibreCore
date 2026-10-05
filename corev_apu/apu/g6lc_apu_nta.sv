// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio-mmio notify_pending[0] consumes QueuePumpAlloc and pulses
// notify_clear[0]. arm latches control-queue bases. Cursor
// pending[1] faults. CFG/INFO still fire through QueuePumpAlloc.
// Enable=0 elaborates no datapath. Does not edit virtio_mmio,
// g6lc_apu_vgpu_avail, or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// NotifyTakeAlloc (nta): virtio notify_pending[0] consumes QueuePumpAlloc. Default-off. FeatureVirgl stays illegal.
// Interplay: NotifyTakeAlloc (nta) --> QueuePumpAlloc (qpa). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_nta
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_nta_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_nta_cpl_t cpl_o,
  output apu_nta_t nta_o,
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
    assign notify_clear_o = '0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign nta_o = '0;
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
                    (|rd_rsp_data_i) | (|notify_pending_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, FireQpa, WaitQpa, Clr, Done } state_e;
    state_e state_q;
    apu_nta_cpl_t cpl_q;
    apu_nta_t rec_q;
    apu_nta_req_t req_q;
    apu_qpa_req_t bind_q, qpa_req;
    logic bound_q, auto_q;
    logic [APU_NUM_QUEUES-1:0] clr_q;
    logic qpa_req_v, qpa_rdy, qpa_cpl, qpa_ack, qpa_irq;
    logic [31:0] qpa_isr;
    apu_qpa_cpl_t qpa_c;
    apu_qpa_t qpa_rec;
    apu_avu_req_t avu_n;

    assign req_ready_o = state_q == Idle && rst_ni && qpa_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_nta_cpl_t'('0);
    assign nta_o = rec_q;
    assign irq_o = qpa_irq;
    assign isr_o = qpa_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : '0;
    assign qpa_req_v = state_q == FireQpa;
    assign qpa_ack = state_q == WaitQpa;
    always_comb begin
      qpa_req = auto_q ? bind_q : req_q.qpa;
      if (auto_q) begin
        qpa_req.vca.op = APU_VCA_NOTIFY;
        qpa_req.vca.queue_sel = 32'd0;
      end
      avu_n = bind_q.vca.qta.qal.avu;
      avu_n.device_idx = bind_q.vca.qta.qal.avu.device_idx + {8'd0, qpa_rec.count};
      avu_n.used_idx = qpa_rec.used_idx;
    end

    g6lc_apu_qpa #(.Enable(1'b1)) i_qpa (
      .clk_i, .rst_ni,
      .req_valid_i(qpa_req_v), .req_ready_o(qpa_rdy), .req_i(qpa_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qpa_cpl), .cpl_ready_i(qpa_ack), .cpl_o(qpa_c), .qpa_o(qpa_rec),
      .irq_o(qpa_irq), .isr_o(qpa_isr), .ack_valid_i, .ack_i,
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
        bind_q <= '0;
        bound_q <= 1'b0;
        auto_q <= 1'b0;
        clr_q <= '0;
      end else unique case (state_q)
        Idle: begin
          auto_q <= 1'b0;
          if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            if (req_i.arm) begin
              bind_q <= req_i.qpa;
              bound_q <= 1'b1;
              rec_q <= '{
                valid:       1'b1,
                bound:       1'b1,
                capset:      1'b0,
                info:        1'b0,
                alloc:       1'b0,
                dispatch:    1'b0,
                irq:         1'b0,
                clear:       2'd0,
                count:       8'd0,
                cfg_rdata:   32'd0,
                num_capsets: 32'(APU_VCA_NUM_CAPSETS),
                capset_id:   32'd0,
                max_version: 32'd0,
                max_size:    32'd0,
                type_word:   32'd0,
                cmd:         32'd0,
                result:      32'd0,
                handle:      32'd0,
                resp_word0:  32'd0,
                used_idx:    16'd0,
                resp_addr:   64'd0
              };
              cpl_q <= '{status: APU_NTA_OK};
              state_q <= Done;
            end else state_q <= FireQpa;
          end else if (qpa_rdy && notify_pending_i[0] && !bound_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_NTA_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else if (qpa_rdy && notify_pending_i[1] && !notify_pending_i[0]) begin
            rec_q <= '{
              valid:       1'b0,
              bound:       bound_q,
              capset:      1'b0,
              info:        1'b0,
              alloc:       1'b0,
              dispatch:    1'b0,
              irq:         1'b0,
              clear:       2'b10,
              count:       8'd0,
              cfg_rdata:   32'd0,
              num_capsets: 32'd0,
              capset_id:   32'd0,
              max_version: 32'd0,
              max_size:    32'd0,
              type_word:   32'd0,
              cmd:         32'd0,
              result:      32'd0,
              handle:      32'd0,
              resp_word0:  32'd0,
              used_idx:    16'd0,
              resp_addr:   64'd0
            };
            cpl_q <= '{status: APU_NTA_FAULT};
            clr_q <= 2'b10;
            state_q <= Clr;
          end else if (qpa_rdy && bound_q && notify_pending_i[0]) begin
            rec_q <= '0;
            auto_q <= 1'b1;
            clr_q <= 2'b01;
            state_q <= FireQpa;
          end
        end
        FireQpa: if (qpa_rdy) state_q <= WaitQpa;
        WaitQpa: if (qpa_cpl) begin
          rec_q <= '{
            valid:       qpa_rec.valid,
            bound:       bound_q,
            capset:      qpa_rec.capset,
            info:        qpa_rec.info,
            alloc:       qpa_rec.alloc,
            dispatch:    qpa_rec.dispatch,
            irq:         qpa_rec.irq,
            clear:       auto_q ? 2'b01 : 2'd0,
            count:       qpa_rec.count,
            cfg_rdata:   qpa_rec.cfg_rdata,
            num_capsets: qpa_rec.num_capsets,
            capset_id:   qpa_rec.capset_id,
            max_version: qpa_rec.max_version,
            max_size:    qpa_rec.max_size,
            type_word:   qpa_rec.type_word,
            cmd:         qpa_rec.cmd,
            result:      qpa_rec.result,
            handle:      qpa_rec.handle,
            resp_word0:  qpa_rec.resp_word0,
            used_idx:    qpa_rec.used_idx,
            resp_addr:   qpa_rec.resp_addr
          };
          cpl_q <= '{status: apu_nta_status_e'(qpa_c.status)};
          if (auto_q) begin
            bind_q <= '{
              vca: '{
                op:           APU_VCA_NOTIFY,
                cfg_addr:     bind_q.vca.cfg_addr,
                capset_index: bind_q.vca.capset_index,
                queue_sel:    32'd0,
                qta: '{
                  qal: '{
                    gnh_only: bind_q.vca.qta.qal.gnh_only,
                    gnh:      bind_q.vca.qta.qal.gnh,
                    avu:      avu_n
                  }
                }
              }
            };
            state_q <= Clr;
          end else state_q <= Done;
        end
        Clr: state_q <= Done;
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

// NotifyTakeAlloc (nta) enable-0 fixture: notify_pending[0] consumes QueuePumpAlloc.
module g6lc_apu_nta_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_nta_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_nta_cpl_t cpl_o,
  output apu_nta_t nta_o,
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
  g6lc_apu_nta #(.Enable(Enable)) i_dut (.*);
endmodule
