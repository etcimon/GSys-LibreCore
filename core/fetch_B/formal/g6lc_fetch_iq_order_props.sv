// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: I6 clause 1 (program-order issue) against the live IQ
// (`core/fetch_B/instr_queue.sv`).
//
// I6 (firmware-boot-principles.md sB): "IQ order is program order. Head
// selection must not depend on opcode, `rd`, or FU." The existing
// `g6lc_fetch_iq.sby` checks the separate non-interference contract.
// This contract watches an arbitrary accepted entry and counts its position
// independently of DUT timestamps, FIFO addresses or selected heads.
//
// The default geometry is FETCH_WIDTH=64, RVC, 2 harts, 2 issue ports.
// XLEN/VLEN are reduced to 32; addresses and payloads remain arbitrary.
// Occupancy and circular placement are checked against independent counters.
// Exceptions use the non-hypervisor envelope; guest exception translation
// and frontend transaction association remain separate obligations.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_iq_order.sby
//      cva6-build verify --formal

module g6lc_fetch_iq_order_props #(
    parameter int unsigned FW = 64,  // FETCH_WIDTH bits
    parameter int unsigned AB = 3,   // FETCH_ALIGN_BITS
    parameter int unsigned NH = 2,   // NrHarts
    parameter int unsigned NI = 2    // NrIssuePorts
) (
    input logic clk_i,
    input logic flush_i, leftover_complete_i, exception_gva_i,
    input logic [(NH > 1 ? $clog2(NH) : 1)-1:0] hart_i,
    input logic [FW/16-1:0][31:0] addr_i,
    input logic [FW/16-1:0] valid_i,
    input ariane_pkg::frontend_exception_t exception_i,
    input logic [31:0] exception_addr_i, predict_address_i,
    input logic [31:0] exception_gpaddr_i, exception_tinst_i,
    input ariane_pkg::cf_t [FW/16-1:0] cf_type_i,
    input logic [NI-1:0] fetch_entry_ready_i,
    input logic [FW/16-1:0][31:0] instr_i,
    input logic watch_i,
    input logic [$clog2(FW/16)-1:0] watch_slot_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  localparam int unsigned VLEN = 32;
  localparam int unsigned XLEN = 32;
  localparam int unsigned GPLEN = 32;
  localparam int unsigned SLOTS = FW / 16;
  localparam int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1;
  localparam int unsigned SLOTW = $clog2(SLOTS);

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c = config_pkg::cva6_cfg_empty;
    c.XLEN = XLEN;
    c.VLEN = VLEN;
    c.GPLEN = GPLEN;
    c.FETCH_WIDTH = FW;
    c.FETCH_ALIGN_BITS = AB;
    c.INSTR_PER_FETCH = SLOTS;
    c.LOG2_INSTR_PER_FETCH = SLOTW;
    c.RVC = 1'b1;
    c.NrHarts = NH;
    c.NrIssuePorts = NI;
    c.TvalEn = 1'b1;
    c.FtqDepth = 0;  // smt2 ships FtqDepth=0
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // Layout-identical to the localparam types in `core/cva6.sv`; the queue only
  // stores and forwards these, so a structural copy is faithful here.
  typedef struct packed {
    cf_t cf;
    logic [VLEN-1:0] predict_address;
  } bp_sbe_t;

  typedef struct packed {
    logic [XLEN-1:0] cause;
    logic [XLEN-1:0] tval;
    logic [GPLEN-1:0] tval2;
    logic [31:0] tinst;
    logic gva;
    logic valid;
  } exc_t;

  typedef struct packed {
    logic [VLEN-1:0] address;
    logic [31:0] instruction;
    bp_sbe_t branch_predict;
    exc_t ex;
    logic [HARTW-1:0] hart_id;
  } fe_t;

  // --- stimulus -------------------------------------------------------------
  localparam int unsigned CAPACITY = SLOTS * 8;
  localparam int unsigned COUNT_W = $clog2(CAPACITY + 1);
  logic [COUNT_W-1:0] ref_count_q, watch_pos_q;
  logic [SLOTW-1:0] ref_head_q;
  logic watching_q;
  logic [31:0] watch_pc_q, watch_instr_q, watch_tval_q, watch_target_q;
  logic [HARTW-1:0] watch_hart_q;
  frontend_exception_t watch_exception_q;
  cf_t watch_cf_q;
  int unsigned push_count, pop_count, watch_rank;

  // --- observed outputs -----------------------------------------------------
  logic ready_o, replay_o;
  logic [SLOTS-1:0] consumed_o;
  logic [VLEN-1:0] replay_addr_o;
  fe_t [NI-1:0] fetch_entry_o;
  logic [NI-1:0] fetch_entry_valid_o;

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  instr_queue #(.CVA6Cfg(Cfg), .fetch_entry_t(fe_t)) dut (
      .clk_i, .rst_ni, .flush_i, .hart_i,
      .instr_i, .addr_i, .valid_i, .leftover_complete_i,
      .ready_o, .consumed_o,
      .exception_i, .exception_addr_i, .exception_gpaddr_i,
      .exception_tinst_i, .exception_gva_i, .predict_address_i, .cf_type_i,
      .replay_o, .replay_addr_o,
      .fetch_entry_o, .fetch_entry_valid_o, .fetch_entry_ready_i
  );

  always_comb begin
    logic prefix;
    push_count = 0;
    pop_count = 0;
    watch_rank = 0;
    prefix = 1'b1;
    for (int unsigned p = 0; p < NI; p++) begin
      prefix &= fetch_entry_valid_o[p] && fetch_entry_ready_i[p];
      if (prefix) pop_count++;
    end
    for (int unsigned s = 0; s < SLOTS; s++) begin
      if (consumed_o[s]) begin
        push_count++;
        if (s < int'(watch_slot_i)) watch_rank++;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      ref_count_q <= '0;
      ref_head_q <= '0;
      watching_q <= 1'b0;
      watch_pos_q <= '0;
      watch_pc_q <= '0;
      watch_instr_q <= '0;
      watch_hart_q <= '0;
      watch_tval_q <= '0;
      watch_target_q <= '0;
      watch_exception_q <= FE_NONE;
      watch_cf_q <= NoCF;
    end else begin
      ref_count_q <= COUNT_W'(int'(ref_count_q) + push_count - pop_count);
      ref_head_q <= SLOTW'(int'(ref_head_q) + pop_count);
      if (watching_q) begin
        if (pop_count > int'(watch_pos_q)) watching_q <= 1'b0;
        else watch_pos_q <= COUNT_W'(int'(watch_pos_q) - pop_count);
      end else if (watch_i && consumed_o[watch_slot_i]) begin
        watching_q <= 1'b1;
        watch_pos_q <= COUNT_W'(int'(ref_count_q) - pop_count + watch_rank);
        watch_pc_q <= addr_i[watch_slot_i];
        watch_instr_q <= instr_i[watch_slot_i];
        watch_hart_q <= hart_i;
        watch_tval_q <= exception_addr_i;
        watch_target_q <= predict_address_i;
        watch_exception_q <= exception_i;
        watch_cf_q <= cf_type_i[watch_slot_i];
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      assert ((consumed_o & ~valid_i) == '0);
      assert (pop_count <= int'(ref_count_q));
      assert (int'(ref_count_q) + push_count - pop_count <= CAPACITY);
      assert (fetch_entry_valid_o[0] == (ref_count_q != 0));
      if (watching_q) begin
        assert (watch_pos_q < ref_count_q);
        for (int unsigned p = 0; p < NI; p++) begin
          if (watch_pos_q == COUNT_W'(p) && fetch_entry_valid_o[p]) begin
            assert (fetch_entry_o[p].address == watch_pc_q);
            assert (fetch_entry_o[p].instruction == watch_instr_q);
            assert (fetch_entry_o[p].hart_id == watch_hart_q);
            assert (fetch_entry_o[p].branch_predict.cf == watch_cf_q);
            if (watch_cf_q != NoCF)
              assert (fetch_entry_o[p].branch_predict.predict_address == watch_target_q);
            assert (fetch_entry_o[p].ex.valid == (watch_exception_q != FE_NONE));
            if (watch_exception_q != FE_NONE) begin
              assert (fetch_entry_o[p].ex.tval == watch_tval_q);
              assert (fetch_entry_o[p].ex.cause ==
                  (watch_exception_q == FE_INSTR_ACCESS_FAULT ? riscv::INSTR_ACCESS_FAULT : riscv::INSTR_PAGE_FAULT));
            end
          end
        end
      end
      cover (watching_q && watch_pos_q == 0 && pop_count != 0);
      cover (watching_q && watch_hart_q == HARTW'(1) && pop_count > int'(watch_pos_q));
      cover (push_count != 0 && !valid_i[0]);
      cover (pop_count > 1);
    end
  end

  // --- environment: packet slots may be sparse and PCs may move backwards.
  // Only legal hart identifiers and control-flow metadata enums are assumed.
  logic env_cf_valid;

  always_comb begin
    env_cf_valid = 1'b1;
    for (int unsigned i = 0; i < SLOTS; i++) begin
      env_cf_valid &= ((cf_type_i[i] == NoCF) || (cf_type_i[i] == Branch) ||
                      (cf_type_i[i] == Jump) || (cf_type_i[i] == JumpR) ||
                      (cf_type_i[i] == Return));
    end
  end

  // Environment assumes live in the always_ff block below (same encoding as
  // the asserts, so abc-bmc3 cannot discharge them on an unclocked frame).

  // --- helper: independent logical stream position determines bank occupancy ---
  int unsigned bank_count[SLOTS];
  always_comb begin
    for (int unsigned f = 0; f < SLOTS; f++) begin
      bank_count[f] = (int'(ref_count_q) + SLOTS - 1 -
          ((f + SLOTS - int'(ref_head_q)) % SLOTS)) / SLOTS;
    end
  end

  localparam int unsigned TARGET_DEPTH = ariane_pkg::FETCH_ADDR_FIFO_DEPTH;
  localparam int unsigned TARGET_PTR_W = $clog2(TARGET_DEPTH);
  logic [SLOTS-1:0][2:0] fifo_read_ptr;
  cf_t [SLOTS-1:0][7:0] stored_cf;
  logic [COUNT_W-1:0] target_count, targets_before_watch;
  logic [SLOTW-1:0] watch_bank;
  logic [TARGET_PTR_W-1:0] target_watch_index;

  assign watch_bank = SLOTW'(int'(ref_head_q) + int'(watch_pos_q));
  assign target_watch_index = TARGET_PTR_W'(
      int'(dut.i_fifo_address.read_pointer_q) + targets_before_watch);

  for (genvar f = 0; f < SLOTS; f++) begin : gen_storage_lemmas
    logic [2:0] watched_index;
    assign fifo_read_ptr[f] = dut.gen_instr_fifo[f].i_fifo_instr_data.read_pointer_q;
    assign watched_index = 3'(int'(fifo_read_ptr[f]) + int'(watch_pos_q) / SLOTS);
    for (genvar j = 0; j < 8; j++) begin : gen_cf_alias
      assign stored_cf[f][j] = dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[j].cf;
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        assert (dut.gen_instr_fifo[f].i_fifo_instr_data.status_cnt_q == 4'(bank_count[f]));
        assert (dut.gen_instr_fifo[f].i_fifo_instr_data.write_pointer_q ==
            3'(int'(fifo_read_ptr[f]) + bank_count[f]));
        if (!flush_i && watching_q && watch_bank == SLOTW'(f)) begin
          assert (int'(watch_pos_q) / SLOTS < bank_count[f]);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].pc == watch_pc_q);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].instr == watch_instr_q);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].hart == watch_hart_q);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].cf == watch_cf_q);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].ex == watch_exception_q);
          assert (dut.gen_instr_fifo[f].i_fifo_instr_data.mem_q[watched_index].ex_vaddr == watch_tval_q);
        end
      end
    end
  end

  always_comb begin
    target_count = 0;
    targets_before_watch = 0;
    for (int unsigned f = 0; f < SLOTS; f++) begin
      for (int unsigned j = 0; j < 8; j++) begin
        if (stored_cf[f][3'(int'(fifo_read_ptr[f]) + j)] != NoCF) begin
          if (j < bank_count[f]) target_count++;
          if (watching_q && j < (int'(watch_pos_q) + SLOTS - 1 -
              ((f + SLOTS - int'(ref_head_q)) % SLOTS)) / SLOTS)
            targets_before_watch++;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (target_count <= TARGET_DEPTH);
      assert (int'(dut.i_fifo_address.status_cnt_q) == target_count);
      assert (dut.i_fifo_address.write_pointer_q == TARGET_PTR_W'(
          int'(dut.i_fifo_address.read_pointer_q) + target_count));
      if (!flush_i && watching_q && watch_cf_q != NoCF) begin
        assert (targets_before_watch < target_count);
        assert (targets_before_watch <= int'(watch_pos_q));
        assert (dut.i_fifo_address.mem_q[target_watch_index] == watch_target_q);
      end
    end
  end

  // --- temporal: coverage remembers full occupancy and flush of live work ---
  logic seen_full_q, seen_flush_q, seen_full_no_flush_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      seen_full_q <= 1'b0;
      seen_flush_q <= 1'b0;
      seen_full_no_flush_q <= 1'b0;
    end else begin
      if (flush_i) seen_full_no_flush_q <= 1'b0;
      else if (ref_count_q == CAPACITY) seen_full_no_flush_q <= 1'b1;
      if (ref_count_q == CAPACITY) seen_full_q <= 1'b1;
      if (flush_i && ref_count_q != 0) seen_flush_q <= 1'b1;
    end
  end

  // --- I6 clause 1: physical placement follows independently counted acceptance ---
  // Payload identity is checked above, separately from the bank occupancy relation.
  // Neither a DUT timestamp nor an assumption on DUT queue contents supplies
  // the expected instruction, PC, hart, exception or prediction value.

  // FIFO data-order is checked through the live `cva6_fifo_v3` instances.
  // Their insertion/removal arithmetic is related to the logical stream by
  // bank_count; arbitrary accepted payloads must emerge at their watched rank.
  // All occupancy and pointer relations below are assertions, not assumptions.
  // No prefix-valid input, numerical PC order or sequence-range bound is assumed.
  //
  // Immediate asserts inside always_ff, not concurrent SVA: abc-bmc3's AIGER
  // path treats clk_i as $anyseq and checks sampled properties on unclocked
  // frames (the historical FAIL at step 4 with PI_clk_i held 0).

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (int'(hart_i) < NH);
      assume (env_cf_valid);
      assert (ref_count_q <= CAPACITY);
      assert (dut.idx_ds_q == (SLOTS'(1) << ref_head_q));
      assert (dut.idx_is_q == SLOTW'(int'(ref_head_q) + int'(ref_count_q)));
      for (int unsigned f = 0; f < SLOTS; f++) begin
        assert (bank_count[f] <= 8);
        assert (dut.instr_queue_empty[f] == (bank_count[f] == 0));
        assert (dut.instr_queue_full[f] == (bank_count[f] == 8));
        assert (dut.instr_queue_usage[f] == 3'(bank_count[f]));
      end
      if (!flush_i) begin
        for (int unsigned p = 0; p < NI; p++) begin
          if (fetch_entry_valid_o[p]) begin
            assert (int'(ref_count_q) > p);
            assert (dut.idx_ds[p] == (SLOTS'(1) << ((int'(ref_head_q) + p) % SLOTS)));
          end
        end
      end
      cover (ref_count_q == CAPACITY);
      cover (seen_full_q && ref_count_q == 0);
      cover (!flush_i && seen_full_no_flush_q && ref_count_q == 0);
      cover (!flush_i && dut.full_address);
      cover (seen_flush_q && watching_q && pop_count > int'(watch_pos_q));
      cover (!flush_i && leftover_complete_i && replay_o && consumed_o == SLOTS'(1));
      cover (!flush_i && watching_q && watch_exception_q != FE_NONE && pop_count > int'(watch_pos_q));
      cover (!flush_i && watching_q && watch_cf_q != NoCF && pop_count > int'(watch_pos_q));
    end
  end
`endif

endmodule
