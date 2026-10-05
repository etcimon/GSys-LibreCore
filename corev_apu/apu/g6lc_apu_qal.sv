// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext walk, DMA-read the first payload into AllocRun CS, then
// ALLOC (vkAllocateCommandBuffers), CREATE, or DISPATCH. DISPATCH
// publishes the SPIR-V result to the last WRITE window, used.idx, and
// ISR. ALLOC, CREATE, and GNH write nothing. EMPTY fetches nothing.
// Enable=0 elaborates no datapath. Does not edit g6lc_apu_vgpu_avail.
// Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// QueueAlloc (qal): AvailNext CS into AllocRun ALLOC/CREATE/DISPATCH. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueAlloc (qal) --> AvailNext (avn) --> AllocRun (aru) ==> WRITE then used then ISR. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qal
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qal_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qal_cpl_t cpl_o,
  output apu_qal_t qal_o,
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
    assign qal_o = '0;
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
      Idle, FireAvn, WaitAvn, RdPay, WaitRd, LoadCs, FireAru, WaitAru,
      WrPay, WaitWr, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_qal_cpl_t cpl_q;
    apu_qal_t rec_q;
    apu_qal_req_t req_q;
    logic [63:0] pay_addr_q, pay_rd_addr, last_addr_q, used_q, elem_addr_q;
    logic [31:0] pay_len_q, off_q, beat_q, last_len_q, remain, beat, isr_q, result_q;
    logic [15:0] last_flags_q, desc_id_q, uidx_q, next_idx;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_data_q;
    logic [7:0] wbase_q, qsize_q, uslot;
    logic [3:0] load_i_q, nwords_q;
    logic [31:0] cmd_q;
    logic pay_rd, avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic aru_req_v, aru_rdy, aru_cpl, aru_ack, aru_cs_we, aru_irq;
    logic [7:0] aru_cs_idx;
    logic [31:0] aru_cs_wdata, aru_cs_rdata, aru_res;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_aru_req_t aru_req_q;
    apu_aru_cpl_t aru_c;
    apu_aru_t aru_rec;
    logic pay_ok, disp_need, is_create, is_disp, is_alloc, wr_busy, pub_ok;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qal_cpl_t'('0);
    assign qal_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign remain = (off_q < pay_len_q) ? (pay_len_q - off_q) : 32'd0;
    assign beat = (remain > 32'(APU_VGPU_BEAT_BYTES)) ? 32'(APU_VGPU_BEAT_BYTES)
                                                      : remain;
    assign pay_rd = state_q == RdPay;
    assign rd_valid_o = pay_rd || avn_rd_v;
    assign rd_addr_o = pay_rd ? pay_rd_addr : avn_rd_addr;
    assign rd_len_o = pay_rd ? beat_q : avn_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitRd) || avn_rsp_r;
    assign avn_rd_r = rd_ready_i && !pay_rd;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign avn_req.avail_base = req_q.avu.avail_base;
    assign avn_req.desc_base = req_q.avu.desc_base;
    assign avn_req.queue_size = req_q.avu.queue_size;
    assign avn_req.device_idx = req_q.avu.device_idx;
    assign avn_req.max_chain = req_q.avu.max_chain;
    assign pay_rd_addr = pay_addr_q + 64'(off_q);
    assign aru_req_v = state_q == FireAru;
    assign aru_ack = state_q == WaitAru;
    assign aru_cs_we = state_q == LoadCs;
    assign aru_cs_idx = wbase_q + {4'b0, load_i_q};
    assign aru_cs_wdata = beat_data_q[{load_i_q[2:0], 5'b0} +: 32];
    assign pay_ok = (avn_rec.first_len != 32'd0) &&
                    (avn_rec.first_len[1:0] == 2'd0) &&
                    (avn_rec.first_addr[1:0] == 2'd0) &&
                    (avn_rec.first_len <= 32'(APU_VNENC_WORDS * 4));
    assign is_create = cmd_q == APU_VNENC_CMD_CREATE_SHADER_MODULE;
    assign is_disp = cmd_q == APU_VND_CMD_DISPATCH;
    assign is_alloc = cmd_q == APU_VAC_CMD_ALLOC;
    assign disp_need = (last_flags_q & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                       (last_len_q >= 32'd4) &&
                       (last_addr_q[1:0] == 2'd0) &&
                       (req_q.avu.used_base[1:0] == 2'd0);
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign wr_busy = (state_q == WrPay) || (state_q == WrElem) || (state_q == WrIdx);
    assign wr_valid_o = wr_busy;
    assign wr_rsp_ready_o = (state_q == WaitWr) || (state_q == WaitElem) ||
                            (state_q == WaitIdx);
    assign pub_ok = (last_addr_q[1:0] == 2'd0) && (used_q[1:0] == 2'd0) &&
                    (qsize_q != 8'd0);

    always_comb begin
      wr_addr_o = last_addr_q;
      wr_len_o = 32'd4;
      wr_data_o = '0;
      unique case (state_q)
        WrPay, WaitWr: begin
          wr_addr_o = last_addr_q;
          wr_len_o = 32'd4;
          wr_data_o[31:0] = result_q;
        end
        WrElem, WaitElem: begin
          wr_addr_o = elem_addr_q;
          wr_len_o = 32'd8;
          wr_data_o[31:0]  = {16'h0, desc_id_q};
          wr_data_o[63:32] = 32'd4;
        end
        WrIdx, WaitIdx: begin
          wr_addr_o = used_q;
          wr_len_o = 32'd4;
          wr_data_o[31:0] = {next_idx, 16'h0};
        end
        default: ;
      endcase
    end

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(avn_req),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i(rd_rsp_ok_i), .rd_rsp_addr_i(rd_rsp_addr_i),
      .rd_rsp_len_i(rd_rsp_len_i), .rd_rsp_data_i(rd_rsp_data_i)
    );

    g6lc_apu_aru #(.Enable(1'b1)) i_aru (
      .clk_i, .rst_ni, .cs_we_i(aru_cs_we), .cs_idx_i(aru_cs_idx),
      .cs_wdata_i(aru_cs_wdata), .cs_rdata_o(aru_cs_rdata),
      .req_valid_i(aru_req_v), .req_ready_o(aru_rdy), .req_i(aru_req_q),
      .in_a_i, .in_b_i,
      .cpl_valid_o(aru_cpl), .cpl_ready_i(aru_ack), .cpl_o(aru_c), .aru_o(aru_rec),
      .irq_o(aru_irq), .result_o(aru_res)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        pay_addr_q <= '0;
        pay_len_q <= '0;
        last_addr_q <= '0;
        last_len_q <= '0;
        last_flags_q <= '0;
        desc_id_q <= '0;
        off_q <= '0;
        beat_q <= '0;
        beat_data_q <= '0;
        wbase_q <= '0;
        load_i_q <= '0;
        nwords_q <= '0;
        cmd_q <= '0;
        aru_req_q <= '0;
        isr_q <= '0;
        result_q <= '0;
        used_q <= '0;
        elem_addr_q <= '0;
        uidx_q <= '0;
        qsize_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            off_q <= '0;
            used_q <= req_i.avu.used_base;
            uidx_q <= req_i.avu.used_idx;
            qsize_q <= req_i.avu.queue_size;
            if (req_i.gnh_only) begin
              aru_req_q <= '{op: APU_ARU_GNH, gnh: req_i.gnh};
              state_q <= FireAru;
            end else state_q <= FireAvn;
          end
          FireAvn: if (avn_rdy) state_q <= WaitAvn;
          WaitAvn: if (avn_cpl) begin
            if (avn_c.status == APU_AVN_EMPTY) begin
              cpl_q <= '{status: APU_QAL_EMPTY};
              state_q <= Done;
            end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid || !pay_ok) begin
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else begin
              pay_addr_q <= avn_rec.first_addr;
              pay_len_q <= avn_rec.first_len;
              last_addr_q <= avn_rec.last_addr;
              last_len_q <= avn_rec.last_len;
              last_flags_q <= avn_rec.last_flags;
              desc_id_q <= avn_rec.desc_id;
              off_q <= '0;
              beat_q <= (avn_rec.first_len > 32'(APU_VGPU_BEAT_BYTES)) ?
                        32'(APU_VGPU_BEAT_BYTES) : avn_rec.first_len;
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       '0,
                result:    '0,
                handle:    '0,
                used_idx:  req_q.avu.used_idx,
                resp_addr: avn_rec.last_addr
              };
              state_q <= RdPay;
            end
          end
          RdPay: if (rd_ready_i) state_q <= WaitRd;
          WaitRd: if (rd_rsp_valid_i) begin
            if (!rd_rsp_ok_i || rd_rsp_addr_i != pay_rd_addr ||
                rd_rsp_len_i != beat_q) begin
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else begin
              beat_data_q <= rd_rsp_data_i;
              wbase_q <= off_q[9:2];
              nwords_q <= beat_q[5:2];
              load_i_q <= '0;
              if (off_q == 32'd0) cmd_q <= rd_rsp_data_i[31:0];
              state_q <= LoadCs;
            end
          end
          LoadCs: begin
            if (load_i_q + 4'd1 == nwords_q) begin
              if ((off_q + beat_q) == pay_len_q) begin
                if (!(is_create || is_disp || is_alloc) ||
                    (is_disp && !disp_need)) begin
                  cpl_q <= '{status: APU_QAL_FAULT};
                  state_q <= Done;
                end else begin
                  aru_req_q <= '{
                    op: is_disp ? APU_ARU_DISPATCH :
                        (is_alloc ? APU_ARU_ALLOC : APU_ARU_CREATE),
                    gnh: '0
                  };
                  rec_q <= '{
                    valid:     1'b0,
                    alloc:     is_alloc,
                    dispatch:  is_disp,
                    irq:       isr_q[0],
                    cmd:       cmd_q,
                    result:    '0,
                    handle:    '0,
                    used_idx:  uidx_q,
                    resp_addr: last_addr_q
                  };
                  state_q <= FireAru;
                end
              end else begin
                off_q <= off_q + beat_q;
                beat_q <= ((pay_len_q - (off_q + beat_q)) > 32'(APU_VGPU_BEAT_BYTES)) ?
                          32'(APU_VGPU_BEAT_BYTES) : (pay_len_q - (off_q + beat_q));
                state_q <= RdPay;
              end
            end else load_i_q <= load_i_q + 4'd1;
          end
          FireAru: if (aru_rdy) state_q <= WaitAru;
          WaitAru: if (aru_cpl) begin
            if (aru_c.status != APU_ARU_OK || !aru_rec.valid) begin
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    '0,
                handle:    '0,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else if (!aru_rec.dispatch) begin
              rec_q <= '{
                valid:     1'b1,
                alloc:     aru_rec.alloc,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    aru_rec.result,
                handle:    aru_rec.handle,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QAL_OK};
              state_q <= Done;
            end else if (!pub_ok) begin
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                dispatch:  1'b0,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    '0,
                handle:    '0,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else begin
              result_q <= aru_res;
              rec_q <= '{
                valid:     1'b0,
                alloc:     1'b0,
                dispatch:  1'b1,
                irq:       isr_q[0],
                cmd:       cmd_q,
                result:    aru_res,
                handle:    aru_rec.handle,
                used_idx:  uidx_q,
                resp_addr: last_addr_q
              };
              elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
              state_q <= WrPay;
            end
          end
          WrPay: if (wr_ready_i) state_q <= WaitWr;
          WaitWr: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else state_q <= WrElem;
          end
          WrElem: if (wr_ready_i) state_q <= WaitElem;
          WaitElem: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else state_q <= WrIdx;
          end
          WrIdx: if (wr_ready_i) state_q <= WaitIdx;
          WaitIdx: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              rec_q <= '0;
              cpl_q <= '{status: APU_QAL_FAULT};
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q <= '{
                valid:     1'b1,
                alloc:     1'b0,
                dispatch:  1'b1,
                irq:       1'b1,
                cmd:       cmd_q,
                result:    result_q,
                handle:    rec_q.handle,
                used_idx:  next_idx,
                resp_addr: last_addr_q
              };
              cpl_q <= '{status: APU_QAL_OK};
              state_q <= Done;
            end
          end
          Done: if (cpl_ready_i) state_q <= Idle;
          default: state_q <= Idle;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// QueueAlloc (qal) enable-0 fixture: AvailNext CS into AllocRun.
module g6lc_apu_qal_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qal_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qal_cpl_t cpl_o,
  output apu_qal_t qal_o,
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
  g6lc_apu_qal #(.Enable(Enable)) i_dut (.*);
endmodule
