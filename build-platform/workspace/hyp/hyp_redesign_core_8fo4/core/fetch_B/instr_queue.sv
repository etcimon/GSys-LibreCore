// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (epoch-tagged elastic queue)
// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Modified by: Etienne Cimon
// Date: 26.10.2018
//
// Description: Instruction Queue, separates instruction front-end from processor
//              back-end.
//
// INSTR_PER_FETCH parallel 32-bit FIFOs are filled round-robin: idx_is_q is the
// binary fill pointer, idx_ds_q the one-hot drain pointer, so a fetch packet of
// arbitrary length lands without a shifter on the queue itself. Instructions past
// the first predicted-taken control flow of a packet are dropped; a packet that
// does not fit is not partially accepted but replayed (replay_o/replay_addr_o).
//
// A/B draft note: the rotations are expressed once as rotate_left/rotate_right
// instead of open-coded double-width shifts, the RVC and non-RVC input/output
// paths are one path parameterised by INSTR_PER_FETCH, and the (dead) PC
// reconstruction chain is gone - fetch_entry_o.address comes from the realigner
// PC stored with each word.
//
// hyp8 (epoch + elastic drain):
//  * Every entry carries the fetch epoch its window was accepted under
//    (push_epoch_i). A window whose epoch has died presents nothing: no push,
//    no replay, no consumed_o — the redirect that killed it already restarted
//    the stream. Entries left behind inside the FIFOs are wrong-path: they
//    are never delivered — a stale head occupies its drain position and is
//    popped inside the consumed prefix (drop, not issue), preserving program
//    order for the live entries behind it.
//  * Drain is a two-step elastic handshake: per-lane eligibility is the
//    FIFO's registered occupancy plus the head entry's epoch check
//    ("registered eligibility"), then the prefix-fire step computes fires and
//    stale drops together as one consumed prefix. fetch_entry_ready_i timing
//    is unchanged: issue samples fetch_entry_o in the same cycle as valid.

