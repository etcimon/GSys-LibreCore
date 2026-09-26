// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Testbench DRAM access-latency model.
//
// Replaces the axi_delayer FIXED_DELAY mechanism for DRAM-latency
// experiments: stream_delay is a single-slot, per-handshake delay (every
// beat costs FixedDelay cycles, and the next beat cannot enter until the
// previous one leaves), and its internal counter is 4 bits wide so
// FixedDelay=40 silently truncated to 8. Both properties penalise long
// bursts exactly where a memory-latency experiment must not.
//
// This module instead models a pipelined access latency: every accepted
// AR (and every completed W beat sequence) earns a deadline Latency
// cycles out, and only the FIRST response beat of each read burst (or the
// B response of each write) is held until that deadline; the remaining
// beats of the burst flow without added delay. Read bursts are assumed
// to return in AR-acceptance order (true for the testbench SRAM backend);
// a sim-only first-beat id check enforces it.
//
// Latency == 0 is the identity case: all five channels are pure wires.
//
// Testbench-only instrument; not a synthesizable design.
module g6lc_tb_dram_latency #(
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter int unsigned Latency        = 0,
    parameter int unsigned Depth          = 32
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    AXI_BUS.Slave  slv,
    AXI_BUS.Master mst
);

  if (Latency == 0) begin : gen_passthrough
    assign mst.aw_id     = slv.aw_id;
    assign mst.aw_addr   = slv.aw_addr;
    assign mst.aw_len    = slv.aw_len;
    assign mst.aw_size   = slv.aw_size;
    assign mst.aw_burst  = slv.aw_burst;
    assign mst.aw_lock   = slv.aw_lock;
    assign mst.aw_cache  = slv.aw_cache;
    assign mst.aw_prot   = slv.aw_prot;
    assign mst.aw_qos    = slv.aw_qos;
    assign mst.aw_atop   = slv.aw_atop;
    assign mst.aw_region = slv.aw_region;
    assign mst.aw_user   = slv.aw_user;
    assign mst.aw_valid  = slv.aw_valid;
    assign slv.aw_ready  = mst.aw_ready;

    assign mst.w_data    = slv.w_data;
    assign mst.w_strb    = slv.w_strb;
    assign mst.w_last    = slv.w_last;
    assign mst.w_user    = slv.w_user;
    assign mst.w_valid   = slv.w_valid;
    assign slv.w_ready   = mst.w_ready;

    assign slv.b_id      = mst.b_id;
    assign slv.b_resp    = mst.b_resp;
    assign slv.b_user    = mst.b_user;
    assign slv.b_valid   = mst.b_valid;
    assign mst.b_ready   = slv.b_ready;

    assign mst.ar_id     = slv.ar_id;
    assign mst.ar_addr   = slv.ar_addr;
    assign mst.ar_len    = slv.ar_len;
    assign mst.ar_size   = slv.ar_size;
    assign mst.ar_burst  = slv.ar_burst;
    assign mst.ar_lock   = slv.ar_lock;
    assign mst.ar_cache  = slv.ar_cache;
    assign mst.ar_prot   = slv.ar_prot;
    assign mst.ar_qos    = slv.ar_qos;
    assign mst.ar_region = slv.ar_region;
    assign mst.ar_user   = slv.ar_user;
    assign mst.ar_valid  = slv.ar_valid;
    assign slv.ar_ready  = mst.ar_ready;

    assign slv.r_id      = mst.r_id;
    assign slv.r_data    = mst.r_data;
    assign slv.r_resp    = mst.r_resp;
    assign slv.r_last    = mst.r_last;
    assign slv.r_user    = mst.r_user;
    assign slv.r_valid   = mst.r_valid;
    assign mst.r_ready   = slv.r_ready;
  end else begin : gen_latency

    localparam int unsigned PTRW = (Depth > 1) ? $clog2(Depth) : 1;
    typedef struct packed {
      logic [31:0]            deadline;
      logic [AXI_ID_WIDTH-1:0] id;
    } rd_entry_t;

    logic [31:0] cycle_q;

    // Read-side deadline FIFO, one entry per accepted AR (in return order).
    rd_entry_t            rd_fifo [Depth];
    logic [PTRW-1:0]      rd_head_q, rd_tail_q;
    logic [PTRW:0]        rd_count_q;
    logic                 rd_pending_q; // first beat of head burst passed

    // Write-side deadline FIFO, one entry per completed W beat sequence.
    logic [31:0]          wr_fifo [Depth];
    logic [PTRW-1:0]      wr_head_q, wr_tail_q;
    logic [PTRW:0]        wr_count_q;

    logic                 ar_hs, w_last_hs, r_hs, r_last_hs, b_hs;
    logic                 rd_gated, wr_gated;

    // AW passes through untouched.
    assign mst.aw_id     = slv.aw_id;
    assign mst.aw_addr   = slv.aw_addr;
    assign mst.aw_len    = slv.aw_len;
    assign mst.aw_size   = slv.aw_size;
    assign mst.aw_burst  = slv.aw_burst;
    assign mst.aw_lock   = slv.aw_lock;
    assign mst.aw_cache  = slv.aw_cache;
    assign mst.aw_prot   = slv.aw_prot;
    assign mst.aw_qos    = slv.aw_qos;
    assign mst.aw_atop   = slv.aw_atop;
    assign mst.aw_region = slv.aw_region;
    assign mst.aw_user   = slv.aw_user;
    assign mst.aw_valid  = slv.aw_valid;
    assign slv.aw_ready  = mst.aw_ready;

    // W passes through; each completed burst earns a B deadline.
    assign mst.w_data    = slv.w_data;
    assign mst.w_strb    = slv.w_strb;
    assign mst.w_last    = slv.w_last;
    assign mst.w_user    = slv.w_user;
    assign mst.w_valid   = slv.w_valid;
    assign slv.w_ready   = mst.w_ready;

    // B is held until the head write deadline.
    assign wr_gated      = (wr_count_q != 0) && (cycle_q < wr_fifo[wr_head_q]);
    assign slv.b_id      = mst.b_id;
    assign slv.b_resp    = mst.b_resp;
    assign slv.b_user    = mst.b_user;
    assign slv.b_valid   = mst.b_valid && !wr_gated;
    assign mst.b_ready   = slv.b_ready && !wr_gated;

    // AR passes through; each accepted AR earns a first-beat deadline.
    assign mst.ar_id     = slv.ar_id;
    assign mst.ar_addr   = slv.ar_addr;
    assign mst.ar_len    = slv.ar_len;
    assign mst.ar_size   = slv.ar_size;
    assign mst.ar_burst  = slv.ar_burst;
    assign mst.ar_lock   = slv.ar_lock;
    assign mst.ar_cache  = slv.ar_cache;
    assign mst.ar_prot   = slv.ar_prot;
    assign mst.ar_qos    = slv.ar_qos;
    assign mst.ar_region = slv.ar_region;
    assign mst.ar_user   = slv.ar_user;
    assign mst.ar_valid  = slv.ar_valid;
    assign slv.ar_ready  = mst.ar_ready;

    // R: only the first beat of the head burst is deadline-gated. valid and
    // ready are suppressed together so the backend sees real backpressure
    // and no beat is dropped or duplicated.
    assign rd_gated      = !rd_pending_q && (rd_count_q != 0) &&
                           (cycle_q < rd_fifo[rd_head_q].deadline);
    assign slv.r_id      = mst.r_id;
    assign slv.r_data    = mst.r_data;
    assign slv.r_resp    = mst.r_resp;
    assign slv.r_last    = mst.r_last;
    assign slv.r_user    = mst.r_user;
    assign slv.r_valid   = mst.r_valid && !rd_gated;
    assign mst.r_ready   = slv.r_ready && !rd_gated;

    assign ar_hs      = mst.ar_valid && mst.ar_ready;
    assign w_last_hs  = mst.w_valid && mst.w_ready && mst.w_last;
    assign r_hs       = mst.r_valid && mst.r_ready;
    assign r_last_hs  = r_hs && mst.r_last;
    assign b_hs       = mst.b_valid && mst.b_ready;

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_dram_latency
      if (!rst_ni) begin
        cycle_q      <= '0;
        rd_head_q    <= '0;
        rd_tail_q    <= '0;
        rd_count_q   <= '0;
        rd_pending_q <= 1'b0;
        wr_head_q    <= '0;
        wr_tail_q    <= '0;
        wr_count_q   <= '0;
      end else begin
        cycle_q <= cycle_q + 32'd1;

        if (ar_hs) begin
          if (rd_count_q == PTRW+1'(Depth)) $fatal(1, "DRAM_LAT_DEPTH");
          rd_fifo[rd_tail_q].deadline <= cycle_q + 32'(Latency);
          rd_fifo[rd_tail_q].id       <= slv.ar_id;
          rd_tail_q <= (rd_tail_q == PTRW'(Depth-1)) ? '0 : rd_tail_q + 1'b1;
        end
        case ({ar_hs, r_last_hs})
          2'b10:   rd_count_q <= rd_count_q + 1'b1;
          2'b01:   rd_count_q <= rd_count_q - 1'b1;
          default: ;
        endcase
        if (r_hs && !rd_pending_q) begin
          // The backend is expected to return read bursts in AR-acceptance
          // order; a different id here breaks the deadline FIFO mapping.
          if (mst.r_id !== rd_fifo[rd_head_q].id) $fatal(1, "DRAM_LAT_ORDER");
          rd_pending_q <= 1'b1;
        end
        if (r_last_hs) begin
          rd_pending_q <= 1'b0;
          rd_head_q <= (rd_head_q == PTRW'(Depth-1)) ? '0 : rd_head_q + 1'b1;
        end

        if (w_last_hs) begin
          if (wr_count_q == PTRW+1'(Depth)) $fatal(1, "DRAM_LAT_DEPTH");
          wr_fifo[wr_tail_q] <= cycle_q + 32'(Latency);
          wr_tail_q <= (wr_tail_q == PTRW'(Depth-1)) ? '0 : wr_tail_q + 1'b1;
        end
        case ({w_last_hs, b_hs})
          2'b10:   wr_count_q <= wr_count_q + 1'b1;
          2'b01:   wr_count_q <= wr_count_q - 1'b1;
          default: ;
        endcase
        if (b_hs) begin
          wr_head_q <= (wr_head_q == PTRW'(Depth-1)) ? '0 : wr_head_q + 1'b1;
        end
      end
    end
  end

endmodule
