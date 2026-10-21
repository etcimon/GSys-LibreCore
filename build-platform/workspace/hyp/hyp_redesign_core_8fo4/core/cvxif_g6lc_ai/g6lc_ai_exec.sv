// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai execute stage (CVXIF seam B).
//
// T0: setcfg/getcfg/dot4* (1-cycle).
// T1: tile RF (flops) + accumulator bank on tc_sram (g6lc_ai_acc_bank) +
// multi-cycle ai.mma.* (one (m,n) full-K reduction per cycle).
// Island-scale staging lives in corev_apu (I1), not here.
//
// aicfg/ais owned by csr_regfile; sideband setcfg/dirty writeback.
// Timing: multi-cycle MMA stalls issue via busy_o (no ex_stage cone growth).

module g6lc_ai_exec
  import g6lc_ai_instr_pkg::*;
#(
    parameter int unsigned           NrRgprPorts = 2,
    parameter int unsigned           XLEN        = 64,
    parameter config_pkg::ai_cfg_t   AiCfg       = config_pkg::AiCfgOff,
    parameter type                   hartid_t    = logic,
    parameter type                   id_t        = logic,
    parameter type                   registers_t = logic
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  valid_i,
    input  registers_t            registers_i,
    input  opcode_t               opcode_i,
    input  logic       [31:0]     instr_i,
    input  hartid_t               hartid_i,
    input  id_t                   id_i,
    input  logic       [     4:0] rd_i,
    // CSR sideband
    input  logic       [XLEN-1:0] aicfg_i,
    input  logic       [     1:0] ais_i,
    input  logic                  ai_q_en_i,   // aiqctl[0] — enq enable
    input  logic [7:0]            ai_qid_i,    // aiqctl[15:8]
    // Island completion sideband for ai.poll (tie 0 when no island)
    input  logic                  isl_has_completion_i,
    // Sideband retired watermark (highest ticket the island has completed for
    // this producer, claimed or not). Answers polls for tickets behind the head.
    input  logic                  isl_retired_valid_i,
    input  logic [31:0]           isl_retired_ticket_i,
    input  logic [31:0]           isl_last_ticket_i,
    input  logic [15:0]           isl_last_status_i,
    // 1 when the sideband reaches a real island: ai.poll then reports only island
    // completions. 0 keeps the pre-P3 local-ticket stub for islandless bring-up.
    input  logic                  isl_attached_i,
    // Held-valid acceptance from the island; tie 1 for the legacy pulse contract.
    input  logic                  sb_enq_ready_i,
    // Ticket the island allocated for the accepted kick (valid with ready).
    input  logic [31:0]           sb_enq_ticket_i,
    input  logic                  testmode_i,  // DFT
    output logic                  setcfg_we_o,
    output logic       [XLEN-1:0] setcfg_wdata_o,
    output logic                  dirty_o,
    // Stall new issue while multi-cycle MMA is in flight
    output logic                  busy_o,
    // Sideband kick to island (ai.enq): ticket/qid + optional desc ptr (rs1).
    // Non-zero ptr ⇒ island DMA-fetch 64 B then run; zero ⇒ latched MMIO desc.
    output logic                  sb_enq_valid_o,
    output logic [7:0]            sb_qid_o,
    output logic [31:0]           sb_ticket_o,
    output logic [XLEN-1:0]       sb_desc_ptr_o,
    // PMU pulses (1-cycle, group 4 — see g6lc_core_pkg MHPMGrpAI)
    output logic                  pmu_op_o,      // any result_valid
    output logic                  pmu_mma_o,     // MMA done
    output logic                  pmu_post_o,    // requant/relu/gelu done
    output logic                  pmu_t0_o,      // T0 single-cycle complete
    // Result
    output logic       [XLEN-1:0] result_o,
    output hartid_t               hartid_o,
    output id_t                   id_o,
    output logic       [     4:0] rd_o,
    output logic                  valid_o,
    output logic                  we_o
);

  // Elaboration-time geometry (max). Active shape is min(aicfg request, max).
  localparam int unsigned TileM     = (AiCfg.TileM == 0) ? 8 : AiCfg.TileM;
  localparam int unsigned TileN     = (AiCfg.TileN == 0) ? 8 : AiCfg.TileN;
  localparam int unsigned TileK     = (AiCfg.TileK == 0) ? 8 : AiCfg.TileK;
  localparam int unsigned TileCount = (AiCfg.TileCount == 0) ? 8 : AiCfg.TileCount;
  localparam int unsigned AccDepth  = (AiCfg.AccDepth == 0) ? 4 : AiCfg.AccDepth;
  localparam int unsigned AccBanks  = (AiCfg.AccBanks == 0) ? 1 : AiCfg.AccBanks;
  localparam int unsigned AccCount  = AccDepth * AccBanks;
  localparam int unsigned TileElems = TileM * TileN;
  localparam int unsigned AccElems  = TileM * TileN;  // same spatial shape as C tile
  // hyp8 AiCfgOff normalises to these literals, and every preset in
  // config_pkg has TileM/N/K == 8 so the row stride is a shift. sv-timing
  // does not fold AiCfg struct fields, so a localparam TileN on this cone
  // was a variable multiply. The literals are the silicon values.
  localparam int unsigned TE64 = 64;
  localparam int unsigned TC8 = 8;
  localparam int unsigned AC4 = 4;
  // pragma translate_off
  initial begin
    assert (TileN == 8 && TileM == 8 && TileK == 8 && TileElems == TE64 && AccElems == TE64
            && TileCount == TC8 && AccCount == AC4 && $clog2(TileElems) == 6)
      else $error("g6lc_ai_exec index geometry is the hyp8 AiCfgOff normalisation");
  end
  // pragma translate_on

  // ------------------------------------------------------------------ helpers
  function automatic logic [3:0] clog2_u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction

  function automatic logic [XLEN-1:0] grant_setcfg(input logic [XLEN-1:0] req);
    logic [XLEN-1:0] g;
    logic [3:0] m_req, n_req, k_req, m_max, n_max, k_max;
    g = '0;
    m_max = clog2_u(TileM);
    n_max = clog2_u(TileN);
    k_max = clog2_u(TileK);
    m_req = req[3:0];
    n_req = req[7:4];
    k_req = req[11:8];
    g[3:0]   = (m_req > m_max) ? m_max : m_req;
    g[7:4]   = (n_req > n_max) ? n_max : n_req;
    g[11:8]  = (k_req > k_max) ? k_max : k_req;
    g[13:12] = req[13:12];
    g[15:14] = (req[15:14] == 2'b11) ? 2'b01 : req[15:14];
    g[19:16] = AiContractVersion;
    g[21:20] = (AiCfg.Int4En && req[21:20] == 2'b01) ? 2'b01 : 2'b00;
    g[22]    = AiCfg.Sparse24En ? req[22] : 1'b0;
    return g;
  endfunction

  // Active shape from aicfg (powers of two, clamped to elab max)
  function automatic int unsigned dim_of(input logic [3:0] lg, input int unsigned maxv);
    int unsigned d;
    d = 1 << lg;
    return (d > maxv || lg == 0 && maxv >= 1) ? ((d > maxv) ? maxv : d) : d;
  endfunction

  // ------------------------------------------------------------------ storage
  // tiles[tile][elem] INT8 — flops (multi-read K-reduction per cycle)
  logic [7:0]  tiles_q [TileCount][TileElems];
  logic [7:0]  tiles_d [TileCount][TileElems];

  // Accumulators: one SRAM word = full spatial tile (AccElems × s32) via tc_sram
  localparam int unsigned AccDataW = AccElems * 32;
  localparam int unsigned AccBeW   = AccDataW / 8;
  localparam int unsigned AccAddrW = (AccCount > 1) ? $clog2(AccCount) : 1;

  logic                 acc_r_req, acc_w_req;
  logic [AccAddrW-1:0]  acc_r_acc, acc_w_acc;
  logic [AccDataW-1:0]  acc_r_data, acc_w_data;
  logic [AccBeW-1:0]    acc_w_be;

  g6lc_ai_acc_bank #(
      .AccCount(AccCount),
      .AccElems(AccElems)
  ) i_acc_bank (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .testmode_i(testmode_i),
      .r_req_i   (acc_r_req),
      .r_acc_i   (acc_r_acc),
      .r_data_o  (acc_r_data),
      .w_req_i   (acc_w_req),
      .w_acc_i   (acc_w_acc),
      .w_data_i  (acc_w_data),
      .w_be_i    (acc_w_be)
  );

  // Element extract / byte-enable helpers for the wide bank word
  function automatic logic signed [31:0] acc_get(
      input logic [AccDataW-1:0] bank, input int unsigned elem
  );
    return signed'(bank[elem*32 +: 32]);
  endfunction

  function automatic logic [AccBeW-1:0] acc_be_elem(input int unsigned elem);
    logic [AccBeW-1:0] be;
    be = '0;
    if (elem < AccElems) be[elem*4 +: 4] = 4'hF;
    return be;
  endfunction

  function automatic logic [AccDataW-1:0] acc_wdata_elem(
      input int unsigned elem, input logic signed [31:0] v
  );
    logic [AccDataW-1:0] w;
    w = '0;
    if (elem < AccElems) w[elem*32 +: 32] = v;
    return w;
  endfunction

  // ------------------------------------------------------------------ multi-cycle FSM
  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,
    ST_MMA   = 3'd1,
    ST_DONE  = 3'd2,
    ST_RQ    = 3'd3,  // requant product
    ST_RQ_S  = 3'd6,  // requant magnitude shift
    ST_RQ_R  = 3'd7,  // requant round, zp, clamp, tile write
    ST_RELU  = 3'd4,
    ST_ENQ   = 3'd5   // ai.enq held until the island accepts (VALID/READY)
  } state_e;
  state_e state_q, state_d;

  logic [4:0]  mma_acc_q, mma_ta_q, mma_tb_q;
  logic [4:0]  mma_acc_d, mma_ta_d, mma_tb_d;
  logic [3:0]  mma_m_q, mma_n_q;       // spatial iterators
  logic [3:0]  mma_m_d, mma_n_d;
  logic [3:0]  mma_M_q, mma_N_q, mma_K_q;  // active dims
  logic [3:0]  mma_M_d, mma_N_d, mma_K_d;
  logic [1:0]  mma_dtype_q, mma_accmode_q;
  logic [1:0]  mma_dtype_d, mma_accmode_d;
  hartid_t     mma_hart_q, mma_hart_d;
  id_t         mma_id_q, mma_id_d;
  logic [4:0]  mma_rd_q, mma_rd_d;
  opcode_t     mma_op_q, mma_op_d;
  // requant packed scale: [15:0] s16 scale, [23:16] s8 zp, [27:24] shift 0..15
  // Seam B: both ai.requant and ai.requant.t take this packing in the rs2 GPR
  // (pointer form cannot dereference memory without a DMA port).
  logic [31:0] rq_pack_q, rq_pack_d;

  logic [31:0] ticket_q, ticket_d;
  logic        sb_enq_n, sb_enq_q;
  logic [7:0]  sb_qid_n, sb_qid_q;
  logic [31:0] sb_ticket_n, sb_ticket_q;
  logic [XLEN-1:0] sb_desc_ptr_n, sb_desc_ptr_q;

  assign sb_enq_valid_o = sb_enq_q;
  assign sb_qid_o       = sb_qid_q;
  assign sb_ticket_o    = sb_ticket_q;
  assign sb_desc_ptr_o  = sb_desc_ptr_q;

  // Decode indices from the instruction word (tile/acc are not RF regs)
  logic [4:0] idx_rs1, idx_rs2, idx_rd;
  assign idx_rs1 = instr_i[19:15];
  assign idx_rs2 = instr_i[24:20];
  assign idx_rd  = instr_i[11:7];

  // ------------------------------------------------------------------ outputs
  logic [XLEN-1:0] result_n, result_q;
  hartid_t         hartid_n, hartid_q;
  id_t             id_n, id_q;
  logic            valid_n, valid_q;
  logic [4:0]      rd_n, rd_q;
  logic            we_n, we_q;
  logic            setcfg_we_n, setcfg_we_q;
  logic [XLEN-1:0] setcfg_wdata_n, setcfg_wdata_q;
  logic            dirty_n, dirty_q;
  logic signed [31:0] dot4a_dot_s, dot4a_acc_s;
  logic [XLEN-1:0]    dot4a_prod;

  assign result_o       = result_q;
  assign hartid_o       = hartid_q;
  assign id_o           = id_q;
  assign valid_o        = valid_q;
  assign rd_o           = rd_q;
  assign we_o           = we_q;
  assign setcfg_we_o    = setcfg_we_q;
  assign setcfg_wdata_o = setcfg_wdata_q;
  assign dirty_o        = dirty_q;
  assign busy_o         = (state_q != ST_IDLE);

  // Accumulator read request, formed only from registered state and the issue
  // inputs. Kept out of the FSM process so the Latency-0 read data that process
  // consumes is not also a function of its own outputs (a scheduling loop).
  always_comb begin
    acc_r_req = 1'b0;
    acc_r_acc = '0;
    if (state_q == ST_IDLE && valid_i && opcode_i == AI_MVACC && idx_rs1 < AccCount) begin
      acc_r_req = 1'b1;
      acc_r_acc = AccAddrW'(idx_rs1);
    end else if ((state_q == ST_MMA || state_q == ST_RQ) && mma_acc_q < AccCount) begin
      acc_r_req = 1'b1;
      acc_r_acc = AccAddrW'(mma_acc_q);
    end
  end

  // Classify completing ops for PMU (latched with valid_q)
  logic pmu_mma_n, pmu_mma_q, pmu_post_n, pmu_post_q, pmu_t0_n, pmu_t0_q;
  assign pmu_op_o   = valid_q;
  assign pmu_mma_o  = valid_q && pmu_mma_q;
  assign pmu_post_o = valid_q && pmu_post_q;
  assign pmu_t0_o   = valid_q && pmu_t0_q;

  // ai.poll — POLL_PENDING/OK/ERR (g6lc_ai_instr_pkg F15). Prefer island.
  logic [31:0] poll_want;
  logic        poll_isl_hit, poll_isl_err, poll_local_done;
  logic [1:0]  poll_status;
  assign poll_want       = registers_i[0][31:0];
  // Head match gives the exact status. Any other ticket at or below the
  // retired watermark is complete (its detail is in the completion word /
  // the MMIO claim); above it, or with no island evidence, it is pending.
  assign poll_isl_hit    = (isl_has_completion_i && (poll_want == isl_last_ticket_i)) ||
                           (isl_retired_valid_i && (poll_want <= isl_retired_ticket_i));
  assign poll_isl_err    = isl_has_completion_i && (poll_want == isl_last_ticket_i) &&
                           (isl_last_status_i != 16'd0);
  assign poll_local_done = !isl_attached_i && (poll_want < ticket_q);
  always_comb begin
    if (!ai_q_en_i) poll_status = POLL_PENDING[1:0];
    else if (poll_isl_err) poll_status = POLL_ERR[1:0];
    else if (poll_isl_hit || poll_local_done) poll_status = POLL_OK[1:0];
    else poll_status = POLL_PENDING[1:0];
  end

  // T0 dot4. Four byte products in parallel, then one four-operand sum.
  // The old dot4_s8/dot4_u8 functions carried acc += aa*bb for four trips,
  // and that function body was one ~280 FO4 node on result_n. Sum and
  // valid still update together in ST_IDLE (no extra issue cycle).
  logic [XLEN-1:0]    dot4_a, dot4_b;
  logic signed [31:0] dot4_s_p [4];
  logic        [31:0] dot4_u_p [4];
  logic signed [31:0] dot4_s_sum;
  logic        [31:0] dot4_u_sum;
  assign dot4_a = XLEN'(registers_i[0]);
  assign dot4_b = XLEN'(registers_i[1]);
  for (genvar di = 0; di < 4; di++) begin : gen_dot4
    assign dot4_s_p[di] = 32'(signed'(dot4_a[di*8 +: 8]) * signed'(dot4_b[di*8 +: 8]));
    assign dot4_u_p[di] = 32'(dot4_a[di*8 +: 8] * dot4_b[di*8 +: 8]);
  end
  assign dot4_s_sum = dot4_s_p[0] + dot4_s_p[1] + dot4_s_p[2] + dot4_s_p[3];
  assign dot4_u_sum = dot4_u_p[0] + dot4_u_p[1] + dot4_u_p[2] + dot4_u_p[3];

  // Requant is four registered steps per element: extend, product, magnitude
  // shift, then round/zp/clamp. The tile write and the (m,n) advance happen
  // on the round step. valid_o is still only ST_DONE.
  logic [15:0]        rq_c_wide;
  logic               rq_ok, rq_acc_ok, rq_ta_ok, rq_el_ok;
  logic signed [15:0] rq_sc;
  logic signed [7:0]  rq_zp;
  logic [3:0]         rq_sh;
  logic signed [31:0] rq_aval;
  logic signed [47:0] rq_aval_w, rq_aval_q, rq_sc_w, rq_prod;
  logic [1:0]         rq_ph_q;
  logic [15:0]        rq_c_q;
  logic signed [47:0] rq_prod_q, rq_ux, rq_ux_q, rq_t, rq_t_q, rq_t_rnd, rq_adj;
  logic               rq_neg_q, rq_sh0_q, rq_bump;
  logic [47:0]        rq_mask, rq_half, rq_rem, rq_rem_q;
  logic signed [31:0] rq_wz;
  logic               rq_hi, rq_lo;
  logic [7:0]         rq_byte;
  localparam int unsigned RQ_IDX_W = (TileElems <= 1) ? 1 : $clog2(TileElems);
  logic [RQ_IDX_W-1:0] rq_c_idx;

  assign rq_sc     = signed'(rq_pack_q[15:0]);
  assign rq_zp     = signed'(rq_pack_q[23:16]);
  assign rq_sh     = rq_pack_q[27:24];
  // m * 8 + n. AccElems and TileElems are both 64, so one compare covers both.
  assign rq_c_wide = {8'd0, mma_m_q, 3'b0} + 16'(mma_n_q);
  // Separate compares. One && expression was a single 21 FO4 node.
  assign rq_acc_ok = mma_acc_q < 5'd4;
  assign rq_ta_ok  = mma_ta_q < 5'd8;
  assign rq_el_ok  = rq_c_wide < 16'd64;
  assign rq_ok     = rq_acc_ok & rq_ta_ok & rq_el_ok;
  // 64 elements: the index is the low 6 bits. A bound of $clog2(TileElems)
  // is a variable shift.
  assign rq_c_idx  = rq_c_wide[5:0];
  // The element index is registered on requant phase 0. The accumulator
  // read uses that flop, so the m*8+n add is not in series with the extract.
  assign rq_aval   = acc_get(acc_r_data, int'(rq_c_q));
  assign rq_aval_w = signed'({{16{rq_aval[31]}}, rq_aval});
  assign rq_sc_w   = signed'({{32{rq_sc[15]}}, rq_sc});
  // Multiply the registered extension. The read and the sign-extend are the
  // previous ST_RQ cycle, so they are not in series with this product.
  assign rq_prod   = rq_aval_q * rq_sc_w;

  // rq_sh is a runtime amount. A variable shift is a barrel (~32 FO4).
  // Each amount is a constant shift; rq_sh only muxes the arm. sh==0 wraps
  // the half amount the way a 4-bit subtract does (0-1 = 15).
  // The mask and the half are shifts of a constant one. A variable
  // shift of that one was ~32 FO4. Each amount is a constant shift and
  // rq_sh only muxes. The product magnitude shift stays one variable
  // shift: muxing 16 shifted copies of the data measured worse.
  logic [15:0][47:0] rq_one_sh, rq_half_sh, rq_mask_sh;
  for (genvar s = 0; s < 16; s++) begin : gen_rq_sh
    if (s == 0) begin : gen_sh0
      assign rq_half_sh[s] = 48'b1 << 15;
    end else begin : gen_shn
      assign rq_half_sh[s] = 48'b1 << (s - 1);
    end
    assign rq_one_sh[s]  = 48'b1 << s;
    assign rq_mask_sh[s] = rq_one_sh[s] - 48'b1;
  end
  assign rq_mask = rq_mask_sh[rq_sh];
  assign rq_half = rq_half_sh[rq_sh];
  // Absolute value. A signed unary minus on this product was one 30 FO4
  // node; the following >> rq_sh is 2. Invert plus one is a 48-bit add.
  logic [47:0] rq_prod_bits, rq_mag_neg;
  assign rq_prod_bits = rq_prod_q;
  assign rq_mag_neg   = ~rq_prod_bits + 48'd1;
  assign rq_ux        = rq_prod_bits[47] ? rq_mag_neg : rq_prod_bits;
  assign rq_rem       = rq_ux & rq_mask;
  // One variable shift. A 16-way mux of shifted copies measured 34.6.
  // Both halves of a 4-way split in one cycle measured 39.8, and a
  // register between those halves measured 32.8.
  assign rq_t         = rq_ux >> rq_sh;

  assign rq_bump  = (rq_rem_q > rq_half) || ((rq_rem_q == rq_half) && rq_t_q[0]);
  assign rq_t_rnd = rq_bump ? (rq_t_q + 48'sd1) : rq_t_q;
  assign rq_adj   = rq_sh0_q ? rq_prod_q : (rq_neg_q ? -rq_t_rnd : rq_t_rnd);
  assign rq_wz    = rq_adj[31:0] + 32'(rq_zp);
  assign rq_hi    = rq_wz > 32'sd127;
  assign rq_lo    = !rq_hi && (rq_wz < -32'sd128);
  assign rq_byte  = rq_hi ? 8'sd127 : rq_lo ? 8'sh80 : rq_wz[7:0];

  // 0 register the element index, 1 capture the extended accumulator,
  // 2 capture the product. One extra coprocessor cycle per element.
  // valid_o is still only ST_DONE.
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_ph_ff
    if (!rst_ni) rq_ph_q <= 2'd0;
    else if (state_q == ST_RQ) rq_ph_q <= (rq_ph_q == 2'd2) ? 2'd0 : rq_ph_q + 2'd1;
    else rq_ph_q <= 2'd0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_c_ff
    if (!rst_ni) rq_c_q <= '0;
    else if (state_q == ST_RQ && rq_ph_q == 2'd0) rq_c_q <= rq_ok ? rq_c_wide : 16'd0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_aval_ff
    if (!rst_ni) rq_aval_q <= '0;
    else if (state_q == ST_RQ && rq_ph_q == 2'd1) rq_aval_q <= rq_aval_w;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_prod_ff
    if (!rst_ni) rq_prod_q <= '0;
    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_prod_q <= rq_prod;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_neg_ff
    if (!rst_ni) rq_neg_q <= 1'b0;
    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_neg_q <= rq_prod[47];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_sh0_ff
    if (!rst_ni) rq_sh0_q <= 1'b0;
    else if (state_q == ST_RQ && rq_ph_q == 2'd2) rq_sh0_q <= (rq_sh == 4'd0);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_ux_ff
    if (!rst_ni) rq_ux_q <= '0;
    else if (state_q == ST_RQ_S) rq_ux_q <= rq_ux;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_t_ff
    if (!rst_ni) rq_t_q <= '0;
    else if (state_q == ST_RQ_S) rq_t_q <= rq_t;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : rq_rem_ff
    if (!rst_ni) rq_rem_q <= '0;
    else if (state_q == ST_RQ_S) rq_rem_q <= rq_rem;
  end

  // ------------------------------------------------------------------ combo
  // One (m,n) dot over K. Products are parallel lanes; the sum is one
  // adder, not mac_sum = mac_sum + product carried across TileK.
  logic [7:0]         mac_a_q [TileK];
  logic [7:0]         mac_b_q [TileK];
  logic               mac_use_q [TileK];
  logic signed [31:0] mac_prod_q [TileK];
  localparam int unsigned MAC_TIDX_W = (TileCount <= 1) ? 1 : $clog2(TileCount);
  localparam int unsigned MAC_EIDX_W = (TileElems <= 1) ? 1 : $clog2(TileElems);
  for (genvar kk = 0; kk < TileK; kk++) begin : gen_mac_k
    logic [15:0] a_i, b_i;
    logic        use_k;
    logic [MAC_TIDX_W-1:0] ta_i, tb_i;
    logic [MAC_EIDX_W-1:0] ae, be;
    // One byte per operand. A second indexed read (signed view and raw
    // view) put 64 loads on ae, which is 21 FO4 before the byte mux.
    logic [7:0] a_byte, b_byte;
    assign a_i = {8'd0, mma_m_q, 3'b0} + 16'(kk);
    assign b_i = (16'(kk) << 3) + 16'(mma_n_q);
    assign use_k = (16'(kk) < 16'(mma_K_q)) && (a_i < TE64) && (b_i < TE64)
                && (mma_ta_q < TC8) && (mma_tb_q < TC8);
    assign ta_i  = mma_ta_q[MAC_TIDX_W-1:0];
    assign tb_i  = mma_tb_q[MAC_TIDX_W-1:0];
    // 64 elements. The low 6 bits are the element; the index fanout is
    // the cost, not this slice.
    assign ae    = a_i[5:0];
    assign be    = b_i[5:0];
    assign a_byte = tiles_q[ta_i][ae];
    assign b_byte = tiles_q[tb_i][be];
    // ph 0 captures the selected bytes. The multiply reads those flops.
    always_ff @(posedge clk_i or negedge rst_ni) begin : mac_a_ff
      if (!rst_ni) mac_a_q[kk] <= '0;
      else if (state_q == ST_MMA && mma_ph_q == 2'd0) mac_a_q[kk] <= a_byte;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin : mac_b_ff
      if (!rst_ni) mac_b_q[kk] <= '0;
      else if (state_q == ST_MMA && mma_ph_q == 2'd0) mac_b_q[kk] <= b_byte;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin : mac_use_ff
      if (!rst_ni) mac_use_q[kk] <= 1'b0;
      else if (state_q == ST_MMA && mma_ph_q == 2'd0) mac_use_q[kk] <= use_k;
    end
    // ph 1 captures the dtype-selected product, or zero when the lane is
    // off. One assignment so the multiply stays one node. Widths match
    // the old p_s/p_u (16) and p_su/p_us (17) captures. Signed and
    // unsigned views are casts of the same byte.
    always_ff @(posedge clk_i or negedge rst_ni) begin : mac_prod_ff
      if (!rst_ni) mac_prod_q[kk] <= '0;
      else if (state_q == ST_MMA && mma_ph_q == 2'd1)
        mac_prod_q[kk] <=
            ({32{mac_use_q[kk] && mma_dtype_q == 2'b00}} & 32'(signed'(16'(signed'(mac_a_q[kk]) * signed'(mac_b_q[kk])))))
          | ({32{mac_use_q[kk] && mma_dtype_q == 2'b01}} & 32'(signed'(16'(signed'({1'b0, mac_a_q[kk]}) * signed'({1'b0, mac_b_q[kk]})))))
          | ({32{mac_use_q[kk] && mma_dtype_q == 2'b10}} & 32'(signed'(17'(signed'(mac_a_q[kk]) * signed'({1'b0, mac_b_q[kk]})))))
          | ({32{mac_use_q[kk] && mma_dtype_q == 2'b11}} & 32'(signed'(17'(signed'({1'b0, mac_a_q[kk]}) * signed'(mac_b_q[kk])))));
    end
  end
  // TileK is 8. Use and dtype were applied when the product was captured,
  // so phase 2 is one eight-operand sum. The log tree was the longer cone.
  logic signed [31:0] mac_lane_sum;
  assign mac_lane_sum = mac_prod_q[0] + mac_prod_q[1] + mac_prod_q[2] + mac_prod_q[3]
                      + mac_prod_q[4] + mac_prod_q[5] + mac_prod_q[6] + mac_prod_q[7];

  // K-sum, element index, and the 33-bit accumulate are outside the FSM.
  // The saturate/write step uses the registered sum, so the read-modify
  // add is not in series with the byte-enable write. One extra cycle per
  // (m,n); valid_o is still only ST_DONE. Elements are distinct, so the
  // byte-enable write does not have to land in the same cycle as the read.
  // ReLU/GELU element. TileN is 8 in this config; a variable * TileN
  // was billed as a multiply on the copy into the tile flop.
  logic [15:0]               relu_c_w;
  logic                      relu_ok;
  logic [MAC_TIDX_W-1:0]     relu_ta, relu_tb;
  logic [MAC_EIDX_W-1:0]     relu_c_idx;
  logic signed [7:0]         relu_v;
  logic [7:0]                relu_byte;
  assign relu_c_w   = {8'd0, mma_m_q, 3'b0} + 16'(mma_n_q);
  assign relu_ta    = mma_ta_q[MAC_TIDX_W-1:0];
  assign relu_tb    = mma_tb_q[MAC_TIDX_W-1:0];
  assign relu_c_idx = relu_c_w[5:0];
  assign relu_ok    = (mma_ta_q < TC8) && (mma_tb_q < TC8) && (relu_c_w < TE64);
  assign relu_v     = signed'(tiles_q[relu_tb][relu_c_idx]);
  assign relu_byte  = (mma_op_q == AI_ACT_RELU && relu_v < 0) ? 8'd0 : relu_v;

  logic [15:0]        mac_c_w;
  logic               mma_elem_ok;
  logic signed [31:0] mac_old_w;
  logic signed [32:0] mac_wide;
  logic [2:0]         mma_ph_q;
  logic signed [32:0] mac_wide_q;
  logic signed [31:0] mac_sum_q;
  logic [15:0]        mac_c_q;
  logic               mac_sat_hi, mac_sat_lo;

  assign mac_c_w     = {8'd0, mma_m_q, 3'b0} + 16'(mma_n_q);
  assign mma_elem_ok = (mma_acc_q < AC4) && (mac_c_w < TE64);
  // Phase 2 registers the element index with the lane sum. Phase 3 reads
  // the accumulator from that flop, then adds.
  assign mac_old_w   = acc_get(acc_r_data, int'(mac_c_q));
  // The eight-lane sum is registered in mac_sum_q on phase 2. The
  // accumulator add is phase 3, so the sum is not in series with it.
  assign mac_wide    = signed'({mac_old_w[31], mac_old_w}) + signed'({mac_sum_q[31], mac_sum_q});
  assign mac_sat_hi  = mac_wide_q > 33'sd2147483647;
  assign mac_sat_lo  = mac_wide_q < -33'sd2147483648;

  // 0 bytes, 1 products, 2 sum, 3 accumulator add, 4 write and advance.
  always_ff @(posedge clk_i or negedge rst_ni) begin : mma_ph_ff
    if (!rst_ni) mma_ph_q <= 3'd0;
    else if (state_q == ST_MMA) mma_ph_q <= (mma_ph_q == 3'd4) ? 3'd0 : mma_ph_q + 3'd1;
    else mma_ph_q <= 3'd0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : mma_wide_ff
    if (!rst_ni) mac_wide_q <= '0;
    else if (state_q == ST_MMA && mma_ph_q == 3'd3) mac_wide_q <= mac_wide;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : mma_sum_ff
    if (!rst_ni) mac_sum_q <= '0;
    else if (state_q == ST_MMA && mma_ph_q == 2'd2) mac_sum_q <= mac_lane_sum;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : mma_c_ff
    if (!rst_ni) mac_c_q <= '0;
    else if (state_q == ST_MMA && mma_ph_q == 3'd2)
      mac_c_q <= mma_elem_ok ? mac_c_w : 16'd0;
  end

  always_comb begin
    logic signed [31:0] mac_new;
    // defaults: hold tiles; no acc write
    for (int unsigned t = 0; t < TileCount; t++)
      for (int unsigned e = 0; e < TileElems; e++) tiles_d[t][e] = tiles_q[t][e];
    acc_w_req  = 1'b0;
    acc_w_acc  = '0;
    acc_w_data = '0;
    acc_w_be   = '0;

    state_d        = state_q;
    mma_acc_d      = mma_acc_q;
    mma_ta_d       = mma_ta_q;
    mma_tb_d       = mma_tb_q;
    mma_m_d        = mma_m_q;
    mma_n_d        = mma_n_q;
    mma_M_d        = mma_M_q;
    mma_N_d        = mma_N_q;
    mma_K_d        = mma_K_q;
    mma_dtype_d    = mma_dtype_q;
    mma_accmode_d  = mma_accmode_q;
    mma_hart_d     = mma_hart_q;
    mma_id_d       = mma_id_q;
    mma_rd_d       = mma_rd_q;
    mma_op_d       = mma_op_q;
    rq_pack_d      = rq_pack_q;
    ticket_d       = ticket_q;
    sb_enq_n       = 1'b0;
    sb_qid_n       = sb_qid_q;
    sb_ticket_n    = sb_ticket_q;
    sb_desc_ptr_n  = sb_desc_ptr_q;

    result_n       = '0;
    hartid_n       = hartid_i;
    id_n           = id_i;
    valid_n        = 1'b0;
    rd_n           = rd_i;
    we_n           = 1'b0;
    setcfg_we_n    = 1'b0;
    setcfg_wdata_n = '0;
    dirty_n        = 1'b0;
    pmu_mma_n      = 1'b0;
    pmu_post_n     = 1'b0;
    pmu_t0_n       = 1'b0;
    dot4a_prod     = '0;
    dot4a_dot_s    = '0;
    dot4a_acc_s    = '0;

    unique case (state_q)
      ST_IDLE: begin
        if (valid_i) begin
          unique case (opcode_i)
            AI_SETCFG: begin
              setcfg_wdata_n = grant_setcfg(registers_i[0]);
              setcfg_we_n    = 1'b1;
              result_n       = setcfg_wdata_n;
              we_n           = 1'b1;
              dirty_n        = 1'b1;
              valid_n        = 1'b1;
              pmu_t0_n       = 1'b1;
            end
            AI_GETCFG: begin
              result_n = aicfg_i;
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_RELACC: begin
              // Whole-bank clear through tc_sram (single cycle, full BE)
              if (idx_rd < AccCount) begin
                acc_w_req  = 1'b1;
                acc_w_acc  = AccAddrW'(idx_rd);
                acc_w_data = '0;
                acc_w_be   = '1;
              end
              dirty_n  = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_DOT4_S8: begin
              result_n = XLEN'(signed'(dot4_s_sum));
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_DOT4_U8: begin
              result_n = XLEN'(dot4_u_sum);
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_DOT4A_S8: begin
              dot4a_prod  = XLEN'(signed'(dot4_s_sum));
              dot4a_dot_s = signed'(dot4a_prod[31:0]);
              if (NrRgprPorts >= 3) begin
                dot4a_acc_s = signed'(registers_i[2][31:0]);
                result_n    = XLEN'(signed'(dot4a_dot_s + dot4a_acc_s));
              end else result_n = dot4a_prod;
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_MVTA: begin
              // tile=rd, data=rs1 GPR, elem=rs2 field (0..31)
              if (idx_rd < TileCount && int'(idx_rs2) < TileElems) begin
                tiles_d[idx_rd][idx_rs2] = registers_i[0][7:0];
              end
              dirty_n  = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_MVACC: begin
              // rd GPR, acc=rs1, elem=rs2 — Latency=0 combo read
              if (idx_rs1 < AccCount && int'(idx_rs2) < AccElems) begin
                result_n  = XLEN'(acc_get(acc_r_data, int'(idx_rs2)));
              end else result_n = '0;
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_MMA_S8, AI_MMA_U8, AI_MMA_SU8, AI_MMA_US8: begin
              // Capture and enter multi-cycle
              mma_acc_d     = idx_rd;
              mma_ta_d      = idx_rs1;
              mma_tb_d      = idx_rs2;
              mma_m_d       = '0;
              mma_n_d       = '0;
              mma_M_d       = 4'(dim_of(aicfg_i[3:0], TileM));
              mma_N_d       = 4'(dim_of(aicfg_i[7:4], TileN));
              mma_K_d       = 4'(dim_of(aicfg_i[11:8], TileK));
              // Prefer opcode dtype if it encodes signedness; else aicfg
              unique case (opcode_i)
                AI_MMA_S8:  mma_dtype_d = 2'b00;
                AI_MMA_U8:  mma_dtype_d = 2'b01;
                AI_MMA_SU8: mma_dtype_d = 2'b10;
                default:    mma_dtype_d = 2'b11; // us8
              endcase
              mma_accmode_d = aicfg_i[15:14];
              mma_hart_d    = hartid_i;
              mma_id_d      = id_i;
              mma_rd_d      = rd_i;
              mma_op_d      = opcode_i;
              state_d       = ST_MMA;
              // no result this cycle
            end
            AI_REQUANT, AI_REQUANT_T: begin
              // dest tile=rd, src acc=rs1, packed scale in rs2 GPR
              mma_ta_d      = idx_rd;   // dest tile
              mma_acc_d     = idx_rs1;  // src acc
              mma_m_d       = '0;
              mma_n_d       = '0;
              mma_M_d       = 4'(dim_of(aicfg_i[3:0], TileM));
              mma_N_d       = 4'(dim_of(aicfg_i[7:4], TileN));
              rq_pack_d     = registers_i[1][31:0];
              mma_hart_d    = hartid_i;
              mma_id_d      = id_i;
              mma_rd_d      = rd_i;
              mma_op_d      = opcode_i;
              state_d       = ST_RQ;
            end
            AI_ACT_RELU: begin
              // dest=rd tile, src=rs1 tile
              mma_ta_d      = idx_rd;
              mma_tb_d      = idx_rs1;
              mma_m_d       = '0;
              mma_n_d       = '0;
              mma_M_d       = 4'(dim_of(aicfg_i[3:0], TileM));
              mma_N_d       = 4'(dim_of(aicfg_i[7:4], TileN));
              mma_hart_d    = hartid_i;
              mma_id_d      = id_i;
              mma_rd_d      = rd_i;
              mma_op_d      = opcode_i;
              state_d       = ST_RELU;
            end
            AI_ACT_GELU: begin
              // P1: identity copy (approximation TBD); still multi-cycle for shape
              mma_ta_d      = idx_rd;
              mma_tb_d      = idx_rs1;
              mma_m_d       = '0;
              mma_n_d       = '0;
              mma_M_d       = 4'(dim_of(aicfg_i[3:0], TileM));
              mma_N_d       = 4'(dim_of(aicfg_i[7:4], TileN));
              mma_hart_d    = hartid_i;
              mma_id_d      = id_i;
              mma_rd_d      = rd_i;
              mma_op_d      = opcode_i;
              state_d       = ST_RELU;  // gelu path distinguished by mma_op_q
            end
            AI_ENQ: begin
              // Return ticket or all-ones if queue disabled. Sideband kick
              // carries rs1 as optional desc ptr (0 ⇒ use MMIO-latched desc).
              // The kick is held VALID until the island accepts it; the ticket
              // is returned only on acceptance (legacy islands accept at once).
              if (ai_q_en_i) begin
                sb_enq_n       = 1'b1;
                sb_qid_n       = ai_qid_i;
                sb_ticket_n    = ticket_q;
                sb_desc_ptr_n  = registers_i[0];
                mma_hart_d     = hartid_i;
                mma_id_d       = id_i;
                mma_rd_d       = rd_i;
                state_d        = ST_ENQ;
              end else begin
                result_n = XLEN'(ENQ_FULL);
                we_n     = 1'b1;
                valid_n  = 1'b1;
                pmu_t0_n = 1'b1;
              end
            end
            AI_POLL: begin
              // Status from poll_status wires (see above). Always complete T0.
              result_n = XLEN'(poll_status);
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_QFENCE: begin
              // Release/acquire ordering fence for prior enqueues — T0 no-op
              // until the P3 engine owns memory ordering.
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_EXPSEL: begin
              result_n = '0;
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            default: begin
              valid_n = 1'b0;
            end
          endcase
        end
      end

      ST_MMA: begin
        // Phase 2 captures the lane sum. Phase 3 adds the accumulator.
        // Phase 4 writes mac_wide_q and advances (m,n).
        if (mma_ph_q == 3'd4) begin
          if (mma_elem_ok) begin
            unique case (mma_accmode_q)
              2'b00: mac_new = mac_sum_q;
              2'b10: mac_new = mac_sat_hi ? 32'sh7fff_ffff
                              : mac_sat_lo ? 32'sh8000_0000
                              : mac_wide_q[31:0];
              default: mac_new = mac_wide_q[31:0];
            endcase
            acc_w_req  = 1'b1;
            acc_w_acc  = AccAddrW'(mma_acc_q);
            acc_w_data = acc_wdata_elem(int'(mac_c_q), mac_new);
            acc_w_be   = acc_be_elem(int'(mac_c_q));
          end
          if (mma_n_q + 4'd1 < mma_N_q) begin
            mma_n_d = mma_n_q + 4'd1;
          end else begin
            mma_n_d = '0;
            if (mma_m_q + 4'd1 < mma_M_q) begin
              mma_m_d = mma_m_q + 4'd1;
            end else begin
              state_d = ST_DONE;
            end
          end
        end
      end

      ST_RQ: begin
        // Phase 0 registers the index, phase 1 the extended accumulator,
        // phase 2 the product. Indices stay put until the round step.
        state_d = (rq_ph_q == 2'd2) ? ST_RQ_S : ST_RQ;
      end

      ST_RQ_S: begin
        // Magnitude and round shift captured in rq_shift_ff.
        state_d = ST_RQ_R;
      end

      ST_RQ_R: begin
        // y = clamp_s8(RHE(acc * scale, shift) + zp) on the round step.
        if (rq_ok) tiles_d[mma_ta_q][rq_c_idx] = rq_byte;
        if (mma_n_q + 4'd1 < mma_N_q) begin
          mma_n_d = mma_n_q + 4'd1;
          state_d = ST_RQ;
        end else begin
          mma_n_d = '0;
          if (mma_m_q + 4'd1 < mma_M_q) begin
            mma_m_d = mma_m_q + 4'd1;
            state_d = ST_RQ;
          end else state_d = ST_DONE;
        end
      end

      ST_RELU: begin
        if (relu_ok) tiles_d[relu_ta][relu_c_idx] = relu_byte;
        if (mma_n_q + 4'd1 < mma_N_q) begin
          mma_n_d = mma_n_q + 4'd1;
        end else begin
          mma_n_d = '0;
          if (mma_m_q + 4'd1 < mma_M_q) mma_m_d = mma_m_q + 4'd1;
          else state_d = ST_DONE;
        end
      end

      ST_ENQ: begin
        sb_enq_n = 1'b1;
        if (sb_enq_ready_i) begin
          sb_enq_n = 1'b0;
          hartid_n = mma_hart_q;
          id_n     = mma_id_q;
          rd_n     = mma_rd_q;
          // Attached island: its stream is the ticket; the local counter follows
          // it so a later detach/poll_local keeps counting from the same point.
          result_n = XLEN'(isl_attached_i ? sb_enq_ticket_i : sb_ticket_q);
          ticket_d = (isl_attached_i ? sb_enq_ticket_i : sb_ticket_q) + 32'd1;
          we_n     = 1'b1;
          valid_n  = 1'b1;
          pmu_t0_n = 1'b1;
          state_d  = ST_IDLE;
        end
      end

      ST_DONE: begin
        // Complete with no GPR writeback
        hartid_n = mma_hart_q;
        id_n     = mma_id_q;
        rd_n     = mma_rd_q;
        we_n     = 1'b0;
        valid_n  = 1'b1;
        dirty_n  = 1'b1;
        if (mma_op_q inside {AI_MMA_S8, AI_MMA_U8, AI_MMA_SU8, AI_MMA_US8})
          pmu_mma_n = 1'b1;
        else if (mma_op_q inside {AI_REQUANT, AI_REQUANT_T, AI_ACT_RELU, AI_ACT_GELU})
          pmu_post_n = 1'b1;
        state_d  = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase
  end

  // ------------------------------------------------------------------ regs
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_q       <= '0;
      hartid_q       <= '0;
      id_q           <= '0;
      valid_q        <= 1'b0;
      rd_q           <= '0;
      we_q           <= 1'b0;
      setcfg_we_q    <= 1'b0;
      setcfg_wdata_q <= '0;
      dirty_q        <= 1'b0;
      pmu_mma_q      <= 1'b0;
      pmu_post_q     <= 1'b0;
      pmu_t0_q       <= 1'b0;
      ticket_q       <= '0;
      sb_enq_q       <= 1'b0;
      sb_qid_q       <= '0;
      sb_ticket_q    <= '0;
      sb_desc_ptr_q  <= '0;
      state_q        <= ST_IDLE;
      mma_acc_q      <= '0;
      mma_ta_q       <= '0;
      mma_tb_q       <= '0;
      mma_m_q        <= '0;
      mma_n_q        <= '0;
      mma_M_q        <= '0;
      mma_N_q        <= '0;
      mma_K_q        <= '0;
      mma_dtype_q    <= '0;
      mma_accmode_q  <= '0;
      mma_hart_q     <= '0;
      mma_id_q       <= '0;
      mma_rd_q       <= '0;
      mma_op_q       <= AI_ILLEGAL;
      rq_pack_q      <= '0;
      for (int unsigned t = 0; t < TileCount; t++)
        for (int unsigned e = 0; e < TileElems; e++) tiles_q[t][e] <= '0;
      // Accumulators reset via tc_sram SimInit="zeros"
    end else begin
      result_q       <= result_n;
      hartid_q       <= hartid_n;
      id_q           <= id_n;
      valid_q        <= valid_n;
      rd_q           <= rd_n;
      we_q           <= we_n;
      setcfg_we_q    <= setcfg_we_n;
      setcfg_wdata_q <= setcfg_wdata_n;
      dirty_q        <= dirty_n;
      pmu_mma_q      <= pmu_mma_n;
      pmu_post_q     <= pmu_post_n;
      pmu_t0_q       <= pmu_t0_n;
      ticket_q       <= ticket_d;
      sb_enq_q       <= sb_enq_n;
      sb_qid_q       <= sb_qid_n;
      sb_ticket_q    <= sb_ticket_n;
      sb_desc_ptr_q  <= sb_desc_ptr_n;
      state_q        <= state_d;
      mma_acc_q      <= mma_acc_d;
      mma_ta_q       <= mma_ta_d;
      mma_tb_q       <= mma_tb_d;
      mma_m_q        <= mma_m_d;
      mma_n_q        <= mma_n_d;
      mma_M_q        <= mma_M_d;
      mma_N_q        <= mma_N_d;
      mma_K_q        <= mma_K_d;
      mma_dtype_q    <= mma_dtype_d;
      mma_accmode_q  <= mma_accmode_d;
      mma_hart_q     <= mma_hart_d;
      mma_id_q       <= mma_id_d;
      mma_rd_q       <= mma_rd_d;
      mma_op_q       <= mma_op_d;
      rq_pack_q      <= rq_pack_d;
      for (int unsigned t = 0; t < TileCount; t++)
        for (int unsigned e = 0; e < TileElems; e++) tiles_q[t][e] <= tiles_d[t][e];
    end
  end

  // verilator lint_off UNUSEDSIGNAL
  logic [1:0] ais_unused;
  assign ais_unused = ais_i;
  // verilator lint_on UNUSEDSIGNAL

endmodule
