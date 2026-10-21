// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// hyp8: W1/W2/W3 request pipeline (registered pa-compares + lowest-free at
// W1, decision/select at W2, byte merge/coalesce + array write at W3),
// registered data_gnt (+2 grant),
// two-step drain select, wbuffer_data_o widened by the pending-export entry,
// fixup version epochs, g6lc_hyp_rr_arb_tree arbiters.
// SPDX-FileCopyrightText: machine-generated
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 13.09.2018
// Description: coalescing write buffer for WT dcache
// Modified by: Etienne Cimon (Verilator width)
//
// A couple of notes:
//
// 1) the write buffer behaves as a fully-associative cache, and is therefore coalescing.
//    this cache is used by the cache readout logic to forward data to the load unit.
//
//    each byte can be in the following states (valid/dirty/txblock):
//
//    0/0/0:    invalid -> free entry in the buffer
//    1/1/0:    valid and dirty, Byte is hence not part of TX in-flight
//    1/0/1:    valid and not dirty, Byte is part of a TX in-flight
//    1/1/1:    valid and, part of tx and dirty. this means that the byte has been
//              overwritten while in TX and needs to be retransmitted once the write of that byte returns.
//    1/0/0:    this would represent a clean state, but is never reached in the wbuffer in the current implementation.
//              this is because when a TX returns, and the byte is in state [1/0/1], it is written to cache if needed and
//              its state is immediately cleared to 0/x/x.
//
//    this state is used to distinguish between bytes that have been written and not
//    yet sent to the memory subsystem, and bytes that are part of a transaction.
//
// 2) further, each word in the write buffer has a cache states (checked, hit_oh)
//
//    checked == 0: unknown cache state
//    checked == 1: cache state has been looked up, valid way is stored in "hit_oh"
//
//    cache invalidations/refills affecting a particular word will clear its word state to 0,
//    so another lookup has to be done. note that these lookups are triggered as soon as there is
//    a valid word with checked == 0 in the write buffer.
//
// 3) returning write ACKs free the TX immediately. If the word is already tag-checked and present
//    in the cache, the clean BE is written back to the data array. If the tag state is still VOID
//    (checked==0) when the ACK races in, the TX is still freed (do not hold rtrn forever — that
//    deadlocks load misses via tx_rdwr_collision); the word is dropped from the buffer / retransmitted
//    if re-dirtied. Memory already holds the written bytes.
//    Exception: OpenSBI ecall extension objects at 0x80040xxx (list/time/rfence/ipi,
//    not namelen stack 0x80046xxx). VOID ACK keeps the word until tag-check, then wr_req
//    the hit way. Unfiltered VOID-late hung pin @12aa8; dropping these words leaves
//    L1 at ELF BSS 0 (hold IPI walk a5=0 on ecall_rfence.next).
//    Widening to 0x80040–0x80045 (console_tbuf) did not unhang hold printf; reverted.
//
//    That window is named VoidKeepEn / VoidKeepTag below; VoidKeepEn = 0 compiles
//    the containment out and restores stock upstream ACK handling. Do not widen it
//    without a proxy run: every address-agnostic form of the fix is recorded
//    reverted in architecture/multi-threading/linux-boot-scale.md S1.
//
// 4) we handle NC writes using the writebuffer circuitry. upon an NC request, the writebuffer will first be drained.
//    then, only the NC word is written into the write buffer and no further write requests are acknowledged until that
//    word has been evicted from the write buffer.


module wt_dcache_wbuffer
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: WbufPipelined gates the W1/W2 request pipeline + registered
    // data_gnt + two-step drain (137.1-FO4 cone class)
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter DCACHE_CL_IDX_WIDTH = 0,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type wbuffer_t = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni, // Asynchronous reset active low

    input logic cache_en_i,  // writes are treated as NC if disabled
    output logic empty_o,  // asserted if no data is present in write buffer
    output logic not_ni_o,  // asserted if no ni data is present in write buffer
    // core request ports
    input dcache_req_i_t req_port_i,
    output dcache_req_o_t req_port_o,
    // interface to miss handler
    input logic miss_ack_i,
    output logic [G6LCCfg.PLEN-1:0] miss_paddr_o,
    output logic miss_req_o,
    output logic miss_we_o,  // always 1 here
    output logic [G6LCCfg.XLEN-1:0] miss_wdata_o,
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] miss_wuser_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits_o,  // unused here (set to 0)
    output logic miss_nc_o,  // request to I/O space
    output logic [2:0] miss_size_o,  //
    output logic [G6LCCfg.MEM_TID_WIDTH-1:0]          miss_id_o,       // ID of this transaction (wbuffer uses all IDs from 0 to DCACHE_MAX_TX-1)
    // write responses from memory
    input logic miss_rtrn_vld_i,
    input logic [G6LCCfg.MEM_TID_WIDTH-1:0] miss_rtrn_id_i,  // transaction ID to clear
    // cache read interface
    output logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] rd_tag_o,  // tag in - comes one cycle later
    output logic [DCACHE_CL_IDX_WIDTH-1:0] rd_idx_o,
    output logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] rd_off_o,
    output logic rd_req_o,  // read the word at offset off_i[:3] in all ways
    output logic rd_tag_only_o,  // set to 1 here as we do not have to read the data arrays
    input logic rd_ack_i,
    input logic [G6LCCfg.XLEN-1:0] rd_data_i,  // unused
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_vld_bits_i,  // unused
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_hit_oh_i,
    // cacheline writes
    input logic wr_cl_vld_i,
    input logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx_i,
    input logic wr_cl_inv_i,  // cacheline write is an invalidation; no valid bits installed
    // cache word write interface
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_req_o,
    input logic wr_ack_i,
    output logic [DCACHE_CL_IDX_WIDTH-1:0] wr_idx_o,
    output logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] wr_off_o,
    output logic [G6LCCfg.XLEN-1:0] wr_data_o,
    output logic [(G6LCCfg.XLEN/8)-1:0] wr_data_be_o,
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] wr_user_o,
    // explicit line invalidation for SL-W fixup queue
    output logic inv_req_o,
    input logic inv_ack_i,
    output logic [DCACHE_CL_IDX_WIDTH-1:0] inv_idx_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] inv_way_oh_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] inv_vld_bits_o,
    // SL-W PMU events
    output logic pm_void_ack_o,
    output logic pm_fixup_write_o,
    output logic pm_fixup_inval_o,
    output logic pm_fixup_full_o,
    // SL-W fixup queue forwarding to read mux (newest-first, bypass then FIFO)
    output wbuffer_t [G6LCCfg.WtDcacheFixupDepth:0] fixup_wbuffer_o,
    // to forwarding logic and miss unit
    // hyp8: widened by one virtual entry — index WtDcacheWbufDepth carries
    // the in-flight pending record (the store accepted this cycle) so byte
    // merge keeps +0 forwarding latency while the write is staged.
    // hyp8 r5: DEPTH queue entries + 2 pending-export records (the W3
    // deferred write + the fresh accept) so a store stays forward-visible
    // at +0 across the whole accept->W3-apply window.
    output wbuffer_t [G6LCCfg.WtDcacheWbufDepth+1:0] wbuffer_data_o,
    output logic [G6LCCfg.DCACHE_MAX_TX-1:0][G6LCCfg.PLEN-1:0]     tx_paddr_o,      // used to check for address collisions with read operations
    output logic [G6LCCfg.DCACHE_MAX_TX-1:0] tx_vld_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin wt_dcache_wbuffer status=proposal target=10-adjusted-FO4
  // svt-plan: cone fixup selection, coalescing, supersession and array-write
  // acknowledgement interact with the same pending entry and its byte mask.
  // svt-plan: reshape retain the existing acceptance-time T47 byte clearing;
  // use stationary fixup descriptors plus narrow age references for exports.
  // svt-plan: boundary prepare a fixup write descriptor after tag lookup;
  // retire it only when the array grants the still-live byte subset.
  // svt-plan: carry source slot+generation, PA, data/user, be, way and
  // tag/invalidation version; keep the source reserved until acknowledgement.
  // svt-plan: conflict a coalesce/new store/invalidation after preparation
  // must mask or invalidate the descriptor, including on its grant cycle;
  // replay changed payloads rather than writing old data under a new mask.
  // svt-plan: visibility export the pending write until array visibility;
  // preserve newest-byte order across wbuffer, fixup queue and bypass entry.
  // svt-plan: effect separates tag/age selection from payload write control;
  // a bounded local supersession check replaces repeating the entire lookup.
  // svt-plan: cost descriptor storage and version comparisons; write service
  // gains a cycle and can replay, so capacity includes prepared/inflight work.
  // svt-plan: limit byte conflict checks remain on grant; increasing pending
  // depth without shortening the export merge can move the bottleneck there.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 105.6 adjusted FO4 on the
  // Nangate45 board): fixup and wbuffer next-state merge accepted stores,
  // deferred writes and byte supersession. wbuffer_data_o exports wbuffer_q;
  // load byte selection is in wt_dcache_mem. Staging must reserve acceptance
  // capacity and preserve supersession before a deferred write can retire.
  // svt-pipe: require-contract
  // svt-pipe: protocol wb valid=miss_req_o
  // svt-pipe: no-cut on=wbuffer_data_o
  // svt-pipe: no-cut on=fixup_bypass_d
  // svt-pipe: cycle wb q=wbuffer_q d=wbuffer_data_o hold=miss_req_o steps=1
  // svt-pipe: cut-ok wb on=wbuffer_data_o
  // wbuffer_data_o is already wbuffer_q. No extra register; fixup_bypass_d stays locked.

  function automatic logic [(G6LCCfg.XLEN/8)-1:0] to_byte_enable8(
      input logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] offset, input logic [1:0] size);
    logic [(G6LCCfg.XLEN/8)-1:0] be;
    be = '0;
    unique case (size)
      2'b00:   be[offset] = '1;  // byte
      2'b01:   be[offset+:2] = '1;  // hword
      2'b10:   be[offset+:4] = '1;  // word
      default: be = '1;  // dword
    endcase  // size
    return be;
  endfunction : to_byte_enable8

  function automatic logic [(G6LCCfg.XLEN/8)-1:0] to_byte_enable4(
      input logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] offset, input logic [1:0] size);
    logic [3:0] be;
    logic [1:0] off4;
    off4 = offset[1:0];
    be = '0;
    unique case (size)
      2'b00:   be[off4] = 1'b1;  // byte
      2'b01:   be[off4+:2] = 2'b11;  // hword
      default: be = 4'b1111;  // word
    endcase  // size
    return (G6LCCfg.XLEN / 8)'(be);
  endfunction : to_byte_enable4

  // openpiton requires the data to be replicated in case of smaller sizes than dwords
  function automatic logic [G6LCCfg.XLEN-1:0] repData64(
      input logic [G6LCCfg.XLEN-1:0] data, input logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] offset,
      input logic [1:0] size);
    logic [G6LCCfg.XLEN-1:0] out;
    unique case (size)
      2'b00:   for (int k = 0; k < 8; k++) out[k*8+:8] = data[offset*8+:8];  // byte
      2'b01:   for (int k = 0; k < 4; k++) out[k*16+:16] = data[offset*8+:16];  // hword
      2'b10:   for (int k = 0; k < 2; k++) out[k*32+:32] = data[offset*8+:32];  // word
      default: out = data;  // dword
    endcase  // size
    return out;
  endfunction : repData64

  function automatic logic [G6LCCfg.XLEN-1:0] repData32(
      input logic [G6LCCfg.XLEN-1:0] data, input logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] offset,
      input logic [1:0] size);
    logic [G6LCCfg.XLEN-1:0] out;
    unique case (size)
      2'b00:   for (int k = 0; k < 4; k++) out[k*8+:8] = data[offset*8+:8];  // byte
      2'b01:   for (int k = 0; k < 2; k++) out[k*16+:16] = data[offset*8+:16];  // hword
      default: out = data;  // word
    endcase  // size
    return out;
  endfunction : repData32

  typedef struct packed {
    logic                                         vld;
    logic                                         nc;
    logic                                         inv;
    logic [(G6LCCfg.XLEN/8)-1:0]                  be;
    logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0] ptr;
  } tx_stat_t;

  tx_stat_t [G6LCCfg.DCACHE_MAX_TX-1:0] tx_stat_d, tx_stat_q;
  wbuffer_t [G6LCCfg.WtDcacheWbufDepth-1:0] wbuffer_d, wbuffer_q;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] valid;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] dirty;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] tocheck;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] wbuffer_hit_oh, inval_hit;
  //logic     [G6LCCfg.WtDcacheWbufDepth-1:0][7:0]    bdirty;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0][(G6LCCfg.XLEN/8)-1:0] bdirty;

  logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0]
      next_ptr, dirty_ptr, hit_ptr, wr_ptr, check_ptr_d, check_ptr_q, check_ptr_q1, rtrn_ptr;
  // hyp8: tag-check consume chain extension. With DcacheHitExtra==2 the
  // mem response arrives two cycles later, so the consume stage
  // (check_*_q1 / fixup_check_en_q1) is tapped off p3 instead of q.
  localparam bit WBCHK_PIPE = (HypCfg.DcacheHitExtra == 2);
  logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0] check_ptr_p2, check_ptr_p3;
  logic [$bits(wbuffer_q[0].wtag)-1:0] check_wtag_p2, check_wtag_p3;
  logic check_en_p2, check_en_p3;
  logic [G6LCCfg.MEM_TID_WIDTH-1:0] tx_id, rtrn_id;

  // hyp8 r3: the ACK-return record reads are dynamic-index NR:1 selects
  // reused across the fixup/evict/drain logic; hoist them once so every
  // consumer shares the select.
  tx_stat_t                            rtrn_tx;
  wbuffer_t                            rtrn_wb;
  logic                                          w3_vld_q, w3_is_ni_q;
  logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0]  w3_ptr_q;
  logic [G6LCCfg.DCACHE_TAG_WIDTH+G6LCCfg.DCACHE_INDEX_WIDTH-
         G6LCCfg.XLEN_ALIGN_BYTES-1:0]           w3_wtag_q;
  logic [(G6LCCfg.XLEN/8)-1:0]                   w3_be_q;
  logic [G6LCCfg.XLEN-1:0]                       w3_wdata_q;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]          w3_wuser_q;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0]          w3_pend_oh;
  logic                          e_req, e_is_ni;
  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0]   e_tag;
  logic [G6LCCfg.DCACHE_INDEX_WIDTH-1:0] e_idx;
  logic [G6LCCfg.XLEN-1:0]               e_wdata;
  logic [(G6LCCfg.XLEN/8)-1:0]           e_be;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]  e_wuser;
  logic                          e_accept, e_hit_any;
  logic ni_inside, ni_conflict;
  // hyp8 r6: the return-id decode and the NR:1 record read are one cycle.
  // Evict legality, fixup, and the TX pop run on the registered snapshot,
  // so the mux and the legality fold are not one register-to-register path.
  // Store forwarding reads wbuffer_q and the W3 pending export, not this
  // snapshot, so a load does not wait an extra cycle.
  logic                                rtrn_snap_v_q;
  logic [G6LCCfg.MEM_TID_WIDTH-1:0]    rtrn_snap_id_q;
  logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0] rtrn_snap_ptr_q;
  tx_stat_t                            rtrn_snap_tx_q;
  wbuffer_t                            rtrn_snap_wb_q;
  logic [G6LCCfg.MEM_TID_WIDTH-1:0]    rtrn_id_raw;
  assign rtrn_tx  = rtrn_snap_tx_q;
  assign rtrn_wb  = rtrn_snap_wb_q;
  assign rtrn_id  = rtrn_snap_id_q;


  logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] bdirty_off;
  logic [(G6LCCfg.XLEN/8)-1:0] tx_be;
  logic [G6LCCfg.PLEN-1:0] wr_paddr, rd_paddr, extract_tag;
  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] rd_tag_d, rd_tag_q;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_hit_oh_d, rd_hit_oh_q;
  logic check_en_d, check_en_q, check_en_q1;
  // T34: the word a tag check was issued for, carried beside check_ptr. A
  // slot can be ACKed, freed and re-allocated to a new store inside the two
  // cycles the check takes (write-through ACK in 1-2 cycles); without this
  // the result (checked/hit_oh of the OLD word's line) landed on the NEW
  // occupant, whose ACK-time write then went to another way or was skipped:
  // the real line stayed stale and a line in the wrong way took the bytes
  // (Linux memblock: sd 0x80040000 at c=6,704,293, ld 129 cycles later read
  // 0x80000000; prof-t34fst). A result is applied only to the same word.
  logic [$bits(wbuffer_q[0].wtag)-1:0] check_wtag_d, check_wtag_q, check_wtag_q1;
  logic check_same_q1;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_wbuffer  region=4207  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: fixup_check_en_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_check_en_q
