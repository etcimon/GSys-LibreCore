// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio-mmio notify_pending[0] consumes QueuePump and pulses
// notify_clear[0]. BIND latches control-queue bases. Cursor
// pending[1] faults. CFG/INFO still fire through QueuePump.
// Enable=0 elaborates no datapath. Does not edit virtio_mmio,
// g6lc_apu_vgpu_avail, or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// NotifyTake (ntk): virtio notify_pending[0] consumes QueuePump. Default-off. FeatureVirgl stays illegal.
// Interplay: NotifyTake (ntk) --> QueuePump (qpu). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_ntk
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_ntk_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_ntk_cpl_t cpl_o,
  output apu_ntk_t ntk_o,
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
    assign ntk_o = '0;
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
    typedef enum logic [2:0] { Idle, FireQpu, WaitQpu, Clr, Done } state_e;
    state_e state_q;
    apu_ntk_cpl_t cpl_q;
    apu_ntk_t rec_q;
    apu_ntk_req_t req_q;
    apu_qpu_req_t bind_q, qpu_req;
    logic bound_q, auto_q;
    logic [APU_NUM_QUEUES-1:0] clr_q;
    logic qpu_req_v, qpu_rdy, qpu_cpl, qpu_ack, qpu_irq;
    logic [31:0] qpu_isr;
    apu_qpu_cpl_t qpu_c;
    apu_qpu_t qpu_rec;
    apu_avu_req_t avu_n;

    assign req_ready_o = state_q == Idle && rst_ni && qpu_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_ntk_cpl_t'('0);
    assign ntk_o = rec_q;
    assign irq_o = qpu_irq;
    assign isr_o = qpu_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : '0;
    assign qpu_req_v = state_q == FireQpu;
    assign qpu_ack = state_q == WaitQpu;
    always_comb begin
      qpu_req = auto_q ? bind_q : req_q.qpu;
      if (auto_q) begin
        qpu_req.vct.op = APU_VCT_NOTIFY;
        qpu_req.vct.queue_sel = 32'd0;
      end
      avu_n = bind_q.vct.qty.qrn.avu;
      avu_n.device_idx = bind_q.vct.qty.qrn.avu.device_idx + {8'd0, qpu_rec.count};
      avu_n.used_idx = qpu_rec.used_idx;
    end

    g6lc_apu_qpu #(.Enable(1'b1)) i_qpu (
      .clk_i, .rst_ni,
      .req_valid_i(qpu_req_v), .req_ready_o(qpu_rdy), .req_i(qpu_req),
      .in_a_i, .in_b_i,
      .cpl_valid_o(qpu_cpl), .cpl_ready_i(qpu_ack), .cpl_o(qpu_c), .qpu_o(qpu_rec),
      .irq_o(qpu_irq), .isr_o(qpu_isr), .ack_valid_i, .ack_i,
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
              bind_q <= req_i.qpu;
              bound_q <= 1'b1;
              rec_q <= '{
                valid:       1'b1,
                bound:       1'b1,
                capset:      1'b0,
                info:        1'b0,
                dispatch:    1'b0,
                irq:         1'b0,
                clear:       2'd0,
                count:       8'd0,
                cfg_rdata:   32'd0,
                num_capsets: 32'(APU_VCT_NUM_CAPSETS),
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
              cpl_q <= '{status: APU_NTK_OK};
              state_q <= Done;
            end else state_q <= FireQpu;
          end else if (qpu_rdy && notify_pending_i[0] && !bound_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_NTK_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else if (qpu_rdy && notify_pending_i[1] && !notify_pending_i[0]) begin
            rec_q <= '0;
            rec_q <= '{
              valid:       1'b0,
              bound:       bound_q,
              capset:      1'b0,
              info:        1'b0,
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
            cpl_q <= '{status: APU_NTK_FAULT};
            clr_q <= 2'b10;
            state_q <= Clr;
          end else if (qpu_rdy && bound_q && notify_pending_i[0]) begin
            rec_q <= '0;
            auto_q <= 1'b1;
            clr_q <= 2'b01;
            state_q <= FireQpu;
          end
        end
        FireQpu: if (qpu_rdy) state_q <= WaitQpu;
        WaitQpu: if (qpu_cpl) begin
          rec_q <= '{
            valid:       qpu_rec.valid,
            bound:       bound_q,
            capset:      qpu_rec.capset,
            info:        qpu_rec.info,
            dispatch:    qpu_rec.dispatch,
            irq:         qpu_rec.irq,
            clear:       auto_q ? 2'b01 : 2'd0,
            count:       qpu_rec.count,
            cfg_rdata:   qpu_rec.cfg_rdata,
            num_capsets: qpu_rec.num_capsets,
            capset_id:   qpu_rec.capset_id,
            max_version: qpu_rec.max_version,
            max_size:    qpu_rec.max_size,
            type_word:   qpu_rec.type_word,
            cmd:         qpu_rec.cmd,
            result:      qpu_rec.result,
            handle:      qpu_rec.handle,
            resp_word0:  qpu_rec.resp_word0,
            used_idx:    qpu_rec.used_idx,
            resp_addr:   qpu_rec.resp_addr
          };
          cpl_q <= '{status: apu_ntk_status_e'(qpu_c.status)};
          if (auto_q) begin
            bind_q <= '{
              vct: '{
                op:           APU_VCT_NOTIFY,
                cfg_addr:     bind_q.vct.cfg_addr,
                capset_index: bind_q.vct.capset_index,
                queue_sel:    32'd0,
                qty: '{
                  qrn: '{
                    gnh_only: bind_q.vct.qty.qrn.gnh_only,
                    gnh:      bind_q.vct.qty.qrn.gnh,
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

// NotifyTake (ntk) enable-0 fixture: notify_pending[0] consumes QueuePump.
module g6lc_apu_ntk_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_ntk_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_ntk_cpl_t cpl_o,
  output apu_ntk_t ntk_o,
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
  g6lc_apu_ntk #(.Enable(Enable)) i_dut (.*);
endmodule
