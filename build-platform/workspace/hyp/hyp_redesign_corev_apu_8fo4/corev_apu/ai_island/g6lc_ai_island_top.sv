// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island top (P3 spine): capability window + AI-3 addr check +
// descriptor engine. Not yet on the SoC AXI map — standalone veri first.
//
// Register map (byte address, 32-bit data). Names in g6lc_ai_island_cfg_pkg:
//   CAP_BASE / REG_OFF_CAP     capability window (RO) through 0x00FF
//   REG_OFF_CTL     0x0100  control  [0]=enable [1]=wr_cpl_en
//   REG_OFF_STATUS  0x0104  status   [0]=busy, [1]=fetch_busy, [31:16]=last_status
//   REG_OFF_DOORBELL 0x0108 doorbell  [7:0]=qid, [30:8]=ticket, [31]=fetch_from_mem
//   REG_OFF_CPL     0x010C  done sticky (write 1 = claim/pop CPL FIFO head)
//   0x0110          done ticket (RO) — CPL FIFO head
//   0x0114          done status (RO) — CPL FIFO head
//   Completion FIFO depth = min(QueueDepth, 16) (see g6lc_ai_cpl_fifo / completion-fifo.md)
//   0x0118/0x011C   desc_ptr lo/hi (fetch source when doorbell[31]=1)
//   REG_OFF_QUEUE   0x0120       q0 region: +0 base_lo, +4 base_hi, +8 limit_lo,
//                            +c limit_hi, +10 perm (write commits region)
//   REG_OFF_QUEUE_TAIL 0x01A0+(q-1)*0x20  q>=1. 0x0140 is the descriptor latch,
//                            so q1 is not 0x0120+0x20.
//   DESC_BASE       0x0140..0x017F  descriptor latch (16x32-bit)
//   PMU_OFF_R_BEATS / W_BEATS / CYCLES / GBPS_X1000  (RO, sticky last GEMM)
//   CAP_OFF_MAX_AR_OUT 0x40  GEMM multi-outstanding AR (I3)
//   CAP_OFF_DRAM_TIMING 0x44  packed Cas/tRCD/tRP (0 = island-DMA bypass)
//   CAP_OFF_DRAM_STATUS 0x48  [0]=init_done [1]=timing_en
//   CAP_OFF_DRAM_CH_R/W 0x50/0x70  SoC occupancy (8×32), not GEMM PMU
// Guest-absolute: AI_CAP_BASE=0x4000_0000, AI_DESC_BASE=0x4000_0140.

