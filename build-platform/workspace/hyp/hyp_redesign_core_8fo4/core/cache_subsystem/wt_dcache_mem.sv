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
// Date: 13.09.2018
// Description: Memory arrays, arbiter and tag comparison for WT dcache.
// Modified by: Etienne Cimon (opt-in visibility diagnostics).
//
//
// Notes: 1) all ports can trigger a readout of all ways, and the way where the tag hits is selected
//
//        2) only port0 can write full cache lines. higher ports are read only. also, port0 can only read the tag array,
//           and does not trigger a cache line readout.
//
//        3) the single word write port is a separate port without access to the tag memory.
//           these single word writes can interleave with read operations if they go to different
//           cacheline offsets, since each word offset is placed into a different SRAM bank.
//
//        4) Read ports with same priority are RR arbited. but high prio ports (rd_prio_i[port_nr] = '1b1) will stall
//           low prio ports (rd_prio_i[port_nr] = '1b0)


module wt_dcache_mem
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg             = config_pkg::g6lc_cfg_empty,
    // hyp8: hit-latency staging (DcacheHitExtra=2 — the accepted rank-5 cut).
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg        = g6lc_hyp_pkg::Hyp8,
    parameter                        DCACHE_CL_IDX_WIDTH = 0,
    parameter type                   wbuffer_t           = logic,
    parameter int unsigned           NumPorts            = 3
) (
    input logic clk_i,
    input logic rst_ni,

    // ports
    input logic [NumPorts-1:0][G6LCCfg.DCACHE_TAG_WIDTH-1:0] rd_tag_i,  // tag in - comes one cycle later
    input logic [NumPorts-1:0][DCACHE_CL_IDX_WIDTH-1:0] rd_idx_i,
    input logic [NumPorts-1:0][G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] rd_off_i,
    input logic [NumPorts-1:0] rd_req_i,  // read the word at offset off_i[:3] in all ways
    input  logic  [NumPorts-1:0]                              rd_tag_only_i,      // only do a tag/valid lookup, no access to data arrays
    input logic [NumPorts-1:0] rd_prio_i,  // 0: low prio, 1: high prio
    output logic [NumPorts-1:0] rd_ack_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_vld_bits_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_hit_oh_o,
    output logic [G6LCCfg.XLEN-1:0] rd_data_o,
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] rd_user_o,

    // only available on port 0, uses address signals of port 0
    input logic                                      wr_cl_vld_i,
    input logic                                      wr_cl_nc_i,       // noncacheable access
    input logic [      G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_cl_we_i,       // writes a full cacheline
    input logic [      G6LCCfg.DCACHE_TAG_WIDTH-1:0] wr_cl_tag_i,
    input logic [           DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx_i,
    input logic [   G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] wr_cl_off_i,
    input logic [     G6LCCfg.DCACHE_LINE_WIDTH-1:0] wr_cl_data_i,
    input logic [G6LCCfg.DCACHE_USER_LINE_WIDTH-1:0] wr_cl_user_i,
    input logic [   G6LCCfg.DCACHE_LINE_WIDTH/8-1:0] wr_cl_data_be_i,
    input logic [      G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_vld_bits_i,

    // separate port for single word write, no tag access
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_req_i,  // write a single word to offset off_i[:3]
    output logic wr_ack_o,
    input logic [DCACHE_CL_IDX_WIDTH-1:0] wr_idx_i,
    input logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] wr_off_i,
    input logic [G6LCCfg.XLEN-1:0] wr_data_i,
    input logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] wr_user_i,
    input logic [(G6LCCfg.XLEN/8)-1:0] wr_data_be_i,

    // explicit line invalidation for SL-W fixup queue
    input logic inv_req_i,
    output logic inv_ack_o,
    input logic [DCACHE_CL_IDX_WIDTH-1:0] inv_idx_i,
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] inv_way_oh_i,
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] inv_vld_bits_i,

    // forwarded wbuffer
    // hyp8: widened by the in-flight pending-export entry (WtDcacheWbufDepth+1)
  // so a word committed to the drain stage stays forward-visible (T47).
  input wbuffer_t [G6LCCfg.WtDcacheWbufDepth+1:0] wbuffer_data_i,
    // SL-W fixup queue forwarding (newest-first; unused when fixup depth is 0)
    input wbuffer_t [G6LCCfg.WtDcacheFixupDepth:0] fixup_wbuffer_i,
    // Full XLEN word present in wbuffer/fixup: load can complete without a
    // miss refill (store still buffered, not yet a TX). Not a miss-unit mask.
    output logic wbuffer_fwd_hit_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin wt_dcache_mem status=proposal target=10-adjusted-FO4
  // svt-plan: cone production forwarding is per-byte first-match across
  // wbuffer_all; the single wbuffer_hit_idx read is only a mutation branch.
  // svt-plan: reshape for each byte form ordered {valid,data,user} leaves;
  // merge with associative left-valid priority, preserving lower-index wins.
  // svt-plan: boundary local byte winners/cache word -> final overlay;
  // latch payloads with masks, not a hit vector pointing at mutable entries.
  // svt-plan: carry request identity, PA, hit/miss/exception, byte winners,
  // cache/refill data and user bits, wr_cl_vld_i source class and coherence epoch.
  // svt-plan: conflict define snapshot visibility at accepted load lookup;
  // invalidate/replay an invalidated response and serialize older stores
  // that have not yet appeared in the forwarding snapshot.
  // svt-plan: effect serial O(WbufferAllDepth) byte selection becomes
  // O(log WbufferAllDepth) merge levels, optionally split across a register.
  // svt-plan: cost payload snapshot registers and +1 response cycle if cut;
  // delay wbuffer_fwd_hit_o, miss decision and load completion consistently.
  // svt-plan: limit rd_tag is not guaranteed in the request cycle; a free
  // earlier tag CAM or one new-entry bypass cannot cover all concurrent writers.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 47.2 adjusted FO4 on the
  // Nangate45 board): D$ data path: bank select and forward merge.
  // svt-pipe: require-contract
  // svt-pipe: protocol dm valid=rd_req_i
  // The merge drives rd_data_o; wbuffer_data_i is its input bundle.
  // svt-pipe: no-cut on=rd_data_o
  // svt-pipe: cycle dm q=rd_data_o d=rd_hit_oh_o hold=rd_req_i steps=1

  localparam DCACHE_NUM_BANKS = G6LCCfg.DCACHE_LINE_WIDTH / G6LCCfg.XLEN;
  localparam DCACHE_NUM_BANKS_WIDTH = $clog2(DCACHE_NUM_BANKS);

  // SL-W: combine normal wbuffer and fixup queue for readout forwarding.
  // For fixup depth 0 the upper slice is empty and the readout logic reduces
  // to the original wbuffer_data_i behaviour.
  // Pad to a power of two so lzc WIDTH == array length. A raw depth of 11
  // (Wbuf=8 + fixup-forward=3) gives $clog2=4, and Verilator indexes the
  // packed VlWide with that 4-bit cnt (0..15) — SIGSEGV on the testharness.
  localparam int unsigned FixupForwardDepth = G6LCCfg.WtDcacheFixupDepth + int'(G6LCCfg.WtDcacheFixupDepth > 0);
  // hyp8 r5: the export bundle carries WbufDepth+2 words -- the
  // W3-pending write record plus the fresh-accept record ride the top
  // slots so back-to-back accepted stores both stay forward-visible.
  localparam int unsigned WbufExportDepth   = G6LCCfg.WtDcacheWbufDepth + 2;
  localparam int unsigned WbufferAllRaw     = WbufExportDepth + FixupForwardDepth;
  localparam int unsigned WbufferAllDepth   = (WbufferAllRaw <= 1) ? 1 : (2 ** $clog2(WbufferAllRaw));

  wbuffer_t [WbufferAllDepth-1:0] wbuffer_all;

  for (genvar k = 0; k < WbufferAllDepth; k++) begin : gen_wbuffer_all
    if (k < WbufExportDepth) begin : gen_wbuf
      

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_mem  region=4118  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: bank_idx_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to bank_idx_q
// order expect: bank_off_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to bank_off_q
// order expect: cmp_en_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cmp_en_q
// order expect: vld_sel_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vld_sel_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     bank_idx_q <= …; // sv-timing: cycle 1/1 on clk_i
//     bank_off_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cmp_en_q <= …; // sv-timing: cycle 1/1 on clk_i
//     vld_sel_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14288 c=3.50 slack=0.00 */
//     /* node14289 c=3.50 slack=0.00 */
//     /* node14290 c=3.50 slack=0.00 */
//     /* node14291 c=3.50 slack=0.00 */
//     /* node14292 c=3.50 slack=0.00 */
//     /* node14293 c=3.50 slack=0.00 */
//     /* node14294 c=3.50 slack=0.00 */
//     /* node14295 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign wbuffer_all[k] = wbuffer_data_i[k];
    end else if (k < WbufferAllRaw) begin : gen_fix
      assign wbuffer_all[k] = fixup_wbuffer_i[k-WbufExportDepth];
    end else begin : gen_pad
      assign wbuffer_all[k] = '0;
    end
  end

  // functions
  function automatic logic [DCACHE_NUM_BANKS-1:0] dcache_cl_bin2oh(
      input logic [DCACHE_NUM_BANKS_WIDTH-1:0] in);
    logic [DCACHE_NUM_BANKS-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  // number of bits needed to address AXI data. If AxiDataWidth equals G6LCCfg.XLEN this parameter
  // is not needed. Therefore, increment it by one to avoid reverse range select during elaboration.
  localparam AXI_OFFSET_WIDTH = G6LCCfg.AxiDataWidth == G6LCCfg.XLEN ? $clog2(
      G6LCCfg.AxiDataWidth / 8
  ) + 1 : $clog2(
      G6LCCfg.AxiDataWidth / 8
  );

  logic [DCACHE_NUM_BANKS-1:0]                                                     bank_req;
  logic [DCACHE_NUM_BANKS-1:0]                                                     bank_we;
  logic [DCACHE_NUM_BANKS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0][(G6LCCfg.XLEN/8)-1:0] bank_be;
  logic [DCACHE_NUM_BANKS-1:0][     DCACHE_CL_IDX_WIDTH-1:0]                       bank_idx;
  logic [DCACHE_CL_IDX_WIDTH-1:0] bank_idx_d, bank_idx_q;
  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] bank_off_d, bank_off_q;

  logic [DCACHE_NUM_BANKS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.XLEN-1:0] bank_wdata;  //
  logic [DCACHE_NUM_BANKS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.XLEN-1:0] bank_rdata;  //
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.XLEN-1:0] rdata_cl;  // selected word from each cacheline
  logic [DCACHE_NUM_BANKS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0] bank_wuser;  //
  logic [DCACHE_NUM_BANKS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0] bank_ruser;  //
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0]                      ruser_cl;          // selected word from each cacheline

  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] rd_tag;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] vld_req;  // bit enable for valid regs
  logic vld_we;  // valid bits write enable
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] vld_wdata;  // valid bits to write
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_TAG_WIDTH-1:0]            tag_rdata;                    // these are the tags coming from the tagmem
  logic [DCACHE_CL_IDX_WIDTH-1:0] vld_addr;  // valid bit

  logic [$clog2(NumPorts)-1:0] vld_sel_d, vld_sel_q;

  logic [WbufferAllDepth-1:0] wbuffer_hit_oh;
  logic [(G6LCCfg.XLEN/8)-1:0] wbuffer_be;
  logic [G6LCCfg.XLEN-1:0] wbuffer_rdata, rdata;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] wbuffer_ruser, ruser;
  logic [G6LCCfg.PLEN-1:0] wbuffer_cmp_addr;

  logic cmp_en_d, cmp_en_q;
  logic rd_acked;
  logic wr_denied;
  logic [NumPorts-1:0] bank_collision, rd_req_masked, rd_req_prio;

  // hyp8: response-stage boundary (the accepted rank-5 D$ +2 cut,
  // HypCfg.DcacheHitExtra). Live mode (DcacheHitExtra==0) aliases the
  // combinational network exactly as before: tag compare at the SRAM
  // rdata cycle, way/data merge same cycle. Piped mode registers the
  // compare + lookup inputs at T1 (SRAM-rdata cycle), runs the way select
  // and forward merge at T2, and registers the response — hit/vld/data/user
  // and wbuffer_fwd_hit_o all leave +2 cycles after the accepted request.
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]                   rd_hit_oh_c, rd_vld_bits_c;
  logic [G6LCCfg.XLEN-1:0]                               rd_data_c;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]                  rd_user_c;
  logic                                                  fwd_hit_c;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]                   hit_sel;
  logic [WbufferAllDepth-1:0]                            merge_hit;
  logic [WbufferAllDepth-1:0][(G6LCCfg.XLEN/8)-1:0]      merge_vld;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.XLEN-1:0] rdata_arr;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0] ruser_arr;
  logic                                                  rd_refill;
  logic [G6LCCfg.XLEN-1:0]                               rd_refill_word;
  logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]                  rd_refill_user;

  ///////////////////////////////////////////////////////
  // arbiter
  ///////////////////////////////////////////////////////

  // Priority is highest for lowest read port index
  //
  // SRAM bank mapping:
  //
  // Bank 0                   Bank 2
  // [way0, w0] [way1, w0] .. [way0, w1] [way1, w1] ..

  // byte enable mapping
  for (genvar k = 0; k < DCACHE_NUM_BANKS; k++) begin : gen_bank
    for (genvar j = 0; j < G6LCCfg.DCACHE_SET_ASSOC; j++) begin : gen_bank_way
      assign bank_be[k][j]   = (wr_cl_we_i[j] & wr_cl_vld_i)  ? wr_cl_data_be_i[k*(G6LCCfg.XLEN/8) +: (G6LCCfg.XLEN/8)] :
                               (wr_req_i[j]   & wr_ack_o)     ? wr_data_be_i              :
                                                                '0;
      assign bank_wdata[k][j] = (wr_cl_we_i[j] & wr_cl_vld_i) ?  wr_cl_data_i[k*G6LCCfg.XLEN +: G6LCCfg.XLEN] :
                                                                 wr_data_i;
      assign bank_wuser[k][j] = (wr_cl_we_i[j] & wr_cl_vld_i) ?  wr_cl_user_i[k*G6LCCfg.DCACHE_USER_WIDTH +: G6LCCfg.DCACHE_USER_WIDTH] :
                                                                 wr_user_i;
    end
  end

  // Same-cycle deny-inval: drop valid on the hit way when wr_ack is
  // denied (load vs word-write same bank). Delayed-by-1 (nackinv-d1)
  // hung packed namelen (h0 cap @40000); keep this pairing.
  //
  // SL-W: explicit `inv_req` invalidates one way.  It has priority over the
  // existing `wr_denied` path so the full-queue fallback cannot be starved by
  // a colliding word write.
  // T43: the valid-bit DATA follows the same priority as vld_addr/vld_req --
  // the missunit's line write/invalidation (wr_cl_vld_i) first. With inv_req_i
  // ahead of it, an AMO/flush "invalidate all ways" (wr_cl_we=ff,
  // wr_vld_bits=0) that coincided with a pending, unacked fixup inv_req wrote
  // the fixup's `inv_vld_bits & ~way` (e.g. f7) into all eight ways at the
  // missunit's index with the missunit's tag: seven ways validated on one
  // line, the next load hit them all (hit=f7) and read the pre-AMO word (the
  // L3 boot's amoand after amoor on work->data, cycle 713,884,693).
