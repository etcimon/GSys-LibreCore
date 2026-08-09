// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai CVXIF coprocessor top (seam B / option B).
// Instantiated from corev_apu/src/ariane.sv gen_COPRO_G6LC_AI.
//
// Reuses the generic instr_decoder from core/cvxif_example/ (already on the
// flist) with this package's mask/match table. Compressed interface always
// rejects (isa-encoding.md §1: no 16-bit encodings).
//
// Config gates (RequantEn / SparseEn / Queues) and ais!=Off are applied at
// issue so a refused op becomes illegal-instruction via accept=0 — the only
// precise trap path CVXIF exposes (core/cvxif_fu.sv).

module g6lc_ai_coprocessor
  import g6lc_ai_instr_pkg::*;
#(
    parameter int unsigned         NrRgprPorts         = 2,
    parameter int unsigned         XLEN                = 64,
    parameter config_pkg::ai_cfg_t AiCfg               = config_pkg::AiCfgOff,
    parameter type                 readregflags_t      = logic,
    parameter type                 writeregflags_t     = logic,
    parameter type                 id_t                = logic,
    parameter type                 hartid_t            = logic,
    parameter type                 x_compressed_req_t  = logic,
    parameter type                 x_compressed_resp_t = logic,
    parameter type                 x_issue_req_t       = logic,
    parameter type                 x_issue_resp_t      = logic,
    parameter type                 x_register_t        = logic,
    parameter type                 x_commit_t          = logic,
    parameter type                 x_result_t          = logic,
    parameter type                 cvxif_req_t         = logic,
    parameter type                 cvxif_resp_t        = logic,
    localparam type                registers_t         = logic [NrRgprPorts-1:0][XLEN-1:0]
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  cvxif_req_t  cvxif_req_i,
    output cvxif_resp_t cvxif_resp_o
);

  // ---- compressed: never accept (no 16-bit Xg6lcai encodings) ------------
  assign cvxif_resp_o.compressed_ready      = 1'b1;
  assign cvxif_resp_o.compressed_resp.accept = 1'b0;
  assign cvxif_resp_o.compressed_resp.instr  = '0;

  // ---- issue / register path ---------------------------------------------
  x_issue_req_t  issue_req;
  x_issue_resp_t issue_resp_raw, issue_resp;
  logic          issue_valid, issue_ready_raw, issue_ready;
  x_register_t   register;
  logic          register_valid;

  registers_t registers;
  opcode_t    opcode_raw, opcode;
  hartid_t    issue_hartid;
  id_t        issue_id;
  logic [4:0] issue_rd;
  logic [31:0] issue_instr;

  // Local ais mirror for the illegal gate (must match g6lc_ai_exec reset).
  // Until CSRs land (AI-X), both sides reset to Initial and this gate is open
  // after reset; when ais is forced Off by a future CSR write path it will
  // close. For P1 the exec unit is the sole owner of ais — we approximate the
  // gate as "always on while MatrixEn" by keeping accept from the table and
  // applying only the config-group gates here. Full ais Off→illegal needs the
  // CSR seam so software can write Off; tracked as AI-X.
  logic gate_ok;

  assign issue_req       = cvxif_req_i.issue_req;
  assign issue_valid     = cvxif_req_i.issue_valid;
  assign register        = cvxif_req_i.register;
  assign register_valid  = cvxif_req_i.register_valid;
  assign issue_instr     = issue_req.instr;

  instr_decoder #(
      .copro_issue_resp_t(g6lc_ai_instr_pkg::copro_issue_resp_t),
      .opcode_t          (g6lc_ai_instr_pkg::opcode_t),
      .NbInstr           (g6lc_ai_instr_pkg::NbInstr),
      .CoproInstr        (g6lc_ai_instr_pkg::CoproInstr),
      .NrRgprPorts       (NrRgprPorts),
      .hartid_t          (hartid_t),
      .id_t              (id_t),
      .x_issue_req_t     (x_issue_req_t),
      .x_issue_resp_t    (x_issue_resp_t),
      .x_register_t      (x_register_t),
      .registers_t       (registers_t)
  ) i_instr_decoder (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .issue_valid_i   (issue_valid),
      .issue_req_i     (issue_req),
      .issue_ready_o   (issue_ready_raw),
      .issue_resp_o    (issue_resp_raw),
      .register_valid_i(register_valid),
      .register_i      (register),
      .registers_o     (registers),
      .opcode_o        (opcode_raw),
      .hartid_o        (issue_hartid),
      .id_o            (issue_id),
      .rd_o            (issue_rd)
  );

  // Config-group gates (isa-encoding.md §3). MatrixEn is implied by this
  // module only being elaborated under COPRO_G6LC_AI + AiCfg.MatrixEn.
  always_comb begin
    gate_ok = 1'b1;
    if (is_requant_group(opcode_raw) && !AiCfg.RequantEn) gate_ok = 1'b0;
    if (is_sparse_group(opcode_raw)  && !AiCfg.SparseEn)  gate_ok = 1'b0;
    if (is_queue_group(opcode_raw)   && (AiCfg.Queues == 0)) gate_ok = 1'b0;
    // Seam B: native tile load/store must never accept (TileLdEn forced 0).
    if (AiCfg.TileLdEn == 1'b0) begin
      // ldt/stt are not in the table; nothing else to strip.
    end
  end

  always_comb begin
    issue_resp = issue_resp_raw;
    issue_ready = issue_ready_raw;
    opcode = opcode_raw;
    if (issue_valid && issue_resp_raw.accept && !gate_ok) begin
      // Refuse → illegal-instruction in the core.
      issue_resp.accept        = 1'b0;
      issue_resp.writeback     = '0;
      issue_resp.register_read = '0;
      issue_ready              = 1'b1;
      opcode                   = AI_ILLEGAL;
    end
  end

  assign cvxif_resp_o.issue_ready    = issue_ready;
  assign cvxif_resp_o.issue_resp     = issue_resp;
  assign cvxif_resp_o.register_ready = issue_ready;

  // Fire the exec unit when the decoder accepted and registers are ready.
  logic exec_fire;
  assign exec_fire = issue_valid && issue_ready && issue_resp.accept;

  // ---- execute -----------------------------------------------------------
  logic [XLEN-1:0] result;
  hartid_t         res_hartid;
  id_t             res_id;
  logic [4:0]      res_rd;
  logic            res_valid;
  logic            res_we;

  g6lc_ai_exec #(
      .NrRgprPorts(NrRgprPorts),
      .XLEN       (XLEN),
      .AiCfg      (AiCfg),
      .hartid_t   (hartid_t),
      .id_t       (id_t),
      .registers_t(registers_t)
  ) i_exec (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .valid_i    (exec_fire),
      .registers_i(registers),
      .opcode_i   (opcode),
      .instr_i    (issue_instr),
      .hartid_i   (issue_hartid),
      .id_i       (issue_id),
      .rd_i       (issue_rd),
      .result_o   (result),
      .hartid_o   (res_hartid),
      .id_o       (res_id),
      .rd_o       (res_rd),
      .valid_o    (res_valid),
      .we_o       (res_we)
  );

  always_comb begin
    cvxif_resp_o.result_valid  = res_valid;
    cvxif_resp_o.result.hartid = res_hartid;
    cvxif_resp_o.result.id     = res_id;
    cvxif_resp_o.result.data   = result;
    cvxif_resp_o.result.rd     = res_rd;
    cvxif_resp_o.result.we     = res_we;
  end

  // Commit kill is ignored in P1 (no long multi-cycle T1 yet that needs kill).
  // verilator lint_off UNUSEDSIGNAL
  logic commit_valid_unused;
  x_commit_t commit_unused;
  assign commit_valid_unused = cvxif_req_i.commit_valid;
  assign commit_unused       = cvxif_req_i.commit;
  logic result_ready_unused;
  assign result_ready_unused = cvxif_req_i.result_ready;
  // verilator lint_on UNUSEDSIGNAL

endmodule
