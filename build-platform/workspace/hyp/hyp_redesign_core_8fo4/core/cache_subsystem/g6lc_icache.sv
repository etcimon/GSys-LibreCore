// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
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
// Modified by: Etienne Cimon
// Date: 15.08.2018
// Description: Instruction cache that is compatible with openpiton.
// U3: optional MRU way prediction for data-array chip-enable energy.
//
// Some notes:
//
// 1) refills always have the size of one cache line, except for accesses to the I/O region, which is mapped
//    to the top half of the physical address space (bit 39 = 1). the data width of the interface has the width
//    of one cache line, and hence the ifills can be transferred in a single cycle. note that the ifills must be
//    consumed unconditionally.
//
// 2) instruction fetches are always assumed to be aligned to 32bit (lower 2 bits are ignored)
//
// 3) NC accesses to I/O space are expected to return 32bit from memory.
//

// ---- Licensing provenance (see LICENSE, LICENSE.CERN-OHL-S, NOTICE) --------
// The original work of the copyright holders named above remains licensed
// under the license stated above, and that grant is unaffected.
// Modifications (c) 2026 Etienne Cimon: way prediction, RRIP replacement and coherent invalidation support.
// The upstream notice above is prose and declares no SPDX identifier, so the
// outbound offer is stated here as the file's single SPDX tag. See REUSE.toml.
// Etienne Cimon offers this file AS A WHOLE under:
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial


