// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// hyp8 port of core/g6lc_zicclsm.sv (89d3dadd0). Config type adapted
// cva6_cfg_t/CVA6Cfg -> g6lc_cfg_t/G6LCCfg; ariane_pkg -> g6lc_core_pkg.
//
// Zicclsm two-beat LSU splitter. Intra-word misaligned LS use the existing
// BE/shift path. Accesses that wrap the XLEN word become two sequential
// beats. AMOs / LR/SC / AMOCAS / CBO stay outside this module (they trap).
// Off-config is a wire (bit-identical).

module g6lc_zicclsm
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type lsu_ctrl_t = logic,
    parameter type exception_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  lsu_ctrl_t   ctrl_i,
    output lsu_ctrl_t   ctrl_o,
    input  logic        pop_ld_fu_i,
    input  logic        pop_st_fu_i,
    output logic        pop_ld_byp_o,
    output logic        pop_st_byp_o,
    input  logic        ld_valid_fu_i,
    input  logic [G6LCCfg.XLEN-1:0] ld_result_fu_i,
    input  exception_t  ld_ex_fu_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] ld_tid_fu_i,
    output logic        ld_valid_o,
    output logic [G6LCCfg.XLEN-1:0] ld_result_o,
    output exception_t  ld_ex_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] ld_tid_o,
    input  logic        st_valid_fu_i,
    input  logic [G6LCCfg.XLEN-1:0] st_result_fu_i,
    input  exception_t  st_ex_fu_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] st_tid_fu_i,
    output logic        st_valid_o,
    output logic [G6LCCfg.XLEN-1:0] st_result_o,
    output exception_t  st_ex_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] st_tid_o
);
  localparam int unsigned W = G6LCCfg.IS_XLEN64 ? 8 : 4;

  function automatic logic wraps(input logic [2:0] off, input logic [1:0] sz);
    unique case (sz)
      2'b00:   wraps = 1'b0;
      2'b01:   wraps = (off == 3'(W - 1));
      2'b10:   wraps = (unsigned'(off) > unsigned'(W - 4));
      default: wraps = (off != 3'b000);
    endcase
  endfunction

  function automatic logic [G6LCCfg.XLEN-1:0] finish_load(
      input fu_op op, input logic [63:0] assembled);
    unique case (op)
      LB, HLV_B:
        finish_load = {{G6LCCfg.XLEN - 8{assembled[7]}}, assembled[7:0]};
      LBU, HLV_BU:
        finish_load = {{G6LCCfg.XLEN - 8{1'b0}}, assembled[7:0]};
      LH, HLV_H:
        finish_load = {{G6LCCfg.XLEN - 16{assembled[15]}}, assembled[15:0]};
      FLH:
        finish_load = {{G6LCCfg.XLEN - 16{1'b1}}, assembled[15:0]};
      LHU, HLV_HU, HLVX_HU:
        finish_load = {{G6LCCfg.XLEN - 16{1'b0}}, assembled[15:0]};
      LW, HLV_W:
        finish_load = {{G6LCCfg.XLEN - 32{assembled[31]}}, assembled[31:0]};
      FLW:
        finish_load = {{G6LCCfg.XLEN - 32{1'b1}}, assembled[31:0]};
      LWU, HLV_WU, HLVX_WU:
        finish_load = {{G6LCCfg.XLEN - 32{1'b0}}, assembled[31:0]};
      default:
        finish_load = assembled[G6LCCfg.XLEN-1:0];
    endcase
  endfunction

  if (!G6LCCfg.RVZicclsm) begin : gen_off
    assign ctrl_o        = ctrl_i;
    assign pop_ld_byp_o  = pop_ld_fu_i;
    assign pop_st_byp_o  = pop_st_fu_i;
    assign ld_valid_o    = ld_valid_fu_i;
    assign ld_result_o   = ld_result_fu_i;
    assign ld_ex_o       = ld_ex_fu_i;
    assign ld_tid_o      = ld_tid_fu_i;
    assign st_valid_o    = st_valid_fu_i;
    assign st_result_o   = st_result_fu_i;
    assign st_ex_o       = st_ex_fu_i;
    assign st_tid_o      = st_tid_fu_i;
  end else begin : gen_on
    typedef enum logic [2:0] {
      IDLE,
      B0_ACTIVE,
      B0_WAIT,
      B1_ACTIVE,
      B1_WAIT
    } state_e;
    state_e state_q, state_d;
    lsu_ctrl_t orig_q, orig_d;
    logic [G6LCCfg.XLEN-1:0] beat0_data_q, beat0_data_d;
    logic [2:0] off, off_q, off_d;
    logic [1:0] sz;
    logic [3:0] n0, n1, n0_q, n0_d, n1_q, n1_d;
    logic split_now;
    lsu_ctrl_t beat0, beat1;
    logic [63:0] b0_in64, b0_aligned, b1_assembled, st_b1_data;
    logic is_load;
    logic hold_v_q, hold_v_d;
    logic [63:0] hold_r_q, hold_r_d;
    fu_op        hold_op_q, hold_op_d;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] hold_tid_q, hold_tid_d;

    assign off = ctrl_i.vaddr[2:0];
    assign sz = extract_transfer_size(ctrl_i.operation);
    assign n0 = 4'(W) - {1'b0, off};
    assign n1 = 4'(1 << unsigned'(sz)) - n0;
    assign split_now = ctrl_i.valid && zicclsm_eligible(ctrl_i.operation, ctrl_i.fu) &&
                       !ctrl_i.is_speculative_load_miss && wraps(off, sz);
    assign is_load = orig_q.fu == LOAD;

    // A136 + A10: byte-granular 8:1 muxes replace three 64-bit dynamic shifts
    // and 64-bit mask subtractors. Beat-0 data is right-aligned by off_q at
    // capture (1+ cycle early), and beat-1 assembly selects per byte lane.
    assign b0_in64 = 64'(ld_result_fu_i);
    logic [63:0] b0_q64, orig_data64;
    assign b0_q64      = 64'(beat0_data_q);
    assign orig_data64 = 64'(orig_q.data);
    for (genvar b = 0; b < 8; b++) begin : gen_byte_mux
      logic [2:0] b0_src, b1_src, st_src;
      assign b0_src = 3'(b) + off_q;
      assign b0_aligned[b*8 +: 8] = b0_in64[b0_src*8 +: 8];
      assign b1_src = 3'(b) - n0_q[2:0];
      assign b1_assembled[b*8 +: 8] = (4'(b) < n0_q)
          ? b0_q64[b*8 +: 8]
          : b0_in64[b1_src*8 +: 8];
      assign st_src = 3'(b) + n0_q[2:0];
      assign st_b1_data[b*8 +: 8] = ((4'(b) + n0_q) < 4'd8)
          ? orig_data64[st_src*8 +: 8]
          : 8'h00;
    end

    always_comb begin
      beat0 = orig_q;
      beat1 = orig_q;
      if (orig_q.fu == LOAD) begin
        beat0.vaddr = {orig_q.vaddr[G6LCCfg.VLEN-1:3], 3'b000};
        beat0.operation = G6LCCfg.IS_XLEN64 ? LD : LWU;
        beat0.be = '1;
        beat1.vaddr = beat0.vaddr + G6LCCfg.VLEN'(W);
        beat1.operation = beat0.operation;
        beat1.be = '1;
      end else begin
        beat0.be = ((8'((8'b1 << n0_q) - 1)) << orig_q.vaddr[2:0]);
        beat1.vaddr = orig_q.vaddr + G6LCCfg.VLEN'(n0_q);
        beat1.data = G6LCCfg.XLEN'(st_b1_data);
        beat1.be = 8'((8'b1 << n1_q) - 1);
      end
      beat0.valid = 1'b1;
      beat1.valid = 1'b1;
    end

    always_comb begin
      state_d        = state_q;
      orig_d         = orig_q;
      beat0_data_d   = beat0_data_q;
      off_d          = off_q;
      n0_d           = n0_q;
      n1_d           = n1_q;
      hold_v_d       = 1'b0;
      hold_r_d       = hold_r_q;
      hold_op_d      = hold_op_q;
      hold_tid_d     = hold_tid_q;
      ctrl_o         = ctrl_i;
      pop_ld_byp_o   = pop_ld_fu_i;
      pop_st_byp_o   = pop_st_fu_i;
      ld_valid_o     = ld_valid_fu_i;
      ld_result_o    = ld_result_fu_i;
      ld_ex_o        = ld_ex_fu_i;
      ld_tid_o       = ld_tid_fu_i;
      st_valid_o     = st_valid_fu_i;
      st_result_o    = st_result_fu_i;
      st_ex_o        = st_ex_fu_i;
      st_tid_o       = st_tid_fu_i;

      unique case (state_q)
        IDLE: begin
          if (split_now) begin
            state_d      = B0_ACTIVE;
            orig_d       = ctrl_i;
            off_d        = off;
            n0_d         = n0;
            n1_d         = n1;
            ctrl_o       = ctrl_i;
            pop_ld_byp_o = 1'b0;
            pop_st_byp_o = 1'b0;
            if (ctrl_i.fu == LOAD) begin
              ctrl_o.vaddr     = {ctrl_i.vaddr[G6LCCfg.VLEN-1:3], 3'b000};
              ctrl_o.operation = G6LCCfg.IS_XLEN64 ? LD : LWU;
              ctrl_o.be        = '1;
            end else begin
              ctrl_o.be = ((8'((8'b1 << n0) - 1)) << off);
            end
            if (ctrl_i.fu == LOAD && pop_ld_fu_i) state_d = B0_WAIT;
            if (ctrl_i.fu == STORE && pop_st_fu_i) state_d = B0_WAIT;
          end
        end
        B0_ACTIVE: begin
          ctrl_o       = beat0;
          pop_ld_byp_o = 1'b0;
          pop_st_byp_o = 1'b0;
          ld_valid_o   = 1'b0;
          st_valid_o   = 1'b0;
          if (is_load && ld_valid_fu_i) begin
            if (ld_ex_fu_i.valid) begin
              ld_valid_o   = 1'b1;
              pop_ld_byp_o = 1'b1;
              state_d      = IDLE;
            end else begin
              beat0_data_d = G6LCCfg.XLEN'(b0_aligned);
              state_d      = B1_ACTIVE;
            end
          end else if (is_load && pop_ld_fu_i) state_d = B0_WAIT;
          if (!is_load && st_valid_fu_i) begin
            if (st_ex_fu_i.valid) begin
              st_valid_o   = 1'b1;
              pop_st_byp_o = 1'b1;
              state_d      = IDLE;
            end else state_d = B1_ACTIVE;
          end else if (!is_load && pop_st_fu_i) state_d = B0_WAIT;
        end
        B0_WAIT: begin
          ctrl_o       = orig_q;
          ctrl_o.valid = 1'b0;
          pop_ld_byp_o = 1'b0;
          pop_st_byp_o = 1'b0;
          ld_valid_o   = 1'b0;
          st_valid_o   = 1'b0;
          if (is_load && ld_valid_fu_i) begin
            if (ld_ex_fu_i.valid) begin
              ld_valid_o   = 1'b1;
              pop_ld_byp_o = 1'b1;
              state_d      = IDLE;
            end else begin
              beat0_data_d = G6LCCfg.XLEN'(b0_aligned);
              state_d      = B1_ACTIVE;
            end
          end
          if (!is_load && st_valid_fu_i) begin
            if (st_ex_fu_i.valid) begin
              st_valid_o   = 1'b1;
              pop_st_byp_o = 1'b1;
              state_d      = IDLE;
            end else begin
              state_d = B1_ACTIVE;
            end
          end
        end
        B1_ACTIVE: begin
          ctrl_o         = beat1;
          pop_ld_byp_o   = 1'b0;
          pop_st_byp_o   = 1'b0;
          ld_valid_o     = 1'b0;
          st_valid_o     = 1'b0;
          if (is_load && pop_ld_fu_i) state_d = B1_WAIT;
          if (!is_load && pop_st_fu_i) state_d = B1_WAIT;
          if (ld_valid_fu_i && ld_ex_fu_i.valid) begin
            ld_valid_o   = 1'b1;
            pop_ld_byp_o = 1'b1;
            state_d      = IDLE;
          end
          if (st_valid_fu_i && st_ex_fu_i.valid) begin
            st_valid_o   = 1'b1;
            pop_st_byp_o = 1'b1;
            state_d      = IDLE;
          end
        end
        B1_WAIT: begin
          ctrl_o       = orig_q;
          ctrl_o.valid = 1'b0;
          pop_ld_byp_o = 1'b0;
          pop_st_byp_o = 1'b0;
          ld_valid_o   = 1'b0;
          st_valid_o   = 1'b0;
          if (is_load && ld_valid_fu_i) begin
            hold_v_d     = 1'b1;
            hold_r_d     = b1_assembled;
            hold_op_d    = orig_q.operation;
            hold_tid_d   = orig_q.trans_id;
            pop_ld_byp_o = 1'b1;
            state_d      = IDLE;
          end
          if (!is_load && st_valid_fu_i) begin
            st_valid_o   = 1'b1;
            st_result_o  = orig_q.data;
            st_ex_o      = st_ex_fu_i;
            st_tid_o     = orig_q.trans_id;
            pop_st_byp_o = 1'b1;
            state_d      = IDLE;
          end
        end
        default: state_d = IDLE;
      endcase

      if (hold_v_q) begin
        ld_valid_o  = 1'b1;
        ld_result_o = finish_load(hold_op_q, hold_r_q);
        ld_tid_o    = hold_tid_q;
        ld_ex_o     = '0;
      end

      // OoO wrong-path recovery for an in-flight split: a cancelled_mask
      // squash does not raise flush_i, so the held op's beats never produce
      // the awaited result and the WAIT arms would pin the bypass head
      // forever (the load/store unit drops the beat on the same mask). In
      // the WAIT arms every issued beat has already popped (the ACTIVE->WAIT
      // edge consumed its pop_ld/st_fu_i), so no beat completion is still
      // outstanding: releasing the head here cannot double-pop. ctrl_i is
      // still the held op (pop_*_byp_o is 0 while split), so its
      // is_speculative_load_miss tracks orig_q.trans_id's cancel.
      if (((state_q == B0_WAIT) || (state_q == B1_WAIT)) &&
          ctrl_i.is_speculative_load_miss) begin
        state_d        = IDLE;
        ctrl_o.valid   = 1'b0;
        ld_valid_o     = 1'b0;
        st_valid_o     = 1'b0;
        pop_ld_byp_o   = is_load;
        pop_st_byp_o   = !is_load;
      end

      if (flush_i) begin
        state_d      = IDLE;
        ctrl_o.valid = 1'b0;
        ld_valid_o   = 1'b0;
        st_valid_o   = 1'b0;
        pop_ld_byp_o = 1'b0;
        pop_st_byp_o = 1'b0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q      <= IDLE;
        orig_q       <= '0;
        beat0_data_q <= '0;
        off_q        <= '0;
        n0_q         <= '0;
        n1_q         <= '0;
        hold_v_q     <= 1'b0;
        hold_r_q     <= '0;
        hold_op_q    <= LD;
        hold_tid_q   <= '0;
      end else begin
        state_q      <= state_d;
        orig_q       <= orig_d;
        beat0_data_q <= beat0_data_d;
        off_q        <= off_d;
        n0_q         <= n0_d;
        n1_q         <= n1_d;
        hold_v_q     <= hold_v_d;
        hold_r_q     <= hold_r_d;
        hold_op_q    <= hold_op_d;
        hold_tid_q   <= hold_tid_d;
      end
    end
  end
endmodule
