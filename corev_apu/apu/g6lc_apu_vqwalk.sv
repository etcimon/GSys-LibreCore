// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Generic virtqueue walker (§6c Settled bullet 4 of
// architecture/uncore/apu-vulkan-engine.md).  Watches two split-ring
// (virtio 1.x, little-endian) queues described by apu_vq_state_t
// {desc, avail, used, num, ready} snapshots, reacts to a pending-level
// notify_i per queue, and walks the avail ring one chain element at a
// time.
//
// Layout:  desc  entry i (16 B) @ desc+16i   {addr u64@0, len u32@8,
//                                              flags u16@12, next u16@14}
//          avail {flags u16@0, idx u16@2, ring[num] u16 @4+2i}
//          used  {flags u16@0, idx u16@2, ring[num] {id u32,len u32}
//                                              @4+8i}
// flags: NEXT=1, WRITE=2, INDIRECT=4.
//
// Per element: read avail ring head index, follow the descriptor chain
// (bounded NEXT, <= APU_VG_MAX_DESC entries, loop/out-of-range/INDIRECT
// detection via a visited list), then
//   queue 0: hand {head, n, desc[4]} to vgtop over chain_*, wait for
//            cpl_valid_i, publish {head, cpl_len_i};
//   queue 1: cursor queue — publish {head, 0} with no hand-off;
//   chain fault: publish {head, 0} and keep walking.
// Publication order is strict: the {id} then {len} 32-bit strobed
// writes at used+4+8*(used_idx % num), then a 16-bit strobed write of
// the running used index at used+2 (never a 32-bit write over flags),
// and only after that beat's response does used_valid_o rise, held
// until used_ready_i.
//
// An mp error on any walker access (avail/desc/used table address
// outside the guest window) raises sticky bus_fault_o, halts that
// queue, and publishes nothing for the aborted element; the fault
// clears only with reset_req_i.  Descriptor-walk faults are not bus
// faults — the element is published len 0 and the queue continues.
//
// Batching: after the avail backlog drains, avail.idx is re-read once;
// a notify still pending is cleared and a moved idx keeps the queue
// running.  queue_enable_i[q] low or reset_req_i clears the queue's
// counters (last_avail, ring position, used position/index, halt).
// A queue drop mid-flight parks the walker in StAbort until an
// already-accepted mp request's response has arrived (mp_pend_q), so
// no stale response can be consumed by a later request.  reset_req_i
// clears mp_pend_q outright: apmem's flush_i drops accepted-but-
// unissued requests without a response, and a response for an
// already-issued transaction is harmlessly ignored while idle.
// All % num arithmetic is compare-and-subtract wrap, never a divider.
// Round-robin between queues, one chain at a time; all walker traffic
// is dom=0 (guest absolute).
//
// Timing impact: one 64-bit mp request per state hop; the widest cone
// is the request-address mux.  No new clock, no latch.
// Review checklist: always_ff/always_comb split, async active-low
// reset, Enable=0 constant-zero netlist, no initial outside
// translate_off.
module g6lc_apu_vqwalk
  import g6lc_apu_vg_pkg::*;
  import g6lc_apu_mp_pkg::*;
