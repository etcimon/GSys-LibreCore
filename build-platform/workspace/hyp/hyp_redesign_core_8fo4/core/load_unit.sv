// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
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
// Author: Florian Zaruba    <zarubaf@iis.ee.ethz.ch>, ETH Zurich
//         Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 15.08.2018
// Modified by: Etienne Cimon
// Description: Load Unit, takes care of all load requests
//
// Contributor: Cesar Fuguet <cesar.fuguettortolero@cea.fr>, CEA List
// Date: August 29, 2023
// Modification: add support for multiple outstanding load operations
//               to the data cache

module load_unit
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: forward-pipeline depth + hazard-verdict gating live in HypCfg.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type lsu_ctrl_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush signal - CONTROLLER (full flush marks all slots flushed)
    input logic flush_i,
    // FSE S4: younger-only cancel — mark matching TID slots flushed
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Load request is valid - LSU_BYPASS
    input logic valid_i,
    // Load request input - LSU_BYPASS
    input lsu_ctrl_t lsu_ctrl_i,
    // Pop the load request from the LSU bypass FIFO - LSU_BYPASS
    output logic pop_ld_o,
    // Load unit result is valid - ISSUE_STAGE
    output logic valid_o,
    // Load transaction ID - ISSUE_STAGE
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_o,
    // Load result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] result_o,
    // Load exception - ISSUE_STAGE
    output exception_t ex_o,
    // Data Endian mode - CSR_REGFILE
    input logic mbe_i,
    // Request address translation - MMU
    output logic translation_req_o,
    // Virtual address - MMU
    output logic [G6LCCfg.VLEN-1:0] vaddr_o,
    // Transformed trap instruction out - MMU
    output logic [31:0] tinst_o,
    // Instruction is a hyp load store instruction - MMU
    output logic hs_ld_st_inst_o,
    // Hyp load store with execute permissions - MMU
    output logic hlvx_inst_o,
    // Physical address - MMU
    input logic [G6LCCfg.PLEN-1:0] paddr_i,
    // Excepted which appears before load - MMU
    input exception_t ex_i,
    // ex_i came from the shared PTW-error broadcast rather than this load's
    // own registered translation result - MMU
    input logic ex_ptw_i,
    // Data TLB hit - MMU
    input logic dtlb_hit_i,
    // Physical page number from the DTLB - MMU
    input logic [G6LCCfg.PPNW-1:0] dtlb_ppn_i,
    // Page offset for address checking - STORE_UNIT
    output logic [11:0] page_offset_o,
    // R3a: full load paddr when DTLB hit - STORE_UNIT / STQ match
    output logic [G6LCCfg.PLEN-1:0] load_paddr_o,
    output logic                    load_paddr_valid_o,
    // OoO: program-order identity of the querying load. A store may only be
    // observed by a load that follows it in program order; under OoO issue the
    // store buffer can hold younger stores, so an address match is not enough.
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_o,
    // T6b: hart of the querying load — the store buffer's speculative
    // forwarding is same-hart only under OoO multi-hart. Constant-0 else.
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] load_hart_o,
    // Indicates if the page offset matches a store unit entry - STORE_UNIT
    input logic page_offset_matches_i,
    // T33: that match is against the speculative STQ only - STORE_UNIT
    input logic page_offset_spec_only_i,
    // T33: give the parked load back to the scoreboard (cancel + commit-time
    // refetch, the LSQ mem_violation path) so an older load can use the unit
    output logic lu_replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] lu_replay_id_o,
    // Store buffer is empty - STORE_UNIT
    input logic store_buffer_empty_i,
    // Committed store queue is empty (only speculative, hence younger, stores
    // may remain) - STORE_UNIT. Under OoO the non-idempotent gate waits on this
    // rather than on the whole buffer: a younger store that issued early sits in
    // the speculative queue until *its* commit, which cannot precede the older
    // load's, so waiting for it would deadlock.
    input logic no_st_pending_i,
    // R3a: STQ store→load data forward - STORE_UNIT
    input logic                        st_fwd_valid_i,
    input logic [G6LCCfg.XLEN-1:0]     st_fwd_data_i,
    input logic [(G6LCCfg.XLEN/8)-1:0] st_fwd_be_i,
    // Transaction ID of the committing instruction - COMMIT_STAGE
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tran_id_i,
    // Data cache request out - CACHES
    input dcache_req_o_t req_port_i,
    // Data cache request in - CACHES
    output dcache_req_i_t req_port_o,
    // Presence of non-idempotent operations in the D$ write buffer - CACHES
    input logic dcache_wbuffer_not_ni_i,
    // R3a cont.10: D$ write buffer empty (all committed stores visible in D$)
    input logic dcache_wbuffer_empty_i,
    output logic phys_valid_o,
    output logic [G6LCCfg.PLEN-1:0] phys_addr_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] phys_id_o,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] phys_hart_o,
    output logic [1:0] phys_size_o,
    // hyp8 L5: LSQ per-scoreboard-entry checked bits — a load publishes
    // its data result only once its hazard verdict is final (L1).
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] ld_checked_i,
    // hyp8: staged store-buffer forward request (L2). Fired when the
    // load's request is granted and its physical address is known; the
    // buffer answers StoreFwdCycles later with the F3 response below.
    // `tag` is the load-buffer slot the response must re-pair with, so
    // responses rejoin their requester regardless of D$ rid ordering.
    output struct packed {
      logic                                        valid;
      logic [G6LCCfg.PLEN-1:0]                     pa;
      logic [1:0]                                  size;
      logic [G6LCCfg.TRANS_ID_BITS-1:0]            tid;
      logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
      logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
    } fwd_req_o,
    input struct packed {
      logic                                        valid;
      logic [G6LCCfg.XLEN-1:0]                     data;
      logic [(G6LCCfg.XLEN/8)-1:0]                 be;
      logic                                        forward_possible;
      logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
    } fwd_rsp_i,
    // hyp8: IQ re-arm replay — same event as lu_replay_o (T33), exported
    // separately so the scoreboard/commit path and the IQ can consume
    // the pulse without sharing the legacy name.
    output logic                             replay_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] replay_tid_o
);
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin load_unit status=proposal target=10-adjusted-FO4
  // svt-plan: cone translation/hazard/request control is separate from
  // return-data shift/sign selection; choose boundaries for both transactions.
  // svt-plan: boundary request/translation ownership -> permission+hazard
  // verdict -> cache acceptance; optional response snapshot -> align/extend.
  // svt-plan: carry TID+generation, hart, VA/PA, size/op, endian mode,
  // exception context, load-buffer ID and forwarding source with the token.
  // svt-plan: capacity reserve load-buffer/response slots at acceptance;
  // tag_valid/kill_req must refer to the same earlier cache request.
  // svt-plan: visibility NI/MMIO requests wait for commit/permissions;
  // recheck pending older stores before publication, including STQ bypasses.
  // svt-plan: effect separates tag/permission/hazard control from request
  // dispatch and isolates returned-word selection from shift/sign logic.
  // svt-plan: cost extra load latency and held requests/results; neither
  // dtlb_hit nor st_fwd_data can be delayed without its ownership and verdict.
  // svt-plan: limit early index request is already overlapped with translation;
  // added stages must retain that split and COH_OOO physical validation.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 59.3 adjusted FO4 on the
  // Nangate45 board): load unit FSM: the TLB / D$ handshakes are same-cycle.
  // svt-pipe: require-contract
  // svt-pipe: protocol lu valid=valid_i
  // svt-pipe: no-cut on=state_q
  // svt-pipe: cycle lu q=state_q d=state_d hold=valid_i steps=1

  // hyp8: one-hot FSM state (L1 request issue cycle unchanged). Each state is a
  // single bit of state_q; transitions write a one-hot literal LU_S_* into
  // state_d. The original encoded case is kept verbatim under translate_off as
  // load_control_ref with an encoding-equality assertion.
  localparam int LU_B_IDLE                = 0,
                 LU_B_WAIT_GNT            = 1,
                 LU_B_SEND_TAG            = 2,
                 LU_B_WAIT_PAGE_OFFSET    = 3,
                 LU_B_ABORT_TRANSACTION   = 4,
                 LU_B_ABORT_TRANSACTION_NI= 5,
                 LU_B_WAIT_TRANSLATION    = 6,
                 LU_B_WAIT_FLUSH          = 7,
                 LU_B_WAIT_WB_EMPTY       = 8,
                 LU_B_WAIT_SPEC_LOAD      = 9;
  localparam logic [9:0] LU_S_IDLE                     = 10'b1 << LU_B_IDLE;
  localparam logic [9:0] LU_S_WAIT_GNT                 = 10'b1 << LU_B_WAIT_GNT;
  localparam logic [9:0] LU_S_SEND_TAG                 = 10'b1 << LU_B_SEND_TAG;
  localparam logic [9:0] LU_S_WAIT_PAGE_OFFSET         = 10'b1 << LU_B_WAIT_PAGE_OFFSET;
  localparam logic [9:0] LU_S_ABORT_TRANSACTION        = 10'b1 << LU_B_ABORT_TRANSACTION;
  localparam logic [9:0] LU_S_ABORT_TRANSACTION_NI     = 10'b1 << LU_B_ABORT_TRANSACTION_NI;
  localparam logic [9:0] LU_S_WAIT_TRANSLATION         = 10'b1 << LU_B_WAIT_TRANSLATION;
  localparam logic [9:0] LU_S_WAIT_FLUSH               = 10'b1 << LU_B_WAIT_FLUSH;
  localparam logic [9:0] LU_S_WAIT_WB_EMPTY            = 10'b1 << LU_B_WAIT_WB_EMPTY;
  localparam logic [9:0] LU_S_WAIT_SPEC_LOAD           = 10'b1 << LU_B_WAIT_SPEC_LOAD;

  logic [9:0] state_d, state_q;

  // in order to decouple the response interface from the request interface,
  // we need a a buffer which can hold all inflight memory load requests
  typedef struct packed {
    logic [G6LCCfg.TRANS_ID_BITS-1:0]    trans_id;        // scoreboard identifier
    logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] address_offset;  // least significant bits of the address
    fu_op                                operation;       // type of load
  } ldbuf_t;


  // to support a throughput of one load per cycle, if the number of entries
  // of the load buffer is 1, implement a fall-through mode. This however
  // adds a combinational path between the request and response interfaces
  // towards the cache.
  localparam logic LDBUF_FALLTHROUGH = (G6LCCfg.NrLoadBufEntries == 1);
  localparam int unsigned REQ_ID_BITS = G6LCCfg.NrLoadBufEntries > 1 ? $clog2(
      G6LCCfg.NrLoadBufEntries
  ) : 1;

  typedef logic [REQ_ID_BITS-1:0] ldbuf_id_t;

  logic [G6LCCfg.NrLoadBufEntries-1:0] ldbuf_valid_q, ldbuf_valid_d;
  logic [G6LCCfg.NrLoadBufEntries-1:0] ldbuf_flushed_q, ldbuf_flushed_d;
  ldbuf_t [G6LCCfg.NrLoadBufEntries-1:0] ldbuf_q;
  logic ldbuf_empty, ldbuf_full;
  ldbuf_id_t ldbuf_free_index;
  logic      ldbuf_w;
  ldbuf_t    ldbuf_wdata;
  ldbuf_id_t ldbuf_windex;
  logic      ldbuf_r;
  ldbuf_t    ldbuf_rdata;
  ldbuf_id_t ldbuf_rindex;
  ldbuf_id_t ldbuf_last_id_q;

  // svt-stage: begin L3
  // hyp8 L3/L4/L5: response-wait, align and publish staging.
  // data_rvalid is a pulse — the response word is captured into the slot
  // (rpend_q/rdata_q) and the slot is published only when its LSQ verdict
  // is final (ld_checked_i) and its staged store-forward response has
  // returned (fwd_seen_q). A slot freed without publishing is a
  // tombstone (flushed) or a killed request (rkill_q).
  logic [G6LCCfg.NrLoadBufEntries-1:0] rpend_q;
  logic [G6LCCfg.NrLoadBufEntries-1:0] rkill_q;
  logic [G6LCCfg.XLEN-1:0]             rdata_q [G6LCCfg.NrLoadBufEntries];
  logic [G6LCCfg.NrLoadBufEntries-1:0] fwd_reqed_q;
  logic [G6LCCfg.NrLoadBufEntries-1:0] fwd_seen_q;
  logic [G6LCCfg.XLEN-1:0]             fwd_data_q [G6LCCfg.NrLoadBufEntries];
  logic [(G6LCCfg.XLEN/8)-1:0]         fwd_be_q [G6LCCfg.NrLoadBufEntries];
  logic [G6LCCfg.NrLoadBufEntries-1:0] fwd_possible_q;
  ldbuf_id_t rresp_idx;    // slot named by the incoming data_rid
  ldbuf_id_t retire_idx;   // slot publishing this cycle (L5 pick)

  // hyp8 H5: speculative-wakeup miss replay. The IQ releases a load's
  // dependents on a countdown calibrated to the D$ hit latency — the
  // response is expected 2 + HypCfg.DcacheHitExtra cycles after the
  // request grant (ldbuf_w). When that window passes with no response
  // captured for the slot, the release was premature (a miss): pulse
  // replay_o once with the slot's transaction id so the dependents
  // re-arm; the real writeback on data_rvalid wakes them firmly when the
  // miss data lands. Forward-covered loads never reach the D$; flushed,
  // killed and cancelled slots are exempt. The age counter equals the
  // threshold for exactly one cycle, so the pulse is one-shot per slot.
  localparam int unsigned LD_HIT_LAT = 2 + HypCfg.DcacheHitExtra;
  localparam int unsigned LD_AGE_W   = (LD_HIT_LAT + 2 <= 2) ? 1
                                     : $clog2(LD_HIT_LAT + 2);
  logic [G6LCCfg.NrLoadBufEntries-1:0][LD_AGE_W-1:0] miss_age_q;
  logic                                            miss_replay;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]                  miss_replay_id;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_unit  region=3091  makespan=5.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ldbuf_flushed_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ldbuf_flushed_q