`ifdef G6LC_MUT_VLD_WDATA_INV_PRIO
  assign vld_wdata     = inv_req_i  ? (inv_vld_bits_i & ~inv_way_oh_i) :   // review mutation: the pre-fix mux
                         wr_denied ? '0 :
                                     wr_vld_bits_i;
`else
  assign vld_wdata     = wr_cl_vld_i ? wr_vld_bits_i :
                         inv_req_i   ? (inv_vld_bits_i & ~inv_way_oh_i) :
                         wr_denied   ? '0 :
                                       wr_vld_bits_i;
`endif
  assign vld_addr      = (wr_cl_vld_i) ? wr_cl_idx_i :
                         (inv_req_i)  ? inv_idx_i :
                         (wr_denied)  ? wr_idx_i :
                                        rd_idx_i[vld_sel_d];
  assign rd_tag        = rd_tag_i[vld_sel_q];  //delayed by one cycle
  assign bank_off_d    = (wr_cl_vld_i) ? wr_cl_off_i : rd_off_i[vld_sel_d];
  assign bank_idx_d    = (wr_cl_vld_i) ? wr_cl_idx_i : rd_idx_i[vld_sel_d];
  assign vld_req       = (wr_cl_vld_i) ? wr_cl_we_i :
                         (inv_req_i)  ? inv_way_oh_i :
                         (wr_denied)  ? wr_req_i :
                         (rd_acked)   ? '1 : '0;


  // priority masking
  // disable low prio requests when any of the high prio reqs is present
  assign rd_req_prio   = rd_req_i & rd_prio_i;
  assign rd_req_masked = (|rd_req_prio) ? rd_req_prio : rd_req_i;

  // T48: a read is not acknowledged in a cycle the SL-W explicit invalidation
  // (inv_req_i) owns the valid-bit port. cmp_en_d below is cleared whenever
  // the valid bits are written, so an acknowledged lookup in that cycle came
  // back as hit=0 -- a false miss. A load's false miss only refilled a line
  // that was already resident (duplicate ways, `hit=22`); the write buffer's
  // tag check recorded `checked=1, hit_oh=0` for a present line, its ACK then
  // wrote nothing, and with the fixup queue full the word was dropped: the
  // L3 boot's trap-frame slot that read the previous value 8,850 cycles
  // later (PA 0x826d2b90, c=1,616,654,967: three checks hit=02, hit=02,
  // hit=00). The refill (wr_cl_vld_i) already held the port the same way.
  logic rd_port_busy;
  assign rd_port_busy = wr_cl_vld_i | inv_req_i;

  logic rd_req;
  g6lc_hyp_rr_arb_tree #(
      .NumIn    (NumPorts),
      .DataWidth(1)
  ) i_rr_arb_tree (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (rd_req_masked),
      .gnt_o  (rd_ack_o),
      .data_i ('0),
`ifdef G6LC_MUT_RD_ACK_DURING_INV
      .gnt_i  (~wr_cl_vld_i),          // review mutation: the pre-fix grant
