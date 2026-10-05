// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// HandleRun then, on dispatch, WRITE the SPIR-V result, virtq_used_elem,
// used.idx, and virtio used-buffer ISR. Publication order is result,
// element, index, interrupt. Create and table ops write nothing.
// Enable=0 elaborates no datapath. Not wired into g6lc_apu_sys.
// FeatureVirgl stays illegal.

// RunDone (rdn): HandleRun dispatch then WRITE result, used.idx, and ISR. Default-off. FeatureVirgl stays illegal.
// Interplay: RunDone (rdn) --> HandleRun (hrn) ==> WRITE then used then ISR. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_rdn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_rdn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_rdn_cpl_t cpl_o,
  output apu_rdn_t rdn_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
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
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rdn_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    ack_valid_i | wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i) | (|in_a_i) |
                    (|in_b_i) | (|ack_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireHrn, WaitHrn, WrPay, WaitPay, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_rdn_cpl_t cpl_q;
    apu_rdn_t rec_q;
    logic [31:0] isr_q, result_q;
    logic [63:0] used_q, resp_addr_q, elem_addr_q;
    logic [15:0] uidx_q, desc_q, next_idx;
    logic [7:0] qsize_q, uslot;
    logic wr_busy, pub_ok;
    logic hrn_req, hrn_rdy, hrn_cpl, hrn_ack, hrn_irq;
    logic [31:0] hrn_res;
    apu_hrn_req_t hrn_req_q;
    apu_hrn_cpl_t hrn_c;
    apu_hrn_t hrn_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_rdn_cpl_t'('0);
    assign rdn_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign hrn_req = state_q == FireHrn;
    assign hrn_ack = state_q == WaitHrn;
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign wr_busy = (state_q == WrPay) || (state_q == WrElem) || (state_q == WrIdx);
    assign wr_valid_o = wr_busy;
    assign wr_rsp_ready_o = (state_q == WaitPay) || (state_q == WaitElem) ||
                            (state_q == WaitIdx);
    assign pub_ok = (resp_addr_q[1:0] == 2'd0) && (used_q[1:0] == 2'd0) &&
                    (qsize_q != 8'd0);

    always_comb begin
      wr_addr_o = resp_addr_q;
      wr_len_o = 32'd4;
      wr_data_o = '0;
      unique case (state_q)
        WrPay, WaitPay: begin
          wr_addr_o = resp_addr_q;
          wr_len_o = 32'd4;
          wr_data_o[31:0] = result_q;
        end
        WrElem, WaitElem: begin
          wr_addr_o = elem_addr_q;
          wr_len_o = 32'd8;
          wr_data_o[31:0]  = {16'h0, desc_q};
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

    g6lc_apu_hrn #(.Enable(1'b1)) i_hrn (
      .clk_i, .rst_ni, .cs_we_i, .cs_idx_i, .cs_wdata_i, .cs_rdata_o,
      .req_valid_i(hrn_req), .req_ready_o(hrn_rdy), .req_i(hrn_req_q),
      .in_a_i, .in_b_i,
      .cpl_valid_o(hrn_cpl), .cpl_ready_i(hrn_ack), .cpl_o(hrn_c),
      .hrn_o(hrn_rec), .irq_o(hrn_irq), .result_o(hrn_res)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        isr_q <= '0;
        result_q <= '0;
        used_q <= '0;
        resp_addr_q <= '0;
        elem_addr_q <= '0;
        uidx_q <= '0;
        desc_q <= '0;
        qsize_q <= '0;
        hrn_req_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            hrn_req_q <= req_i.hrn;
            used_q <= req_i.used_base;
            resp_addr_q <= req_i.resp_addr;
            uidx_q <= req_i.used_idx;
            desc_q <= req_i.desc_id;
            qsize_q <= req_i.queue_size;
            state_q <= FireHrn;
          end
          FireHrn: if (hrn_rdy) state_q <= WaitHrn;
          WaitHrn: if (hrn_cpl) begin
            if (hrn_c.status != APU_HRN_OK || !hrn_rec.valid) begin
              cpl_q.status <= APU_RDN_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else if (!hrn_rec.dispatch) begin
              rec_q.valid <= 1'b1;
              rec_q.dispatch <= 1'b0;
              rec_q.handle <= hrn_rec.handle;
              rec_q.result <= hrn_rec.result;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              cpl_q.status <= APU_RDN_OK;
              state_q <= Done;
            end else if (!pub_ok) begin
              cpl_q.status <= APU_RDN_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else begin
              result_q <= hrn_res;
              rec_q.result <= hrn_res;
              rec_q.handle <= hrn_rec.handle;
              rec_q.dispatch <= 1'b1;
              rec_q.desc_id <= desc_q;
              rec_q.resp_addr <= resp_addr_q;
              rec_q.resp_word0 <= hrn_res;
              elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
              state_q <= WrPay;
            end
          end
          WrPay: if (wr_ready_i) state_q <= WaitPay;
          WaitPay: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_RDN_FAULT;
              state_q <= Done;
            end else state_q <= WrElem;
          end
          WrElem: if (wr_ready_i) state_q <= WaitElem;
          WaitElem: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_RDN_FAULT;
              state_q <= Done;
            end else state_q <= WrIdx;
          end
          WrIdx: if (wr_ready_i) state_q <= WaitIdx;
          WaitIdx: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_RDN_FAULT;
              rec_q.valid <= 1'b0;
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q.valid <= 1'b1;
              rec_q.irq <= 1'b1;
              rec_q.isr <= APU_UIR_ISR_VRING;
              rec_q.used_idx <= next_idx;
              cpl_q.status <= APU_RDN_OK;
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

// RunDone (rdn) enable-0 fixture: HandleRun then WRITE result, used.idx, ISR.
module g6lc_apu_rdn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_rdn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_rdn_cpl_t cpl_o,
  output apu_rdn_t rdn_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  g6lc_apu_rdn #(.Enable(Enable)) i_dut (.*);
endmodule