// order expect: ldbuf_last_id_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to ldbuf_last_id_q
// order expect: ldbuf_q  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to ldbuf_q
// order expect: ldbuf_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ldbuf_valid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ldbuf_flushed_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ldbuf_last_id_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ldbuf_q <= …; // sv-timing: cycle 1/1 on clk_i
//     ldbuf_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node11501 c=3.50 slack=2.00 */
//     /* node11502 c=3.50 slack=2.00 */
//     /* node11503 c=3.50 slack=2.00 */
//     /* node11504 c=3.50 slack=2.00 */
//     /* node11505 c=3.50 slack=2.00 */
//     /* node11506 c=3.50 slack=2.00 */
//     /* node11507 c=4.50 slack=1.00 */
//     /* node11508 c=5.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_unit  region=3096  makespan=26.400 FO4  cycle_count=4  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: load_pa_q  ready_cycle=4  ready_fo4=26.400  OpenSTA: report_timing -from clk_i -to load_pa_q
// order expect: load_pa_v_q  ready_cycle=4  ready_fo4=26.400  OpenSTA: report_timing -from clk_i -to load_pa_v_q
// --- factor stage 1/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node11513 c=3.50 slack=22.90 */
//     /* node11514 c=3.50 slack=22.90 */
//   end
// end
// --- factor stage 2/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//   end
// end
// --- factor stage 3/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 3: no capture on this edge (slack) */
//   end
// end
// --- factor stage 4/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     load_pa_q <= …; // sv-timing: cycle 4/4 on clk_i
//     load_pa_v_q <= …; // sv-timing: cycle 4/4 on clk_i
//     /* node11515 c=25.40 slack=1.00 */
//     /* node11516 c=26.40 slack=0.00 */
//     /* node11517 c=26.40 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_unit  region=3125  makespan=11.300 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: wpo_cnt_q  ready_cycle=2  ready_fo4=11.300  OpenSTA: report_timing -from clk_i -to wpo_cnt_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node11546 c=3.50 slack=7.80 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     wpo_cnt_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node11547 c=10.30 slack=1.00 */
//     /* node11548 c=11.30 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_unit  region=3129  makespan=7.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: hart_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to hart_q
// order expect: owner_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to owner_q
// order expect: pending_q  ready_cycle=1  ready_fo4=7.000  OpenSTA: report_timing -from clk_i -to pending_q
// order expect: size_q  ready_cycle=1  ready_fo4=7.500  OpenSTA: report_timing -from clk_i -to size_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     hart_q <= …; // sv-timing: cycle 1/1 on clk_i
//     owner_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pending_q <= …; // sv-timing: cycle 1/1 on clk_i
//     size_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node11629 c=3.50 slack=4.00 */
//     /* node11630 c=3.50 slack=4.00 */
//     /* node11631 c=3.50 slack=4.00 */
//     /* node11632 c=3.50 slack=4.00 */
//     /* node11633 c=7.00 slack=0.50 */
//     /* node11634 c=4.50 slack=3.00 */
//     /* node11635 c=4.50 slack=3.00 */
//     /* node11636 c=7.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=load_unit  region=3142  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node11665 c=3.50 slack=0.00 */
//     /* node11666 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign ldbuf_full = &ldbuf_valid_q;

  //
  //  buffer of outstanding loads

  //  write in the first available slot
  generate
    if (G6LCCfg.NrLoadBufEntries > 1) begin : ldbuf_free_index_multi_gen
      g6lc_hyp_lzc #(
          .WIDTH(G6LCCfg.NrLoadBufEntries),
          .MODE (1'b0)                       // Count leading zeros
      ) lzc_windex_i (
          .in_i   (~ldbuf_valid_q),
          .cnt_o  (ldbuf_free_index),
          .empty_o(ldbuf_empty)
      );
    end else begin : ldbuf_free_index_single_gen
      assign ldbuf_free_index = 1'b0;
    end
  // svt-stage: end L3
  endgenerate

  // hyp8 NrLoadBufEntries is 8, so a response cannot free the only
  // slot in the same cycle a new load allocates it. The depth-1
  // fall-through mux read ldbuf_r and tied issue to the retire scan.
  assign ldbuf_windex = ldbuf_free_index;

  always_comb begin : ldbuf_comb
    ldbuf_valid_d = ldbuf_valid_q;

    //  Free read entry (in the case of fall-through mode, free the entry
    //  only if there is no pending load). hyp8: freeing happens at L5
    //  publish or tombstone/rkill drain, not at the rvalid pulse.
    if (ldbuf_r && (!LDBUF_FALLTHROUGH || !ldbuf_w)) begin
      ldbuf_valid_d[ldbuf_rindex] = 1'b0;
    end
    //  Track a new outstanding operation in the load buffer
    if (ldbuf_w) begin
      ldbuf_valid_d[ldbuf_windex] = 1'b1;
    end
  end

  // Flushed flags are per slot. A procedural scan that rewrote one vector
  // put the same-cycle cancel behind a carried chain. Flush still wins over
  // a same-cycle grant, and a cancelled grant is marked in this cycle.
  logic lu_cancel_new;
  assign lu_cancel_new = ldbuf_w && cancelled_mask_i[ldbuf_wdata.trans_id];
  for (genvar gi = 0; gi < G6LCCfg.NrLoadBufEntries; gi++) begin : gen_ldbuf_flush
    logic old_hit, new_hit, hold;
    assign old_hit = !flush_i && ldbuf_valid_q[gi]
                  && cancelled_mask_i[ldbuf_q[gi].trans_id];
    assign new_hit = !flush_i && lu_cancel_new && (ldbuf_windex == ldbuf_id_t'(gi));
    assign hold    = ldbuf_flushed_q[gi] && !(ldbuf_w && (ldbuf_windex == ldbuf_id_t'(gi)));
    assign ldbuf_flushed_d[gi] = flush_i || old_hit || new_hit || hold;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : ldbuf_ff
    if (!rst_ni) begin
      ldbuf_flushed_q <= '0;
      ldbuf_valid_q   <= '0;
      ldbuf_last_id_q <= '0;
      ldbuf_q         <= '0;
      rpend_q         <= '0;
      rkill_q         <= '0;
      rdata_q         <= '{default: '0};
      fwd_reqed_q     <= '0;
      fwd_seen_q      <= '0;
      fwd_possible_q  <= '0;
      fwd_data_q      <= '{default: '0};
      fwd_be_q        <= '{default: '0};
      miss_age_q      <= '0;
    end else begin
      ldbuf_flushed_q <= ldbuf_flushed_d;
      ldbuf_valid_q   <= ldbuf_valid_d;
      if (ldbuf_w) begin
        ldbuf_last_id_q       <= ldbuf_windex;
        ldbuf_q[ldbuf_windex] <= ldbuf_wdata;
        // fresh slot: no response captured, no forward outstanding
        rpend_q[ldbuf_windex]        <= 1'b0;
        rkill_q[ldbuf_windex]        <= 1'b0;
        fwd_reqed_q[ldbuf_windex]    <= fwd_req_o.valid;
        fwd_seen_q[ldbuf_windex]     <= 1'b0;
        fwd_possible_q[ldbuf_windex] <= 1'b0;
      end
      // L3: capture a response pulse into its slot; a tag killed in the
      // same cycle marks the capture rkill so it drains without publish.
      if (req_port_i.data_rvalid && ldbuf_valid_q[rresp_idx]) begin
        rpend_q[rresp_idx] <= 1'b1;
        rdata_q[rresp_idx] <= req_port_i.data_rdata;
        rkill_q[rresp_idx] <= (rresp_idx == ldbuf_last_id_q) && req_port_o.kill_req;
      end
      if (ldbuf_r) begin
        rpend_q[ldbuf_rindex] <= 1'b0;
        rkill_q[ldbuf_rindex] <= 1'b0;
      end
      // hyp8 H5: per-slot age since the D$ request grant (miss replay)
      if (ldbuf_w) begin
        miss_age_q[ldbuf_windex] <= LD_AGE_W'(1);
      end
      for (int unsigned i = 0; i < G6LCCfg.NrLoadBufEntries; i++) begin
        if (!(ldbuf_w && (ldbuf_windex == ldbuf_id_t'(i))) &&
            ldbuf_valid_q[i] && !rpend_q[i] &&
            (miss_age_q[i] != {LD_AGE_W{1'b1}})) begin
          miss_age_q[i] <= miss_age_q[i] + LD_AGE_W'(1);
        end
      end
      // staged forward response lands in its requester's slot
      if (fwd_rsp_i.valid) begin
        fwd_seen_q[fwd_rsp_i.tag]     <= 1'b1;
        fwd_data_q[fwd_rsp_i.tag]     <= fwd_rsp_i.data;
        fwd_be_q[fwd_rsp_i.tag]       <= fwd_rsp_i.be;
        fwd_possible_q[fwd_rsp_i.tag] <= fwd_rsp_i.forward_possible;
      end
    end
  end

  // page offset is defined as the lower 12 bits, feed through for address checker
  assign page_offset_o = lsu_ctrl_i.vaddr[11:0];
  // R3a: use load **vaddr** as STQ key. Shared MMU dtlb_ppn/paddr is
  // also used by the store path — sampling ppn while a store translates desyncs
  // the key and misses stack RAW (next_tag ld s2 → 0 → by_offset sw 0(s2)
  // store-access-fault mcause=6 @ 0x80012e9c). Bare OpenSBI: VA==PA for DRAM.
  // G1m: valid only while a load is at the LSU head. Always-1 advertised
  // idle/store vaddrs to STQ (false page-offset match + sticky + forward).
  // P4 c.lw then waited ~200k and retired leftover data (a5=0x010dfeec).
  assign load_paddr_valid_o = valid_i;
  // T32: under translation the STQ holds PHYSICAL store addresses, so a
  // virtual key never forwards (pa_eq misses) while the [11:0] interlock
  // still matches -- every stack RAW waits for the STQ to drain, and a
  // younger load parked in WAIT_PAGE_OFFSET on an older *speculative* store
  // deadlocks the older load at the LU input (Linux sched_clock_noinstr:
  // prologue sd ra,40(sp) / epilogue ld ra,40(sp) ahead of the head ld).
  // The key is the load's own translation: taken from the shared MMU port
  // only in a cycle this unit drives translation_req_o (then dtlb_ppn_i is
  // this load's PPN, not a store's), and held while the same load stays at
  // the LU head. Bare mode: ppn == vaddr[PLEN-1:12], the key is unchanged.
  logic                    load_pa_v_q;
  logic [G6LCCfg.PLEN-1:0] load_pa_q, load_pa_now;
  logic                    load_pa_now_v;
  // One bare clear. The compound `flush || !valid || pop` was a select
  // on every bit of the captured physical address. Pop still wins over
  // a same-cycle sample.
  logic                    pa_drop;
  assign load_pa_now_v = valid_i && translation_req_o && dtlb_hit_i;
  assign load_pa_now   = G6LCCfg.PLEN'({dtlb_ppn_i, lsu_ctrl_i.vaddr[11:0]});
  assign pa_drop = flush_i | ~valid_i | pop_ld_o;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      load_pa_v_q <= 1'b0;
      load_pa_q   <= '0;
    end else if (pa_drop) begin
      load_pa_v_q <= 1'b0;
    end else if (load_pa_now_v) begin
      load_pa_v_q <= 1'b1;
      load_pa_q   <= load_pa_now;
    end
  end
  // One select into every physical-address bit is a 56-way fanout.
  // hyp8 PLEN is 56. Four copies of each select drive 14 bits. Now
  // still wins over the held key, and the held key over the virtual
  // address. Pop still clears the held key in the pop cycle.
  logic [55:0] pa_hold_lo, pa_out_lo;
  logic hold_s0, hold_s1, hold_s2, hold_s3;
  logic now_s0, now_s1, now_s2, now_s3;
  assign hold_s0 = load_pa_v_q;
  assign hold_s1 = load_pa_v_q;
  assign hold_s2 = load_pa_v_q;
  assign hold_s3 = load_pa_v_q;
  assign now_s0 = load_pa_now_v;
  assign now_s1 = load_pa_now_v;
  assign now_s2 = load_pa_now_v;
  assign now_s3 = load_pa_now_v;
  for (genvar b = 0; b < 56; b++) begin : gen_pa_bit
    if (b < 14) begin : gen_b0
      assign pa_hold_lo[b] = hold_s0 ? load_pa_q[b] : lsu_ctrl_i.vaddr[b];
      assign pa_out_lo[b]  = now_s0 ? load_pa_now[b] : pa_hold_lo[b];
    end else if (b < 28) begin : gen_b1
      assign pa_hold_lo[b] = hold_s1 ? load_pa_q[b] : lsu_ctrl_i.vaddr[b];
      assign pa_out_lo[b]  = now_s1 ? load_pa_now[b] : pa_hold_lo[b];
    end else if (b < 42) begin : gen_b2
      assign pa_hold_lo[b] = hold_s2 ? load_pa_q[b] : lsu_ctrl_i.vaddr[b];
      assign pa_out_lo[b]  = now_s2 ? load_pa_now[b] : pa_hold_lo[b];
    end else begin : gen_b3
      assign pa_hold_lo[b] = hold_s3 ? load_pa_q[b] : lsu_ctrl_i.vaddr[b];
      assign pa_out_lo[b]  = now_s3 ? load_pa_now[b] : pa_hold_lo[b];
    end
  end
  assign load_paddr_o = pa_out_lo;
  assign load_trans_id_o = lsu_ctrl_i.trans_id;
  assign load_hart_o = lsu_ctrl_i.hart;
  // feed-through the virtual address for VA translation
  assign vaddr_o = lsu_ctrl_i.vaddr;
  assign hs_ld_st_inst_o = G6LCCfg.RVH ? lsu_ctrl_i.hs_ld_st_inst : 1'b0;
  assign hlvx_inst_o = G6LCCfg.RVH ? lsu_ctrl_i.hlvx_inst : 1'b0;
  // feed-through the transformed instruction for mmu
  assign tinst_o = G6LCCfg.RVH ? lsu_ctrl_i.tinst : '0;
  // this is a read-only interface so set the write enable to 0
  assign req_port_o.data_we = 1'b0;
  assign req_port_o.data_wdata = '0;
  assign req_port_o.cbo_op = g6lc_core_pkg::CBO_NONE;
  // compose the load buffer write data, control is handled in the FSM
  assign ldbuf_wdata = {
    lsu_ctrl_i.trans_id, lsu_ctrl_i.vaddr[G6LCCfg.XLEN_ALIGN_BYTES-1:0], lsu_ctrl_i.operation
  };
  // output address
  // we can now output the lower 12 bit as the index to the cache
  assign req_port_o.address_index = lsu_ctrl_i.vaddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:0];
  // translation from last cycle, again: control is handled in the FSM
  assign req_port_o.address_tag   = paddr_i[G6LCCfg.DCACHE_TAG_WIDTH     +
                                              G6LCCfg.DCACHE_INDEX_WIDTH-1 :
                                              G6LCCfg.DCACHE_INDEX_WIDTH];
  // request id = index of the load buffer's entry
  assign req_port_o.data_id = ldbuf_windex;
  // user field not used
  assign req_port_o.data_wuser = '0;
  // directly forward exception fields (valid bit is set below)
  assign ex_o.cause = ex_i.cause;
  assign ex_o.tval = ex_i.tval;
  assign ex_o.tval2 = G6LCCfg.RVH ? ex_i.tval2 : '0;
  assign ex_o.tinst = G6LCCfg.RVH ? ex_i.tinst : '0;
  assign ex_o.gva = G6LCCfg.RVH ? ex_i.gva : 1'b0;

  // Check that NI operations follow the necessary conditions.
  // FSE S2 audit: speculative loads never issue to non-idempotent regions until
  // the controlling branch is resolved (see IDLE: dtlb_hit && !paddr_ni, else
  // WAIT_SPEC_LOAD). DeepSpecEn widens the in-flight window but does not relax
  // this gate — NI still requires NonIdemPotenceEn + store-buffer drain rules.
  logic paddr_ni;
  logic not_commit_time;
  logic inflight_stores;
  logic stall_ni;
  assign paddr_ni = config_pkg::is_inside_nonidempotent_regions(
      G6LCCfg, {{52 - G6LCCfg.PPNW{1'b0}}, dtlb_ppn_i, 12'd0}
  );
  assign not_commit_time = commit_tran_id_i != lsu_ctrl_i.trans_id;
  assign inflight_stores = !dcache_wbuffer_not_ni_i ||
                           (G6LCCfg.OoOEn ? !no_st_pending_i : !store_buffer_empty_i);
  assign stall_ni = (inflight_stores || not_commit_time) && (paddr_ni && G6LCCfg.NonIdemPotenceEn);

  // R3a: STQ data forward covers this load's bytes (lsu_ctrl.be already sized/aligned)
  logic st_fwd_covers;
  // (store_be & load_be) == load_be is "every requested byte is
  // present". A per-byte OR reduces as a tree; the wide equality
  // left-folded the mask.
  logic [(G6LCCfg.XLEN/8)-1:0] fwd_byte_ok;
  logic                        st_fwd_bytes;
  for (genvar b = 0; b < (G6LCCfg.XLEN / 8); b++) begin : gen_fwd_byte
    assign fwd_byte_ok[b] = ~lsu_ctrl_i.be[b] | st_fwd_be_i[b];
  end
  assign st_fwd_bytes = &fwd_byte_ok;
  assign st_fwd_covers = (G6LCCfg.CohPolicy != config_pkg::COH_OOO) &&
                         st_fwd_valid_i && (|lsu_ctrl_i.be) && st_fwd_bytes;
  // Bare enable for the page-offset forward. The compound guard was
  // the select on that state arm. Same cycle: covered and checked
  // still completes without waiting for data_rvalid.
  logic fwd_final;
  logic ld_checked_head;
  assign ld_checked_head = ld_checked_i[lsu_ctrl_i.trans_id];
  assign fwd_final = st_fwd_covers & ld_checked_head;

  // R3a cont.14: cont.4/10 STQ-empty-for-all-loads under SpeculativeSb made
  // DI force-SI path_offset return -4, while true SI (SpeculativeSb=0, no
  // st_pipeline_busy) advances past /cpus into sbi_trap_handler. Revert to
  // classic the core page-offset interlock only (+ store-side sticky so post-
  // grant loads still wait for wbuffer). Forward covers stack RAW when live.
  // Soft-ladder iter-012: SS-wide st_pipeline_busy + STQ-nofwd was PEEL-negative
  // (fw64d); restored SpeculativeSb gate (smt2 has SpeculativeSb=0).
  logic st_pipeline_busy;
  assign st_pipeline_busy = G6LCCfg.SpeculativeSb && G6LCCfg.SuperscalarEn &&
                            page_offset_matches_i && !st_fwd_covers &&
                            (!store_buffer_empty_i || !dcache_wbuffer_empty_i);

  // Pulse: load completed from STQ forward this cycle (no D$ request)
  logic st_fwd_done;
  // T33: WAIT_PAGE_OFFSET dwell counter; replay only under OoO (the cancel +
  // commit-time refetch path exists there) and only for a speculative-only
  // match -- a committed/draining store finishes on its own.
  localparam int unsigned WPO_REPLAY_AFTER = 64;
  logic [7:0] wpo_cnt_q;
  logic       lu_replay_fire;
  assign lu_replay_fire = G6LCCfg.OoOEn && page_offset_spec_only_i &&
                          (wpo_cnt_q >= 8'(WPO_REPLAY_AFTER));
  assign lu_replay_id_o = lsu_ctrl_i.trans_id;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) wpo_cnt_q <= '0;
    else if (!state_q[LU_B_WAIT_PAGE_OFFSET] || flush_i) wpo_cnt_q <= '0;
    else if (wpo_cnt_q != 8'hFF) wpo_cnt_q <= wpo_cnt_q + 8'd1;
  end
  logic cancelled_request, cancel_hit;
  assign cancel_hit = lsu_ctrl_i.is_speculative_load_miss
                   | cancelled_mask_i[lsu_ctrl_i.trans_id];
  assign cancelled_request = G6LCCfg.OoOEn & valid_i & cancel_hit;
  // Translation request is a state decode, not an output of the FSM
  // process. The PA key samples dtlb_ppn only while this is high; tying
  // it to the process pulled the whole next-state arm onto that sample.
  // State bits are LU_B_IDLE, WAIT_GNT, SEND_TAG, WAIT_TRANSLATION.
  // A localparam index of state_q is billed as a variable index.
  logic tr_idle_ok, accept_req_w;
  logic st_idle, st_gnt, st_tag, st_xlat;
  logic tr_issue_st, tr_issue_acc, tr_issue, tr_xlat_en, tr_or_gx, tr_state;
  assign tr_idle_ok = !G6LCCfg.SpeculativeSb || dtlb_hit_i || !lsu_ctrl_i.is_speculative_load;
  assign accept_req_w = valid_i && !ldbuf_full;
  assign st_idle = state_q[0];
  assign st_gnt  = state_q[1];
  assign st_tag  = state_q[2];
  assign st_xlat = state_q[6];
  assign tr_xlat_en = st_xlat & (G6LCCfg.MmuPresent | G6LCCfg.NonIdemPotenceEn);
  assign tr_issue_st  = st_idle | st_tag;
  assign tr_issue_acc = tr_issue_st & accept_req_w;
  assign tr_issue = tr_issue_acc & tr_idle_ok;
  assign tr_or_gx = st_gnt | tr_xlat_en;
  assign tr_state = tr_or_gx | tr_issue;
  assign translation_req_o = ~cancelled_request & tr_state;
  // D$ request is the same decode, not a priority arm inside the FSM.
  // IDLE and SEND_TAG issue only when the load is not speculative-NC,
  // the store pipe is idle, and the page offset does not match a store
  // that still has to train. WAIT_GNT holds the request. A cancel clears it
  // in this cycle, matching the tail of load_control.
  logic spec_issue_ok, lu_issue_now;
  assign spec_issue_ok = !G6LCCfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load
                      || (dtlb_hit_i && !paddr_ni);
  assign lu_issue_now = !page_offset_matches_i
                     && !(st_fwd_covers && !ld_checked_head);
  assign req_port_o.data_req = !cancelled_request && (
      state_q[LU_B_WAIT_GNT] ||
      ((state_q[LU_B_IDLE] || state_q[LU_B_SEND_TAG]) && accept_req_w
       && spec_issue_ok && !st_pipeline_busy && lu_issue_now));

  // ---------------
  // Load Control
  // ---------------
  // Kill is an OR of the state arms. It used to be assigned inside the
  // priority default branch, so the abort arm sat behind every earlier
  // compare. The exception publish still reads this bit in the same cycle.
  logic kill_send, kill_flush, kill_abort, kill_abort_ni, kill_req_w;
`ifdef G6LC_MUT_LSU_EXKILL
  assign kill_send = state_q[LU_B_SEND_TAG] && ex_i.valid;
`else
  assign kill_send = state_q[LU_B_SEND_TAG] && ex_i.valid &&
      (!ex_ptw_i || flush_i || cancelled_mask_i[ldbuf_q[ldbuf_last_id_q].trans_id]);
`endif
  assign kill_flush    = state_q[LU_B_WAIT_FLUSH];
  assign kill_abort    = state_q[LU_B_ABORT_TRANSACTION] && G6LCCfg.MmuPresent;
  assign kill_abort_ni = state_q[LU_B_ABORT_TRANSACTION_NI] && G6LCCfg.NonIdemPotenceEn;
  assign kill_req_w    = kill_send || kill_flush || kill_abort || kill_abort_ni;
  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // hyp8: sv-timing BalanceMux staging removed; FSM next-state
  // targets are literal again (the ORed arm tree was a timing
  // artifact that collapsed every transition of a state into a
  // single superset value).
  always_comb begin : load_control
    automatic logic accept_req;

    // default assignments
    state_d              = state_q;
    // data_req is the continuous decode above.
    // tag control
    req_port_o.kill_req  = kill_req_w;
    req_port_o.tag_valid = 1'b0;
    req_port_o.data_be   = lsu_ctrl_i.be;
    req_port_o.data_size = extract_transfer_size(lsu_ctrl_i.operation);
    pop_ld_o             = 1'b0;
    lu_replay_o          = 1'b0;
    st_fwd_done          = 1'b0;

    // Depth-1 fall-through is not this configuration. Accept does not
    // read the retire pop, so a new request is not in series with it.
    accept_req = valid_i && !ldbuf_full;

    case (1'b1)  // hyp8: one-hot state select
      state_q[LU_B_IDLE]: begin
        if (accept_req) begin
          // translation_req_o is the continuous decode above.
          // check if load is speculative and non idempotent, if it is then stall and wait for branch result
          if (!G6LCCfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load || (dtlb_hit_i && !paddr_ni)) begin
            // R3a: if STQ can fully satisfy this load, complete from forward
            // (no D$ request). Closes stack *nextoffset RAW without waiting for
            // STQ drain + wbuffer. Partial coverage still waits in WAIT_PAGE_OFFSET.
            // R3a cont.4/5: wait until STQ + D$ wbuffer empty (unless forward).
            if (st_pipeline_busy) begin
              state_d = LU_S_WAIT_PAGE_OFFSET; // hyp8: literal FSM target (svt balance-mux arm restored)
            end else if (page_offset_matches_i && st_fwd_covers && !req_port_i.data_rvalid &&
                         ld_checked_head) begin // hyp8: publish only verdict-final
              state_d = LU_S_IDLE; // hyp8: literal FSM target (svt balance-mux arm restored)
              pop_ld_o    = 1'b1;
              st_fwd_done = 1'b1;
              // hyp8: a covered load whose verdict is not yet final waits
              // (forward data would otherwise be consumed unchecked); a
              // non-matching or unchecked-covered load still issues to D$.
            end else if (!page_offset_matches_i &&
                         !(st_fwd_covers && !ld_checked_head)) begin
              // data_req is the continuous decode above.
              // we got no data grant so wait for the grant before sending the tag
              if (!req_port_i.data_gnt) begin
                state_d = LU_S_WAIT_GNT; // hyp8: literal FSM target (svt balance-mux arm restored)
              end else begin
                if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
                  state_d = LU_S_ABORT_TRANSACTION; // hyp8: literal FSM target (svt balance-mux arm restored)
                end else begin
                  if (!stall_ni) begin
                    // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                    state_d = LU_S_SEND_TAG; // hyp8: literal FSM target (svt balance-mux arm restored)
                    pop_ld_o = 1'b1;
                    // translation valid but this is to NC and the WB is not yet empty.
                  end else if (G6LCCfg.NonIdemPotenceEn) begin
                    state_d = LU_S_ABORT_TRANSACTION_NI;
                  end
                end
              end
            end else begin
              // wait for the store buffer to train and the page offset to not match anymore
              // (or until STQ forward fully covers)
              state_d = LU_S_WAIT_PAGE_OFFSET; // hyp8: literal FSM target (svt balance-mux arm restored)
            end
          end else begin
            // check branch result on the next cycle
            state_d = LU_S_WAIT_SPEC_LOAD; // hyp8: literal FSM target (svt balance-mux arm restored)
          end
        end
      end

      // wait here for the page offset to not match anymore
      state_q[LU_B_WAIT_PAGE_OFFSET]: begin
        // R3a: complete from STQ forward when bytes are fully covered
        // T39/T44: a covered load WAITS while the result port carries a D$
        // response (data_rvalid); it never falls through to the "re-issue to
        // D$" branch below. Pre-fix, st_pipeline_busy is 0 whenever the
        // forward covers, so one cycle of rvalid from an unrelated load sent
        // the covered load to WAIT_GNT and it read the line the store had not
        // reached yet (HPDCACHE: insert_header's `ld s8,56(s1)` 29 cycles
        // after its `sd`, the 2-hart server1 oops; the single-hart exec oops).
`ifdef G6LC_MUT_LU_FWD_RVALID_FALLTHROUGH
        if (fwd_final && !req_port_i.data_rvalid) begin   // review mutation: the pre-fix shape (+ hyp8 checked gate)
          state_d     = LU_S_IDLE;
          pop_ld_o    = 1'b1;
          st_fwd_done = 1'b1;
`else
        if (fwd_final) begin // hyp8: hold until verdict-final
          if (!req_port_i.data_rvalid) begin
            state_d     = LU_S_IDLE;
            pop_ld_o    = 1'b1;
            st_fwd_done = 1'b1;
          end
`endif
        end else if (st_pipeline_busy && lu_replay_fire) begin
          // T33: the only store in the way is speculative and has not left in
          // WPO_REPLAY_AFTER cycles -- it is waiting on retirement, possibly on
          // an older load queued behind this one. Hand this load back: the
          // scoreboard cancels it and refetches from its PC at commit, by which
          // time the store has committed. Linux sched_clock_noinstr deadlock.
          state_d     = LU_S_IDLE;
          pop_ld_o    = 1'b1;
          lu_replay_o = 1'b1;
        end else if (st_pipeline_busy) begin
          // hold until STQ + D$ wbuffer drain
          state_d = LU_S_WAIT_PAGE_OFFSET;
        end else begin
          // No in-flight stores (or sticky match only): re-issue to D$
          state_d = LU_S_WAIT_GNT;
        end
      end

      state_q[LU_B_WAIT_SPEC_LOAD]: begin
        // if we have a misspredicted speculative load
        if (G6LCCfg.SpeculativeSb && lsu_ctrl_i.is_speculative_load_miss) begin
          // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
          if (!req_port_i.data_rvalid) begin
            state_d  = LU_S_IDLE;
            pop_ld_o = 1'b1;
          end
          // if we have a correct prediction this is now a regular load
        end else begin
          state_d = LU_S_IDLE;
        end
      end

      state_q[LU_B_WAIT_GNT]: begin
        // translation_req_o and data_req stay high via the decode above.
        // we finally got a data grant
        if (req_port_i.data_gnt) begin
          // so we send the tag in the next cycle
          if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
            state_d = LU_S_ABORT_TRANSACTION; // hyp8: literal FSM target (svt balance-mux arm restored)
          end else begin
            if (!stall_ni) begin
              // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
              state_d = LU_S_SEND_TAG; // hyp8: literal FSM target (svt balance-mux arm restored)
              pop_ld_o = 1'b1;
              // translation valid but this is to NC and the WB is not yet empty.
            end else if (G6LCCfg.NonIdemPotenceEn) begin
              state_d = LU_S_ABORT_TRANSACTION_NI;
            end
          end

        end
        // otherwise we keep waiting on our grant
      end
      // we know for sure that the tag we want to send is valid
      state_q[LU_B_SEND_TAG]: begin
        req_port_o.tag_valid = 1'b1;
        state_d = LU_S_IDLE;

        if (accept_req) begin
          // translation_req_o is the continuous decode above.
          // check if load is speculative and non idempotent, if it is then stall and wait for branch result
          if (!G6LCCfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load || (dtlb_hit_i && !paddr_ni)) begin
            // check if the page offset matches with a store, if it does stall and wait
            // R3a: STQ forward path (mirror IDLE)
            if (st_pipeline_busy) begin
              state_d = LU_S_WAIT_PAGE_OFFSET; // hyp8: literal FSM target (svt balance-mux arm restored)
            end else if (page_offset_matches_i && st_fwd_covers && !req_port_i.data_rvalid &&
                         ld_checked_head) begin // hyp8: publish only verdict-final
              state_d = LU_S_IDLE; // hyp8: literal FSM target (svt balance-mux arm restored)
              pop_ld_o    = 1'b1;
              st_fwd_done = 1'b1;
              // hyp8: a covered load whose verdict is not yet final waits
              // (forward data would otherwise be consumed unchecked); a
              // non-matching or unchecked-covered load still issues to D$.
            end else if (!page_offset_matches_i &&
                         !(st_fwd_covers && !ld_checked_head)) begin
              // data_req is the continuous decode above.
              // we got no data grant so wait for the grant before sending the tag
              if (!req_port_i.data_gnt) begin
                state_d = LU_S_WAIT_GNT; // hyp8: literal FSM target (svt balance-mux arm restored)
              end else begin
                // we got a grant so we can send the tag in the next cycle
                if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
                  state_d = LU_S_ABORT_TRANSACTION; // hyp8: literal FSM target (svt balance-mux arm restored)
                end else begin
                  if (!stall_ni) begin
                    // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                    state_d = LU_S_SEND_TAG; // hyp8: literal FSM target (svt balance-mux arm restored)
                    pop_ld_o = 1'b1;
                    // translation valid but this is to NC and the WB is not yet empty.
                  end else if (G6LCCfg.NonIdemPotenceEn) begin
                    state_d = LU_S_ABORT_TRANSACTION_NI;
                  end
                end
              end
            end else begin
              // wait for the store buffer to train and the page offset to not match anymore
              state_d = LU_S_WAIT_PAGE_OFFSET; // hyp8: literal FSM target (svt balance-mux arm restored)
            end
          end else begin
            // check branch result on the next cycle
            state_d = LU_S_WAIT_SPEC_LOAD; // hyp8: literal FSM target (svt balance-mux arm restored)
          end
        end
        // ----------
        // Exception
        // ----------
        // N1d: ex_i (g6lc_mmu_exception) is shared between LSU requesters.
        // A registered-path exception (misaligned, permission, PMP) at
        // SEND_TAG is this load's own fault and kills the tag as upstream did.
        // A PTW-broadcast exception (ex_ptw_i) belongs to a different walk —
        // this load already resolved its translation — so it must not kill a
        // surviving load's tag; that would drop it silently: no result, no
        // phys_valid, no cancel — phys_pending then masks the commit head
        // forever. Flush/cancel still kill: the entry is being squashed.
      end

      state_q[LU_B_WAIT_FLUSH]: begin
        // the D$ arbiter will take care of presenting this to the memory only in case we
        // have an outstanding request
        req_port_o.tag_valid = 1'b1;
        // we've killed the current request so we can go back to idle
        state_d = LU_S_IDLE;
      end

      // These states are one-hot, so each is its own case item. A priority
      // if of all of them in default billed the arms as one chain.
      state_q[LU_B_ABORT_TRANSACTION]: begin
        if (G6LCCfg.MmuPresent) begin
          req_port_o.tag_valid = 1'b1;
          state_d = LU_S_WAIT_TRANSLATION;
        end else begin
          state_d = LU_S_IDLE;
        end
      end
      state_q[LU_B_ABORT_TRANSACTION_NI]: begin
        if (G6LCCfg.NonIdemPotenceEn) begin
          req_port_o.tag_valid = 1'b1;
          state_d = LU_S_WAIT_WB_EMPTY;
        end else begin
          state_d = LU_S_IDLE;
        end
      end
      state_q[LU_B_WAIT_WB_EMPTY]: begin
        if (G6LCCfg.NonIdemPotenceEn && dcache_wbuffer_not_ni_i) begin
          state_d = LU_S_WAIT_TRANSLATION;
        end else begin
          state_d = LU_S_IDLE;
        end
      end
      state_q[LU_B_WAIT_TRANSLATION]: begin
        if (G6LCCfg.MmuPresent || G6LCCfg.NonIdemPotenceEn) begin
          if (dtlb_hit_i) state_d = LU_S_WAIT_GNT;
          // Exception wins over the TLB hit in the same cycle.
          if (ex_i.valid) begin
            state_d  = LU_S_IDLE;
            pop_ld_o = ~req_port_i.data_rvalid;
          end
        end else begin
          state_d = LU_S_IDLE;
        end
      end
      default: begin
        state_d = LU_S_IDLE;
      end
    endcase

    if (cancelled_request) begin
      // data_req is cleared by the continuous decode above.
      st_fwd_done = 1'b0;
      pop_ld_o = 1'b1;
      state_d = LU_S_IDLE;
    end

    // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in an extra stage
    if (flush_i) begin
      state_d = LU_S_WAIT_FLUSH;
    end
  end

  // track the load data for later usage
  assign ldbuf_w = req_port_o.data_req & req_port_i.data_gnt;

  if (G6LCCfg.CohPolicy == config_pkg::COH_OOO) begin : gen_phys_owner
    logic pending_q;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] owner_q;
    logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_q;
    logic [1:0] size_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pending_q <= 1'b0;
        owner_q <= '0;
        hart_q <= '0;
        size_q <= '0;
      end else begin
        pending_q <= ldbuf_w && !cancelled_mask_i[lsu_ctrl_i.trans_id];
        if (ldbuf_w) begin
          owner_q <= lsu_ctrl_i.trans_id;
          hart_q <= lsu_ctrl_i.hart;
          size_q <= extract_transfer_size(lsu_ctrl_i.operation);
        end
      end
    end
    // N1d: publish on any tag that was actually delivered (not killed). The
    // shared exception/flush suppressors dropped the one-shot phys event for
    // loads whose scoreboard entry outlived the transient — the LSQ never
    // re-reads it, so a dropped pulse is a permanent phys_pending wedge.
    // Publishing for a dying entry is harmless: the LSQ capture is keyed on
    // id+hart and the entry is torn down by cancel/flush regardless.
    assign phys_valid_o = pending_q && req_port_o.tag_valid && !req_port_o.kill_req &&
                          !flush_i && !cancelled_mask_i[owner_q];
    assign phys_addr_o = paddr_i;
    assign phys_id_o = owner_q;
    assign phys_hart_o = hart_q;
    assign phys_size_o = size_q;
  end else begin : gen_no_phys_owner
    assign phys_valid_o = 1'b0;
    assign phys_addr_o = '0;
    assign phys_id_o = '0;
    assign phys_hart_o = '0;
    assign phys_size_o = '0;
  end

  // ---------------
  // Retire Load
  // ---------------
  // svt-stage: begin L5
  // hyp8 L5 publish. data_rvalid only captures into the slot (rpend_q);
  // the slot is published once (a) the LSQ verdict for its trans_id is
  // final (ld_checked_i — a load cannot commit before its verdict) and
  // (b) its staged store-forward response has returned. Tombstoned
  // (flush/cancel) and killed slots drain without publishing. Exception
  // completions publish immediately: a faulted load produced no data
  // read, so no forward/violation check can apply to it.
  assign rresp_idx = (G6LCCfg.NrLoadBufEntries > 1) ? ldbuf_id_t'(req_port_i.data_rid)
                                                  : ldbuf_id_t'(1'b0);
  assign ldbuf_rdata = ldbuf_q[retire_idx];

  // Publish mask: one bit per slot, same predicate as the reference scan
  // (response captured, not tombstoned, LSQ verdict final, forward
  // resolved). Lowest index wins, which is what `if (!valid_o)` kept.
  // valid_o still means "this slot's trans_id and data".
  localparam int unsigned NLD = (G6LCCfg.NrLoadBufEntries > 0) ? G6LCCfg.NrLoadBufEntries : 1;
  logic [NLD-1:0] pub_ok, pub_oh;
  for (genvar i = 0; i < NLD; i++) begin : gen_pub_ok
    assign pub_ok[i] = rpend_q[i] && ldbuf_valid_q[i] && !ldbuf_flushed_q[i] &&
                       ld_checked_i[ldbuf_q[i].trans_id] &&
                       (!fwd_reqed_q[i] || fwd_seen_q[i]);
  end
  assign pub_oh = pub_ok & (~pub_ok + {{NLD-1{1'b0}}, 1'b1});

  // One-hot to index, outside the publish process. A procedural scan
  // that rewrote retire_idx sat in front of the exception arm, and that
  // arm also reads kill_req, so the buffer mux was billed after kill.
  localparam int unsigned LD_IDX_W = (NLD <= 1) ? 1 : $clog2(NLD);
  logic [LD_IDX_W-1:0] pub_part [NLD];
  logic [LD_IDX_W-1:0] pub_or [NLD];
  logic [LD_IDX_W-1:0] pub_idx_w;
  logic                pub_any;
  logic                ex_pub;
  for (genvar pi = 0; pi < NLD; pi++) begin : gen_pub_part
    assign pub_part[pi] = pub_oh[pi] ? LD_IDX_W'(pi) : '0;
  end
  assign pub_or[0] = pub_part[0];
  for (genvar pi = 1; pi < NLD; pi++) begin : gen_pub_or
    assign pub_or[pi] = pub_or[pi-1] | pub_part[pi];
  end
  assign pub_idx_w = pub_or[NLD-1];
  assign pub_any   = |pub_oh;
  // Same predicate as the old exception arm, using kill_req_w rather than
  // the FSM output so the kill OR is not behind load_control.
  assign ex_pub = req_port_i.data_rvalid && ldbuf_valid_q[rresp_idx] &&
                  !ldbuf_flushed_q[rresp_idx] &&
                  ((ldbuf_last_id_q != rresp_idx) || !kill_req_w) &&
                  ex_i.valid && !ex_ptw_i && state_q[LU_B_SEND_TAG];

  // decoupled rvalid/publish process
  always_comb begin : rvalid_output
    // G1l: leftover D$ rvalid with rid of a free slot must not pop or
    // retire (stale trans_id / rdata → P4 c.lw a5=0x010dfeec while
    // DRAM[fdt+0x28]=1). NrLoadBufEntries>1 so no fall-through same-cycle
    // grant+rvalid. Flush-phantom is already handled above.
    ldbuf_r    = 1'b0;
    ldbuf_rindex = '0;
    retire_idx = '0;
    trans_id_o = ldbuf_q[retire_idx].trans_id;
    valid_o    = 1'b0;
    ex_o.valid = 1'b0;

    // publish pick: pub_oh is already the lowest set bit.
    if (pub_any) begin
      retire_idx   = ldbuf_id_t'(pub_idx_w);
      valid_o      = 1'b1;
      trans_id_o   = ldbuf_q[retire_idx].trans_id;
      ldbuf_r      = 1'b1;
      ldbuf_rindex = retire_idx;
    end else if (ex_pub) begin
      // Faulted load: publish in the same cycle as kill_req. ex_pub
      // already includes !kill_req_w for the tag that owns this response.
      trans_id_o   = ldbuf_q[rresp_idx].trans_id;
      valid_o      = 1'b1;
      ex_o.valid   = 1'b1;
      ldbuf_r      = 1'b1;
      ldbuf_rindex = rresp_idx;
    end

    // drain pick (no publish): a tombstoned or tag-killed slot that has
    // captured its response frees here — LSU tombstones survive flush
    // but never produce a writeback.
    if (!ldbuf_r) begin
      for (int unsigned i = 0; i < G6LCCfg.NrLoadBufEntries; i++) begin
        if (!ldbuf_r && rpend_q[i] && ldbuf_valid_q[i] &&
            (ldbuf_flushed_q[i] || rkill_q[i])) begin
          ldbuf_r      = 1'b1;
          ldbuf_rindex = ldbuf_id_t'(i);
        end
      end
    end

    // an exception occurred during translation
    // exceptions can retire out-of-order -> but we need to give priority to non-excepting load and stores
    // so we simply check if we got an rvalid if so we prioritize it by not retiring the exception - we simply go for another
    // round in the load FSM
    if ((G6LCCfg.MmuPresent || G6LCCfg.NonIdemPotenceEn) && (state_q[LU_B_WAIT_TRANSLATION]) && !req_port_i.data_rvalid && ex_i.valid && valid_i && !cancelled_request) begin
      trans_id_o = lsu_ctrl_i.trans_id;
      valid_o = 1'b1;
      ex_o.valid = 1'b1;
    end

    // raise valid when removing a misspredicted speculative load
    if (G6LCCfg.SpeculativeSb && (state_q[LU_B_WAIT_SPEC_LOAD]) && lsu_ctrl_i.is_speculative_load_miss && !req_port_i.data_rvalid && valid_i && !cancelled_request) begin
      trans_id_o = lsu_ctrl_i.trans_id;
      valid_o = 1'b1;
      ex_o.valid = 1'b0;
    end

    // R3a: STQ store→load forward completion (no D$ rvalid / ldbuf slot).
    // hyp8: st_fwd_done is only set when the verdict is already final
    // (the FSM holds the covered load until ld_checked_i asserts), so the
    // publication is verdict-safe by construction.
    if (st_fwd_done) begin
      trans_id_o = lsu_ctrl_i.trans_id;
      valid_o    = 1'b1;
      ex_o.valid = 1'b0;
    end
  end

  // svt-stage: end L5
  // svt-stage: begin L2
  // hyp8 L2: staged forward request — fired when the D$ request commits
  // (ldbuf_w) and the load's physical address is already resolved. The
  // store buffer answers StoreFwdCycles cycles later on fwd_rsp_i; the
  // tag re-pairs the response with this ldbuf slot. Under
  // StoreFwdCycles==1 the live st_fwd_* path below owns forwarding and
  // no request is raised.
  assign fwd_req_o.valid = (HypCfg.StoreFwdCycles > 1) && ldbuf_w &&
                           (dtlb_hit_i || !G6LCCfg.MmuPresent);
  assign fwd_req_o.pa    = load_paddr_o;
  assign fwd_req_o.size  = extract_transfer_size(lsu_ctrl_i.operation);
  assign fwd_req_o.tid   = lsu_ctrl_i.trans_id;
  assign fwd_req_o.hart  = lsu_ctrl_i.hart;
  assign fwd_req_o.tag   = ldbuf_windex;

  // svt-stage: end L2
  // hyp8 H5: fire once when a granted slot's response has not arrived by
  // the expected hit-latency cycle (2 + DcacheHitExtra after the grant).
  // A same-cycle rvalid for the slot is still a hit; lowest slot index
  // wins when several expire together.
  always_comb begin
    miss_replay    = 1'b0;
    miss_replay_id = '0;
    for (int unsigned i = G6LCCfg.NrLoadBufEntries; i > 0; i--) begin
      if (ldbuf_valid_q[i-1] && !rpend_q[i-1] &&
          !ldbuf_flushed_q[i-1] && !rkill_q[i-1] &&
          !cancelled_mask_i[ldbuf_q[i-1].trans_id] &&
          (miss_age_q[i-1] == LD_AGE_W'(LD_HIT_LAT)) &&
          !(req_port_i.data_rvalid && (rresp_idx == ldbuf_id_t'(i-1)))) begin
        miss_replay    = 1'b1;
        miss_replay_id = ldbuf_q[i-1].trans_id;
      end
    end
  end

  // hyp8: IQ re-arm sources — the T33 speculative-store replay OR the D$
  // miss slot-timeout (H5). Coincident losers are carried by the dispatch
  // merge's pending set.
  assign replay_o     = lu_replay_o | miss_replay;
  assign replay_tid_o = lu_replay_o ? lu_replay_id_o : miss_replay_id;


  // latch physical address for the tag cycle (one cycle after applying the index)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q <= LU_S_IDLE;
    end else begin
      state_q <= state_d;
    end
  end

  // ---------------
  // Sign Extend
  // ---------------
  logic [G6LCCfg.XLEN-1:0] shifted_data;
  // R3a: mux D$ rdata vs STQ forward; operation/offset from active source
  logic [G6LCCfg.XLEN-1:0]                 load_rdata;
  logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0]     load_addr_offset;
  fu_op                                    load_operation;

  // svt-stage: begin L4
  // hyp8 L4/L5: the publishing slot's captured response is merged with
  // its staged forward response — forward bytes override the D$ word
  // wherever the buffer flagged forward_possible (byte-exact youngest-
  // writer data owned by the store buffer side).
  logic [G6LCCfg.XLEN-1:0] fwd_merged_data;
  for (genvar b = 0; b < G6LCCfg.XLEN / 8; b++) begin : gen_fwd_merge
    assign fwd_merged_data[b*8 +: 8] =
        (fwd_possible_q[retire_idx] && fwd_be_q[retire_idx][b])
            ? fwd_data_q[retire_idx][b*8 +: 8]
            : rdata_q[retire_idx][b*8 +: 8];
  end

  assign load_rdata = st_fwd_done ? st_fwd_data_i : fwd_merged_data;
  assign load_addr_offset = st_fwd_done
                              ? lsu_ctrl_i.vaddr[G6LCCfg.XLEN_ALIGN_BYTES-1:0]
                              : ldbuf_rdata.address_offset;
  assign load_operation = st_fwd_done ? lsu_ctrl_i.operation : ldbuf_rdata.operation;

  // realign as needed
  // address_offset is just the last three bits of the load address which select the byte address within the word
  assign shifted_data = load_rdata >> {load_addr_offset, 3'b000};

  // The code here is legacy - from the days before G6LC was Big Endian Capable :)
  /*// result mux (leaner code, but more logic stages.
    // can be used instead of the code below (in between //result mux fast) if timing is not so critical)
    always_comb begin
        unique case (ldbuf_rdata.operation)
            LWU:        result_o = shifted_data[31:0];
            LHU:        result_o = shifted_data[15:0];
            LBU:        result_o = shifted_data[7:0];
            LW:         result_o = 64'(signed'(shifted_data[31:0]));
            LH:         result_o = 64'(signed'(shifted_data[15:0]));
            LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
            default:    result_o = shifted_data;
        endcase
    end  */

  /*
  // BIG ENDIAN CAPABLE result mux
  // Can be used instead of the code below (in between "BIG ENDIAN CAPABLE result mux fast" and "end BIG ENDIAN CAPABLE result mux fast") if timing is not so critical.
  // This code has been tested and is functionally identical to "BIG ENDIAN CAPABLE result mux fast", and while commented out it still aids in the readability of load_unit.sv.
  always_comb begin
      unique case (ldbuf_rdata.operation)
          LWU:        result_o = 64'(unsigned'(mbe_i ? {<<8{shifted_data[31:0]}} : shifted_data[31:0]));
          LHU:        result_o = 64'(unsigned'(mbe_i ? {<<8{shifted_data[15:0]}} : shifted_data[15:0]));
          LBU:        result_o = 64'(unsigned'(shifted_data[7:0]));
          LW:         result_o = 64'(signed'(mbe_i ? {<<8{shifted_data[31:0]}} : shifted_data[31:0]));
          LH:         result_o = 64'(signed'(mbe_i ? {<<8{shifted_data[15:0]}} : shifted_data[15:0]));
          LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
          default:    result_o = mbe_i ? {<<8{shifted_data}} : shifted_data;
      endcase
  end
  */

  // BIG ENDIAN CAPABLE result mux fast
  logic [G6LCCfg.XLEN-1:0] endian_data;

  // Reversing the order of the Bytes in the data loaded from memory if mbe=1 -> which comes from the CSRregfile meaning the processor is in Big Endian Mode.
  // If mbe=1 then the processor should treat Data memory as Big Endian. The internals of G6LC are Little endian, so we achieve this by Reversing the Byte Order to Little Endian when it enters the processor through a Load.
  always_comb begin
    endian_data = shifted_data;
    if (mbe_i) begin
      case (load_operation)
        LB, LBU, HLV_B, HLV_BU, FLB: begin
          // If we are just loading a byte, then this needs not be touched
          endian_data[7:0] = {shifted_data[7:0]};
        end
        LH, LHU, HLV_H, HLV_HU, HLVX_HU, FLH: begin
          endian_data[15:0] = {<<8{shifted_data[15:0]}};
        end
        LW, LWU, HLV_W, HLV_WU, HLVX_WU, FLW, AMO_LRW, AMO_SCW, AMO_SWAPW, AMO_ADDW,
        AMO_ANDW, AMO_ORW, AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW, AMO_MINWU: begin
          endian_data[31:0] = {<<8{shifted_data[31:0]}};
        end
        default: begin
          endian_data[G6LCCfg.XLEN-1:0] = {<<8{shifted_data[G6LCCfg.XLEN-1:0]}};
        end
      endcase
    end
  end

  // result mux fast
  logic [        (G6LCCfg.XLEN/8)-1:0] rdata_sign_bits;
  logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] rdata_offset;
  logic rdata_sign_bit, rdata_is_signed, rdata_is_fp_signed;


  // prepare these signals for faster selection in the next cycle
  assign rdata_is_signed    =   load_operation inside {g6lc_core_pkg::LW,  g6lc_core_pkg::LH,  g6lc_core_pkg::LB, g6lc_core_pkg::HLV_W, g6lc_core_pkg::HLV_H, g6lc_core_pkg::HLV_B};
  assign rdata_is_fp_signed =   load_operation inside {g6lc_core_pkg::FLW, g6lc_core_pkg::FLH, g6lc_core_pkg::FLB};
  // If we are in Big Endian Mode, we don't need to add anything to the address offset to find the byte that contains the sign bit, as it is always the lowest addressed byte that has the sign bit.
  assign rdata_offset       = ((load_operation inside {g6lc_core_pkg::LW,  g6lc_core_pkg::FLW, g6lc_core_pkg::HLV_W}) && G6LCCfg.IS_XLEN64 && (~mbe_i)) ? load_addr_offset + 3 :
                                ( load_operation inside {g6lc_core_pkg::LH,  g6lc_core_pkg::FLH, g6lc_core_pkg::HLV_H} && (~mbe_i))                     ? load_addr_offset + 1 :
                                                                                                                         load_addr_offset;

  for (genvar i = 0; i < (G6LCCfg.XLEN / 8); i++) begin : gen_sign_bits
    assign rdata_sign_bits[i] = load_rdata[(i+1)*8-1];
  end


  // select correct sign bit in parallel to result shifter above
  // pull to 0 if unsigned
  assign rdata_sign_bit = (rdata_is_signed && rdata_sign_bits[rdata_offset]) || (G6LCCfg.FpPresent && rdata_is_fp_signed);

  // result mux
  always_comb begin
    unique case (load_operation)
      g6lc_core_pkg::LW, g6lc_core_pkg::LWU, g6lc_core_pkg::HLV_W, g6lc_core_pkg::HLV_WU, g6lc_core_pkg::HLVX_WU:
      result_o = {{G6LCCfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
      g6lc_core_pkg::LH, g6lc_core_pkg::LHU, g6lc_core_pkg::HLV_H, g6lc_core_pkg::HLV_HU, g6lc_core_pkg::HLVX_HU:
      result_o = {{G6LCCfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
      g6lc_core_pkg::LB, g6lc_core_pkg::LBU, g6lc_core_pkg::HLV_B, g6lc_core_pkg::HLV_BU:
      result_o = {{G6LCCfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
      default: begin
        // FLW, FLH and FLB have been defined here in default case to improve Code Coverage
        if (G6LCCfg.FpPresent) begin
          unique case (load_operation)
            g6lc_core_pkg::FLW: begin
              result_o = {{G6LCCfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
            end
            g6lc_core_pkg::FLH: begin
              result_o = {{G6LCCfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
            end
            g6lc_core_pkg::FLB: begin
              result_o = {{G6LCCfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
            end
            default: begin
              result_o = endian_data[G6LCCfg.XLEN-1:0];
            end
          endcase
        end else begin
          result_o = endian_data[G6LCCfg.XLEN-1:0];
        end
      end
    endcase
  end
  // end BIG ENDIAN CAPABLE result mux fast

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  initial begin
    assert (G6LCCfg.DcacheIdWidth >= REQ_ID_BITS)
    else $fatal(1, "DcacheIdWidth parameter is not wide enough to encode pending loads");
    assert (LU_B_IDLE == 0 && LU_B_WAIT_GNT == 1 && LU_B_SEND_TAG == 2
         && LU_B_WAIT_TRANSLATION == 6)
    else $fatal(1, "load_unit translation state bits drifted from the literals");
    assert (G6LCCfg.PLEN == 56 && G6LCCfg.VLEN >= 56)
    else $fatal(1, "load_unit physical-address bit mux is the hyp8 PLEN");
  end
  // True when this buffer entry is a misaligned load — mirrors the LSU's
  // data_misaligned_detection coverage (integer, FP and hypervisor loads).
  function automatic logic offset_misaligned(input g6lc_core_pkg::fu_op op,
                                             input logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] off);
    unique case (op)
      g6lc_core_pkg::LW, g6lc_core_pkg::LWU, g6lc_core_pkg::FLW,
      g6lc_core_pkg::HLV_W, g6lc_core_pkg::HLV_WU, g6lc_core_pkg::HLVX_WU:
        return off[1:0] != 2'b00;
      g6lc_core_pkg::LH, g6lc_core_pkg::LHU, g6lc_core_pkg::FLH,
      g6lc_core_pkg::HLV_H, g6lc_core_pkg::HLV_HU, g6lc_core_pkg::HLVX_HU:
        return off[0] != 1'b0;
      g6lc_core_pkg::LD, g6lc_core_pkg::FLD, g6lc_core_pkg::HLV_D:
        return G6LCCfg.IS_XLEN64 && |off;
      default:
        return 1'b0;
    endcase
  endfunction
  // A misaligned load is granted before its exception is known, so a
  // misaligned offset in the load buffer is legal. The contract is precise
  // delivery: the entry completes once, with the misaligned exception, and its
  // data return is killed rather than retired. The killed request is answered
  // by the data cache with a dummy rvalid in the kill cycle. Under address
  // translation the grant can precede a DTLB miss (T27, the Linux unaligned-
  // access probe right after satp was written): the request is then aborted
  // with a kill and no completion, the walk runs, and the re-issued load
  // delivers the exception -- so the cycle after the grant is either the
  // exception completion or the translation abort; misaligned_entry_no_data
  // keeps the "never retires data" half in both cases.
  misaligned_entry_excepts :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
      ldbuf_w && offset_misaligned(ldbuf_wdata.operation, ldbuf_wdata.address_offset)
      |=> (valid_o && ex_o.valid && ex_o.cause == riscv::LD_ADDR_MISALIGNED && req_port_o.kill_req) ||
          (req_port_o.kill_req && !valid_o &&
           (state_q[LU_B_ABORT_TRANSACTION] || state_q[LU_B_ABORT_TRANSACTION_NI] || state_q[LU_B_WAIT_FLUSH])))
  else $error("misaligned load buffer entry did not complete with LD_ADDR_MISALIGNED and a killed request");
  misaligned_entry_no_data :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
      ldbuf_r && valid_o && !ex_o.valid |-> !offset_misaligned(ldbuf_rdata.operation, ldbuf_rdata.address_offset))
  else $error("misaligned load buffer entry retired with data");
  misaligned_tval :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
      valid_o && ex_o.valid && ex_o.cause == riscv::LD_ADDR_MISALIGNED
      |-> (G6LCCfg.TvalEn ? ex_o.tval[G6LCCfg.XLEN_ALIGN_BYTES-1:0] != '0 : ex_o.tval == '0))
  else $error("misaligned load tval does not follow TvalEn");
  // A killed tag is always answered by a dummy rvalid for that same request —
  // the exception writeback relies on it to retire exactly once.
  send_tag_kill_rvalid :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
      (state_q[LU_B_SEND_TAG] && req_port_o.kill_req)
      |-> req_port_i.data_rvalid && (ldbuf_rindex == ldbuf_last_id_q))
  else $error("SEND_TAG kill without the matching dummy data_rvalid");
  //pragma translate_on

  // svt-stage: end L4
  // svt-stage: class L2 value
  // svt-stage: class L3 value
  // svt-stage: class L4 value
  // svt-stage: class L5 value

  //pragma translate_off
  // hyp8: verbatim pre-onehot load_control as the equivalence reference. The
  // encoded next-state rf_state_d must equal the one-hot state_d's encoding
  // every cycle; sideband outputs must match bit-for-bit.
  function automatic logic [3:0] lu_oh2enc(input logic [9:0] oh);
    lu_oh2enc = '0;
    for (int i = 0; i < 10; i++) if (oh[i]) lu_oh2enc |= 4'(i);
  endfunction
  logic [3:0] rf_state_q, rf_state_d;
  logic rf_translation_req_o, rf_pop_ld_o, rf_lu_replay_o, rf_st_fwd_done;
  dcache_req_i_t rf_req_port_o;

  always_comb begin : load_control_dec
    rf_state_q = lu_oh2enc(state_q);
  end
  always_comb begin : load_control_ref
    automatic logic accept_req;

    // default assignments
    rf_state_d              = rf_state_q;
    rf_translation_req_o    = 1'b0;
    rf_req_port_o.data_req  = 1'b0;
    // tag control
    rf_req_port_o.kill_req  = 1'b0;
    rf_req_port_o.tag_valid = 1'b0;
    rf_req_port_o.data_be   = lsu_ctrl_i.be;
    rf_req_port_o.data_size = extract_transfer_size(lsu_ctrl_i.operation);
    rf_pop_ld_o             = 1'b0;
    rf_lu_replay_o          = 1'b0;
    rf_st_fwd_done          = 1'b0;

    // In 4'(LU_B_IDLE) and 4'(LU_B_SEND_TAG) states, this unit can accept a new load request
    // when the load buffer is not full or if there is a response and the
    // load buffer is in fall-through mode
    accept_req           = valid_i && !ldbuf_full;

    case (rf_state_q)
      4'(LU_B_IDLE): begin
        if (accept_req) begin
          // start the translation process even though we do not know if the addresses match this should ease timing
          // don't start the translation for speculative loads that miss on tlb
          rf_translation_req_o = (!G6LCCfg.SpeculativeSb || dtlb_hit_i || !lsu_ctrl_i.is_speculative_load);
          // check if load is speculative and non idempotent, if it is then stall and wait for branch result
          if (!G6LCCfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load || (dtlb_hit_i && !paddr_ni)) begin
            // R3a: if STQ can fully satisfy this load, complete from forward
            // (no D$ request). Closes stack *nextoffset RAW without waiting for
            // STQ drain + wbuffer. Partial coverage still waits in 4'(LU_B_WAIT_PAGE_OFFSET).
            // R3a cont.4/5: wait until STQ + D$ wbuffer empty (unless forward).
            if (st_pipeline_busy) begin
              rf_state_d = 4'(LU_B_WAIT_PAGE_OFFSET); // hyp8: literal FSM target (svt balance-mux arm restored)
            end else if (page_offset_matches_i && st_fwd_covers && !req_port_i.data_rvalid &&
                         ld_checked_head) begin // hyp8: publish only verdict-final
              rf_state_d = 4'(LU_B_IDLE); // hyp8: literal FSM target (svt balance-mux arm restored)
              rf_pop_ld_o    = 1'b1;
              rf_st_fwd_done = 1'b1;
              // hyp8: a covered load whose verdict is not yet final waits
              // (forward data would otherwise be consumed unchecked); a
              // non-matching or unchecked-covered load still issues to D$.
            end else if (!page_offset_matches_i &&
                         !(st_fwd_covers && !ld_checked_head)) begin
              // make a load request to memory
              rf_req_port_o.data_req = 1'b1;
              // we got no data grant so wait for the grant before sending the tag
              if (!req_port_i.data_gnt) begin
                rf_state_d = 4'(LU_B_WAIT_GNT); // hyp8: literal FSM target (svt balance-mux arm restored)
              end else begin
                if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
                  rf_state_d = 4'(LU_B_ABORT_TRANSACTION); // hyp8: literal FSM target (svt balance-mux arm restored)
                end else begin
                  if (!stall_ni) begin
                    // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                    rf_state_d = 4'(LU_B_SEND_TAG); // hyp8: literal FSM target (svt balance-mux arm restored)
                    rf_pop_ld_o = 1'b1;
                    // translation valid but this is to NC and the WB is not yet empty.
                  end else if (G6LCCfg.NonIdemPotenceEn) begin
                    rf_state_d = 4'(LU_B_ABORT_TRANSACTION_NI);
                  end
                end
              end
            end else begin
              // wait for the store buffer to train and the page offset to not match anymore
              // (or until STQ forward fully covers)
              rf_state_d = 4'(LU_B_WAIT_PAGE_OFFSET); // hyp8: literal FSM target (svt balance-mux arm restored)
            end
          end else begin
            // check branch result on the next cycle
            rf_state_d = 4'(LU_B_WAIT_SPEC_LOAD); // hyp8: literal FSM target (svt balance-mux arm restored)
          end
        end
      end

      // wait here for the page offset to not match anymore
      4'(LU_B_WAIT_PAGE_OFFSET): begin
        // R3a: complete from STQ forward when bytes are fully covered
        // T39/T44: a covered load WAITS while the result port carries a D$
        // response (data_rvalid); it never falls through to the "re-issue to
        // D$" branch below. Pre-fix, st_pipeline_busy is 0 whenever the
        // forward covers, so one cycle of rvalid from an unrelated load sent
        // the covered load to 4'(LU_B_WAIT_GNT) and it read the line the store had not
        // reached yet (HPDCACHE: insert_header's `ld s8,56(s1)` 29 cycles
        // after its `sd`, the 2-hart server1 oops; the single-hart exec oops).
`ifdef G6LC_MUT_LU_FWD_RVALID_FALLTHROUGH
        if (st_fwd_covers && !req_port_i.data_rvalid &&
            ld_checked_head) begin   // review mutation: the pre-fix shape (+ hyp8 checked gate)
          rf_state_d     = 4'(LU_B_IDLE);
          rf_pop_ld_o    = 1'b1;
          rf_st_fwd_done = 1'b1;
`else
        if (st_fwd_covers && ld_checked_head) begin // hyp8: hold until verdict-final
          if (!req_port_i.data_rvalid) begin
            rf_state_d     = 4'(LU_B_IDLE);
            rf_pop_ld_o    = 1'b1;
            rf_st_fwd_done = 1'b1;
          end
`endif
        end else if (st_pipeline_busy && lu_replay_fire) begin
          // T33: the only store in the way is speculative and has not left in
          // WPO_REPLAY_AFTER cycles -- it is waiting on retirement, possibly on
          // an older load queued behind this one. Hand this load back: the
          // scoreboard cancels it and refetches from its PC at commit, by which
          // time the store has committed. Linux sched_clock_noinstr deadlock.
          rf_state_d     = 4'(LU_B_IDLE);
          rf_pop_ld_o    = 1'b1;
          rf_lu_replay_o = 1'b1;
        end else if (st_pipeline_busy) begin
          // hold until STQ + D$ wbuffer drain
          rf_state_d = 4'(LU_B_WAIT_PAGE_OFFSET);
        end else begin
          // No in-flight stores (or sticky match only): re-issue to D$
          rf_state_d = 4'(LU_B_WAIT_GNT);
        end
      end

      4'(LU_B_WAIT_SPEC_LOAD): begin
        // if we have a misspredicted speculative load
        if (G6LCCfg.SpeculativeSb && lsu_ctrl_i.is_speculative_load_miss) begin
          // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
          if (!req_port_i.data_rvalid) begin
            rf_state_d  = 4'(LU_B_IDLE);
            rf_pop_ld_o = 1'b1;
          end
          // if we have a correct prediction this is now a regular load
        end else begin
          rf_state_d = 4'(LU_B_IDLE);
        end
      end

      4'(LU_B_WAIT_GNT): begin
        // keep the translation request up
        rf_translation_req_o   = 1'b1;
        // keep the request up
        rf_req_port_o.data_req = 1'b1;
        // we finally got a data grant
        if (req_port_i.data_gnt) begin
          // so we send the tag in the next cycle
          if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
            rf_state_d = 4'(LU_B_ABORT_TRANSACTION); // hyp8: literal FSM target (svt balance-mux arm restored)
          end else begin
            if (!stall_ni) begin
              // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
              rf_state_d = 4'(LU_B_SEND_TAG); // hyp8: literal FSM target (svt balance-mux arm restored)
              rf_pop_ld_o = 1'b1;
              // translation valid but this is to NC and the WB is not yet empty.
            end else if (G6LCCfg.NonIdemPotenceEn) begin
              rf_state_d = 4'(LU_B_ABORT_TRANSACTION_NI);
            end
          end

        end
        // otherwise we keep waiting on our grant
      end
      // we know for sure that the tag we want to send is valid
      4'(LU_B_SEND_TAG): begin
        rf_req_port_o.tag_valid = 1'b1;
        rf_state_d = 4'(LU_B_IDLE);

        if (accept_req) begin
          // start the translation process even though we do not know if the addresses match this should ease timing
          // don't start the translation for speculative loads that miss on tlb
          rf_translation_req_o = (!G6LCCfg.SpeculativeSb || dtlb_hit_i || !lsu_ctrl_i.is_speculative_load);
          // check if load is speculative and non idempotent, if it is then stall and wait for branch result
          if (!G6LCCfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load || (dtlb_hit_i && !paddr_ni)) begin
            // check if the page offset matches with a store, if it does stall and wait
            // R3a: STQ forward path (mirror 4'(LU_B_IDLE))
            if (st_pipeline_busy) begin
              rf_state_d = 4'(LU_B_WAIT_PAGE_OFFSET); // hyp8: literal FSM target (svt balance-mux arm restored)
            end else if (page_offset_matches_i && st_fwd_covers && !req_port_i.data_rvalid &&
                         ld_checked_head) begin // hyp8: publish only verdict-final
              rf_state_d = 4'(LU_B_IDLE); // hyp8: literal FSM target (svt balance-mux arm restored)
              rf_pop_ld_o    = 1'b1;
              rf_st_fwd_done = 1'b1;
              // hyp8: a covered load whose verdict is not yet final waits
              // (forward data would otherwise be consumed unchecked); a
              // non-matching or unchecked-covered load still issues to D$.
            end else if (!page_offset_matches_i &&
                         !(st_fwd_covers && !ld_checked_head)) begin
              // make a load request to memory
              rf_req_port_o.data_req = 1'b1;
              // we got no data grant so wait for the grant before sending the tag
              if (!req_port_i.data_gnt) begin
                rf_state_d = 4'(LU_B_WAIT_GNT); // hyp8: literal FSM target (svt balance-mux arm restored)
              end else begin
                // we got a grant so we can send the tag in the next cycle
                if (G6LCCfg.MmuPresent && !dtlb_hit_i) begin
                  rf_state_d = 4'(LU_B_ABORT_TRANSACTION); // hyp8: literal FSM target (svt balance-mux arm restored)
                end else begin
                  if (!stall_ni) begin
                    // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                    rf_state_d = 4'(LU_B_SEND_TAG); // hyp8: literal FSM target (svt balance-mux arm restored)
                    rf_pop_ld_o = 1'b1;
                    // translation valid but this is to NC and the WB is not yet empty.
                  end else if (G6LCCfg.NonIdemPotenceEn) begin
                    rf_state_d = 4'(LU_B_ABORT_TRANSACTION_NI);
                  end
                end
              end
            end else begin
              // wait for the store buffer to train and the page offset to not match anymore
              rf_state_d = 4'(LU_B_WAIT_PAGE_OFFSET); // hyp8: literal FSM target (svt balance-mux arm restored)
            end
          end else begin
            // check branch result on the next cycle
            rf_state_d = 4'(LU_B_WAIT_SPEC_LOAD); // hyp8: literal FSM target (svt balance-mux arm restored)
          end
        end
        // ----------
        // Exception
        // ----------
        // N1d: ex_i (g6lc_mmu_exception) is shared between LSU requesters.
        // A registered-path exception (misaligned, permission, PMP) at
        // 4'(LU_B_SEND_TAG) is this load's own fault and kills the tag as upstream did.
        // A PTW-broadcast exception (ex_ptw_i) belongs to a different walk —
        // this load already resolved its translation — so it must not kill a
        // surviving load's tag; that would drop it silently: no result, no
        // phys_valid, no cancel — phys_pending then masks the commit head
        // forever. Flush/cancel still kill: the entry is being squashed.
`ifdef G6LC_MUT_LSU_EXKILL
        // MUTANT: unconditional kill on any shared exception (drops live loads)
        if (ex_i.valid) begin
          rf_req_port_o.kill_req = 1'b1;
        end
`else
        if (ex_i.valid && (!ex_ptw_i || flush_i ||
                           cancelled_mask_i[ldbuf_q[ldbuf_last_id_q].trans_id])) begin
          rf_req_port_o.kill_req = 1'b1;
        end
`endif
      end

      4'(LU_B_WAIT_FLUSH): begin
        // the D$ arbiter will take care of presenting this to the memory only in case we
        // have an outstanding request
        rf_req_port_o.kill_req = 1'b1;
        rf_req_port_o.tag_valid = 1'b1;
        // we've killed the current request so we can go back to idle
        rf_state_d = 4'(LU_B_IDLE);
      end

      default: begin
        // abort the previous request - free the D$ arbiter
        // we are here because of a TLB miss, we need to abort the current request and give way for the
        // PTW walker to satisfy the TLB miss
        if (rf_state_q == 4'(LU_B_ABORT_TRANSACTION) && G6LCCfg.MmuPresent) begin
          rf_req_port_o.kill_req = 1'b1;
          rf_req_port_o.tag_valid = 1'b1;
          // wait until the WB is empty
          rf_state_d = 4'(LU_B_WAIT_TRANSLATION);
        end else if (rf_state_q == 4'(LU_B_ABORT_TRANSACTION_NI) && G6LCCfg.NonIdemPotenceEn) begin
          rf_req_port_o.kill_req = 1'b1;
          rf_req_port_o.tag_valid = 1'b1;
          // re-do the request
          rf_state_d = 4'(LU_B_WAIT_WB_EMPTY);
        end else if (rf_state_q == 4'(LU_B_WAIT_WB_EMPTY) && G6LCCfg.NonIdemPotenceEn && dcache_wbuffer_not_ni_i) begin
          // Wait until the write-back buffer is empty in the data cache.
          // the write buffer is empty, so let's go and re-do the translation.
          rf_state_d = 4'(LU_B_WAIT_TRANSLATION);
        end else if(rf_state_q == 4'(LU_B_WAIT_TRANSLATION) && (G6LCCfg.MmuPresent || G6LCCfg.NonIdemPotenceEn)) begin
          rf_translation_req_o = 1'b1;
          // we've got a hit and we can continue with the request process
          if (dtlb_hit_i) rf_state_d = 4'(LU_B_WAIT_GNT);

          // we got an exception
          if (ex_i.valid) begin
            // the next state will be the idle state
            rf_state_d  = 4'(LU_B_IDLE);
            // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
            rf_pop_ld_o = ~req_port_i.data_rvalid;
          end
        end else begin
          rf_state_d = 4'(LU_B_IDLE);
        end
      end
    endcase

    if (cancelled_request) begin
      rf_req_port_o.data_req = 1'b0;
      rf_translation_req_o = 1'b0;
      rf_st_fwd_done = 1'b0;
      rf_pop_ld_o = 1'b1;
      rf_state_d = 4'(LU_B_IDLE);
    end

    // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in an extra stage
    if (flush_i) begin
      rf_state_d = 4'(LU_B_WAIT_FLUSH);
    end
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot(state_q))
    else $fatal(1, "load_unit hyp8 one-hot FSM: state_q not one-hot");
  assert property (@(posedge clk_i) disable iff (!rst_ni) state_d == (10'(1) << rf_state_d))
    else $fatal(1, "load_unit hyp8 one-hot FSM next-state mismatch");
  assert property (@(posedge clk_i) disable iff (!rst_ni) rf_translation_req_o == translation_req_o)
    else $fatal(1, "load_unit hyp8 translation_req_o mismatch");
  // req_port_o is partly continuous-assign (data_we/data_wdata/cbo_op/
  // address_*/data_id/data_wuser at the module level) — the reference comb
  // only covers the FSM-owned fields, so the compare is field-scoped.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   rf_req_port_o.data_req  == req_port_o.data_req  &&
                   rf_req_port_o.kill_req  == req_port_o.kill_req  &&
                   rf_req_port_o.tag_valid == req_port_o.tag_valid &&
                   rf_req_port_o.data_be   == req_port_o.data_be   &&
                   rf_req_port_o.data_size == req_port_o.data_size)
    else $fatal(1, "load_unit hyp8 req_port_o mismatch");
  assert property (@(posedge clk_i) disable iff (!rst_ni) rf_pop_ld_o == pop_ld_o)
    else $fatal(1, "load_unit hyp8 pop_ld_o mismatch");
  assert property (@(posedge clk_i) disable iff (!rst_ni) rf_lu_replay_o == lu_replay_o)
    else $fatal(1, "load_unit hyp8 lu_replay_o mismatch");
  assert property (@(posedge clk_i) disable iff (!rst_ni) rf_st_fwd_done == st_fwd_done)
    else $fatal(1, "load_unit hyp8 st_fwd_done mismatch");
  //pragma translate_on

endmodule