`else
      .gnt_i  (~rd_port_busy),
`endif
      .req_o  (rd_req),
      .data_o (),
      .idx_o  (vld_sel_d)
  );

`ifdef G6LC_MUT_RD_ACK_DURING_INV
  assign rd_acked = rd_req & ~wr_cl_vld_i;
`else
  assign rd_acked = rd_req & ~rd_port_busy;
`endif

  always_comb begin : p_bank_req
    vld_we    = wr_cl_vld_i;
    wr_denied = 1'b0;
    inv_ack_o = 1'b0;
    bank_req  = '0;
    wr_ack_o  = '0;
    bank_we   = '0;
    bank_idx  = '{default: wr_idx_i};

    for (int k = 0; k < NumPorts; k++) begin
      bank_collision[k] = rd_off_i[k][G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES] == wr_off_i[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES];
    end

    if (wr_cl_vld_i & |wr_cl_we_i) begin
      // Cache-line refill has highest priority.  A pending invalidation must
      // wait until the line write completes.
      bank_req = '1;
      bank_we  = '1;
      bank_idx = '{default: wr_cl_idx_i};
    end else begin
      // SL-W explicit invalidation has priority over single-word writes.
      if (inv_req_i) begin
        inv_ack_o = 1'b1;
        vld_we    = 1'b1;
      end

      if (rd_acked) begin
        if (!rd_tag_only_i[vld_sel_d]) begin
          bank_req = dcache_cl_bin2oh(
              rd_off_i[vld_sel_d][G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]);
          bank_idx[rd_off_i[vld_sel_d][G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]] = rd_idx_i[vld_sel_d];
        end
      end

      if (|wr_req_i) begin
        if (rd_tag_only_i[vld_sel_d] || !(rd_ack_o[vld_sel_d] && bank_collision[vld_sel_d])) begin
          wr_ack_o = 1'b1;
          bank_req |= dcache_cl_bin2oh(
              wr_off_i[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]
          );
          bank_we =
              dcache_cl_bin2oh(wr_off_i[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]);
        end else begin
          wr_denied = 1'b1;
          vld_we    = 1'b1;
        end
      end
    end
  end

  ///////////////////////////////////////////////////////
  // tag comparison, hit generatio, readoud muxes
  ///////////////////////////////////////////////////////

  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-G6LCCfg.XLEN_ALIGN_BYTES-1:0] wr_cl_off;
  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-G6LCCfg.XLEN_ALIGN_BYTES-1:0] wr_cl_nc_off;
  logic [                   $clog2(WbufferAllDepth)-1:0] wbuffer_hit_idx;
  logic [                    $clog2(G6LCCfg.DCACHE_SET_ASSOC)-1:0] rd_hit_idx;

  assign cmp_en_d = (|vld_req) & ~vld_we;

  // word tag comparison in write buffer
  assign wbuffer_cmp_addr = (wr_cl_vld_i) ? {wr_cl_tag_i, wr_cl_idx_i, wr_cl_off_i} :
                                            {rd_tag, bank_idx_q, bank_off_q};
  // hit generation
  for (genvar i = 0; i < G6LCCfg.DCACHE_SET_ASSOC; i++) begin : gen_tag_cmpsel
    // tag comparison of ways >0
    assign rd_hit_oh_c[i] = (rd_tag == tag_rdata[i]) & rd_vld_bits_c[i] & cmp_en_q;
    // byte offset mux of ways >0
    assign rdata_cl[i] = bank_rdata[bank_off_q[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]][i];
    assign ruser_cl[i] = bank_ruser[bank_off_q[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]][i];
  end

  for (genvar k = 0; k < WbufferAllDepth; k++) begin : gen_wbuffer_hit
    assign wbuffer_hit_oh[k] = (|wbuffer_all[k].valid) & ({{G6LCCfg.XLEN_ALIGN_BYTES{1'b0}}, wbuffer_all[k].wtag} == (wbuffer_cmp_addr >> G6LCCfg.XLEN_ALIGN_BYTES));
  end

  g6lc_hyp_lzc #(
      .WIDTH(WbufferAllDepth)
  ) i_lzc_wbuffer_hit (
      .in_i   (merge_hit),
      .cnt_o  (wbuffer_hit_idx),
      .empty_o()
  );

  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.DCACHE_SET_ASSOC)
  ) i_lzc_rd_hit (
      .in_i   (hit_sel),
      .cnt_o  (rd_hit_idx),
      .empty_o()
  );

  // SL-W: the hit index may point into the combined wbuffer_all (normal + fixup)
  // T46: with the fixup queue a word can be held by two entries at once -- the
  // store that was ACKed before its tag check sits in the fixup queue with its
  // array write pending while a younger store to the same word allocates a
  // fresh wbuffer entry. Forwarding from the single lowest-index hit (the
  // young wbuffer entry) took its bytes and left the rest to the array, which
  // did not have the older word yet: a `sd` then `sh` then `ld` on one stack
  // slot returned the `sh` bytes over the pre-`sd` contents (L3 boot, retire
  // 948,230,046). The readout now merges byte-wise across every matching
  // entry, lowest index first: the wbuffer entry (youngest; upstream keeps one
  // per word), then the fixup entries newest-first.
`ifdef G6LC_MUT_WBUF_FWD_ONE_HOT
  assign wbuffer_rdata = wbuffer_all[wbuffer_hit_idx].data;   // review mutation: the pre-fix single-entry forward
  assign wbuffer_ruser = wbuffer_all[wbuffer_hit_idx].user;
  assign wbuffer_be    = (|merge_hit) ? wbuffer_all[wbuffer_hit_idx].valid : '0;