// order expect: fixup_check_en_q1  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_check_en_q1
// order expect: fixup_hit_oh_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to fixup_hit_oh_q
// order expect: fixup_vld_bits_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to fixup_vld_bits_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     fixup_check_en_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_check_en_q1 <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_hit_oh_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_vld_bits_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14521 c=3.50 slack=1.00 */
//     /* node14522 c=3.50 slack=1.00 */
//     /* node14523 c=3.50 slack=1.00 */
//     /* node14524 c=3.50 slack=1.00 */
//     /* node14525 c=3.50 slack=1.00 */
//     /* node14526 c=3.50 slack=1.00 */
//     /* node14527 c=4.50 slack=0.00 */
//     /* node14528 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_wbuffer  region=4227  makespan=8.000 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: fixup_bypass_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_bypass_q
// order expect: fixup_bypass_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_bypass_valid_q
// order expect: fixup_cnt  ready_cycle=1  ready_fo4=8.000  OpenSTA: report_timing -from clk_i -to fixup_cnt
// order expect: fixup_head  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to fixup_head
// order expect: fixup_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_q
// order expect: fixup_sel_bypass_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_sel_bypass_q
// order expect: fixup_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to fixup_state_q
// order expect: fixup_tail  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to fixup_tail
// order expect: refill_hit_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to refill_hit_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     fixup_bypass_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_bypass_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_cnt <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_head <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_sel_bypass_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     fixup_tail <= …; // sv-timing: cycle 1/1 on clk_i
//     refill_hit_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14596 c=3.50 slack=4.50 */
//     /* node14597 c=3.50 slack=4.50 */
//     /* node14598 c=3.50 slack=4.50 */
//     /* node14599 c=3.50 slack=4.50 */
//     /* node14600 c=3.50 slack=4.50 */
//     /* node14601 c=3.50 slack=4.50 */
//     /* node14602 c=3.50 slack=4.50 */
//     /* node14603 c=3.50 slack=4.50 */
//     /* node14604 c=3.50 slack=4.50 */
//     /* node14605 c=3.50 slack=4.50 */
//     /* node14606 c=3.50 slack=4.50 */
//     /* node14607 c=3.50 slack=4.50 */
//     /* node14608 c=3.50 slack=4.50 */
//     /* node14609 c=3.50 slack=4.50 */
//     /* node14610 c=3.50 slack=4.50 */
//     /* node14611 c=4.50 slack=3.50 */
//     /* node14612 c=4.50 slack=3.50 */
//     /* node14613 c=8.00 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_wbuffer  region=4285  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: check_en_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_en_q
// order expect: check_en_q1  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_en_q1
// order expect: check_ptr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_ptr_q
// order expect: check_ptr_q1  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_ptr_q1
// order expect: check_wtag_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_wtag_q
// order expect: check_wtag_q1  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to check_wtag_q1
// order expect: ni_pending_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ni_pending_q
// order expect: rd_hit_oh_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to rd_hit_oh_q
// order expect: rd_tag_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to rd_tag_q
// order expect: tx_stat_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to tx_stat_q
// order expect: void_keep_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to void_keep_q
// order expect: wbuffer_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wbuffer_q
// order expect: wr_cl_idx_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_cl_idx_q
// order expect: wr_cl_vld_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_cl_vld_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     check_en_q <= …; // sv-timing: cycle 1/1 on clk_i
//     check_en_q1 <= …; // sv-timing: cycle 1/1 on clk_i
//     check_ptr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     check_ptr_q1 <= …; // sv-timing: cycle 1/1 on clk_i
//     check_wtag_q <= …; // sv-timing: cycle 1/1 on clk_i
//     check_wtag_q1 <= …; // sv-timing: cycle 1/1 on clk_i
//     ni_pending_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rd_hit_oh_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rd_tag_q <= …; // sv-timing: cycle 1/1 on clk_i
//     tx_stat_q <= …; // sv-timing: cycle 1/1 on clk_i
//     void_keep_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wbuffer_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_cl_idx_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_cl_vld_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14790 c=3.50 slack=0.00 */
//     /* node14791 c=3.50 slack=0.00 */
//     /* node14792 c=3.50 slack=0.00 */
//     /* node14793 c=3.50 slack=0.00 */
//     /* node14794 c=3.50 slack=0.00 */
//     /* node14795 c=3.50 slack=0.00 */
//     /* node14796 c=3.50 slack=0.00 */
//     /* node14797 c=3.50 slack=0.00 */
//     /* node14798 c=3.50 slack=0.00 */
//     /* node14799 c=3.50 slack=0.00 */
//     /* node14800 c=3.50 slack=0.00 */
//     /* node14801 c=3.50 slack=0.00 */
//     /* node14802 c=3.50 slack=0.00 */
//     /* node14803 c=3.50 slack=0.00 */
//     /* node14804 c=3.50 slack=0.00 */
//     /* node14805 c=3.50 slack=0.00 */
//     /* node14806 c=3.50 slack=0.00 */
//     /* node14807 c=3.50 slack=0.00 */
//     /* node14808 c=3.50 slack=0.00 */
//     /* node14809 c=3.50 slack=0.00 */
//     /* node14810 c=3.50 slack=0.00 */
//     /* node14811 c=3.50 slack=0.00 */
//     /* node14812 c=3.50 slack=0.00 */
//     /* node14813 c=3.50 slack=0.00 */
//     /* node14814 c=3.50 slack=0.00 */
//     /* node14815 c=3.50 slack=0.00 */
//     /* node14816 c=3.50 slack=0.00 */
//     /* node14817 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // Per-slot tag compare. A variable index of the tag, then one compare,
  // was the front of the ni_pending cone. chk_hit[gi] is that compare
  // AND the pointer match; check_same_q1 is the OR.
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] chk_hit;
  assign check_same_q1 = |chk_hit;
  logic full, dirty_rd_en, rdy;
  logic rtrn_empty, evict, evict_base;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] ni_pending_d, ni_pending_q;
  logic wbuffer_wren;
  logic free_tx_slots;

  logic wr_cl_vld_q, wr_cl_vld_d;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx_q, wr_cl_idx_d;

  logic ack_wr_active;
  logic ack_wr_sel, ack_wr_lost;
  logic fixup_hold;
  logic leg_go_q, leg_fire_q;
  logic [G6LCCfg.PLEN-1:0]              leg_paddr_q;
  logic [(G6LCCfg.XLEN/8)-1:0]          leg_be_q;
  logic [G6LCCfg.XLEN-1:0]              leg_data_q;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] leg_user_q;
  // Comb candidate. Feeds only the legality register. The queue reads
  // leg_fire_q / leg_*_q, so this cone ends at that edge.
  logic                                 leg_fire_d;
  logic                                 leg_l1_q, leg_l1_d;
  logic                                 leg_push_q;
  logic [G6LCCfg.PLEN-1:0]              leg_push_paddr_q;
  logic [(G6LCCfg.XLEN/8)-1:0]          leg_push_be_q;
  logic [G6LCCfg.XLEN-1:0]              leg_push_data_q;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] leg_push_user_q;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]  leg_l1_oh_q, leg_l1_oh_d;
  logic [G6LCCfg.PLEN-1:0]              leg_paddr_d;
  logic [(G6LCCfg.XLEN/8)-1:0]          leg_be_d;
  logic [G6LCCfg.XLEN-1:0]              leg_data_d;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] leg_user_d;
  logic rtrn_inv;
  logic [G6LCCfg.WtDcacheWbufDepth-1:0][DCACHE_CL_IDX_WIDTH-1:0] wtag_comp;

  logic [G6LCCfg.PLEN-1:0] debug_paddr[G6LCCfg.WtDcacheWbufDepth-1:0];

  // VOID-keep window (header note 3). This is containment for the
  // ACK-before-check stale-L1 class, not a general fix: a write ACK that races
  // ahead of its tag check frees the TX and drops the word, so the clean bytes
  // never reach the L1 data array while a stale copy of that line may still be
  // resident. Main memory is correct, L1 is not, and a later load hits the
  // stale way.
  //
  // Holding every VOID-ACK word until its tag check either deadlocks the return
  // FIFO or hangs the firmware; the address-agnostic variants are all recorded
  // reverted in architecture/multi-threading/linux-boot-scale.md S1 (ackinv,
  // voidchk2, keep/keepv/keep1..7, snoopd, wr1). The only known-green
  // containment is this narrow window over the OpenSBI ecall-extension objects
  // (list/time/rfence/ipi at 0x80040xxx, not the namelen stack at 0x80046xxx).
  // Widening it to 0x80040-0x80045 (console_tbuf) was tried and reverted.
  //
  // Because the window is workload-scoped it is an open item, not a design: it
  // is the only hard-coded workload address in synthesizable core RTL and it
  // must be replaced by an address-agnostic mechanism before this core supports
  // another memory map or another firmware. Tracked as SL-W in AGENTS-todo.md.
  //
  // hyp8 config bit is 0. A struct-field parameter is not folded, so the
  // void-keep compare stayed on the slot next-state cone. Literal 0 removes it.
  localparam bit VoidKeepEn = 1'b0;
  localparam logic [19:0] VoidKeepTag = 20'h80040;

  logic [G6LCCfg.WtDcacheWbufDepth-1:0] void_keep_d, void_keep_q;
  logic [G6LCCfg.PLEN-1:0] wr_paddr_check;
  logic [(G6LCCfg.XLEN/8)-1:0] ack_be;
  logic check_wr;

  // SL-W post-ACK fixup queue (see architecture/dcache-ack-before-check.md §3.1).
  // When G6LCCfg.WtDcacheFixupDepth is 0 the block is empty and all fixup
  // signals are tied off: the legacy VoidKeepEn path is preserved bit-identical.
  logic                       fixup_push, fixup_full, fixup_evict, fixup_match;
  logic                       fixup_export_push;
  logic [G6LCCfg.PLEN-1:0]    fixup_paddr_push;
  logic [(G6LCCfg.XLEN/8)-1:0] fixup_be_push;
  logic [G6LCCfg.XLEN-1:0]    fixup_data_push;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] fixup_user_push;
  logic                       fixup_empty;
  logic                       fixup_pm_void_ack, fixup_pm_write, fixup_pm_inval, fixup_pm_full;

  logic                       fixup_rd_req, fixup_rd_tag_only;
  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] fixup_rd_tag;
  logic [DCACHE_CL_IDX_WIDTH-1:0]      fixup_rd_idx;
  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] fixup_rd_off;
  logic                                fixup_check_en_d, fixup_check_en_q, fixup_check_en_q1;
  logic                                fixup_check_en_p2, fixup_check_en_p3;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] fixup_hit_oh_q;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] fixup_vld_bits_q;

  logic                       fixup_wr_req, fixup_wr_ack;
  // Register-only view of "fixup owns the write port". The FSM's
  // fixup_wr_req is the same bit, but it is assigned inside the queue
  // controller, so reading it would pull that cone into the grant.
  logic                       fixup_wr_pend;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] fixup_wr_oh;
  logic [DCACHE_CL_IDX_WIDTH-1:0]      fixup_wr_idx;
  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] fixup_wr_off;
  logic [G6LCCfg.XLEN-1:0]             fixup_wr_data;
  logic [(G6LCCfg.XLEN/8)-1:0]         fixup_wr_data_be;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] fixup_wr_user;

  logic                       fixup_inv_req, fixup_inv_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0]      fixup_inv_idx;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] fixup_inv_way_oh;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] fixup_inv_vld_bits;

  wbuffer_t wbuffer_check_mux, wbuffer_dirty_mux;
  logic     rtrn_checked_mid;

  ///////////////////////////////////////////////////////
  // SL-W fixup queue
  ///////////////////////////////////////////////////////

  generate
    if (G6LCCfg.WtDcacheFixupDepth == 0) begin : gen_fixup_disabled
      // No queue allocated: tie off the fixup interface.
      assign fixup_empty          = 1'b1;
      assign fixup_full           = 1'b0;
      assign fixup_match          = 1'b0;
      assign fixup_rd_req         = 1'b0;
      assign fixup_rd_tag         = '0;
      assign fixup_rd_idx         = '0;
      assign fixup_rd_off         = '0;
      assign fixup_rd_tag_only    = 1'b1;
      assign fixup_wr_req         = 1'b0;
      assign fixup_wr_pend        = 1'b0;
      assign fixup_wr_oh          = '0;
      assign fixup_wr_idx         = '0;
      assign fixup_wr_off         = '0;
      assign fixup_wr_data        = '0;
      assign fixup_wr_data_be     = '0;
      assign fixup_wr_user        = '0;
      assign fixup_inv_req        = 1'b0;
      assign fixup_inv_idx        = '0;
      assign fixup_inv_way_oh     = '0;
      assign fixup_inv_vld_bits   = '0;
      assign inv_req_o            = 1'b0;
      assign inv_idx_o            = '0;
      assign inv_way_oh_o         = '0;
      assign inv_vld_bits_o       = '0;
      // ack_wr_active is NOT tied off here: p_tx_stat drives it procedurally in
      // every config, and only gen_fixup_queue reads it. A tie-off would be a
      // second driver on a procedurally-assigned variable.
      assign fixup_pm_void_ack    = 1'b0;
      assign fixup_pm_write       = 1'b0;
      assign fixup_pm_inval       = 1'b0;
      assign fixup_pm_full        = 1'b0;
      assign pm_void_ack_o        = 1'b0;
      assign pm_fixup_write_o     = 1'b0;
      assign pm_fixup_inval_o     = 1'b0;
      assign pm_fixup_full_o      = 1'b0;
      assign fixup_wbuffer_o      = '{default: '0};
    end else begin : gen_fixup_queue
      // Queue entry type.  Only the head of the FIFO is processed at a time.
      typedef enum logic [1:0] {
        FIXUP_PEND,
        FIXUP_CHECK,
        FIXUP_RETIRE
      } fixup_state_t;

      typedef struct packed {
        logic [G6LCCfg.PLEN-1:0]            paddr;
        logic [(G6LCCfg.XLEN/8)-1:0]        be;
        logic [G6LCCfg.XLEN-1:0]            data;
        logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] user;
      } fixup_entry_t;

      fixup_entry_t [G6LCCfg.WtDcacheFixupDepth-1:0] fixup_q, fixup_d;
      fixup_entry_t                                  fixup_bypass_q, fixup_bypass_d;
      // hyp8: per-slot version counter for the prepare/supersede/retire
      // discipline — a slot's byte-content epoch bumps on every merge or
      // T47 supersede-mask and resets on alloc and retire, so a re-used
      // slot can never alias an in-flight generation (evidence bit; the
      // export order itself stays positional-newest).
      logic [G6LCCfg.WtDcacheFixupDepth-1:0][1:0]    fixup_ver_d, fixup_ver_q;
      fixup_state_t                                  fixup_state_q, fixup_state_d;
      logic [$clog2(G6LCCfg.WtDcacheFixupDepth)-1:0] fixup_head;
      logic [$clog2(G6LCCfg.WtDcacheFixupDepth)-1:0] fixup_tail;
      logic [$clog2(G6LCCfg.WtDcacheFixupDepth):0]   fixup_cnt;
      logic                                          fixup_bypass_valid_q, fixup_bypass_valid_d;
      logic                                          fixup_coalesced, fixup_active_coalesced;
      logic                                          fixup_alloc, fixup_pop, fixup_dead, fixup_active_dead;
      logic                                          fixup_active_valid;
      // T37: which entry the in-flight tag check / retire belongs to. The active
      // entry (active_paddr, fixup_wr_*, fixup_inv_*) follows fixup_bypass_valid_q
      // combinationally, so a push that lands in the bypass slot while the FIFO
      // head is in CHECK/RETIRE moved the pass onto the bypass word with the
      // head's hit vector: RETIRE then took the full-queue fallback and
      // invalidated the HEAD's way at the BYPASS word's index and dropped the
      // bypass word unwritten -- its line stayed valid and stale in L1 (Linux
      // blake2s: `sw` 0x5be0cd19 -> h[7], the `lw` 19 cycles later read the old
      // 0; the inval hit way 6, the line sat in way 3). The pass is restarted
      // from PEND whenever the selection changes under it.
      logic                                          fixup_sel_bypass_q, fixup_sel_bypass_d;

      function automatic fixup_entry_t merge_fixup(
          input fixup_entry_t prior,
          input logic [G6LCCfg.XLEN-1:0] data,
          input logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] user_data,
          input logic [(G6LCCfg.XLEN/8)-1:0] be);
        fixup_entry_t merged;
        merged = prior;
        merged.be = prior.be | be;
        // hyp8 XLEN is 64 and DataUserEn is 0, so user bits stay at prior.
        // Each byte is its own mux in one assignment. The indexed loop
        // rewrote merged and was billed once per byte.
        // pragma translate_off
        assert (G6LCCfg.XLEN == 64 && G6LCCfg.DATA_USER_EN == 0)
          else $error("merge_fixup byte concat is the hyp8 store");
        // pragma translate_on
        merged.data = {be[7] ? data[63:56] : prior.data[63:56],
                       be[6] ? data[55:48] : prior.data[55:48],
                       be[5] ? data[47:40] : prior.data[47:40],
                       be[4] ? data[39:32] : prior.data[39:32],
                       be[3] ? data[31:24] : prior.data[31:24],
                       be[2] ? data[23:16] : prior.data[23:16],
                       be[1] ? data[15:8]  : prior.data[15:8],
                       be[0] ? data[7:0]   : prior.data[7:0]};
        return merged;
      endfunction

      // Cast the configured depth to the count width so all count comparisons are
      // width-clean and Verilator does not emit WIDTHEXPAND warnings.
      localparam int unsigned FixupDepth    = G6LCCfg.WtDcacheFixupDepth;
      localparam [$clog2(FixupDepth):0] FixupDepthCnt = FixupDepth[$clog2(FixupDepth):0];
      localparam int unsigned FixupForwardDepth = FixupDepth + int'(FixupDepth > 0);

      // A144: the queue is read in slot order, not by walking (head + k) %
      // Depth. A slot is occupied when its ring distance from the head is
      // below the count; a word-address match is tested in every slot in
      // parallel; "the first match in FIFO order from the head" is the
      // lowest matching slot at or above the head, else the lowest below
      // it (two log-depth prefix-OR isolates split by a thermometer mask),
      // exactly what the serial `!coalesced && k < cnt` walk selected. The
      // head-relative read muxes and the Depth-deep priority chain were the
      // module's worst register-to-register path (2.83 ns on the board).
      logic [FixupDepth-1:0] fixup_slot_valid, fixup_slot_ge_head;
      always_comb begin
        for (int unsigned k = 0; k < FixupDepth; k++) begin
          automatic int unsigned ring_dist;
          ring_dist = (k >= unsigned'(fixup_head)) ? k - unsigned'(fixup_head)
                                                    : k + FixupDepth - unsigned'(fixup_head);
          fixup_slot_valid[k]   = ring_dist < unsigned'(fixup_cnt);
          fixup_slot_ge_head[k] = k >= unsigned'(fixup_head);
        end
      end
      function automatic logic [FixupDepth-1:0] fixup_lowest_set(input logic [FixupDepth-1:0] x);
        logic [FixupDepth-1:0] below;
        below = x << 1;
        for (int unsigned l = 1; l < FixupDepth; l = l << 1) below = below | (below << l);
        return x & ~below;
      endfunction
      function automatic logic [FixupDepth-1:0] fixup_first_from_head(input logic [FixupDepth-1:0] m);
        logic [FixupDepth-1:0] hi, lo;
        hi = m & fixup_slot_ge_head;
        lo = m & ~fixup_slot_ge_head;
        return (|hi) ? fixup_lowest_set(hi) : fixup_lowest_set(lo);
      endfunction

      // Full when the FIFO is at capacity and there is no bypass slot available.
      assign fixup_full  = (fixup_cnt == FixupDepthCnt) && fixup_bypass_valid_q;
      assign fixup_empty = (fixup_cnt == '0) && !fixup_bypass_valid_q;

      assign fixup_dead        = (fixup_cnt != '0) && (fixup_q[fixup_head].be == '0);
      assign fixup_active_dead = fixup_bypass_valid_q ? (fixup_bypass_q.be == '0) : fixup_dead;
      assign fixup_alloc       = fixup_push && !fixup_coalesced && (fixup_cnt < FixupDepthCnt);
      // The active entry exists only while the bypass slot or the FIFO holds
      // one. Without this guard the state machine tag-checked and "retired" the
      // stale array slot at fixup_head after the queue drained, writing an old
      // copy over newer L1 data and wrapping the count below zero.
      assign fixup_active_valid = fixup_bypass_valid_q || (fixup_cnt != '0);
      // Same condition as the FIXUP_RETIRE write arm, read from
      // registers so the ACK grant does not sit on the controller.
      assign fixup_wr_pend = (fixup_state_q == FIXUP_RETIRE) &&
                             fixup_active_valid && !fixup_active_dead &&
                             (fixup_bypass_valid_q == fixup_sel_bypass_q) &&
                             !fixup_bypass_valid_q;
      assign fixup_pop         = !fixup_bypass_valid_q && (fixup_cnt != '0) && !fixup_active_coalesced &&
                                 ((fixup_state_q == FIXUP_RETIRE && fixup_wr_ack) ||
                                  (fixup_state_q == FIXUP_PEND && fixup_dead));
      always_comb begin
        fixup_match = fixup_bypass_valid_q &&
            fixup_bypass_q.paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] == rtrn_wb.wtag;
        for (int unsigned k = 0; k < FixupDepth; k++) begin
          if (fixup_slot_valid[k] &&
              fixup_q[k].paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] == rtrn_wb.wtag)
            fixup_match = 1'b1;
        end
      end

      // hyp8 r6b: the coalesce CAM reads the snapshot address, not the
      // push strobe. It runs beside ACK legality; only the write enable
      // waits for fixup_push. Same bytes as the old in-if compare.
      logic [G6LCCfg.PLEN-1:0] snap_paddr;
      logic                    snap_bypass_hit;
      logic [FixupDepth-1:0]   snap_push_match, snap_push_first;
      // Same word id the push used to build in fixup_paddr_push.
      // The push is one cycle after the return, so the CAM matches the
      // captured push address, not whatever return is live now.
      assign snap_paddr = leg_push_paddr_q;
      assign snap_bypass_hit = fixup_bypass_valid_q &&
          (fixup_bypass_q.paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] ==
           snap_paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]);
      for (genvar k = 0; k < FixupDepth; k++) begin : gen_snap_cam
        assign snap_push_match[k] = fixup_slot_valid[k] &&
            (fixup_q[k].paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] ==
             snap_paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]);
      end
      assign snap_push_first = fixup_first_from_head(snap_push_match);
      // Coalesce flags are an OR of the CAM, not a carried write inside
      // the depth-8 merge loop. The state machine still sees them in
      // this cycle, so a push that hits the active entry still blocks
      // retire. The ack below reads the register-only request copy, so
      // completion does not loop through the request this block writes.
      assign fixup_coalesced = fixup_push && (snap_bypass_hit || (|snap_push_first));
      assign fixup_active_coalesced = fixup_push &&
          (snap_bypass_hit || (!fixup_bypass_valid_q && snap_push_first[fixup_head]));

      // T47 word match. Merge copies paddr through, and the invalidate
      // clear only writes be, so a slot's word address changes only when
      // this cycle allocates it. The allocated slot and a bypass alloc
      // use the push address; every other slot uses the registered word.
      // That is the post-push compare, and it does not read fixup_d.
      // The mask in p_fixup_ctrl still reads fixup_d.be, so a word
      // allocated this cycle is masked this cycle.
      logic [FixupDepth-1:0] fixup_word_hit;
      logic                  fixup_bypass_alloc, fixup_bypass_word_hit;
      logic                  fixup_push_word_hit;
      assign fixup_push_word_hit =
          fixup_paddr_push[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] ==
          {e_tag, e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
      assign fixup_bypass_alloc = fixup_push && !fixup_coalesced &&
                                  !(fixup_cnt < FixupDepthCnt) && !fixup_bypass_valid_q;
      for (genvar k = 0; k < FixupDepth; k++) begin : gen_fixup_word
        logic slot_is_alloc, hit_old, take_new, take_old;
        assign slot_is_alloc = fixup_alloc && (fixup_tail == k);
        assign hit_old =
            fixup_q[k].paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] ==
            {e_tag, e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
        assign take_new = slot_is_alloc && fixup_push_word_hit;
        assign take_old = !slot_is_alloc && hit_old;
        assign fixup_word_hit[k] = take_new || take_old;
      end
      logic bypass_hit_old, bypass_take_new, bypass_take_old;
      assign bypass_hit_old =
          fixup_bypass_q.paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] ==
          {e_tag, e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
      assign bypass_take_new = fixup_bypass_alloc && fixup_push_word_hit;
      assign bypass_take_old = !fixup_bypass_alloc && fixup_bypass_valid_q && bypass_hit_old;
      assign fixup_bypass_word_hit = bypass_take_new || bypass_take_old;

      // Helper signals derived from the active entry.
      logic [G6LCCfg.PLEN-1:0] active_paddr;
      assign active_paddr = fixup_bypass_valid_q ? fixup_bypass_q.paddr : fixup_q[fixup_head].paddr;

      logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] paddr_tag;
      logic [DCACHE_CL_IDX_WIDTH-1:0]      paddr_cl_idx;
      logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] paddr_offset;

      assign paddr_tag    = active_paddr[G6LCCfg.DCACHE_INDEX_WIDTH+G6LCCfg.DCACHE_TAG_WIDTH-1:G6LCCfg.DCACHE_INDEX_WIDTH];
      assign paddr_cl_idx = active_paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH];
      assign paddr_offset = active_paddr[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0];

      // Refill matching: a cacheline write (refill/inval) is in flight for this
      // entry's index if wr_cl_vld_d/q matches the current paddr's CL index.
      logic refill_hit_d, refill_hit_q;
      assign refill_hit_d = (wr_cl_vld_d && (wr_cl_idx_d == paddr_cl_idx)) ||
                            (wr_cl_vld_q && (wr_cl_idx_q == paddr_cl_idx));

      // Tag-read interface.  The queue reads only when the wbuffer has no tag
      // check of its own in flight and the current entry is not blocked by a
      // refill.  fixup_rd_req_o below is ORed with the wbuffer rd_req_o.
      assign fixup_rd_tag_only = 1'b1;
      assign fixup_rd_tag      = paddr_tag;
      assign fixup_rd_idx      = paddr_cl_idx;
      assign fixup_rd_off      = paddr_offset;
      // One left-folded AND of these terms was the module spine. Each
      // assign is a single gate, so the request is a tree. The request
      // is still the same cycle as rd_ack: FIXUP_PEND becomes FIXUP_CHECK
      // when both are true. The wbuffer check window is +2 cycles under
      // DcacheHitExtra, so the fixup tag check waits until that response
      // is consumed.
      logic fixup_rd_pend, fixup_rd_live, fixup_rd_free, fixup_rd_ok;
      logic fixup_chk_none, fixup_chk_q, fixup_chk_open;
      logic fixup_chk_pipe, fixup_rd_hold, fixup_rd_win;
      assign fixup_rd_pend  = (fixup_state_q == FIXUP_PEND);
      assign fixup_rd_live  = fixup_rd_pend && fixup_active_valid;
      assign fixup_rd_free  = !refill_hit_q && !fixup_active_dead;
      assign fixup_rd_ok    = fixup_rd_live && fixup_rd_free;
      assign fixup_chk_none = !(|tocheck);
      assign fixup_chk_q    = fixup_chk_none && !check_en_q;
      assign fixup_chk_open = fixup_chk_q && !check_en_q1;
      assign fixup_chk_pipe = !(check_en_p2 || check_en_p3);
      assign fixup_rd_hold  = !WBCHK_PIPE || fixup_chk_pipe;
      assign fixup_rd_win   = fixup_chk_open && fixup_rd_hold;
      assign fixup_rd_req   = fixup_rd_ok && fixup_rd_win;

      // Capture tag-check result.  rd_hit_oh_i/rd_vld_bits_i are valid one
      // cycle after rd_ack_i (when fixup_check_en_q is high), and the queue
      // consumes them one cycle later (fixup_check_en_q1).
      // hyp8: under DcacheHitExtra==2 the response is valid at issue+3 —
      // the capture key is the p3 tap and the consume tap lands at issue+4.
      assign fixup_check_en_d = fixup_rd_req && rd_ack_i;
      always_ff @(posedge clk_i or negedge rst_ni) begin : p_fixup_check_ff
        if (!rst_ni) begin
          fixup_check_en_q  <= 1'b0;
          fixup_check_en_p2 <= 1'b0;
          fixup_check_en_p3 <= 1'b0;
          fixup_check_en_q1 <= 1'b0;
          fixup_hit_oh_q    <= '0;
          fixup_vld_bits_q  <= '0;
        end else begin
          fixup_check_en_q  <= fixup_check_en_d;
          fixup_check_en_p2 <= fixup_check_en_q;
          fixup_check_en_p3 <= fixup_check_en_p2;
          fixup_check_en_q1 <= WBCHK_PIPE ? fixup_check_en_p3 : fixup_check_en_q;
          if (WBCHK_PIPE ? fixup_check_en_p3 : fixup_check_en_q) begin
            fixup_hit_oh_q   <= rd_hit_oh_i;
            fixup_vld_bits_q <= rd_vld_bits_i;
          end
        end
      end

      // Invalidation outputs to wt_dcache_mem.
      // T48: inv_req_o is the RETIRE-state condition restated on registers
      // only (no path through inv_ack_i), because wt_dcache_mem now holds its
      // read grants on it: as a copy of the always_comb's fixup_inv_req it
      // would sit on a block-level cycle (p_bank_req -> inv_ack -> FSM ->
      // inv_req -> arbiter -> rd_ack -> p_bank_req) that a simulator may
      // settle in the wrong order. The two agree by construction
      // (fixup_inv_req_matches_port below).
      assign inv_req_o      = (fixup_state_q == FIXUP_RETIRE) && fixup_active_valid && !fixup_active_dead &&
