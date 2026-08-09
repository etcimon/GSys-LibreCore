// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai per-queue address region checker (AI-3).
//
// Each queue has a programmed [base, limit) window and R/W permission bits
// carrying the submitting context. A T2 DMA master must pass every pointer
// through this unit before issue — unchecked dereference from a mapped
// doorbell is privilege escalation (architecture/ai-matrix/isa-encoding.md §7).
//
// Timing: pure combinational check; programming is FF'd. No DMA path lengthening.

module g6lc_ai_addr_check #(
    parameter int unsigned NumQueues = 2,
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned QidWidth  = (NumQueues > 1) ? $clog2(NumQueues) : 1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    // Programming (S-mode / island BAR). Applies on prog_we_i.
    input  logic                  prog_we_i,
    input  logic [QidWidth-1:0]   prog_qid_i,
    input  logic [AddrWidth-1:0]  prog_base_i,
    input  logic [AddrWidth-1:0]  prog_limit_i,  // exclusive end
    input  logic [1:0]            prog_perm_i,   // [0]=R [1]=W
    // Check request (combinational result when check_req_i)
    input  logic                  check_req_i,
    input  logic [QidWidth-1:0]   check_qid_i,
    input  logic [AddrWidth-1:0]  check_addr_i,
    input  logic [AddrWidth-1:0]  check_len_i,   // bytes; 0 means 1-byte probe
    input  logic                  check_need_r_i,
    input  logic                  check_need_w_i,
    output logic                  check_ok_o
);

  typedef logic [AddrWidth-1:0] addr_t;

  addr_t              base_q  [NumQueues];
  addr_t              limit_q [NumQueues];
  logic [1:0]         perm_q  [NumQueues];
  logic [NumQueues-1:0] valid_q;  // programmed at least once

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned q = 0; q < NumQueues; q++) begin
        base_q[q]  <= '0;
        limit_q[q] <= '0;
        perm_q[q]  <= '0;
      end
      valid_q <= '0;
    end else if (prog_we_i && (int'(prog_qid_i) < NumQueues)) begin
      base_q[prog_qid_i]  <= prog_base_i;
      limit_q[prog_qid_i] <= prog_limit_i;
      perm_q[prog_qid_i]  <= prog_perm_i;
      valid_q[prog_qid_i] <= 1'b1;
    end
  end

  always_comb begin
    addr_t base, limit, addr, last, span;
    logic [1:0] perm;
    logic       v, in_range, perm_ok;

    base = '0; limit = '0; addr = '0; last = '0; span = '0;
    perm = '0; v = 1'b0; in_range = 1'b0; perm_ok = 1'b0;
    check_ok_o = 1'b0;

    if (check_req_i && (int'(check_qid_i) < NumQueues)) begin
      base  = base_q[check_qid_i];
      limit = limit_q[check_qid_i];
      perm  = perm_q[check_qid_i];
      v     = valid_q[check_qid_i];
      addr  = check_addr_i;
      span  = (check_len_i == '0) ? addr_t'(1) : check_len_i;
      last  = addr + span - addr_t'(1);
      in_range = v
          && (limit > base)
          && (addr >= base)
          && (last >= addr)
          && (last < limit);
      perm_ok = (!check_need_r_i || perm[0]) && (!check_need_w_i || perm[1]);
      check_ok_o = in_range && perm_ok;
    end
  end

endmodule