`else
  // per byte lane: the lowest-index matching entry that holds the byte.
  // A140: the serial "first hit wins" scan over WbufferAllDepth entries is a
  // balanced tree of the same associative merge (left operand wins when
  // valid), so the depth is log2(WbufferAllDepth) select levels instead of
  // one priority chain per lane. Data and user travel in the leaf tuple, so
  // the user byte follows the same winning entry as the data byte. Measured
  // (A140, paired placement): worst arrival -26% for +31% of this module's
  // logic area; the prefix-one-hot AND-OR form measured -7% at -4.5% area and
  // is the area-neutral alternative recorded in the review.
  typedef struct packed {
    logic       v;
    logic [7:0] d;
    logic [7:0] u;
  } fwd_leaf_t;
  localparam int unsigned FWD_LVL = (WbufferAllDepth <= 1) ? 0 : $clog2(WbufferAllDepth);
  localparam int unsigned FWD_USER_BYTES = (G6LCCfg.DCACHE_USER_WIDTH / 8 < G6LCCfg.XLEN / 8) ?
      G6LCCfg.DCACHE_USER_WIDTH / 8 : G6LCCfg.XLEN / 8;
  for (genvar k = 0; k < G6LCCfg.XLEN / 8; k++) begin : gen_fwd_lane
    fwd_leaf_t [WbufferAllDepth-1:0] node [0:FWD_LVL];
    for (genvar e = 0; e < WbufferAllDepth; e++) begin : gen_leaf
      assign node[0][e].v = merge_hit[e] & merge_vld[e][k];
      assign node[0][e].d = wbuffer_all[e].data[8*k+:8];
      if (k < FWD_USER_BYTES) begin : gen_user_leaf
        assign node[0][e].u = wbuffer_all[e].user[8*k+:8];
      end else begin : gen_no_user_leaf
        assign node[0][e].u = '0;
      end
    end
    for (genvar l = 1; l <= FWD_LVL; l++) begin : gen_level
      for (genvar n = 0; n < WbufferAllDepth; n++) begin : gen_node
        if (n < (WbufferAllDepth >> l)) begin : gen_merge
          assign node[l][n] = node[l-1][2*n].v ? node[l-1][2*n] : node[l-1][2*n+1];
        end else begin : gen_unused
          assign node[l][n] = '0;
        end
      end
    end
    assign wbuffer_be[k]         = node[FWD_LVL][0].v;
    assign wbuffer_rdata[8*k+:8] = node[FWD_LVL][0].v ? node[FWD_LVL][0].d : 8'h0;
    if (k < FWD_USER_BYTES) begin : gen_user_out
      assign wbuffer_ruser[8*k+:8] = node[FWD_LVL][0].v ? node[FWD_LVL][0].u : 8'h0;
    end
  end
  if (G6LCCfg.DCACHE_USER_WIDTH > FWD_USER_BYTES * 8) begin : gen_user_tail
    assign wbuffer_ruser[G6LCCfg.DCACHE_USER_WIDTH-1:FWD_USER_BYTES*8] = '0;
  end
`endif
  // Complete-word forward: every byte of the XLEN readout is in the buffer.
  // A cache-miss load of that word must not issue a refill (stale DRAM) while
  // the store is still sitting in the wbuffer. Per-word miss-unit *masking* of
  // colliding loads was tried and reverted (starves FDT walks); completing the
  // load here does not hold miss-port arbitration.
  assign fwd_hit_c = (|merge_hit) && (&wbuffer_be);

  if (G6LCCfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_offset
    // In case of an uncached read, return the desired G6LCCfg.XLEN-bit segment of the most recent AXI read
    assign wr_cl_off     = (wr_cl_nc_i) ? (G6LCCfg.AxiDataWidth == G6LCCfg.XLEN) ? '0 :
                              {{G6LCCfg.DCACHE_OFFSET_WIDTH-AXI_OFFSET_WIDTH{1'b0}}, wr_cl_off_i[AXI_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES]} :
                              wr_cl_off_i[G6LCCfg.DCACHE_OFFSET_WIDTH-1:G6LCCfg.XLEN_ALIGN_BYTES];
  end else begin : gen_piton_offset
    assign wr_cl_off = wr_cl_off_i[G6LCCfg.DCACHE_OFFSET_WIDTH-1:3];
  end

  always_comb begin
    if (rd_refill) begin
      rdata = rd_refill_word;
      ruser = rd_refill_user;
    end else begin
      rdata = rdata_arr[rd_hit_idx];
      ruser = ruser_arr[rd_hit_idx];
    end
  end

  // overlay bytes that hit in the write buffer
  for (genvar k = 0; k < (G6LCCfg.XLEN / 8); k++) begin : gen_rd_data
    assign rd_data_c[8*k+:8] = (wbuffer_be[k]) ? wbuffer_rdata[8*k+:8] : rdata[8*k+:8];
  end
  for (genvar k = 0; k < G6LCCfg.DCACHE_USER_WIDTH / 8; k++) begin : gen_rd_user
    assign rd_user_c[8*k+:8] = (wbuffer_be[k]) ? wbuffer_ruser[8*k+:8] : ruser[8*k+:8];
  end

  // hyp8: T1 tag-compare stage -> T2 way/data stage (DcacheHitExtra==2).
  // T1 captures the tag compare, the SRAM rdata word per way, the wbuffer
  // compare vector and byte-valid masks, and the refill-word select. T2 runs
  // the hit select and byte merge against those registers and registers the
  // response, so rd_hit_oh_o / rd_vld_bits_o / rd_data_o / rd_user_o /
  // wbuffer_fwd_hit_o arrive +2 cycles after the accepted request. The
  // per-entry byte masks are snapshotted at T1 so a drain between T1 and T2
  // cannot silently retract forwarded bytes; entry data/user ride live —
  // a drained slot's payload is not rewritten in the same window.
  if (HypCfg.DcacheHitExtra == 2) begin : gen_rsp_pipe
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] hit_t1_q, hit_t2_q;
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] vld_t1_q, vld_t2_q;
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.XLEN-1:0] rdata_cl_q;
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0] ruser_cl_q;
    logic [WbufferAllDepth-1:0]                       wbuf_hit_oh_q;
    logic [WbufferAllDepth-1:0][(G6LCCfg.XLEN/8)-1:0] wbuf_vld_q;
    logic                                             refill_vld_q;
    logic [G6LCCfg.XLEN-1:0]                          refill_word_q;
    logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]             refill_user_q;
    logic [G6LCCfg.XLEN-1:0]                          rd_data_q;
    logic [G6LCCfg.DCACHE_USER_WIDTH-1:0]             rd_user_q;
    logic                                             fwd_hit_q;

    assign hit_sel         = hit_t1_q;
    assign merge_hit       = wbuf_hit_oh_q;
    assign merge_vld       = wbuf_vld_q;
    assign rdata_arr       = rdata_cl_q;
    assign ruser_arr       = ruser_cl_q;
    assign rd_refill       = refill_vld_q;
    assign rd_refill_word  = refill_word_q;
    assign rd_refill_user  = refill_user_q;

    assign rd_hit_oh_o      = hit_t2_q;
    assign rd_vld_bits_o    = vld_t2_q;
    assign rd_data_o        = rd_data_q;
    assign rd_user_o        = rd_user_q;
    assign wbuffer_fwd_hit_o = fwd_hit_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_rsp_t1
      if (!rst_ni) begin
        hit_t1_q       <= '0;
        vld_t1_q       <= '0;
        rdata_cl_q     <= '0;
        ruser_cl_q     <= '0;
        wbuf_hit_oh_q  <= '0;
        wbuf_vld_q     <= '0;
        refill_vld_q   <= 1'b0;
        refill_word_q  <= '0;
        refill_user_q  <= '0;
      end else begin
        hit_t1_q      <= rd_hit_oh_c;
        vld_t1_q      <= rd_vld_bits_c;
        rdata_cl_q    <= rdata_cl;
        ruser_cl_q    <= ruser_cl;
        wbuf_hit_oh_q <= wbuffer_hit_oh;
        for (int k = 0; k < WbufferAllDepth; k++)
          wbuf_vld_q[k] <= wbuffer_all[k].valid;
        refill_vld_q  <= wr_cl_vld_i;
        refill_word_q <= wr_cl_data_i[wr_cl_off*G6LCCfg.XLEN+:G6LCCfg.XLEN];
        refill_user_q <= wr_cl_user_i[wr_cl_off*G6LCCfg.DCACHE_USER_WIDTH+:G6LCCfg.DCACHE_USER_WIDTH];
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_rsp_t2
      if (!rst_ni) begin
        hit_t2_q  <= '0;
        vld_t2_q  <= '0;
        rd_data_q <= '0;
        rd_user_q <= '0;
        fwd_hit_q <= 1'b0;
      end else begin
        hit_t2_q  <= hit_t1_q;
        vld_t2_q  <= vld_t1_q;
        rd_data_q <= rd_data_c;
        rd_user_q <= rd_user_c;
        fwd_hit_q <= fwd_hit_c;
      end
    end
  end else begin : gen_rsp_live
    assign hit_sel         = rd_hit_oh_c;
    assign merge_hit       = wbuffer_hit_oh;
    for (genvar k = 0; k < WbufferAllDepth; k++) begin : gen_merge_vld_live
      assign merge_vld[k] = wbuffer_all[k].valid;
    end
    assign rdata_arr       = rdata_cl;
    assign ruser_arr       = ruser_cl;
    assign rd_refill       = wr_cl_vld_i;
    assign rd_refill_word  = wr_cl_data_i[wr_cl_off*G6LCCfg.XLEN+:G6LCCfg.XLEN];
    assign rd_refill_user  = wr_cl_user_i[wr_cl_off*G6LCCfg.DCACHE_USER_WIDTH+:G6LCCfg.DCACHE_USER_WIDTH];

    assign rd_hit_oh_o      = rd_hit_oh_c;
    assign rd_vld_bits_o    = rd_vld_bits_c;
    assign rd_data_o        = rd_data_c;
    assign rd_user_o        = rd_user_c;
    assign wbuffer_fwd_hit_o = fwd_hit_c;
  end

  ///////////////////////////////////////////////////////
  // memory arrays and regs
  ///////////////////////////////////////////////////////

  logic [G6LCCfg.DCACHE_TAG_WIDTH:0] vld_tag_rdata[G6LCCfg.DCACHE_SET_ASSOC-1:0];

  for (genvar k = 0; k < DCACHE_NUM_BANKS; k++) begin : gen_data_banks
    // Data RAM
    sram_cache #(
        .USER_WIDTH (G6LCCfg.DCACHE_SET_ASSOC * G6LCCfg.DCACHE_USER_WIDTH),
        .DATA_WIDTH (G6LCCfg.DCACHE_SET_ASSOC * G6LCCfg.XLEN),
        .USER_EN    (G6LCCfg.DATA_USER_EN),
        .BYTE_ACCESS(1),
        .TECHNO_CUT (G6LCCfg.TechnoCut),
        .NUM_WORDS  (G6LCCfg.DCACHE_NUM_WORDS)
    ) i_data_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (bank_req[k]),
        .we_i   (bank_we[k]),
        .addr_i (bank_idx[k]),
        .wuser_i(bank_wuser[k]),
        .wdata_i(bank_wdata[k]),
        .be_i   (bank_be[k]),
        .ruser_o(bank_ruser[k]),
        .rdata_o(bank_rdata[k])
    );
  end

  for (genvar i = 0; i < G6LCCfg.DCACHE_SET_ASSOC; i++) begin : gen_tag_srams

    assign tag_rdata[i]     = vld_tag_rdata[i][G6LCCfg.DCACHE_TAG_WIDTH-1:0];
    assign rd_vld_bits_c[i] = vld_tag_rdata[i][G6LCCfg.DCACHE_TAG_WIDTH];

    // Tag RAM
    sram_cache #(
        // tag + valid bit
        .DATA_WIDTH (G6LCCfg.DCACHE_TAG_WIDTH + 1),
        .BYTE_ACCESS(0),
        .TECHNO_CUT (G6LCCfg.TechnoCut),
        .NUM_WORDS  (G6LCCfg.DCACHE_NUM_WORDS)
    ) i_tag_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (vld_req[i]),
        .we_i   (vld_we),
        .addr_i (vld_addr),
        .wuser_i('0),
        .wdata_i({vld_wdata[i], wr_cl_tag_i}),
        .be_i   ('1),
        .ruser_o(),
        .rdata_o(vld_tag_rdata[i])
    );
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      bank_idx_q <= '0;
      bank_off_q <= '0;
      vld_sel_q  <= '0;
      cmp_en_q   <= '0;
    end else begin
      bank_idx_q <= bank_idx_d;
      bank_off_q <= bank_off_d;
      vld_sel_q  <= vld_sel_d;
      cmp_en_q   <= cmp_en_d;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  bit smt_mem_trace, smt_mem_watch;
  logic [G6LCCfg.PLEN-1:0] smt_mem_address;
  int unsigned smt_mem_cycle = 0;
  initial begin
    smt_mem_watch = $value$plusargs("smt_mem_watch=%h", smt_mem_address);
    smt_mem_trace = $test$plusargs("smt_flow_trace") || smt_mem_watch;
  end
  always @(posedge clk_i) begin
    if (!rst_ni) smt_mem_cycle = 0;
    else if (smt_mem_trace) begin
      smt_mem_cycle++;
      if ((cmp_en_q || wr_cl_vld_i) && (!smt_mem_watch ||
          (wbuffer_cmp_addr >> G6LCCfg.XLEN_ALIGN_BYTES) == (smt_mem_address >> G6LCCfg.XLEN_ALIGN_BYTES)))
        $display("[smt-flow] wt_lookup cycle=%0d port=%0d pa=%h hit=%h raw=%h forward=%h be=%h result=%h refill=%b",
                 smt_mem_cycle, vld_sel_q, wbuffer_cmp_addr, rd_hit_oh_o, rdata,
                 wbuffer_hit_oh, wbuffer_be, rd_data_o, wr_cl_vld_i);
      if ((|wr_req_i) && (!smt_mem_watch || {wr_idx_i, wr_off_i} == smt_mem_address[G6LCCfg.DCACHE_INDEX_WIDTH-1:0]))
        $display("[smt-flow] wt_word cycle=%0d idx=%h off=%h ways=%h ack=%b data=%h be=%h denied=%b",
                 smt_mem_cycle, wr_idx_i, wr_off_i, wr_req_i, wr_ack_o,
                 wr_data_i, wr_data_be_i, wr_denied);
      if ((inv_req_i || wr_denied) && (!smt_mem_watch ||
          vld_addr == smt_mem_address[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH]))
        $display("[smt-flow] wt_inval cycle=%0d idx=%h ways=%h valid=%h explicit=%b ack=%b",
                 smt_mem_cycle, vld_addr, vld_req, vld_wdata, inv_req_i, inv_ack_o);
    end
  end

  // T43 invariant: a missunit line write / invalidation writes its own valid
  // bits (at most one way set -- the refilled way), never another path's.
  missunit_vld_write_own_bits :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (wr_cl_vld_i && |wr_cl_we_i) |-> (vld_wdata == wr_vld_bits_i && $onehot0(vld_wdata)))
  else $error("[l1 dcache] missunit line write at idx %h would validate ways %h (own bits %h, inv_req=%b)",
              wr_cl_idx_i, vld_wdata, wr_vld_bits_i, inv_req_i);