`ifdef G6LC_MUT_FIXUP_SEL_DRIFT
                              fixup_bypass_valid_q;
`else
                              (fixup_bypass_valid_q == fixup_sel_bypass_q) && fixup_bypass_valid_q;
`endif
      assign inv_idx_o      = fixup_inv_idx;
      assign inv_way_oh_o   = fixup_inv_way_oh;
      assign inv_vld_bits_o = fixup_inv_vld_bits;
      //pragma translate_off
      fixup_inv_req_matches_port :
      assert property (@(posedge clk_i) disable iff (!rst_ni) inv_req_o == fixup_inv_req)
      else $error("[wt_dcache_wbuffer] inv_req_o (%b) and the fixup FSM's inv request (%b) disagree", inv_req_o, fixup_inv_req);
      //pragma translate_on

      // SL-W PMU events
      assign pm_void_ack_o    = fixup_pm_void_ack;
      assign pm_fixup_write_o = fixup_pm_write;
      assign pm_fixup_inval_o = fixup_pm_inval;
      assign pm_fixup_full_o  = fixup_pm_full;

      // Write / invalidate interface (used by the priority mux in p_tx_stat).
      assign fixup_wr_idx     = paddr_cl_idx;
      assign fixup_wr_off     = paddr_offset;
      assign fixup_wr_data    = fixup_bypass_valid_q ? fixup_bypass_q.data : fixup_q[fixup_head].data;
      assign fixup_wr_data_be = fixup_bypass_valid_q ? fixup_bypass_q.be   : fixup_q[fixup_head].be;
      assign fixup_wr_user    = (G6LCCfg.DATA_USER_EN != 0) ?
                                (fixup_bypass_valid_q ? fixup_bypass_q.user : fixup_q[fixup_head].user) : '0;
      assign fixup_inv_idx      = paddr_cl_idx;
      assign fixup_inv_vld_bits = fixup_vld_bits_q;
      assign fixup_inv_way_oh   = fixup_hit_oh_q;

      // Fixup write / invalidate completion.  These are driven by the wbuffer
      // write-port priority mux: wr_req_o is only granted to the queue when
      // neither check_wr nor the ACK writeback is using the port.
      assign fixup_wr_ack  = wr_ack_i && fixup_wr_pend && !check_wr && !ack_wr_active;
      assign fixup_inv_ack = inv_ack_i && inv_req_o;

      // Controller: allocate, retire, and arbitrate the shared read/write ports.
      always_comb begin : p_fixup_ctrl
        fixup_d               = fixup_q;
        fixup_ver_d           = fixup_ver_q;
        fixup_bypass_d        = fixup_bypass_q;
        fixup_state_d         = fixup_state_q;
        fixup_bypass_valid_d  = fixup_bypass_valid_q;
        fixup_pm_void_ack     = 1'b0;
        fixup_pm_write        = 1'b0;
        fixup_pm_inval        = 1'b0;
        fixup_pm_full         = 1'b0;
        fixup_wr_req          = 1'b0;
        fixup_wr_oh           = '0;
        fixup_inv_req         = 1'b0;

        // Allocation on push. Coalesce same-word PA first so a later store to
        // the alias does not fill the queue with stale older words (iter-1
        // mini_stq_flush_fwd saw 0x33330000 after 0x33330001).
        if (fixup_push) begin
          fixup_pm_void_ack = 1'b1;
          // Address compares are snap_bypass_hit / snap_push_first,
          // already resolved against rtrn_wb.wtag. fixup_paddr_push is
          // that same wtag with byte zeros, so the match is identical.
          // The coalesce bits are continuous assigns on that CAM.
          if (snap_bypass_hit) begin
            fixup_bypass_d = merge_fixup(fixup_bypass_q, fixup_data_push, fixup_user_push, fixup_be_push);
          end else begin
            for (int unsigned k = 0; k < FixupDepth; k++) begin
              if (snap_push_first[k]) begin
                fixup_d[k] = merge_fixup(fixup_q[k], fixup_data_push, fixup_user_push, fixup_be_push);
                fixup_ver_d[k] = fixup_ver_q[k] + 2'd1;  // hyp8: supersede epoch
              end
            end
          end
          if (!fixup_coalesced) begin
            if (fixup_cnt < FixupDepthCnt) begin
              fixup_d[fixup_tail] = '{paddr: fixup_paddr_push,
                                       be:    fixup_be_push,
                                       data:  fixup_data_push,
                                       user:  fixup_user_push};
              fixup_ver_d[fixup_tail] = '0;  // hyp8: prepare — fresh epoch
            end else if (!fixup_bypass_valid_q) begin
              fixup_bypass_valid_d = 1'b1;
              fixup_bypass_d       = '{paddr: fixup_paddr_push,
                                       be:    fixup_be_push,
                                       data:  fixup_data_push,
                                       user:  fixup_user_push};
            end else begin
              fixup_pm_full = 1'b1;
            end
          end
        end

        // hyp8: retire — the popped head slot's epoch resets so a re-used
        // slot cannot alias the retired generation.
        if (fixup_pop) fixup_ver_d[fixup_head] = '0;

        if (wr_cl_inv_i) begin
          for (int unsigned k = 0; k < FixupDepth; k++) begin
            if (fixup_q[k].paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] == wr_cl_idx_i)
              fixup_d[k].be = '0;
          end
          if (fixup_bypass_valid_q &&
              fixup_bypass_q.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] == wr_cl_idx_i)
            fixup_bypass_d.be = '0;
        end

        // T47: a younger store accepted into the wbuffer for a word that still
        // has a fixup entry pending supersedes that entry's bytes. The fixup's
        // deferred array write would otherwise land AFTER the younger store's
        // own write and put the older bytes back (the L3 boot's
        // ret_from_exception restore of s7 reading the previous trap frame's
        // value, 36.3 s on every WT model since the fixup queue). The bytes the
        // new store covers are dropped from every entry holding the word; an
        // entry whose bytes are all superseded becomes dead and is skipped.
`ifndef G6LC_MUT_FIXUP_KEEP_SUPERSEDED
        // (compared on the post-push state so a word ACKed and re-written in
        // the same cycle is masked too)
        if (wbuffer_wren) begin
          for (int unsigned k = 0; k < FixupDepth; k++) begin
            if (fixup_word_hit[k]) begin
              fixup_d[k].be = fixup_d[k].be & ~e_be;
              fixup_ver_d[k] = fixup_ver_q[k] + 2'd1;  // hyp8: supersede epoch
            end
          end
          if (fixup_bypass_word_hit)
            fixup_bypass_d.be = fixup_bypass_d.be & ~e_be;
        end
