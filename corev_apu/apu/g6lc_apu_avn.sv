// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtq_avail.idx plus ring[device_idx] name a descriptor head. NextChain
// follows NEXT. INDIRECT, loops, and empty rings fault or return EMPTY.
// Programmed bases, power-of-two queue size, 16-bit index wrap. Enable=0
// elaborates no datapath. Does not edit g6lc_apu_vgpu_avail. Not wired
// into g6lc_apu_sys. FeatureVirgl stays illegal.

// AvailNext (avn): virtq_avail.idx + ring[head] feeds NextChain. Default-off. FeatureVirgl stays illegal.
// Interplay: AvailNext (avn) --> NextChain (chain) --? AvailDescriptor (avail) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_avn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_avn_cpl_t cpl_o,
  output apu_avn_t avn_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign avn_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                    rd_rsp_valid_i | rd_rsp_ok_i | (|req_i) |
                    (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, RdIdx, WaitIdx, RdRing, WaitRing, FireChain, WaitChain, Done
    } state_e;
    state_e state_q;
    apu_avn_cpl_t cpl_q;
    apu_avn_t rec_q;
    logic [63:0] avail_q, desc_q, addr_q;
    logic [7:0] qsize_q;
    logic [15:0] dev_q, idx_q, head_q;
    logic [3:0] max_q;
    logic slot_odd_q;
    logic pow2_qsize, req_bad, avail_rd;
    logic ch_req_v, ch_rdy, ch_cpl, ch_ack, ch_rd_v, ch_rd_r, ch_rsp_v, ch_rsp_r;
    logic [63:0] ch_rd_addr;
    logic [31:0] ch_rd_len;
    apu_chain_req_t ch_req;
    apu_chain_cpl_t ch_c;
    apu_chain_t ch_rec;
    logic [7:0] slot;
    logic [63:0] ring_byte;

    assign pow2_qsize = (req_i.queue_size != 8'd0) &&
                        ((req_i.queue_size & (req_i.queue_size - 8'd1)) == 8'd0);
    assign req_bad = (req_i.avail_base[1:0] != 2'd0) ||
                     (req_i.desc_base[3:0] != 4'd0) ||
                     !pow2_qsize ||
                     (req_i.queue_size < 8'd2) ||
                     (req_i.queue_size > 8'(APU_CHAIN_QMAX)) ||
                     (req_i.max_chain == 4'd0) ||
                     (req_i.max_chain > 4'(APU_CHAIN_MAX));
    assign slot = 8'(dev_q) & (qsize_q - 8'd1);
    assign ring_byte = avail_q + 64'd4 + (64'(slot) << 1);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_avn_cpl_t'('0);
    assign avn_o = rec_q;
    assign avail_rd = (state_q == RdIdx) || (state_q == RdRing);
    assign rd_valid_o = avail_rd || ch_rd_v;
    assign rd_addr_o = avail_rd ? addr_q : ch_rd_addr;
    assign rd_len_o = avail_rd ? 32'd4 : ch_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitIdx) || (state_q == WaitRing) ||
                            ch_rsp_r;
    assign ch_rd_r = rd_ready_i && !avail_rd;
    assign ch_rsp_v = rd_rsp_valid_i && (state_q == WaitChain);
    assign ch_req_v = state_q == FireChain;
    assign ch_ack = state_q == WaitChain;
    assign ch_req.desc_base = desc_q;
    assign ch_req.queue_size = qsize_q;
    assign ch_req.head = head_q[7:0];
    assign ch_req.max_chain = max_q;

    g6lc_apu_chain #(.Enable(1'b1)) i_chain (
      .clk_i, .rst_ni,
      .req_valid_i(ch_req_v), .req_ready_o(ch_rdy), .req_i(ch_req),
      .cpl_valid_o(ch_cpl), .cpl_ready_i(ch_ack), .cpl_o(ch_c), .chain_o(ch_rec),
      .rd_valid_o(ch_rd_v), .rd_ready_i(ch_rd_r),
      .rd_addr_o(ch_rd_addr), .rd_len_o(ch_rd_len),
      .rd_rsp_valid_i(ch_rsp_v), .rd_rsp_ready_o(ch_rsp_r),
      .rd_rsp_ok_i(rd_rsp_ok_i), .rd_rsp_addr_i(rd_rsp_addr_i),
      .rd_rsp_len_i(rd_rsp_len_i), .rd_rsp_data_i(rd_rsp_data_i)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        avail_q <= '0;
        desc_q <= '0;
        addr_q <= '0;
        qsize_q <= '0;
        dev_q <= '0;
        idx_q <= '0;
        head_q <= '0;
        max_q <= '0;
        slot_odd_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          if (req_bad) begin
            cpl_q.status <= APU_AVN_FAULT;
            state_q <= Done;
          end else begin
            avail_q <= req_i.avail_base;
            desc_q <= req_i.desc_base;
            qsize_q <= req_i.queue_size;
            dev_q <= req_i.device_idx;
            max_q <= req_i.max_chain;
            addr_q <= req_i.avail_base;
            state_q <= RdIdx;
          end
        end
        RdIdx: if (rd_ready_i) state_q <= WaitIdx;
        WaitIdx: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q || rd_rsp_len_i != 32'd4) begin
            cpl_q.status <= APU_AVN_FAULT;
            state_q <= Done;
          end else begin
            idx_q <= rd_rsp_data_i[31:16];
            if (rd_rsp_data_i[31:16] == dev_q) begin
              cpl_q.status <= APU_AVN_EMPTY;
              state_q <= Done;
            end else begin
              addr_q <= {ring_byte[63:2], 2'b00};
              slot_odd_q <= ring_byte[1];
              state_q <= RdRing;
            end
          end
        end
        RdRing: if (rd_ready_i) state_q <= WaitRing;
        WaitRing: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q || rd_rsp_len_i != 32'd4) begin
            cpl_q.status <= APU_AVN_FAULT;
            state_q <= Done;
          end else begin
            head_q <= slot_odd_q ? rd_rsp_data_i[31:16] : rd_rsp_data_i[15:0];
            if ((slot_odd_q ? rd_rsp_data_i[31:16] : rd_rsp_data_i[15:0]) >=
                {8'd0, qsize_q}) begin
              cpl_q.status <= APU_AVN_FAULT;
              state_q <= Done;
            end else state_q <= FireChain;
          end
        end
        FireChain: if (ch_rdy) state_q <= WaitChain;
        WaitChain: if (ch_cpl) begin
          if (ch_c.status != APU_CHAIN_OK || !ch_rec.valid) begin
            cpl_q.status <= APU_AVN_FAULT;
            state_q <= Done;
          end else begin
            rec_q.valid <= 1'b1;
            rec_q.avail_idx <= idx_q;
            rec_q.device_idx <= dev_q + 16'd1;
            rec_q.desc_id <= head_q;
            rec_q.count <= ch_rec.count;
            rec_q.first_addr <= ch_rec.first_addr;
            rec_q.first_len <= ch_rec.first_len;
            rec_q.last_addr <= ch_rec.last_addr;
            rec_q.last_len <= ch_rec.last_len;
            rec_q.last_flags <= ch_rec.last_flags;
            cpl_q.status <= APU_AVN_OK;
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

// AvailNext (avn) enable-0 fixture: virtq_avail into NextChain.
module g6lc_apu_avn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_avn_cpl_t cpl_o,
  output apu_avn_t avn_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_avn #(.Enable(Enable)) i_dut (.*);
endmodule
