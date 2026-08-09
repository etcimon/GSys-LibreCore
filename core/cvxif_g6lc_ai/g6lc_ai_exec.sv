// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai execute stage for the CVXIF seam (option B).
//
// P1 slice (architecture/ai-matrix/README.md §8, AGENTS-todo AI-1):
//   - Fully functional T0: ai.setcfg / ai.getcfg / ai.relacc / ai.dot4*
//   - Local aicfg + aistatus.ais (CSR file wiring is AI-X, ordered after CSRs)
//   - T1 MMA / requant / queue / sparse: accepted and completed precisely as
//     stubs (no tile SRAM yet); they retire with we=0 or a defined GPR result
//     so the issue/scoreboard path is exercised without lengthening ex_stage.
//
// Timing: single registered stage (same shape as cvxif_example/copro_alu.sv).
// T1 multi-cycle MAC trees land later behind this interface; do not grow
// combinational cones into the core pipeline from here.

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
    // Fire one op when valid_i (registers already captured by issue decoder)
    input  logic                  valid_i,
    input  registers_t            registers_i,
    input  opcode_t               opcode_i,
    input  logic       [31:0]     instr_i,
    input  hartid_t               hartid_i,
    input  id_t                   id_i,
    input  logic       [     4:0] rd_i,
    // Result (registered)
    output logic       [XLEN-1:0] result_o,
    output hartid_t               hartid_o,
    output id_t                   id_o,
    output logic       [     4:0] rd_o,
    output logic                  valid_o,
    output logic                  we_o
);

  // ------------------------------------------------------------------ state
  // Local extension state until csr_regfile gains aicfg/aistatus (AI-X).
  // Reset ais=Initial when the plane is present (parallel to FS when F is present).
  logic [XLEN-1:0] aicfg_q, aicfg_d;
  logic [1:0]      ais_q, ais_d;       // aistatus[7:6]
  logic            acc_dirty_q, acc_dirty_d;
  logic [31:0]     ticket_q, ticket_d; // T2 stub ticket counter

  // Default granted geometry from the package (log2 of Tile*)
  function automatic logic [3:0] clog2_u(input int unsigned v);
    // $clog2(1)=0, $clog2(8)=3 — matches isa-encoding M/N/K as log2 tile dims.
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction

  function automatic logic [XLEN-1:0] default_aicfg();
    logic [XLEN-1:0] g;
    g = '0;
    g[3:0]   = clog2_u(AiCfg.TileM);
    g[7:4]   = clog2_u(AiCfg.TileN);
    g[11:8]  = clog2_u(AiCfg.TileK);
    g[13:12] = 2'b00;  // s8×s8
    g[15:14] = 2'b01;  // accumulate
    g[19:16] = AiContractVersion;
    g[21:20] = 2'b00;  // 8-bit (Int4En may upgrade on setcfg)
    g[22]    = 1'b0;
    return g;
  endfunction

  // vsetvli-shaped grant: clamp request to what this part supports.
  function automatic logic [XLEN-1:0] grant_setcfg(input logic [XLEN-1:0] req);
    logic [XLEN-1:0] g;
    logic [3:0] m_req, n_req, k_req, m_max, n_max, k_max;
    g = '0;
    m_max = clog2_u(AiCfg.TileM);
    n_max = clog2_u(AiCfg.TileN);
    k_max = clog2_u(AiCfg.TileK);
    m_req = req[3:0];
    n_req = req[7:4];
    k_req = req[11:8];
    // Grant min(request, hardware max) — never trap (isa-encoding.md §3.1).
    g[3:0]   = (m_req > m_max) ? m_max : m_req;
    g[7:4]   = (n_req > n_max) ? n_max : n_req;
    g[11:8]  = (k_req > k_max) ? k_max : k_req;
    g[13:12] = req[13:12];
    g[15:14] = (req[15:14] == 2'b11) ? 2'b01 : req[15:14];
    g[19:16] = AiContractVersion;  // read-only on grant
    // INT4 / sparse: downgrade to 0 if the part does not implement them.
    g[21:20] = (AiCfg.Int4En && req[21:20] == 2'b01) ? 2'b01 : 2'b00;
    g[22]    = AiCfg.Sparse24En ? req[22] : 1'b0;
    return g;
  endfunction

  // Four-lane s8 or u8 dot product → s32, then sign/zero-extend to XLEN.
  function automatic logic [XLEN-1:0] dot4_s8(
      input logic [XLEN-1:0] a,
      input logic [XLEN-1:0] b
  );
    logic signed [31:0] acc;
    logic signed [7:0]  aa, bb;
    acc = 32'sd0;
    for (int i = 0; i < 4; i++) begin
      aa  = signed'(a[i*8 +: 8]);
      bb  = signed'(b[i*8 +: 8]);
      acc = acc + 32'(aa * bb);
    end
    return XLEN'(signed'(acc));
  endfunction

  function automatic logic [XLEN-1:0] dot4_u8(
      input logic [XLEN-1:0] a,
      input logic [XLEN-1:0] b
  );
    logic [31:0] acc;
    logic [7:0]  aa, bb;
    acc = 32'd0;
    for (int i = 0; i < 4; i++) begin
      aa  = a[i*8 +: 8];
      bb  = b[i*8 +: 8];
      acc = acc + 32'(aa * bb);
    end
    return XLEN'(acc);
  endfunction

  // ------------------------------------------------------------------ combo
  logic [XLEN-1:0] result_n, result_q;
  hartid_t         hartid_n, hartid_q;
  id_t             id_n, id_q;
  logic            valid_n, valid_q;
  logic [4:0]      rd_n, rd_q;
  logic            we_n, we_q;
  logic signed [31:0] dot4a_dot_s, dot4a_acc_s;
  logic [XLEN-1:0]    dot4a_prod;

  assign result_o = result_q;
  assign hartid_o = hartid_q;
  assign id_o     = id_q;
  assign valid_o  = valid_q;
  assign rd_o     = rd_q;
  assign we_o     = we_q;

  always_comb begin
    result_n    = '0;
    hartid_n    = hartid_i;
    id_n        = id_i;
    valid_n     = 1'b0;
    rd_n        = rd_i;
    we_n        = 1'b0;
    aicfg_d     = aicfg_q;
    ais_d       = ais_q;
    acc_dirty_d = acc_dirty_q;
    ticket_d    = ticket_q;
    dot4a_prod  = '0;
    dot4a_dot_s = '0;
    dot4a_acc_s = '0;

    if (valid_i) begin
      valid_n = 1'b1;
      unique case (opcode_i)
        AI_SETCFG: begin
          aicfg_d  = grant_setcfg(registers_i[0]);
          result_n = aicfg_d;
          we_n     = 1'b1;
          // setcfg writes extension state → Dirty
          ais_d    = AiDirty;
        end
        AI_GETCFG: begin
          result_n = aicfg_q;
          we_n     = 1'b1;
        end
        AI_RELACC: begin
          // Tile index in rd field of the instruction; P1: clear dirty flag.
          acc_dirty_d = 1'b0;
          we_n        = 1'b0;
          ais_d       = AiDirty;
        end
        AI_DOT4_S8: begin
          result_n = dot4_s8(registers_i[0], registers_i[1]);
          we_n     = 1'b1;
        end
        AI_DOT4_U8: begin
          result_n = dot4_u8(registers_i[0], registers_i[1]);
          we_n     = 1'b1;
        end
        AI_DOT4A_S8: begin
          // Accumulate into prior rd (rs3 when NrRgprPorts>=3, else 0).
          dot4a_prod  = dot4_s8(registers_i[0], registers_i[1]);
          dot4a_dot_s = signed'(dot4a_prod[31:0]);
          if (NrRgprPorts >= 3) begin
            dot4a_acc_s = signed'(registers_i[2][31:0]);
            result_n    = XLEN'(signed'(dot4a_dot_s + dot4a_acc_s));
          end else begin
            result_n = dot4a_prod;
          end
          we_n = 1'b1;
        end
        AI_MMA_S8, AI_MMA_U8, AI_MMA_SU8, AI_MMA_US8: begin
          // T1 stub: complete with no GPR write; tile/acc array is a later drop.
          acc_dirty_d = 1'b1;
          ais_d       = AiDirty;
          we_n        = 1'b0;
        end
        AI_MVACC: begin
          // Stub: return 0 until accumulator SRAM lands.
          result_n = '0;
          we_n     = 1'b1;
        end
        AI_MVTA: begin
          ais_d = AiDirty;
          we_n  = 1'b0;
        end
        AI_REQUANT, AI_REQUANT_T, AI_ACT_RELU, AI_ACT_GELU: begin
          ais_d = AiDirty;
          we_n  = 1'b0;
        end
        AI_ENQ: begin
          // Stub: always succeed with a ticket; full ring is P3.
          result_n = XLEN'(ticket_q);
          ticket_d = ticket_q + 32'd1;
          we_n     = 1'b1;
        end
        AI_POLL: begin
          // Stub: always complete (1).
          result_n = XLEN'(32'd1);
          we_n     = 1'b1;
        end
        AI_QFENCE: begin
          we_n = 1'b0;
        end
        AI_EXPSEL: begin
          // Stub: return 0 expert id.
          result_n = '0;
          we_n     = 1'b1;
        end
        default: begin
          valid_n = 1'b0;
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_q    <= '0;
      hartid_q    <= '0;
      id_q        <= '0;
      valid_q     <= 1'b0;
      rd_q        <= '0;
      we_q        <= 1'b0;
      aicfg_q     <= default_aicfg();
      // Plane present → Initial (software may still force Off via aistatus later).
      ais_q       <= AiInitial;
      acc_dirty_q <= 1'b0;
      ticket_q    <= '0;
    end else begin
      result_q    <= result_n;
      hartid_q    <= hartid_n;
      id_q        <= id_n;
      valid_q     <= valid_n;
      rd_q        <= rd_n;
      we_q        <= we_n;
      aicfg_q     <= aicfg_d;
      ais_q       <= ais_d;
      acc_dirty_q <= acc_dirty_d;
      ticket_q    <= ticket_d;
    end
  end

endmodule