`endif

        // State machine for the active (head or bypass) entry.
        fixup_sel_bypass_d = fixup_sel_bypass_q;
        case (fixup_state_q)
          FIXUP_PEND: begin
            if (fixup_active_dead && fixup_bypass_valid_q && !fixup_active_coalesced) begin
              fixup_bypass_valid_d = 1'b0;
            end
            if (fixup_rd_req && rd_ack_i) begin
              fixup_state_d      = FIXUP_CHECK;
              fixup_sel_bypass_d = fixup_bypass_valid_q;
            end
          end

          FIXUP_CHECK: begin
            if (fixup_active_dead || !fixup_active_valid) begin
              fixup_state_d = FIXUP_PEND;
`ifdef G6LC_MUT_FIXUP_SEL_DRIFT
            end else if (1'b0) begin   // review mutation: the pre-fix shape (pass follows the selection)
`else
            end else if (fixup_bypass_valid_q != fixup_sel_bypass_q) begin
              // T37: the active entry changed under the check -- restart on it
              fixup_state_d = FIXUP_PEND;
`endif
            end else if (fixup_check_en_q1) begin
              if (|fixup_hit_oh_q) begin
                fixup_state_d = FIXUP_RETIRE;
              end else begin
                // Tag miss: line not resident. Keep the entry so loads can
                // still forward until a refill makes the line visible, then
                // retry the tag check. Popping here reopened the wbuffer hole
                // on mini_stq_flush_fwd (checked-miss ACK, L1 empty).
                fixup_state_d = FIXUP_PEND;
              end
            end
          end

          FIXUP_RETIRE: begin
            if (fixup_active_dead || !fixup_active_valid) begin
              // Invalidated (or gone) before retire: drop the entry without
              // touching the write/inv ports or PMU pulses.
              fixup_state_d = FIXUP_PEND;
`ifdef G6LC_MUT_FIXUP_SEL_DRIFT
            end else if (1'b0) begin
`else
            end else if (fixup_bypass_valid_q != fixup_sel_bypass_q) begin
              // T37: the hit vector belongs to the other entry -- restart
              fixup_state_d = FIXUP_PEND;
`endif
            end else if (fixup_bypass_valid_q) begin
              // Full-queue fallback: a tag hit must become an explicit
              // invalidation of the hit way.
              fixup_inv_req  = 1'b1;
              fixup_pm_inval = 1'b1;
              if (fixup_inv_ack && !fixup_active_coalesced) begin
                fixup_bypass_valid_d = 1'b0;
                fixup_state_d        = FIXUP_PEND;
              end
            end else begin
              // Normal hit: write the acknowledged bytes into the hit way.
              fixup_wr_req   = 1'b1;
              fixup_wr_oh    = fixup_hit_oh_q;
              fixup_pm_write = 1'b1;
              if (fixup_wr_ack && !fixup_active_coalesced) begin
                fixup_state_d = FIXUP_PEND;
              end
            end
          end
          default: fixup_state_d = FIXUP_PEND;
        endcase
      end

      // Sequential update of FIFO and state.
      always_ff @(posedge clk_i or negedge rst_ni) begin : p_fixup_ff
        if (!rst_ni) begin
          fixup_q               <= '{default: '0};
          fixup_bypass_q        <= '{default: '0};
          fixup_state_q         <= FIXUP_PEND;
          fixup_head            <= '0;
          fixup_tail            <= '0;
          fixup_cnt             <= '0;
          fixup_ver_q           <= '0;
          fixup_bypass_valid_q  <= 1'b0;
          fixup_sel_bypass_q    <= 1'b0;
          refill_hit_q          <= 1'b0;
        end else begin
          fixup_q               <= fixup_d;
          fixup_ver_q           <= fixup_ver_d;
          fixup_bypass_q        <= fixup_bypass_d;
          fixup_state_q         <= fixup_state_d;
          fixup_bypass_valid_q  <= fixup_bypass_valid_d;
          fixup_sel_bypass_q    <= fixup_sel_bypass_d;
          refill_hit_q          <= refill_hit_d;

          // Head/tail and count management.  A push into the FIFO increments
          // the tail; a retire-ack or a dead head pops it.  The count takes the
          // net delta so a same-cycle push and pop cannot clobber each other.
          if (fixup_alloc) fixup_tail <= fixup_tail + 1'b1;
          if (fixup_pop)  fixup_head <= fixup_head + 1'b1;
          fixup_cnt <= fixup_cnt + ($bits(fixup_cnt))'(fixup_alloc) - ($bits(fixup_cnt))'(fixup_pop);
        end
      end

      //pragma translate_off
      // T37 invariant: a fixup write or invalidation acts on the entry whose tag
      // check produced fixup_hit_oh_q. Fires on the pre-fix shape
      // (G6LC_MUT_FIXUP_SEL_DRIFT) the moment a bypass push lands under a pass.
      fixup_pass_entry_stable :
      assert property (@(posedge clk_i) disable iff (!rst_ni)
          (fixup_wr_req || fixup_inv_req) |-> (fixup_bypass_valid_q == fixup_sel_bypass_q))
      else $error("[l1 dcache wbuffer] fixup pass acting on an entry other than the one it tag-checked (bypass=%b sel=%b idx=%h way=%h)",
                  fixup_bypass_valid_q, fixup_sel_bypass_q, paddr_cl_idx, fixup_hit_oh_q);

      // T47 invariant: a fixup array write never carries a byte that a younger
      // wbuffer entry holds for the same word (the deferred write would put the
      // older byte back after the younger store's own write).
      logic fixup_wr_superseded;
      always_comb begin
        fixup_wr_superseded = 1'b0;
        for (int unsigned i = 0; i < G6LCCfg.WtDcacheWbufDepth; i++) begin
          if ((|wbuffer_q[i].valid) &&
              wbuffer_q[i].wtag == active_paddr[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] &&
              (|(wbuffer_q[i].valid & fixup_wr_data_be)))
            fixup_wr_superseded = 1'b1;
        end
      end
      fixup_write_not_superseded :
      assert property (@(posedge clk_i) disable iff (!rst_ni)
          (fixup_wr_req && fixup_wr_ack) |-> !fixup_wr_superseded)
      else $error("[l1 dcache wbuffer] fixup array write of pa %h be %h over bytes a younger wbuffer entry holds",
                  active_paddr, fixup_wr_data_be);
      //pragma translate_on

      // Convert a fixup paddr to the wtag used by the cache readout mux.
      function automatic [G6LCCfg.DCACHE_TAG_WIDTH+(G6LCCfg.DCACHE_INDEX_WIDTH-G6LCCfg.XLEN_ALIGN_BYTES)-1:0] fixup_wtag(input [G6LCCfg.PLEN-1:0] paddr);
        fixup_wtag = {paddr[G6LCCfg.DCACHE_INDEX_WIDTH+G6LCCfg.DCACHE_TAG_WIDTH-1:G6LCCfg.DCACHE_INDEX_WIDTH],
                      paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
      endfunction

      // Forward newest fixup data first (bypass if active, then tail-1, ...).
      // Each slot is its own process so the fill is a parallel cone, not a
      // serial for-loop behind the ACK decision. The same-cycle push overlay
      // is a one-hot of a match (else a free slot). Lowest index wins, which
      // is what the old downward scan left in `slot`.
      wbuffer_t [FixupForwardDepth-1:0] fwd_ent;
      logic [FixupForwardDepth-1:0] exp_hit, exp_free, exp_pick;
      for (genvar i = 0; i < FixupForwardDepth; i++) begin : gen_fwd_ent
        logic take_bypass;
        logic [$clog2(FixupForwardDepth+1)-1:0] ufifo;
        logic [$clog2(FixupDepth > 1 ? FixupDepth : 2)-1:0] usrc;
        assign take_bypass = (i == 0) && fixup_bypass_valid_q;
        assign ufifo = (i == 0) ? '0 : (i - (fixup_bypass_valid_q ? 1 : 0));
        if (FixupDepth > 1) begin : gen_usrc
          // 2*Depth keeps the unsigned sum non-negative for every legal ufifo.
          assign usrc = (unsigned'(fixup_tail) + (2 * FixupDepth) - 1 - unsigned'(ufifo)) %
                        FixupDepth;
        end else begin : gen_usrc0
          assign usrc = '0;
        end
        always_comb begin
          fwd_ent[i] = '0;
          if (take_bypass) begin
            fwd_ent[i].wtag  = fixup_wtag(fixup_bypass_q.paddr);
            fwd_ent[i].data  = fixup_bypass_q.data;
            fwd_ent[i].user  = (G6LCCfg.DATA_USER_EN != 0) ? fixup_bypass_q.user : '0;
            fwd_ent[i].valid = fixup_bypass_q.be;
          end else if (ufifo < unsigned'(fixup_cnt)) begin
            fwd_ent[i].wtag  = fixup_wtag(fixup_q[usrc].paddr);
            fwd_ent[i].data  = fixup_q[usrc].data;
            fwd_ent[i].user  = (G6LCCfg.DATA_USER_EN != 0) ? fixup_q[usrc].user : '0;
            fwd_ent[i].valid = fixup_q[usrc].be;
          end
        end
        assign exp_hit[i]  = (|fwd_ent[i].valid) && (fwd_ent[i].wtag == rtrn_wb.wtag);
        assign exp_free[i] = !(|fwd_ent[i].valid);
      end
      // Lowest set bit, same overwrite order as the old downward scan.
      function automatic logic [FixupForwardDepth-1:0] fwd_lowest(
          input logic [FixupForwardDepth-1:0] x);
        logic [FixupForwardDepth-1:0] below;
        below = x << 1;
        for (int unsigned l = 1; l < FixupForwardDepth; l = l << 1)
          below = below | (below << l);
        return x & ~below;
      endfunction
      assign exp_pick = (|exp_hit) ? fwd_lowest(exp_hit) : fwd_lowest(exp_free);
      always_comb begin : p_fixup_wbuffer
        fixup_wbuffer_o = fwd_ent;
        // Same-cycle VOID ACK overlay. The match was already resolved
        // against the snapshot tag, so this mux does not re-scan.
        if (fixup_export_push) begin
          for (int unsigned i = 0; i < FixupForwardDepth; i++) begin
            if (exp_pick[i]) begin
              fixup_wbuffer_o[i].wtag   = leg_push_paddr_q[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES];
              fixup_wbuffer_o[i].valid |= fixup_be_push;
              for (int b = 0; b < G6LCCfg.XLEN/8; b++) begin
                if (fixup_be_push[b]) begin
                  fixup_wbuffer_o[i].data[b*8+:8] = fixup_data_push[b*8+:8];
                  if (G6LCCfg.DATA_USER_EN != 0)
                    fixup_wbuffer_o[i].user[b*8+:8] = fixup_user_push[b*8+:8];
                end
              end
            end
          end
        end
      end
    end
  endgenerate

  ///////////////////////////////////////////////////////
  // misc
  ///////////////////////////////////////////////////////
  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] miss_tag;
  logic is_nc_miss;
  logic is_ni;
  assign miss_tag = miss_paddr_o[G6LCCfg.DCACHE_INDEX_WIDTH+:G6LCCfg.DCACHE_TAG_WIDTH];
  assign is_nc_miss = !config_pkg::is_inside_cacheable_regions(
      G6LCCfg,
      {
        {64 - G6LCCfg.DCACHE_TAG_WIDTH - G6LCCfg.DCACHE_INDEX_WIDTH{1'b0}},
        miss_tag,
        {G6LCCfg.DCACHE_INDEX_WIDTH{1'b0}}
      }
  );
  assign miss_nc_o = !cache_en_i || is_nc_miss;
  // Non-idempotent if request goes to NI region
  assign is_ni = config_pkg::is_inside_nonidempotent_regions(
      G6LCCfg,
      {
        {64 - G6LCCfg.DCACHE_TAG_WIDTH - G6LCCfg.DCACHE_INDEX_WIDTH{1'b0}},
        req_port_i.address_tag,
        {G6LCCfg.DCACHE_INDEX_WIDTH{1'b0}}
      }
  );

  assign miss_we_o = 1'b1;
  assign miss_vld_bits_o = '0;
  // hyp8: the low DEPTH entries are the queue; the extra slots are the
  // pending records so the load merge sees the store before its queue
  // write lands (+0 forward visibility, committed data).
  // hyp8 r5: 2-deep pending export across the W3 split -- slot DEPTH is
  // the fresh accept (newest pending, lowest index wins on a tag tie),
  // slot DEPTH+1 is the W3-pending descriptor. A load sees the accepted
  // store through W2 (accept), W3 (descriptor), and the array from the
  // cycle it lands; both pendings can never lose to each other's stale
  // bytes since per-byte overlay is newest-first.
  always_comb begin : p_pend_export
    wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth]   = '0;
    wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1] = '0;
    if (e_accept) begin
      wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth].wtag = {
        e_tag, e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]
      };
      for (int k = 0; k < (G6LCCfg.XLEN / 8); k++) begin
        if (e_be[k]) begin
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth].valid[k]     = 1'b1;
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth].dirty[k]     = 1'b1;
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth].data[k*8+:8] = e_wdata[k*8+:8];
          if (G6LCCfg.DATA_USER_EN != 0)
            wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth].user[k*8+:8] = e_wuser[k*8+:8];
        end
      end
    end
    if (w3_vld_q) begin
      wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].wtag = w3_wtag_q;
      for (int k = 0; k < (G6LCCfg.XLEN / 8); k++) begin
        if (w3_be_q[k]) begin
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].valid[k]     = 1'b1;
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].dirty[k]     = 1'b1;
          wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].data[k*8+:8] = w3_wdata_q[k*8+:8];
          if (G6LCCfg.DATA_USER_EN != 0)
            wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].user[k*8+:8] = w3_wuser_q[k*8+:8];
        end
      end
    end
  end
  assign wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth-1:0] = wbuffer_q;

  for (genvar k = 0; k < G6LCCfg.DCACHE_MAX_TX; k++) begin : gen_tx_vld
    assign tx_vld_o[k] = tx_stat_q[k].vld;
    assign tx_paddr_o[k] = {
      {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_q[tx_stat_q[k].ptr].wtag << G6LCCfg.XLEN_ALIGN_BYTES
    };
  end

  ///////////////////////////////////////////////////////
  // openpiton does not understand byte enable sigs
  // need to convert to the four cases:
  // 00: byte
  // 01: halfword
  // 10: word
  // 11: dword
  // non-contiguous writes need to be serialized!
  // e.g. merged dwords with BE like this: 8'b01001100
  ///////////////////////////////////////////////////////

  // hyp8 wb_drain: two-step oldest-sendable select under WbufPipelined.
  // D1 captures the rr pick (pointer, record, its sendable-byte vector);
  // D2 offers the held selection until miss_ack_i — a younger dirty word
  // arriving while a request waits cannot move that request's payload.
  logic                        dr_vld;
  wbuffer_t                    dr_mux;
  logic [(G6LCCfg.XLEN/8)-1:0] dr_bdirty;
  logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0] dr_ptr;
  generate
    if (HypCfg.WbufPipelined) begin : gen_drain_reg
      logic drain_hold_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin : p_drain
        if (~rst_ni) begin
          drain_hold_q <= 1'b0;
          dr_ptr       <= '0;
          dr_mux       <= '0;
          dr_bdirty    <= '0;
          dr_vld       <= 1'b0;
        end else begin
          drain_hold_q <= miss_req_o && !miss_ack_i;
          if (!drain_hold_q) begin
            dr_ptr    <= dirty_ptr;
            dr_mux    <= wbuffer_dirty_mux;
            dr_bdirty <= bdirty[dirty_ptr];
            dr_vld    <= |dirty;
          end
        end
      end
    end else begin : gen_drain_live
      assign dr_vld    = |dirty;
      assign dr_mux    = wbuffer_dirty_mux;
      assign dr_bdirty = bdirty[dirty_ptr];
      assign dr_ptr    = dirty_ptr;
    end
  endgenerate

  // get byte offset
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.XLEN / 8)
  ) i_vld_bdirty (
      .in_i   (dr_bdirty),
      .cnt_o  (bdirty_off),
      .empty_o()
  );

  // add the offset to the physical base address of this buffer entry
  assign miss_paddr_o = {dr_mux.wtag, bdirty_off};
  assign miss_id_o = tx_id;

  // is there any dirty word to be transmitted, and is there a free TX slot?
  assign miss_req_o = dr_vld && free_tx_slots;

  // get size of aligned words, and the corresponding byte enables
  // note: openpiton can only handle aligned offsets + size, and hence
  // we have to split unaligned data into multiple transfers (see toSize64)
  // e.g. if we have the following valid bytes: 0011_1001 -> TX0: 0000_0001, TX1: 0000_1000, TX2: 0011_0000
  if (G6LCCfg.IS_XLEN64) begin : gen_size_64b
    assign miss_size_o = {1'b0, toSize64(dr_bdirty)};
  end else begin : gen_size_32b
    assign miss_size_o = {1'b0, toSize32(dr_bdirty)};
  end

  // replicate transfers shorter than a dword
  assign miss_wdata_o = G6LCCfg.IS_XLEN64 ? repData64(
      dr_mux.data, bdirty_off, miss_size_o[1:0]
  ) : repData32(
      dr_mux.data, bdirty_off, miss_size_o[1:0]
  );
  if (G6LCCfg.DATA_USER_EN != 0) begin
    assign miss_wuser_o = G6LCCfg.IS_XLEN64 ? repData64(
        dr_mux.user, bdirty_off, miss_size_o[1:0]
    ) : repData32(
        dr_mux.user, bdirty_off, miss_size_o[1:0]
    );
  end else begin
    assign miss_wuser_o = '0;
  end

  assign tx_be = G6LCCfg.IS_XLEN64 ? to_byte_enable8(
      bdirty_off, miss_size_o[1:0]
  ) : to_byte_enable4(
      bdirty_off, miss_size_o[1:0]
  );

  ///////////////////////////////////////////////////////
  // TX status registers and ID counters
  ///////////////////////////////////////////////////////

  // TODO: todo: make this fall through if timing permits it
  g6lc_fifo_v3 #(
      .FALL_THROUGH(1'b0),
      .DATA_WIDTH  ($clog2(G6LCCfg.DCACHE_MAX_TX)),
      .DEPTH       (G6LCCfg.DCACHE_MAX_TX),
      .FPGA_EN     (G6LCCfg.FpgaEn)
  ) i_rtrn_id_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (),
      .empty_o   (rtrn_empty),
      .usage_o   (),
      .data_i    (miss_rtrn_id_i),
      .push_i    (miss_rtrn_vld_i),
      .data_o    (rtrn_id_raw),
      .pop_i     (evict)
  );

  // TX next state only. The tag check and the word-write data mux
  // live in their own blocks so a later assign here is not billed as
  // depending on those reads.
  always_comb begin : p_tx_stat
    tx_stat_d = tx_stat_q;
    // Free the TX on the same edge that pops the return. evict is
    // already the granted decision: a lost L1 write is not in it, and
    // a fixup push pops one cycle after the grant so the queue and
    // the buffer entry move together.
    if (evict && rtrn_tx.vld)
      tx_stat_d[rtrn_id].vld = 1'b0;

    for (int unsigned t = 0; t < G6LCCfg.DCACHE_MAX_TX; t++) begin
      if (tx_stat_q[t].vld && wr_cl_inv_i && (wtag_comp[tx_stat_q[t].ptr] == wr_cl_idx_i))
        tx_stat_d[t].inv = 1'b1;
    end

    if (dirty_rd_en) begin
      tx_stat_d[tx_id].vld = 1'b1;
      tx_stat_d[tx_id].ptr = dr_ptr;
      tx_stat_d[tx_id].be  = tx_be;
      tx_stat_d[tx_id].nc  = miss_nc_o;
      tx_stat_d[tx_id].inv = 1'b0;
    end
  end

  // Who owns the cache word port. Register-only, plus the void-keep
  // check (check_wr) and the fixup retire bit (fixup_wr_pend).
  // Priority, high to low: void-keep, fixup retire, registered ACK write.
  // A stolen port clears ack_wr_active so the return is retried instead
  // of dropping a word the array silently did not take.
  always_comb begin : p_wr_sel
    ack_wr_sel    = leg_go_q && leg_l1_q;
    ack_wr_active = ack_wr_sel && !check_wr && !fixup_wr_pend;
  end
  assign ack_wr_lost = ack_wr_sel && !(ack_wr_active && wr_ack_i);

  // Word-write data. Outputs only; the grant bit above does not read
  // these muxes. Same priority as p_wr_sel.
  always_comb begin : p_wr_data
    wr_req_o     = '0;
    wr_idx_o     = '0;
    wr_off_o     = '0;
    wr_data_o    = '0;
    wr_data_be_o = '0;
    wr_user_o    = '0;

    if (ack_wr_sel) begin
      wr_data_be_o = leg_be_q;
      wr_idx_o     = leg_paddr_q[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH];
      wr_off_o     = leg_paddr_q[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0];
      wr_data_o    = leg_data_q;
      wr_user_o    = leg_user_q;
      wr_req_o     = leg_l1_oh_q;
    end
    if (!check_wr && fixup_wr_pend) begin
      wr_data_be_o = fixup_wr_data_be;
      wr_idx_o     = fixup_wr_idx;
      wr_off_o     = fixup_wr_off;
      wr_data_o    = fixup_wr_data;
      wr_user_o    = fixup_wr_user;
      wr_req_o     = fixup_wr_oh;
    end
    if (check_wr) begin
      wr_data_be_o = wbuffer_q[check_ptr_q1].valid;
      wr_idx_o     = wr_paddr_check[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH];
      wr_off_o     = wr_paddr_check[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0];
      wr_data_o    = wbuffer_q[check_ptr_q1].data;
      wr_user_o    = wbuffer_q[check_ptr_q1].user;
      wr_req_o     = rd_hit_oh_q;
    end
  end

  // L1-only (or plain drop) pop, captured here so the tag-check
  // cone ends at this flop. The buffer clear and the TX free read
  // drop_q the next cycle. A lost grant stores 0 and retries.
  logic drop_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_drop
    if (!rst_ni) drop_q <= 1'b0;
    else         drop_q <= leg_go_q && !leg_fire_q && !ack_wr_lost;
  end

  // Fixup push and L1-only drop both pop one cycle after the grant.
  // The entry stays in the buffer until that edge, so a load still
  // forwards it while the fixup queue accepts the copy.
  always_comb begin : p_leg_evict
    evict      = leg_push_q || drop_q;
    evict_base = leg_push_q || drop_q;
  end

  // Hold and the two return decisions. Each block ends at the
  // legality register. The queue and the TX restore read the
  // registered bits, not these cones.
  // Mid-state `checked` is what the reference read through wbuffer_d
  // (post tag-return, post-inval, pre-evict).
  always_comb begin : p_leg_hold
    rtrn_checked_mid = !inval_hit[rtrn_ptr] &&
        (chk_hit[rtrn_ptr]
            ? (!void_keep_q[rtrn_ptr] &&
               (|rtrn_wb.valid || rtrn_wb.checked))
            : rtrn_wb.checked);
    // Hold only an unchecked candidate while the fixup queue is full.
    // A checked tag-miss is not held: that deadlock keeps the buffer
    // non-empty while the refill loads wait on empty.
    fixup_hold = (G6LCCfg.WtDcacheFixupDepth > 0) &&
                 !rtrn_tx.nc && !rtrn_inv && rtrn_tx.vld &&
                 rtrn_snap_v_q &&
                 !rtrn_wb.checked &&
                 !chk_hit[rtrn_ptr] &&
                 !(VoidKeepEn && !rtrn_checked_mid &&
                   (wr_paddr[31:12] == VoidKeepTag)) &&
                 fixup_full && !fixup_match;
  end

  // Same predicate the reference evaluated inside `if (evict_base)`.
  always_comb begin : p_leg_fire
    leg_fire_d  = rtrn_snap_v_q && !fixup_hold &&
                  (G6LCCfg.WtDcacheFixupDepth > 0) &&
                  !rtrn_tx.nc && !rtrn_inv && rtrn_tx.vld && (|ack_be) &&
                  (fixup_match ||
                   (!(rtrn_wb.checked && (|rtrn_wb.hit_oh)) &&
                    !chk_hit[rtrn_ptr] &&
                    !(VoidKeepEn && !rtrn_checked_mid &&
                      (wr_paddr[31:12] == VoidKeepTag)))) &&
                  (!fixup_full || fixup_match);
    leg_paddr_d = {rtrn_wb.wtag, {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}};
    leg_be_d    = ack_be;
    leg_data_d  = rtrn_wb.data;
    leg_user_d  = rtrn_wb.user;
  end

  // Registered L1 write: checked hit, or the tag hit completing on
  // this return. !check_wr matches the reference (void-keep owns the
  // port and the ACK write is not started). The hit way is the first
  // arm's hit_oh, else the tag-return way.
  always_comb begin : p_leg_l1
    leg_l1_d = rtrn_snap_v_q && !fixup_hold && rtrn_tx.vld && !rtrn_inv &&
               !check_wr && (|ack_be) &&
               ((rtrn_wb.checked && (|rtrn_wb.hit_oh)) ||
                (chk_hit[rtrn_ptr] && (|rd_hit_oh_q)));
    leg_l1_oh_d = (rtrn_wb.checked && (|rtrn_wb.hit_oh)) ? rtrn_wb.hit_oh
                                                        : rd_hit_oh_q;
  end

  // Return legality is its own module so the hold cone ends at go_q
  // and the TX pop / fixup push start from that register.
  wt_dcache_wbuffer_leg #(
      .G6LCCfg (G6LCCfg)
  ) i_wbuffer_leg (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .snap_v_i     (rtrn_snap_v_q),
      .fixup_hold_i (fixup_hold),
      .ack_wr_lost_i(ack_wr_lost),
      .fire_i       (leg_fire_d),
      .l1_i         (leg_l1_d),
      .l1_oh_i      (leg_l1_oh_d),
      .paddr_i      (leg_paddr_d),
      .be_i         (leg_be_d),
      .data_i       (leg_data_d),
      .user_i       (leg_user_d),
      .go_q         (leg_go_q),
      .fire_q       (leg_fire_q),
      .l1_q         (leg_l1_q),
      .l1_oh_q      (leg_l1_oh_q),
      .paddr_q      (leg_paddr_q),
      .be_q         (leg_be_q),
      .data_q       (leg_data_q),
      .user_q       (leg_user_q),
      .push_q       (leg_push_q),
      .push_paddr_q (leg_push_paddr_q),
      .push_be_q    (leg_push_be_q),
      .push_data_q  (leg_push_data_q),
      .push_user_q  (leg_push_user_q)
  );

  assign free_tx_slots = |(~tx_vld_o);

  // next word to lookup in the cache
  g6lc_hyp_rr_arb_tree #(
      .NumIn    (G6LCCfg.DCACHE_MAX_TX),
      .LockIn   (1'b1),
      .DataWidth(1)
  ) i_tx_id_rr (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (~tx_vld_o),
      .gnt_o  (),
      .data_i ('0),
      .gnt_i  (dirty_rd_en),
      .req_o  (),
      .data_o (),
      .idx_o  (tx_id)
  );

  ///////////////////////////////////////////////////////
  // cache readout & update
  ///////////////////////////////////////////////////////

  assign extract_tag = rd_paddr >> G6LCCfg.DCACHE_INDEX_WIDTH;
  assign rd_tag_d = extract_tag[G6LCCfg.DCACHE_TAG_WIDTH-1:0];

  // trigger TAG readout in cache
  // The read port is shared between the wbuffer tag-check pipeline and the
  // SL-W fixup queue.  The wbuffer has priority; the queue only reads when no
  // wbuffer word is pending.
  assign rd_paddr = {
    {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_check_mux.wtag << G6LCCfg.XLEN_ALIGN_BYTES
  };
  assign rd_req_o     = (|tocheck) || fixup_rd_req;
  assign rd_tag_only_o = 1'b1;
  assign rd_tag_o     = check_en_q ? rd_tag_q : fixup_rd_tag;
  assign rd_idx_o     = (|tocheck) ? rd_paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] : fixup_rd_idx;
  assign rd_off_o     = (|tocheck) ? rd_paddr[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] : fixup_rd_off;
  assign check_en_d   = (|tocheck) & rd_ack_i;
  assign check_wtag_d = wbuffer_check_mux.wtag;

  // cache update port
  // hyp8 r6: rtrn_ptr/tx/wb are the registered snapshot. The live FIFO
  // head is rtrn_id_raw and is captured only while the snapshot is free.
  // svt-stage: begin W2S
  assign rtrn_ptr = rtrn_snap_ptr_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin : rtrn_snap
    if (!rst_ni) begin
      rtrn_snap_v_q   <= 1'b0;
      rtrn_snap_id_q  <= '0;
      rtrn_snap_ptr_q <= '0;
      rtrn_snap_tx_q  <= '0;
      rtrn_snap_wb_q  <= '0;
    end else if (evict) begin
      rtrn_snap_v_q <= 1'b0;
    end else if (!rtrn_snap_v_q && !rtrn_empty) begin
      rtrn_snap_v_q   <= 1'b1;
      rtrn_snap_id_q  <= rtrn_id_raw;
      rtrn_snap_tx_q  <= tx_stat_q[rtrn_id_raw];
      rtrn_snap_ptr_q <= tx_stat_q[rtrn_id_raw].ptr;
      rtrn_snap_wb_q  <= wbuffer_q[tx_stat_q[rtrn_id_raw].ptr];
    end
  end
  // svt-stage: end W2S
  // if we wrote into a word while it was in-flight, we cannot write the dirty bytes to the cache
  // when the TX returns
  assign ack_be = rtrn_tx.be & (~rtrn_wb.dirty);
  assign wr_paddr = {
    {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, rtrn_wb.wtag << G6LCCfg.XLEN_ALIGN_BYTES
  };
  assign wr_paddr_check = {
    {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_q[check_ptr_q1].wtag << G6LCCfg.XLEN_ALIGN_BYTES
  };
  // Byte valids are constant-indexed per slot. The variable index
  // into the write port is then one bit, not the byte mask.
  logic [G6LCCfg.WtDcacheWbufDepth-1:0] slot_alive;
  for (genvar sa = 0; sa < G6LCCfg.WtDcacheWbufDepth; sa++) begin : gen_slot_alive
    assign slot_alive[sa] = (|wbuffer_q[sa].valid) && void_keep_q[sa];
  end
  // chk_hit is already one-hot on check_ptr. OR the matching live slot
  // instead of indexing the vectors. The way hit is the low 8 ways.
  assign check_wr = (|(chk_hit & slot_alive)) && (|rd_hit_oh_q[7:0]);
  // Cache word write port is driven by the priority mux in p_tx_stat.


  ///////////////////////////////////////////////////////
  // readout of status bits, index calculation
  ///////////////////////////////////////////////////////

  assign wr_cl_vld_d = wr_cl_vld_i;
  assign wr_cl_idx_d = wr_cl_idx_i;

  for (genvar k = 0; k < G6LCCfg.WtDcacheWbufDepth; k++) begin : gen_flags
    // only for debug, will be pruned
    if (G6LCCfg.DebugEn) begin
      assign debug_paddr[k] = {
        {G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_q[k].wtag << G6LCCfg.XLEN_ALIGN_BYTES
      };
    end

    // dirty bytes that are ready for transmission.
    // note that we cannot retransmit a word that is already in-flight
    // since the multiple transactions might overtake each other in the memory system!
    assign bdirty[k] = (|wbuffer_q[k].txblock) ? '0 : wbuffer_q[k].dirty & wbuffer_q[k].valid;


    assign dirty[k] = |bdirty[k];
    assign valid[k] = |wbuffer_q[k].valid;
    assign wbuffer_hit_oh[k] = valid[k] & (wbuffer_q[k].wtag == {req_port_i.address_tag, req_port_i.address_index[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]});

    // checks if an invalidation/cache refill hits a particular word
    // note: an invalidation can hit multiple words!
    // need to respect previous cycle, too, since we add a cycle of latency to the rd_hit_oh_i signal...
    assign wtag_comp[k] = wbuffer_q[k].wtag[G6LCCfg.DCACHE_INDEX_WIDTH-G6LCCfg.XLEN_ALIGN_BYTES-1:G6LCCfg.DCACHE_OFFSET_WIDTH-G6LCCfg.XLEN_ALIGN_BYTES];
    assign inval_hit[k]  = (wr_cl_vld_d & valid[k] & (wtag_comp[k] == wr_cl_idx_d)) |
                           (wr_cl_vld_q & valid[k] & (wtag_comp[k] == wr_cl_idx_q));

    // these word have to be looked up in the cache
    assign tocheck[k] = (~wbuffer_q[k].checked) & valid[k];
  end

  assign rtrn_inv = rtrn_tx.inv ||
                    (wr_cl_inv_i && (wtag_comp[rtrn_ptr] == wr_cl_idx_i));

  // svt-stage: begin W3
  // hyp8 r5: W3 merge/write stage (HypCfg.WbufPipelined only). W2 keeps
  // the decision -- hit/coalesce select, alloc pointer, NI-conflict
  // verdict and data_gnt timing are unchanged; the accepted write is
  // registered here as a descriptor and W3 performs the byte
  // merge/coalesce and the array write. +1 cycle from store acceptance to
  // array visibility (rank 4, value class; recorded). Forward visibility
  // stays +0 through the 2-deep pending export below. The pending slot
  // counts against next_ptr/full (w3_pend_oh) and answers tag compares
  // (w3_tag_match) so a back-to-back same-tag store coalesces into the
  // pending write instead of aliasing the still-free array slot.
  logic                                          w3_tag_match;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_w3
    if (!rst_ni) begin
      w3_vld_q   <= 1'b0;
      w3_is_ni_q <= 1'b0;
      w3_ptr_q   <= '0;
      w3_wtag_q  <= '0;
      w3_be_q    <= '0;
      w3_wdata_q <= '0;
      w3_wuser_q <= '0;
    end else if (HypCfg.WbufPipelined) begin
      w3_vld_q   <= e_accept;
      w3_ptr_q   <= wr_ptr;
      w3_wtag_q  <= {e_tag,
                     e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
      w3_be_q    <= e_be;
      w3_wdata_q <= e_wdata;
      w3_wuser_q <= e_wuser;
      w3_is_ni_q <= e_is_ni;
    end
  end
  assign w3_pend_oh   = w3_vld_q
      ? (G6LCCfg.WtDcacheWbufDepth'(1) << w3_ptr_q) : '0;
  assign w3_tag_match = w3_vld_q &&
      (w3_wtag_q == {req_port_i.address_tag,
        req_port_i.address_index[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]});

  // Effective write side of the per-entry patch chain: the W3 descriptor
  // under WbufPipelined, the live request otherwise.
  logic [(G6LCCfg.XLEN/8)-1:0]                   wrv_be;
  logic [G6LCCfg.XLEN-1:0]                       wrv_data;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]          wrv_user;
  logic [G6LCCfg.DCACHE_TAG_WIDTH+G6LCCfg.DCACHE_INDEX_WIDTH-
         G6LCCfg.XLEN_ALIGN_BYTES-1:0]           wrv_wtag;
  logic                                          wrv_isni;
  assign wrv_be    = HypCfg.WbufPipelined ? w3_be_q    : e_be;
  assign wrv_data  = HypCfg.WbufPipelined ? w3_wdata_q : e_wdata;
  assign wrv_user  = HypCfg.WbufPipelined ? w3_wuser_q : e_wuser;
  assign wrv_wtag  = HypCfg.WbufPipelined
      ? w3_wtag_q
      : {e_tag,
         e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]};
  assign wrv_isni  = HypCfg.WbufPipelined ? w3_is_ni_q : e_is_ni;
  // svt-stage: end W3

  // svt-stage: begin W1
  // hyp8: W1/W2 request pipeline (HypCfg.WbufPipelined). During W1 the
  // physical-address compares (wbuffer_hit_oh), the lowest-free select and
  // the NI region check are computed on the live request and registered;
  // W2 performs the alloc/coalesce write and the T47 supersede mask from
  // the captured request, and data_gnt is the registered W2 verdict
  // (+2 on store grant, rank 2 — the producer holds data_req until gnt).
  // hyp8 r5: W2 is decision-only now -- the accepted write is registered
  // as the W3 descriptor above and applied one cycle later.
  // The e_* signals are the effective request view each stage consumes.

  generate
    if (HypCfg.WbufPipelined) begin : gen_w1w2
      logic                          w1_vld_q, w1_is_ni_q, w1_accepted_q;
      logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0]   w1_tag_q;
      logic [G6LCCfg.DCACHE_INDEX_WIDTH-1:0] w1_idx_q;
      logic [G6LCCfg.XLEN-1:0]               w1_wdata_q;
      logic [(G6LCCfg.XLEN/8)-1:0]           w1_be_q;
      logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]  w1_wuser_q;
      logic [G6LCCfg.WtDcacheWbufDepth-1:0]  w1_hit_oh_q;
      logic [$clog2(G6LCCfg.WtDcacheWbufDepth)-1:0] w1_hit_ptr_q, w1_next_ptr_q;
      logic                          w1_full_q;
      logic                          w1_w3hit_q;
      logic                          gnt_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin : p_w1
        if (~rst_ni) begin
          w1_vld_q      <= 1'b0;
          w1_is_ni_q    <= 1'b0;
          w1_accepted_q <= 1'b0;
          w1_tag_q      <= '0;
          w1_idx_q      <= '0;
          w1_wdata_q    <= '0;
          w1_be_q       <= '0;
          w1_wuser_q    <= '0;
          w1_hit_oh_q   <= '0;
          w1_hit_ptr_q  <= '0;
          w1_next_ptr_q <= '0;
          w1_full_q     <= 1'b0;
          w1_w3hit_q    <= 1'b0;
          gnt_q         <= 1'b0;
        end else begin
          w1_vld_q      <= req_port_i.data_req;
          w1_is_ni_q    <= is_ni;
          w1_tag_q      <= req_port_i.address_tag;
          w1_idx_q      <= req_port_i.address_index;
          w1_wdata_q    <= req_port_i.data_wdata;
          w1_be_q       <= req_port_i.data_be;
          w1_wuser_q    <= req_port_i.data_wuser;
          w1_hit_oh_q   <= wbuffer_hit_oh;
          w1_hit_ptr_q  <= hit_ptr;
          w1_next_ptr_q <= next_ptr;
          w1_full_q     <= full;
          w1_w3hit_q    <= w3_tag_match;
          // write-once per held data_req: after the W2 verdict the
          // producer keeps asserting until it sees data_gnt, so the
          // re-captured request must not write a second time.
          w1_accepted_q <= req_port_i.data_req && (w1_accepted_q || e_accept);
          gnt_q         <= e_accept;
        end
      end

      assign e_req    = w1_vld_q && !w1_accepted_q;
      assign e_tag    = w1_tag_q;
      assign e_idx    = w1_idx_q;
      assign e_wdata  = w1_wdata_q;
      assign e_be     = w1_be_q;
      assign e_wuser  = w1_wuser_q;
      assign e_is_ni  = w1_is_ni_q;
      // hyp8 r5: a live W3 pending write answers the coalesce select
      // (same-tag store merges into the pending slot) and holds its array
      // slot out of the lowest-free pool via w3_pend_oh.
      assign wr_ptr   = (|w1_hit_oh_q) ? w1_hit_ptr_q
                                       : (w1_w3hit_q ? w3_ptr_q
                                                     : w1_next_ptr_q);
      assign rdy      = (|w1_hit_oh_q) | w1_w3hit_q | (~w1_full_q);
      assign e_accept = e_req && rdy && !ni_conflict;
      assign e_hit_any = (|w1_hit_oh_q) | w1_w3hit_q;
      assign req_port_o.data_gnt = gnt_q;
    end else begin : gen_w_live
      assign e_req    = req_port_i.data_req;
      assign e_tag    = req_port_i.address_tag;
      assign e_idx    = req_port_i.address_index;
      assign e_wdata  = req_port_i.data_wdata;
      assign e_be     = req_port_i.data_be;
      assign e_wuser  = req_port_i.data_wuser;
      assign e_is_ni  = is_ni;
      assign wr_ptr   = (|wbuffer_hit_oh) ? hit_ptr : next_ptr;
      assign rdy      = (|wbuffer_hit_oh) | (~full);
      assign e_accept = e_req && rdy && !ni_conflict;
      assign e_hit_any = |wbuffer_hit_oh;
      assign req_port_o.data_gnt = e_accept;
    end
  endgenerate

  // next free entry in the buffer -- hyp8 r5: a W3-pending write owns
  // its slot already, so it counts as occupied for the lowest-free pick.
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.WtDcacheWbufDepth)
  ) i_vld_lzc (
      .in_i   (~(valid | w3_pend_oh)),
      .cnt_o  (next_ptr),
      .empty_o(full)
  );

  // get index of hit
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.WtDcacheWbufDepth)
  ) i_hit_lzc (
      .in_i   (wbuffer_hit_oh),
      .cnt_o  (hit_ptr),
      .empty_o()
  );

  // next dirty word to serve
  g6lc_hyp_rr_arb_tree #(
      .NumIn   (G6LCCfg.WtDcacheWbufDepth),
      .LockIn  (1'b1),
      .DataType(wbuffer_t)
  ) i_dirty_rr (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (dirty),
      .gnt_o  (),
      .data_i (wbuffer_q),
      .gnt_i  (dirty_rd_en),
      .req_o  (),
      .data_o (wbuffer_dirty_mux),
      .idx_o  (dirty_ptr)
  );

  // next word to lookup in the cache
  g6lc_hyp_rr_arb_tree #(
      .NumIn   (G6LCCfg.WtDcacheWbufDepth),
      .DataType(wbuffer_t)
  ) i_clean_rr (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (tocheck),
      .gnt_o  (),
      .data_i (wbuffer_q),
      .gnt_i  (check_en_d),
      .req_o  (),
      .data_o (wbuffer_check_mux),
      .idx_o  (check_ptr_d)
  );

  ///////////////////////////////////////////////////////
  // update logic
  ///////////////////////////////////////////////////////

  assign req_port_o.data_rvalid = '0;
  assign req_port_o.data_rdata  = '0;
  assign req_port_o.data_ruser  = '0;
  assign req_port_o.data_rid    = '0;

  assign rd_hit_oh_d = rd_hit_oh_i;

  assign ni_inside = |ni_pending_q;
  // svt-stage: end W1
  // svt-stage: begin W2
  // hyp8: the conflict verdict applies to the effective (W2) request —
  // under WbufPipelined e_is_ni is the captured NI check of the request
  // being allocated this cycle.
  assign ni_conflict = G6LCCfg.NonIdemPotenceEn && e_is_ni && ni_inside;
  assign not_ni_o = !ni_inside;
  // hyp8 r5: a W3-pending store is not in the array yet but it is in the
  // buffer -- keep it in the empty verdict so drain-complete checks see it.
  assign empty_o    = !(|valid) && !w3_vld_q;

  // TODO: rewrite and separate into MUXES and write strobe logic
  // hyp8: the composed next-state writer is split per slot so each LHS
  // group bills as an independent cone. Scalar/queue outputs live in
  // p_buffer_sc; each wbuffer slot gets its own always_comb applying the
  // same ordered stages as the emit (tag return -> invalidate -> evict ->
  // drain-tx -> new word) on a local next record.
  always_comb begin : p_buffer_sc
    dirty_rd_en       = miss_req_o && miss_ack_i;
    wbuffer_wren      = e_accept;
    fixup_push        = 1'b0;
    fixup_export_push = 1'b0;
    fixup_evict       = 1'b0;
    fixup_paddr_push  = '0;
    fixup_be_push     = '0;
    fixup_data_push   = '0;
    fixup_user_push   = '0;
    // Granted push only. leg_push_q is a register; the tag check
    // ended at the legality flops the cycle before.
    if (leg_push_q) begin
      fixup_evict       = 1'b1;
      fixup_export_push = 1'b1;
      fixup_push        = 1'b1;
      fixup_paddr_push  = leg_push_paddr_q;
      fixup_be_push     = leg_push_be_q;
      fixup_data_push   = leg_push_data_q;
      fixup_user_push   = leg_push_user_q;
    end
  end

  localparam int unsigned WBW = $clog2(G6LCCfg.WtDcacheWbufDepth);

  // hyp8: every wbuffer_d field is a single priority-chain expression over
  // the ordered events (tag return -> invalidate -> evict -> drain-tx ->
  // new word), so the structural model bills each field as an independent
  // LHS instead of serializing the ~16 per-entry patches. Priority order
  // below reproduces the original sequential patch order exactly.
  for (genvar gi = 0; gi < G6LCCfg.WtDcacheWbufDepth; gi++) begin : gen_wbuf_n
    logic                            chk_gi, vkc_gi, inv_gi, ev_gi, drn_gi,
                                     wr_gi, vkhold_gi, checked_mid,
                                     checked_clr, checked_set,
                                     ev_vk_any, valid_all_gone, tag_eq;
    logic [(G6LCCfg.XLEN/8)-1:0]     evbe, valid_mid, vmid_clr;
    // Tag hit of this slot. Same as the old indexed compare AND the
    // pointer match: only check_ptr_q1 can be hot.
    assign tag_eq = wbuffer_q[gi].wtag == check_wtag_q1;
    assign chk_hit[gi] = check_en_q1 && tag_eq && (check_ptr_q1 == WBW'(gi));
    assign chk_gi = chk_hit[gi];
    assign vkc_gi = chk_gi && void_keep_q[gi];
    assign inv_gi = inval_hit[gi];
    assign ev_gi  = evict && (rtrn_ptr == WBW'(gi));
    assign drn_gi = miss_req_o && miss_ack_i && (dr_ptr == WBW'(gi));
    // hyp8 r5: the store-write term is the W3 apply under WbufPipelined
    // (registered descriptor), the live W2 accept otherwise.
    assign wr_gi  = HypCfg.WbufPipelined ? (w3_vld_q && (w3_ptr_q == WBW'(gi)))
                                         : (e_accept && (wr_ptr == WBW'(gi)));
    assign evbe   = rtrn_tx.be;
    // checked after tag-return and invalidate. Clear wins over the
    // tag-hit set, which wins over the registered bit.
    assign checked_clr = vkc_gi | inv_gi;
    assign checked_set = chk_gi & (|wbuffer_q[gi].valid) & ~checked_clr;
    assign checked_mid = checked_set | (~checked_clr & wbuffer_q[gi].checked);
    // Void-keep is off on hyp8 (literal VoidKeepEn). The address compare
    // is not on this cone.
    assign vkhold_gi = 1'b0;
    // Byte-validity after the void-keep clear and the evict byte patches,
    // before drain/wr (the `wb_n.valid == '0` test reads this state).
    // vkhold_gi is the literal 0, and void_keep_d cannot set while that
    // is true, so vkc_gi stays 0. ORing it into the byte clear pulled
    // the tag compare onto this cone. The clear is the evict bytes.
    for (genvar k = 0; k < (G6LCCfg.XLEN / 8); k++) begin : gen_vmid
      assign vmid_clr[k] = ev_gi & evbe[k] & ~wbuffer_q[gi].dirty[k];
      assign valid_mid[k] = ~vmid_clr[k] & wbuffer_q[gi].valid[k];
    end
    assign ev_vk_any      = ev_gi && vkhold_gi &&
                            |(evbe & ~wbuffer_q[gi].dirty);
    assign valid_all_gone = ev_gi && (valid_mid == '0);

    // valid: wr > evict-clear > void-keep clear > hold
    // dirty: wr > drain > hold
    // txblock: drain > evict > void-keep clear > hold
    // data/user: wr only
    for (genvar k = 0; k < (G6LCCfg.XLEN / 8); k++) begin : gen_wbf
      assign wbuffer_d[gi].valid[k] =
          (wr_gi && wrv_be[k]) ? 1'b1 : valid_mid[k];
      assign wbuffer_d[gi].dirty[k] =
          (wr_gi && wrv_be[k]) ? 1'b1
          : (drn_gi && tx_be[k]) ? 1'b0 : wbuffer_q[gi].dirty[k];
      assign wbuffer_d[gi].txblock[k] =
          (drn_gi && tx_be[k]) ? 1'b1
          : (ev_gi && evbe[k]) ? (vkhold_gi && !wbuffer_q[gi].dirty[k])
          : vkc_gi ? 1'b0 : wbuffer_q[gi].txblock[k];
      assign wbuffer_d[gi].data[k*8+:8] =
          (wr_gi && wrv_be[k]) ? wrv_data[k*8+:8]
                               : wbuffer_q[gi].data[k*8+:8];
      assign wbuffer_d[gi].user[k*8+:8] =
          (wr_gi && wrv_be[k] && (G6LCCfg.DATA_USER_EN != 0))
              ? wrv_user[k*8+:8] : wbuffer_q[gi].user[k*8+:8];
    end
    assign wbuffer_d[gi].checked =
        wr_gi ? 1'b0 : valid_all_gone ? 1'b0 : checked_mid;
    assign wbuffer_d[gi].hit_oh =
        (chk_gi && (|wbuffer_q[gi].valid)) ? rd_hit_oh_q
                                           : wbuffer_q[gi].hit_oh;
    assign wbuffer_d[gi].wtag =
        wr_gi ? wrv_wtag : wbuffer_q[gi].wtag;
    // write new word into the buffer — the effective (W3) record under
    // WbufPipelined; the NI conflict was folded into e_accept at W2.
    // vkc_gi is 0 while void-keep cannot set, so it does not clear NI.
    assign ni_pending_d[gi] = wr_gi ? wrv_isni
                                    : (~valid_all_gone & ni_pending_q[gi]);
    assign void_keep_d[gi] = wr_gi ? 1'b0
                          : valid_all_gone ? 1'b0
                          : ev_vk_any ? 1'b1
                          : vkc_gi ? 1'b0 : void_keep_q[gi];
  end


  ///////////////////////////////////////////////////////
  // ff's
  ///////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      wbuffer_q    <= '{default: '0};
      tx_stat_q    <= '{default: '0};
      ni_pending_q <= '0;
      check_ptr_q  <= '0;
      check_ptr_q1 <= '0;
      check_en_q   <= '0;
      check_en_q1  <= '0;
      check_wtag_q <= '0;
      check_wtag_q1 <= '0;
      rd_tag_q     <= '0;
      rd_hit_oh_q  <= '0;
      wr_cl_vld_q  <= '0;
      wr_cl_idx_q  <= '0;
      void_keep_q  <= '0;
    end else begin
      wbuffer_q    <= wbuffer_d;
      tx_stat_q    <= tx_stat_d;
      ni_pending_q <= ni_pending_d;
      void_keep_q  <= void_keep_d;
      check_ptr_q  <= check_ptr_d;
      check_ptr_p2 <= check_ptr_q;
      check_ptr_p3 <= check_ptr_p2;
      check_ptr_q1 <= WBCHK_PIPE ? check_ptr_p3 : check_ptr_q;
      check_en_q   <= check_en_d;
      check_en_p2  <= check_en_q;
      check_en_p3  <= check_en_p2;
      check_en_q1  <= WBCHK_PIPE ? check_en_p3 : check_en_q;
      check_wtag_q <= check_wtag_d;
      check_wtag_p2 <= check_wtag_q;
      check_wtag_p3 <= check_wtag_p2;
      check_wtag_q1 <= WBCHK_PIPE ? check_wtag_p3 : check_wtag_q;
      rd_tag_q     <= rd_tag_d;
      rd_hit_oh_q  <= rd_hit_oh_d;
      wr_cl_vld_q  <= wr_cl_vld_d;
      wr_cl_idx_q  <= wr_cl_idx_d;
    end
  end


  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  bit smt_wt_trace, smt_wt_watch;
  logic [G6LCCfg.PLEN-1:0] smt_wt_address;
  int unsigned smt_wt_cycle = 0;
  initial begin
    smt_wt_watch = $value$plusargs("smt_mem_watch=%h", smt_wt_address);
    smt_wt_trace = $test$plusargs("smt_flow_trace") || smt_wt_watch;
    assert (G6LCCfg.WtDcacheFixupVoidKeepEn == 1'b0)
      else $error("wt_dcache_wbuffer VoidKeepEn is a literal 0");
  end
  always @(posedge clk_i) begin
    if (!rst_ni) smt_wt_cycle = 0;
    else if (smt_wt_trace) begin
      smt_wt_cycle++;
      if (miss_req_o && miss_ack_i && (!smt_wt_watch ||
          (miss_paddr_o >> G6LCCfg.XLEN_ALIGN_BYTES) == (smt_wt_address >> G6LCCfg.XLEN_ALIGN_BYTES)))
        $display("[smt-flow] wt_tx cycle=%0d id=%0d pa=%h data=%h be=%h nc=%b",
                 smt_wt_cycle, miss_id_o, miss_paddr_o, miss_wdata_o, tx_be, miss_nc_o);
      if (evict && rtrn_tx.vld && (!smt_wt_watch ||
          rtrn_wb.wtag == smt_wt_address[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]))
        $display("[smt-flow] wt_ack cycle=%0d id=%0d ptr=%0d wtag=%h data=%h be=%h checked=%b hit=%h ack_active=%b wr_req=%h wr_ack=%b fix_push=%b fix_req=%b check_wr=%b",
                 smt_wt_cycle, rtrn_id, rtrn_ptr, rtrn_wb.wtag,
                 rtrn_wb.data, ack_be, rtrn_wb.checked,
                 rtrn_wb.hit_oh, ack_wr_active, wr_req_o, wr_ack_i,
                 fixup_push, fixup_wr_req, check_wr);
      if (check_en_q1 && (!smt_wt_watch ||
          wbuffer_q[check_ptr_q1].wtag == smt_wt_address[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]))
        $display("[smt-flow] wt_check cycle=%0d ptr=%0d wtag=%h hit=%h valid=%h",
                 smt_wt_cycle, check_ptr_q1, wbuffer_q[check_ptr_q1].wtag,
                 rd_hit_oh_q, wbuffer_q[check_ptr_q1].valid);
      // T37: the word's arrival (allocation or merge into a live entry) and the
      // entry's byte state after it, and the fixup-queue push/retire of its bytes
      if (wbuffer_wren && (!smt_wt_watch ||
          {e_tag, e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]} ==
          smt_wt_address[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]))
        $display("[smt-flow] wt_alloc cycle=%0d ptr=%0d merge=%b be=%h data=%h | before: valid=%h dirty=%h txblock=%h checked=%b hit=%h | full=%b",
                 smt_wt_cycle, wr_ptr, e_hit_any, e_be, e_wdata,
                 wbuffer_q[wr_ptr].valid, wbuffer_q[wr_ptr].dirty, wbuffer_q[wr_ptr].txblock,
                 wbuffer_q[wr_ptr].checked, wbuffer_q[wr_ptr].hit_oh, full);
      if (fixup_push && (!smt_wt_watch ||
          fixup_paddr_push[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES] == smt_wt_address[G6LCCfg.PLEN-1:G6LCCfg.XLEN_ALIGN_BYTES]))
        $display("[smt-flow] wt_fixup_push cycle=%0d pa=%h be=%h data=%h full=%b match=%b",
                 smt_wt_cycle, fixup_paddr_push, fixup_be_push, fixup_data_push, fixup_full, fixup_match);
      if (fixup_wr_req && (!smt_wt_watch ||
          {fixup_wr_idx, fixup_wr_off} == smt_wt_address[G6LCCfg.DCACHE_INDEX_WIDTH-1:0]))
        $display("[smt-flow] wt_fixup_wr cycle=%0d idx=%h off=%h ways=%h be=%h data=%h ack=%b",
                 smt_wt_cycle, fixup_wr_idx, fixup_wr_off, fixup_wr_oh, fixup_wr_data_be, fixup_wr_data, fixup_wr_ack);
    end
  end
`ifndef VERILATOR

  hot1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) req_port_i.data_req |-> $onehot0(
      wbuffer_hit_oh
  ))
  else $fatal(1, "[l1 dcache wbuffer] wbuffer_hit_oh signal must be hot1");

  tx_status :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) evict && miss_ack_i && miss_req_o |-> (tx_id != rtrn_id))
  else $fatal(1, "[l1 dcache wbuffer] cannot allocate and clear same tx slot id in the same cycle");

  // Note: after free-on-ACK, a late/duplicate return may pop with vld already 0.
  // That is non-fatal (we still drain the rtrn FIFO); buffer clear is gated on be/valid.
  tx_valid0 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) evict && rtrn_tx.vld |-> 1'b1)
  else $fatal(1, "[l1 dcache wbuffer] evicting invalid transaction slot");

  tx_valid1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) evict && rtrn_tx.vld |-> |rtrn_wb.valid)
  else $fatal(1, "[l1 dcache wbuffer] wbuffer entry corresponding to this transaction is invalid");

  // hyp8: under WbufPipelined the grant is the registered W2 verdict — the
  // meaningful invariant is that a write fires only on a ready verdict.
  write_full :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) wbuffer_wren |-> rdy)
  else $fatal(1, "[l1 dcache wbuffer] cannot write if full or no hit");

  unused0 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) !req_port_i.tag_valid)
  else $fatal(1, "[l1 dcache wbuffer] req_port_i.tag_valid should not be asserted");

  unused1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) !req_port_i.kill_req)
  else $fatal(1, "[l1 dcache wbuffer] req_port_i.kill_req should not be asserted");

  for (genvar k = 0; k < G6LCCfg.WtDcacheWbufDepth; k++) begin : gen_assert1
    for (genvar j = 0; j < (G6LCCfg.XLEN / 8); j++) begin : gen_assert2
      byteStates :
      assert property (
        @(posedge clk_i) disable iff (!rst_ni) {wbuffer_q[k].valid[j], wbuffer_q[k].dirty[j], wbuffer_q[k].txblock[j]} inside {3'b000, 3'b110, 3'b101, 3'b111} )
      else
        $fatal(
            1,
            "[l1 dcache wbuffer] byte %02d of wbuffer entry %02d has invalid state: valid=%01b, dirty=%01b, txblock=%01b",
            j,
            k,
            wbuffer_q[k].valid[j],
            wbuffer_q[k].dirty[j],
            wbuffer_q[k].txblock[j]
        );
    end
  end

  // hyp8 r5 W3 equivalence (retimed reference): the original single-cycle
  // W2 write patch is evaluated on the W3-aligned inputs -- the
  // descriptor captured at W2 against the buffer state at W3 -- and the
  // applied array fields are checked against it. (a) The descriptor
  // carries the previous cycle's effective request verbatim. (b) The
  // write lands at the next edge with every be-byte valid+dirty and the
  // descriptor's data/tag -- the intentional +1 alignment.
  w3_descr :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (HypCfg.WbufPipelined && w3_vld_q)
      |-> (w3_be_q   == $past(e_be)) &&
          (w3_ptr_q  == $past(wr_ptr)) &&
          (w3_wdata_q == $past(e_wdata)) &&
          (w3_wtag_q == $past({e_tag,
              e_idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]})))
    else $fatal(1, "[l1 dcache wbuffer] W3 descriptor != accepted W2 request");

  for (genvar k = 0; k < (G6LCCfg.XLEN / 8); k++) begin : gen_w3_ref
    w3_landed :
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (HypCfg.WbufPipelined && w3_vld_q && w3_be_q[k])
        |=> wbuffer_q[$past(w3_ptr_q)].valid[k] &&
            wbuffer_q[$past(w3_ptr_q)].dirty[k] &&
            (wbuffer_q[$past(w3_ptr_q)].data[k*8+:8] ==
             $past(w3_wdata_q[k*8+:8])) &&
            (wbuffer_q[$past(w3_ptr_q)].wtag == $past(w3_wtag_q)))
      else $fatal(1, "[l1 dcache wbuffer] W3 write byte %0d did not land", k);
  end

  w3_export :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (HypCfg.WbufPipelined && w3_vld_q)
      |-> ((wbuffer_data_o[G6LCCfg.WtDcacheWbufDepth+1].valid & w3_be_q)
           == w3_be_q))
    else $fatal(1, "[l1 dcache wbuffer] W3 record not forward-exported");
`endif
  //pragma translate_on

  // svt-stage: end W2
  // hyp8 r3: the ACK-return select cone (rtrn id/ptr decode, record
  // reads, evict/invalidate legality) drives W2 combinationally — the
  // flat assigns and p_tx_stat sit outside the regions, so attribute
  // their drivers to W2 for an honest stage view.
  // svt-stage: use W2 on=rtrn_id,rtrn_ptr,rtrn_tx,rtrn_wb,ack_be,wr_paddr,wr_paddr_check,check_wr,rtrn_inv,rtrn_checked_mid,evict,evict_base,fixup_match,fixup_full,fixup_evict,fixup_export_push,fixup_push,fixup_paddr_push,fixup_be_push,fixup_data_push,fixup_user_push
  // svt-stage: class W1 value
  // svt-stage: class W2 value
  // svt-stage: class W2S value
  // svt-stage: class W3 value
endmodule  // wt_dcache_wbuffer
