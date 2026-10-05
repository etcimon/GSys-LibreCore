// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio-mmio notify_pending[0] consumes QueuePumpBegin and pulses
// notify_clear[0]. arm latches control-queue bases. Cursor
// pending[1] faults. CFG/INFO still fire through QueuePumpBegin.
// Enable=0 elaborates no datapath. Does not edit virtio_mmio,
// g6lc_apu_vgpu_avail, or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// NotifyTakeBegin (ntb): virtio notify_pending[0] consumes QueuePumpBegin. Default-off. FeatureVirgl stays illegal.
// Interplay: NotifyTakeBegin (ntb) --> QueuePumpBegin (qpb). --? NotifyTakeAlloc (nta) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_ntb
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_ntb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_ntb_cpl_t cpl_o,
  output apu_ntb_t ntb_o,
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
    assign ntb_o = '0;
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
    typedef enum logic [2:0] { Idle, FireQpb, WaitQpb, Clr, Done } state_e;
    state_e state_q;
    apu_ntb_cpl_t cpl_q;
    apu_ntb_t rec_q;
    apu_ntb_req_t req_q;
    apu_qpb_req_t bind_q, qpb_req;
    logic bound_q, auto_q;
    logic [APU_NUM_QUEUES-1:0] clr_q;
    logic qpb_req_v, qpb_rdy, qpb_cpl, qpb_ack, qpb_irq;
    logic [31:0] qpb_isr;
    apu_qpb_cpl_t qpb_c;
    apu_qpb_t qpb_rec;
    apu_avu_req_t avu_n;

    assign req_ready_o = state_q == Idle && rst_ni && qpb_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_ntb_cpl_t'('0);
    assign ntb_o = rec_q;
    assign irq_o = qpb_irq;
    assign isr_o = qpb_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : '0;
    assign qpb_req_v = state_q == FireQpb;
    assign qpb_ack = state_q == WaitQpb;
    always_comb begin
      qpb_req = auto_q ? bind_q : req_q.qpb;
      if (auto_q) begin
        qpb_req.vcb.op = APU_VCB_NOTIFY;
        qpb_req.vcb.queue_sel = 32'd0;
      end
      avu_n = bind_q.vcb.qtb.qbn.avu;
      avu_n.device_idx = bind_q.vcb.qtb.qbn.avu.device_idx + {8'd0, qpb_rec.count};
      avu_n.used_idx = qpb_rec.used_idx;
    end

    g6lc_apu_qpb #(.Enable(1'b1)) i_qpb (
      .clk_i, .rst_ni,
      .req_valid_i(qpb_req_v), .req_ready_o(qpb_rdy), .req_i(qpb_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qpb_cpl), .cpl_ready_i(qpb_ack), .cpl_o(qpb_c), .qpb_o(qpb_rec),
      .irq_o(qpb_irq), .isr_o(qpb_isr), .ack_valid_i, .ack_i,
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
              bind_q <= req_i.qpb;
              bound_q <= 1'b1;
              rec_q <= '{
                valid:       1'b1,
                bound:       1'b1,
                capset:      1'b0,
                info:        1'b0,
                alloc:       1'b0,
                begin_cmd:   1'b0,
                dispatch:    1'b0,
                irq:         1'b0,
                clear:       2'd0,
                count:       8'd0,
                cfg_rdata:   32'd0,
                num_capsets: 32'(APU_VCB_NUM_CAPSETS),
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
              cpl_q <= '{status: APU_NTB_OK};
              state_q <= Done;
            end else state_q <= FireQpb;
          end else if (qpb_rdy && notify_pending_i[0] && !bound_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_NTB_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else if (qpb_rdy && notify_pending_i[1] && !notify_pending_i[0]) begin
            rec_q <= '{
              valid:       1'b0,
              bound:       bound_q,
              capset:      1'b0,
              info:        1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
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
            cpl_q <= '{status: APU_NTB_FAULT};
            clr_q <= 2'b10;
            state_q <= Clr;
          end else if (qpb_rdy && bound_q && notify_pending_i[0]) begin
            rec_q <= '0;
            auto_q <= 1'b1;
            clr_q <= 2'b01;
            state_q <= FireQpb;
          end
        end
        FireQpb: if (qpb_rdy) state_q <= WaitQpb;
        WaitQpb: if (qpb_cpl) begin
          rec_q <= '{
            valid:       qpb_rec.valid,
            bound:       bound_q,
            capset:      qpb_rec.capset,
            info:        qpb_rec.info,
            alloc:       qpb_rec.alloc,
            begin_cmd:   qpb_rec.begin_cmd,
            dispatch:    qpb_rec.dispatch,
            irq:         qpb_rec.irq,
            clear:       auto_q ? 2'b01 : 2'd0,
            count:       qpb_rec.count,
            cfg_rdata:   qpb_rec.cfg_rdata,
            num_capsets: qpb_rec.num_capsets,
            capset_id:   qpb_rec.capset_id,
            max_version: qpb_rec.max_version,
            max_size:    qpb_rec.max_size,
            type_word:   qpb_rec.type_word,
            cmd:         qpb_rec.cmd,
            result:      qpb_rec.result,
            handle:      qpb_rec.handle,
            resp_word0:  qpb_rec.resp_word0,
            used_idx:    qpb_rec.used_idx,
            resp_addr:   qpb_rec.resp_addr
          };
          cpl_q <= '{status: apu_ntb_status_e'(qpb_c.status)};
          if (auto_q) begin
            bind_q <= '{
              vcb: '{
                op:           APU_VCB_NOTIFY,
                cfg_addr:     bind_q.vcb.cfg_addr,
                capset_index: bind_q.vcb.capset_index,
                queue_sel:    32'd0,
                qtb: '{
                  qbn: '{
                    gnh_only: bind_q.vcb.qtb.qbn.gnh_only,
                    gnh:      bind_q.vcb.qtb.qbn.gnh,
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

// NotifyTakeBegin (ntb) enable-0 fixture: notify_pending[0] consumes QueuePumpBegin.
module g6lc_apu_ntb_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_ntb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_ntb_cpl_t cpl_o,
  output apu_ntb_t ntb_o,
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
  g6lc_apu_ntb #(.Enable(Enable)) i_dut (.*);
endmodule
