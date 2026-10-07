// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext walk, snapshot GET_CAPSET / GET_CAPSET_INFO, grant Venus
// id 4 through VenusCapset, WRITE the capset response, then
// virtq_used_elem, used.idx, and virtio used-buffer ISR. Virgl id 1
// faults. EMPTY writes nothing. NumCapsets stays 0 on
// virtio_gpu_config; this is not advertised GET_CAPSET. Enable=0
// elaborates no datapath. Does not edit g6lc_apu_vgpu_avail. Not
// wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// GrantCapset (gcs): AvailNext GET_CAPSET/INFO Venus blob on the WRITE window, then used.idx and ISR. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
// Interplay: GrantCapset (gcs) --> AvailNext (avn) --> VenusCapset (vcap) ==> WRITE then used then ISR. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_gcs
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_gcs_cpl_t cpl_o,
  output apu_gcs_t gcs_o,
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
    assign gcs_o = '0;
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
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                    ack_valid_i | rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i |
                    wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) |
                    (|ack_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireAvn, WaitAvn, RdPay, WaitPay, FireVcap, WaitVcap,
      WrPay, WaitPayWr, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_gcs_cpl_t cpl_q;
    apu_gcs_t rec_q;
    logic [31:0] isr_q, snap_q [APU_CMS_WORDS], rlen_q, ulen_q, off_q;
    logic [63:0] used_q, resp_addr_q, elem_addr_q, pay_addr_q;
    logic [31:0] pay_len_q;
    logic [15:0] uidx_q, desc_q, next_idx;
    logic [7:0] qsize_q, uslot;
    logic info_q, info_now, wr_busy, pay_rd, len_ok, cmd_len_ok;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    logic avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic vcap_req_v, vcap_rdy, vcap_cpl, vcap_ack;
    logic [31:0] remain, beat;
    logic [5:0] wbase;
    apu_avu_req_t req_q;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    apu_vcap_req_t vcap_req;
    apu_vcap_cpl_t vcap_c;
    apu_vcap_t vcap_rec;
    logic [31:0] vcap_blob_unused;
    logic chain_ok, type_ok;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_gcs_cpl_t'('0);
    assign gcs_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign avn_req.avail_base = req_q.avail_base;
    assign avn_req.desc_base = req_q.desc_base;
    assign avn_req.queue_size = req_q.queue_size;
    assign avn_req.device_idx = req_q.device_idx;
    assign avn_req.max_chain = req_q.max_chain;
    assign info_now = snap_q[3'd0] == VGPU_CMD_GET_CAPSET_INFO;
    assign len_ok = (info_now && ulen_q == 32'(APU_GCS_INFO_BYTES)) ||
                    (snap_q[3'd0] == VGPU_CMD_GET_CAPSET &&
                     ulen_q == 32'(APU_GCS_GET_BYTES));
    assign vcap_req_v = state_q == FireVcap && type_ok && len_ok;
    assign vcap_ack = state_q == WaitVcap;
    assign vcap_req.op = info_now ? APU_VCAP_INFO : APU_VCAP_GET;
    assign vcap_req.capset_id = info_now ? APU_VGPU_CAPSET_VENUS : snap_q[3'd6];
    assign vcap_req.capset_version = info_now ? 32'd0 : snap_q[3'd7];
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign pay_rd = state_q == RdPay;
    assign rd_valid_o = pay_rd || avn_rd_v;
    assign rd_addr_o = pay_rd ? pay_addr_q : avn_rd_addr;
    assign rd_len_o = pay_rd ? pay_len_q : avn_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitPay) || avn_rsp_r;
    assign avn_rd_r = rd_ready_i && !pay_rd;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign wr_busy = (state_q == WrPay) || (state_q == WrElem) || (state_q == WrIdx);
    assign wr_valid_o = wr_busy;
    assign wr_rsp_ready_o = (state_q == WaitPayWr) || (state_q == WaitElem) ||
                            (state_q == WaitIdx);
    assign remain = (off_q < rlen_q) ? (rlen_q - off_q) : 32'd0;
    assign beat = (remain > 32'(APU_VGPU_BEAT_BYTES)) ? 32'(APU_VGPU_BEAT_BYTES)
                                                      : remain;
    assign wbase = 6'(off_q[7:2]);
    // Legal command lengths differ per request: GET_CAPSET_INFO is
    // hdr + cap_set_id + padding (APU_CMS_BYTES), GET_CAPSET additionally
    // carries cap_set_version (APU_CMS_BYTES + 4). The exact per-command
    // length is re-checked at FireVcap once the opcode is decoded.
    assign chain_ok = (avn_rec.last_flags & VIRTQ_DESC_F_WRITE) != 16'd0 &&
                      (avn_rec.last_len != 32'd0) &&
                      (avn_rec.last_len[1:0] == 2'd0) &&
                      (avn_rec.last_addr[1:0] == 2'd0) &&
                      ((avn_rec.first_len == 32'(APU_CMS_BYTES)) ||
                       (avn_rec.first_len == 32'(APU_CMS_BYTES) + 32'd4)) &&
                      (avn_rec.first_addr[1:0] == 2'd0) &&
                      (req_q.used_base[1:0] == 2'd0);
    assign cmd_len_ok = info_now ? (pay_len_q == 32'(APU_CMS_BYTES))
                                 : (pay_len_q == 32'(APU_CMS_BYTES) + 32'd4);
    assign type_ok = (snap_q[3'd0] == VGPU_CMD_GET_CAPSET_INFO &&
                      snap_q[3'd6] == 32'd0) ||
                     (snap_q[3'd0] == VGPU_CMD_GET_CAPSET);

    function automatic logic [31:0] gcs_word(input logic [5:0] idx);
      if (idx == 6'd0)
        gcs_word = info_q ? VGPU_RESP_OK_CAPSET_INFO : VGPU_RESP_OK_CAPSET;
      else if (idx < 6'd6)
        gcs_word = snap_q[idx[2:0]];
      else if (info_q) begin
        unique case (idx)
          6'd6: gcs_word = APU_VGPU_CAPSET_VENUS;
          6'd7: gcs_word = 32'd1;
          6'd8: gcs_word = 32'(APU_VCAP_BYTES);
          default: gcs_word = 32'd0;
        endcase
      end else
        gcs_word = apu_vcap_word(idx - 6'd6);
    endfunction

    always_comb begin
      wr_addr_o = resp_addr_q;
      wr_len_o = rlen_q;
      wr_data_o = '0;
      unique case (state_q)
        WrPay, WaitPayWr: begin
          wr_addr_o = resp_addr_q + 64'(off_q);
          wr_len_o = beat;
          wr_data_o[31:0]    = gcs_word(wbase);
          wr_data_o[63:32]   = gcs_word(wbase + 6'd1);
          wr_data_o[95:64]   = gcs_word(wbase + 6'd2);
          wr_data_o[127:96]  = gcs_word(wbase + 6'd3);
          wr_data_o[159:128] = gcs_word(wbase + 6'd4);
          wr_data_o[191:160] = gcs_word(wbase + 6'd5);
          wr_data_o[223:192] = gcs_word(wbase + 6'd6);
          wr_data_o[255:224] = gcs_word(wbase + 6'd7);
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
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i(rd_rsp_ok_i), .rd_rsp_addr_i(rd_rsp_addr_i),
      .rd_rsp_len_i(rd_rsp_len_i), .rd_rsp_data_i(rd_rsp_data_i)
    );

    g6lc_apu_vcap #(.Enable(1'b1)) i_vcap (
      .clk_i, .rst_ni,
      .req_valid_i(vcap_req_v), .req_ready_o(vcap_rdy), .req_i(vcap_req),
      .cpl_valid_o(vcap_cpl), .cpl_ready_i(vcap_ack), .cpl_o(vcap_c),
      .vcap_o(vcap_rec),
      .blob_idx_i(6'd0), .blob_word_o(vcap_blob_unused)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        isr_q <= '0;
        snap_q <= '{default: '0};
        rlen_q <= '0;
        ulen_q <= '0;
        off_q <= '0;
        used_q <= '0;
        resp_addr_q <= '0;
        elem_addr_q <= '0;
        pay_addr_q <= '0;
        pay_len_q <= '0;
        uidx_q <= '0;
        desc_q <= '0;
        qsize_q <= '0;
        info_q <= 1'b0;
        req_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            used_q <= req_i.used_base;
            uidx_q <= req_i.used_idx;
            qsize_q <= req_i.queue_size;
            off_q <= '0;
            info_q <= 1'b0;
            state_q <= FireAvn;
          end
          FireAvn: if (avn_rdy) state_q <= WaitAvn;
          WaitAvn: if (avn_cpl) begin
            if (avn_c.status == APU_AVN_EMPTY) begin
              cpl_q.status <= APU_GCS_EMPTY;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid ||
                         !chain_ok) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else begin
              pay_addr_q <= avn_rec.first_addr;
              pay_len_q <= avn_rec.first_len;
              resp_addr_q <= avn_rec.last_addr;
              ulen_q <= avn_rec.last_len;
              desc_q <= avn_rec.desc_id;
              elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
              rec_q.desc_id <= avn_rec.desc_id;
              rec_q.resp_addr <= avn_rec.last_addr;
              state_q <= RdPay;
            end
          end
          RdPay: if (rd_ready_i) state_q <= WaitPay;
          WaitPay: if (rd_rsp_valid_i) begin
            if (!rd_rsp_ok_i || rd_rsp_addr_i != pay_addr_q ||
                rd_rsp_len_i != pay_len_q) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else begin
              snap_q[0] <= rd_rsp_data_i[31:0];
              snap_q[1] <= rd_rsp_data_i[63:32];
              snap_q[2] <= rd_rsp_data_i[95:64];
              snap_q[3] <= rd_rsp_data_i[127:96];
              snap_q[4] <= rd_rsp_data_i[159:128];
              snap_q[5] <= rd_rsp_data_i[191:160];
              snap_q[6] <= rd_rsp_data_i[223:192];
              snap_q[7] <= rd_rsp_data_i[255:224];
              state_q <= FireVcap;
            end
          end
          FireVcap: begin
            if (!type_ok || !len_ok || !cmd_len_ok) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              state_q <= Done;
            end else if (vcap_rdy) begin
              rlen_q <= info_now ? 32'(APU_GCS_INFO_BYTES)
                                 : 32'(APU_GCS_GET_BYTES);
              info_q <= info_now;
              rec_q.info <= info_now;
              rec_q.capset_id <= APU_VGPU_CAPSET_VENUS;
              rec_q.resp_word0 <= info_now ? VGPU_RESP_OK_CAPSET_INFO
                                           : VGPU_RESP_OK_CAPSET;
              state_q <= WaitVcap;
            end
          end
          WaitVcap: if (vcap_cpl) begin
            if (vcap_c.status != APU_VCAP_OK) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.irq <= isr_q[0];
              rec_q.isr <= isr_q;
              rec_q.valid <= 1'b0;
              rec_q.resp_word0 <= '0;
              rec_q.capset_id <= '0;
              rec_q.info <= 1'b0;
              state_q <= Done;
            end else begin
              off_q <= '0;
              state_q <= WrPay;
            end
          end
          WrPay: if (wr_ready_i) state_q <= WaitPayWr;
          WaitPayWr: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.valid <= 1'b0;
              state_q <= Done;
            end else if ((off_q + beat) == rlen_q) begin
              state_q <= WrElem;
            end else begin
              off_q <= off_q + beat;
              state_q <= WrPay;
            end
          end
          WrElem: if (wr_ready_i) state_q <= WaitElem;
          WaitElem: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.valid <= 1'b0;
              state_q <= Done;
            end else state_q <= WrIdx;
          end
          WrIdx: if (wr_ready_i) state_q <= WaitIdx;
          WaitIdx: if (wr_rsp_valid_i) begin
            if (!wr_rsp_ok_i) begin
              cpl_q.status <= APU_GCS_FAULT;
              rec_q.valid <= 1'b0;
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q.valid <= 1'b1;
              rec_q.irq <= 1'b1;
              rec_q.isr <= APU_UIR_ISR_VRING;
              rec_q.used_idx <= next_idx;
              cpl_q.status <= APU_GCS_OK;
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

// GrantCapset (gcs) enable-0 fixture: GET_CAPSET/INFO then used.idx then ISR.
module g6lc_apu_gcs_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_gcs_cpl_t cpl_o,
  output apu_gcs_t gcs_o,
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
  g6lc_apu_gcs #(.Enable(Enable)) i_dut (.*);
endmodule
