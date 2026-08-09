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
    output logic                  setcfg_we_o,
    output logic       [XLEN-1:0] setcfg_wdata_o,
    output logic                  dirty_o,
    // Stall new issue while multi-cycle MMA is in flight
    output logic                  busy_o,
    // PMU pulses (1-cycle, group 4 — see ariane_pkg MHPMGrpAI)
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

  function automatic logic [XLEN-1:0] dot4_s8(
      input logic [XLEN-1:0] a, input logic [XLEN-1:0] b
  );
    logic signed [31:0] acc;
    logic signed [7:0] aa, bb;
    acc = 32'sd0;
    for (int i = 0; i < 4; i++) begin
      aa  = signed'(a[i*8 +: 8]);
      bb  = signed'(b[i*8 +: 8]);
      acc = acc + 32'(aa * bb);
    end
    return XLEN'(signed'(acc));
  endfunction

  function automatic logic [XLEN-1:0] dot4_u8(
      input logic [XLEN-1:0] a, input logic [XLEN-1:0] b
  );
    logic [31:0] acc;
    logic [7:0] aa, bb;
    acc = 32'd0;
    for (int i = 0; i < 4; i++) begin
      aa  = a[i*8 +: 8];
      bb  = b[i*8 +: 8];
      acc = acc + 32'(aa * bb);
    end
    return XLEN'(acc);
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
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .r_req_i (acc_r_req),
      .r_acc_i (acc_r_acc),
      .r_data_o(acc_r_data),
      .w_req_i (acc_w_req),
      .w_acc_i (acc_w_acc),
      .w_data_i(acc_w_data),
      .w_be_i  (acc_w_be)
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
    ST_RQ    = 3'd3,  // requant s32→s8
    ST_RELU  = 3'd4
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

  // Classify completing ops for PMU (latched with valid_q)
  logic pmu_mma_n, pmu_mma_q, pmu_post_n, pmu_post_q, pmu_t0_n, pmu_t0_q;
  assign pmu_op_o   = valid_q;
  assign pmu_mma_o  = valid_q && pmu_mma_q;
  assign pmu_post_o = valid_q && pmu_post_q;
  assign pmu_t0_o   = valid_q && pmu_t0_q;

  // ------------------------------------------------------------------ combo
  always_comb begin
    logic signed [31:0] mac_sum, mac_old, mac_new;
    logic signed [7:0]  mac_av, mac_bv;
    logic [7:0]         mac_au, mac_bu;
    logic signed [32:0] mac_wide;
    int unsigned        mac_a_elem, mac_b_elem, mac_c_elem;
    // defaults: hold tiles; no acc write
    for (int unsigned t = 0; t < TileCount; t++)
      for (int unsigned e = 0; e < TileElems; e++) tiles_d[t][e] = tiles_q[t][e];
    acc_r_req  = 1'b0;
    acc_r_acc  = '0;
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
              result_n = dot4_s8(registers_i[0], registers_i[1]);
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_DOT4_U8: begin
              result_n = dot4_u8(registers_i[0], registers_i[1]);
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_DOT4A_S8: begin
              dot4a_prod  = dot4_s8(registers_i[0], registers_i[1]);
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
                acc_r_req = 1'b1;
                acc_r_acc = AccAddrW'(idx_rs1);
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
              result_n = XLEN'(ticket_q);
              ticket_d = ticket_q + 32'd1;
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_POLL: begin
              result_n = XLEN'(32'd1);
              we_n     = 1'b1;
              valid_n  = 1'b1;
              pmu_t0_n = 1'b1;
            end
            AI_QFENCE: begin
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
        // C[m,n] = sum_k A[m,k]*B[k,n]; tiles row-major [row*TileN+col]
        mac_sum = 32'sd0;
        for (int unsigned kk = 0; kk < TileK; kk++) begin
          if (kk < int'(mma_K_q)) begin
            mac_a_elem = mma_m_q * TileN + kk;
            mac_b_elem = kk * TileN + mma_n_q;
            if (mac_a_elem < TileElems && mac_b_elem < TileElems &&
                mma_ta_q < TileCount && mma_tb_q < TileCount) begin
              unique case (mma_dtype_q)
                2'b00: begin
                  mac_av  = signed'(tiles_q[mma_ta_q][mac_a_elem]);
                  mac_bv  = signed'(tiles_q[mma_tb_q][mac_b_elem]);
                  mac_sum = mac_sum + 32'(mac_av * mac_bv);
                end
                2'b01: begin
                  mac_au  = tiles_q[mma_ta_q][mac_a_elem];
                  mac_bu  = tiles_q[mma_tb_q][mac_b_elem];
                  mac_sum = mac_sum + 32'(mac_au * mac_bu);
                end
                2'b10: begin
                  mac_av  = signed'(tiles_q[mma_ta_q][mac_a_elem]);
                  mac_bu  = tiles_q[mma_tb_q][mac_b_elem];
                  mac_sum = mac_sum + 32'(mac_av * signed'({1'b0, mac_bu}));
                end
                default: begin
                  mac_au  = tiles_q[mma_ta_q][mac_a_elem];
                  mac_bv  = signed'(tiles_q[mma_tb_q][mac_b_elem]);
                  mac_sum = mac_sum + 32'(signed'({1'b0, mac_au}) * mac_bv);
                end
              endcase
            end
          end
        end
        mac_c_elem = mma_m_q * TileN + mma_n_q;
        if (mma_acc_q < AccCount && mac_c_elem < AccElems) begin
          acc_r_req = 1'b1;
          acc_r_acc = AccAddrW'(mma_acc_q);
          mac_old   = acc_get(acc_r_data, mac_c_elem);
          unique case (mma_accmode_q)
            2'b00: mac_new = mac_sum;
            2'b10: begin
              mac_wide = signed'({mac_old[31], mac_old}) + signed'({mac_sum[31], mac_sum});
              if (mac_wide > 33'sd2147483647) mac_new = 32'sh7fff_ffff;
              else if (mac_wide < -33'sd2147483648) mac_new = 32'sh8000_0000;
              else mac_new = mac_wide[31:0];
            end
            default: mac_new = mac_old + mac_sum;
          endcase
          acc_w_req  = 1'b1;
          acc_w_acc  = AccAddrW'(mma_acc_q);
          acc_w_data = acc_wdata_elem(mac_c_elem, mac_new);
          acc_w_be   = acc_be_elem(mac_c_elem);
        end
        // Advance (m,n)
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

      ST_RQ: begin
        // y = clamp_s8( RHE(acc * scale, shift) + zp )
        // pack: scale s16 [15:0], zp s8 [23:16], shift [27:24]
        begin
          logic signed [15:0] sc;
          logic signed [7:0]  zp;
          logic [3:0]         sh;
          logic signed [31:0] aval;
          logic signed [47:0] prod, adj, ux, t;
          logic [47:0]        rem, half;
          logic signed [31:0] with_zp;
          int unsigned        c_elem;
          sc  = signed'(rq_pack_q[15:0]);
          zp  = signed'(rq_pack_q[23:16]);
          sh  = rq_pack_q[27:24];
          c_elem = mma_m_q * TileN + mma_n_q;
          if (mma_acc_q < AccCount && mma_ta_q < TileCount && c_elem < AccElems &&
              c_elem < TileElems) begin
            acc_r_req = 1'b1;
            acc_r_acc = AccAddrW'(mma_acc_q);
            aval = acc_get(acc_r_data, c_elem);
            // Signed widen: s32×s16 → s48
            prod = signed'({{16{aval[31]}}, aval}) * signed'({{32{sc[15]}}, sc});
            if (sh == 4'd0) begin
              adj = prod;
            end else begin
              ux   = prod[47] ? -prod : prod;
              half = 48'b1 << (sh - 4'd1);
              rem  = ux & ((48'b1 << sh) - 48'b1);
              t    = ux >> sh;
              if (rem > half || (rem == half && t[0])) t = t + 48'b1;
              adj  = prod[47] ? -t : t;
            end
            with_zp = adj[31:0] + 32'(zp);
            if (with_zp > 32'sd127) with_zp = 32'sd127;
            else if (with_zp < -32'sd128) with_zp = -32'sd128;
            tiles_d[mma_ta_q][c_elem] = with_zp[7:0];
          end
        end
        if (mma_n_q + 4'd1 < mma_N_q) begin
          mma_n_d = mma_n_q + 4'd1;
        end else begin
          mma_n_d = '0;
          if (mma_m_q + 4'd1 < mma_M_q) mma_m_d = mma_m_q + 4'd1;
          else state_d = ST_DONE;
        end
      end

      ST_RELU: begin
        begin
          int unsigned c_elem;
          logic signed [7:0] v;
          c_elem = mma_m_q * TileN + mma_n_q;
          if (mma_ta_q < TileCount && mma_tb_q < TileCount && c_elem < TileElems) begin
            v = signed'(tiles_q[mma_tb_q][c_elem]);
            if (mma_op_q == AI_ACT_RELU) begin
              tiles_d[mma_ta_q][c_elem] = (v < 0) ? 8'sd0 : v;
            end else begin
              // GELU stub: copy
              tiles_d[mma_ta_q][c_elem] = v;
            end
          end
        end
        if (mma_n_q + 4'd1 < mma_N_q) begin
          mma_n_d = mma_n_q + 4'd1;
        end else begin
          mma_n_d = '0;
          if (mma_m_q + 4'd1 < mma_M_q) mma_m_d = mma_m_q + 4'd1;
          else state_d = ST_DONE;
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