#(
  parameter bit Enable = 0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    testmode_i,
  input  logic                    reset_req_i,
  input  g6lc_apu_pkg::apu_vq_state_t vq0_i,
  input  g6lc_apu_pkg::apu_vq_state_t vq1_i,
  input  logic [1:0]              queue_enable_i,
  input  logic [1:0]              notify_i,
  output logic [1:0]              notify_clear_o,
  // shared memory port (dom=0, guest absolute)
  output logic                    mp_req_valid_o,
  input  logic                    mp_req_ready_i,
  output apu_mp_req_t             mp_req_o,
  input  logic                    mp_rsp_valid_i,
  input  apu_mp_rsp_t             mp_rsp_i,
  // chain hand-off to vgtop (queue 0 only)
  output logic                    chain_valid_o,
  input  logic                    chain_ready_i,
  output logic [15:0]             chain_id_o,
  output logic [3:0]              chain_n_o,
  output apu_vg_desc_t [APU_VG_MAX_DESC-1:0] chain_desc_o,
  // completion back from vgtop
  input  logic                    cpl_valid_i,
  output logic                    cpl_ready_o,
  input  logic [31:0]             cpl_len_i,
  // publication event
  output logic                    used_valid_o,
  output logic [31:0]             used_qid_o,
  output logic [31:0]             used_len_o,
  input  logic                    used_ready_i,
  output logic                    bus_fault_o,
  output logic                    idle_o,
  output logic [1:0][15:0]        last_avail_o
);
  if (!Enable) begin : gen_off
    assign notify_clear_o = '0;
    assign mp_req_valid_o = 1'b0;
    assign mp_req_o       = '0;
    assign chain_valid_o  = 1'b0;
    assign chain_id_o     = '0;
    assign chain_n_o      = '0;
    assign chain_desc_o   = '{default: '0};
    assign cpl_ready_o    = 1'b0;
    assign used_valid_o   = 1'b0;
    assign used_qid_o     = '0;
    assign used_len_o     = '0;
    assign bus_fault_o    = 1'b0;
    assign idle_o         = 1'b1;
    assign last_avail_o   = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | reset_req_i |
                    (|vq0_i) | (|vq1_i) | (|queue_enable_i) |
                    (|notify_i) | mp_req_ready_i | mp_rsp_valid_i |
                    (|mp_rsp_i) | chain_ready_i | cpl_valid_i |
                    (|cpl_len_i) | used_ready_i;
  end else begin : gen_on
    localparam logic [15:0] FLG_NEXT     = 16'h0001;
    localparam logic [15:0] FLG_INDIRECT = 16'h0004;

    typedef enum logic [4:0] {
      StIdle,                       // pick a queue, take notify
      StIdxRd, StIdxW,              // read avail.idx
      StHead, StHeadW,              // read avail.ring[ring_pos]
      StD0, StD0W,                  // desc beat 0: addr u64
      StD1, StD1W,                  // desc beat 1: len/flags/next
      StChain, StCpl,               // q0 hand-off + completion
      StPubE, StPubEW,              // used element id word
      StPubL, StPubLW,              // used element len word
      StPubI, StPubIW,              // used index u16
      StPubV,                       // used_valid_o handshake
      StDrain, StDrainW,            // re-read avail.idx once
      StAbort                       // queue dropped: drain pending rsp
    } state_e;
    state_e state_q;

    // per-queue state
    logic [1:0][15:0] last_avail_q;  // monotonic avail position
    logic [1:0][15:0] ring_pos_q;    // last_avail % num (wrap-sub)
    logic [1:0][15:0] used_idx_q;    // monotonic used index
    logic [1:0][15:0] used_pos_q;    // used_idx % num
    logic [1:0]       halt_q;
    logic             turn_q;        // round-robin cursor

    // in-flight queue snapshot + chain
    logic        cur_q;
    logic [63:0] desc_q, avail_q, used_q;
    logic [15:0] num_q, idx_snap_q;
    logic [15:0] head_q, cur_idx_q;
    logic [3:0]  ndesc_q;
    logic [15:0] visited_q [APU_VG_MAX_DESC];
    logic [63:0] d_addr_q;
    apu_vg_desc_t chain_q [APU_VG_MAX_DESC];
    logic [31:0] pub_len_q;
    logic [2:0]  rd_off_q;
    logic        bus_fault_q;
    logic [1:0]  clr_q;
    logic        mp_pend_q;          // an accepted request owes a rsp

    assign bus_fault_o    = bus_fault_q;
    assign idle_o         = state_q == StIdle;
    assign last_avail_o   = last_avail_q;
    assign notify_clear_o = clr_q;

    // u16 field extracted from the last read beat
    logic [15:0] rd_u16;
    assign rd_u16 = 16'(mp_rsp_i.rdata >> (32'(rd_off_q) * 8));

    // ------------------------------------------------ request issue
    // mp_req_o is driven combinationally in each issue state and held
    // until mp_req_ready_i; rd_off_q latches the byte offset of the
    // u16 field inside the beat for the matching wait state.
    logic [63:0] avail_ent_a, used_elem_a;
    logic [15:0] nxt_used_idx;
    assign avail_ent_a  = avail_q + 64'd4 +
                          {48'h0, ring_pos_q[cur_q], 1'b0};
    assign used_elem_a  = used_q + 64'd4 +
                          {45'h0, used_pos_q[cur_q], 3'b000};
    assign nxt_used_idx = used_idx_q[cur_q] + 16'd1;

    always_comb begin
      mp_req_valid_o = 1'b0;
      mp_req_o       = '0;
      mp_req_o.dom   = 1'b0;
      unique case (state_q)
        StIdxRd, StDrain: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.addr  = avail_q & ~64'h7;
        end
        StHead: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.addr  = avail_ent_a & ~64'h7;
        end
        StD0: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.addr  = desc_q + {48'h0, cur_idx_q, 4'b0000};
        end
        StD1: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.addr  = desc_q + {48'h0, cur_idx_q, 4'b0000} + 64'd8;
        end
        StPubE: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.we    = 1'b1;
          mp_req_o.addr  = used_elem_a;
          mp_req_o.wstrb = used_elem_a[2] ? 8'hF0 : 8'h0F;
          mp_req_o.wdata = used_elem_a[2] ? {32'(head_q), 32'h0}
                                          : {32'h0, 32'(head_q)};
        end
        StPubL: begin
          mp_req_valid_o = 1'b1;
          mp_req_o.we    = 1'b1;
          mp_req_o.addr  = used_elem_a + 64'd4;
          mp_req_o.wstrb = used_elem_a[2] ? 8'h0F : 8'hF0;
          mp_req_o.wdata = used_elem_a[2] ? {32'h0, pub_len_q}
                                          : {pub_len_q, 32'h0};
        end
        StPubI: begin
          // 16-bit strobed write at used+2; used is 4-aligned so the
          // field lands at byte 2 or 6 of the used-aligned beat.
          mp_req_valid_o = 1'b1;
          mp_req_o.we    = 1'b1;
          mp_req_o.addr  = used_q & ~64'h7;
          mp_req_o.wstrb = used_q[2] ? 8'hC0 : 8'h0C;
          mp_req_o.wdata = used_q[2] ? {nxt_used_idx, 48'h0}
                                     : 64'(nxt_used_idx) << 16;
        end
        default: ;
      endcase
    end

    // ------------------------------------------------ outputs
    assign chain_valid_o = state_q == StChain;
    assign chain_id_o    = head_q;
    assign chain_n_o     = ndesc_q;
    always_comb begin
      chain_desc_o = '{default: '0};
      for (int unsigned i = 0; i < APU_VG_MAX_DESC; i++)
        chain_desc_o[i] = chain_q[i];
    end
    // StAbort drains the completion handshake too: a queue dropped in
    // StCpl still consumes the held cpl_valid so vgtop never holds a
    // stale completion into the queue's next lifetime
    assign cpl_ready_o  = state_q == StCpl ||
                          (state_q == StAbort && cpl_valid_i);
    assign used_valid_o = state_q == StPubV;
    assign used_qid_o   = {31'h0, cur_q};
    assign used_len_o   = pub_len_q;

    // ------------------------------------------------ FSM
    logic pick;
    logic q_pend0, q_pend1;
    assign q_pend0 = queue_enable_i[0] && !halt_q[0] && vq0_i.ready &&
                     notify_i[0];
    assign q_pend1 = queue_enable_i[1] && !halt_q[1] && vq1_i.ready &&
                     notify_i[1];
    assign pick = (q_pend0 && q_pend1) ? turn_q
                : q_pend0 ? 1'b0 : 1'b1;

    logic [15:0] d_flags, d_next;
    assign d_flags = 16'(mp_rsp_i.rdata[47:32]);
    assign d_next  = 16'(mp_rsp_i.rdata[63:48]);

    // NEXT-loop detection: d_next must not revisit the current index
    // or any index already walked this chain.
    logic next_loop;
    always_comb begin
      next_loop = (d_next == cur_idx_q);
      for (int unsigned i = 0; i < APU_VG_MAX_DESC; i++)
        if (i < ndesc_q && visited_q[i] == d_next)
          next_loop = 1'b1;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q      <= StIdle;
        cur_q        <= 1'b0;
        desc_q       <= '0;
        avail_q      <= '0;
        used_q       <= '0;
        num_q        <= '0;
        idx_snap_q   <= '0;
        head_q       <= '0;
        cur_idx_q    <= '0;
        ndesc_q      <= '0;
        d_addr_q     <= '0;
        chain_q      <= '{default: '0};
        visited_q    <= '{default: '0};
        pub_len_q    <= '0;
        rd_off_q     <= '0;
        bus_fault_q  <= 1'b0;
        clr_q        <= '0;
        mp_pend_q    <= 1'b0;
        turn_q       <= 1'b0;
        last_avail_q <= '0;
        ring_pos_q   <= '0;
        used_idx_q   <= '0;
        used_pos_q   <= '0;
        halt_q       <= '0;
      end else begin
        clr_q <= '0;
        if (reset_req_i) begin
          // engine reset: clear everything including the sticky fault;
          // apmem's flush drops accepted-but-unissued requests without
          // a response, so the outstanding-request tracker clears too
          state_q      <= StIdle;
          bus_fault_q  <= 1'b0;
          halt_q       <= '0;
          mp_pend_q    <= 1'b0;
          last_avail_q <= '0;
          ring_pos_q   <= '0;
          used_idx_q   <= '0;
          used_pos_q   <= '0;
        end else begin
          // one response per accepted request: set on the accept edge,
          // cleared when the response pulse arrives
          mp_pend_q <= (mp_req_valid_o && mp_req_ready_i) ||
                       (mp_pend_q && !mp_rsp_valid_i);
          // enable falling clears the queue's counters and state
          for (int q = 0; q < 2; q++) begin
            if (!queue_enable_i[q]) begin
              last_avail_q[q] <= '0;
              ring_pos_q[q]   <= '0;
              used_idx_q[q]   <= '0;
              used_pos_q[q]   <= '0;
              halt_q[q]       <= 1'b0;
            end
          end

          unique case (state_q)
            // ---------------------------------------------- acquire
            StIdle: begin
              if ((q_pend0 || q_pend1) && !mp_pend_q) begin
                cur_q   <= pick;
                if (!pick) begin
                  desc_q  <= vq0_i.desc;
                  avail_q <= vq0_i.avail;
                  used_q  <= vq0_i.used;
                  num_q   <= vq0_i.num;
                end else begin
                  desc_q  <= vq1_i.desc;
                  avail_q <= vq1_i.avail;
                  used_q  <= vq1_i.used;
                  num_q   <= vq1_i.num;
                end
                clr_q[pick] <= 1'b1;
                if (q_pend0 && q_pend1) turn_q <= ~turn_q;
                state_q <= StIdxRd;
              end
            end
            StIdxRd:
              if (mp_req_ready_i) begin
                rd_off_q <= 3'((avail_q + 64'd2) & 64'h7);
                state_q  <= StIdxW;
              end
            StIdxW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else begin
                  idx_snap_q <= rd_u16;
                  if (rd_u16 != last_avail_q[cur_q])
                    state_q <= StHead;
                  else
                    state_q <= StIdle;
                end
              end
            // -------------------------------------- avail ring entry
            StHead:
              if (mp_req_ready_i) begin
                rd_off_q <= avail_ent_a[2:0];
                state_q  <= StHeadW;
              end
            StHeadW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else begin
                  head_q    <= rd_u16;
                  cur_idx_q <= rd_u16;
                  ndesc_q   <= '0;
                  if (rd_u16 >= num_q) begin
                    // descriptor index beyond the queue: chain fault
                    pub_len_q <= '0;
                    state_q   <= StPubE;
                  end else begin
                    state_q <= StD0;
                  end
                end
              end
            // ------------------------------------------ descriptor
            StD0:
              if (mp_req_ready_i) state_q <= StD0W;
            StD0W:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else begin
                  d_addr_q <= mp_rsp_i.rdata;
                  state_q  <= StD1;
                end
              end
            StD1:
              if (mp_req_ready_i) state_q <= StD1W;
            StD1W:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else begin
                  visited_q[ndesc_q[1:0]]   <= cur_idx_q;
                  chain_q[ndesc_q[1:0]].addr  <= d_addr_q;
                  chain_q[ndesc_q[1:0]].len   <=
                    mp_rsp_i.rdata[31:0];
                  chain_q[ndesc_q[1:0]].write <= d_flags[1];
                  chain_q[ndesc_q[1:0]].pad   <= '0;
                  ndesc_q <= ndesc_q + 4'd1;
                  if ((d_flags & FLG_INDIRECT) != 0) begin
                    pub_len_q <= '0;
                    state_q   <= StPubE;
                  end else if ((d_flags & FLG_NEXT) != 0) begin
                    if (ndesc_q == APU_VG_MAX_DESC[3:0] - 4'd1 ||
                        d_next >= num_q || next_loop) begin
                      pub_len_q <= '0;
                      state_q   <= StPubE;
                    end else begin
                      cur_idx_q <= d_next;
                      state_q   <= StD0;
                    end
                  end else if (cur_q) begin
                    // cursor queue: no hand-off, publish len 0
                    pub_len_q <= '0;
                    state_q   <= StPubE;
                  end else begin
                    state_q <= StChain;
                  end
                end
              end
            // --------------------------------- q0 hand-off + complete
            StChain:
              if (chain_ready_i) state_q <= StCpl;
            StCpl:
              if (cpl_valid_i) begin
                pub_len_q <= cpl_len_i;
                state_q   <= StPubE;
              end
            // ------------------------------------------ publication
            StPubE:
              if (mp_req_ready_i) state_q <= StPubEW;
            StPubEW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else state_q <= StPubL;
              end
            StPubL:
              if (mp_req_ready_i) state_q <= StPubLW;
            StPubLW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else state_q <= StPubI;
              end
            StPubI:
              if (mp_req_ready_i) state_q <= StPubIW;
            StPubIW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else state_q <= StPubV;
              end
            StPubV:
              if (used_ready_i) begin
                last_avail_q[cur_q] <= last_avail_q[cur_q] + 16'd1;
                ring_pos_q[cur_q]   <=
                  ring_pos_q[cur_q] + 16'd1 == num_q ? 16'd0
                  : ring_pos_q[cur_q] + 16'd1;
                used_idx_q[cur_q]   <= used_idx_q[cur_q] + 16'd1;
                used_pos_q[cur_q]   <=
                  used_pos_q[cur_q] + 16'd1 == num_q ? 16'd0
                  : used_pos_q[cur_q] + 16'd1;
                if (last_avail_q[cur_q] + 16'd1 != idx_snap_q)
                  state_q <= StHead;
                else
                  state_q <= StDrain;
              end
            // ----------------------------------------------- drain
            StDrain:
              if (mp_req_ready_i) begin
                rd_off_q <= 3'((avail_q + 64'd2) & 64'h7);
                state_q  <= StDrainW;
              end
            StDrainW:
              if (mp_rsp_valid_i) begin
                if (mp_rsp_i.err) begin
                  bus_fault_q   <= 1'b1;
                  halt_q[cur_q] <= 1'b1;
                  state_q       <= StIdle;
                end else begin
                  if (notify_i[cur_q]) clr_q[cur_q] <= 1'b1;
                  idx_snap_q <= rd_u16;
                  if (rd_u16 != last_avail_q[cur_q])
                    state_q <= StHead;
                  else
                    state_q <= StIdle;
                end
              end
            // ------------------------------------ abandon on drop
            StAbort:
              // the queue fell mid-walk: consume-and-ignore the
              // pending response (if any) before going idle, so a
              // later request can never read a stale one
              if (!mp_pend_q) state_q <= StIdle;
            default: state_q <= StIdle;
          endcase

          // a mid-flight queue drop abandons the walk; StAbort waits
          // for the outstanding response first
          if (!queue_enable_i[cur_q] && state_q != StIdle &&
              state_q != StAbort)
            state_q <= StAbort;
        end
      end
    end

    logic unused;
    assign unused = testmode_i | (|d_flags[15:2]);

    `ifndef SYNTHESIS
    initial assert (APU_VG_MAX_DESC == 4)
      else $fatal(1, "APU VQWALK: visited/chain depth assumes 4");
    `endif
  end
endmodule
