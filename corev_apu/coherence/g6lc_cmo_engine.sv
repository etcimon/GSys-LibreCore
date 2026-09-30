// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// T9a eWT CMO engine — serializes per-core Zicbom cache-block ops and pushes
// them through the cache hierarchy. One CMO in flight, round-robin over the
// cores' cmo_valid_i (a core's WT tracker holds its request until ready).
//
//   inval (op 0):  three parallel pushes —
//                  (1) L1 broadcast to ALL cores, issued into a dedicated
//                      g6lc_l3_inclusive_inv instance in the cluster (the
//                      broadcaster drains once every core has accepted);
//                  (2) L2 tag match-inval via l2_inval_* (the cluster
//                      arbitrates this wire with the inclusive victim source;
//                      the victim wins and the engine simply keeps
//                      l2_inval_valid_o raised);
//                  (3) L3 tag match-inval via l3_inval_*.
//                  done pulses only after the L1 broadcast has drained, so a
//                  retiring cbo.inval is ordered behind every level's invalid
//                  state.
//   clean (op 1) /
//   flush (op 2): done once l2_write_idle_i && l3_write_idle_i — under eWT
//                  there is no dirty state to write back; the contract is
//                  ordering against in-flight writes, which write-idle gives.
//
// All handshakes are explicit valid/ready; no combinational path from any
// ready input back into a request grant, and no combinational loop between
// the engine and the cluster arbitration.