module instr_queue
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type fetch_entry_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // Fetch hart — stamped into the packet (L3); not the decode-time active hart
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_i,
    // hyp8: current fetch epoch + the epoch this packet was accepted under
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    input logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] push_epoch_i,
    // Instruction - instr_realign
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0] instr_i,
    // Instruction address - instr_realign
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] addr_i,
    // Instruction is valid - instr_realign
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0] valid_i,
    // Leftover-complete in slot0 (serving_unaligned) — I7 slot0 push
    input logic leftover_complete_i,
    // Handshake's ready with CACHE - CACHE
    output logic ready_o,
    // Indicates instructions consumed, or popped by ID_STAGE - FRONTEND
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] consumed_o,
    // Exception (which is page-table fault) - CACHE
    input g6lc_core_pkg::frontend_exception_t exception_i,
    // Exception address - CACHE
    input logic [G6LCCfg.VLEN-1:0] exception_addr_i,
    input logic [G6LCCfg.GPLEN-1:0] exception_gpaddr_i,
    input logic [31:0] exception_tinst_i,
    input logic exception_gva_i,
    // Branch predict - FRONTEND
    input logic [G6LCCfg.VLEN-1:0] predict_address_i,
    // Instruction predict address - FRONTEND
    input g6lc_core_pkg::cf_t [G6LCCfg.INSTR_PER_FETCH-1:0] cf_type_i,
    // T21: BP checkpoint identity of each CF slot (allocated this cycle) and
    // the call flag; delivered in fetch_entry_o.branch_predict so the resolve
    // path can address its own checkpoint and re-apply its RAS effect
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0] ckpt_v_i,
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0][7:0] ckpt_idx_i,
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0] is_call_i,
    input logic [G6LCCfg.INSTR_PER_FETCH-1:0] is_return_i,
    // Replay instruction because one of the FIFO was full - FRONTEND
    output logic replay_o,
    // Address at which to replay the fetch - FRONTEND
    output logic [G6LCCfg.VLEN-1:0] replay_addr_o,
    // Handshake's data with ID_STAGE - ID_STAGE
    output fetch_entry_t [G6LCCfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid with ID_STAGE - ID_STAGE
    output logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready with ID_STAGE - ID_STAGE
    input logic [G6LCCfg.NrIssuePorts-1:0] fetch_entry_ready_i,
    // T6b-3b: oldest undelivered instruction per hart (the mixed-residency
    // restart frontier). The port view only reaches NrIssuePorts positions —
    // a peer hart's entries queued deeper than them are invisible to it.
    // '0 in single-hart and drained-handoff configurations.
    output logic [G6LCCfg.NrHarts-1:0] queue_oldest_valid_o,
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:0] queue_oldest_pc_o
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  localparam g6lc_fetch_pkg::fetch_en_t  En  = g6lc_fetch_pkg::en(G6LCCfg);
  localparam int unsigned NrFifo = Geo.slots;
  localparam int unsigned NrIssue = Geo.issue;
  localparam int unsigned IdxW = Geo.log2_slots;
  localparam int unsigned HidW = Geo.hart_idx_w;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;
  // Per-slot instruction FIFO depth — the pending-frontier FIFOs below derive
  // their capacity from it (slots × depth = the queue's total occupancy).
  localparam int unsigned IFifoDepth = 8;

  typedef logic [IdxW-1:0] fifo_idx_t;
  // NrFifo is a power of two, so a truncating mask is a modulo
  localparam fifo_idx_t IdxMask = fifo_idx_t'(NrFifo - 1);

  typedef struct packed {
    logic [31:0]                     instr;      // instruction word
    logic [G6LCCfg.VLEN-1:0]         pc;         // instr PC from realign (not reconstructed)
    g6lc_core_pkg::cf_t              cf;         // branch was taken
    logic                            ckpt_v;     // T21: BP checkpoint allocated for this CF
    logic [7:0]                      ckpt_idx;   // T21: its index
    logic                            is_call;    // T21: decoded call (RAS push at fetch)
    logic                            is_ret;     // T23: decoded return (RAS pop at fetch when predicted)
    logic                            is_ctrl;    // opcode is control-flow, including a not-taken branch
    logic                            is_taken;   // cf != NoCF, stored at push
    g6lc_core_pkg::frontend_exception_t ex;      // exception happened
    logic [G6LCCfg.VLEN-1:0]         ex_vaddr;   // lower VLEN bits of tval for exception
    logic [G6LCCfg.GPLEN-1:0]        ex_gpaddr;  // lower GPLEN bits of tval2 for exception
    logic [31:0]                     ex_tinst;   // tinst of exception
    logic                            ex_gva;
    logic [HidW-1:0]                 hart;       // fetch hart (L3 packet_hart)
    logic [EW-1:0]                   epoch;      // hyp8: fetch epoch at push
    // O7o debug: monotonic per-instruction sequence, kept for the order probe.
    // This field is not used for any architectural handshake; it is trace/gate only.
    logic [15:0]                     push_seq;
  } instr_data_t;

  // instruction queues
  instr_data_t [NrFifo-1:0] instr_data_in, instr_data_out;
  logic [NrFifo-1:0] instr_queue_full, instr_queue_empty;
  logic [NrFifo-1:0] push_instr, push_instr_fifo, pop_instr;
  // input stream
  logic [NrFifo-1:0] taken, branch_mask, valid, fifo_pos;
  fifo_idx_t [NrFifo-1:0] slot_fifo;
  logic instr_overflow;
  logic [NrFifo-1:0] slot0_pos;
  logic slot0_full, lo_partial, rest_found;
  logic [G6LCCfg.VLEN-1:0] rest_addr;
  fifo_idx_t idx_is_d, idx_is_q;
  // O7p: shamt counts pushed FIFOs; it can be up to NrFifo, so it needs one
  // more bit than the binary FIFO index to avoid wrapping to 0 on a 4-wide push.
  // Sized to that bound ($clog2(NrFifo+1)): the sequence/index increments it
  // steps are precomputed per candidate step value (sv-timing SelectIncrement),
  // so one spare bit would double the candidate array for nothing.
  localparam int unsigned ShamtW = $clog2(NrFifo + 1);
  logic [ShamtW-1:0] shamt;
  // O7o: global per-instruction push sequence. push_seq_q is the next number to
  // hand out; push_seq_d is the next value after this cycle's push. Reset on
  // queue flush so the small counter does not wrap in a long run.
  logic [15:0] push_seq_q, push_seq_d;
  // output stream: one-hot select rotated by issue port
  logic [NrFifo-1:0] idx_ds_d, idx_ds_q;
  logic [NrIssue:0][NrFifo-1:0] idx_ds;
  logic [NrFifo-1:0][$clog2(8)-1:0] instr_queue_usage;
  // address (branch target) queue
  logic [G6LCCfg.VLEN-1:0] address_out;
  logic push_address, pop_address, full_address, address_overflow;
  // downstream handshake
  logic [NrIssue-1:0] fetch_entry_is_cf, fetch_entry_blocks_ss, fetch_entry_fire, fire_prefix;
  // hyp8: drain eligibility — per-lane occupancy is the registered FIFO
  // counter; the head entry's epoch liveness and the stale prefix complete it
  logic [NrFifo-1:0] lane_epoch_ok, lane_live, lane_stale;
  logic [NrIssue-1:0] pos_stale, pos_present;  // per drain position
  logic [NrIssue-1:0] consumed_pos;            // fired or stale-dropped prefix
  logic [NrIssue-1:0] pos_go;                  // stale drop or port fire
  logic [NrIssue-1:0] fill_prefix;             // positions <p all present/stale
  // Per FIFO head: control-flow class and predicted-taken, so the drain
  // pointer only one-hot-reduces a bit. The class must not wait on a 32-bit
  // select of the issued word. fetch_entry_o still carries the word itself.
  logic [NrFifo-1:0] slot_ctrl;
  logic [NrFifo-1:0] lane_ctrl, lane_cf;
  logic [NrIssue-1:0] port_ctrl, port_cf;
  logic [NrIssue-1:0] block_any;

  // rotate a per-slot mask between input-stream order and FIFO order
  function automatic logic [NrFifo-1:0] rotate_left(logic [NrFifo-1:0] v, fifo_idx_t amt);
    logic [2*NrFifo-1:0] ext;
    ext = {v, v} << amt;
    return ext[2*NrFifo-1:NrFifo];
  endfunction

  function automatic logic [NrFifo-1:0] rotate_right(logic [NrFifo-1:0] v, fifo_idx_t amt);
    logic [2*NrFifo-1:0] ext;
    ext = {v, v} >> amt;
    return ext[NrFifo-1:0];
  endfunction

  // control-flow class straight from the 32-bit word, no full decode: a CF
  // instruction must be the youngest of an issue group
  function automatic logic is_ctrl_instr(logic [31:0] w);
    unique case (w[1:0])
      2'b11:
      return (w[6:0] == 7'b1100011) ||  // BRANCH
      (w[6:0] == 7'b1101111) ||  // JAL
      (w[6:0] == 7'b1100111);  // JALR
      2'b01:
      return (w[15:13] == 3'b101) ||  // c.j / c.jal
      (w[15:13] == 3'b110) ||  // c.beqz
      (w[15:13] == 3'b111);  // c.bnez
      2'b10: return (w[15:13] == 3'b100) && (w[6:2] == 5'b00000);  // c.jr / c.jalr
      default: return 1'b0;
    endcase
  endfunction

  // ----------------------
  // Input interface
  // ----------------------
  // I7 is all-or-nothing, so readiness is the AND over every FIFO plus the shared
  // target queue: one full slot must stall the whole packet, not part of it.
  assign ready_o = ~(|instr_queue_full) & ~full_address;

  // hyp8: a dead-epoch packet is dropped whole — nothing is pushed, nothing is
  // replayed, nothing is consumed; the epoch bump already restarted the stream.
  logic win_live;
  assign win_live = (push_epoch_i == epoch_i);

  for (genvar i = 0; i < NrFifo; i++) begin : gen_taken
    assign taken[i] = cf_type_i[i] != g6lc_core_pkg::NoCF;
  end

  // L3: through first predicted CF (packet_upto_cf). n-wide = NrFifo.
  always_comb begin : gen_branch_mask
    logic [7:0] taken8, mask8;
    taken8 = '0;
    taken8[NrFifo-1:0] = taken;
    mask8 = g6lc_fetch_pkg::packet_upto_cf(taken8, NrFifo);
    branch_mask = mask8[NrFifo-1:0];
  end

  // Slots past the first predicted-taken CF are dropped here, not in L1: the
  // realigner still emitted them, and L2/L3 may drop but never modify (SPEC §0).
  assign valid = valid_i & branch_mask & {NrFifo{win_live}};
  // input slot i is served by FIFO (i + idx_is_q)
  always_comb begin : gen_compact_slots
    fifo_idx_t rank;
    rank = '0;
    fifo_pos = '0;
    slot_fifo = '0;
    for (int unsigned s = 0; s < NrFifo; s++) begin
      slot_fifo[s] = (idx_is_q + rank) & IdxMask;
      if (valid[s]) begin
        fifo_pos[slot_fifo[s]] = 1'b1;
        rank = rank + 1'b1;
      end
    end
  end
  assign instr_overflow = |(instr_queue_full & fifo_pos);
  // I7: if any needed slot cannot enqueue, push none (then replay).
  // Leftover-complete slot0 is the previous window's carry: if it fits
  // and later slots overflow, push slot0 and replay the rest
  // (s4-v-lorepl-kill t=2452203). Not pipe_keep (osbi 129b8).
  assign slot0_pos = rotate_left({{(NrFifo - 1) {1'b0}}, valid[0]}, idx_is_q);
  assign slot0_full = |(instr_queue_full & slot0_pos);
  assign lo_partial = g6lc_fetch_pkg::leftover_slot0_push(
      leftover_complete_i, valid[0], slot0_full, instr_overflow);
  assign push_instr = lo_partial ? slot0_pos
      : (fifo_pos & {NrFifo{g6lc_fetch_pkg::packet_accept(instr_overflow)}});
  assign push_instr_fifo = push_instr
      & {NrFifo{g6lc_fetch_pkg::packet_accept(address_overflow)}};
  // Rotated BACK into realigner slot order: the frontend's cf_consumed / ras_push
  // index by input slot, so returning FIFO order here would credit the wrong slot.
  for (genvar s = 0; s < NrFifo; s++) begin : gen_consumed_slots
    assign consumed_o[s] = valid[s] && push_instr_fifo[slot_fifo[s]];
  end

  // First unpushed slot after a leftover-complete slot0 push. Replay must resume
  // there, not at the completing window, or the carry would be dropped again.
  always_comb begin : gen_rest_addr
    rest_addr = exception_addr_i;
    rest_found = 1'b0;
    for (int unsigned i = 1; i < NrFifo; i++) begin
      if (valid[i] && !rest_found) begin
        rest_addr = addr_i[i];
        rest_found = 1'b1;
      end
    end
  end

  // The push count is decided before admission, not read off its result:
  // fifo_pos sets one distinct bit per valid slot (ranks are distinct modulo
  // NrFifo), slot0_pos is one-hot exactly when valid[0] holds, and lo_partial
  // implies valid[0] (leftover_slot0_push). So popcount(push_instr_fifo) ==
  // address_overflow ? 0 : lo_partial ? 1 : instr_overflow ? 0 : popcount(valid),
  // and popcount(valid) starts at the head of the cone instead of its tail
  // (18 → 10 structural FO4 into push_seq_d / idx_is_d). Exhaustively proved
  // equal with Yosys SAT for NrFifo = 2, 4, 8:
  // sv-timing/fixtures/auto_correct/instr_queue_shamt_equiv.sv.
  // Count of post-mask valids, before admission. The trace sequence
  // advances by this count. Rejected packets leave a gap; push_seq is
  // not an architectural handshake. The fill pointer still uses shamt,
  // which is zero when the packet is not pushed.
  logic [ShamtW-1:0] valid_count;
  always_comb begin : gen_valid_count
    valid_count = '0;
    for (int unsigned i = 0; i < NrFifo; i++) valid_count = valid_count + ShamtW'(valid[i]);
  end
  logic [1:0] sh_sel;
  always_comb begin
    if (address_overflow) sh_sel = 2'd0;
    else if (lo_partial)  sh_sel = 2'd1;
    else if (instr_overflow) sh_sel = 2'd2;
    else sh_sel = 2'd3;
  end
  always_comb begin : gen_shamt
    unique case (sh_sel)
      2'd1:    shamt = ShamtW'(1);
      2'd3:    shamt = valid_count;
      default: shamt = '0;
    endcase
  end

  assign idx_is_d = (idx_is_q + fifo_idx_t'(shamt)) & IdxMask;
  assign push_seq_d = push_seq_q + 16'(valid_count);

  // hyp8 r3: the fifo-source pick was a serial last-writer loop feeding
  // dynamic-index reads, and rank a serial popcount. Same picks written
  // as a last-match one-hot + masked-OR gathers; when no slot maps to a
  // fifo the original read slot 0 (s defaulted to '0) — keep that mux.
  logic [NrFifo-1:0] fsel_oh[NrFifo];   // fsel_oh[f][i]: slot i feeds fifo f
  logic [NrFifo-1:0] fsel_hit[NrFifo];  // any source (before last-match)
  logic [NrFifo-1:0] fsel_none;
  // Ranks are distinct, so at most one valid slot maps to a FIFO. The
  // higher-bit last-match OR was 4.4 FO4 on the fill-pointer chain and
  // selected the same slot as the hit.
  for (genvar f = 0; f < NrFifo; f++) begin : gen_fsel
    for (genvar i = 0; i < NrFifo; i++) begin : gen_fsel_i
      assign fsel_hit[f][i] = valid[i] && (slot_fifo[i] == fifo_idx_t'(f));
      assign fsel_oh[f][i]  = fsel_hit[f][i];
    end
    // The empty-hit OR is outside the payload if. Inside the if it was a
    // 5.5 FO4 guard on the default cf write, which the fill pointer reads.
    assign fsel_none[f] = ~|fsel_hit[f];
  end

  // Control-flow opcode class, including a not-taken branch. Computed on
  // the push word so the drain only reduces a stored bit.
  for (genvar i = 0; i < NrFifo; i++) begin : gen_slot_ctrl
    logic rvi, c1, c2, op_br, op_jal, op_jalr, c1j, c1beq, c1bne, c2jr;
    assign rvi    = instr_i[i][1:0] == 2'b11;
    assign c1     = instr_i[i][1:0] == 2'b01;
    assign c2     = instr_i[i][1:0] == 2'b10;
    assign op_br  = instr_i[i][6:0] == 7'b1100011;
    assign op_jal = instr_i[i][6:0] == 7'b1101111;
    assign op_jalr = instr_i[i][6:0] == 7'b1100111;
    assign c1j    = instr_i[i][15:13] == 3'b101;
    assign c1beq  = instr_i[i][15:13] == 3'b110;
    assign c1bne  = instr_i[i][15:13] == 3'b111;
    assign c2jr   = (instr_i[i][15:13] == 3'b100) && (instr_i[i][6:2] == 5'b00000);
    assign slot_ctrl[i] = (rvi & (op_br | op_jal | op_jalr))
                        | (c1 & (c1j | c1beq | c1bne))
                        | (c2 & c2jr);
  end

  always_comb begin : gen_fifo_input
    for (int unsigned f = 0; f < NrFifo; f++) begin
      instr_data_in[f].instr     = '0;
      instr_data_in[f].pc        = '0;
      instr_data_in[f].cf        = cf_t'('0);
      instr_data_in[f].ckpt_v    = 1'b0;
      instr_data_in[f].ckpt_idx  = '0;
      instr_data_in[f].is_call   = 1'b0;
      instr_data_in[f].is_ret    = 1'b0;
      instr_data_in[f].is_ctrl   = 1'b0;
      instr_data_in[f].is_taken  = 1'b0;
      for (int unsigned i = 0; i < NrFifo; i++) begin
        instr_data_in[f].instr    |= instr_i[i]     & {32{fsel_oh[f][i]}};
        instr_data_in[f].pc       |= addr_i[i]      & {G6LCCfg.VLEN{fsel_oh[f][i]}};
        instr_data_in[f].cf       = cf_t'(logic'(instr_data_in[f].cf) |
                                          (logic'(cf_type_i[i]) &
                                           {$bits(cf_t){fsel_oh[f][i]}}));
        instr_data_in[f].ckpt_v   |= ckpt_v_i[i]    & fsel_oh[f][i];
        instr_data_in[f].ckpt_idx |= ckpt_idx_i[i]  & {$bits(ckpt_idx_i[i]){fsel_oh[f][i]}};
        instr_data_in[f].is_call  |= is_call_i[i]   & fsel_oh[f][i];
        instr_data_in[f].is_ret   |= is_return_i[i] & fsel_oh[f][i];
        instr_data_in[f].is_ctrl  |= slot_ctrl[i]   & fsel_oh[f][i];
        instr_data_in[f].is_taken |= taken[i]      & fsel_oh[f][i];
      end
      if (fsel_none[f]) begin
        instr_data_in[f].instr    = instr_i[0];
        instr_data_in[f].pc       = addr_i[0];
        instr_data_in[f].cf       = cf_type_i[0];
        instr_data_in[f].ckpt_v   = ckpt_v_i[0];
        instr_data_in[f].ckpt_idx = ckpt_idx_i[0];
        instr_data_in[f].is_call  = is_call_i[0];
        instr_data_in[f].is_ret   = is_return_i[0];
        instr_data_in[f].is_ctrl  = slot_ctrl[0];
        instr_data_in[f].is_taken = taken[0];
      end
      // an exception holds for the whole fetch packet
      instr_data_in[f].ex = exception_i;
      instr_data_in[f].ex_vaddr = exception_addr_i;
      instr_data_in[f].ex_gpaddr = G6LCCfg.RVH ? exception_gpaddr_i : '0;
      instr_data_in[f].ex_tinst = G6LCCfg.RVH ? exception_tinst_i : '0;
      instr_data_in[f].ex_gva = G6LCCfg.RVH && exception_gva_i;
      instr_data_in[f].hart = HidW'(g6lc_fetch_pkg::packet_hart(En, 8'(hart_i)));
      instr_data_in[f].epoch = push_epoch_i;
      // O7o: sequence by actual PC order within the valid (post-branch-mask)
      // slots of this push, then add the global packet counter. Same count
      // as the serial s2<s accumulate — $countones over the prefix mask.
      begin : rank_blk
        automatic logic [NrFifo-1:0] below_m;
        below_m = '0;
        for (int unsigned i = 0; i < NrFifo; i++)
          below_m |= {NrFifo{fsel_oh[f][i]}} & NrFifo'((NrFifo'(1) << i) - 1'b1);
        instr_data_in[f].push_seq = push_seq_q +
            {{(16 - IdxW) {1'b0}},
             IdxW'($countones(valid & below_m))};
      end
    end
  end
  // ----------------------
  // Replay Logic
  // ----------------------
  // Replay the fetch if an instruction FIFO we needed was full, or if the branch
  // target FIFO was full (then nothing of the packet is accepted at all).
  // hyp8: a dead-epoch window never replays — the epoch bump already owns the
  // restart, and re-presenting it would resurrect wrong-path work.
  assign address_overflow = full_address & push_address;
  assign replay_o = win_live & (instr_overflow | address_overflow);
  // Replay the I$ window (exception_addr_i = response window base), not slot0.
  // Leftover-complete slot0 is the carry PC in the previous window
  // (s4-v-norepl-npc: overflow replay'd 12956 then npc 12960/12968).
  // Completing window is vaddr 12958. I7 all-or-nothing so replay_sel
  // was always 0 on overflow. Not leftover_pending hold / I$ take drop.
  // Leftover-complete slot0 push: replay the first unpushed rest PC
  // (ld ra@1295a), not the completing window (would leftover_drop).
  assign replay_addr_o = (lo_partial && rest_found && |push_instr_fifo)
      ? rest_addr : exception_addr_i;

  // ----------------------
  // Downstream interface
  // ----------------------
  // O7o: select the issue group by circular position from the registered
  // drain head. Compact insertion maps consecutive logical positions onto
  // consecutive FIFOs and pop is a prefix, so the p-th oldest live entry is
  // always the FIFO at head+p; push_seq no longer arbitrates (trace only).
  // Each port's drain mask is a constant rotate of the one-hot head.
  // rotate_left's variable shift was on the issue-to-advance cone.
  for (genvar p = 0; p <= NrIssue; p++) begin : gen_idx_ds
    if (p == 0) begin : gen_rot0
      assign idx_ds[p] = idx_ds_q;
    end else if (p < NrFifo) begin : gen_rot
      assign idx_ds[p] = {idx_ds_q[NrFifo-p-1:0], idx_ds_q[NrFifo-1:NrFifo-p]};
    end else begin : gen_z
      assign idx_ds[p] = '0;
    end
  end

  // hyp8: per-lane eligibility = registered occupancy AND a live-epoch head.
  // A stale head is presented to nobody; it occupies its position until it is
  // dropped inside the consumed prefix below.
  // One epoch compare per FIFO. Live and stale are the two polarities
  // of that bit, so the presentable check does not wait on the stale OR.
  for (genvar f = 0; f < NrFifo; f++) begin : gen_lane_elig
    assign lane_epoch_ok[f] = instr_data_out[f].epoch == epoch_i;
    assign lane_live[f]     = ~instr_queue_empty[f] && lane_epoch_ok[f];
    assign lane_stale[f]    = ~instr_queue_empty[f] && !lane_epoch_ok[f];
  end

  // One-hot drain pointer: the selected lane is present when it is occupied
  // and its epoch matches. A zero pointer selects nothing.
  for (genvar p = 0; p < NrIssue; p++) begin : gen_pos_state
    assign pos_stale[p]   = |(lane_stale & idx_ds[p]);
    assign pos_present[p] = |(lane_live & idx_ds[p]);
  end

  // Guard against an all-zero drain pointer: it would present a bogus pc=0
  // entry from the initial FIFO state and lock the pointer at zero.
  // fill_prefix[p]: every position up to and including p holds an entry
  // (presentable or stale-dropping) — a hole before p blocks port p, and a
  // stale entry earlier in the group is being dropped so it does not block.
  assign fill_prefix[0] = pos_present[0] | pos_stale[0];
  for (genvar p = 1; p < NrIssue; p++) begin : gen_fill_prefix
    assign fill_prefix[p] = (pos_present[p] | pos_stale[p]) & fill_prefix[p-1];
  end

  // port 0 presents whenever its position holds a live entry; a later port
  // additionally requires that no earlier port carries a control-flow
  // instruction and that no hole or live-but-unconsumed entry precedes it.
  // block_any[p] is the OR of blocks_ss[0 .. p-1], same as the old carried scan.
  assign block_any[0] = 1'b0;
  for (genvar p = 1; p < NrIssue; p++) begin : gen_block_any
    assign block_any[p] = block_any[p-1] | fetch_entry_blocks_ss[p-1];
  end
  // Later-port valid is two ANDs of independent pairs, not one
  // left-folded four-input term.
  logic idx_any;
  assign idx_any = |idx_ds_q;
  assign fetch_entry_valid_o[0] = idx_any & pos_present[0];
  for (genvar p = 1; p < NrIssue; p++) begin : gen_fetch_entry_valid
    logic hold, gate;
    assign hold = pos_present[p] & fill_prefix[p-1];
    assign gate = ~block_any[p] & idx_any;
    assign fetch_entry_valid_o[p] = hold & gate;
  end

  always_comb begin : gen_fetch_entry
    for (int unsigned p = 0; p < NrIssue; p++) begin
      fetch_entry_o[p] = '0;
      fetch_entry_o[p].branch_predict.predict_address = address_out;
      fetch_entry_o[p].branch_predict.cf = g6lc_core_pkg::NoCF;
    end

    // map each issue port to its rotating FIFO slot
    for (int unsigned f = 0; f < NrFifo; f++) begin
      for (int unsigned p = 0; p < NrIssue; p++) begin
        if (idx_ds[p][f]) begin
          fetch_entry_o[p].instruction = instr_data_out[f].instr;
          // PC from the FIFO (realigner), not a combinational size chain
          fetch_entry_o[p].address = instr_data_out[f].pc;
          fetch_entry_o[p].ex.valid = instr_data_out[f].ex != g6lc_core_pkg::FE_NONE;
          unique case (instr_data_out[f].ex)
            g6lc_core_pkg::FE_INSTR_ACCESS_FAULT:
            fetch_entry_o[p].ex.cause = riscv::INSTR_ACCESS_FAULT;
            g6lc_core_pkg::FE_INSTR_GUEST_PAGE_FAULT:
            fetch_entry_o[p].ex.cause = (G6LCCfg.RVH && p == 0) ? riscv::INSTR_GUEST_PAGE_FAULT :
                riscv::INSTR_PAGE_FAULT;
            default: fetch_entry_o[p].ex.cause = riscv::INSTR_PAGE_FAULT;
          endcase
          if (G6LCCfg.TvalEn) begin
            fetch_entry_o[p].ex.tval = {
              {(G6LCCfg.XLEN - G6LCCfg.VLEN) {1'b0}}, instr_data_out[f].ex_vaddr
            };
          end
          if (G6LCCfg.RVH && p == 0) begin
            fetch_entry_o[p].ex.tval2 = instr_data_out[f].ex_gpaddr;
            fetch_entry_o[p].ex.tinst = instr_data_out[f].ex_tinst;
            fetch_entry_o[p].ex.gva   = instr_data_out[f].ex_gva;
          end
          fetch_entry_o[p].branch_predict.cf = instr_data_out[f].cf;
          fetch_entry_o[p].branch_predict.ckpt_v = instr_data_out[f].ckpt_v;
          fetch_entry_o[p].branch_predict.ckpt_idx = instr_data_out[f].ckpt_idx;
          fetch_entry_o[p].branch_predict.is_call = instr_data_out[f].is_call;
          fetch_entry_o[p].branch_predict.is_ret = instr_data_out[f].is_ret;
          fetch_entry_o[p].hart_id = instr_data_out[f].hart;
        end
      end
    end
  end

  // Opcode class and predicted-taken were stored at push. The drain
  // reduces those bits. It does not re-decode the head word or recompare cf.
  // NoCF is the zero encoding, so is_taken matches cf != NoCF.
  for (genvar f = 0; f < NrFifo; f++) begin : gen_lane_class
    assign lane_ctrl[f] = instr_data_out[f].is_ctrl;
    assign lane_cf[f]   = instr_data_out[f].is_taken;
  end
  for (genvar p = 0; p < NrIssue; p++) begin : gen_port_class
    assign port_ctrl[p] = |(idx_ds[p] & lane_ctrl);
    assign port_cf[p]   = |(idx_ds[p] & lane_cf);
  end

  for (genvar p = 0; p < NrIssue; p++) begin : gen_fire
    // taken CF from the predictor: pops the branch target FIFO
    assign fetch_entry_is_cf[p] = port_cf[p] & pos_present[p];
    // any CF-class instruction, including a not-taken branch; a stale position
    // is being dropped, so its (wrong-path) CF must not block later ports
    assign fetch_entry_blocks_ss[p] = (port_cf[p] | port_ctrl[p]) & pos_present[p];
    assign fetch_entry_fire[p] = fetch_entry_valid_o[p] & fetch_entry_ready_i[p];
  end

  // hyp8: one consumed prefix per cycle: a stale entry at a position is
  // dropped (popped without being issued) when every earlier position is
  // consumed; a live position is consumed only when its port fires.
  for (genvar p = 0; p < NrIssue; p++) begin : gen_pos_go
    assign pos_go[p] = pos_stale[p] | fetch_entry_fire[p];
  end
  assign consumed_pos[0] = pos_go[0];
  for (genvar p = 1; p < NrIssue; p++) begin : gen_consumed_prefix
    assign consumed_pos[p] = consumed_pos[p-1] & pos_go[p];
  end
  assign fire_prefix = consumed_pos;  // kept name for the pop/rotate maps

  always_comb begin : gen_pop
    pop_instr = '0;
    for (int unsigned f = 0; f < NrFifo; f++) begin
      for (int unsigned p = 0; p < NrIssue; p++) begin
        if (idx_ds[p][f]) pop_instr[f] = consumed_pos[p];
      end
    end
  end

  // One shared branch-target FIFO for all issue ports, so any firing CF pops it.
  // The consumed prefix (not the raw fire) keeps the pop aligned with the drain
  // order; a stale position carries cf=NoCF on the dropped packet anyway.
  assign pop_address = |(fetch_entry_is_cf & consumed_pos);

  // Highest consumed position wins, matching the ascending overwrite.
  // The rotated masks already exist, so the advance is a one-hot mux.
  logic [NrIssue-1:0] cons_hi;
  logic               cons_none;
  // Higher-consumed bits are constant-index wires. A part-select bound
  // of NrIssue is billed as a variable shift even when the width is known.
  for (genvar p = 0; p < NrIssue; p++) begin : gen_cons_hi
    logic [NrIssue-1:0] hi_bit;
    for (genvar h = 0; h < NrIssue; h++) begin : gen_hi
      if (h > p) assign hi_bit[h] = consumed_pos[h];
      else       assign hi_bit[h] = 1'b0;
    end
    assign cons_hi[p] = consumed_pos[p] & ~(|hi_bit);
  end
  assign cons_none = ~|consumed_pos;
  logic [NrIssue:0][NrFifo-1:0] adv_term;
  assign adv_term[0] = {NrFifo{cons_none}} & idx_ds[0];
  for (genvar p = 0; p < NrIssue; p++) begin : gen_adv
    assign adv_term[p+1] = adv_term[p] | ({NrFifo{cons_hi[p]}} & idx_ds[p+1]);
  end
  assign idx_ds_d = adv_term[NrIssue];

//pragma translate_off
  // -------------------------------------------------------------------------
  // ORDER PROBE (`+iq_trace`). I6 clause 1 -- "IQ order is program order" -- is
  // the clause g6lc_fetch_iq.sby does NOT prove (it proves clause 2,
  // value-independence, by self-composition, and both copies can be wrong in the
  // same way while it stays green). This makes clause 1 observable.
  //
  // Both rotating pointers are printed, because the output pointer alone looked
  // disciplined -- `idx_ds_d` advances only on `consumed_pos` -- which moves
  // suspicion to the INPUT pointer mapping pushes onto FIFOs the output pointer
  // has already passed. Order can break at either end and only the pair shows
  // which.
  //   isq/dsq/dsd  input pointer, output pointer, next output pointer
  //   push/valid   which FIFOs are written this cycle, and the slot valids
  //   fire         consumed_pos -- positions actually leaving the queue
  //   cons         consumed_o back to the frontend
  //   full/rdy     occupancy and the resulting ready_o
  //   a0           address leaving port 0, i.e. the order actually observed
  // -------------------------------------------------------------------------
  logic iqt_en;
  initial iqt_en = $test$plusargs("iq_trace");

  // The probe prints four fixed columns, but NrFifo is 2 in narrow configs.
  // Absent FIFOs read as zero rather than indexing past the array.
  logic [3:0][G6LCCfg.VLEN-1:0] dbg_pc;
  logic [3:0][15:0] dbg_seq;
  always_comb begin
    for (int unsigned k = 0; k < 4; k++) begin
      dbg_pc[k]  = (k < NrFifo) ? instr_data_out[(k < NrFifo) ? k : 0].pc : '0;
      dbg_seq[k] = (k < NrFifo) ? instr_data_out[(k < NrFifo) ? k : 0].push_seq : '0;
    end
  end

  // Sampled on the posedge (pre-update values): a negedge-sensitive block here was the
  // only negedge logic in the model and forced a full act/nba scheduler pass on every
  // negedge evaluation step of every simulation, armed or not.
  always @(posedge clk_i) begin
    if (rst_ni && iqt_en && $time() < 200000) begin
      if ((|push_instr_fifo) || (|consumed_o) || (|fetch_entry_valid_o)) begin
        // Single string literal: a concatenated {"..",".."} format compiles but
        // never reaches the binary, giving a silent no-op probe.
        $display("[iq] t=%0t psq=%0d psd=%0d isq=%b dsq=%b dsd=%b push=%b valid=%b fire=%b cons=%b full=%b rdy=%b a0=%h head=[%h %h %h %h] pseq=[%0d %0d %0d %0d]",
                 $time, push_seq_q, push_seq_d, idx_is_q, idx_ds_q, idx_ds_d, push_instr_fifo, valid,
                 consumed_pos, consumed_o, instr_queue_full, ready_o,
                 fetch_entry_o[0].address,
                 dbg_pc[0], dbg_pc[1], dbg_pc[2], dbg_pc[3],
                 dbg_seq[0], dbg_seq[1], dbg_seq[2], dbg_seq[3]);
      end
    end
  end
//pragma translate_on

  // ----------------------
  // FIFOs
  // ----------------------
  for (genvar i = 0; i < NrFifo; i++) begin : gen_instr_fifo
    // do not save an instruction if we could not save its branch target
    // DEPTH=4 replay'd leftover-complete 4-slot packets (s4-v-kill2
    // t=125002 replay=1 full=8). Dual-issue drain vs 4-wide leftover.
    g6lc_fifo_v3 #(
        .FPGA_ALTERA(G6LCCfg.FpgaAlteraEn),
        .DEPTH(IFifoDepth),
        .dtype(instr_data_t),
        .FPGA_EN(G6LCCfg.FpgaEn)
    ) i_fifo_instr_data (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   (flush_i),
        .testmode_i(1'b0),
        .full_o    (instr_queue_full[i]),
        .empty_o   (instr_queue_empty[i]),
        .usage_o   (instr_queue_usage[i]),
        .data_i    (instr_data_in[i]),
        .push_i    (push_instr_fifo[i]),
        .data_o    (instr_data_out[i]),
        .pop_i     (pop_instr[i])
    );
  end

  always_comb begin : gen_push_address
    push_address = 1'b0;
    for (int unsigned f = 0; f < NrFifo; f++) begin
      push_address |= push_instr[f] & (instr_data_in[f].cf != g6lc_core_pkg::NoCF);
    end
  end

  g6lc_fifo_v3 #(
      .FPGA_ALTERA(G6LCCfg.FpgaAlteraEn),
      .DEPTH      (g6lc_core_pkg::FETCH_ADDR_FIFO_DEPTH),
      .DATA_WIDTH (G6LCCfg.VLEN),
      .FPGA_EN    (G6LCCfg.FpgaEn)
  ) i_fifo_address (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (flush_i),
      .testmode_i(1'b0),
      .full_o    (full_address),
      .empty_o   (),
      .usage_o   (),
      .data_i    (predict_address_i),
      .push_i    (push_address & ~full_address),
      .data_o    (address_out),
      .pop_i     (pop_address)
  );

  // ----------------------
  // Per-hart pending frontier (T6b-3b)
  // ----------------------
  // The output ports expose only NrIssue positions; a peer hart's entries
  // queued deeper behind the presented slots are invisible to the restart
  // frontier. Keep one address FIFO per hart, pushed in push order and popped
  // once per delivered instruction of that hart — per-hart delivery order is
  // push order (compact insertion is program order and a packet is single-
  // hart), so the head is exactly that hart's oldest undelivered instruction.
  // hyp8: stale-epoch heads are dropped inside the consumed prefix without
  // being delivered, so the pending FIFOs must skip them too — a stale drop
  // pops the frontier address of the entry's stamped hart.
  // Mixed residency only: the whole block constant-folds to a '0 tie under
  // SmtDrainedHandoff and NrHarts==1.
  if (G6LCCfg.NrHarts > 1 && !G6LCCfg.SmtDrainedHandoff) begin : gen_pend_frontier
    localparam int unsigned PendDepth = NrFifo * IFifoDepth;
    localparam int unsigned PAW = (PendDepth > 1) ? $clog2(PendDepth) : 1;
    localparam int unsigned PopW = (NrIssue > 1) ? $clog2(NrIssue + 1) : 1;

    logic [G6LCCfg.NrHarts-1:0][PendDepth-1:0][G6LCCfg.VLEN-1:0] pend_mem;
    logic [G6LCCfg.NrHarts-1:0][PAW-1:0] pend_wr_q, pend_rd_q;
    logic [G6LCCfg.NrHarts-1:0][PAW:0] pend_cnt_q;

    // Pushed FIFOs are contiguous from idx_is_q (compact insertion), so the
    // k-th pushed instruction's PC is instr_data_in[(idx_is_q + k) mod NrFifo]
    // for k < shamt — already in push order.
    logic [NrFifo-1:0][G6LCCfg.VLEN-1:0] push_addr;
    for (genvar k = 0; k < NrFifo; k++) begin : gen_push_addr
      assign push_addr[k] =
          instr_data_in[fifo_idx_t'((idx_is_q + fifo_idx_t'(k)) & IdxMask)].pc;
    end

    // Deliveries per hart this cycle: the consumed prefix is the queue's
    // actual pop — a port handshake without the earlier prefix pops nothing,
    // and a stale-epoch position consumed without issue is a drop that the
    // frontier must still pass (its hart is the entry's stamped hart).
    logic [G6LCCfg.NrHarts-1:0][PopW-1:0] pop_cnt;
    always_comb begin : gen_pend_pop
      pop_cnt = '0;
      for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
        for (int unsigned p = 0; p < NrIssue; p++) begin
          if (consumed_pos[p]) begin
            for (int unsigned f = 0; f < NrFifo; f++) begin
              if (idx_ds[p][f] && instr_data_out[f].hart == HidW'(h))
                pop_cnt[h] = pop_cnt[h] + PopW'(1);
            end
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : gen_pend_ptrs
      if (!rst_ni) begin
        pend_wr_q <= '0;
        pend_rd_q <= '0;
        pend_cnt_q <= '0;
      end else if (flush_i) begin
        pend_wr_q <= '0;
        pend_rd_q <= '0;
        pend_cnt_q <= '0;
      end else begin
        for (int unsigned h = 0; h < G6LCCfg.NrHarts; h++) begin
          if (|shamt && hart_i == HidW'(h)) begin
            for (int unsigned k = 0; k < NrFifo; k++) begin
              if (k < int'(shamt))
                pend_mem[h][pend_wr_q[h] + PAW'(k)] <= push_addr[k];
            end
            pend_wr_q[h] <= pend_wr_q[h] + PAW'(shamt);
            pend_cnt_q[h] <= pend_cnt_q[h] + (PAW + 1)'(shamt) - (PAW + 1)'(pop_cnt[h]);
          end else begin
            pend_cnt_q[h] <= pend_cnt_q[h] - (PAW + 1)'(pop_cnt[h]);
          end
          pend_rd_q[h] <= pend_rd_q[h] + PAW'(pop_cnt[h]);
        end
      end
    end

    for (genvar h = 0; h < G6LCCfg.NrHarts; h++) begin : gen_pend_out
      assign queue_oldest_valid_o[h] = |pend_cnt_q[h];
      assign queue_oldest_pc_o[h] = pend_mem[h][pend_rd_q[h]];
    end

//pragma translate_off
    // Delivery order is push order per hart: the rank-th same-hart delivery
    // this cycle must read the rank-th pending entry from the head. Stale
    // drops leave the queue without an address to compare — only live fires
    // are checked.
    always @(posedge clk_i) begin : gen_pend_order_check
      if (rst_ni && !flush_i) begin
        for (int unsigned p = 0; p < NrIssue; p++) begin
          int unsigned rank;
          rank = 0;
          for (int unsigned q = 0; q < p; q++) begin
            if (consumed_pos[q] && !pos_stale[q] &&
                fetch_entry_o[q].hart_id == fetch_entry_o[p].hart_id)
              rank++;
          end
          if (consumed_pos[p] && !pos_stale[p]) begin
            assert (fetch_entry_o[p].address ==
                    pend_mem[int'(fetch_entry_o[p].hart_id)]
                            [pend_rd_q[int'(fetch_entry_o[p].hart_id)] + PAW'(rank)])
            else $error("[instr_queue] pending-frontier order broke: port %0d hart %0d pc %h",
                        p, fetch_entry_o[p].hart_id, fetch_entry_o[p].address);
          end
        end
      end
    end
//pragma translate_on
  end else begin : gen_no_pend_frontier
    assign queue_oldest_valid_o = '0;
    assign queue_oldest_pc_o = '0;
  end

  // ----------------------
  // Pointers
  // ----------------------
  if (NrFifo > 1) begin : gen_rotating_pointers
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        idx_ds_q <= {{NrFifo - 1{1'b0}}, 1'b1};  // one-hot
        idx_is_q <= '0;  // binary
        push_seq_q <= '0;
      end else if (flush_i) begin
        idx_ds_q <= {{NrFifo - 1{1'b0}}, 1'b1};
        idx_is_q <= '0;
        push_seq_q <= '0;
      end else begin
        idx_ds_q <= idx_ds_d;
        idx_is_q <= idx_is_d;
        push_seq_q <= push_seq_d;
      end
    end
  end else begin : gen_static_pointers
    assign idx_ds_q = 1'b1;
    assign idx_is_q = '0;
  end

  // pragma translate_off
  replay_address_fifo :
  assert property (@(posedge clk_i) disable iff (!rst_ni) replay_o |-> !i_fifo_address.push_i)
  else $fatal(1, "[instr_queue] Pushing address although replay asserted");

  output_select_onehot :
  assert property (@(posedge clk_i) $onehot0(idx_ds_q))
  else begin
    $error("Output select should be one-hot encoded");
    $stop();
  end

  // Per-head class matches is_ctrl_instr. The one-hot reduce is the select.
  always_comb begin : lane_class_chk
    for (int unsigned f = 0; f < NrFifo; f++) begin
      assert (lane_ctrl[f] == is_ctrl_instr(instr_data_out[f].instr))
      else $error("[instr_queue] lane_ctrl diverged from is_ctrl_instr");
      assert (lane_cf[f] == (instr_data_out[f].cf != g6lc_core_pkg::NoCF))
      else $error("[instr_queue] lane_cf diverged from cf != NoCF");
    end
  end
  // pragma translate_on
endmodule
