// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext consume then virtq_used: element first, used.idx second.
// The idx store is publication. EMPTY writes nothing. Enable=0
// elaborates no datapath. Does not edit g6lc_apu_vgpu_avail. Not
// wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// AvailUsed (avu): AvailNext then virtq_used elem and used.idx. Default-off. FeatureVirgl stays illegal.
// Interplay: AvailUsed (avu) --> AvailNext (avn) --> NextChain (chain) ==> virtq_used. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_avu
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
  output apu_avu_cpl_t cpl_o,
  output apu_avu_t avu_o,
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
    assign avu_o = '0;
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
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                    rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i | wr_rsp_valid_i |
                    wr_rsp_ok_i | (|req_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireAvn, WaitAvn, WrElem, WaitElem, WrIdx, WaitIdx, Done
    } state_e;
    state_e state_q;
    apu_avu_cpl_t cpl_q;
    apu_avu_t rec_q;
    logic [63:0] used_q, elem_addr_q;
    logic [15:0] uidx_q, next_idx;
    logic [7:0] qsize_q;
    logic [31:0] ulen_q;
    logic pow2_qsize, req_bad;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    apu_avu_req_t req_q;
    apu_avn_req_t avn_req;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    logic [7:0] uslot;

    assign pow2_qsize = (req_i.queue_size != 8'd0) &&
                        ((req_i.queue_size & (req_i.queue_size - 8'd1)) == 8'd0);
    assign req_bad = (req_i.avail_base[1:0] != 2'd0) ||
                     (req_i.desc_base[3:0] != 4'd0) ||
                     (req_i.used_base[1:0] != 2'd0) ||
                     !pow2_qsize ||
                     (req_i.queue_size < 8'd2) ||
                     (req_i.queue_size > 8'(APU_CHAIN_QMAX)) ||
                     (req_i.max_chain == 4'd0) ||
                     (req_i.max_chain > 4'(APU_CHAIN_MAX));
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_avu_cpl_t'('0);
    assign avu_o = rec_q;
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign avn_req.avail_base = req_q.avail_base;
    assign avn_req.desc_base = req_q.desc_base;
    assign avn_req.queue_size = req_q.queue_size;
    assign avn_req.device_idx = req_q.device_idx;
    assign avn_req.max_chain = req_q.max_chain;
    assign uslot = 8'(uidx_q) & (qsize_q - 8'd1);
    assign next_idx = uidx_q + 16'd1;
    assign wr_valid_o = (state_q == WrElem) || (state_q == WrIdx);
    assign wr_addr_o = (state_q == WrIdx) ? used_q : elem_addr_q;
    assign wr_len_o = (state_q == WrIdx) ? 32'd4 : 32'd8;
    assign wr_rsp_ready_o = (state_q == WaitElem) || (state_q == WaitIdx);

    always_comb begin
      wr_data_o = '0;
      if (state_q == WrIdx) wr_data_o[31:0] = {next_idx, 16'h0};
      else begin
        wr_data_o[31:0] = {16'h0, rec_q.desc_id};
        wr_data_o[63:32] = ulen_q;
      end
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
        used_q <= '0;
        elem_addr_q <= '0;
        uidx_q <= '0;
        qsize_q <= '0;
        ulen_q <= '0;
        req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          if (req_bad) begin
            cpl_q.status <= APU_AVU_FAULT;
            state_q <= Done;
          end else begin
            used_q <= req_i.used_base;
            uidx_q <= req_i.used_idx;
            qsize_q <= req_i.queue_size;
            state_q <= FireAvn;
          end
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            cpl_q.status <= APU_AVU_EMPTY;
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid) begin
            cpl_q.status <= APU_AVU_FAULT;
            state_q <= Done;
          end else begin
            rec_q.valid <= 1'b1;
            rec_q.avail_idx <= avn_rec.avail_idx;
            rec_q.device_idx <= avn_rec.device_idx;
            rec_q.desc_id <= avn_rec.desc_id;
            rec_q.count <= avn_rec.count;
            rec_q.first_addr <= avn_rec.first_addr;
            rec_q.last_addr <= avn_rec.last_addr;
            ulen_q <= ((avn_rec.last_flags & VIRTQ_DESC_F_WRITE) != 16'd0)
                      ? avn_rec.last_len : 32'd0;
            elem_addr_q <= used_q + 64'd4 + (64'(uslot) << 3);
            state_q <= WrElem;
          end
        end
        WrElem: if (wr_ready_i) state_q <= WaitElem;
        WaitElem: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i) begin
            cpl_q.status <= APU_AVU_FAULT;
            rec_q.valid <= 1'b0;
            state_q <= Done;
          end else state_q <= WrIdx;
        end
        WrIdx: if (wr_ready_i) state_q <= WaitIdx;
        WaitIdx: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i) begin
            cpl_q.status <= APU_AVU_FAULT;
            rec_q.valid <= 1'b0;
            state_q <= Done;
          end else begin
            rec_q.used_idx <= next_idx;
            rec_q.used_len <= ulen_q;
            cpl_q.status <= APU_AVU_OK;
            state_q <= Done;
          end
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

// AvailUsed (avu) enable-0 fixture: AvailNext then virtq_used.
module g6lc_apu_avu_fixture
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
  output apu_avu_cpl_t cpl_o,
  output apu_avu_t avu_o,
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
  g6lc_apu_avu #(.Enable(Enable)) i_dut (.*);
endmodule
