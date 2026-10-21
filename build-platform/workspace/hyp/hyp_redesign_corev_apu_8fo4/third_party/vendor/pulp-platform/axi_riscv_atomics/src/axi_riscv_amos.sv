// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright (c) 2018 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// AXI RISC-V Atomic Operations (AMOs) Adapter
//
// This adapter implements atomic memory operations in accordance with the RVWMO memory consistency
// model.
//
// Interface notes:
// -  This module has combinational paths between AXI inputs and outputs for minimum latency. Add
//    slices upstream or downstream or in both directions if combinatorial paths become too long.
//    The module adheres to the AXI ready/valid dependency specification to prevent combinatorial
//    loops.

module axi_riscv_amos #(
    // AXI Parameters
    parameter int unsigned AXI_ADDR_WIDTH       = 0,
    parameter int unsigned AXI_DATA_WIDTH       = 0,
    parameter int unsigned AXI_ID_WIDTH         = 0,
    parameter int unsigned AXI_USER_WIDTH       = 0,
    // Maximum number of AXI write transactions outstanding at the same time
    parameter int unsigned AXI_MAX_WRITE_TXNS   = 0,
    // Word width of the widest RISC-V processor that can issue requests to this module.
    // 32 for RV32; 64 for RV64, where both 32-bit (.W suffix) and 64-bit (.D suffix) AMOs are
    // supported if `aw_strb` is set correctly.
    parameter int unsigned RISCV_WORD_WIDTH     = 0,
    /// Derived Parameters (do NOT change manually!)
    localparam int unsigned AXI_STRB_WIDTH      = AXI_DATA_WIDTH / 8
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,

    /// Slave Interface
    input  logic [AXI_ADDR_WIDTH-1:0]   slv_aw_addr_i,
    input  logic [2:0]                  slv_aw_prot_i,
    input  logic [3:0]                  slv_aw_region_i,
    input  logic [5:0]                  slv_aw_atop_i,
    input  logic [7:0]                  slv_aw_len_i,
    input  logic [2:0]                  slv_aw_size_i,
    input  logic [1:0]                  slv_aw_burst_i,
    input  logic                        slv_aw_lock_i,
    input  logic [3:0]                  slv_aw_cache_i,
    input  logic [3:0]                  slv_aw_qos_i,
    input  logic [AXI_ID_WIDTH-1:0]     slv_aw_id_i,
    input  logic [AXI_USER_WIDTH-1:0]   slv_aw_user_i,
    output logic                        slv_aw_ready_o,
    input  logic                        slv_aw_valid_i,

    input  logic [AXI_ADDR_WIDTH-1:0]   slv_ar_addr_i,
    input  logic [2:0]                  slv_ar_prot_i,
    input  logic [3:0]                  slv_ar_region_i,
    input  logic [7:0]                  slv_ar_len_i,
    input  logic [2:0]                  slv_ar_size_i,
    input  logic [1:0]                  slv_ar_burst_i,
    input  logic                        slv_ar_lock_i,
    input  logic [3:0]                  slv_ar_cache_i,
    input  logic [3:0]                  slv_ar_qos_i,
    input  logic [AXI_ID_WIDTH-1:0]     slv_ar_id_i,
    input  logic [AXI_USER_WIDTH-1:0]   slv_ar_user_i,
    output logic                        slv_ar_ready_o,
    input  logic                        slv_ar_valid_i,

    input  logic [AXI_DATA_WIDTH-1:0]   slv_w_data_i,
    input  logic [AXI_STRB_WIDTH-1:0]   slv_w_strb_i,
    input  logic [AXI_USER_WIDTH-1:0]   slv_w_user_i,
    input  logic                        slv_w_last_i,
    output logic                        slv_w_ready_o,
    input  logic                        slv_w_valid_i,

    output logic [AXI_DATA_WIDTH-1:0]   slv_r_data_o,
    output logic [1:0]                  slv_r_resp_o,
    output logic                        slv_r_last_o,
    output logic [AXI_ID_WIDTH-1:0]     slv_r_id_o,
    output logic [AXI_USER_WIDTH-1:0]   slv_r_user_o,
    input  logic                        slv_r_ready_i,
    output logic                        slv_r_valid_o,

    output logic [1:0]                  slv_b_resp_o,
    output logic [AXI_ID_WIDTH-1:0]     slv_b_id_o,
    output logic [AXI_USER_WIDTH-1:0]   slv_b_user_o,
    input  logic                        slv_b_ready_i,
    output logic                        slv_b_valid_o,

    /// Master Interface
    output logic [AXI_ADDR_WIDTH-1:0]   mst_aw_addr_o,
    output logic [2:0]                  mst_aw_prot_o,
    output logic [3:0]                  mst_aw_region_o,
    output logic [5:0]                  mst_aw_atop_o,
    output logic [7:0]                  mst_aw_len_o,
    output logic [2:0]                  mst_aw_size_o,
    output logic [1:0]                  mst_aw_burst_o,
    output logic                        mst_aw_lock_o,
    output logic [3:0]                  mst_aw_cache_o,
    output logic [3:0]                  mst_aw_qos_o,
    output logic [AXI_ID_WIDTH-1:0]     mst_aw_id_o,
    output logic [AXI_USER_WIDTH-1:0]   mst_aw_user_o,
    input  logic                        mst_aw_ready_i,
    output logic                        mst_aw_valid_o,

    output logic [AXI_ADDR_WIDTH-1:0]   mst_ar_addr_o,
    output logic [2:0]                  mst_ar_prot_o,
    output logic [3:0]                  mst_ar_region_o,
    output logic [7:0]                  mst_ar_len_o,
    output logic [2:0]                  mst_ar_size_o,
    output logic [1:0]                  mst_ar_burst_o,
    output logic                        mst_ar_lock_o,
    output logic [3:0]                  mst_ar_cache_o,
    output logic [3:0]                  mst_ar_qos_o,
    output logic [AXI_ID_WIDTH-1:0]     mst_ar_id_o,
    output logic [AXI_USER_WIDTH-1:0]   mst_ar_user_o,
    input  logic                        mst_ar_ready_i,
    output logic                        mst_ar_valid_o,

    output logic [AXI_DATA_WIDTH-1:0]   mst_w_data_o,
    output logic [AXI_STRB_WIDTH-1:0]   mst_w_strb_o,
    output logic [AXI_USER_WIDTH-1:0]   mst_w_user_o,
    output logic                        mst_w_last_o,
    input  logic                        mst_w_ready_i,
    output logic                        mst_w_valid_o,

    input  logic [AXI_DATA_WIDTH-1:0]   mst_r_data_i,
    input  logic [1:0]                  mst_r_resp_i,
    input  logic                        mst_r_last_i,
    input  logic [AXI_ID_WIDTH-1:0]     mst_r_id_i,
    input  logic [AXI_USER_WIDTH-1:0]   mst_r_user_i,
    output logic                        mst_r_ready_o,
    input  logic                        mst_r_valid_i,

    input  logic [1:0]                  mst_b_resp_i,
    input  logic [AXI_ID_WIDTH-1:0]     mst_b_id_i,
    input  logic [AXI_USER_WIDTH-1:0]   mst_b_user_i,
    output logic                        mst_b_ready_o,
    input  logic                        mst_b_valid_i
);

    localparam int unsigned OUTSTND_BURSTS_WIDTH = $clog2(AXI_MAX_WRITE_TXNS+1);
    localparam int unsigned AXI_ALU_RATIO        = AXI_DATA_WIDTH/RISCV_WORD_WIDTH;

    // State types
    typedef enum logic [1:0] { FEEDTHROUGH_AW, WAIT_RESULT_AW, SEND_AW } aw_state_t;
    aw_state_t   aw_state_d, aw_state_q;

    typedef enum logic [2:0] { FEEDTHROUGH_W, WAIT_DATA_W, WAIT_RESULT_W, WAIT_CHANNEL_W, SEND_W } w_state_t;
    w_state_t    w_state_d, w_state_q;

    typedef enum logic [1:0] { FEEDTHROUGH_B, WAIT_COMPLETE_B, WAIT_CHANNEL_B, SEND_B } b_state_t;
    b_state_t    b_state_d, b_state_q;

    typedef enum logic [1:0] { FEEDTHROUGH_AR, WAIT_CHANNEL_AR, SEND_AR } ar_state_t;
    ar_state_t   ar_state_d, ar_state_q;

    typedef enum logic [1:0] { FEEDTHROUGH_R, WAIT_DATA_R, WAIT_CHANNEL_R, SEND_R } r_state_t;
    r_state_t    r_state_d, r_state_q;

    typedef enum logic [1:0] { NONE, INVALID, LOAD, STORE } atop_req_t;
    atop_req_t   atop_valid_d, atop_valid_q;

    // Signal declarations
    // Transaction FF
    logic [AXI_ADDR_WIDTH-1:0]          addr_d,         addr_q;
    logic [AXI_ID_WIDTH-1:0]            id_d,           id_q;
    logic [AXI_STRB_WIDTH-1:0]          strb_d,         strb_q;
    logic [2:0]                         size_d,         size_q;
    logic [5:0]                         atop_d,         atop_q;
    logic [3:0]                         cache_d,        cache_q;
    logic [2:0]                         prot_d,         prot_q;
    logic [3:0]                         qos_d,          qos_q;
    logic [3:0]                         region_d,       region_q;
    logic [1:0]                         r_resp_d,       r_resp_q;
    logic [AXI_USER_WIDTH-1:0]          aw_user_d,      aw_user_q,
                                        w_user_d,       w_user_q,
                                        r_user_d,       r_user_q;
    // Data FF
    logic [AXI_DATA_WIDTH-1:0]          w_data_d,       w_data_q;       // AMO operand
    logic [AXI_DATA_WIDTH-1:0]          r_data_d,       r_data_q;       // Data from memory
    logic [AXI_DATA_WIDTH-1:0]          result_d,       result_q;       // Result of AMO operation
    logic                               w_d_valid_d,    w_d_valid_q,    // AMO operand valid
                                        r_d_valid_d,    r_d_valid_q;    // Data from memory valid
    // Counters
    logic [OUTSTND_BURSTS_WIDTH-1:0]    w_cnt_d,        w_cnt_q;        // Outstanding W beats
    logic [OUTSTND_BURSTS_WIDTH-1:0]    w_cnt_req_d,    w_cnt_req_q;    // W beats until AMO can read W
    logic [OUTSTND_BURSTS_WIDTH-1:0]    w_cnt_inj_d,    w_cnt_inj_q;    // W beats until AMO can insert its W
    // States
    logic                               adapter_ready;
    logic                               transaction_collision;
    logic                               aw_valid,       aw_ready,       aw_free,
                                        w_valid,        w_ready,        w_free,
                                        b_valid,        b_ready,        b_free,
                                        ar_valid,       ar_ready,       ar_free,
                                        r_valid,        r_ready,        r_free;
    logic                               big_endian;
    // ALU Signals
    logic [RISCV_WORD_WIDTH-1:0]                        alu_operand_a;
    logic [RISCV_WORD_WIDTH-1:0]                        alu_operand_b;
    logic [RISCV_WORD_WIDTH-1:0]                        alu_result;
    logic [AXI_DATA_WIDTH-1:0]                          alu_result_ext;
    logic [AXI_ALU_RATIO-1:0][RISCV_WORD_WIDTH-1:0]     op_a;
    logic [AXI_ALU_RATIO-1:0][RISCV_WORD_WIDTH-1:0]     op_b;
    logic [AXI_ALU_RATIO-1:0][RISCV_WORD_WIDTH-1:0]     op_a_sign_ext;
    logic [AXI_ALU_RATIO-1:0][RISCV_WORD_WIDTH-1:0]     op_b_sign_ext;
    logic [AXI_ALU_RATIO-1:0][RISCV_WORD_WIDTH-1:0]     res;
    logic [AXI_STRB_WIDTH-1:0][7:0]                     strb_ext;
    logic                                               sign_a;
    logic                                               sign_b;

    /**
     * Calculate ready signals and channel states
     */

    // Check if all state machines are ready for the next atomic request
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_riscv_amos  region=5590  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ar_ready  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ar_ready
// order expect: ar_valid  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ar_valid
// order expect: aw_ready  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aw_ready
// order expect: aw_valid  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aw_valid
// order expect: b_ready  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to b_ready
// order expect: b_valid  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to b_valid
// order expect: r_ready  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_ready
// order expect: r_valid  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_valid
// order expect: w_ready  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_ready
// order expect: w_valid  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_valid
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ar_ready <= …; // sv-timing: cycle 1/1 on clk_i
//     ar_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     aw_ready <= …; // sv-timing: cycle 1/1 on clk_i
//     aw_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     b_ready <= …; // sv-timing: cycle 1/1 on clk_i
//     b_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     r_ready <= …; // sv-timing: cycle 1/1 on clk_i
//     r_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     w_ready <= …; // sv-timing: cycle 1/1 on clk_i
//     w_valid <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19764 c=3.50 slack=0.00 */
//     /* node19765 c=3.50 slack=0.00 */
//     /* node19766 c=3.50 slack=0.00 */
//     /* node19767 c=3.50 slack=0.00 */
//     /* node19768 c=3.50 slack=0.00 */
//     /* node19769 c=3.50 slack=0.00 */
//     /* node19770 c=3.50 slack=0.00 */
//     /* node19771 c=3.50 slack=0.00 */
//     /* node19772 c=3.50 slack=0.00 */
//     /* node19773 c=3.50 slack=0.00 */
//     /* node19774 c=3.50 slack=0.00 */
//     /* node19775 c=3.50 slack=0.00 */
//     /* node19776 c=3.50 slack=0.00 */
//     /* node19777 c=3.50 slack=0.00 */
//     /* node19778 c=3.50 slack=0.00 */
//     /* node19779 c=3.50 slack=0.00 */
//     /* node19780 c=3.50 slack=0.00 */
//     /* node19781 c=3.50 slack=0.00 */
//     /* node19782 c=3.50 slack=0.00 */
//     /* node19783 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_riscv_amos  region=5593  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: atop_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to atop_valid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     atop_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19792 c=3.50 slack=0.00 */
//     /* node19793 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_riscv_amos  region=5598  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: addr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to addr_q
// order expect: atop_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to atop_q
// order expect: aw_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aw_state_q
// order expect: aw_user_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to aw_user_q
// order expect: b_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to b_state_q
// order expect: cache_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cache_q
// order expect: id_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to id_q
// order expect: prot_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to prot_q
// order expect: qos_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to qos_q
// order expect: region_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to region_q
// order expect: result_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to result_q
// order expect: size_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to size_q
// order expect: strb_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to strb_q
// order expect: w_cnt_inj_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_cnt_inj_q
// order expect: w_cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_cnt_q
// order expect: w_cnt_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_cnt_req_q
// order expect: w_d_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_d_valid_q
// order expect: w_data_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_data_q
// order expect: w_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_state_q
// order expect: w_user_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to w_user_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     atop_q <= …; // sv-timing: cycle 1/1 on clk_i
//     aw_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     aw_user_q <= …; // sv-timing: cycle 1/1 on clk_i
//     b_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cache_q <= …; // sv-timing: cycle 1/1 on clk_i
//     id_q <= …; // sv-timing: cycle 1/1 on clk_i
//     prot_q <= …; // sv-timing: cycle 1/1 on clk_i
//     qos_q <= …; // sv-timing: cycle 1/1 on clk_i
//     region_q <= …; // sv-timing: cycle 1/1 on clk_i
//     result_q <= …; // sv-timing: cycle 1/1 on clk_i
//     size_q <= …; // sv-timing: cycle 1/1 on clk_i
//     strb_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_cnt_inj_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_cnt_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_d_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_data_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     w_user_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19938 c=3.50 slack=0.00 */
//     /* node19939 c=3.50 slack=0.00 */
//     /* node19940 c=3.50 slack=0.00 */
//     /* node19941 c=3.50 slack=0.00 */
//     /* node19942 c=3.50 slack=0.00 */
//     /* node19943 c=3.50 slack=0.00 */
//     /* node19944 c=3.50 slack=0.00 */
//     /* node19945 c=3.50 slack=0.00 */
//     /* node19946 c=3.50 slack=0.00 */
//     /* node19947 c=3.50 slack=0.00 */
//     /* node19948 c=3.50 slack=0.00 */
//     /* node19949 c=3.50 slack=0.00 */
//     /* node19950 c=3.50 slack=0.00 */
//     /* node19951 c=3.50 slack=0.00 */
//     /* node19952 c=3.50 slack=0.00 */
//     /* node19953 c=3.50 slack=0.00 */
//     /* node19954 c=3.50 slack=0.00 */
//     /* node19955 c=3.50 slack=0.00 */
//     /* node19956 c=3.50 slack=0.00 */
//     /* node19957 c=3.50 slack=0.00 */
//     /* node19958 c=3.50 slack=0.00 */
//     /* node19959 c=3.50 slack=0.00 */
//     /* node19960 c=3.50 slack=0.00 */
//     /* node19961 c=3.50 slack=0.00 */
//     /* node19962 c=3.50 slack=0.00 */
//     /* node19963 c=3.50 slack=0.00 */
//     /* node19964 c=3.50 slack=0.00 */
//     /* node19965 c=3.50 slack=0.00 */
//     /* node19966 c=3.50 slack=0.00 */
//     /* node19967 c=3.50 slack=0.00 */
//     /* node19968 c=3.50 slack=0.00 */
//     /* node19969 c=3.50 slack=0.00 */
//     /* node19970 c=3.50 slack=0.00 */
//     /* node19971 c=3.50 slack=0.00 */
//     /* node19972 c=3.50 slack=0.00 */
//     /* node19973 c=3.50 slack=0.00 */
//     /* node19974 c=3.50 slack=0.00 */
//     /* node19975 c=3.50 slack=0.00 */
//     /* node19976 c=3.50 slack=0.00 */
//     /* node19977 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_riscv_amos  region=5601  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ar_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ar_state_q
// order expect: r_d_valid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_d_valid_q
// order expect: r_data_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_data_q
// order expect: r_resp_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_resp_q
// order expect: r_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_state_q
// order expect: r_user_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to r_user_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ar_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     r_d_valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     r_data_q <= …; // sv-timing: cycle 1/1 on clk_i
//     r_resp_q <= …; // sv-timing: cycle 1/1 on clk_i
//     r_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     r_user_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20070 c=3.50 slack=0.00 */
//     /* node20071 c=3.50 slack=0.00 */
//     /* node20072 c=3.50 slack=0.00 */
//     /* node20073 c=3.50 slack=0.00 */
//     /* node20074 c=3.50 slack=0.00 */
//     /* node20075 c=3.50 slack=0.00 */
//     /* node20076 c=3.50 slack=0.00 */
//     /* node20077 c=3.50 slack=0.00 */
//     /* node20078 c=3.50 slack=0.00 */
//     /* node20079 c=3.50 slack=0.00 */
//     /* node20080 c=3.50 slack=0.00 */
//     /* node20081 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // --- BalanceMux arm staging (latency-neutral) ---
  logic svt_bm_p15359_n19758_0;
  logic svt_bm_p15359_n19758_1;
  logic svt_bm_p15359_n19758_2;
  logic svt_bm_p15359_n19758_3;
  logic svt_bm_p15359_n19758_4;
  logic svt_bm_p15359_n19758_5;
  logic svt_bm_p15359_n19758_6;
  logic svt_bm_p15359_n19758_7;
  var type(adapter_ready) svt_bm_top_p15359_n19758;
  always_comb begin : svt_bm_top_p15359_n19758_stage
    svt_bm_p15359_n19758_0 = aw_state_q == FEEDTHROUGH_AW;
    svt_bm_p15359_n19758_1 = w_state_q == FEEDTHROUGH_W;
    svt_bm_p15359_n19758_2 = svt_bm_p15359_n19758_0 && svt_bm_p15359_n19758_1;
    svt_bm_p15359_n19758_3 = b_state_q == FEEDTHROUGH_B;
    svt_bm_p15359_n19758_4 = ar_state_q == FEEDTHROUGH_AR;
    svt_bm_p15359_n19758_5 = r_state_q == FEEDTHROUGH_R;
    svt_bm_p15359_n19758_6 = svt_bm_p15359_n19758_4 && svt_bm_p15359_n19758_5;
    svt_bm_p15359_n19758_7 = svt_bm_p15359_n19758_3 && svt_bm_p15359_n19758_6;
    svt_bm_top_p15359_n19758 = type(adapter_ready)'(svt_bm_p15359_n19758_2 && svt_bm_p15359_n19758_7);
  end
  // END sv-timing auto-correct (balance_mux rewrite)