module g6lc_cmo_engine #(
    parameter int unsigned NR_CORES = 1,
    // Request ports: the NR_CORES core sidebands plus optional non-core writers
    // (the AI island's DMA-write invalidation queue, AiCfg.DmaInvalEn). Writer
    // ports index from NR_CORES upward and are inval-only by contract.
    parameter int unsigned NR_WRITERS = NR_CORES,
    // Tie off levels that do not exist: the corresponding inval step is
    // skipped and the write-idle input is ignored (tie it high).
    parameter bit          L2_EN  = 1'b1,
    parameter bit          L3_EN  = 1'b0,
    parameter int unsigned AXI_ADDR_WIDTH = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Per-core request sideband (core's cmo_* outputs). ready = accept into
    // the engine; done = the whole hierarchy completed the op.
    input  logic [NR_WRITERS-1:0]     cmo_valid_i,
    input  logic [1:0]                cmo_op_i   [NR_WRITERS],
    input  logic [AXI_ADDR_WIDTH-1:0] cmo_addr_i [NR_WRITERS],
    output logic [NR_WRITERS-1:0]     cmo_ready_o,
    output logic [NR_WRITERS-1:0]     cmo_done_o,
    // L1 broadcast (into the cluster's broadcaster instance): valid is held
    // until l1_bcast_ready_i captures the line; l1_bcast_done_i pulses when
    // every core's invalidation was accepted.
    output logic                      l1_bcast_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] l1_bcast_addr_o,
    input  logic                      l1_bcast_ready_i,
    input  logic                      l1_bcast_done_i,
    // L2/L3 tag match-inval requests (ready = applied; both are single-cycle
    // tag clears, but the L2 one loses the slot to an inclusive victim and
    // must simply keep valid raised).
    output logic                      l2_inval_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] l2_inval_addr_o,
    input  logic                      l2_inval_ready_i,
    output logic                      l3_inval_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0] l3_inval_addr_o,
    input  logic                      l3_inval_ready_i,
    // Write-idle for clean/flush ordering
    input  logic                      l2_write_idle_i,
    input  logic                      l3_write_idle_i
);

  localparam logic [1:0] CMO_OP_INVAL = 2'd0;
  // 2'd1 = clean, 2'd2 = flush — identical wait-write-idle handling

  typedef enum logic [2:0] {
    S_IDLE,
    S_ISSUE,
    S_WAIT_L1,
    S_DONE
  } state_e;

  state_e                       state_q, state_d;
  logic [$clog2(NR_WRITERS > 1 ? NR_WRITERS : 2)-1:0] sel_q, sel_d;
  logic [$clog2(NR_WRITERS > 1 ? NR_WRITERS : 2)-1:0] rr_ptr_q, rr_ptr_d;
  logic [1:0]                   op_q, op_d;
  logic [AXI_ADDR_WIDTH-1:0]    addr_q, addr_d;
  logic                         l1_sent_q, l1_sent_d;
  // The broadcaster's drain_done is a one-cycle pulse that can fire while
  // the L2/L3 pushes are still waiting — latch it or the done is lost. The
  // latch lives in the FF (not the comb default) so no always_comb reads
  // l1_bcast_done_i: the cluster pairing would otherwise form a
  // block-granularity comb loop (done_i -> this block -> bcast_valid ->
  // broadcaster block -> done_i).
  logic                         l1_done_q, l1_done_d;
  logic                         l2_done_q, l2_done_d;
  logic                         l3_done_q, l3_done_d;

  // Round-robin request pick: first valid at or after rr_ptr_q, wrapping.
  logic [NR_WRITERS-1:0] req_v;
  assign req_v = cmo_valid_i;
  function automatic logic [$bits(sel_q)-1:0] rr_pick(
      input logic [NR_WRITERS-1:0] v,
      input int unsigned ptr
  );
    for (int unsigned i = 0; i < NR_WRITERS; i++) begin
      automatic int unsigned c = (ptr + i) % NR_WRITERS;
      if (v[c]) return $bits(sel_q)'(c);
    end
    return $bits(sel_q)'(ptr % NR_WRITERS);
  endfunction

  wire logic [$bits(sel_q)-1:0] sel_c = rr_pick(req_v, int'(rr_ptr_q));
  wire logic                    sel_valid = req_v[sel_c];

  always_comb begin
    state_d    = state_q;
    sel_d      = sel_q;
    rr_ptr_d   = rr_ptr_q;
    op_d       = op_q;
    addr_d     = addr_q;
    l1_sent_d  = l1_sent_q;
    l1_done_d  = l1_done_q;
    l2_done_d  = l2_done_q;
    l3_done_d  = l3_done_q;

    cmo_ready_o       = '0;
    cmo_done_o        = '0;
    l1_bcast_valid_o  = 1'b0;
    l1_bcast_addr_o   = addr_q;
    l2_inval_valid_o  = 1'b0;
    l2_inval_addr_o   = addr_q;
    l3_inval_valid_o  = 1'b0;
    l3_inval_addr_o   = addr_q;

    unique case (state_q)
      S_IDLE: begin
        if (sel_valid) begin
          cmo_ready_o[sel_c] = 1'b1;
          sel_d   = sel_c;
          op_d    = cmo_op_i[sel_c];
          addr_d  = cmo_addr_i[sel_c];
          l1_sent_d = 1'b0;
          l1_done_d = 1'b0;
          l2_done_d = !L2_EN;
          l3_done_d = !L3_EN;
          // rotate past the granted core for next time
          rr_ptr_d = (int'(sel_c) == NR_WRITERS-1) ? '0
                     : $bits(rr_ptr_q)'(int'(sel_c) + 1);
          state_d = S_ISSUE;
        end
      end

      S_ISSUE: begin
        if (op_q == CMO_OP_INVAL) begin
          // All three level pushes may proceed in parallel; each records its
          // own accept so a losing arbitration (victim wins the L2 slot) just
          // keeps the offer raised.
          if (!l1_sent_q) begin
            l1_bcast_valid_o = 1'b1;
            if (l1_bcast_ready_i) l1_sent_d = 1'b1;
          end
          if (!l2_done_q) begin
            l2_inval_valid_o = 1'b1;
            if (l2_inval_ready_i) l2_done_d = 1'b1;
          end
          if (!l3_done_q) begin
            l3_inval_valid_o = 1'b1;
            if (l3_inval_ready_i) l3_done_d = 1'b1;
          end
          if ((l1_sent_q || (l1_bcast_valid_o && l1_bcast_ready_i)) &&
              l2_done_d && l3_done_d)
            state_d = l1_done_d ? S_DONE : S_WAIT_L1;
        end else begin
          // clean / flush: ordered once no write remains in flight below
          if (l2_write_idle_i && l3_write_idle_i) state_d = S_DONE;
        end
      end

      S_WAIT_L1: begin
        // L2/L3 tag clears already landed; the broadcast's drain is the last
        // completion — done only after EVERY core acknowledged its L1 inval.
        // l1_done_d includes a drain_done_i pulse that fired this cycle.
        if (l1_done_d) state_d = S_DONE;
      end

      S_DONE: begin
        cmo_done_o[sel_q] = 1'b1;
        state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= S_IDLE;
      sel_q     <= '0;
      rr_ptr_q  <= '0;
      op_q      <= '0;
      addr_q    <= '0;
      l1_sent_q <= 1'b0;
      l1_done_q <= 1'b0;
      l2_done_q <= 1'b0;
      l3_done_q <= 1'b0;
    end else begin
      state_q   <= state_d;
      sel_q     <= sel_d;
      rr_ptr_q  <= rr_ptr_d;
      op_q      <= op_d;
      addr_q    <= addr_d;
      l1_sent_q <= l1_sent_d;
      l1_done_q <= l1_done_d | l1_bcast_done_i;
      l2_done_q <= l2_done_d;
      l3_done_q <= l3_done_d;
    end
  end

endmodule
