// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai execute stage for the CVXIF seam (option B).
//
// aicfg / ais are owned by csr_regfile; this unit reads them and writebacks
// setcfg grants + Dirty pulses over the sideband (ariane.sv wiring).
//
// Timing: single registered stage (same shape as cvxif_example/copro_alu.sv).

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
    // CSR sideband (owned by csr_regfile)
    input  logic       [XLEN-1:0] aicfg_i,
    input  logic       [     1:0] ais_i,
    output logic                  setcfg_we_o,
    output logic       [XLEN-1:0] setcfg_wdata_o,
    output logic                  dirty_o,
    // Result (registered)
    output logic       [XLEN-1:0] result_o,
    output hartid_t               hartid_o,
    output id_t                   id_o,
    output logic       [     4:0] rd_o,
    output logic                  valid_o,
    output logic                  we_o
);

  logic [31:0] ticket_q, ticket_d;

  function automatic logic [3:0] clog2_u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
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

  always_comb begin
    result_n        = '0;
    hartid_n        = hartid_i;
    id_n            = id_i;
    valid_n         = 1'b0;
    rd_n            = rd_i;
    we_n            = 1'b0;
    setcfg_we_n     = 1'b0;
    setcfg_wdata_n  = '0;
    dirty_n         = 1'b0;
    ticket_d        = ticket_q;
    dot4a_prod      = '0;
    dot4a_dot_s     = '0;
    dot4a_acc_s     = '0;

    if (valid_i) begin
      valid_n = 1'b1;
      unique case (opcode_i)
        AI_SETCFG: begin
          setcfg_wdata_n = grant_setcfg(registers_i[0]);
          setcfg_we_n    = 1'b1;
          result_n       = setcfg_wdata_n;
          we_n           = 1'b1;
          dirty_n        = 1'b1;
        end
        AI_GETCFG: begin
          result_n = aicfg_i;
          we_n     = 1'b1;
        end
        AI_RELACC: begin
          dirty_n = 1'b1;
          we_n    = 1'b0;
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
          dirty_n = 1'b1;
          we_n    = 1'b0;
        end
        AI_MVACC: begin
          result_n = '0;
          we_n     = 1'b1;
        end
        AI_MVTA: begin
          dirty_n = 1'b1;
          we_n    = 1'b0;
        end
        AI_REQUANT, AI_REQUANT_T, AI_ACT_RELU, AI_ACT_GELU: begin
          dirty_n = 1'b1;
          we_n    = 1'b0;
        end
        AI_ENQ: begin
          result_n = XLEN'(ticket_q);
          ticket_d = ticket_q + 32'd1;
          we_n     = 1'b1;
        end
        AI_POLL: begin
          result_n = XLEN'(32'd1);
          we_n     = 1'b1;
        end
        AI_QFENCE: begin
          we_n = 1'b0;
        end
        AI_EXPSEL: begin
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
      result_q        <= '0;
      hartid_q        <= '0;
      id_q            <= '0;
      valid_q         <= 1'b0;
      rd_q            <= '0;
      we_q            <= 1'b0;
      setcfg_we_q     <= 1'b0;
      setcfg_wdata_q  <= '0;
      dirty_q         <= 1'b0;
      ticket_q        <= '0;
    end else begin
      result_q        <= result_n;
      hartid_q        <= hartid_n;
      id_q            <= id_n;
      valid_q         <= valid_n;
      rd_q            <= rd_n;
      we_q            <= we_n;
      setcfg_we_q     <= setcfg_we_n;
      setcfg_wdata_q  <= setcfg_wdata_n;
      dirty_q         <= dirty_n;
      ticket_q        <= ticket_d;
    end
  end

  // ais_i used by the coprocessor issue gate (not needed inside exec)
  // verilator lint_off UNUSEDSIGNAL
  logic [1:0] ais_unused;
  assign ais_unused = ais_i;
  // verilator lint_on UNUSEDSIGNAL

endmodule