`ifndef VERILATOR
  initial begin
    cach_line_width_axi :
    assert (G6LCCfg.DCACHE_LINE_WIDTH >= G6LCCfg.AxiDataWidth)
    else $fatal(1, "[l1 dcache] cache line size needs to be greater or equal AXI data width");
  end

  initial begin
    axi_xlen :
    assert (G6LCCfg.AxiDataWidth >= G6LCCfg.XLEN)
    else $fatal(1, "[l1 dcache] AXI data width needs to be greater or equal G6LCCfg.XLEN");
  end

  initial begin
    cach_line_width_xlen :
    assert (G6LCCfg.DCACHE_LINE_WIDTH > G6LCCfg.XLEN)
    else $fatal(1, "[l1 dcache] cache_line_size needs to be greater than G6LCCfg.XLEN");
  end

  // hyp8: the hit is registered DcacheHitExtra cycles deeper than the
  // SRAM-rdata cycle (accepted request +1 live, +DcacheHitExtra piped).
  hit_hot1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (&vld_req && !vld_we) |-> ##(1 + HypCfg.DcacheHitExtra) $onehot0(
      rd_hit_oh_o
  ))
  else $fatal(1, "[l1 dcache] rd_hit_oh_o signal must be hot1");

  word_write_hot1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) wr_ack_o |-> $onehot0(wr_req_i))
  else $fatal(1, "[l1 dcache] wr_req_i signal must be hot1");

  wbuffer_hit_hot1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) &vld_req |-> !vld_we |=> $onehot0(
      wbuffer_hit_oh
  ))
  else $fatal(1, "[l1 dcache] wbuffer_hit_oh signal must be hot1");

  // this is only used for verification!
  logic vld_mirror[G6LCCfg.DCACHE_NUM_WORDS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0];
  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] tag_mirror[G6LCCfg.DCACHE_NUM_WORDS-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0];
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] tag_write_duplicate_test;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_mirror
    if (!rst_ni) begin
      vld_mirror <= '{default: '0};
      tag_mirror <= '{default: '0};
    end else begin
      for (int i = 0; i < G6LCCfg.DCACHE_SET_ASSOC; i++) begin
        if (vld_req[i] & vld_we) begin
          vld_mirror[vld_addr][i] <= vld_wdata[i];
          tag_mirror[vld_addr][i] <= wr_cl_tag_i;
        end
      end
    end
  end

  for (genvar i = 0; i < G6LCCfg.DCACHE_SET_ASSOC; i++) begin : gen_tag_dubl_test
    assign tag_write_duplicate_test[i] = (tag_mirror[vld_addr][i] == wr_cl_tag_i) & vld_mirror[vld_addr][i] & (|vld_wdata);
  end

  tag_write_duplicate :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) |vld_req |-> vld_we |-> !(|tag_write_duplicate_test))
  else $fatal(1, "[l1 dcache] cannot allocate a CL that is already present in the cache");

`endif
  //pragma translate_on

endmodule  // wt_dcache_mem
