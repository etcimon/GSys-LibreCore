// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext walk, DMA-read the first payload into RunDone CS, then
// CREATE (vkCreateShaderModule) or DISPATCH (vkCmdDispatch). DISPATCH
// publishes the SPIR-V result to the last WRITE window, used.idx, and
// ISR. CREATE and GNH write nothing. EMPTY fetches nothing. Enable=0
// elaborates no datapath. Does not edit g6lc_apu_vgpu_avail. Not wired
// into g6lc_apu_sys. FeatureVirgl stays illegal.

// QueueRun (qrn): AvailNext fetches CS into RunDone CREATE or DISPATCH. Default-off. FeatureVirgl stays illegal.
// Interplay: QueueRun (qrn) --> AvailNext (avn) --> RunDone (rdn) ==> WRITE then used then ISR. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_qrn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qrn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qrn_cpl_t cpl_o,
  output apu_qrn_t qrn_o,
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
    assign qrn_o = '0;
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
      Idle, FireAvn, WaitAvn, RdPay, WaitPay, LoadCs, FireRdn, WaitRdn, Done
    } state_e;
    state_e state_q;
    apu_qrn_cpl_t cpl_q;
    apu_qrn_t rec_q;
    apu_qrn_req_t req_q;
    logic [63:0] pay_addr_q, pay_rd_addr, last_addr_q;
    logic [31:0] pay_len_q, off_q, beat_q, last_len_q, remain, beat;
    logic [15:0] last_flags_q, desc_id_q;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_data_q;
    logic [7:0] wbase_q;
    logic [3:0] load_i_q, nwords_q;
    logic [31:0] cmd_q;
    logic pay_rd, avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic rdn_req_v, rdn_rdy, rdn_cpl, rdn_ack, rdn_cs_we;
    logic [7:0] rdn_cs_idx;
    logic [31:0] rdn_cs_wdata, rdn_cs_rdata;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_rdn_req_t rdn_req_q;
    apu_rdn_cpl_t rdn_c;
    apu_rdn_t rdn_rec;
    logic pay_ok, disp_need, is_create, is_disp;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_qrn_cpl_t'('0);
    assign qrn_o = rec_q;
    assign remain = (off_q < pay_len_q) ? (pay_len_q - off_q) : 32'd0;
    assign beat = (remain > 32'(APU_VGPU_BEAT_BYTES)) ? 32'(APU_VGPU_BEAT_BYTES)
                                                      : remain;
    assign pay_rd = state_q == RdPay;
    assign rd_valid_o = pay_rd || avn_rd_v;
    assign rd_addr_o = pay_rd ? pay_rd_addr : avn_rd_addr;
    assign rd_len_o = pay_rd ? beat_q : avn_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitPay) || avn_rsp_r;
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
    assign rdn_req_v = state_q == FireRdn;
    assign rdn_ack = state_q == WaitRdn;
    assign rdn_cs_we = state_q == LoadCs;
    assign rdn_cs_idx = wbase_q + {4'b0, load_i_q};
    assign rdn_cs_wdata = beat_data_q[{load_i_q[2:0], 5'b0} +: 32];
    assign pay_ok = (avn_rec.first_len != 32'd0) &&
                    (avn_rec.first_len[1:0] == 2'd0) &&
                    (avn_rec.first_addr[1:0] == 2'd0) &&
                    (avn_rec.first_len <= 32'(APU_VNENC_WORDS * 4));
    assign is_create = cmd_q == APU_VNENC_CMD_CREATE_SHADER_MODULE;
    assign is_disp = cmd_q == APU_VND_CMD_DISPATCH;
    assign disp_need = (last_flags_q & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                       (last_len_q >= 32'd4) &&
                       (last_addr_q[1:0] == 2'd0) &&
                       (req_q.avu.used_base[1:0] == 2'd0);

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

    g6lc_apu_rdn #(.Enable(1'b1)) i_rdn (
      .clk_i, .rst_ni, .cs_we_i(rdn_cs_we), .cs_idx_i(rdn_cs_idx),
      .cs_wdata_i(rdn_cs_wdata), .cs_rdata_o(rdn_cs_rdata),
      .req_valid_i(rdn_req_v), .req_ready_o(rdn_rdy), .req_i(rdn_req_q),
      .in_a_i, .in_b_i,
      .cpl_valid_o(rdn_cpl), .cpl_ready_i(rdn_ack), .cpl_o(rdn_c), .rdn_o(rdn_rec),
      .irq_o, .isr_o, .ack_valid_i, .ack_i,
      .wr_valid_o, .wr_ready_i, .wr_addr_o, .wr_len_o, .wr_data_o,
      .wr_rsp_valid_i, .wr_rsp_ready_o, .wr_rsp_ok_i
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
        rdn_req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          off_q <= '0;
          if (req_i.gnh_only) begin
            rdn_req_q <= '0;
            rdn_req_q.hrn.op <= APU_HRN_GNH;
            rdn_req_q.hrn.gnh <= req_i.gnh;
            rdn_req_q.used_base <= req_i.avu.used_base;
            rdn_req_q.resp_addr <= '0;
            rdn_req_q.used_idx <= req_i.avu.used_idx;
            rdn_req_q.queue_size <= req_i.avu.queue_size;
            state_q <= FireRdn;
          end else state_q <= FireAvn;
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            cpl_q.status <= APU_QRN_EMPTY;
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid || !pay_ok) begin
            cpl_q.status <= APU_QRN_FAULT;
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
            rec_q.resp_addr <= avn_rec.last_addr;
            state_q <= RdPay;
          end
        end
        RdPay: if (rd_ready_i) state_q <= WaitPay;
        WaitPay: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != pay_rd_addr ||
              rd_rsp_len_i != beat_q) begin
            cpl_q.status <= APU_QRN_FAULT;
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
              if (!(is_create || is_disp) || (is_disp && !disp_need)) begin
                cpl_q.status <= APU_QRN_FAULT;
                state_q <= Done;
              end else begin
                rdn_req_q <= '0;
                rdn_req_q.hrn.op <= is_disp ? APU_HRN_DISPATCH : APU_HRN_CREATE;
                rdn_req_q.used_base <= req_q.avu.used_base;
                rdn_req_q.resp_addr <= last_addr_q;
                rdn_req_q.used_idx <= req_q.avu.used_idx;
                rdn_req_q.desc_id <= desc_id_q;
                rdn_req_q.queue_size <= req_q.avu.queue_size;
                rec_q.cmd <= cmd_q;
                state_q <= FireRdn;
              end
            end else begin
              off_q <= off_q + beat_q;
              beat_q <= ((pay_len_q - (off_q + beat_q)) > 32'(APU_VGPU_BEAT_BYTES)) ?
                        32'(APU_VGPU_BEAT_BYTES) : (pay_len_q - (off_q + beat_q));
              state_q <= RdPay;
            end
          end else load_i_q <= load_i_q + 4'd1;
        end
        FireRdn: if (rdn_rdy) state_q <= WaitRdn;
        WaitRdn: if (rdn_cpl) begin
          if (rdn_c.status != APU_RDN_OK || !rdn_rec.valid) begin
            rec_q.valid <= 1'b0;
            rec_q.irq <= rdn_rec.irq;
            cpl_q.status <= APU_QRN_FAULT;
          end else begin
            rec_q.valid <= 1'b1;
            rec_q.dispatch <= rdn_rec.dispatch;
            rec_q.irq <= rdn_rec.irq;
            rec_q.result <= rdn_rec.result;
            rec_q.handle <= rdn_rec.handle;
            rec_q.used_idx <= rdn_rec.used_idx;
            rec_q.resp_addr <= rdn_rec.resp_addr;
            rec_q.cmd <= cmd_q;
            cpl_q.status <= APU_QRN_OK;
          end
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

// QueueRun (qrn) enable-0 fixture: AvailNext CS into RunDone.
module g6lc_apu_qrn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_qrn_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_qrn_cpl_t cpl_o,
  output apu_qrn_t qrn_o,
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
  g6lc_apu_qrn #(.Enable(Enable)) i_dut (.*);
endmodule
