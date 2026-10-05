// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Reusable virtq_desc NEXT walker. The table base, queue size, and head
// index are programmed. A walk follows NEXT, snapshots first and last
// payload windows, and rejects INDIRECT, loops, OOB next, zero length,
// and chains longer than max_chain. A fault issues no further read.
// Enable=0 elaborates no datapath. Not g6lc_apu_vgpu_avail, not
// g6lc_apu_vgpu_gnw, and not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal.

// NextChain (chain): Reusable virtq_desc NEXT walker with programmed table base and head. Default-off. FeatureVirgl stays illegal.
// Interplay: NextChain (chain) --? AvailDescriptor (avail) --? GuestNextWalk (gnw). Programmed addresses. See AGENTS-impl-interplays.md.
module g6lc_apu_chain
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_chain_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_chain_cpl_t cpl_o,
  output apu_chain_t chain_o,
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
    assign chain_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                    rd_rsp_valid_i | rd_rsp_ok_i | (|req_i) |
                    (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    state_e state_q;
    apu_chain_cpl_t cpl_q;
    apu_chain_t chain_q;
    logic [63:0] base_q, addr_q;
    logic [7:0] qsize_q, idx_q, head_q;
    logic [3:0] max_q, count_q;
    logic [APU_CHAIN_QMAX-1:0] seen_q;
    logic [63:0] first_addr_q;
    logic [31:0] first_len_q;
    logic [63:0] d_addr;
    logic [31:0] d_len;
    logic [15:0] d_flags, d_next;
    logic req_bad, pow2_qsize;

    assign d_addr = rd_rsp_data_i[63:0];
    assign d_len = rd_rsp_data_i[95:64];
    assign d_flags = rd_rsp_data_i[111:96];
    assign d_next = rd_rsp_data_i[127:112];
    assign pow2_qsize = (req_i.queue_size != 8'd0) &&
                        ((req_i.queue_size & (req_i.queue_size - 8'd1)) == 8'd0);
    assign req_bad = (req_i.desc_base[3:0] != 4'd0) ||
                     !pow2_qsize ||
                     (req_i.queue_size < 8'd2) ||
                     (req_i.queue_size > 8'(APU_CHAIN_QMAX)) ||
                     (req_i.head >= req_i.queue_size) ||
                     (req_i.max_chain == 4'd0) ||
                     (req_i.max_chain > 4'(APU_CHAIN_MAX));

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_chain_cpl_t'('0);
    assign chain_o = chain_q;
    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_CHAIN_DESC_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        chain_q <= '0;
        base_q <= '0;
        addr_q <= '0;
        qsize_q <= '0;
        idx_q <= '0;
        head_q <= '0;
        max_q <= '0;
        count_q <= '0;
        seen_q <= '0;
        first_addr_q <= '0;
        first_len_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          chain_q <= '0;
          if (req_bad) begin
            cpl_q.status <= APU_CHAIN_FAULT;
            state_q <= Done;
          end else begin
            base_q <= req_i.desc_base;
            qsize_q <= req_i.queue_size;
            head_q <= req_i.head;
            max_q <= req_i.max_chain;
            idx_q <= req_i.head;
            count_q <= '0;
            seen_q <= 16'(16'b1 << req_i.head[3:0]);
            addr_q <= req_i.desc_base + (64'(req_i.head) << 4);
            first_addr_q <= '0;
            first_len_q <= '0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_CHAIN_DESC_BYTES) ||
              (d_flags & VIRTQ_DESC_F_INDIRECT) != 16'd0 ||
              d_len == 32'd0) begin
            cpl_q.status <= APU_CHAIN_FAULT;
            state_q <= Done;
          end else if ((d_flags & VIRTQ_DESC_F_NEXT) != 16'd0) begin
            if (d_next >= 16'(qsize_q) || seen_q[d_next[3:0]] ||
                (count_q + 4'd1) >= max_q) begin
              cpl_q.status <= APU_CHAIN_FAULT;
              state_q <= Done;
            end else begin
              if (count_q == 4'd0) begin
                first_addr_q <= d_addr;
                first_len_q <= d_len;
              end
              count_q <= count_q + 4'd1;
              idx_q <= d_next[7:0];
              seen_q[d_next[3:0]] <= 1'b1;
              addr_q <= base_q + (64'(d_next[7:0]) << 4);
              state_q <= Issue;
            end
          end else begin
            chain_q.valid <= 1'b1;
            chain_q.count <= count_q + 4'd1;
            chain_q.head <= head_q;
            chain_q.last_idx <= idx_q;
            chain_q.last_flags <= d_flags;
            chain_q.first_addr <= (count_q == 4'd0) ? d_addr : first_addr_q;
            chain_q.first_len <= (count_q == 4'd0) ? d_len : first_len_q;
            chain_q.last_addr <= d_addr;
            chain_q.last_len <= d_len;
            cpl_q.status <= APU_CHAIN_OK;
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
      cpl_valid_o |-> !req_ready_o && !rd_valid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_CHAIN_OK |-> chain_o.valid &&
        chain_o.count != 4'd0);
    `endif
  end
endmodule

// NextChain (chain) enable-0 fixture: reusable virtq_desc NEXT walker.
module g6lc_apu_chain_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_chain_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_chain_cpl_t cpl_o,
  output apu_chain_t chain_o,
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
  g6lc_apu_chain #(.Enable(Enable)) i_dut (.*);
endmodule