assign adapter_ready = svt_bm_top_p15359_n19758; // sv-timing: BalanceMux/rebalance #667 RHS rewrite
                           // sv-timing: (RHS rewrite continuation removed) ( w_state_q == FEEDTHROUGH_W ) &&
                           // sv-timing: (RHS rewrite continuation removed) ( b_state_q == FEEDTHROUGH_B ) &&
                           // sv-timing: (RHS rewrite continuation removed) (ar_state_q == FEEDTHROUGH_AR) &&
                           // sv-timing: (RHS rewrite continuation removed) ( r_state_q == FEEDTHROUGH_R );

    // Calculate if the channels are free
    assign aw_free = ~aw_valid | aw_ready;
    assign  w_free = ~ w_valid |  w_ready;
    assign  b_free = ~ b_valid |  b_ready;
    assign ar_free = ~ar_valid | ar_ready;
    assign  r_free = ~ r_valid |  r_ready;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(~rst_ni) begin
            aw_valid <= 0;
            aw_ready <= 0;
            w_valid  <= 0;
            w_ready  <= 0;
            b_valid  <= 0;
            b_ready  <= 0;
            ar_valid <= 0;
            ar_ready <= 0;
            r_valid  <= 0;
            r_ready  <= 0;
        end else begin
            aw_valid <= mst_aw_valid_o;
            aw_ready <= mst_aw_ready_i;
            w_valid  <= mst_w_valid_o;
            w_ready  <= mst_w_ready_i;
            b_valid  <= slv_b_valid_o;
            b_ready  <= slv_b_ready_i;
            ar_valid <= mst_ar_valid_o;
            ar_ready <= mst_ar_ready_i;
            r_valid  <= slv_r_valid_o;
            r_ready  <= slv_r_ready_i;
        end
    end

    // Calculate if the request interferes with the ongoing atomic transaction
    // The protected bytes go from addr_q up to addr_q + (1 << size_q) - 1
    // TODO Bursts need special treatment
    assign transaction_collision = (slv_aw_addr_i < (     addr_q + (8'h01 <<      size_q))) &
                                   (     addr_q < (slv_aw_addr_i + (8'h01 << slv_aw_size_i)));

    always_comb begin : calc_atop_valid
        atop_valid_d = atop_valid_q;
        if (adapter_ready) begin
            atop_valid_d = NONE;
            if (slv_aw_valid_i && slv_aw_atop_i) begin
                // Default is invalid request
                atop_valid_d = INVALID;
                // Valid load operation (includes AtomicCompare — returns old data)
                if ((slv_aw_atop_i      ==  axi_pkg::ATOP_ATOMICSWAP) ||
                    (slv_aw_atop_i      ==  axi_pkg::ATOP_ATOMICCMP) ||
                    (slv_aw_atop_i[5:4] == {axi_pkg::ATOP_ATOMICLOAD})) begin
                    atop_valid_d = LOAD;
                end
                // Valid store operation
                if (slv_aw_atop_i[5:4] == {axi_pkg::ATOP_ATOMICSTORE}) begin
                    atop_valid_d = STORE;
                end
                // Invalidate valid request if control signals do not match
                // Burst or exclusive access
                if (slv_aw_len_i | slv_aw_lock_i) begin
                    atop_valid_d = INVALID;
                end
                // Unsupported size
                if (slv_aw_size_i > $clog2(RISCV_WORD_WIDTH/8)) begin
                    atop_valid_d = INVALID;
                end
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_atop_valid
        if(~rst_ni) begin
            atop_valid_q <= NONE;
        end else begin
            atop_valid_q <= atop_valid_d;
        end
    end

    /**
     * Write Channel: AW, W, B
     */

    /*====================================================================
    =                                 AW                                 =
    ====================================================================*/
    always_comb begin : axi_aw_channel
        // Defaults AXI Bus
        mst_aw_id_o     = slv_aw_id_i;
        mst_aw_addr_o   = slv_aw_addr_i;
        mst_aw_len_o    = slv_aw_len_i;
        mst_aw_size_o   = slv_aw_size_i;
        mst_aw_burst_o  = slv_aw_burst_i;
        mst_aw_lock_o   = slv_aw_lock_i;
        mst_aw_cache_o  = slv_aw_cache_i;
        mst_aw_prot_o   = slv_aw_prot_i;
        mst_aw_qos_o    = slv_aw_qos_i;
        mst_aw_region_o = slv_aw_region_i;
        mst_aw_atop_o   = 6'b0;
        mst_aw_user_o   = slv_aw_user_i;
        // Defaults FF
        addr_d          = addr_q;
        id_d            = id_q;
        size_d          = size_q;
        atop_d          = atop_q;
        cache_d         = cache_q;
        prot_d          = prot_q;
        qos_d           = qos_q;
        region_d        = region_q;
        aw_user_d       = aw_user_q;
        w_cnt_inj_d     = w_cnt_inj_q;
        // State Machine
        aw_state_d      = aw_state_q;

        // Default control: Block AW channel if...
        if (slv_aw_valid_i && slv_aw_atop_i) begin
            // Block if atomic request
            mst_aw_valid_o = 1'b0;
            slv_aw_ready_o = 1'b0;
        end else if (w_cnt_q == AXI_MAX_WRITE_TXNS) begin
            // Block if counter is overflowing
            mst_aw_valid_o = 1'b0;
            slv_aw_ready_o = 1'b0;
        end else if (slv_aw_valid_i && transaction_collision && !adapter_ready) begin
            // Block requests to the same address as current atomic transaction
            mst_aw_valid_o = 1'b0;
            slv_aw_ready_o = 1'b0;
        end else begin
            // Forward
            mst_aw_valid_o  = slv_aw_valid_i;
            slv_aw_ready_o  = mst_aw_ready_i;
        end

        // Count W burst to know when to inject the W data
        if (w_cnt_inj_q && mst_w_valid_o && mst_w_ready_i && mst_w_last_o) begin
            w_cnt_inj_d = w_cnt_inj_q - 1;
        end

        unique case (aw_state_q)

            FEEDTHROUGH_AW: begin
                // Feedthrough slave to master until atomic operation is detected
                if (slv_aw_valid_i && slv_aw_atop_i && adapter_ready) begin
                    // Acknowledge atomic transaction
                    slv_aw_ready_o = 1'b1;
                    // Remember request
                    atop_d    = slv_aw_atop_i;
                    addr_d    = slv_aw_addr_i;
                    id_d      = slv_aw_id_i;
                    size_d    = slv_aw_size_i;
                    cache_d   = slv_aw_cache_i;
                    prot_d    = slv_aw_prot_i;
                    qos_d     = slv_aw_qos_i;
                    region_d  = slv_aw_region_i;
                    aw_user_d = slv_aw_user_i;
                    // If valid AMO --> wait for result
                    if (atop_valid_d != INVALID) begin
                        aw_state_d = WAIT_RESULT_AW;
                    end
                end

            end // FEEDTHROUGH_AW

            WAIT_RESULT_AW, SEND_AW: begin
                // If the result is ready and the channel is free --> inject AW request
                if ((r_d_valid_q && w_d_valid_q && aw_free) || (aw_state_q == SEND_AW)) begin
                    // Block
                    slv_aw_ready_o  = 1'b0;
                    // Make write request
                    mst_aw_valid_o  = 1'b1;
                    mst_aw_addr_o   = addr_q;
                    mst_aw_len_o    = 8'h00;
                    mst_aw_id_o     = id_q;
                    mst_aw_size_o   = size_q;
                    mst_aw_burst_o  = 2'b00;
                    mst_aw_lock_o   = 1'b0;
                    mst_aw_cache_o  = cache_q;
                    mst_aw_prot_o   = prot_q;
                    mst_aw_qos_o    = qos_q;
                    mst_aw_region_o = region_q;
                    mst_aw_user_o   = aw_user_q;
                    // Check if request is acknowledged
                    if (mst_aw_ready_i) begin
                        aw_state_d = FEEDTHROUGH_AW;
                    end else begin
                        aw_state_d = SEND_AW;
                    end
                    // Remember outstanding W beats before injected request
                    if (aw_state_q == WAIT_RESULT_AW) begin
                        if (w_cnt_q && mst_w_valid_o && mst_w_ready_i && mst_w_last_o) begin
                            w_cnt_inj_d = w_cnt_q - 1;
                        end else begin
                            w_cnt_inj_d = w_cnt_q;
                        end
                    end
                end
            end // WAIT_RESULT_AW, SEND_AW

            default: aw_state_d = FEEDTHROUGH_AW;

        endcase
    end // axi_aw_channel

    /*====================================================================
    =                                 W                                  =
    ====================================================================*/
    always_comb begin : axi_w_channel
        // Defaults AXI Bus
        mst_w_data_o = slv_w_data_i;
        mst_w_strb_o = slv_w_strb_i;
        mst_w_last_o = slv_w_last_i;
        mst_w_user_o = slv_w_user_i;
        // Defaults FF
        strb_d       = strb_q;
        w_user_d     = w_user_q;
        w_data_d     = w_data_q;
        result_d     = result_q;
        w_d_valid_d  = w_d_valid_q;
        w_cnt_req_d  = w_cnt_req_q;
        // State Machine
        w_state_d    = w_state_q;

        // Default control
        // Make sure no data is sent without knowing if it's atomic
        if (w_cnt_q == 0) begin
            // Stall W as it precedes the AW request
            slv_w_ready_o = 1'b0;
            mst_w_valid_o = 1'b0;
        end else begin
            mst_w_valid_o = slv_w_valid_i;
            slv_w_ready_o = mst_w_ready_i;
        end

        unique case (w_state_q)

            FEEDTHROUGH_W: begin
                if (adapter_ready) begin
                    // Reset read flag
                    w_d_valid_d = 1'b0;
                    result_d    = '0;

                    if (atop_valid_d != NONE) begin
                        // Check if data is also available and does not belong to previous request
                        if (w_cnt_q == 0) begin
                            // Block downstream
                            mst_w_valid_o = 1'b0;
                            // Fetch data and wait for all data
                            slv_w_ready_o  = 1'b1;
                            if (slv_w_valid_i) begin
                                if (atop_valid_d != INVALID) begin
                                    w_data_d    = slv_w_data_i;
                                    strb_d      = slv_w_strb_i;
                                    w_user_d    = slv_w_user_i;
                                    w_d_valid_d = 1'b1;
                                    w_state_d   = WAIT_RESULT_W;
                                end
                            end else begin
                                w_cnt_req_d = '0;
                                w_state_d   = WAIT_DATA_W;
                            end
                        end else begin
                            // Remember the amount of outstanding bursts and count down
                            if (mst_w_valid_o && mst_w_ready_i && mst_w_last_o) begin
                                w_cnt_req_d = w_cnt_q - 1;
                            end else begin
                                w_cnt_req_d = w_cnt_q;
                            end
                            w_state_d   = WAIT_DATA_W;
                        end
                    end
                end
            end // FEEDTHROUGH_W

            WAIT_DATA_W: begin
                // Count W beats until data arrives that belongs to the AMO request
                if (w_cnt_req_q == 0) begin
                    // Block downstream
                    mst_w_valid_o = 1'b0;
                    // Ready upstream
                    slv_w_ready_o = 1'b1;

                    if (slv_w_valid_i) begin
                        if (atop_valid_q == INVALID) begin
                            w_state_d    = FEEDTHROUGH_W;
                        end else begin
                            w_data_d    = slv_w_data_i;
                            strb_d      = slv_w_strb_i;
                            w_user_d    = slv_w_user_i;
                            w_d_valid_d = 1'b1;
                            w_state_d   = WAIT_RESULT_W;
                        end
                    end
                end else if (mst_w_valid_o && mst_w_ready_i && mst_w_last_o) begin
                    w_cnt_req_d = w_cnt_req_q - 1;
                end
            end // WAIT_DATA_W

            WAIT_RESULT_W: begin
                // If the result is ready, try to write it
                if (r_d_valid_q && w_d_valid_q && aw_free) begin
                    // Check if W channel is free and make sure data is not interleaved
                    result_d = alu_result_ext;
                    if (w_free && w_cnt_q == 0) begin
                        // Block
                        slv_w_ready_o = 1'b0;
                        // Send write data
                        mst_w_valid_o = 1'b1;
                        mst_w_data_o  = alu_result_ext;
                        mst_w_last_o  = 1'b1;
                        mst_w_strb_o  = strb_q;
                        mst_w_user_o  = w_user_q;
                        if (mst_w_ready_i) begin
                            w_state_d = FEEDTHROUGH_W;
                        end else begin
                            w_state_d = SEND_W;
                        end
                    end else begin
                        w_state_d = WAIT_CHANNEL_W;
                    end
                end
            end // WAIT_RESULT_W

            WAIT_CHANNEL_W, SEND_W: begin
                // Wait to not interleave the data
                if ((w_free && w_cnt_inj_q == 0) || (w_state_q == SEND_W)) begin
                    // Block
                    slv_w_ready_o = 1'b0;
                    // Send write data
                    mst_w_valid_o = 1'b1;
                    mst_w_data_o  = result_q;
                    mst_w_last_o  = 1'b1;
                    mst_w_strb_o  = strb_q;
                    mst_w_user_o  = w_user_q;
                    if (mst_w_ready_i) begin
                        w_state_d = FEEDTHROUGH_W;
                    end else begin
                        w_state_d = SEND_W;
                    end
                end
            end // WAIT_CHANNEL_W, SEND_W

            default: w_state_d = FEEDTHROUGH_W;

        endcase
    end // axi_w_channel

    /*====================================================================
    =                                 B                                  =
    ====================================================================*/
    always_comb begin : axi_b_channel
        // Defaults AXI Bus
        mst_b_ready_o = slv_b_ready_i;
        slv_b_id_o    = mst_b_id_i;
        slv_b_resp_o  = mst_b_resp_i;
        slv_b_user_o  = mst_b_user_i;
        slv_b_valid_o = mst_b_valid_i;
        // State Machine
        b_state_d     = b_state_q;

        unique case (b_state_q)

            FEEDTHROUGH_B: begin
                if (adapter_ready) begin
                    if (atop_valid_d == LOAD || atop_valid_d == STORE) begin
                        // Wait until write is complete
                        b_state_d = WAIT_COMPLETE_B;
                    end else if (atop_valid_d == INVALID) begin
                        // Inject B error resp once the channel is free
                        if (b_free) begin
                            // Block downstream
                            mst_b_ready_o = 1'b0;
                            // Write B response
                            slv_b_valid_o = 1'b1;
                            slv_b_id_o    = slv_aw_id_i;
                            slv_b_resp_o  = axi_pkg::RESP_SLVERR;
                            slv_b_user_o  = '0;
                            if (!slv_b_ready_i) begin
                                b_state_d = SEND_B;
                            end
                        end else begin
                            b_state_d = WAIT_CHANNEL_B;
                        end
                    end
                end
            end // FEEDTHROUGH_B

            WAIT_CHANNEL_B, SEND_B: begin
                if (b_free || (b_state_q == SEND_B)) begin
                    // Block downstream
                    mst_b_ready_o = 1'b0;
                    // Write B response
                    slv_b_valid_o = 1'b1;
                    slv_b_id_o    = id_q;
                    slv_b_resp_o  = axi_pkg::RESP_SLVERR;
                    slv_b_user_o  = '0;
                    if (slv_b_ready_i) begin
                        b_state_d = FEEDTHROUGH_B;
                    end else begin
                        b_state_d = SEND_B;
                    end
                end
            end // WAIT_CHANNEL_B, SEND_B

            WAIT_COMPLETE_B: begin
                if (mst_b_valid_i && (mst_b_id_i == id_q)) begin
                    b_state_d = FEEDTHROUGH_B;
                end
            end // WAIT_COMPLETE_B

            default: b_state_d = FEEDTHROUGH_B;

        endcase
    end // axi_b_channel

    // Keep track of outstanding downstream write bursts and responses.
    always_comb begin
        w_cnt_d = w_cnt_q;
        if (mst_aw_valid_o && mst_aw_ready_i) begin
            w_cnt_d += 1;
        end
        if (mst_w_valid_o && mst_w_ready_i && mst_w_last_o) begin
            w_cnt_d -= 1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : axi_write_channel_ff
        if(~rst_ni) begin
            aw_state_q  <= FEEDTHROUGH_AW;
            w_state_q   <= FEEDTHROUGH_W;
            b_state_q   <= FEEDTHROUGH_B;
            w_cnt_q     <= '0;
            w_cnt_req_q <= '0;
            w_cnt_inj_q <= '0;
            addr_q      <= '0;
            id_q        <= '0;
            size_q      <= '0;
            strb_q      <= '0;
            cache_q     <= '0;
            prot_q      <= '0;
            qos_q       <= '0;
            region_q    <= '0;
            aw_user_q   <= '0;
            w_user_q    <= '0;
            w_data_q    <= '0;
            result_q    <= '0;
            w_d_valid_q <= '0;
            atop_q      <= 6'b0;
        end else begin
            aw_state_q  <= aw_state_d;
            w_state_q   <= w_state_d;
            b_state_q   <= b_state_d;
            w_cnt_q     <= w_cnt_d;
            w_cnt_req_q <= w_cnt_req_d;
            w_cnt_inj_q <= w_cnt_inj_d;
            addr_q      <= addr_d;
            id_q        <= id_d;
            size_q      <= size_d;
            strb_q      <= strb_d;
            cache_q     <= cache_d;
            prot_q      <= prot_d;
            qos_q       <= qos_d;
            region_q    <= region_d;
            aw_user_q   <= aw_user_d;
            w_user_q    <= w_user_d;
            w_data_q    <= w_data_d;
            result_q    <= result_d;
            w_d_valid_q <= w_d_valid_d;
            atop_q      <= atop_d;
        end
    end

    /**
    * Read Channel: AR, R
    */

    /*====================================================================
    =                                AR                                  =
    ====================================================================*/
    always_comb begin : axi_ar_channel
        // Defaults AXI Bus
        mst_ar_id_o     = slv_ar_id_i;
        mst_ar_addr_o   = slv_ar_addr_i;
        mst_ar_len_o    = slv_ar_len_i;
        mst_ar_size_o   = slv_ar_size_i;
        mst_ar_burst_o  = slv_ar_burst_i;
        mst_ar_lock_o   = slv_ar_lock_i;
        mst_ar_cache_o  = slv_ar_cache_i;
        mst_ar_prot_o   = slv_ar_prot_i;
        mst_ar_qos_o    = slv_ar_qos_i;
        mst_ar_region_o = slv_ar_region_i;
        mst_ar_user_o   = slv_ar_user_i;
        mst_ar_valid_o  = 1'b0;
        slv_ar_ready_o  = 1'b0;
        // State Machine
        ar_state_d      = ar_state_q;

        unique case (ar_state_q)

            FEEDTHROUGH_AR: begin
                // Feed through
                mst_ar_valid_o = slv_ar_valid_i;
                slv_ar_ready_o = mst_ar_ready_i;

                if (adapter_ready) begin
                    if (atop_valid_d == LOAD | atop_valid_d == STORE) begin
                        if (ar_free) begin
                            // Acquire channel
                            slv_ar_ready_o  = 1'b0;
                            // Immediately start read request
                            mst_ar_valid_o  = 1'b1;
                            mst_ar_addr_o   = slv_aw_addr_i;
                            mst_ar_id_o     = slv_aw_id_i;
                            mst_ar_len_o    = 8'h00;
                            mst_ar_size_o   = slv_aw_size_i;
                            mst_ar_burst_o  = 2'b00;
                            mst_ar_lock_o   = 1'h0;
                            mst_ar_cache_o  = slv_aw_cache_i;
                            mst_ar_prot_o   = slv_aw_prot_i;
                            mst_ar_qos_o    = slv_aw_qos_i;
                            mst_ar_region_o = slv_aw_region_i;
                            mst_ar_user_o   = slv_aw_user_i;
                            if (!mst_ar_ready_i) begin
                                // Hold read request but do not depend on AW
                                ar_state_d = SEND_AR;
                            end
                        end else begin
                            // Wait until AR is free
                            ar_state_d   = WAIT_CHANNEL_AR;
                        end
                    end
                end
            end // FEEDTHROUGH_AR

            WAIT_CHANNEL_AR, SEND_AR: begin
                // Issue read request
                if (ar_free || (ar_state_q == SEND_AR)) begin
                    // Inject read request
                    mst_ar_valid_o  = 1'b1;
                    mst_ar_addr_o   = addr_q;
                    mst_ar_id_o     = id_q;
                    mst_ar_len_o    = 8'h00;
                    mst_ar_size_o   = size_q;
                    mst_ar_burst_o  = 2'b00;
                    mst_ar_lock_o   = 1'h0;
                    mst_ar_cache_o  = cache_q;
                    mst_ar_prot_o   = prot_q;
                    mst_ar_qos_o    = qos_q;
                    mst_ar_region_o = region_q;
                    mst_ar_user_o   = aw_user_q;
                    if (mst_ar_ready_i) begin
                        // Request acknowledged
                        ar_state_d = FEEDTHROUGH_AR;
                    end else begin
                        // Hold read request
                        ar_state_d = SEND_AR;
                    end
                end else begin
                    // Wait until AR is free
                    mst_ar_valid_o = slv_ar_valid_i;
                    slv_ar_ready_o = mst_ar_ready_i;
                end
            end // WAIT_CHANNEL_AR, SEND_AR

            default: ar_state_d = FEEDTHROUGH_AR;

        endcase
    end // axi_ar_channel

    /*====================================================================
    =                                 R                                  =
    ====================================================================*/
    always_comb begin : axi_r_channel
        // Defaults AXI Bus
        mst_r_ready_o = slv_r_ready_i;
        slv_r_id_o    = mst_r_id_i;
        slv_r_data_o  = mst_r_data_i;
        slv_r_resp_o  = mst_r_resp_i;
        slv_r_last_o  = mst_r_last_i;
        slv_r_user_o  = mst_r_user_i;
        slv_r_valid_o = mst_r_valid_i;
        // Defaults FF
        r_data_d      = r_data_q;
        r_resp_d      = r_resp_q;
        r_user_d      = r_user_q;
        r_d_valid_d   = r_d_valid_q;
        // State Machine
        r_state_d     = r_state_q;

        unique case (r_state_q)

            FEEDTHROUGH_R: begin
                if (adapter_ready) begin
                    // Reset read flag
                    r_d_valid_d = 1'b0;

                    if (atop_valid_d == LOAD || atop_valid_d == STORE) begin
                        // Wait for R response to read data
                        r_state_d = WAIT_DATA_R;
                    end else if (atop_valid_d == INVALID) begin
                        // Send R response once channel is free
                        if (r_free) begin
                            // Acquire the R channel
                            // Block downstream
                            mst_r_ready_o = 1'b0;
                            // Send R error response
                            slv_r_valid_o = 1'b1;
                            slv_r_data_o  = '0;
                            slv_r_id_o    = slv_aw_id_i;
                            slv_r_last_o  = 1'b1;
                            slv_r_resp_o  = axi_pkg::RESP_SLVERR;
                            slv_r_user_o  = '0;
                            if (!slv_r_ready_i) begin
                                // Hold R response
                                r_state_d = SEND_R;
                            end
                        end else begin
                            r_state_d = WAIT_CHANNEL_R;
                        end
                    end
                end
            end // FEEDTHROUGH_R

            WAIT_DATA_R: begin
                // Read data
                if (mst_r_valid_i && (mst_r_id_i == id_q)) begin
                    // Acknowledge downstream and block upstream
                    mst_r_ready_o = 1'b1;
                    slv_r_valid_o = 1'b0;
                    // Store data
                    r_data_d    = mst_r_data_i;
                    r_resp_d    = mst_r_resp_i;
                    r_user_d    = mst_r_user_i;
                    r_d_valid_d = 1'b1;
                    if (atop_valid_q == STORE) begin
                        r_state_d = FEEDTHROUGH_R;
                    end else begin
                        // Wait for B resp before injecting R
                        r_state_d = WAIT_CHANNEL_R;
                    end
                end
            end // WAIT_DATA_R

            WAIT_CHANNEL_R, SEND_R: begin
                // Wait for the R channel to become free and B response to be valid
                // TODO: Use b_state_d to be one cycle quicker
                if ((r_free && (b_state_q != WAIT_COMPLETE_B)) || (r_state_q == SEND_R)) begin
                    // Block downstream
                    mst_r_ready_o = 1'b0;
                    // Send R response
                    slv_r_valid_o = 1'b1;
                    slv_r_data_o  = r_data_q;
                    slv_r_id_o    = id_q;
                    slv_r_last_o  = 1'b1;
                    slv_r_resp_o  = r_resp_q;
                    slv_r_user_o  = r_user_q;
                    if (atop_valid_q == INVALID) begin
                        slv_r_data_o = '0;
                        slv_r_resp_o = axi_pkg::RESP_SLVERR;
                        slv_r_user_o = '0;
                    end
                    if (slv_r_ready_i) begin
                        r_state_d = FEEDTHROUGH_R;
                    end else begin
                        r_state_d = SEND_R;
                    end
                end
            end // WAIT_CHANNEL_R, SEND_R

            default: r_state_d = FEEDTHROUGH_R;

        endcase
    end // axi_r_channel

    always_ff @(posedge clk_i or negedge rst_ni) begin : axi_read_channel_ff
        if(~rst_ni) begin
            ar_state_q  <= FEEDTHROUGH_AR;
            r_state_q   <= FEEDTHROUGH_R;
            r_data_q    <= '0;
            r_resp_q    <= '0;
            r_user_q    <= '0;
            r_d_valid_q <= 1'b0;
        end else begin
            ar_state_q  <= ar_state_d;
            r_state_q   <= r_state_d;
            r_data_q    <= r_data_d;
            r_resp_q    <= r_resp_d;
            r_user_q    <= r_user_d;
            r_d_valid_q <= r_d_valid_d;
        end
    end

    /**
     * ALU
     */

    assign big_endian     = (atop_q[3] == axi_pkg::ATOP_BIG_END);
    // Intermediate wires: Verilator ≥5.0xx rejects streaming concat in ternary
    // (implicit cast context, IEEE 1800-2023 11.4.17).
    logic [AXI_ALU_RATIO*RISCV_WORD_WIDTH-1:0] op_a_be, op_b_be, op_b_be_full, res_be;
    assign op_a_be        = {<<8{r_data_q & strb_ext}};
    assign op_b_be        = {<<8{w_data_q & strb_ext}};
    // Full-word BE swap for AtomicCompare (no strb mask); keep stream out of ternary.
    assign op_b_be_full   = {<<8{w_data_q}};
    assign res_be         = {<<8{res}};
    assign op_a           = big_endian ? op_a_be : (r_data_q & strb_ext);
    // AtomicCompare packs {cmp,swap} across the full write data word; do not
    // byte-mask op_b or the compare half is lost when strb covers only the
    // store lane.
    assign op_b           = (atop_q == axi_pkg::ATOP_ATOMICCMP)
                                ? (big_endian ? op_b_be_full : w_data_q)
                                : (big_endian ? op_b_be : (w_data_q & strb_ext));
    assign sign_a         = |(op_a & ~(strb_ext >> 1));
    assign sign_b         = |(op_b & ~(strb_ext >> 1));
    assign alu_result_ext = big_endian ? res_be : res;

    generate
        if (AXI_ALU_RATIO == 1 && RISCV_WORD_WIDTH == 32) begin
            assign alu_operand_a  = op_a;
            assign alu_operand_b  = op_b;
            assign res            = alu_result;
        end else if (AXI_ALU_RATIO == 1 && RISCV_WORD_WIDTH == 64) begin
            assign res        = alu_result;
            always_comb begin
                op_a_sign_ext = op_a | ({AXI_ALU_RATIO*RISCV_WORD_WIDTH{sign_a}} & ~strb_ext);
                op_b_sign_ext = op_b | ({AXI_ALU_RATIO*RISCV_WORD_WIDTH{sign_b}} & ~strb_ext);

                if (atop_q[2:0] == axi_pkg::ATOP_SMAX || atop_q[2:0] == axi_pkg::ATOP_SMIN) begin
                    // Sign extend
                    alu_operand_a = op_a_sign_ext;
                    alu_operand_b = op_b_sign_ext;
                end else begin
                    // No sign extension necessary
                    alu_operand_a = op_a;
                    alu_operand_b = op_b;
                end
            end
        end else begin
            always_comb begin
                op_a_sign_ext = op_a | ({AXI_ALU_RATIO*RISCV_WORD_WIDTH{sign_a}} & ~strb_ext);
                op_b_sign_ext = op_b | ({AXI_ALU_RATIO*RISCV_WORD_WIDTH{sign_b}} & ~strb_ext);

                if (atop_q[2:0] == axi_pkg::ATOP_SMAX || atop_q[2:0] == axi_pkg::ATOP_SMIN) begin
                    // Sign extend
                    alu_operand_a = op_a_sign_ext[addr_q[$clog2(AXI_DATA_WIDTH/8)-1:$clog2(RISCV_WORD_WIDTH/8)]];
                    alu_operand_b = op_b_sign_ext[addr_q[$clog2(AXI_DATA_WIDTH/8)-1:$clog2(RISCV_WORD_WIDTH/8)]];
                end else begin
                    // No sign extension necessary
                    alu_operand_a = op_a[addr_q[$clog2(AXI_DATA_WIDTH/8)-1:$clog2(RISCV_WORD_WIDTH/8)]];
                    alu_operand_b = op_b[addr_q[$clog2(AXI_DATA_WIDTH/8)-1:$clog2(RISCV_WORD_WIDTH/8)]];
                end
                res = '0;
                res[addr_q[$clog2(AXI_DATA_WIDTH/8)-1:$clog2(RISCV_WORD_WIDTH/8)]] = alu_result;
            end
        end
    endgenerate

    generate
        for (genvar i = 0; i < AXI_STRB_WIDTH; i++) begin
            always_comb begin
                if (strb_q[i]) begin
                    strb_ext[i] = 8'hFF;
                end else begin
                    strb_ext[i] = 8'h00;
                end
            end
        end
    endgenerate

    axi_riscv_amos_alu #(
        .DATA_WIDTH ( RISCV_WORD_WIDTH )
    ) i_amo_alu (
        .amo_op_i           ( atop_q        ),
        .amo_operand_a_i    ( alu_operand_a ),
        .amo_operand_b_i    ( alu_operand_b ),
        .amo_result_o       ( alu_result    )
    );

    // Validate parameters.
// pragma translate_off
`ifndef VERILATOR
    initial begin: validate_params
        assert (AXI_ADDR_WIDTH > 0)
            else $fatal(1, "AXI_ADDR_WIDTH must be greater than 0!");
        assert (AXI_DATA_WIDTH > 0)
            else $fatal(1, "AXI_DATA_WIDTH must be greater than 0!");
        assert (AXI_ID_WIDTH > 0)
            else $fatal(1, "AXI_ID_WIDTH must be greater than 0!");
        assert (AXI_MAX_WRITE_TXNS > 0)
            else $fatal(1, "AXI_MAX_WRITE_TXNS must be greater than 0!");
        assert (RISCV_WORD_WIDTH == 32 || RISCV_WORD_WIDTH == 64)
            else $fatal(1, "RISCV_WORD_WIDTH must be 32 or 64!");
        assert (RISCV_WORD_WIDTH <= AXI_DATA_WIDTH)
            else $fatal(1, "RISCV_WORD_WIDTH must not be greater than AXI_DATA_WIDTH!");
    end
`endif
// pragma translate_on

endmodule
