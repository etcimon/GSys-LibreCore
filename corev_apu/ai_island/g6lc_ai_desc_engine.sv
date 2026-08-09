// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor engine spine (P3).
//
// Accepts a software-pushed 64-byte descriptor (doorbell path) on a given
// queue, validates version/op, runs AI-3 address checks on every pointer,
// and completes with a status word. Does **not** yet perform GEMM traffic —
// that is I1 cluster work. The contract this unit freezes is: bad pointers
// never reach a DMA master.
//
// Timing: multi-cycle FSM; idle when not busy. Address check is combo and
// does not lengthen a critical path beyond one region compare.

module g6lc_ai_desc_engine
  import g6lc_ai_desc_pkg::*;
#(
    parameter int unsigned NumQueues = 2,
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned QidWidth  = (NumQueues > 1) ? $clog2(NumQueues) : 1,
    parameter int unsigned MaxPrio   = 15
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  testmode_i,
    // Global enable (island control)
    input  logic                  enable_i,
    // Submit (doorbell / ai.enq host path)
    input  logic                  submit_valid_i,
    output logic                  submit_ready_o,
    input  logic [QidWidth-1:0]   submit_qid_i,
    input  logic [31:0]           submit_ticket_i,
    input  desc_bits_t            submit_desc_i,
    // Completion
    output logic                  done_valid_o,
    output logic [31:0]           done_ticket_o,
    output logic [15:0]           done_status_o,
    output logic                  done_irq_o,
    // AI-3 address-check programming + query (shared unit)
    output logic                  prog_we_o,
    output logic [QidWidth-1:0]   prog_qid_o,
    output logic [AddrWidth-1:0]  prog_base_o,
    output logic [AddrWidth-1:0]  prog_limit_o,
    output logic [1:0]            prog_perm_o,
    // External program port (BAR) muxed over same prog_* when prog_ext_we_i
    input  logic                  prog_ext_we_i,
    input  logic [QidWidth-1:0]   prog_ext_qid_i,
    input  logic [AddrWidth-1:0]  prog_ext_base_i,
    input  logic [AddrWidth-1:0]  prog_ext_limit_i,
    input  logic [1:0]            prog_ext_perm_i,
    // Checker combo port
    output logic                  check_req_o,
    output logic [QidWidth-1:0]   check_qid_o,
    output logic [AddrWidth-1:0]  check_addr_o,
    output logic [AddrWidth-1:0]  check_len_o,
    output logic                  check_need_r_o,
    output logic                  check_need_w_o,
    input  logic                  check_ok_i,
    // Status
    output logic                  busy_o,
    output logic [15:0]           last_status_o
);

  typedef enum logic [2:0] {
    ST_IDLE       = 3'd0,
    ST_PARSE      = 3'd1,
    ST_CHK_A      = 3'd2,
    ST_CHK_B      = 3'd3,
    ST_CHK_C      = 3'd4,
    ST_CHK_SCALE  = 3'd5,
    ST_CHK_DONE   = 3'd6,
    ST_COMPLETE   = 3'd7
  } state_e;

  state_e state_q, state_d;
  desc_t  desc_q, desc_d;
  logic [QidWidth-1:0] qid_q, qid_d;
  logic [31:0] ticket_q, ticket_d;
  logic [15:0] status_q, status_d;
  logic        irq_q, irq_d;
  logic        done_valid_q, done_valid_d;
  logic [15:0] last_status_q;

  assign busy_o         = (state_q != ST_IDLE);
  assign submit_ready_o = (state_q == ST_IDLE) && enable_i;
  assign done_valid_o   = done_valid_q;
  assign done_ticket_o  = ticket_q;
  assign done_status_o  = status_q;
  assign done_irq_o     = done_valid_q && irq_q;
  assign last_status_o  = last_status_q;

  // Programming is external-only for this unit
  assign prog_we_o    = prog_ext_we_i;
  assign prog_qid_o   = prog_ext_qid_i;
  assign prog_base_o  = prog_ext_base_i;
  assign prog_limit_o = prog_ext_limit_i;
  assign prog_perm_o  = prog_ext_perm_i;

  // Default check idle
  always_comb begin
    state_d       = state_q;
    desc_d        = desc_q;
    qid_d         = qid_q;
    ticket_d      = ticket_q;
    status_d      = status_q;
    irq_d         = irq_q;
    done_valid_d  = 1'b0;

    check_req_o    = 1'b0;
    check_qid_o    = qid_q;
    check_addr_o   = '0;
    check_len_o    = AddrWidth'(8);  // pointer-sized accesses
    check_need_r_o = 1'b0;
    check_need_w_o = 1'b0;

    unique case (state_q)
      ST_IDLE: begin
        if (submit_valid_i && submit_ready_o) begin
          desc_d   = bits_to_desc(submit_desc_i);
          qid_d    = submit_qid_i;
          ticket_d = submit_ticket_i;
          status_d = ST_OK;
          irq_d    = 1'b0;
          state_d  = ST_PARSE;
        end else if (submit_valid_i && !enable_i) begin
          // Drop with disabled status if kicked while off
          desc_d   = bits_to_desc(submit_desc_i);
          qid_d    = submit_qid_i;
          ticket_d = submit_ticket_i;
          status_d = ST_DISABLED;
          irq_d    = 1'b0;
          state_d  = ST_COMPLETE;
        end
      end

      ST_PARSE: begin
        if (desc_q.version != 16'(ContractVersion)) begin
          status_d = ST_BAD_VER;
          state_d  = ST_COMPLETE;
        end else if (!(desc_q.op inside {OP_GEMM, OP_CONV2D, OP_LAYOUT, OP_PREFETCH})) begin
          status_d = ST_BAD_OP;
          state_d  = ST_COMPLETE;
        end else if (int'(qid_q) >= NumQueues) begin
          status_d = ST_BAD_QID;
          state_d  = ST_COMPLETE;
        end else begin
          // Priority is clamped by software/S-mode policy; engine accepts 0..15.
          state_d = ST_CHK_A;
        end
      end

      ST_CHK_A: begin
        check_req_o    = 1'b1;
        check_addr_o   = desc_q.ptr_a;
        check_need_r_o = 1'b1;
        if (!check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_B;
      end

      ST_CHK_B: begin
        check_req_o    = 1'b1;
        check_addr_o   = desc_q.ptr_b;
        check_need_r_o = 1'b1;
        if (!check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_C;
      end

      ST_CHK_C: begin
        check_req_o    = 1'b1;
        check_addr_o   = desc_q.ptr_c;
        check_need_w_o = 1'b1;
        if (!check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else state_d = ST_CHK_SCALE;
      end

      ST_CHK_SCALE: begin
        if (desc_q.ptr_scale == '0) begin
          state_d = ST_CHK_DONE;
        end else begin
          check_req_o    = 1'b1;
          check_addr_o   = desc_q.ptr_scale;
          check_need_r_o = 1'b1;
          if (!check_ok_i) begin
            status_d = ST_BAD_PTR;
            state_d  = ST_COMPLETE;
          end else state_d = ST_CHK_DONE;
        end
      end

      ST_CHK_DONE: begin
        // Completion word must be writable
        check_req_o    = 1'b1;
        check_addr_o   = desc_q.ptr_done;
        check_need_w_o = 1'b1;
        if (!check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else begin
          // P3 spine: accept without executing GEMM
          status_d = ST_OK;
          irq_d    = desc_irq(desc_q);
          state_d  = ST_COMPLETE;
        end
      end

      ST_COMPLETE: begin
        done_valid_d = 1'b1;
        state_d      = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase

    // testmode: hold idle for scan observability of prog path
    if (testmode_i && state_q == ST_IDLE) begin
      state_d = ST_IDLE;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= ST_IDLE;
      desc_q         <= '0;
      qid_q          <= '0;
      ticket_q       <= '0;
      status_q       <= '0;
      irq_q          <= 1'b0;
      done_valid_q   <= 1'b0;
      last_status_q  <= '0;
    end else begin
      state_q      <= state_d;
      desc_q       <= desc_d;
      qid_q        <= qid_d;
      ticket_q     <= ticket_d;
      status_q     <= status_d;
      irq_q        <= irq_d;
      done_valid_q <= done_valid_d;
      if (done_valid_d) last_status_q <= status_d;
    end
  end

endmodule