`include "axi/typedef.svh"

module g6lc_ai_island_top
  import g6lc_ai_island_cfg_pkg::*;
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_policy_pkg::*;
#(
    parameter config_pkg::ai_cfg_t AiCfg = config_pkg::AiCfgOff,
    // Resident-B directory depth when AiCfg.VaTurboEn (g6lc_ai_gemm_seq ReuseBSlots):
    // 2 keeps two half-bank panels resident (alternating N panels of one layer hit).
    parameter int unsigned ReuseBSlots = 2,
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter int unsigned    AddrWidth = 64,
    // When 1: instantiate AXI desc-fetch (SoC). Standalone spine keeps 0.
    // Island allocates the sideband ticket (multi-producer SoC); 0 = proposed ticket.
    parameter bit             SbTicketAlloc = 1'b0,
    parameter bit             EnableDmaFetch = 1'b0,
    parameter int unsigned    AxiDataWidth = 64,
    parameter int unsigned    AxiIdWidth   = 4,
    parameter type            axi_req_t    = logic,
    parameter type            axi_resp_t   = logic,
    // Granted numeric formats, one bit per config_pkg::AI_FMT_* index. A parameter
    // rather than a package read so a testbench can drive an illegal grant to prove
    // the guard below fires; the design default is the package's own value.
    // Format grant. The package policy (AiIslandDtypeMask, the FP island's seven
    // formats) applies when the island has the float plane; an integer-strip
    // elaboration (AiCfg.IslandFpEn = 0) grants the integer subset of that policy,
    // so one package value serves both planes and the grant-subset-of-implemented
    // guard below holds by construction for either.
    parameter logic [15:0]    DtypeMask    = AiCfg.IslandFpEn ? AiIslandDtypeMask
                                                              : (AiIslandDtypeMask & AiIslandPeImplMask),
    // Register slice on the DMA master (g6lc_ai_axi_cut). Cuts every VALID/READY
    // path at the island boundary; costs one cycle per channel direction.
    parameter bit             AxiCutEn     = 1'b1,
    // flags.accmode 01 (seed the C reduction from memory). Published at
    // CAP_OFF_ACCMODE and enforced by the descriptor engine from this one value.
    parameter bit             AccumulateEn = AiIslandAccmodeGrant[0]
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    input  logic        req_i,
    input  logic        we_i,
    input  logic [15:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        rvalid_o,
    output logic        rerror_o,
    output logic        irq_o,
    // Core-sideband submit (ai.enq): uses latched descriptor + this ticket/qid.
    // Bring-up protocol: SW programs region+desc via MMIO, then loads a
    // *different* island reg (not the just-written addr — STLF can hide the
    // miss) so AXI BRESP has retired, then ai.enq. fence alone is not enough
    // — sideband is a core wire and races the peripheral write.
    // Sideband: non-zero sb_desc_ptr_i ⇒ DMA-fetch then submit; zero ⇒ latched desc.
    input  logic        sb_enq_valid_i,
    output logic        sb_enq_ready_o,
    input  logic [7:0]  sb_qid_i,
    // Producer's proposed ticket (legacy, single producer). The island allocates
    // the ticket it will actually use from one monotonic stream and returns it on
    // sb_enq_ticket_o in the acceptance cycle; with one producer counting its own
    // accepted kicks the two agree, with several cores behind the cluster's
    // arbiter only the island's stream keeps ai.poll's watermark meaningful.
    input  logic [31:0] sb_ticket_i,
    output logic [31:0] sb_enq_ticket_o,
    input  logic [63:0] sb_desc_ptr_i,
    // Completion feedback for ai.poll (in-order tickets)
    output logic [31:0] sb_last_ticket_o,
    output logic [15:0] sb_last_status_o,
    output logic        sb_has_completion_o,
    // Highest sideband-origin ticket ever retired (pushed to the completion
    // FIFO), whether or not it has been claimed. ai.poll uses it to answer for
    // tickets behind the FIFO head or already claimed; MMIO-origin tickets never
    // move it. Wraps with the 32-bit ticket space.
    output logic        sb_retired_valid_o,
    output logic [31:0] sb_retired_ticket_o,
    // AXI master for desc fetch (tie req idle / resp ready when EnableDmaFetch=0)
    output axi_req_t    axi_dma_req_o,
    input  axi_resp_t   axi_dma_resp_i,
    // DMA-write invalidation (AiCfg.DmaInvalEn): one line inval per completed
    // island write toward the cluster's CMO engine writer port; job completion
    // is published only after every inval of the job returned (idle).
    output logic                 dma_inval_valid_o,
    output logic [AddrWidth-1:0] dma_inval_addr_o,
    input  logic                 dma_inval_ready_i,
    input  logic                 dma_inval_done_i,
    // I3: DRAM backend init/calib. Tie 1 when the TB has no DRAM slave.
    // No port defaults: Verilator 5.008 (remote testharness) rejects them.
    input  logic        dram_init_done_i,
    // S5 SoC occupancy. Tie 0 when the TB has no DRAM slave.
    input  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats_i,
    input  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_w_beats_i
);

  localparam int unsigned NumQueues = (IslandCfg.Queues == 0) ? 1 : IslandCfg.Queues;
  localparam int unsigned QidWidth  = $bits(sb_qid_i);
  localparam int CmdCountW = IslandCfg.CommandDepth > 1 ? $clog2(IslandCfg.CommandDepth + 1) : 1;
  logic cmd_mode_q, cmd_prefer_sb_q;
  logic [63:0] cmd_ptr_q;
  logic [31:0] cmd_ticket_q, cmd_receipt_ticket_q, cmd_receipt_code_q;
  logic [31:0] cmd_accepted_q, cmd_rejected_q;
  logic [7:0] cmd_qid_q;
  logic [127:0] cmd_push_data, cmd_pop_data;
  logic cmd_push_valid, cmd_push_ready, cmd_pop_valid, cmd_dispatch;
  logic [CmdCountW-1:0] cmd_count;
  logic cmd_mmio_attempt, cmd_choose_sb, cmd_mmio_accept, cmd_quiescent;
  logic reg_write_error, reg_error_q;
  logic [11:0] cmd_region_decode;
  wire legacy_sb_valid = sb_enq_valid_i && !cmd_mode_q;  // L0 leaf
  // Completion FIFO: host may claim multiple finishes; engine still single-outstanding.
  // Depth is clamped, not scaled: the FIFO only has to cover how many finishes
  // may pile up before software claims, and QueueDepth=64 would buy 4x the
  // flops for a queue the single-outstanding engine can never fill.
  localparam int unsigned CplFifoDepth =
      (IslandCfg.QueueDepth == 0) ? 4 :
      (IslandCfg.QueueDepth > 16) ? 16 : IslandCfg.QueueDepth;
  localparam int unsigned CplCntW =
      (CplFifoDepth <= 1) ? 1 : $clog2(CplFifoDepth + 1);

  // pragma translate_off
  initial begin
    assert (island_cfg_legal(IslandCfg))
      else $error("g6lc_ai_island: illegal DramClass/DramGBps/Clusters (I3)");
    assert (IslandCfg.CommandDepth == 0 || EnableDmaFetch)
      else $error("g6lc_ai_island: command queue requires DMA");
  end
  // pragma translate_on

  // ------------------------------------------------------------------ cap
  logic [31:0] cap_rdata;
  logic        cap_rvalid;
  logic        cap_sel;
  // The capability window owns the first 256 bytes of the 4 KiB island BAR, so
  // one byte compare separates discovery (RO, registered inside i_cap) from
  // every control/descriptor/PMU register decoded in this file.
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7044  makespan=16.300 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: sb_ticket_alloc_q  ready_cycle=3  ready_fo4=16.300  OpenSTA: report_timing -from clk_i -to sb_ticket_alloc_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node25244 c=3.50 slack=12.80 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     sb_ticket_alloc_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node25245 c=16.30 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7047  makespan=21.450 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: sb_desc_hold_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to sb_desc_hold_q
// order expect: sb_enq_sticky_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to sb_enq_sticky_q
// order expect: sb_fetch_pending_q  ready_cycle=3  ready_fo4=21.450  OpenSTA: report_timing -from clk_i -to sb_fetch_pending_q
// order expect: sb_ptr_hold_q  ready_cycle=2  ready_fo4=10.500  OpenSTA: report_timing -from clk_i -to sb_ptr_hold_q
// order expect: sb_qid_hold_q  ready_cycle=3  ready_fo4=21.450  OpenSTA: report_timing -from clk_i -to sb_qid_hold_q
// order expect: sb_ticket_hold_q  ready_cycle=3  ready_fo4=21.450  OpenSTA: report_timing -from clk_i -to sb_ticket_hold_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node25265 c=3.50 slack=17.95 */
//     /* node25266 c=3.50 slack=17.95 */
//     /* node25267 c=3.50 slack=17.95 */
//     /* node25268 c=3.50 slack=17.95 */
//     /* node25269 c=3.50 slack=17.95 */
//     /* node25270 c=3.50 slack=17.95 */
//     /* node25283 c=6.50 slack=14.95 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     sb_desc_hold_q <= …; // sv-timing: cycle 2/3 on clk_i
//     sb_enq_sticky_q <= …; // sv-timing: cycle 2/3 on clk_i
//     sb_ptr_hold_q <= …; // sv-timing: cycle 2/3 on clk_i
//     /* node25271 c=8.50 slack=12.95 */
//     /* node25272 c=9.50 slack=11.95 */
//     /* node25273 c=9.50 slack=11.95 */
//     /* node25274 c=9.50 slack=11.95 */
//     /* node25275 c=9.50 slack=11.95 */
//     /* node25276 c=10.50 slack=10.95 */
//     /* node25277 c=10.50 slack=10.95 */
//     /* node25278 c=10.50 slack=10.95 */
//     /* node25279 c=10.50 slack=10.95 */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     sb_fetch_pending_q <= …; // sv-timing: cycle 3/3 on clk_i
//     sb_qid_hold_q <= …; // sv-timing: cycle 3/3 on clk_i
//     sb_ticket_hold_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node25280 c=21.45 slack=0.00 */
//     /* node25281 c=21.45 slack=0.00 */
//     /* node25282 c=21.45 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7049  makespan=19.650 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: job_src_sb_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to job_src_sb_q
// order expect: sb_retired_ticket_q  ready_cycle=3  ready_fo4=19.650  OpenSTA: report_timing -from clk_i -to sb_retired_ticket_q
// order expect: sb_retired_valid_q  ready_cycle=2  ready_fo4=14.650  OpenSTA: report_timing -from clk_i -to sb_retired_valid_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     job_src_sb_q <= …; // sv-timing: cycle 1/3 on clk_i
//     /* node25285 c=3.50 slack=16.15 */
//     /* node25286 c=3.50 slack=16.15 */
//     /* node25287 c=3.50 slack=16.15 */
//     /* node25288 c=4.50 slack=15.15 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     sb_retired_valid_q <= …; // sv-timing: cycle 2/3 on clk_i
//     /* node25289 c=14.65 slack=5.00 */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     sb_retired_ticket_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node25290 c=19.65 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7050  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: gemm_done_pend_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to gemm_done_pend_q
// order expect: wr_done_pend_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to wr_done_pend_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     gemm_done_pend_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_done_pend_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25291 c=3.50 slack=1.00 */
//     /* node25292 c=3.50 slack=1.00 */
//     /* node25293 c=4.50 slack=0.00 */
//     /* node25294 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7056  makespan=5.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: fetch_grant_q  ready_cycle=1  ready_fo4=5.500  OpenSTA: report_timing -from clk_i -to fetch_grant_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     fetch_grant_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25300 c=3.50 slack=2.00 */
//     /* node25301 c=5.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7085  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: gemm_done_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to gemm_done_q
// order expect: wr_done_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_done_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     gemm_done_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_done_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25333 c=3.50 slack=0.00 */
//     /* node25334 c=3.50 slack=0.00 */
//     /* node25335 c=3.50 slack=0.00 */
//     /* node25336 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7098  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: gemm_ar_max  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to gemm_ar_max
// order expect: pmu_policy_code_hold  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_code_hold
// order expect: pmu_policy_code_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_code_q
// order expect: pmu_policy_event_hold  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_event_hold
// order expect: pmu_policy_event_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_event_q
// order expect: pmu_policy_topo_hold  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_topo_hold
// order expect: pmu_policy_topo_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_topo_q
// order expect: pmu_policy_word_hold  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_word_hold
// order expect: pmu_policy_word_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_policy_word_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     gemm_ar_max <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_code_hold <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_code_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_event_hold <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_event_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_topo_hold <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_topo_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_word_hold <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_policy_word_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25349 c=3.50 slack=1.00 */
//     /* node25350 c=3.50 slack=1.00 */
//     /* node25351 c=3.50 slack=1.00 */
//     /* node25352 c=3.50 slack=1.00 */
//     /* node25353 c=3.50 slack=1.00 */
//     /* node25354 c=3.50 slack=1.00 */
//     /* node25355 c=3.50 slack=1.00 */
//     /* node25356 c=3.50 slack=1.00 */
//     /* node25357 c=3.50 slack=1.00 */
//     /* node25358 c=3.50 slack=1.00 */
//     /* node25359 c=3.50 slack=1.00 */
//     /* node25360 c=3.50 slack=1.00 */
//     /* node25361 c=3.50 slack=1.00 */
//     /* node25362 c=4.50 slack=0.00 */
//     /* node25363 c=4.50 slack=0.00 */
//     /* node25364 c=4.50 slack=0.00 */
//     /* node25365 c=4.50 slack=0.00 */
//     /* node25366 c=4.50 slack=0.00 */
//     /* node25367 c=4.50 slack=0.00 */
//     /* node25368 c=4.50 slack=0.00 */
//     /* node25369 c=4.50 slack=0.00 */
//     /* node25370 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7103  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: reg_error_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to reg_error_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     reg_error_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25387 c=3.50 slack=0.00 */
//     /* node25388 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7112  makespan=16.800 FO4  cycle_count=3  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cmd_accepted_q  ready_cycle=1  ready_fo4=6.500  OpenSTA: report_timing -from clk_i -to cmd_accepted_q
// order expect: cmd_mode_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to cmd_mode_q
// order expect: cmd_prefer_sb_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to cmd_prefer_sb_q
// order expect: cmd_ptr_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to cmd_ptr_q
// order expect: cmd_qid_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to cmd_qid_q
// order expect: cmd_receipt_code_q  ready_cycle=3  ready_fo4=16.800  OpenSTA: report_timing -from clk_i -to cmd_receipt_code_q
// order expect: cmd_receipt_ticket_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to cmd_receipt_ticket_q
// order expect: cmd_rejected_q  ready_cycle=1  ready_fo4=6.500  OpenSTA: report_timing -from clk_i -to cmd_rejected_q
// order expect: cmd_ticket_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to cmd_ticket_q
// --- factor stage 1/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cmd_accepted_q <= …; // sv-timing: cycle 1/3 on clk_i
//     cmd_prefer_sb_q <= …; // sv-timing: cycle 1/3 on clk_i
//     cmd_receipt_ticket_q <= …; // sv-timing: cycle 1/3 on clk_i
//     cmd_rejected_q <= …; // sv-timing: cycle 1/3 on clk_i
//     /* node25397 c=3.50 slack=13.30 */
//     /* node25398 c=3.50 slack=13.30 */
//     /* node25399 c=3.50 slack=13.30 */
//     /* node25400 c=3.50 slack=13.30 */
//     /* node25401 c=3.50 slack=13.30 */
//     /* node25402 c=3.50 slack=13.30 */
//     /* node25403 c=3.50 slack=13.30 */
//     /* node25404 c=3.50 slack=13.30 */
//     /* node25405 c=3.50 slack=13.30 */
//     /* node25406 c=4.50 slack=12.30 */
//     /* node25407 c=4.50 slack=12.30 */
//     /* node25409 c=6.50 slack=10.30 */
//     /* node25410 c=6.50 slack=10.30 */
//   end
// end
// --- factor stage 2/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cmd_mode_q <= …; // sv-timing: cycle 2/3 on clk_i
//     cmd_ptr_q <= …; // sv-timing: cycle 2/3 on clk_i
//     cmd_qid_q <= …; // sv-timing: cycle 2/3 on clk_i
//     cmd_ticket_q <= …; // sv-timing: cycle 2/3 on clk_i
//     /* node25411 c=9.50 slack=7.30 */
//     /* node25412 c=9.50 slack=7.30 */
//     /* node25413 c=9.50 slack=7.30 */
//     /* node25414 c=9.50 slack=7.30 */
//     /* node25415 c=9.50 slack=7.30 */
//   end
// end
// --- factor stage 3/3  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cmd_receipt_code_q <= …; // sv-timing: cycle 3/3 on clk_i
//     /* node25408 c=16.80 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7131  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cap_pending_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cap_pending_q
// order expect: rdata_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to rdata_q
// order expect: rvalid_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to rvalid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cap_pending_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rdata_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rvalid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25611 c=3.50 slack=1.00 */
//     /* node25612 c=3.50 slack=1.00 */
//     /* node25613 c=3.50 slack=1.00 */
//     /* node25614 c=3.50 slack=1.00 */
//     /* node25615 c=4.50 slack=0.00 */
//     /* node25616 c=4.50 slack=0.00 */
//     /* node25617 c=4.50 slack=0.00 */
//     /* node25618 c=4.50 slack=0.00 */
//     /* node25619 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_island_top  region=7132  makespan=5.546 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: pmu_rate_packed_q  ready_cycle=1  ready_fo4=5.546  OpenSTA: report_timing -from clk_i -to pmu_rate_packed_q
// order expect: pmu_rate_pending_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to pmu_rate_pending_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     pmu_rate_packed_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pmu_rate_pending_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node25620 c=3.50 slack=2.05 */
//     /* node25621 c=3.50 slack=2.05 */
//     /* node25622 c=3.50 slack=2.05 */
//     /* node25623 c=4.50 slack=1.05 */
//     /* node25624 c=5.55 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pmu_rate  region=7154  makespan=28.950 FO4  cycle_count=4  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: denominator_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to denominator_q
// order expect: denominator_term_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to denominator_term_q
// order expect: iteration_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to iteration_q
// order expect: numerator_q  ready_cycle=2  ready_fo4=9.500  OpenSTA: report_timing -from clk_i -to numerator_q
// order expect: numerator_term_q  ready_cycle=3  ready_fo4=17.500  OpenSTA: report_timing -from clk_i -to numerator_term_q
// order expect: quotient_q  ready_cycle=1  ready_fo4=7.318  OpenSTA: report_timing -from clk_i -to quotient_q
// order expect: rate_o  ready_cycle=4  ready_fo4=28.950  OpenSTA: report_timing -from clk_i -to rate_o
// order expect: remainder_q  ready_cycle=1  ready_fo4=7.318  OpenSTA: report_timing -from clk_i -to remainder_q
// order expect: state_q  ready_cycle=2  ready_fo4=15.718  OpenSTA: report_timing -from clk_i -to state_q
// --- factor stage 1/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     quotient_q <= …; // sv-timing: cycle 1/4 on clk_i
//     remainder_q <= …; // sv-timing: cycle 1/4 on clk_i
//     /* node25646 c=3.50 slack=25.45 */
//     /* node25647 c=3.50 slack=25.45 */
//     /* node25648 c=3.50 slack=25.45 */
//     /* node25649 c=3.50 slack=25.45 */
//     /* node25650 c=3.50 slack=25.45 */
//     /* node25651 c=3.50 slack=25.45 */
//     /* node25652 c=3.50 slack=25.45 */
//     /* node25653 c=3.50 slack=25.45 */
//     /* node25654 c=3.50 slack=25.45 */
//     /* node25663 c=3.50 slack=25.45 */
//     /* node25664 c=3.50 slack=25.45 */
//     /* node25665 c=4.50 slack=24.45 */
//     /* node25666 c=4.50 slack=24.45 */
//     /* node25667 c=4.57 slack=24.38 */
//     /* node25668 c=7.32 slack=21.63 */
//     /* node25669 c=7.32 slack=21.63 */
//     /* node25670 c=7.32 slack=21.63 */
//     /* node25671 c=7.32 slack=21.63 */
//     /* node25672 c=3.50 slack=25.45 */
//     /* node25673 c=5.00 slack=23.95 */
//     /* node25674 c=4.57 slack=24.38 */
//     /* node25677 c=3.50 slack=25.45 */
//     /* node25678 c=3.50 slack=25.45 */
//   end
// end
// --- factor stage 2/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     denominator_q <= …; // sv-timing: cycle 2/4 on clk_i
//     denominator_term_q <= …; // sv-timing: cycle 2/4 on clk_i
//     iteration_q <= …; // sv-timing: cycle 2/4 on clk_i
//     numerator_q <= …; // sv-timing: cycle 2/4 on clk_i
//     state_q <= …; // sv-timing: cycle 2/4 on clk_i
//     /* node25655 c=9.50 slack=19.45 */
//     /* node25656 c=9.50 slack=19.45 */
//     /* node25657 c=9.50 slack=19.45 */
//     /* node25659 c=9.50 slack=19.45 */
//     /* node25660 c=9.50 slack=19.45 */
//     /* node25661 c=9.50 slack=19.45 */
//     /* node25662 c=9.50 slack=19.45 */
//     /* node25676 c=15.72 slack=13.23 */
//   end
// end
// --- factor stage 3/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     numerator_term_q <= …; // sv-timing: cycle 3/4 on clk_i
//     /* node25658 c=17.50 slack=11.45 */
//   end
// end
// --- factor stage 4/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     rate_o <= …; // sv-timing: cycle 4/4 on clk_i
//     /* node25675 c=28.95 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign cap_sel = req_i && (addr_i[15:8] == 8'h00);

  // Forward declared: PMU hold lives with other regs below; default 0 until first GEMM
  logic [31:0] pmu_gbps_x1000_q;
  // A/B reads are full-width beats. C stores are 8-byte beats (a 4-byte
  // odd-n tail is billed as 8, which is the whole beat when the port is
  // 64 bits). Billing every handshake at AxiDataWidth would publish a C
  // store as 64 bytes on the 512-bit port.
  localparam int unsigned PmuBusBytes = AxiDataWidth / 8;
  localparam int unsigned PmuCBytes   = (PmuBusBytes > 8) ? 8 : PmuBusBytes;
  logic pmu_rate_valid, pmu_rate_pending_q, pmu_rate_packed_q;
  wire pmu_rate_req = EnableDmaFetch && req_i && !we_i &&
      ((addr_i[15:2] == PMU_OFF_GBPS_X1000[15:2]) ||
       (addr_i[15:2] == CAP_OFF_DRAM_MEAS_X1000[15:2]) ||
       (addr_i[15:2] == CAP_OFF_DRAM_GBPS[15:2]));

  // Single source for the granted-format bitmap: the capability window
  // publishes it and the descriptor engine enforces it. Binding both from one
  // value is what keeps discovery and enforcement from drifting -- a part
  // that advertised BF16 and then returned ST_BAD_FMT would be worse than one
  // that never advertised it.
  localparam logic [15:0] DtypeMaskLp = DtypeMask;

  // pragma translate_off
  // NOTE: these asserts do NOT currently execute in the Verilator flow --
  // `verilate_command` (Makefile:729) omits `--assert`, so Verilator skips every
  // assertion in the design, `config_pkg::check_cfg` included. Proven with a
  // standalone probe; tracked as AI-X5. They are written correctly and will
  // start enforcing the moment that flag lands. Do not treat them as a live
  // gate before then: the AI-X2 grant behaviour is proven instead by real
  // descriptor traffic (ai-numfmt-grant, both polarities).
  initial begin
    // A grant the PE cannot execute is worse than no grant: software discovers
    // the format through CAP_OFF_DTYPE_MASK, plans around it, and then every
    // descriptor comes back ST_BAD_FMT. Make raising the mask without the
    // datapath a build failure rather than a runtime surprise.
    // One string literal, NOT a brace concatenation: `{"a","b"}` is a bit
    // vector, so Verilator prints it as a giant decimal instead of using it as
    // the format, and the diagnostic becomes unreadable. Learned the hard way.
    // With IslandFpEn the operand banks hold 4-byte elements and the float dot is
    // usable, so the implemented set widens to AiIslandPeImplMaskFp.
    assert ((DtypeMaskLp & ~(AiCfg.IslandFpEn ? AiIslandPeImplMaskFp : AiIslandPeImplMask)) == 16'h0)
      else $error("g6lc_ai_island_top: AiIslandDtypeMask %h grants a format the PE does not implement (implemented %h); widen the datapath before the grant",
                  DtypeMaskLp, AiCfg.IslandFpEn ? AiIslandPeImplMaskFp : AiIslandPeImplMask);
    // Dense INT8 is the format the golden, the requant rule and every directed
    // test are written in, so a live island must always grant it.
    assert (DtypeMaskLp[config_pkg::AI_FMT_INT])
      else $error("g6lc_ai_island_top: AiIslandDtypeMask must grant AI_FMT_INT");
  end
  // pragma translate_on

  g6lc_ai_cap_window #(
      .IslandCfg(IslandCfg),
      .DtypeMask(DtypeMaskLp),
      .AccumulateEn(AccumulateEn),
      // Flat panel mapping: the K box is a byte capacity per operand bank
      // (g6lc_ai_gemm_seq OperandWords{A,B} * PeLanes; PeLanes = AccTileK lanes,
      // the column groups of a V2 array share the same total B bytes).
      .BankABytes(ai_operand_bank_bytes(IslandCfg.AccTileM, IslandCfg.AccTileK,
                                        (IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? IslandCfg.MacsPerCycle : IslandCfg.AccTileK,
                                        AiCfg.IslandFpEn ? 4 : 1)),
      .BankBBytes(ai_operand_bank_bytes(IslandCfg.AccTileN, IslandCfg.AccTileK,
                                        (IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? IslandCfg.MacsPerCycle : IslandCfg.AccTileK,
                                        AiCfg.IslandFpEn ? 4 : 1)),
      .DmaInvalEn(AiCfg.DmaInvalEn)
  ) i_cap (
      .clk_i, .rst_ni,
      .req_i   (cap_sel),
      .we_i    (we_i),
      .addr_i  (addr_i),
      .wdata_i (wdata_i),
      .dram_gbps_meas_x1000_i(pmu_gbps_x1000_q),
      .dram_init_done_i(dram_init_done_i),
      .ch_r_beats_i(ch_r_beats_i),
      .ch_w_beats_i(ch_w_beats_i),
      .rdata_o (cap_rdata),
      .rvalid_o(cap_rvalid)
  );

  // ------------------------------------------------------------------ regs
  logic              enable_q;
  logic              wr_cpl_en_q;  // CTL[1]: completion-word DMA (runtime)
  logic [31:0]       desc_words_q[16];
  logic [QidWidth-1:0] db_qid_q;
  logic [31:0]       db_ticket_q;
  logic              submit_pulse_q;
  logic              db_pending_q; // latched doorbell waiting for a free engine slot
  // Completion FIFO (replaces single done sticky overwrite)
  logic              cpl_push, cpl_pop;
  logic [31:0]       cpl_push_ticket;
  logic [15:0]       cpl_push_status;
  logic              cpl_push_irq;
  logic              cpl_empty, cpl_full;
  logic [31:0]       done_ticket_hold_q;
  logic [15:0]       done_status_hold_q;
  logic              done_sticky_q;   // !cpl_empty
  logic              head_irq;
  logic [CplCntW-1:0] cpl_count;
  logic [63:0]       desc_ptr_q;

  g6lc_ai_cpl_fifo #(
      .Depth(CplFifoDepth),
      .CntW (CplCntW)
  ) i_cpl_fifo (
      .clk_i,
      .rst_ni,
      .push_i   (cpl_push),
      .ticket_i (cpl_push_ticket),
      .status_i (cpl_push_status),
      .irq_i    (cpl_push_irq),
      .pop_i    (cpl_pop),
      .empty_o  (cpl_empty),
      .full_o   (cpl_full),
      .ticket_o (done_ticket_hold_q),
      .status_o (done_status_hold_q),
      .head_irq_o(head_irq),
      .count_o  (cpl_count)
  );
  assign done_sticky_q = ~cpl_empty;


  logic [63:0] base_q [NumQueues];
  logic [63:0] limit_q[NumQueues];
  logic [1:0]  perm_q [NumQueues];
  // Ownership epoch for exact reuse. Ignored unless VaTurboEn.
  logic [31:0] reuse_epoch_q;
  // Requested error-budget level. The applied nibble stays 0, and
  // gemm_seq does not read either register.
  logic [3:0]  va_level_req_q;
  logic [3:0]  pmu_va_level_q;
  // Requested recipe id. The applied id stays 0. gemm_seq does not read it.
  logic [4:0]  va_recipe_req_q;
  logic [4:0]  pmu_va_recipe_q;
  // Evidence-window claim. Cleared by an epoch, level, or recipe write.
  logic        window_valid_q;
  logic        pmu_window_q;

  // ------------------------------------------------------------------ check / engine
  logic        submit_ready, done_valid, busy_engine;
  logic [31:0] done_ticket;
  logic [15:0] done_status, last_status;
  logic        done_irq;
  logic        fetch_busy;
  logic        busy;
  assign busy = busy_engine || fetch_busy;

  logic                  prog_we;
  logic [QidWidth-1:0]   prog_qid;
  logic [AddrWidth-1:0]  prog_base, prog_limit;
  logic [1:0]            prog_perm;

  logic                  check_req, check_need_r, check_need_w, check_ok;
  logic [QidWidth-1:0]   check_qid;
  logic [AddrWidth-1:0]  check_addr, check_len;
  logic                  probe_req, probe_ok;
  logic [QidWidth-1:0]   probe_qid;
  logic [AddrWidth-1:0]  probe_addr, probe_len;
  logic                  sb_fetch_try, desc_fetch_ok;
  logic                  fetch_ready, fetch_done, fetch_err, fetch_start_q;
  logic                  fetch_submit_pending_q;
  logic [QidWidth-1:0]   fetch_qid_q;
  logic [31:0]           fetch_ticket_q;
  logic                  fetch_refuse_q, fetch_refuse_sb_q;
  logic [15:0]           fetch_refuse_status_q;
  logic [31:0]           fetch_refuse_ticket_q;
  logic                  fetch_refuse_fire;

  desc_bits_t desc_bits, db_desc_hold_q, sb_desc_hold_q, submit_desc_mux, fetch_desc;
  always_comb begin
    for (int unsigned i = 0; i < 16; i++) desc_bits[i*32 +: 32] = desc_words_q[i];
  end

  g6lc_ai_addr_check #(.NumQueues(NumQueues), .AddrWidth(AddrWidth), .QidWidth(QidWidth)) i_addr_check (
      .clk_i, .rst_ni,
      .prog_we_i     (prog_we),
      .prog_qid_i    (prog_qid),
      .prog_base_i   (prog_base),
      .prog_limit_i  (prog_limit),
      .prog_perm_i   (prog_perm),
      .check_req_i   (check_req),
      .check_qid_i   (check_qid),
      .check_addr_i  (check_addr),
      .check_len_i   (check_len),
      .check_need_r_i(check_need_r),
      .check_need_w_i(check_need_w),
      .check_ok_o    (check_ok),
      .probe_req_i   (probe_req),
      .probe_qid_i   (probe_qid),
      .probe_addr_i  (probe_addr),
      .probe_len_i   (probe_len),
      .probe_need_r_i(1'b1),
      .probe_need_w_i(1'b0),
      .probe_ok_o    (probe_ok)
  );

  // Stretch core sideband pulse: zero ptr ⇒ submit latched desc; non-zero
  // ptr ⇒ DMA-fetch then submit. Clear sticky on engine accept.
  logic        sb_enq_sticky_q;
  logic [7:0]  sb_qid_hold_q;
  logic [31:0] sb_ticket_hold_q;
  logic        sb_fetch_pending_q;  // sideband wait for DMA
  logic [63:0] sb_ptr_hold_q;
  logic        fetch_src_sb_q;      // 1=sideband kick, 0=doorbell[31]
  logic [63:0] fetch_addr_q;

  // Descriptor fetch is 64 bytes of 8-byte beats. Probe the committed window
  // for that range. Sideband wins the probe when both kicks land together.
  // E2b L1: flat leaf conjunction.
  assign sb_fetch_try = EnableDmaFetch && l_legacy_sb && l_sbptr_nz && fetch_ready;
  // The queue id rides in the doorbell write. The registered copy is the
  // previous doorbell, so a probe during that write has to use wdata.
  wire db_wr = req_i && we_i && (addr_i[15:0] == 16'h0108) && !cmd_mode_q;
  assign probe_req  = 1'b1;
  assign probe_qid  = cmd_mode_q ? (cmd_pop_valid ? QidWidth'(cmd_pop_data[103:96]) : '0) :
                      (sb_fetch_try ? QidWidth'(sb_qid_i) : (db_wr ? QidWidth'(wdata_i[7:0]) : db_qid_q));
  assign probe_addr = cmd_mode_q ? (cmd_pop_valid ? AddrWidth'(cmd_pop_data[63:0]) : '0) :
                      (sb_fetch_try ? sb_desc_ptr_i : desc_ptr_q);
  assign probe_len  = AddrWidth'(g6lc_ai_desc_pkg::DescBytes);
  // E2b L1: child output + leaf align.
  assign desc_fetch_ok = l_desc_ok;

  // Island-allocated sideband ticket: one stream for every producer.
  logic [31:0] sb_ticket_alloc_q;
  // SbTicketAlloc=0 keeps the producer's proposed ticket (single-producer
  // leaves and the legacy contract); the SoC cluster sets 1 so every core's
  // kicks draw from this one stream.
  wire  [31:0] sb_ticket_eff = SbTicketAlloc ? sb_ticket_alloc_q : sb_ticket_i;
  assign sb_enq_ticket_o = sb_ticket_eff;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sb_ticket_alloc_q <= '0;
    else if (sb_enq_valid_i && sb_enq_ready_o) sb_ticket_alloc_q <= sb_ticket_alloc_q + 32'd1;
  end
  // pragma translate_off
  // A lone producer counting its own accepted kicks proposes exactly the ticket
  // the island allocates; a mismatch means a second producer (or a reset skew)
  // and is reported once so the legacy assumption is visible, never silent.
  logic sb_ticket_mismatch_seen_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sb_ticket_mismatch_seen_q <= 1'b0;
    else if (sb_enq_valid_i && sb_enq_ready_o && (sb_ticket_i != sb_ticket_eff) && !sb_ticket_mismatch_seen_q) begin
      sb_ticket_mismatch_seen_q <= 1'b1;
      $display("[g6lc_ai_island] sideband ticket proposed %0d, allocated %0d (multi-producer stream)", sb_ticket_i, sb_ticket_eff);
    end
  end
  // pragma translate_on

  // Sideband same-cycle submit only when not DMA-fetching a ptr
  logic sb_imm_submit;
  assign sb_imm_submit = l_sb_imm;  // E2b: leaf (see L0 block)

  // Mux MMIO doorbell vs core sideband kick (sideband preferred).
  // A latched doorbell is one cycle wide. If the engine is busy, or the
  // completion FIFO is full, that pulse is held until a slot is free.
  // Disabled+idle still presents the pulse so the engine can return
  // ST_DISABLED.
  logic                  submit_valid_mux;
  logic                  submit_src_sb_mux;
  logic [QidWidth-1:0]   submit_qid_mux;
  logic [31:0]           submit_ticket_mux;
  // E2b L1: flat leaf conjunctions (l_eng_let reads leaves only).
  wire engine_let_through = l_eng_let;
  wire sb_let_through = l_eng_let && !fetch_submit_pending_q;
  wire db_let_through = l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm;
  always_comb begin
    submit_desc_mux = db_desc_hold_q;
    submit_src_sb_mux = 1'b0;
    if (fetch_submit_pending_q && engine_let_through) begin
      submit_valid_mux = 1'b1;
      submit_src_sb_mux = fetch_src_sb_q;
      submit_qid_mux = fetch_qid_q;
      submit_ticket_mux = fetch_ticket_q;
      submit_desc_mux = fetch_desc;
    end else if ((sb_enq_sticky_q || sb_imm_submit) && sb_let_through) begin
      submit_valid_mux  = 1'b1;
      submit_src_sb_mux = 1'b1;
      submit_qid_mux    = QidWidth'(sb_imm_submit ? sb_qid_i : sb_qid_hold_q);
      submit_ticket_mux = sb_imm_submit ? sb_ticket_eff : sb_ticket_hold_q;
      submit_desc_mux = sb_imm_submit ? desc_bits : sb_desc_hold_q;
    end else if ((submit_pulse_q || db_pending_q) && db_let_through) begin
      submit_valid_mux  = 1'b1;
      submit_qid_mux    = db_qid_q;
      submit_ticket_mux = db_ticket_q;
    end else begin
      submit_valid_mux  = 1'b0;
      submit_qid_mux    = db_qid_q;
      submit_ticket_mux = db_ticket_q;
    end
  end



  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sb_enq_sticky_q    <= 1'b0;
      sb_qid_hold_q      <= '0;
      sb_ticket_hold_q   <= '0;
      sb_fetch_pending_q <= 1'b0;
      sb_ptr_hold_q      <= '0;
      sb_desc_hold_q     <= '0;
    end else begin
      if (sb_let_through && (sb_enq_sticky_q || sb_imm_submit)) begin
        sb_enq_sticky_q <= 1'b0;
      end else if (sb_imm_submit && !sb_let_through) begin
        sb_enq_sticky_q  <= 1'b1;
        sb_qid_hold_q    <= sb_qid_i;
        sb_ticket_hold_q <= sb_ticket_eff;
        sb_desc_hold_q   <= desc_bits;
      end else if (EnableDmaFetch && legacy_sb_valid && (sb_desc_ptr_i != '0)
                   && desc_fetch_ok) begin
        // Hold identity for post-fetch submit
        sb_qid_hold_q      <= sb_qid_i;
        sb_ticket_hold_q   <= sb_ticket_eff;
        sb_ptr_hold_q      <= sb_desc_ptr_i;
        sb_fetch_pending_q <= 1'b1;
      end else if (EnableDmaFetch && legacy_sb_valid && (sb_desc_ptr_i != '0)) begin
        sb_qid_hold_q      <= sb_qid_i;
        sb_ticket_hold_q   <= sb_ticket_eff;
        sb_fetch_pending_q <= 1'b0;
      end
      // Once sideband DMA owns the identity, release its pending fetch slot.
      if (EnableDmaFetch && fetch_start_q && fetch_src_sb_q && !legacy_sb_valid)
        sb_fetch_pending_q <= 1'b0;
    end
  end

  // ------------------------------------------------------------------ DMA: fetch + completion store + GEMM (muxed AXI)
  logic        fetch_err_complete_q;  // retained until the error completion is accepted
  logic [31:0] fetch_err_ticket_q;
  logic        fetch_error_fire;

  // Sideband retired watermark (see sb_retired_* ports). The engine is single
  // outstanding, so the origin of the job it holds is one registered bit.
  logic        job_src_sb_q;
  logic        sb_retired_valid_q;
  logic [31:0] sb_retired_ticket_q;
  logic        retire_sb_push;
  assign retire_sb_push = (done_valid && job_src_sb_q) ||
                          (!done_valid && fetch_error_fire && fetch_src_sb_q) ||
                          (!done_valid && !fetch_error_fire && fetch_refuse_fire && fetch_refuse_sb_q);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      job_src_sb_q        <= 1'b0;
      sb_retired_valid_q  <= 1'b0;
      sb_retired_ticket_q <= '0;
    end else begin
      if (submit_valid_mux && submit_ready) job_src_sb_q <= submit_src_sb_mux;
      if (retire_sb_push && cpl_push) begin
        sb_retired_valid_q <= 1'b1;
        if (!sb_retired_valid_q || cpl_push_ticket > sb_retired_ticket_q)
          sb_retired_ticket_q <= cpl_push_ticket;
      end
    end
  end
  logic [3:0]  gemm_ar_max;

  logic        wr_start, wr_ready, wr_done, wr_err;
  // DMA-write invalidation barrier (see gen_dma_inval): the engine sees a job's
  // gemm_done / wr_done only once every line the job wrote is invalid everywhere.
  logic        dma_inval_idle;
  logic [31:0] pmu_dma_invals, pmu_dma_hold;
  logic        gemm_done_pend_q, wr_done_pend_q;
  logic        gemm_done_eng, wr_done_eng;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gemm_done_pend_q <= 1'b0;
      wr_done_pend_q   <= 1'b0;
    end else begin
      gemm_done_pend_q <= (gemm_done_pend_q || gemm_done) && !gemm_done_eng;
      wr_done_pend_q   <= (wr_done_pend_q || wr_done) && !wr_done_eng;
    end
  end
  // Pass-through when nothing is owed (the AiCfg.DmaInvalEn=0 build is exact).
  assign gemm_done_eng = (gemm_done || gemm_done_pend_q) && dma_inval_idle;
  assign wr_done_eng   = (wr_done   || wr_done_pend_q)   && dma_inval_idle;
  logic [AddrWidth-1:0] wr_addr;
  logic [63:0] wr_data;
  // Split so the request mux is checked bit-by-bit rather than as one aggregate
  // (see the split_var note in g6lc_ai_gemm_seq).
  axi_req_t    fetch_axi_req /*verilator split_var*/, store_axi_req /*verilator split_var*/,
               gemm_axi_req /*verilator split_var*/;

  // I1-lite GEMM handshake / params (engine → unit)
  logic        gemm_start, gemm_ready, gemm_engine_ready, gemm_done, gemm_err;
  logic [31:0] gemm_m, gemm_n, gemm_k, gemm_flags;
  logic [15:0] gemm_lda, gemm_ldb;
  logic [2:0]  gemm_numfmt;
  logic [AddrWidth-1:0] gemm_ptr_a, gemm_ptr_b, gemm_ptr_c;
  // I3 PMU from last GEMM job (pmu_gbps_x1000_q declared above for CAP)
  logic [31:0] gemm_pmu_r, gemm_pmu_w, gemm_pmu_cy;
  logic [31:0] pmu_r_hold_q, pmu_w_hold_q, pmu_cy_hold_q;
  logic [3:0][31:0] gemm_pmu_phase, pmu_phase_hold_q;
  logic [2:0][31:0] gemm_pmu_stall, pmu_stall_hold_q;
  // F15: policy codec/steering sticky snapshot (last GEMM job)
  logic [31:0] pmu_policy_code_q, pmu_policy_word_q,
               pmu_policy_topo_q, pmu_policy_event_q;
  logic [31:0] pmu_policy_code_hold, pmu_policy_word_hold,
               pmu_policy_topo_hold, pmu_policy_event_hold;

  if (EnableDmaFetch) begin : gen_dma_fetch
    g6lc_ai_pmu_rate #(
        .ReadBytes(PmuBusBytes), .WriteBytes(PmuCBytes), .ClockKhz(IslandCfg.ClockKhz)
    ) i_pmu_rate (
        .clk_i, .rst_ni, .start_i(pmu_rate_req),
        .reads_i(pmu_r_hold_q), .writes_i(pmu_w_hold_q), .cycles_i(pmu_cy_hold_q),
        .ready_o(), .valid_o(pmu_rate_valid), .rate_o(pmu_gbps_x1000_q)
    );
    axi_req_t  dma_mux_req /*verilator split_var*/;
    axi_resp_t dma_resp_int /*verilator split_var*/;
    axi_resp_t fetch_axi_resp /*verilator split_var*/;
    axi_resp_t store_axi_resp /*verilator split_var*/;
    axi_resp_t gemm_axi_resp  /*verilator split_var*/;
    logic      fetch_grant_q;
    g6lc_ai_desc_fetch #(
        .AddrWidth  (AddrWidth),
        .DataWidth  (AxiDataWidth),
        .IdWidth    (AxiIdWidth),
        .NrChannels (IslandCfg.DramChannels),
        .ChanShift  (IslandCfg.DramChanShift),
        .axi_req_t  (axi_req_t),
        .axi_resp_t (axi_resp_t)
    ) i_fetch (
        .clk_i,
        .rst_ni,
        .start_i (fetch_start_q),
        .addr_i  (AddrWidth'(fetch_addr_q)),
        .ready_o (fetch_ready),
        .done_o  (fetch_done),
        .err_o   (fetch_err),
        .desc_o  (fetch_desc),
        .grant_i (fetch_grant_q),
        .axi_req_o  (fetch_axi_req),
        .axi_resp_i (fetch_axi_resp)
    );
    g6lc_ai_mem_store #(
        .AddrWidth (AddrWidth),
        .DataWidth (AxiDataWidth),
        .IdWidth   (AxiIdWidth),
        .axi_req_t (axi_req_t),
        .axi_resp_t(axi_resp_t)
    ) i_store (
        .clk_i,
        .rst_ni,
        .start_i (wr_start),
        .addr_i  (wr_addr),
        .data_i  (AxiDataWidth'(wr_data)),
        .ready_o (wr_ready),
        .done_o  (wr_done),
        .err_o   (wr_err),
        .axi_req_o  (store_axi_req),
        .axi_resp_i (store_axi_resp)
    );
    // Geometry from IslandCfg. M, N and K are separate so the VA panels
    // 512×512, 512×256 and 1024×128 share one MAC issue width.
    // pragma translate_off
    initial begin
      assert (IslandCfg.MacsPerCycle >= 1 && IslandCfg.AccTileM >= 1 &&
              IslandCfg.AccTileN >= 1 && IslandCfg.AccTileK >= 1)
      else $error("g6lc_ai_island: MacsPerCycle and AccTile must be >= 1");
      assert (island_cfg_out_cols(IslandCfg) >= 1 &&
              IslandCfg.MacsPerCycle == island_cfg_out_cols(IslandCfg) * island_cfg_pe_lanes(IslandCfg))
      else $error("g6lc_ai_island: MacsPerCycle must be OutCols x PeLanes (PeLanes <= AccTileK)");
      // Clusters > 1 elaborates g6lc_ai_cluster_dispatch (N engines, one master);
      // every cluster present is enabled (a partial enable mask is a policy, not
      // a datapath, and is not modelled here).
      assert (IslandCfg.Clusters >= 1 && (IslandCfg.Clusters & (IslandCfg.Clusters - 1)) == 0 &&
              IslandCfg.ClustersEnabled == IslandCfg.Clusters)
      else $error("g6lc_ai_island: Clusters must be a power of two with every cluster enabled");
      assert (IslandCfg.Clusters == 1 || AxiIdWidth > $clog2(IslandCfg.Clusters))
      else $error("g6lc_ai_island: AxiIdWidth too narrow to prefix %0d clusters", IslandCfg.Clusters);
    end
    // pragma translate_on
    if (IslandCfg.Clusters == 1) begin : gen_one_engine
    g6lc_ai_gemm_seq #(
          .AddrWidth (AddrWidth),
          .DataWidth (AxiDataWidth),
          .IdWidth   (AxiIdWidth),
          .MaxDim    (IslandCfg.AccTileM),
          .MaxM      (IslandCfg.AccTileM),
          .MaxN      (IslandCfg.AccTileN),
          .MaxK      (IslandCfg.AccTileK),
          // K lanes per dot and output columns per cycle from MacsPerCycle vs AccTileK
          // (island_cfg_pe_lanes / island_cfg_out_cols). Plain arithmetic here, not the package function:
          // the simulator does not fold a struct-argument function in a parameter port.
          .PeLanes   ((IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? IslandCfg.MacsPerCycle : IslandCfg.AccTileK),
          .OutCols   ((IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? 1 : IslandCfg.MacsPerCycle / IslandCfg.AccTileK),
          .MaxAROut  (IslandCfg.MaxAROut),
          // VaTurboEn enables reuse. It does not widen PeLanes.
          .ReuseBEn  (AiCfg.VaTurboEn),
          .ReuseBSlots(ReuseBSlots),
          .ReuseAEn  (AiCfg.VaTurboEn),
          .MaxElementBytes(AiCfg.IslandFpEn ? 4 : 1),
          .NrChannels(IslandCfg.DramChannels),
          .ChanShift (IslandCfg.DramChanShift),
          // Live dot cells are the pipelines (r2 default-cell decision,
          // rank 1): int dot on g6lc_ai_pe_dot_pipe, float dot on
          // g6lc_ai_pe_dot_float_pipe; the comb cells stay as non-live
          // equivalence oracles (clock_exclude_ai.txt).
          .DotPipeInt   (1'b1),
          .DotPipeFloat (1'b1),
          .axi_req_t (axi_req_t),
          .axi_resp_t(axi_resp_t)
      ) i_gemm (
          .clk_i,
          .rst_ni,
          .testmode_i(testmode_i),
          .start_i  (gemm_start),
          .m_i      (gemm_m),
          .n_i      (gemm_n),
          .k_i      (gemm_k),
          .lda_i    (gemm_lda),
          .ldb_i    (gemm_ldb), .ldc_i(16'd0),
          .numfmt_i (gemm_numfmt),
          .accumulate_i(AccumulateEn && (gemm_flags[FLAG_ACCMODE_SHIFT +: FLAG_ACCMODE_WIDTH] == 2'd1)),
          .ar_max_i (gemm_ar_max),
          .ptr_a_i  (gemm_ptr_a),
          .ptr_b_i  (gemm_ptr_b),
          .ptr_c_i  (gemm_ptr_c),
          .ready_o  (gemm_engine_ready),
          .done_o   (gemm_done),
          .err_o    (gemm_err),
          .pmu_r_beats_o(gemm_pmu_r),
          .pmu_w_beats_o(gemm_pmu_w),
          .pmu_cycles_o (gemm_pmu_cy),
          .pmu_phase_o  (gemm_pmu_phase),
          .pmu_stall_o  (gemm_pmu_stall),
          // VaTurboEn=0 folds both requests to 0 and keeps invalidate set,
          // which is the exact fetch. A set flag is a residency request for
          // the 512×k operand, not an extra MAC.
          .reuse_b_i(AiCfg.VaTurboEn && gemm_flags[FLAG_REUSE_B_SHIFT]),
          .reuse_b_epoch_i(AiCfg.VaTurboEn ? reuse_epoch_q : 32'd0),
          .reuse_b_invalidate_i(!AiCfg.VaTurboEn),
          .pmu_reuse_b_hit_o(),
          .reuse_a_i(AiCfg.VaTurboEn && gemm_flags[FLAG_REUSE_A_SHIFT]),
          .reuse_a_epoch_i(AiCfg.VaTurboEn ? reuse_epoch_q : 32'd0),
          .reuse_a_invalidate_i(!AiCfg.VaTurboEn),
          .pmu_reuse_a_hit_o(),
          .axi_req_o  (gemm_axi_req),
          .axi_resp_i (gemm_axi_resp)
      );
  end else begin : gen_clusters
      // Engine-side AXI types: the dispatch's axi_mux prefixes clog2(Clusters) ID
      // bits, so each engine runs on AxiIdWidth - clog2(Clusters).
      localparam int unsigned EngIdW = AxiIdWidth - $clog2(IslandCfg.Clusters);
      typedef logic [AddrWidth-1:0]      eng_addr_t;
      typedef logic [EngIdW-1:0]         eng_id_t;
      typedef logic [AxiDataWidth-1:0]   eng_data_t;
      typedef logic [AxiDataWidth/8-1:0] eng_strb_t;
      typedef logic [0:0]                eng_user_t;
      `AXI_TYPEDEF_ALL(eng, eng_addr_t, eng_id_t, eng_data_t, eng_strb_t, eng_user_t)
      // r11: the mst-side channel typedefs for the dispatch's axi_mux --
      // a separate prefix so the generated req/resp names don't clash
      // with the parameter axi_req_t/axi_resp_t.
      typedef logic [AddrWidth-1:0]      mst_axi_addr_t;
      typedef logic [AxiIdWidth-1:0]     mst_axi_id_t;
      typedef logic [AxiDataWidth-1:0]   mst_axi_data_t;
      typedef logic [AxiDataWidth/8-1:0] mst_axi_strb_t;
      typedef logic [0:0]                mst_axi_user_t;
      `AXI_TYPEDEF_ALL(mst_axi, mst_axi_addr_t, mst_axi_id_t,
                       mst_axi_data_t, mst_axi_strb_t, mst_axi_user_t)
      g6lc_ai_cluster_dispatch #(
          .AddrWidth (AddrWidth),
          .DataWidth (AxiDataWidth),
          .IdWidth   (AxiIdWidth),
          .Clusters  (IslandCfg.Clusters),
          .MaxDim    (IslandCfg.AccTileM),
          .MaxM      (IslandCfg.AccTileM),
          .MaxN      (IslandCfg.AccTileN),
          .MaxK      (IslandCfg.AccTileK),
          // K lanes per dot and output columns per cycle from MacsPerCycle vs AccTileK
          // (island_cfg_pe_lanes / island_cfg_out_cols). Plain arithmetic here, not the package function:
          // the simulator does not fold a struct-argument function in a parameter port.
          .PeLanes   ((IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? IslandCfg.MacsPerCycle : IslandCfg.AccTileK),
          .OutCols   ((IslandCfg.MacsPerCycle <= IslandCfg.AccTileK) ? 1 : IslandCfg.MacsPerCycle / IslandCfg.AccTileK),
          .MaxAROut  (IslandCfg.MaxAROut),
          // VaTurboEn enables reuse. It does not widen PeLanes.
          .ReuseBEn  (AiCfg.VaTurboEn),
          .ReuseBSlots(ReuseBSlots),
          .ReuseAEn  (AiCfg.VaTurboEn),
          .MaxElementBytes(AiCfg.IslandFpEn ? 4 : 1),
          .NrChannels(IslandCfg.DramChannels),
          .ChanShift (IslandCfg.DramChanShift),
          .DotPipeInt   (1'b1),
          .DotPipeFloat (1'b1),
          .axi_req_t (axi_req_t),
          .axi_resp_t(axi_resp_t),
          .eng_req_t (eng_req_t),
          .eng_resp_t(eng_resp_t),
          .eng_aw_chan_t (eng_aw_chan_t), .eng_w_chan_t (eng_w_chan_t),
          .eng_b_chan_t  (eng_b_chan_t),  .eng_ar_chan_t(eng_ar_chan_t),
          .eng_r_chan_t  (eng_r_chan_t),
          .mst_aw_chan_t (mst_axi_aw_chan_t), .mst_w_chan_t (mst_axi_w_chan_t),
          .mst_b_chan_t  (mst_axi_b_chan_t),  .mst_ar_chan_t(mst_axi_ar_chan_t),
          .mst_r_chan_t  (mst_axi_r_chan_t)
        ) i_gemm (
          .clk_i,
          .rst_ni,
          .testmode_i(testmode_i),
          .start_i  (gemm_start),
          .m_i      (gemm_m),
          .n_i      (gemm_n),
          .k_i      (gemm_k),
          .lda_i    (gemm_lda),
          .ldb_i    (gemm_ldb),
          .numfmt_i (gemm_numfmt),
          .accumulate_i(AccumulateEn && (gemm_flags[FLAG_ACCMODE_SHIFT +: FLAG_ACCMODE_WIDTH] == 2'd1)),
          .ar_max_i (gemm_ar_max),
          .ptr_a_i  (gemm_ptr_a),
          .ptr_b_i  (gemm_ptr_b),
          .ptr_c_i  (gemm_ptr_c),
          .ready_o  (gemm_engine_ready),
          .done_o   (gemm_done),
          .err_o    (gemm_err),
          .pmu_r_beats_o(gemm_pmu_r),
          .pmu_w_beats_o(gemm_pmu_w),
          .pmu_cycles_o (gemm_pmu_cy),
          .pmu_phase_o  (gemm_pmu_phase),
          .pmu_stall_o  (gemm_pmu_stall),
          // VaTurboEn=0 folds both requests to 0 and keeps invalidate set,
          // which is the exact fetch. A set flag is a residency request for
          // the 512×k operand, not an extra MAC.
          .reuse_b_i(AiCfg.VaTurboEn && gemm_flags[FLAG_REUSE_B_SHIFT]),
          .reuse_b_epoch_i(AiCfg.VaTurboEn ? reuse_epoch_q : 32'd0),
          .reuse_b_invalidate_i(!AiCfg.VaTurboEn),
          .pmu_reuse_b_hit_o(),
          .reuse_a_i(AiCfg.VaTurboEn && gemm_flags[FLAG_REUSE_A_SHIFT]),
          .reuse_a_epoch_i(AiCfg.VaTurboEn ? reuse_epoch_q : 32'd0),
          .reuse_a_invalidate_i(!AiCfg.VaTurboEn),
          .pmu_reuse_a_hit_o(),
          .axi_req_o  (gemm_axi_req),
          .axi_resp_i (gemm_axi_resp)
      );
  end

    // Priority: completion store > GEMM > desc fetch. When all idle, drive a
    // clean zero req (no b_ready) so the DMA master cannot siphon B beats from
    // the xbar — that was observed to break subsequent PLIC claim.
    logic store_active, gemm_active;
    assign store_active = (!wr_ready || wr_start);
    assign gemm_active  = (!gemm_ready || gemm_start);
    // The final '0 arm is the important one: an idle master that still drives
    // b_ready/r_ready will accept a response addressed to someone else.
    assign dma_mux_req = store_active ? store_axi_req
                       : gemm_active  ? gemm_axi_req
                       : (!fetch_ready ? fetch_axi_req : '0);

    // Response skid buffers can accept while their client is idle. Qualify
    // responses with the same owner as requests so a descriptor R or status B
    // cannot enter an inactive GEMM buffer.
    assign store_axi_resp = store_active ? dma_resp_int : '0;
    assign gemm_axi_resp  = (!store_active && gemm_active) ? dma_resp_int : '0;
    assign fetch_axi_resp = (!store_active && !gemm_active && !fetch_ready) ? dma_resp_int : '0;
    // The fetch shares this response. Sample ownership in a flop so the
    // grant does not comb-loop through fetch_ready, and so a GEMM beat
    // cannot retire a descriptor read.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) fetch_grant_q <= 1'b0;
      else fetch_grant_q <= !fetch_ready && !store_active && !gemm_active;
    end
    // Registered boundary toward the fabric (see g6lc_ai_axi_cut).
    axi_req_t  cut_req  /*verilator split_var*/;
    axi_resp_t cut_resp /*verilator split_var*/;
    g6lc_ai_axi_cut #(.axi_req_t(axi_req_t), .axi_resp_t(axi_resp_t), .Bypass(!AxiCutEn)) i_axi_cut (
        .clk_i, .rst_ni,
        .slv_req_i(cut_req), .slv_resp_o(cut_resp),
        .mst_req_o(axi_dma_req_o), .mst_resp_i(axi_dma_resp_i)
    );
    // DMA-write invalidation queue (AiCfg.DmaInvalEn). Sits on the muxed master
    // in front of the cut/timing stage: it sees every AW/B of the island's single
    // write stream, holds AW (valid and ready both masked) while it is full, and
    // reports idle when every write landed and was invalidated. The engine's
    // gemm_done / wr_done are held behind that idle so a completion (DONE sticky,
    // IRQ, ptr_done word) is never visible before the job's lines are invalid
    // in every L1/L2/L3.
    axi_req_t  held_req  /*verilator split_var*/;
    axi_resp_t held_resp /*verilator split_var*/;
    logic      dma_aw_hold;
    if (AiCfg.DmaInvalEn) begin : gen_dma_inval
      g6lc_ai_inval_queue #(
          .AddrWidth(AddrWidth), .LineBytes(64), .Depth(8)
      ) i_inval_queue (
          .clk_i, .rst_ni,
          .aw_fire_i    (held_req.aw_valid && held_resp.aw_ready),
          .aw_addr_i    (held_req.aw.addr),
          .aw_len_i     (held_req.aw.len),
          .aw_size_i    (held_req.aw.size),
          .b_fire_i     (held_resp.b_valid && held_req.b_ready),
          .aw_hold_o    (dma_aw_hold),
          .inval_valid_o(dma_inval_valid_o),
          .inval_addr_o (dma_inval_addr_o),
          .inval_ready_i(dma_inval_ready_i),
          .inval_done_i (dma_inval_done_i),
          .idle_o       (dma_inval_idle),
          .pmu_invals_o (pmu_dma_invals),
          .pmu_hold_o   (pmu_dma_hold)
      );
    end else begin : gen_no_dma_inval
      assign dma_aw_hold       = 1'b0;
      assign dma_inval_idle    = 1'b1;
      assign dma_inval_valid_o = 1'b0;
      assign dma_inval_addr_o  = '0;
      assign pmu_dma_invals    = '0;
      assign pmu_dma_hold      = '0;
      logic _unused_inval;
      assign _unused_inval = dma_inval_ready_i | dma_inval_done_i;
    end
    always_comb begin
      held_req          = dma_mux_req;
      held_req.aw_valid = dma_mux_req.aw_valid && !dma_aw_hold;
      dma_resp_int          = held_resp;
      dma_resp_int.aw_ready = held_resp.aw_ready && !dma_aw_hold;
    end
    // I3: DDR4 page-command delay on island DMA only (Cas==0 = live bypass).
    if (IslandCfg.DramCas == 0) begin : gen_dram_t_bypass
      assign cut_req   = held_req;
      assign held_resp = cut_resp;
    end else begin : gen_dram_t_page
      g6lc_ai_dram_timing #(
          .CasCycles  (IslandCfg.DramCas),
          .TrcdCycles (IslandCfg.DramTrcd),
          .TrpCycles  (IslandCfg.DramTrp),
          .AddrWidth  (AddrWidth),
          .axi_req_t  (axi_req_t),
          .axi_resp_t (axi_resp_t)
      ) i_dram_timing (
          .clk_i,
          .rst_ni,
          .slv_req_i  (held_req),
          .slv_resp_o (held_resp),
          .mst_req_o  (cut_req),
          .mst_resp_i (cut_resp)
      );
    end
    // Any active DMA sub-unit counts as busy, so STATUS[1] tells software the
    // island still owns the bus even when the descriptor engine itself is idle.
    assign fetch_busy = !fetch_ready || sb_fetch_pending_q || !wr_ready || !gemm_ready;
  end else begin : gen_no_dma_fetch
    assign pmu_gbps_x1000_q = '0;
    assign pmu_rate_valid = 1'b0;
    assign fetch_ready = 1'b1;
    assign fetch_done  = 1'b0;
    assign fetch_err   = 1'b0;
    assign fetch_desc  = '0;
    assign fetch_busy  = 1'b0;
    assign fetch_axi_req = '0;
    assign store_axi_req = '0;
    assign gemm_axi_req  = '0;
    assign axi_dma_req_o = '0;
    assign dma_inval_valid_o = 1'b0;
    assign dma_inval_addr_o  = '0;
    assign dma_inval_idle    = 1'b1;
    assign pmu_dma_invals    = '0;
    assign pmu_dma_hold      = '0;
    assign wr_ready = 1'b1;
    // One-cycle delayed ack so engine sees wr_issued_q && wr_done_i
    // (same-cycle wr_done=wr_start leaves ST_WR_DONE wedged).
    logic wr_done_q, gemm_done_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        wr_done_q   <= 1'b0;
        gemm_done_q <= 1'b0;
      end else begin
        wr_done_q   <= wr_start;
        gemm_done_q <= gemm_start;
      end
    end
    assign wr_done    = wr_done_q;
    assign wr_err     = 1'b0;
    assign gemm_engine_ready = 1'b1;
    assign gemm_done  = gemm_done_q;
    assign gemm_err   = 1'b0;  // accept-only path when no DMA master
    assign gemm_pmu_r  = '0;
    assign gemm_pmu_w  = '0;
    assign gemm_pmu_cy = '0;
    assign gemm_pmu_phase = '0;
    assign gemm_pmu_stall = '0;
    // verilator lint_off UNUSEDSIGNAL
    logic _ax;
    assign _ax = |axi_dma_resp_i | sb_fetch_pending_q | |sb_desc_ptr_i
                 | |wr_addr | |wr_data
                 | |gemm_m | |gemm_n | |gemm_k | |gemm_lda | |gemm_ldb
                 | |gemm_numfmt
                 | |gemm_ptr_a | |gemm_ptr_b | |gemm_ptr_c;
    // verilator lint_on UNUSEDSIGNAL
  end

  // ------------------------------------------------------------------
  // F15: policy codec/steering (observable/PMU first consumer)
  //
  // Metadata producer: the accepted GEMM descriptor job (gemm_start pulse).
  // First consumer: sticky MMIO snapshot of the selected policy and steering
  // events, exposed through new PMU offsets.  No control back into the GEMM
  // sequencer yet; dense GEMM behavior is unchanged when policy is disabled or
  // the format is unsupported.
  //
  // Placed outside the DMA-fetch generate so the live SoC path (EnableDmaFetch=1)
  // and the standalone spine smoke (EnableDmaFetch=0) see the same PMU interface.
  // When EnableDmaFetch=0 the descriptor engine's ExecuteGemm is also 0, so
  // gemm_start is never asserted and the policy remains idle.
  // ------------------------------------------------------------------
  logic             policy_ready, policy_work_valid;
  localparam bit PolicyEnabled = AiCfg.PolicyCodecEn && AiCfg.PolicyBenefitEn;
  logic policy_publish_ready, policy_flush;
  // Admission owns the pulse: a busy policy evaluator cannot lose gemm_start.
  // Flush on the failed job's completion, not its sticky err level (which is
  // only cleared by the next start and would otherwise deadlock admission).
  assign policy_flush = gemm_done && gemm_err;
  assign gemm_ready = gemm_engine_ready &&
      (!PolicyEnabled || (policy_ready && policy_publish_ready));
  logic             policy_eval, policy_commit, policy_hold;
  logic             policy_predict_hit, policy_predict_miss;
  logic             policy_warm_valid, policy_residual_skip;
  policy_code_t     policy_code, policy_next_code;
  policy_t          policy, policy_next;
  logic [2:0]       policy_numfmt;
  policy_topology_t policy_topology_value;

  g6lc_ai_policy_steer #(
    .AiCfg(AiCfg),
    .ReadBytesPerCycle(IslandCfg.NocWidth / 8)
  ) i_policy_steer (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .enable_i   (AiCfg.PolicyCodecEn),
    .flush_i    (policy_flush),
    .valid_i    (gemm_start),
    .batch_first_i(gemm_start),
    .batch_last_i (gemm_start),
    .m_i        (gemm_m[15:0]),
    .n_i        (gemm_n[15:0]),
    .k_i        (gemm_k[15:0]),
    .opcode_i   (3'd0),
    .balance_i  (2'd1),
    .numfmt_i   (gemm_numfmt),
    .sample_i   ('0),
    .sample_valid_i(1'b0),
    .exact_zero_i(1'b0),
    .next_addr_i   ('0),
    .next_addr_valid_i(1'b0),
    .mispredict_i  (1'b0),
    .ready_o    (policy_ready),
    .work_valid_o(policy_work_valid),
    .code_o     (policy_code),
    .next_code_o(policy_next_code),
    .policy_o   (policy),
    .next_policy_o(policy_next),
    .warm_valid_o(policy_warm_valid),
    .warm_addr_o(),
    .warm_bank_o(),
    .residual_skip_o(policy_residual_skip),
    .eval_o     (policy_eval),
    .commit_o   (policy_commit),
    .hold_o     (policy_hold),
    .predict_hit_o(policy_predict_hit),
    .predict_miss_o(policy_predict_miss),
    .numfmt_o   (policy_numfmt),
    .topology_o (policy_topology_value),
    .subcode_valid_o(), .subcode_evaluated_o(), .subcode_cache_hit_o(), .subcode_o(), .subcode_topology_o(),
    .subcode_baseline_cycles_o(), .subcode_selected_cycles_o()
  );

  // Aggregate event/status snapshot into one 32-bit word.
  logic [31:0] policy_event_word;
  assign policy_event_word = {24'h0,
                              policy_topology_value.apply, policy_warm_valid,
                              policy_residual_skip, policy_predict_miss,
                              policy_predict_hit, policy_hold, policy_commit,
                              policy_eval};

  // Result and completion may arrive in either order, including on one edge.
  // A single owner prevents the next job overwriting an unfinished PMU record.
  logic [127:0] policy_payload, policy_snapshot;
  assign pmu_policy_code_hold = {21'h0, 3'(policy_next_code), 3'(policy_code), 5'h0};
  assign pmu_policy_word_hold = {7'h0, 2'(policy.dataflow),
      4'(policy.tile_m_log2), 4'(policy.tile_n_log2), 4'(policy.tile_k_log2),
      policy.sparse_check, 2'(policy.prefetch_depth), 8'(policy_numfmt)};
  assign pmu_policy_topo_hold = {9'h0, policy_topology_value.valid,
      policy_topology_value.apply, policy_topology_value.rows_log2,
      policy_topology_value.cols_log2, policy_topology_value.reduction_log2,
      policy_topology_value.slots_log2, policy_topology_value.element_bits_log2,
      policy_topology_value.gain_16ths};
  assign pmu_policy_event_hold = policy_event_word;
  assign policy_payload = {pmu_policy_code_hold, pmu_policy_word_hold,
                           pmu_policy_topo_hold, pmu_policy_event_hold};
  assign {pmu_policy_code_q, pmu_policy_word_q, pmu_policy_topo_q,
          pmu_policy_event_q} = policy_snapshot;
  assign gemm_ar_max = 4'(IslandCfg.MaxAROut);
  g6lc_ai_policy_publish i_policy_publish (
    .clk_i, .rst_ni, .start_i(gemm_start && PolicyEnabled),
    .done_i(gemm_done), .cancel_i(policy_flush),
    .result_valid_i(policy_work_valid), .result_i(policy_payload),
    .ready_o(policy_publish_ready), .snapshot_o(policy_snapshot)
  );

  g6lc_ai_desc_engine #(
      .NumQueues       (NumQueues),
      .AddrWidth       (AddrWidth),
      .QidWidth        (QidWidth),
      .WriteCompletion (EnableDmaFetch),
      .ExecuteGemm     (EnableDmaFetch),
      .DtypeMask       (DtypeMaskLp),
      .AccumulateEn    (AccumulateEn),
      .BeatBytes       (AxiDataWidth / 8)
  ) i_engine (
      .clk_i, .rst_ni,
      .testmode_i      (testmode_i),
      .enable_i        (enable_q),
      .wr_cpl_en_i     (wr_cpl_en_q),
      .submit_valid_i  (submit_valid_mux),
      .submit_ready_o  (submit_ready),
      .submit_qid_i    (submit_qid_mux),
      .submit_ticket_i (submit_ticket_mux),
      .submit_desc_i   (submit_desc_mux),
      .done_valid_o    (done_valid),
      .done_ticket_o   (done_ticket),
      .done_status_o   (done_status),
      .done_irq_o      (done_irq),
      .prog_we_o       (),
      .prog_qid_o      (),
      .prog_base_o     (),
      .prog_limit_o    (),
      .prog_perm_o     (),
      .prog_ext_we_i   (prog_we),
      .prog_ext_qid_i  (prog_qid),
      .prog_ext_base_i (prog_base),
      .prog_ext_limit_i(prog_limit),
      .prog_ext_perm_i (prog_perm),
      .check_req_o     (check_req),
      .check_qid_o     (check_qid),
      .check_addr_o    (check_addr),
      .check_len_o     (check_len),
      .check_need_r_o  (check_need_r),
      .check_need_w_o  (check_need_w),
      .check_ok_i      (check_ok),
      .busy_o          (busy_engine),
      .last_status_o   (last_status),
      .wr_start_o      (wr_start),
      .wr_addr_o       (wr_addr),
      .wr_data_o       (wr_data),
      .wr_ready_i      (wr_ready),
      .wr_done_i       (wr_done_eng),
      .wr_err_i        (wr_err),
      .gemm_start_o    (gemm_start),
      .gemm_m_o        (gemm_m),
      .gemm_n_o        (gemm_n),
      .gemm_k_o        (gemm_k),
      .gemm_lda_o      (gemm_lda),
      .gemm_ldb_o      (gemm_ldb),
      .gemm_numfmt_o   (gemm_numfmt),
      .gemm_ptr_a_o    (gemm_ptr_a),
      .gemm_ptr_b_o    (gemm_ptr_b),
      .gemm_ptr_c_o    (gemm_ptr_c),
      .gemm_flags_o    (gemm_flags),
      .gemm_ready_i    (gemm_ready),
      .gemm_done_i     (gemm_done_eng),
      .gemm_err_i      (gemm_err)
  );

  // ------------------------------------------------------------------ writes + prog pulse
  always_comb begin
    logic [11:0] qd;
    int unsigned q;
    q = 0;
    qd = ai_queue_decode(addr_i[15:0], NumQueues);
    prog_we    = 1'b0;
    prog_qid   = '0;
    prog_base  = '0;
    prog_limit = '0;
    prog_perm  = '0;
    if (req_i && we_i && qd[11] && !reg_write_error) begin
      q = qd[10:3];
      if (q < NumQueues && qd[2:0] == 3'd4) begin
        // Commit region on perm write; base/limit already stored
        // Perm is the commit trigger so a half-programmed region can never go
        // live: base/lo/hi land in local regs first and only this write arms them.
        prog_we    = 1'b1;
        prog_qid   = QidWidth'(q);
        prog_base  = AddrWidth'(base_q[q]);
        prog_limit = AddrWidth'(limit_q[q]);
        prog_perm  = wdata_i[1:0];
      end
    end
  end

  // The fetch, the GEMM, and the completion store share one AXI response.
  // Descriptor checks leave the GEMM unit idle and then start it, so a kick
  // during a job waits until the engine itself is idle and no new job is
  // accepted on this cycle.
  // E2b L1: db_let_through's leaf set inlined (no L1->L1 read).
  wire dma_quiet = !busy_engine && gemm_ready && wr_ready
                   && !gemm_start && !wr_start
                   && !l_sb_stk_or_imm
                   && !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q
                        && !l_sb_stk_or_imm);

  assign cmd_region_decode = ai_queue_decode(addr_i, NumQueues);
  assign cmd_quiescent = cmd_count == 0 && cpl_empty && !busy_engine && !fetch_busy &&
      fetch_ready && !fetch_start_q && !fetch_submit_pending_q && !fetch_err_complete_q &&
      !fetch_refuse_q && !db_pending_q && !submit_pulse_q && !sb_enq_sticky_q &&
      !sb_fetch_pending_q && !sb_enq_valid_i && !done_valid;
  assign reg_write_error = IslandCfg.CommandDepth != 0 && req_i && we_i &&
      ((cmd_mode_q && (addr_i == REG_OFF_CTL || addr_i == REG_OFF_DOORBELL ||
                       cmd_region_decode[11] || addr_i == REG_OFF_REUSE_EPOCH ||
                       addr_i == REG_OFF_VA_TURBO_LEVEL || addr_i == REG_OFF_VA_TURBO_RECIPE ||
                       addr_i == REG_OFF_VA_TURBO_WINDOW)) ||
       (addr_i == REG_OFF_CMD_MODE && wdata_i[0] != cmd_mode_q &&
        (!cmd_quiescent || (wdata_i[0] && !enable_q))));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) reg_error_q <= 1'b0;
    else reg_error_q <= reg_write_error;
  end
  assign rerror_o = reg_error_q;
  assign cmd_mmio_attempt = IslandCfg.CommandDepth != 0 && req_i && we_i &&
      addr_i == REG_OFF_CMD_SUBMIT && wdata_i[0];
  assign cmd_choose_sb = sb_enq_valid_i && (!cmd_mmio_attempt || cmd_prefer_sb_q);
  assign cmd_push_valid = cmd_mode_q && enable_q && (cmd_choose_sb || cmd_mmio_attempt);
  // Bit 104 tags the origin (1 = core sideband) so its completion can move the
  // sideband retired watermark.
  assign cmd_push_data = cmd_choose_sb ? {23'd0, 1'b1, sb_qid_i, sb_ticket_eff, sb_desc_ptr_i} :
                                          {23'd0, 1'b0, cmd_qid_q, cmd_ticket_q, cmd_ptr_q};
  assign cmd_mmio_accept = cmd_mmio_attempt && cmd_push_valid && !cmd_choose_sb && cmd_push_ready;
  assign sb_enq_ready_o = !cmd_mode_q ||
      (enable_q && cmd_push_ready && (!cmd_mmio_attempt || cmd_prefer_sb_q));
  // E2b L1: dma_quiet's leaf set inlined.
  assign cmd_dispatch = cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
      !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start &&
      !l_sb_stk_or_imm &&
      !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm) &&
      fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
      !fetch_err_complete_q && !fetch_refuse_q && !done_valid;

  if (IslandCfg.CommandDepth != 0) begin : gen_command_fifo
    g6lc_ai_cmd_fifo #(.Depth(IslandCfg.CommandDepth)) i_commands (
        .clk_i, .rst_ni, .testmode_i,
        .push_valid_i(cmd_push_valid), .push_ready_o(cmd_push_ready), .push_data_i(cmd_push_data),
        .pop_valid_o(cmd_pop_valid), .pop_ready_i(cmd_dispatch), .pop_data_o(cmd_pop_data), .count_o(cmd_count)
    );
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cmd_mode_q <= 1'b0;
        cmd_prefer_sb_q <= 1'b1;
        cmd_ptr_q <= '0;
        cmd_ticket_q <= '0;
        cmd_qid_q <= '0;
        cmd_receipt_ticket_q <= '0;
        cmd_receipt_code_q <= CMD_DISABLED;
        cmd_accepted_q <= '0;
        cmd_rejected_q <= '0;
      end else begin
        if (cmd_push_valid && cmd_push_ready) cmd_prefer_sb_q <= !cmd_choose_sb;
        if (cmd_mmio_attempt) begin
          cmd_receipt_ticket_q <= cmd_ticket_q;
          cmd_receipt_code_q <= !cmd_mode_q || !enable_q ? CMD_DISABLED :
                                (cmd_mmio_accept ? CMD_ACCEPTED : CMD_FULL);
          if (cmd_mmio_accept) cmd_accepted_q <= cmd_accepted_q + 32'd1;
          else cmd_rejected_q <= cmd_rejected_q + 32'd1;
        end
        if (req_i && we_i && !reg_write_error) begin
          case (addr_i)
            REG_OFF_CMD_MODE: cmd_mode_q <= wdata_i[0];
            REG_OFF_CMD_PTR_LO: cmd_ptr_q[31:0] <= wdata_i;
            REG_OFF_CMD_PTR_HI: cmd_ptr_q[63:32] <= wdata_i;
            REG_OFF_CMD_TICKET: cmd_ticket_q <= wdata_i;
            REG_OFF_CMD_QID: cmd_qid_q <= wdata_i[7:0];
            default: ;
          endcase
        end
      end
    end
  end else begin : gen_no_command_fifo
    assign cmd_push_ready = 1'b0;
    assign cmd_pop_valid = 1'b0;
    assign cmd_pop_data = '0;
    assign cmd_count = '0;
    assign cmd_mode_q = 1'b0;
    assign cmd_prefer_sb_q = 1'b1;
    assign cmd_ptr_q = '0;
    assign cmd_ticket_q = '0;
    assign cmd_qid_q = '0;
    assign cmd_receipt_ticket_q = '0;
    assign cmd_receipt_code_q = '0;
    assign cmd_accepted_q = '0;
    assign cmd_rejected_q = '0;
  end

  // E2b: two-level predicate layer. L0 = leaves only (a register, an
  // input, a child output, or ONE operator on those; shared
  // sub-conjunctions are L0 only when they read leaves exclusively).
  // L1 = every consumer predicate as ONE flat conjunction/disjunction of
  // L0 leaves -- no L1 may read another L1.
  logic l_sbptr_nz, l_dbptr_nz, l_legacy_sb, l_db_try, l_db_wdata31;
  logic l_desc_ok, l_sb_imm, l_sb_stk_or_imm, l_pend_or_pulse, l_cpl_room;
  logic l_eng_let;
  always_comb begin
    l_sbptr_nz      = (sb_desc_ptr_i != '0);
    l_dbptr_nz      = (desc_ptr_q != '0);
    l_legacy_sb     = sb_enq_valid_i && !cmd_mode_q;
    l_db_try        = req_i && we_i && !reg_write_error && (addr_i[15:0] == 16'h0108);
    l_db_wdata31    = wdata_i[31];
    l_desc_ok       = probe_ok && (probe_addr[2:0] == 3'b0);
    l_sb_imm        = l_legacy_sb && (!EnableDmaFetch || !l_sbptr_nz);
    l_sb_stk_or_imm = sb_enq_sticky_q || l_sb_imm;
    l_pend_or_pulse = submit_pulse_q || db_pending_q;
    l_cpl_room      = (cpl_room_free < (CplCntW+3)'(CplFifoDepth));
    l_eng_let       = !cpl_full && !cpl_push && fetch_ready && !fetch_start_q
                      && (submit_ready || (!enable_q && !busy_engine));
  end

  // pragma translate_off
  // E2b reference: the nested-form predicates the flat layer replaced.
  logic ref_engine_lt, ref_sb_lt, ref_db_lt, ref_dma_quiet, ref_cmd_disp,
        ref_sft, ref_dfo, ref_eerr, ref_eref, ref_cmdq, ref_rwe;
  always_comb begin
    ref_engine_lt = !cpl_full && !cpl_push && fetch_ready && !fetch_start_q &&
        (submit_ready || (!enable_q && !busy_engine));
    ref_sb_lt = ref_engine_lt && !fetch_submit_pending_q;
    ref_db_lt = ref_sb_lt && !(sb_enq_sticky_q || sb_imm_submit);
    ref_dma_quiet = !busy_engine && gemm_ready && wr_ready && !gemm_start &&
        !wr_start && !(sb_enq_sticky_q || sb_imm_submit) &&
        !((submit_pulse_q || db_pending_q) && ref_db_lt);
    ref_sft = EnableDmaFetch && legacy_sb_valid && (sb_desc_ptr_i != '0) && fetch_ready;
    ref_dfo = probe_ok && (probe_addr[2:0] == 3'b0);
    ref_cmd_disp = cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
        ref_dma_quiet && fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !done_valid;
    ref_eerr = EnableDmaFetch && fetch_err_complete_q && !done_valid &&
        (cpl_room_free < (CplCntW+3)'(CplFifoDepth));
    ref_eref = fetch_refuse_q && !done_valid && !ref_eerr &&
        !(EnableDmaFetch && fetch_done && fetch_err) &&
        (cpl_room_free < (CplCntW+3)'(CplFifoDepth));
    ref_cmdq = cmd_count == 0 && cpl_empty && !busy_engine && !fetch_busy &&
        fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !db_pending_q &&
        !submit_pulse_q && !sb_enq_sticky_q && !sb_fetch_pending_q &&
        !sb_enq_valid_i && !done_valid;
    ref_rwe = IslandCfg.CommandDepth != 0 && req_i && we_i &&
        ((cmd_mode_q && (addr_i == REG_OFF_CTL || addr_i == REG_OFF_DOORBELL ||
                         cmd_region_decode[11] || addr_i == REG_OFF_REUSE_EPOCH ||
                         addr_i == REG_OFF_VA_TURBO_LEVEL || addr_i == REG_OFF_VA_TURBO_RECIPE ||
                         addr_i == REG_OFF_VA_TURBO_WINDOW)) ||
         (addr_i == REG_OFF_CMD_MODE && wdata_i[0] != cmd_mode_q &&
          (!ref_cmdq || (wdata_i[0] && !enable_q))));
  end
  int unsigned g6lc_ai_pred_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_pred_eq <= 0;
    else begin
      g6lc_ai_pred_eq <= g6lc_ai_pred_eq + 1;
      assert (engine_let_through == ref_engine_lt && sb_let_through == ref_sb_lt
              && db_let_through == ref_db_lt && dma_quiet == ref_dma_quiet
              && cmd_dispatch == ref_cmd_disp && fetch_error_fire == ref_eerr
              && fetch_refuse_fire == ref_eref && cmd_quiescent == ref_cmdq
              && reg_write_error == ref_rwe)
        else $error("g6lc_ai_island_top: pred_eq mismatch %b vs %b",
                    {engine_let_through, sb_let_through, db_let_through, dma_quiet,
                     cmd_dispatch, fetch_error_fire, fetch_refuse_fire,
                     cmd_quiescent, reg_write_error},
                    {ref_engine_lt, ref_sb_lt, ref_db_lt, ref_dma_quiet,
                     ref_cmd_disp, ref_eerr, ref_eref, ref_cmdq, ref_rwe});
    end
  end
  final $display("[equiv] g6lc_ai_island_top pred_eq: checked=%0d", g6lc_ai_pred_eq);
  // pragma translate_on

  // E2: fetch/submit arm predicates, computed once as mutually exclusive
  // wires (each arm includes the negation of the higher-priority arms;
  // db sits highest because in the original sequential block the MMIO
  // doorbell write came last and overrode the fifo/sb arms).
  logic fa_cmd_ok, fa_cmd_refuse, fa_sb, fa_sb_refuse, fa_db_ok, fa_db_refuse;
  // r7 R7/P6: db doorbell arms are the leaf family; cmd/sb arms read them.
  always_comb begin
    fa_db_ok = EnableDmaFetch && req_i && we_i && !reg_write_error
        && (addr_i[15:0] == 16'h0108) && wdata_i[31]
        && (desc_ptr_q != '0) && fetch_ready && !fetch_start_q
        && !fetch_submit_pending_q && !fetch_err_complete_q
        && !(EnableDmaFetch && l_legacy_sb && l_sbptr_nz && fetch_ready)
        && l_desc_ok;
    fa_db_refuse = EnableDmaFetch && req_i && we_i && !reg_write_error
        && (addr_i[15:0] == 16'h0108) && wdata_i[31]
        && (desc_ptr_q != '0) && fetch_ready && !fetch_start_q
        && !fetch_submit_pending_q && !fetch_err_complete_q
        && !(EnableDmaFetch && l_legacy_sb && l_sbptr_nz && fetch_ready)
        && !l_desc_ok;
  end
  always_comb begin
    fa_cmd_ok = cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
        !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start &&
        !l_sb_stk_or_imm &&
        !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm) &&
        fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !done_valid
        && !(32'(cmd_pop_data[103:96]) >= NumQueues
             || cmd_pop_data[63:0] == 0 || !l_desc_ok)
        && !fa_db_ok && !fa_db_refuse;
    fa_cmd_refuse = cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
        !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start &&
        !l_sb_stk_or_imm &&
        !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm) &&
        fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !done_valid
        && (32'(cmd_pop_data[103:96]) >= NumQueues
            || cmd_pop_data[63:0] == 0 || !l_desc_ok)
        && !fa_db_ok && !fa_db_refuse;
    fa_sb = !(cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
        !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start &&
        !l_sb_stk_or_imm &&
        !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm) &&
        fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !done_valid)
        && EnableDmaFetch && fetch_ready && !fetch_start_q
        && !fetch_submit_pending_q && !fetch_err_complete_q
        && !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start
        && !l_sb_stk_or_imm
        && !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm)
        && ((l_legacy_sb && l_sbptr_nz && l_desc_ok)
            || (sb_fetch_pending_q && !l_legacy_sb))
        && !fa_db_ok && !fa_db_refuse;
    fa_sb_refuse = !(cmd_mode_q && enable_q && cmd_pop_valid && !cpl_full && !cpl_push &&
        !busy_engine && gemm_ready && wr_ready && !gemm_start && !wr_start &&
        !l_sb_stk_or_imm &&
        !(l_pend_or_pulse && l_eng_let && !fetch_submit_pending_q && !l_sb_stk_or_imm) &&
        fetch_ready && !fetch_start_q && !fetch_submit_pending_q &&
        !fetch_err_complete_q && !fetch_refuse_q && !done_valid)
        && EnableDmaFetch && l_legacy_sb && l_sbptr_nz && fetch_ready && !l_desc_ok
        && !fa_db_ok && !fa_db_refuse;
  end

  // pragma translate_off
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (rst_ni) begin
      assert ($onehot0({fa_cmd_ok, fa_cmd_refuse, fa_sb, fa_sb_refuse,
                        fa_db_ok, fa_db_refuse}))
        else $error("g6lc_ai_island_top: fetch arm not onehot0 %b",
                    {fa_cmd_ok, fa_cmd_refuse, fa_sb, fa_sb_refuse,
                     fa_db_ok, fa_db_refuse});
    end
  end
  int unsigned g6lc_ai_fetch_arm_oh;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_fetch_arm_oh <= 0;
    else g6lc_ai_fetch_arm_oh <= g6lc_ai_fetch_arm_oh + 1;
  end
  final $display("[equiv] g6lc_ai_island_top fetch_arm_oh: checked=%0d",
                 g6lc_ai_fetch_arm_oh);
  // pragma translate_on

  // E2c: the fetch/submit/state registers are split into per-group
  // always_ff blocks (was one ~180-line monolithic block; the analyzer
  // billed every non-blocking write as a serial statement chain).
  // Each register is written in exactly one block; guards are the same
  // expressions as before, recomputed per block from the write-class
  // one-hot below. Same last-write-wins order inside each block.
  logic mmio_we;
  logic w_is_100, w_is_108, w_is_118, w_is_11c, w_in_descwin, w_in_queue;
  logic [11:0] w_qdec;
  logic [NumQueues-1:0] w_qhit;
  // r7 R7/P6: one always_comb per output family -- the single block
  // composed all nine writes as a serial makespan (~51.8).
  always_comb begin
    mmio_we = req_i && we_i && !reg_write_error;
  end
  always_comb begin
    w_qdec = ai_queue_decode(addr_i[15:0], NumQueues);
    for (int unsigned q = 0; q < NumQueues; q++)
      w_qhit[q]  = w_qdec[11] && (w_qdec[10:3] == 8'(q));
  end
  always_comb begin
    w_is_100     = mmio_we && (addr_i[15:0] == 16'h0100);
    w_is_108     = mmio_we && (addr_i[15:0] == 16'h0108);
    w_is_118     = mmio_we && (addr_i[15:0] == 16'h0118);
    w_is_11c     = mmio_we && (addr_i[15:0] == 16'h011C);
    w_in_descwin = mmio_we && (addr_i[15:0] >= 16'h0140) && (addr_i[15:0] < 16'h0180);
  end
  always_comb begin
    w_in_queue   = mmio_we && !w_is_100 && !w_is_108 && !w_is_118 && !w_is_11c
                   && !w_in_descwin
                   && !(addr_i[15:0] == REG_OFF_REUSE_EPOCH
                        || addr_i[15:0] == REG_OFF_VA_TURBO_LEVEL
                        || addr_i[15:0] == REG_OFF_VA_TURBO_RECIPE
                        || addr_i[15:0] == REG_OFF_VA_TURBO_WINDOW)
                   && w_qdec[11];
  end

  // ---- fetch arm registers: addr/qid/ticket/src/start ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_start_q  <= 1'b0;
      fetch_ticket_q <= '0;
      fetch_qid_q    <= '0;
      fetch_src_sb_q <= 1'b0;
      fetch_addr_q   <= '0;
    end else begin
      fetch_start_q <= 1'b0;
      unique case (1'b1)
        fa_cmd_ok: begin
          fetch_addr_q   <= cmd_pop_data[63:0];
          fetch_qid_q    <= QidWidth'(cmd_pop_data[103:96]);
          fetch_ticket_q <= cmd_pop_data[95:64];
          fetch_src_sb_q <= cmd_pop_data[104];
          fetch_start_q  <= 1'b1;
        end
        fa_sb: begin
          fetch_addr_q   <= (legacy_sb_valid && (sb_desc_ptr_i != '0)) ? sb_desc_ptr_i
                                                                      : sb_ptr_hold_q;
          fetch_src_sb_q <= 1'b1;
          fetch_start_q  <= 1'b1;
          fetch_ticket_q <= (legacy_sb_valid && sb_desc_ptr_i != '0) ? sb_ticket_eff : sb_ticket_hold_q;
          fetch_qid_q    <= QidWidth'((legacy_sb_valid && sb_desc_ptr_i != '0) ? sb_qid_i : sb_qid_hold_q);
        end
        fa_db_ok: begin
          fetch_addr_q   <= desc_ptr_q;
          fetch_src_sb_q <= 1'b0;
          fetch_start_q  <= 1'b1;
          fetch_ticket_q <= {9'h0, wdata_i[30:8]};
          fetch_qid_q    <= QidWidth'(wdata_i[7:0]);
        end
        default: ;
      endcase
    end
  end

  // ---- fetch refuse registers ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_refuse_q        <= 1'b0;
      fetch_refuse_sb_q     <= 1'b0;
      fetch_refuse_status_q <= ST_BAD_PTR;
      fetch_refuse_ticket_q <= '0;
    end else begin
      if (fetch_refuse_fire) begin
        fetch_refuse_q    <= 1'b0;
        fetch_refuse_sb_q <= 1'b0;
      end
      unique case (1'b1)
        fa_cmd_refuse: begin
          fetch_refuse_q        <= 1'b1;
          fetch_refuse_sb_q     <= cmd_pop_data[104];
          fetch_refuse_ticket_q <= cmd_pop_data[95:64];
          fetch_refuse_status_q <= 32'(cmd_pop_data[103:96]) >= NumQueues ? ST_BAD_QID : ST_BAD_PTR;
        end
        fa_sb_refuse: begin
          fetch_refuse_q        <= 1'b1;
          fetch_refuse_sb_q     <= 1'b1;
          fetch_refuse_status_q <= (32'(sb_qid_i) >= NumQueues) ? ST_BAD_QID : ST_BAD_PTR;
          fetch_refuse_ticket_q <= sb_ticket_eff;
        end
        fa_db_refuse: begin
          fetch_refuse_q        <= 1'b1;
          fetch_refuse_sb_q     <= 1'b0;
          fetch_refuse_status_q <= (32'(wdata_i[7:0]) >= NumQueues) ? ST_BAD_QID : ST_BAD_PTR;
          fetch_refuse_ticket_q <= {9'h0, wdata_i[30:8]};
        end
        default: ;
      endcase
    end
  end

  // ---- fetch error / submit-pending ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_err_complete_q   <= 1'b0;
      fetch_err_ticket_q     <= '0;
      fetch_submit_pending_q <= 1'b0;
    end else begin
      if (fetch_error_fire) fetch_err_complete_q <= 1'b0;
      if (fetch_submit_pending_q && engine_let_through) fetch_submit_pending_q <= 1'b0;
      if (EnableDmaFetch && fetch_done) begin
        if (fetch_err) begin
          fetch_err_complete_q <= 1'b1;
          fetch_err_ticket_q   <= fetch_ticket_q;
        end else begin
          fetch_submit_pending_q <= 1'b1;
        end
      end
    end
  end

  // ---- descriptor word latch: fetch_done fill + MMIO 0x140 window ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < 16; i++) desc_words_q[i] <= '0;
    end else begin
      if (EnableDmaFetch && fetch_done && !fetch_err) begin
        for (int unsigned i = 0; i < 16; i++)
          desc_words_q[i] <= fetch_desc[i*32 +: 32];
      end
      if (w_in_descwin) desc_words_q[addr_i[5:2]] <= wdata_i;
    end
  end

  // ---- enable / wr-cpl ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      enable_q    <= 1'b0;
      wr_cpl_en_q <= EnableDmaFetch;  // on when DMA path present
    end else if (w_is_100) begin
      enable_q    <= wdata_i[0];
      wr_cpl_en_q <= wdata_i[1];
    end
  end

  // ---- doorbell registers + submit pulse/pending ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      db_qid_q       <= '0;
      db_ticket_q    <= '0;
      db_desc_hold_q <= '0;
      submit_pulse_q <= 1'b0;
      db_pending_q   <= 1'b0;
    end else begin
      submit_pulse_q <= 1'b0;
      if (submit_pulse_q && !db_let_through)
        db_pending_q <= 1'b1;
      else if (db_pending_q && db_let_through)
        db_pending_q <= 1'b0;
      if (fa_db_ok || fa_db_refuse)
        db_pending_q <= 1'b0;
      if (w_is_108) begin
        db_qid_q       <= QidWidth'(wdata_i[7:0]);
        db_ticket_q    <= {9'h0, wdata_i[30:8]};
        db_desc_hold_q <= desc_bits;
        // [31]=fetch_from_mem moved to the fa_db_ok/fa_db_refuse arms (E2).
        // The else arm below is the immediate submit of the latched desc.
        if (!(EnableDmaFetch && wdata_i[31] && (desc_ptr_q != '0)))
          submit_pulse_q <= 1'b1;
      end
    end
  end

  // ---- descriptor pointer ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) desc_ptr_q <= '0;
    else begin
      if (w_is_118) desc_ptr_q[31:0]  <= wdata_i;
      if (w_is_11c) desc_ptr_q[63:32] <= wdata_i;
    end
  end

  // ---- epoch / VA turbo request registers ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reuse_epoch_q  <= '0;
      va_level_req_q <= '0;
      va_recipe_req_q <= '0;
      window_valid_q <= 1'b0;
    end else if (mmio_we) begin
      if (addr_i[15:0] == REG_OFF_REUSE_EPOCH) begin
        reuse_epoch_q <= wdata_i;
        window_valid_q <= 1'b0;
      end else if (addr_i[15:0] == REG_OFF_VA_TURBO_LEVEL) begin
        va_level_req_q <= wdata_i[3:0];
        window_valid_q <= 1'b0;
      end else if (addr_i[15:0] == REG_OFF_VA_TURBO_RECIPE) begin
        va_recipe_req_q <= wdata_i[4:0];
        window_valid_q <= 1'b0;
      end else if (addr_i[15:0] == REG_OFF_VA_TURBO_WINDOW) begin
        window_valid_q <= wdata_i[0];
      end
    end
  end

  // ---- queue base/limit/perm (queue-region writes) ----
  // E4: per-queue generate -- each queue's three registers live in their
  // own always_ff under the constant-compare write one-hot (w_qhit[q]);
  // no runtime index into the register arrays.
  for (genvar q = 0; q < NumQueues; q++) begin : gen_queue_regs
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        base_q[q]  <= '0;
        limit_q[q] <= '0;
        perm_q[q]  <= '0;
      end else if (w_in_queue && w_qhit[q]) begin
        unique case (w_qdec[2:0])
          3'd0: base_q[q][31:0]   <= wdata_i;
          3'd1: base_q[q][63:32]  <= wdata_i;
          3'd2: limit_q[q][31:0]  <= wdata_i;
          3'd3: limit_q[q][63:32] <= wdata_i;
          3'd4: perm_q[q]         <= wdata_i[1:0];
          default: ;
        endcase
      end
    end
  end

  // ---- GEMM PMU latches ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pmu_va_level_q   <= '0;
      pmu_va_recipe_q  <= '0;
      pmu_window_q     <= 1'b0;
      pmu_r_hold_q     <= '0;
      pmu_w_hold_q     <= '0;
      pmu_cy_hold_q    <= '0;
      pmu_phase_hold_q <= '0;
      pmu_stall_hold_q <= '0;
    end else begin
      if (gemm_done) begin
        pmu_va_level_q  <= va_level_req_q;
        pmu_va_recipe_q <= va_recipe_req_q;
        pmu_window_q    <= window_valid_q;
      end
      if (EnableDmaFetch && gemm_done) begin
        pmu_r_hold_q     <= gemm_pmu_r;
        pmu_w_hold_q     <= gemm_pmu_w;
        pmu_cy_hold_q    <= gemm_pmu_cy;
        pmu_phase_hold_q <= gemm_pmu_phase;
        pmu_stall_hold_q <= gemm_pmu_stall;
      end
    end
  end

  // E2: the completion-room check is computed once at CplCntW+3 bits
  // (the four boolean terms need at most +3 above the counter width);
  // the two fire terms share it instead of two separate 32-bit sums.
  logic [CplCntW+2:0] cpl_room_free;
  assign cpl_room_free = (CplCntW+3)'(cpl_count) + (CplCntW+3)'(busy_engine)
      + (CplCntW+3)'(!fetch_ready) + (CplCntW+3)'(fetch_start_q)
      + (CplCntW+3)'(fetch_submit_pending_q);
  // E2b L1: flat leaf conjunctions on l_cpl_room; fetch_error_fire's
  // leaf set is inlined inside fetch_refuse_fire (no L1->L1 read).
  assign fetch_error_fire = EnableDmaFetch && fetch_err_complete_q && !done_valid &&
      l_cpl_room;
  assign fetch_refuse_fire = fetch_refuse_q && !done_valid
      && !(EnableDmaFetch && fetch_err_complete_q && !done_valid && l_cpl_room)
      && !(EnableDmaFetch && fetch_done && fetch_err)
      && l_cpl_room;

  // Completion FIFO push/pop (combinational one-cycle pulses into i_cpl_fifo)
  always_comb begin
    cpl_push         = 1'b0;
    cpl_pop          = 1'b0;
    cpl_push_ticket  = '0;
    cpl_push_status  = '0;
    cpl_push_irq     = 1'b0;
    // Engine completion
    if (done_valid) begin
      cpl_push        = 1'b1;
      cpl_push_ticket = done_ticket;
      cpl_push_status = done_status;
      cpl_push_irq    = done_irq;
    end else if (fetch_error_fire) begin
      cpl_push        = 1'b1;
      cpl_push_ticket = fetch_err_ticket_q;
      cpl_push_status = ST_ERR;
      cpl_push_irq    = 1'b0;
    end else if (fetch_refuse_fire) begin
      cpl_push        = 1'b1;
      cpl_push_ticket = fetch_refuse_ticket_q;
      cpl_push_status = fetch_refuse_status_q;
      cpl_push_irq    = 1'b0;
    end
    // DONE claim: pop head (PLIC discipline)
    if (req_i && we_i && (addr_i[15:0] == 16'h010C) && wdata_i[0]) begin
      cpl_pop = 1'b1;
    end
  end

  // ------------------------------------------------------------------ reads
  // One-cycle registered response for non-cap; cap window already registered.
  logic [31:0] rdata_n, rdata_q;
  logic        rvalid_n, rvalid_q;
  logic        cap_pending_q;

  // E3: one-hot address classes for the rdata gather (A104). The priority
  // case is replaced by a masked-OR of per-class values below; the case form
  // stays as the translate_off reference asserted by g6lc_ai_rdata_eq.
  localparam int unsigned RDCLS = 41;
  logic [RDCLS-1:0] rcls;
  logic [31:0]      rval [0:RDCLS-1];
  always_comb begin
    logic [15:0] a;
    a = addr_i[15:0];
    rcls = '0;
    rcls[0]  = (a == 16'h0100); rval[0]  = {30'h0, wr_cpl_en_q, enable_q};
    rcls[1]  = (a == 16'h0104); rval[1]  = {last_status, 14'h0, fetch_busy, busy};
    rcls[2]  = (a == 16'h0108); rval[2]  = {db_ticket_q[23:0], 8'(db_qid_q)};
    rcls[3]  = (a == 16'h010C); rval[3]  = {31'h0, done_sticky_q};
    rcls[4]  = (a == 16'h0110); rval[4]  = done_ticket_hold_q;
    rcls[5]  = (a == 16'h0114); rval[5]  = {16'h0, done_status_hold_q};
    rcls[6]  = (a == 16'h0118); rval[6]  = desc_ptr_q[31:0];
    rcls[7]  = (a == 16'h011C); rval[7]  = desc_ptr_q[63:32];
    rcls[8]  = (a == REG_OFF_CMD_MODE);    rval[8]  = {31'd0, cmd_mode_q};
    rcls[9]  = (a == REG_OFF_CMD_PTR_LO);  rval[9]  = cmd_ptr_q[31:0];
    rcls[10] = (a == REG_OFF_CMD_PTR_HI);  rval[10] = cmd_ptr_q[63:32];
    rcls[11] = (a == REG_OFF_CMD_TICKET);  rval[11] = cmd_ticket_q;
    rcls[12] = (a == REG_OFF_CMD_QID);     rval[12] = {24'd0, cmd_qid_q};
    rcls[13] = (a == REG_OFF_CMD_CREDITS); rval[13] = 32'(IslandCfg.CommandDepth) - 32'(cmd_count);
    rcls[14] = (a == REG_OFF_CMD_RECEIPT_TICKET); rval[14] = cmd_receipt_ticket_q;
    rcls[15] = (a == REG_OFF_CMD_RECEIPT_CODE);   rval[15] = cmd_receipt_code_q;
    rcls[16] = (a == REG_OFF_CMD_ACCEPTED); rval[16] = cmd_accepted_q;
    rcls[17] = (a == REG_OFF_CMD_REJECTED); rval[17] = cmd_rejected_q;
    rcls[18] = (a == REG_OFF_REUSE_EPOCH);  rval[18] = reuse_epoch_q;
    rcls[19] = (a == REG_OFF_VA_TURBO_LEVEL);   rval[19] = {20'h0, 4'h0, 4'h0, va_level_req_q};
    rcls[20] = (a == PMU_OFF_VA_TURBO_LEVEL);   rval[20] = {20'h0, 4'h0, 4'h0, pmu_va_level_q};
    rcls[21] = (a == REG_OFF_VA_TURBO_RECIPE);  rval[21] = {19'h0, 5'h0, 3'h0, va_recipe_req_q};
    rcls[22] = (a == PMU_OFF_VA_TURBO_RECIPE);  rval[22] = {19'h0, 5'h0, 3'h0, pmu_va_recipe_q};
    rcls[23] = (a == REG_OFF_VA_TURBO_WINDOW);  rval[23] = {31'h0, window_valid_q};
    rcls[24] = (a == PMU_OFF_VA_TURBO_WINDOW);  rval[24] = {31'h0, pmu_window_q};
    rcls[25] = (a == 16'h0180); rval[25] = pmu_r_hold_q;
    rcls[26] = (a == 16'h0184); rval[26] = pmu_w_hold_q;
    rcls[27] = (a == 16'h0188); rval[27] = pmu_cy_hold_q;
    rcls[28] = (a == PMU_OFF_PHASE_LA);  rval[28] = pmu_phase_hold_q[0];
    rcls[29] = (a == PMU_OFF_PHASE_LB);  rval[29] = pmu_phase_hold_q[1];
    rcls[30] = (a == PMU_OFF_PHASE_MAC); rval[30] = pmu_phase_hold_q[2];
    rcls[31] = (a == PMU_OFF_PHASE_STC); rval[31] = pmu_phase_hold_q[3];
    rcls[32] = (a == PMU_OFF_STALL_AR);  rval[32] = pmu_stall_hold_q[0];
    rcls[33] = (a == PMU_OFF_STALL_R);   rval[33] = pmu_stall_hold_q[1];
    rcls[34] = (a == PMU_OFF_STALL_W);   rval[34] = pmu_stall_hold_q[2];
    rcls[35] = (a == 16'h018C); rval[35] = pmu_gbps_x1000_q;
    rcls[36] = (a == 16'h0190); rval[36] = pmu_policy_code_q;
    rcls[37] = (a == 16'h0194); rval[37] = pmu_policy_word_q;
    rcls[38] = (a == 16'h0198); rval[38] = pmu_policy_topo_q;
    rcls[39] = (a == 16'h019C); rval[39] = pmu_policy_event_q;
    rcls[40] = (a >= 16'h0140 && a < 16'h0180); rval[40] = desc_words_q[a[5:2]];
  end

  always_comb begin
    logic [11:0] qd;
    int unsigned q;
    qd = '0;
    q  = 0;
    rdata_n  = '0;
    rvalid_n = 1'b0;
    if (req_i && !cap_sel) begin
      rvalid_n = 1'b1;
      for (int unsigned rc = 0; rc < RDCLS; rc++)
        if (rcls[rc]) rdata_n |= rval[rc];
      if (rcls == '0) begin
        qd = ai_queue_decode(addr_i[15:0], NumQueues);
        // E4: masked-OR over the per-queue one-hot -- no dynamic index.
        for (int unsigned q = 0; q < NumQueues; q++) begin
          if (qd[11] && (qd[10:3] == 8'(q))) begin
            unique case (qd[2:0])
              3'd0: rdata_n |= base_q[q][31:0];
              3'd1: rdata_n |= base_q[q][63:32];
              3'd2: rdata_n |= limit_q[q][31:0];
              3'd3: rdata_n |= limit_q[q][63:32];
              3'd4: rdata_n |= {30'h0, perm_q[q]};
              default: ;
            endcase
          end
        end
      end
    end
  end

  // pragma translate_off
  logic [31:0] rdata_ref;
  logic        rvalid_ref;
  always_comb begin
    logic [11:0] qd;
    int unsigned q;
    q  = 0;
    qd = '0;
    rdata_ref  = '0;
    rvalid_ref = 1'b0;
    if (req_i && !cap_sel) begin
      rvalid_ref = 1'b1;
      unique case (addr_i[15:0])
        16'h0100: rdata_ref = {30'h0, wr_cpl_en_q, enable_q};
        16'h0104: rdata_ref = {last_status, 14'h0, fetch_busy, busy};
        16'h0108: rdata_ref = {db_ticket_q[23:0], 8'(db_qid_q)};
        16'h010C: rdata_ref = {31'h0, done_sticky_q};
        16'h0110: rdata_ref = done_ticket_hold_q;
        16'h0114: rdata_ref = {16'h0, done_status_hold_q};
        16'h0118: rdata_ref = desc_ptr_q[31:0];
        16'h011C: rdata_ref = desc_ptr_q[63:32];
        REG_OFF_CMD_MODE: rdata_ref = {31'd0, cmd_mode_q};
        REG_OFF_CMD_PTR_LO: rdata_ref = cmd_ptr_q[31:0];
        REG_OFF_CMD_PTR_HI: rdata_ref = cmd_ptr_q[63:32];
        REG_OFF_CMD_TICKET: rdata_ref = cmd_ticket_q;
        REG_OFF_CMD_QID: rdata_ref = {24'd0, cmd_qid_q};
        REG_OFF_CMD_CREDITS: rdata_ref = 32'(IslandCfg.CommandDepth) - 32'(cmd_count);
        REG_OFF_CMD_RECEIPT_TICKET: rdata_ref = cmd_receipt_ticket_q;
        REG_OFF_CMD_RECEIPT_CODE: rdata_ref = cmd_receipt_code_q;
        REG_OFF_CMD_ACCEPTED: rdata_ref = cmd_accepted_q;
        REG_OFF_CMD_REJECTED: rdata_ref = cmd_rejected_q;
        REG_OFF_REUSE_EPOCH: rdata_ref = reuse_epoch_q;
        // [3:0] requested, [11:8] applied. Applied is 0.
        REG_OFF_VA_TURBO_LEVEL: rdata_ref = {20'h0, 4'h0, 4'h0, va_level_req_q};
        PMU_OFF_VA_TURBO_LEVEL: rdata_ref = {20'h0, 4'h0, 4'h0, pmu_va_level_q};
        // [4:0] requested id, [12:8] applied id. Applied is 0.
        REG_OFF_VA_TURBO_RECIPE: rdata_ref = {19'h0, 5'h0, 3'h0, va_recipe_req_q};
        PMU_OFF_VA_TURBO_RECIPE: rdata_ref = {19'h0, 5'h0, 3'h0, pmu_va_recipe_q};
        REG_OFF_VA_TURBO_WINDOW: rdata_ref = {31'h0, window_valid_q};
        PMU_OFF_VA_TURBO_WINDOW: rdata_ref = {31'h0, pmu_window_q};
        16'h0180: rdata_ref = pmu_r_hold_q;
        16'h0184: rdata_ref = pmu_w_hold_q;
        16'h0188: rdata_ref = pmu_cy_hold_q;
        PMU_OFF_PHASE_LA:  rdata_ref = pmu_phase_hold_q[0];
        PMU_OFF_PHASE_LB:  rdata_ref = pmu_phase_hold_q[1];
        PMU_OFF_PHASE_MAC: rdata_ref = pmu_phase_hold_q[2];
        PMU_OFF_PHASE_STC: rdata_ref = pmu_phase_hold_q[3];
        PMU_OFF_STALL_AR:  rdata_ref = pmu_stall_hold_q[0];
        PMU_OFF_STALL_R:   rdata_ref = pmu_stall_hold_q[1];
        PMU_OFF_STALL_W:   rdata_ref = pmu_stall_hold_q[2];
        16'h018C: rdata_ref = pmu_gbps_x1000_q;
        16'h0190: rdata_ref = pmu_policy_code_q;
        16'h0194: rdata_ref = pmu_policy_word_q;
        16'h0198: rdata_ref = pmu_policy_topo_q;
        16'h019C: rdata_ref = pmu_policy_event_q;
        default: begin
          if (addr_i[15:0] >= 16'h0140 && addr_i[15:0] < 16'h0180)
            rdata_ref = desc_words_q[addr_i[5:2]];
          else begin
            qd = ai_queue_decode(addr_i[15:0], NumQueues);
            q  = qd[10:3];
            if (qd[11] && q < NumQueues) begin
              unique case (qd[2:0])
                3'd0: rdata_ref = base_q[q][31:0];
                3'd1: rdata_ref = base_q[q][63:32];
                3'd2: rdata_ref = limit_q[q][31:0];
                3'd3: rdata_ref = limit_q[q][63:32];
                3'd4: rdata_ref = {30'h0, perm_q[q]};
                default: rdata_ref = '0;
              endcase
            end
          end
        end
      endcase
    end
  end
  int unsigned g6lc_ai_rdata_eq;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) g6lc_ai_rdata_eq <= 0;
    else begin
      g6lc_ai_rdata_eq <= g6lc_ai_rdata_eq + 1;
      assert (rdata_n == rdata_ref && rvalid_n == rvalid_ref)
        else $error("g6lc_ai_island_top: rdata_eq mismatch %h!=%h v%b!=%b",
                    rdata_n, rdata_ref, rvalid_n, rvalid_ref);
    end
  end
  final $display("[equiv] g6lc_ai_island_top rdata_eq: checked=%0d", g6lc_ai_rdata_eq);
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata_q       <= '0;
      rvalid_q      <= 1'b0;
      cap_pending_q <= 1'b0;
    end else begin
      cap_pending_q <= cap_sel;
      // i_cap already registered its own read, so a cap access must NOT be
      // registered a second time here -- select last cycle's cap result instead.
      if (cap_pending_q) begin
        rdata_q  <= cap_rdata;
        rvalid_q <= cap_rvalid;
      end else begin
        rdata_q  <= rdata_n;
        rvalid_q <= rvalid_n;
      end
      if (pmu_rate_req || pmu_rate_pending_q) rvalid_q <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pmu_rate_pending_q <= 1'b0;
      pmu_rate_packed_q <= 1'b0;
    end else begin
      if (pmu_rate_valid) pmu_rate_pending_q <= 1'b0;
      if (pmu_rate_req) begin
        pmu_rate_pending_q <= 1'b1;
        pmu_rate_packed_q <= addr_i[15:2] == CAP_OFF_DRAM_GBPS[15:2];
      end
    end
  end
  assign rdata_o = pmu_rate_valid ? (pmu_rate_packed_q ?
      {((pmu_gbps_x1000_q > 32'hffff) ? 16'hffff : pmu_gbps_x1000_q[15:0]), 16'(IslandCfg.DramGBps)} :
      pmu_gbps_x1000_q) : rdata_q;
  assign rvalid_o = pmu_rate_valid || (rvalid_q && !pmu_rate_pending_q);
  // Level IRQ while head completion requested IRQ (claim pops head)
  // Level, not pulse: PLIC needs the source held until the claim retires it,
  // and popping the head is what deasserts it (or re-arms it for the next one).
  assign irq_o = done_sticky_q && head_irq;

  assign sb_last_ticket_o     = done_ticket_hold_q;
  assign sb_last_status_o     = done_status_hold_q;
  assign sb_has_completion_o  = done_sticky_q;
  // Simulation-only per-job bench record (+ai_pmu_trace). Prints the same PMU words the
  // MMIO window publishes (0x180.. and 0x0F50..) at the moment the engine completes a job,
  // so any ELF or framework run on the SoC model yields a cycles-per-operation table
  // without HTIF printing from the guest. Not in the netlist.
  // pragma translate_off
  always @(posedge clk_i) begin
    // stderr (unbuffered): the g6lc64_ai harness may not flush stdout at exit.
    // AI_START marks the engine start so a run cut before completion still shows
    // whether the job was ever issued (and when).
    if (rst_ni && gemm_start && gemm_ready && $test$plusargs("ai_pmu_trace"))
      $fdisplay(32'h8000_0002, "AI_START fmt=%0d m=%0d n=%0d k=%0d flags=%h t=%0t",
               gemm_numfmt, gemm_m, gemm_n, gemm_k, gemm_flags, $time);
    if (rst_ni && done_valid && $test$plusargs("ai_pmu_trace"))
      $fdisplay(32'h8000_0002, "AI_JOB ticket=%0d status=%0d fmt=%0d m=%0d n=%0d k=%0d flags=%h cycles=%0d la=%0d lb=%0d mac=%0d stc=%0d stall_ar=%0d stall_r=%0d stall_w=%0d r_beats=%0d w_beats=%0d",
               done_ticket, done_status, gemm_numfmt, gemm_m, gemm_n, gemm_k, gemm_flags,
               pmu_cy_hold_q, pmu_phase_hold_q[0], pmu_phase_hold_q[1], pmu_phase_hold_q[2], pmu_phase_hold_q[3],
               pmu_stall_hold_q[0], pmu_stall_hold_q[1], pmu_stall_hold_q[2], pmu_r_hold_q, pmu_w_hold_q);
  end
  // pragma translate_on

  assign sb_retired_valid_o   = sb_retired_valid_q;
  assign sb_retired_ticket_o  = sb_retired_ticket_q;

  // Silence unused
  // verilator lint_off UNUSEDSIGNAL
  logic _sr, _fec, _full, _prdy;
  logic [CplCntW-1:0] _cnt;
  policy_t _pnext;
  assign _sr   = submit_ready;
  assign _fec  = fetch_err_complete_q;
  assign _full = cpl_full;
  assign _cnt  = cpl_count;
  assign _prdy = policy_ready;
  assign _pnext = policy_next;
  // verilator lint_on UNUSEDSIGNAL

endmodule

module g6lc_ai_pmu_rate #(
    parameter int unsigned ReadBytes = 8,
    parameter int unsigned WriteBytes = 8,
    parameter int unsigned ClockKhz = 2_000_000
) (
    input logic clk_i, rst_ni, start_i,
    input logic [31:0] reads_i, writes_i, cycles_i,
    output logic ready_o, valid_o,
    output logic [31:0] rate_o
);
  localparam int ProductW = 32 + $clog2(64'(ReadBytes) + 64'(WriteBytes) + 64'd1) +
      $clog2(64'(ClockKhz) + 64'd1);
  localparam int Width = ProductW > 42 ? ProductW : 42;
  localparam int ClockBits = $clog2(64'(ClockKhz) + 64'd1);
  localparam int ScaleSteps = ClockBits > 10 ? ClockBits : 10;
  localparam int IterW = $clog2(Width + 1);
  typedef logic [Width-1:0] word_t;
  typedef enum logic [1:0] { IDLE, SCALE, DIVIDE, REPORT } state_t;
  state_t state_q;
  word_t numerator_q, numerator_term_q, denominator_q, denominator_term_q;
  word_t quotient_q, remainder_q;
  word_t numerator_next, denominator_next, quotient_next;
  logic [Width:0] trial, difference;
  logic [IterW-1:0] iteration_q;

  assign ready_o = state_q == IDLE;
  assign valid_o = state_q == REPORT;
  assign numerator_next = numerator_q + (((ClockKhz >> iteration_q) & 1) != 0 ? numerator_term_q : word_t'(0));
  assign denominator_next = denominator_q + (((32'd1000 >> iteration_q) & 1) != 0 ? denominator_term_q : word_t'(0));
  assign trial = {remainder_q, quotient_q[Width-1]};
  assign difference = trial - {1'b0, denominator_q};
  assign quotient_next = {quotient_q[Width-2:0], !difference[Width]};

  // pragma translate_off
  initial begin
    assert (ReadBytes > 0 && (ReadBytes & (ReadBytes - 1)) == 0 &&
            WriteBytes > 0 && (WriteBytes & (WriteBytes - 1)) == 0)
      else $error("g6lc_ai_pmu_rate: byte widths must be powers of two");
  end
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      numerator_q <= '0;
      numerator_term_q <= '0;
      denominator_q <= '0;
      denominator_term_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      iteration_q <= '0;
      rate_o <= '0;
    end else begin
      case (state_q)
        IDLE: if (start_i) begin
          if (cycles_i == 0 || ClockKhz == 0) begin
            rate_o <= '0;
            state_q <= REPORT;
          end else begin
            numerator_q <= '0;
            numerator_term_q <= (word_t'(reads_i) << $clog2(ReadBytes)) +
                                (word_t'(writes_i) << $clog2(WriteBytes));
            denominator_q <= '0;
            denominator_term_q <= word_t'(cycles_i);
            iteration_q <= '0;
            state_q <= SCALE;
          end
        end
        SCALE: begin
          numerator_q <= numerator_next;
          denominator_q <= denominator_next;
          numerator_term_q <= numerator_term_q << 1;
          denominator_term_q <= denominator_term_q << 1;
          iteration_q <= iteration_q + IterW'(1);
          if (iteration_q == IterW'(ScaleSteps - 1)) begin
            quotient_q <= numerator_next;
            remainder_q <= '0;
            iteration_q <= IterW'(Width);
            state_q <= DIVIDE;
          end
        end
        DIVIDE: begin
          quotient_q <= quotient_next;
          remainder_q <= difference[Width] ? trial[Width-1:0] : difference[Width-1:0];
          iteration_q <= iteration_q - IterW'(1);
          if (iteration_q == IterW'(1)) begin
            rate_o <= quotient_next > word_t'(32'hffff_ffff) ? 32'hffff_ffff : 32'(quotient_next);
            state_q <= REPORT;
          end
        end
        REPORT: state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