module g6lc_icache
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type icache_areq_t = logic,
    parameter type icache_arsp_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic,
    parameter type icache_req_t = logic,
    parameter type icache_rtrn_t = logic,
    /// ID to be used for read transactions
    parameter logic [G6LCCfg.MEM_TID_WIDTH-1:0] RdTxId = '0
) (
    input logic clk_i,
    input logic rst_ni,
    /// reset value for the in-flight virtual fetch address
    input logic [G6LCCfg.VLEN-1:0] boot_addr_i,

    /// flush the icache, flush and kill have to be asserted together
    input  logic         flush_i,
    /// enable icache
    input  logic         en_i,
    /// to performance counter
    output logic         miss_o,
    // address translation requests
    input  icache_areq_t areq_i,
    output icache_arsp_t areq_o,
    // data requests
    input  icache_dreq_t dreq_i,
    output icache_drsp_t dreq_o,
    // refill port
    input  logic         mem_rtrn_vld_i,
    input  icache_rtrn_t mem_rtrn_i,
    output logic         mem_data_req_o,
    input  logic         mem_data_ack_i,
    output icache_req_t  mem_data_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_icache status=proposal target=10-adjusted-FO4
  // svt-plan: cone translated tag/hit selection feeds response, miss request
  // and next-state decisions; response token already identifies fetch ownership.
  // svt-plan: boundary bank tag/data read -> registered hit/miss descriptor
  // -> response or MSHR issue; precompute independent PMA/NC attributes.
  // svt-plan: carry token, VA/PA, tag/offset, selected data, exception,
  // cacheability and invalidation epoch through the same descriptor.
  // svt-plan: conflict kill stale responses and suppress refills invalidated
  // after lookup; a held miss cannot issue twice when memory is backpressured.
  // svt-plan: effect separates way compare from word selection and miss
  // arbitration; banking limits per-stage fanout instead of copying a global mux.
  // svt-plan: cost response/miss slots and fetch-hit latency; early fetch
  // prediction must cover the delay and reserve space for returning windows.
  // svt-plan: limit flush sweep, translation ownership and NC fetch behavior
  // stay synchronized; dreq ready is a capacity promise, not a delayed hint.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 52.5 adjusted FO4 on the
  // Nangate45 board): instruction cache: tag compare and fill FSM.
  // svt-pipe: require-contract
  // svt-pipe: protocol ic valid=en_i flush=flush_i
  // svt-pipe: no-cut on=cl_tag_q
  // svt-pipe: cycle ic q=cl_tag_q d=miss_o hold=en_i steps=1

  localparam ICACHE_OFFSET_WIDTH = $clog2(G6LCCfg.ICACHE_LINE_WIDTH / 8);
  localparam ICACHE_NUM_WORDS = 2 ** (G6LCCfg.ICACHE_INDEX_WIDTH - ICACHE_OFFSET_WIDTH);
  localparam ICACHE_CL_IDX_WIDTH = $clog2(ICACHE_NUM_WORDS);  // excluding byte offset

  // functions
  function automatic logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] icache_way_bin2oh(
      input logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] in);
    logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  // signals
  logic cache_en_d, cache_en_q;  // cache is enabled
  logic [G6LCCfg.VLEN-1:0] vaddr_d, vaddr_q;
  logic paddr_is_nc;  // asserted if physical address is non-cacheable
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] cl_hit;  // hit from tag compare
  logic cache_rden;  // triggers cache lookup
  logic cache_wren;  // triggers write to cacheline
  logic
      cmp_en_d,
      cmp_en_q;  // enable tag comparison in next cycle. used to cut long path due to NC signal.
  logic flush_d, flush_q;  // used to register and signal pending flushes

  // replacement strategy
  logic                                      update_lfsr;  // shift the LFSR
  logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] inv_way;  // first non-valid encountered
  logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] rnd_way;  // random index for replacement
  logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] repl_way;  // way to replace
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] repl_way_oh_d, repl_way_oh_q;  // way to replace (onehot)
  logic all_ways_valid;  // we need to switch repl strategy since all are valid

  // invalidations / flushing
  logic inv_en;  // incoming invalidations
  logic inv_d, inv_q;  // invalidation in progress
  logic flush_en, flush_done;  // used to flush cache entries
  logic [ICACHE_CL_IDX_WIDTH-1:0] flush_cnt_d, flush_cnt_q;  // used to flush cache entries

  // U3 way prediction (declared early: FSM + cl_req both use these)
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] way_pred_oh;
  logic                                way_pred_match;
  logic                                force_all_ways_d, force_all_ways_q;
  logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] way_pred_bin;
  logic [G6LCCfg.ICACHE_SET_ASSOC_WIDTH-1:0] hit_idx;

  // mem arrays
  logic                                cl_we;  // write enable to memory array
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] cl_req;  // request to memory array
  logic [     ICACHE_CL_IDX_WIDTH-1:0] cl_index;  // this is a cache-line index, to memory array
  logic [ICACHE_OFFSET_WIDTH-1:0] cl_offset_d, cl_offset_q;  // offset in cache line
  logic [G6LCCfg.ICACHE_TAG_WIDTH-1:0] cl_tag_d, cl_tag_q;  // this is the cache tag
  logic [G6LCCfg.ICACHE_TAG_WIDTH-1:0]          cl_tag_rdata [G6LCCfg.ICACHE_SET_ASSOC-1:0]; // these are the tags coming from the tagmem
  logic [G6LCCfg.ICACHE_LINE_WIDTH-1:0]         cl_rdata     [G6LCCfg.ICACHE_SET_ASSOC-1:0]; // these are the cachelines coming from the cache
  logic [G6LCCfg.ICACHE_USER_LINE_WIDTH-1:0]    cl_ruser[G6LCCfg.ICACHE_SET_ASSOC-1:0]; // these are the cachelines coming from the user cache
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0][G6LCCfg.FETCH_WIDTH-1:0] cl_sel;  // selected word from each cacheline
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0][G6LCCfg.FETCH_USER_WIDTH-1:0] cl_user;  // selected word from each cacheline
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] vld_req;  // bit enable for valid regs
  logic vld_we;  // valid bits write enable
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] vld_wdata;  // valid bits to write
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] vld_rdata;  // valid bits coming from valid regs
  logic [ICACHE_CL_IDX_WIDTH-1:0] vld_addr;  // valid bit

  // cpmtroller FSM
  typedef enum logic [2:0] {
    FLUSH,
    IDLE,
    READ,
    READ_V,    // hyp8: response presentation, +1 behind the token echo
    MISS,
    KILL_ATRANS,
    KILL_MISS
  } state_e;
  state_e state_d, state_q;

  // hyp8: icache response staging. The tag compare and way-hit select run
  // in READ against the SRAM outputs; the response record (selected data,
  // user word, fetch exception) registers at the verdict edge and READ_V
  // presents valid/data one cycle later, behind the same 2-bit token the
  // request echoed at accept — the frontend consumes the response only on
  // a matching token, so the added cycle cannot mispair streams.
  logic [G6LCCfg.FETCH_WIDTH-1:0]      rsp_data_d, rsp_data_q;
  logic [G6LCCfg.FETCH_USER_WIDTH-1:0] rsp_user_d, rsp_user_q;
  logic [$bits(dreq_o.ex)-1:0]         rsp_ex_d, rsp_ex_q;
  logic [G6LCCfg.FETCH_WIDTH-1:0]      dreq_data_sel;
  logic [G6LCCfg.FETCH_USER_WIDTH-1:0] dreq_user_sel;

  ///////////////////////////////////////////////////////
  // address -> cl_index mapping, interface plumbing
  ///////////////////////////////////////////////////////

  // extract tag from physical address, check if NC
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_icache  region=4326  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: token_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to token_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     token_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14885 c=3.50 slack=1.00 */
//     /* node14886 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_icache  region=4351  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cache_en_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cache_en_q
// order expect: cl_offset_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cl_offset_q
// order expect: cl_tag_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cl_tag_q
// order expect: cmp_en_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cmp_en_q
// order expect: flush_cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_cnt_q
// order expect: flush_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_q
// order expect: force_all_ways_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to force_all_ways_q
// order expect: inv_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to inv_q
// order expect: repl_way_oh_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to repl_way_oh_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: vaddr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vaddr_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cache_en_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cl_offset_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cl_tag_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cmp_en_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_q <= …; // sv-timing: cycle 1/1 on clk_i
//     force_all_ways_q <= …; // sv-timing: cycle 1/1 on clk_i
//     inv_q <= …; // sv-timing: cycle 1/1 on clk_i
//     repl_way_oh_q <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     vaddr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14966 c=3.50 slack=0.00 */
//     /* node14967 c=3.50 slack=0.00 */
//     /* node14968 c=3.50 slack=0.00 */
//     /* node14969 c=3.50 slack=0.00 */
//     /* node14970 c=3.50 slack=0.00 */
//     /* node14971 c=3.50 slack=0.00 */
//     /* node14972 c=3.50 slack=0.00 */
//     /* node14973 c=3.50 slack=0.00 */
//     /* node14974 c=3.50 slack=0.00 */
//     /* node14975 c=3.50 slack=0.00 */
//     /* node14976 c=3.50 slack=0.00 */
//     /* node14977 c=3.50 slack=0.00 */
//     /* node14978 c=3.50 slack=0.00 */
//     /* node14979 c=3.50 slack=0.00 */
//     /* node14980 c=3.50 slack=0.00 */
//     /* node14981 c=3.50 slack=0.00 */
//     /* node14982 c=3.50 slack=0.00 */
//     /* node14983 c=3.50 slack=0.00 */
//     /* node14984 c=3.50 slack=0.00 */
//     /* node14985 c=3.50 slack=0.00 */
//     /* node14986 c=3.50 slack=0.00 */
//     /* node14987 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign cl_tag_d  = (areq_i.fetch_valid) ? areq_i.fetch_paddr[G6LCCfg.ICACHE_TAG_WIDTH+G6LCCfg.ICACHE_INDEX_WIDTH-1:G6LCCfg.ICACHE_INDEX_WIDTH] : cl_tag_q;

  // noncacheable if request goes to I/O space, or if cache is disabled
  // This decode gates the hit/bypass decision, so it sits on the critical
  // path out of the tag compare; sv-timing stages it in the corrected build.
  assign paddr_is_nc = (~cache_en_q) | (~config_pkg::is_inside_cacheable_regions(
      G6LCCfg, {{64 - G6LCCfg.PLEN{1'b0}}, cl_tag_d, {G6LCCfg.ICACHE_INDEX_WIDTH{1'b0}}}
  ));

  // pass exception through
  // hyp8: in READ_V the exception rides the registered response record.
  assign dreq_o.ex = (state_q == READ_V) ? rsp_ex_q : areq_i.fetch_exception;

  // Same accept as dreq_o.ready: IDLE when not flushing or blocked on an
  // inval return, and READ_V when the stream is not killed. Named here so
  // the address mux does not wait on the FSM procedure. The port ready
  // is still that procedure, and it matches this expression.
  logic fetch_accept;
  logic acc0, acc1, acc2, acc3;
  logic [63:0] vaddr_bits;
  assign fetch_accept =
      ((state_q == IDLE) && !((flush_q | flush_i) || (en_i && !cache_en_q)) && !mem_rtrn_vld_i) ||
      ((state_q == READ_V) && ~dreq_i.kill_s1 && ~dreq_i.kill_s2);
  assign acc0 = fetch_accept & dreq_i.req;
  assign acc1 = fetch_accept & dreq_i.req;
  assign acc2 = fetch_accept & dreq_i.req;
  assign acc3 = fetch_accept & dreq_i.req;
  for (genvar b = 0; b < 64; b++) begin : gen_vaddr
    if (b < 16) begin : gen_b0
      assign vaddr_bits[b] = acc0 ? dreq_i.vaddr[b] : vaddr_q[b];
    end else if (b < 32) begin : gen_b1
      assign vaddr_bits[b] = acc1 ? dreq_i.vaddr[b] : vaddr_q[b];
    end else if (b < 48) begin : gen_b2
      assign vaddr_bits[b] = acc2 ? dreq_i.vaddr[b] : vaddr_q[b];
    end else begin : gen_b3
      assign vaddr_bits[b] = acc3 ? dreq_i.vaddr[b] : vaddr_q[b];
    end
  end
  assign vaddr_d = vaddr_bits;
  // pragma translate_off
  initial assert (G6LCCfg.VLEN == 64);
  // pragma translate_on
  // I4xi: use the latched request address (vaddr_q) for tag compare, MMU/PMP
  // request, and I$ response vaddr. vaddr_d is the next address before it has
  // been registered; using it for compare/ready created a Verilator
  // active-region convergence loop:
  //   vaddr_d -> cl_index -> cl_hit -> dreq_o.ready -> vaddr_d -> ...
  // This makes the I$ a two-cycle hit (request in IDLE, hit in READ).
  assign areq_o.fetch_vaddr = (vaddr_q >> G6LCCfg.FETCH_ALIGN_BITS) << G6LCCfg.FETCH_ALIGN_BITS;

  // split virtual address into index and offset to address cache arrays
  //
  // I4xk: this MUST be vaddr_d, not vaddr_q. The array read (`cache_rden`) is
  // launched in IDLE, in the same cycle the request arrives, but `vaddr_d` only
  // becomes `vaddr_q` at the next edge -- so indexing with vaddr_q reads the
  // PREVIOUS request's line while READ then compares and returns it as the
  // current one. ICACHE_OFFSET_WIDTH is $clog2(128/8)=4 here, so bit 4 is the
  // line-index LSB and the resulting skew is exactly one cache line: the core is
  // handed the bytes from `addr - 0x10`. That is an I1/I2 violation (decode is a
  // function of bytes and address alone) and it made the machine execute
  // instructions offset from its own PC -- observed as `csrw mtvec` never
  // executing, so traps vectored to the reset vector instead of the handler.
  //
  // Using vaddr_d here does NOT reinstate the convergence loop that I4xi was
  // added to break. That loop was
  //     vaddr_d -> cl_index -> cl_hit -> dreq_o.ready -> vaddr_d
  // and I4xj already cut its `cl_hit -> ready` edge by removing `dreq_o.ready`
  // from the READ hit branch; in IDLE `dreq_o.ready` is an unconditional 1'b1
  // that does not depend on cl_hit. With that edge gone the index no longer
  // participates in any cycle, so the correct address can be used again.
  // `cl_offset_d` (the word-within-line select) already keys off `dreq_i.vaddr`,
  // i.e. the same arriving address, so index and offset are now consistent:
  // read in IDLE with the arriving address, compare and respond in READ with
  // that same address once latched.
  assign cl_index = vaddr_d[G6LCCfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH];


  if (G6LCCfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_offset
    // if we generate a noncacheable access, the word will be at offset 0 or 4 in the cl coming from memory
    assign cl_offset_d = ( fetch_accept & dreq_i.req)      ? ICACHE_OFFSET_WIDTH'((dreq_i.vaddr >> G6LCCfg.FETCH_ALIGN_BITS) << G6LCCfg.FETCH_ALIGN_BITS) :
                         ( paddr_is_nc  & mem_data_req_o ) ? {{ICACHE_OFFSET_WIDTH-3{1'b0}}, cl_offset_q[2], 2'b0} : // needed since we transfer 32bit over a 64bit AXI bus in this case
        cl_offset_q;
    // request word address instead of cl address in case of NC access
    assign mem_data_o.paddr = (paddr_is_nc) ? {cl_tag_d, vaddr_q[G6LCCfg.ICACHE_INDEX_WIDTH-1:3], 3'b0} :                                         // align to 64bit
        {cl_tag_d, vaddr_q[G6LCCfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH], {ICACHE_OFFSET_WIDTH{1'b0}}}; // align to cl
  end else begin : gen_piton_offset
    // icache fills are either cachelines or 4byte fills, depending on whether they go to the Piton I/O space or not.
    // since the piton cache system replicates the data, we can always index the full CL
    assign cl_offset_d = (fetch_accept & dreq_i.req) ? {dreq_i.vaddr >> 2, 2'b0} : cl_offset_q;

    // request word address instead of cl address in case of NC access
    assign mem_data_o.paddr = (paddr_is_nc) ? {cl_tag_d, vaddr_q[G6LCCfg.ICACHE_INDEX_WIDTH-1:2], 2'b0} :                                         // align to 32bit
        {cl_tag_d, vaddr_q[G6LCCfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH], {ICACHE_OFFSET_WIDTH{1'b0}}}; // align to cl
  end


  assign mem_data_o.tid = RdTxId;

  assign mem_data_o.nc  = paddr_is_nc;
  // way that is being replaced
  assign mem_data_o.way = repl_way;
  // present the latched request address (vaddr_q) on the response interface.
  // vaddr_d is the next un-registered address; using it for the response
  // mis-associates data with an un-served request and feeds a combinational
  // loop through the branch-predictor same-window check.
  assign dreq_o.vaddr   = vaddr_q;

  // Echo the accepted request's ownership token on the response so the
  // frontend can distinguish a stale return from a same-address refetch.
  logic [1:0] token_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      token_q <= '0;
    end else if (fetch_accept & dreq_i.req) begin
      token_q <= dreq_i.token;
    end
  end
  assign dreq_o.token   = token_q;

  // invalidations take two cycles
  assign inv_d          = inv_en;

  ///////////////////////////////////////////////////////
  // main control logic
  ///////////////////////////////////////////////////////
  logic addr_ni;
  assign addr_ni = config_pkg::is_inside_nonidempotent_regions(
      G6LCCfg, {{64 - G6LCCfg.PLEN{1'b0}}, areq_i.fetch_paddr}
  );
  // Refill request used to be assigned inside the READ miss else-if, so the
  // whole hit/miss priority landed on that 1-bit. Same cycle as before.
  logic fetch_ok, hit_arm, read_miss_arm;
  assign fetch_ok = areq_i.fetch_valid &&
      (!dreq_i.spec || ((G6LCCfg.NonIdemPotenceEn && !addr_ni) || !G6LCCfg.NonIdemPotenceEn));
  assign hit_arm = (((|cl_hit) && cache_en_q) || areq_i.fetch_exception.valid) && !inv_q;
  assign read_miss_arm = (state_q == READ) && fetch_ok && !(flush_q | flush_i) && !hit_arm &&
                         !dreq_i.kill_s2 && !inv_q;
  assign mem_data_req_o = read_miss_arm;

  always_comb begin : p_fsm
    // default assignment
    state_d = state_q;
    cache_en_d   = cache_en_q & en_i;// disabling the cache is always possible, enable needs to go via flush
    flush_en = 1'b0;
    cmp_en_d = 1'b0;
    cache_rden = 1'b0;
    cache_wren = 1'b0;
    inv_en = 1'b0;
    flush_d = flush_q | flush_i;  // register incoming flush
    force_all_ways_d = 1'b0;

    // interfaces
    dreq_o.ready = 1'b0;
    areq_o.fetch_req = 1'b0;
    dreq_o.valid = 1'b0;
    // mem_data_req_o is the continuous assign below.
    // performance counter
    miss_o = 1'b0;
    // hyp8: response record holds by default
    rsp_data_d = rsp_data_q;
    rsp_user_d = rsp_user_q;
    rsp_ex_d   = rsp_ex_q;

    // handle invalidations unconditionally
    // note: invals are mutually exclusive with
    // ifills, since both arrive over the same IF
    // however, we need to make sure below that we
    // do not trigger a cache readout at the same time...
    if (mem_rtrn_vld_i && mem_rtrn_i.rtype == ICACHE_INV_REQ) begin
      inv_en = 1'b1;
    end

    unique case (state_q)
      //////////////////////////////////
      // this clears all valid bits
      FLUSH: begin
        flush_en = 1'b1;
        if (flush_done) begin
          state_d = IDLE;
          flush_d = 1'b0;
          // if the cache was not enabled set this
          cache_en_d = en_i;
        end
      end
      //////////////////////////////////
      // wait for an incoming request
      IDLE: begin
        // only enable tag comparison if cache is enabled
        cmp_en_d = cache_en_q;

        // handle pending flushes, or perform cache clear upon enable
        if (flush_d || (en_i && !cache_en_q)) begin
          state_d = FLUSH;
          // wait for incoming requests
        end else begin
          // mem requests are for sure invals here
          if (!mem_rtrn_vld_i) begin
            dreq_o.ready = 1'b1;
            // we have a new request
            if (dreq_i.req) begin
              cache_rden = 1'b1;
              state_d    = READ;
            end
          end
          if (dreq_i.kill_s1) begin
            state_d = IDLE;
          end
        end
      end
      //////////////////////////////////
      // check whether we have a hit
      // in case the cache is disabled,
      // or in case the address is NC, we
      // reuse the miss mechanism to handle
      // the request
      READ: begin
        areq_o.fetch_req = '1;
        // only enable tag comparison if cache is enabled
        cmp_en_d    = cache_en_q;
        // readout speculatively
        cache_rden  = cache_en_q;

        if (areq_i.fetch_valid && (!dreq_i.spec || ((G6LCCfg.NonIdemPotenceEn && !addr_ni) || (!G6LCCfg.NonIdemPotenceEn)))) begin
          // check if we have to flush
          if (flush_d) begin
            state_d = IDLE;
            // we have a hit or an exception output valid result
          end else if (((|cl_hit && cache_en_q) || areq_i.fetch_exception.valid) && !inv_q) begin
            // U3 way-pred: if the hit is not in the predicted way and we only
            // fetched that way, re-read all ways for one cycle (energy trade).
            if (G6LCCfg.WayPredEn && G6LCCfg.ICACHE_SET_ASSOC > 1 && |cl_hit &&
                !way_pred_match && !force_all_ways_q && !areq_i.fetch_exception.valid) begin
              force_all_ways_d = 1'b1;
              cache_rden       = 1'b1;
              cmp_en_d         = 1'b1;
              state_d          = READ;
            end else begin
              // hyp8: capture the response record (the comb-selected data and
              // user word for the hit way plus the fetch exception); the
              // tag compare ran this cycle, the way/data select registers
              // here and READ_V presents it +1 behind the token. A killed
              // stream skips the response cycle entirely, as before.
              rsp_data_d = dreq_data_sel;
              rsp_user_d = dreq_user_sel;
              rsp_ex_d   = $bits(rsp_ex_d)'(areq_i.fetch_exception);
              state_d      = (dreq_i.kill_s1) ? IDLE : READ_V;
              force_all_ways_d = 1'b0;
            end
            // we have a miss / NC transaction
          end else if (dreq_i.kill_s2) begin
            state_d = IDLE;
          end else if (!inv_q) begin
            cmp_en_d = 1'b0;
            // only count this as a miss if the cache is enabled, and
            // the address is cacheable
            // send out ifill request
            // refill request is read_miss_arm, outside this case.
            if (mem_data_ack_i) begin
              miss_o  = ~paddr_is_nc;
              state_d = MISS;
            end
          end
          // bail out if this request is being killed (and we missed on the TLB)
        end else if (dreq_i.kill_s2 || flush_d) begin
          state_d = KILL_ATRANS;
        end
      end
      //////////////////////////////////
      // hyp8: present the registered hit response (+1 behind the request's
      // 2-bit token). This is the emit's hit-response cycle moved one stage
      // later — the W1 request/response overlap accept lives here now, so a
      // hit can still admit the next lookup in the response cycle.
      READ_V: begin
        areq_o.fetch_req = '1;
        cmp_en_d         = cache_en_q;
        cache_rden       = cache_en_q;
        dreq_o.valid     = ~dreq_i.kill_s1;  // don't output on flush/misp/replay
        state_d          = IDLE;

        // W1: request/response overlap. A hit-response cycle may also
        // accept the next request: `cl_index` already keys off `vaddr_d`,
        // which carries the arriving address while `ready & req`, so the
        // accepted request's array read is launched in this same cycle
        // and its verdict returns in READ next cycle. In the staged design
        // `ready` no longer reads `cl_hit` — it is a function of this state
        // and the kill pins only, which keeps the I4xi/I4xj feedback cut.
        //
        // Killed streams are not accepted: on kill_s1/kill_s2 the offered
        // address belongs to a dying or redirected stream, so the requester
        // re-offers in IDLE next cycle.
        if (~dreq_i.kill_s1 & ~dreq_i.kill_s2) begin
          dreq_o.ready = 1'b1;
          if (dreq_i.req) begin
            state_d = READ;
          end
        end
      end
      //////////////////////////////////
      // wait until the memory transaction
      // returns. do not write to memory
      // if the nc bit is set.
      MISS: begin
        // note: this is mutually exclusive with ICACHE_INV_REQ,
        // so we do not have to check for invals here
        if (mem_rtrn_vld_i && mem_rtrn_i.rtype == ICACHE_IFILL_ACK) begin
          state_d = IDLE;
          // I4xj: do not gate refill return on bp_fire (kill_s2); that creates
          // a combinational loop through the frontend branch predictor.
          // bp_pend_q / same_win already drops fall-through returns after a
          // taken branch. Cancel only on architectural kills (flush/misp/replay).
          if (!(dreq_i.kill_s1 || flush_d)) begin
            dreq_o.valid = 1'b1;
          end
          // T17: install the line even when the requester killed the stream
          // (mispredict, SMT hart switch). The refill is current memory for a
          // cacheable address, so keeping it is always safe; dropping it let
          // two harts whose I$ miss latency exceeds the starve-switch cadence
          // kill each other's refill forever (g6lc64_ooo_server after
          // OpenSBI's fence.i: no hart fetched again for 18 M cycles). Only a
          // pending I$ flush (fence.i semantics) forbids the install.
          cache_wren = ~paddr_is_nc & ~flush_d;
          // bail out if this request is being killed
        end else if (dreq_i.kill_s1 || flush_d) begin
          state_d = KILL_MISS;
        end
      end
      //////////////////////////////////
      // killed address translation,
      // wait until paddr is valid, and go
      // back to idle
      KILL_ATRANS: begin
        areq_o.fetch_req = '1;
        if (areq_i.fetch_valid) begin
          state_d = IDLE;
        end
      end
      //////////////////////////////////
      // killed miss,
      // wait until memory responds and
      // go back to idle
      KILL_MISS: begin
        if (mem_rtrn_vld_i && mem_rtrn_i.rtype == ICACHE_IFILL_ACK) begin
          state_d = IDLE;
          // T17: same as MISS — the killed stream's line is still worth
          // installing unless an I$ flush is pending (flush_d is sticky until
          // the FLUSH state performs it, so it covers a fence.i that arrived
          // anywhere during the miss).
          cache_wren = ~paddr_is_nc & ~flush_d;
        end
      end
      default: begin
        // we should never get here
        state_d = FLUSH;
      end
    endcase  // state_q
  end

  ///////////////////////////////////////////////////////
  // valid bit invalidation and replacement strategy
  ///////////////////////////////////////////////////////

  // note: it cannot happen that we get an invalidation + a cl replacement
  // in the same cycle as these requests arrive via the same interface
  // flushes take precedence over invalidations (it is ok if we ignore
  // the inval since the cache is cleared anyway)

  assign flush_cnt_d = (flush_done) ? '0 : (flush_en) ? flush_cnt_q + 1 : flush_cnt_q;

  assign flush_done = (flush_cnt_q == (ICACHE_NUM_WORDS - 1));

  // invalidation/clearing address
  // flushing takes precedence over invals
  assign vld_addr = (flush_en)       ? flush_cnt_q        :
                    (inv_en)         ? mem_rtrn_i.inv.idx[G6LCCfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH] :
                                       cl_index;

  assign vld_req  = (flush_en || cache_rden)        ? '1                                    :
                    (mem_rtrn_i.inv.all && inv_en)  ? '1                                    :
                    (mem_rtrn_i.inv.vld && inv_en)  ? icache_way_bin2oh(
      mem_rtrn_i.inv.way
  ) : repl_way_oh_q;

  assign vld_wdata = (cache_wren) ? '1 : '0;

  assign vld_we = (cache_wren | inv_en | flush_en);
  // assign vld_req   = (vld_we | cache_rden);


  // chose random replacement if all are valid
  assign update_lfsr = cache_wren & all_ways_valid;
  assign repl_way = (all_ways_valid) ? rnd_way : inv_way;
  assign repl_way_oh_d = (cmp_en_q) ? icache_way_bin2oh(repl_way) : repl_way_oh_q;

  // enable signals for memory arrays
  // U3: when WayPredEn, only chip-enable the predicted data way on first look-up
  // (tags still all-ways via vld_req). A way mispredict forces a full re-read.
  //
  // Index the predictor with *registered* vaddr_q (cl_index_q), not combo
  // vaddr_d. Tags under compare and train targets belong to the latched
  // request. Using vaddr_d created a Verilator DIDNOTCONVERGE cycle:
  //   way_pred_oh(cl_index=vaddr_d) → match → dreq.ready → vaddr_d → …
  // On same-cycle hit+accept of a new fetch, fall back to full-way CE.
  logic [ICACHE_CL_IDX_WIDTH-1:0] cl_index_q;
  logic                           way_pred_use;
  assign cl_index_q = vaddr_q[G6LCCfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH];
  assign way_pred_use = G6LCCfg.WayPredEn && (G6LCCfg.ICACHE_SET_ASSOC > 1)
      && !force_all_ways_q && !(fetch_accept & dreq_i.req);

  if (G6LCCfg.WayPredEn && G6LCCfg.ICACHE_SET_ASSOC > 1) begin : gen_way_pred
    localparam int unsigned WP_ENTRIES =
        (G6LCCfg.WayPredEntries != 0) ? G6LCCfg.WayPredEntries : 128;
    g6lc_way_predictor #(
        .G6LCCfg    (G6LCCfg),
        .NR_WAYS    (G6LCCfg.ICACHE_SET_ASSOC),
        .NR_ENTRIES (WP_ENTRIES)
    ) i_way_pred (
        .clk_i,
        .rst_ni,
        .flush_i        (flush_i | flush_en),
        .lookup_i       (cache_rden),
        .index_i        ({{(32 - ICACHE_CL_IDX_WIDTH) {1'b0}}, cl_index_q}),
        .way_o          (way_pred_bin),
        .way_oh_o       (way_pred_oh),
        .valid_o        (),
        .update_i       (cmp_en_q && |cl_hit),
        .update_index_i ({{(32 - ICACHE_CL_IDX_WIDTH) {1'b0}}, cl_index_q}),
        .update_way_i   (hit_idx)
    );
  end else begin : gen_no_way_pred
    assign way_pred_oh  = '1;
    assign way_pred_bin = '0;
  end

  assign way_pred_match = |(cl_hit & way_pred_oh);
  assign cl_req = (cache_rden) ?
      (way_pred_use ? way_pred_oh : '1) :
      (cache_wren) ? repl_way_oh_q : '0;
  assign cl_we = cache_wren;


  // find invalid cache line
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.ICACHE_SET_ASSOC)
  ) i_lzc (
      .in_i   (~vld_rdata),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  // generate random cacheline index
  g6lc_hyp_lfsr #(
      .LfsrWidth(8),
      .OutWidth (G6LCCfg.ICACHE_SET_ASSOC_WIDTH)
  ) i_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );


  ///////////////////////////////////////////////////////
  // tag comparison, hit generation
  ///////////////////////////////////////////////////////

  for (genvar i = 0; i < G6LCCfg.ICACHE_SET_ASSOC; i++) begin : gen_tag_cmpsel
    assign cl_hit[i] = (cl_tag_rdata[i] == cl_tag_d) & vld_rdata[i];
    assign cl_sel[i] = cl_rdata[i][{cl_offset_q, 3'b0}+:G6LCCfg.FETCH_WIDTH];
    assign cl_user[i] = (G6LCCfg.FETCH_USER_EN != 32'd0) ? cl_ruser[i][{cl_offset_q, 3'b0}+:G6LCCfg.FETCH_USER_WIDTH] : '0;
  end


  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.ICACHE_SET_ASSOC)
  ) i_lzc_hit (
      .in_i   (cl_hit),
      .cnt_o  (hit_idx),
      .empty_o()
  );

  // G1iw: other 8-byte half [15:0]
  // compressed Branch on user[16:0]
  // for same-cycle recover. G1iv
  // stashed this — MINI-FAIL. Not a
  // stash. SMT+SS. I1: B has no sibling user.
`ifndef G6LC_FETCH_B
  logic [ICACHE_OFFSET_WIDTH-1:0] g1iw_off;
  logic [G6LCCfg.FETCH_WIDTH-1:0] g1iw_other;
  logic                            g1iw_br;
  assign g1iw_off = cl_offset_q ^
      {{(ICACHE_OFFSET_WIDTH - 4) {1'b0}}, 4'h8};
  assign g1iw_other = cmp_en_q
      ? cl_rdata[hit_idx][{g1iw_off, 3'b0}+:G6LCCfg.FETCH_WIDTH]
      : mem_rtrn_i.data[{g1iw_off, 3'b0}+:G6LCCfg.FETCH_WIDTH];
  assign g1iw_br = G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 &&
      G6LCCfg.ICACHE_LINE_WIDTH >= 128 &&
      G6LCCfg.FETCH_WIDTH >= 64 &&
      G6LCCfg.FETCH_USER_WIDTH >= 17 &&
      (g1iw_other[1:0] == 2'b01) &&
      ((g1iw_other[15:13] == 3'b110) ||
       (g1iw_other[15:13] == 3'b111));
  // G1jj sibling-half [31:16] exact
  // c.jalr on user[33:17] — MINI-FAIL
  // lottery tohost 2 @200615. Do not
  // re-land (any sibling +2; yanks live
  // mid-line jalr).
  // G1jl: only the pair (sibling [15:0]
  // compressed Branch AND [31:16] exact
  // c.jalr). G1jk PC-matches present.
  // Not G1iv [15:0] stash. SMT+SS.
  logic g1jl_cjalr;
  assign g1jl_cjalr = g1iw_br &&
      G6LCCfg.FETCH_USER_WIDTH >= 34 &&
      (g1iw_other[31:28] == 4'b1001) &&
      (g1iw_other[22:18] == 5'd0) &&
      (g1iw_other[27:23] != 5'd0) &&
      (g1iw_other[17:16] == 2'b10);
`endif
  // G1ki sticky last sibling pair on
  // user[33] across vaddr change —
  // HOLD-FAIL no cookie @600000
  // [1000]=51b1c001 no BANR. Do not
  // re-land (sticky yanked success-
  // cave addi). Not G1iv. Not G1jj.
  always_comb begin
    if (cmp_en_q) begin
      dreq_data_sel = cl_sel[hit_idx];
      dreq_user_sel = (G6LCCfg.FETCH_USER_EN != 32'd0) ? cl_user[hit_idx] : '0;
    end else begin
      dreq_data_sel = mem_rtrn_i.data[{cl_offset_q, 3'b0}+:G6LCCfg.FETCH_WIDTH];
      dreq_user_sel = (G6LCCfg.FETCH_USER_EN != 32'd0) ? mem_rtrn_i.user[{cl_offset_q, 3'b0}+:G6LCCfg.FETCH_USER_WIDTH] : '0;
    end
    // I1 / SPEC §7: B never smuggles a sibling I$ half on user[]. A keeps G1iw/jl.
`ifndef G6LC_FETCH_B
    if (g1iw_br)
      dreq_user_sel[16:0] = {1'b1, g1iw_other[15:0]};
    if (g1jl_cjalr)
      dreq_user_sel[33:17] = {1'b1, g1iw_other[31:16]};
`endif
    // hyp8: the registered response record owns the data/user pins in
    // READ_V; every other state takes the live selection (incl. the
    // mem_rtrn bypass on the ifill return).
    if (state_q == READ_V) begin
      dreq_o.data = rsp_data_q;
      dreq_o.user = rsp_user_q;
    end else begin
      dreq_o.data = dreq_data_sel;
      dreq_o.user = dreq_user_sel;
    end
  end

  ///////////////////////////////////////////////////////
  // memory arrays and regs
  ///////////////////////////////////////////////////////


  logic [G6LCCfg.ICACHE_TAG_WIDTH:0] cl_tag_valid_rdata[G6LCCfg.ICACHE_SET_ASSOC-1:0];

  for (genvar i = 0; i < G6LCCfg.ICACHE_SET_ASSOC; i++) begin : gen_sram
    // Tag RAM
    sram_cache #(
        // tag + valid bit
        .DATA_WIDTH (G6LCCfg.ICACHE_TAG_WIDTH + 1),
        .BYTE_ACCESS(0),
        .TECHNO_CUT (G6LCCfg.TechnoCut),
        .NUM_WORDS  (ICACHE_NUM_WORDS)
    ) tag_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (vld_req[i]),
        .we_i   (vld_we),
        .addr_i (vld_addr),
        // we can always use the saved tag here since it takes a
        // couple of cycle until we write to the cache upon a miss
        .wuser_i('0),
        .wdata_i({vld_wdata[i], cl_tag_q}),
        .be_i   ('1),
        .ruser_o(),
        .rdata_o(cl_tag_valid_rdata[i])
    );

    assign cl_tag_rdata[i] = cl_tag_valid_rdata[i][G6LCCfg.ICACHE_TAG_WIDTH-1:0];
    assign vld_rdata[i]    = cl_tag_valid_rdata[i][G6LCCfg.ICACHE_TAG_WIDTH];

    // Data RAM
    sram_cache #(
        .USER_WIDTH (G6LCCfg.ICACHE_USER_LINE_WIDTH),
        .DATA_WIDTH (G6LCCfg.ICACHE_LINE_WIDTH),
        .USER_EN    (G6LCCfg.FETCH_USER_EN),
        .BYTE_ACCESS(0),
        .TECHNO_CUT (G6LCCfg.TechnoCut),
        .NUM_WORDS  (ICACHE_NUM_WORDS)
    ) data_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (cl_req[i]),
        .we_i   (cl_we),
        .addr_i (cl_index),
        .wuser_i(mem_rtrn_i.user),
        .wdata_i(mem_rtrn_i.data),
        .be_i   ('1),
        .ruser_o(cl_ruser[i]),
        .rdata_o(cl_rdata[i])
    );
  end


  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      cl_tag_q      <= '0;
      flush_cnt_q   <= '0;
      vaddr_q       <= boot_addr_i;
      cmp_en_q      <= '0;
      cache_en_q    <= '0;
      flush_q       <= '0;
      state_q       <= FLUSH;
      cl_offset_q   <= '0;
      repl_way_oh_q   <= '0;
      inv_q           <= '0;
      force_all_ways_q <= 1'b0;
      rsp_data_q       <= '0;
      rsp_user_q       <= '0;
      rsp_ex_q         <= '0;
    end else begin
      cl_tag_q        <= cl_tag_d;
      flush_cnt_q     <= flush_cnt_d;
      vaddr_q         <= vaddr_d;
      cmp_en_q        <= cmp_en_d;
      cache_en_q      <= cache_en_d;
      flush_q         <= flush_d;
      state_q         <= state_d;
      cl_offset_q     <= cl_offset_d;
      repl_way_oh_q   <= repl_way_oh_d;
      inv_q           <= inv_d;
      force_all_ways_q <= force_all_ways_d;
      rsp_data_q      <= rsp_data_d;
      rsp_user_q      <= rsp_user_d;
      rsp_ex_q        <= rsp_ex_d;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
`ifndef VERILATOR
  repl_inval0 :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) cache_wren |-> !(mem_rtrn_i.inv.all | mem_rtrn_i.inv.vld))
  else $fatal(1, "[l1 icache] cannot replace cacheline and invalidate cacheline simultaneously");

  repl_inval1 :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) (mem_rtrn_i.inv.all | mem_rtrn_i.inv.vld) |-> !cache_wren)
  else $fatal(1, "[l1 icache] cannot replace cacheline and invalidate cacheline simultaneously");

  invalid_state :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) (state_q inside {FLUSH, IDLE, READ, READ_V, MISS, KILL_ATRANS, KILL_MISS}))
  else $fatal(1, "[l1 icache] fsm reached an invalid state");

  hot1 :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) (!inv_en) |-> cache_rden |=> cmp_en_q |-> $onehot0(
      cl_hit
  ))
  else $fatal(1, "[l1 icache] cl_hit signal must be hot1");

  // this is only used for verification!
  logic vld_mirror[ICACHE_NUM_WORDS-1:0][G6LCCfg.ICACHE_SET_ASSOC-1:0];
  logic [G6LCCfg.ICACHE_TAG_WIDTH-1:0] tag_mirror[ICACHE_NUM_WORDS-1:0][G6LCCfg.ICACHE_SET_ASSOC-1:0];
  logic [G6LCCfg.ICACHE_SET_ASSOC-1:0] tag_write_duplicate_test;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_mirror
    if (!rst_ni) begin
      vld_mirror <= '{default: '0};
      tag_mirror <= '{default: '0};
    end else begin
      for (int i = 0; i < G6LCCfg.ICACHE_SET_ASSOC; i++) begin
        if (vld_req[i] & vld_we) begin
          vld_mirror[vld_addr][i] <= vld_wdata[i];
          tag_mirror[vld_addr][i] <= cl_tag_q;
        end
      end
    end
  end

  for (genvar i = 0; i < G6LCCfg.ICACHE_SET_ASSOC; i++) begin : gen_tag_dupl
    assign tag_write_duplicate_test[i] = (tag_mirror[vld_addr][i] == cl_tag_q) & vld_mirror[vld_addr][i] & (|vld_wdata);
  end

  tag_write_duplicate :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) |vld_req |-> vld_we |-> !(|tag_write_duplicate_test))
  else $fatal(1, "[l1 icache] cannot allocate a CL that is already present in the cache");


  initial begin
    // assert wrong parameterizations
    assert (G6LCCfg.ICACHE_INDEX_WIDTH <= 12)
    else $fatal(1, "[l1 icache] cache index width can be maximum 12bit since VM uses 4kB pages");
  end
`endif

  // M3 bring-up probe (+icf_trace): first-300-cycle state/handshake dump.
  // Sim-only; not part of the product logic.
  logic icf_trace;
  initial icf_trace = $test$plusargs("icf_trace");
  always_ff @(posedge clk_i) begin
    if (rst_ni && icf_trace && $time() < 600) begin
      $display("[icf] t=%0t st=%0d st_d=%0d en=%b cen=%b fcnt=%0d fdone=%b | req=%b rdy=%b vld=%b k1=%b k2=%b spec=%b | a_req=%b a_vld=%b a_ex=%b a_pa=%h | mreq=%b mack=%b mrtrn=%b rt=%0d | hit=%b nc=%b vaq=%h vad=%h",
        $time, state_q, state_d, en_i, cache_en_q, flush_cnt_q, flush_done,
        dreq_i.req, dreq_o.ready, dreq_o.valid, dreq_i.kill_s1, dreq_i.kill_s2, dreq_i.spec,
        areq_o.fetch_req, areq_i.fetch_valid, areq_i.fetch_exception.valid,
        areq_i.fetch_paddr,
        mem_data_req_o, mem_data_ack_i, mem_rtrn_vld_i, mem_rtrn_i.rtype,
        |cl_hit, paddr_is_nc, vaddr_q, vaddr_d);
    end
  end
  //pragma translate_on

endmodule  // g6lc_icache
