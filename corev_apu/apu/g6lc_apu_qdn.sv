// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One AvailNext walk, then WRITE response, virtq_used_elem, used.idx,
// and virtio used-buffer ISR. Publication order is response, element,
// index, interrupt. EMPTY writes nothing. Enable=0 elaborates no
// datapath. Does not edit g6lc_apu_vgpu_avail. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal.

// QueueDone (qdn): one AvailNext then response, used.idx, and ISR. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueDone (qdn) --> AvailNext (avn) ==> WRITE then used then ISR. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qdn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic resp_we_i,
  input  logic [2:0] resp_idx_i,
  input  logic [31:0] resp_wdata_i,
  input  logic [31:0] resp_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qdn_cpl_t cpl_o,
  output apu_qdn_t qdn_o,
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
    assign qdn_o = '0;
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
    assign unused = clk_i | rst_ni | resp_we_i | req_valid_i | cpl_ready_i |
                    ack_valid_i | rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i |
                    wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) |
                    (|resp_idx_i) | (|resp_wdata_i) | (|resp_len_i) | (|ack_i) |
                    (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireAvn, WaitAvn, WrPay, WaitPay, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_qdn_cpl_t cpl_q;
    apu_qdn_t rec_q;
    logic [31:0] isr_q, resp_q [APU_PRS_WORDS], rlen_q, ulen_q;
    logic [63:0] used_q, resp_addr_q, elem_addr_q;
    logic [15:0] uidx_q, desc_q, next_idx;
    logic [7:0] qsize_q, uslot;
    logic wr_ok_shape, wr_busy;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    apu_avu_req_t req_q;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qdn_cpl_t'('0);
    assign qdn_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign avn_req.avail_base = req_q.avail_base;
    assign avn_req.desc_base = req_q.desc_base;
    assign avn_req.queue_size = req_q.queue_size;
    assign avn_req.device_idx = req_q.device_idx;
    assign avn_req.max_chain = req_q.max_chain;
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign wr_busy = (state_q == WrPay) || (state_q == WrElem) || (state_q == WrIdx);
    assign wr_valid_o = wr_busy;
    assign wr_rsp_ready_o = (state_q == WaitPay) || (state_q == WaitElem) ||
                            (state_q == WaitIdx);
    assign wr_ok_shape = (avn_rec.last_flags & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                         (avn_rec.last_len != 32'd0) &&
                         (avn_rec.last_len <= 32'(APU_PRS_BYTES)) &&
                         (avn_rec.last_len[1:0] == 2'd0) &&
                         (avn_rec.last_addr[1:0] == 2'd0) &&
                         (avn_rec.last_len == rlen_q) &&
                         (req_q.used_base[1:0] == 2'd0);

    always_comb begin
      wr_addr_o = resp_addr_q;
      wr_len_o = rlen_q;
      wr_data_o = '0;
      unique case (state_q)
        WrPay, WaitPay: begin
          wr_addr_o = resp_addr_q;
          wr_len_o = rlen_q;
          wr_data_o[31:0]    = resp_q[0];
          wr_data_o[63:32]   = resp_q[1];
          wr_data_o[95:64]   = resp_q[2];
          wr_data_o[127:96]  = resp_q[3];
          wr_data_o[159:128] = resp_q[4];
          wr_data_o[191:160] = resp_q[5];
          wr_data_o[223:192] = resp_q[6];
          wr_data_o[255:224] = resp_q[7];
        end
        WrElem, WaitElem: begin
          wr_addr_o = elem_addr_q;
          wr_len_o = 32'd8;
          wr_data_o[31:0]  = {16'h0, desc_q};
          wr_data_o[63:32] = ulen_q;
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
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o, .rd_rsp_ok_i,
      .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        isr_q <= '0;
        resp_q <= '{default: '0};
        rlen_q <= '0;
        ulen_q <= '0;
        used_q <= '0;
        resp_addr_q <= '0;
        elem_addr_q <= '0;
        uidx_q <= '0;
        desc_q <= '0;
        qsize_q <= '0;
        req_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: begin
            if (resp_we_i) resp_q[resp_idx_i] <= resp_wdata_i;
            else if (req_valid_i && req_ready_o) begin
              rec_q <= '0;
              req_q <= req_i;
              rlen_q <= resp_len_i;
              used_q <= req_i.used_base;
              uidx_q <= req_i.used_idx;
              qsize_q <= req_i.queue_size;
              state_q <= FireAvn;
            end
          end
          FireAvn: if (avn_rdy) state_q <= WaitAvn;
          WaitAvn: if (avn_cpl) begin
            if (avn_c.status == APU_AVN_EMPTY) begin
              cpl_q.status <= APU_QDN_EMPTY;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid ||
                         !wr_ok_shape) begin
              cpl_q.status <= APU_QDN_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else begin
              resp_addr_q <= avn_rec.last_addr;
              ulen_q <= avn_rec.last_len;
              desc_q <= avn_rec.desc_id;
              elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
              rec_q.desc_id <= avn_rec.desc_id;
              rec_q.resp_addr <= avn_rec.last_addr;
              rec_q.resp_word0 <= resp_q[0];
              state_q <= WrPay;
            end
          end
          WrPay: if (wr_ready_i) state_q <= WaitPay;
          WaitPay: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_QDN_FAULT;
              state_q <= Done;
            end else state_q <= WrElem;
          end
          WrElem: if (wr_ready_i) state_q <= WaitElem;
          WaitElem: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_QDN_FAULT;
              state_q <= Done;
            end else state_q <= WrIdx;
          end
          WrIdx: if (wr_ready_i) state_q <= WaitIdx;
          WaitIdx: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_QDN_FAULT;
              rec_q.valid <= 1'b0;
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q.valid <= 1'b1;
              rec_q.irq <= 1'b1;
              rec_q.isr <= APU_UIR_ISR_VRING;
              rec_q.used_idx <= next_idx;
              cpl_q.status <= APU_QDN_OK;
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

// QueueDone (qdn) enable-0 fixture: response then used.idx then ISR.
module g6lc_apu_qdn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic resp_we_i,
  input  logic [2:0] resp_idx_i,
  input  logic [31:0] resp_wdata_i,
  input  logic [31:0] resp_len_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qdn_cpl_t cpl_o,
  output apu_qdn_t qdn_o,
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
  g6lc_apu_qdn #(.Enable(Enable)) i_dut (.*);
endmodule
