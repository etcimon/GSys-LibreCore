// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Native APU execution cluster: one physical FP32 FPnew FMA + integer ALU,
// four lockstep fragment-quad contexts. Predication, helper-style skip
// (no write when masked), privilege-separated micro vs shader memory,
// uniform BR, and a horizontal quad exchange. Default-off. Not a rasterizer
// or EGL.

module g6lc_apu_exec
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
#(
  parameter apu_cfg_t ApuCfg = ApuOff
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
  input  logic enable_i,
  input  logic cancel_i,
  input  logic start_i,
  input  logic shader_i,
  input  logic imem_we_i,
  input  logic [3:0] imem_idx_i,
  input  logic [31:0] imem_wdata_i,
  output logic idle_o,
  output logic busy_o,
  output logic fault_o,
  input  logic [1:0] dbg_thread_i,
  input  logic [2:0] dbg_reg_i,
  output logic [31:0] dbg_data_o,
  input  logic [5:0] dbg_dmem_idx_i,
  output logic [31:0] dbg_dmem_o,
  input  logic dbg_we_i,
  input  logic [31:0] dbg_wdata_i
);
  localparam bit ExecEn = ApuCfg.Enable && ApuCfg.ExecEn;
  localparam int unsigned N = 4;
  localparam int unsigned R = 8;
  localparam int unsigned M = ApuCfg.ExecMemWords == 0 ? 64 : ApuCfg.ExecMemWords;

  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU exec: invalid configuration");
  `endif

  if (!ExecEn) begin : gen_off
    assign idle_o = 1'b1;
    assign busy_o = 1'b0;
    assign fault_o = 1'b0;
    assign dbg_data_o = '0;
    assign dbg_dmem_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | enable_i | cancel_i | start_i |
                    shader_i | dbg_we_i | imem_we_i | |dbg_thread_i | |dbg_reg_i |
                    |dbg_wdata_i | |imem_idx_i | |imem_wdata_i | |dbg_dmem_idx_i;
  end else begin : gen_on
    typedef enum logic [2:0] {Idle, Fetch, Issue, WaitFp, Write, Next} state_e;
    state_e state_q;
    logic [3:0] pc_q;
    logic [1:0] thread_q;
    logic shader_q, fault_q;
    logic [N-1:0] mask_q;
    logic [31:0] rf_q [N][R];
    logic [31:0] snap_q [N];
    logic [31:0] imem_q [APU_EXEC_IMEM];
    logic [31:0] dmem_q [M];
    apu_exec_inst_t inst_q;
    logic [31:0] result_q;
    logic [2:0][31:0] fp_ops;
    fpnew_pkg::operation_e fp_op;
    logic fp_mod;
    logic fp_in_v, fp_in_r, fp_out_v, fp_out_r;
    logic [31:0] fp_res;
    fpnew_pkg::status_t fp_st;
    logic [31:0] rs1, rs2, rs3, neigh, alu;
    logic [1:0] mate;
    logic pred_skip, is_fp, is_ld, is_st, is_br, take, kill, mem_bad;
    logic [31:0] ea;
    logic [$clog2(M)-1:0] widx;
    apu_exec_inst_t fetched;
    logic signed [10:0] br_tgt;
    integer t, r;

    assign kill = cancel_i || !enable_i;
    assign idle_o = state_q == Idle;
    assign busy_o = state_q != Idle;
    assign fault_o = fault_q;
    assign dbg_data_o = rf_q[dbg_thread_i][dbg_reg_i];
    assign dbg_dmem_o = dmem_q[dbg_dmem_idx_i];
    assign rs1 = rf_q[thread_q][inst_q.rs1[2:0]];
    assign rs2 = rf_q[thread_q][inst_q.rs2[2:0]];
    assign rs3 = rf_q[thread_q][inst_q.rs3[2:0]];
    assign mate = thread_q ^ 2'b01;
    assign neigh = snap_q[mate];
    assign pred_skip = inst_q.pred && !mask_q[thread_q];
    assign is_fp = inst_q.op == APU_EX_FADD || inst_q.op == APU_EX_FMUL ||
                   inst_q.op == APU_EX_FMADD || inst_q.op == APU_EX_FSUB;
    assign is_ld = inst_q.op == APU_EX_LD;
    assign is_st = inst_q.op == APU_EX_ST;
    assign fetched = apu_exec_inst_t'(imem_q[pc_q]);
    assign is_br = fetched.op == APU_EX_BR;
    assign br_tgt = $signed({7'b0, pc_q}) + $signed({{2{fetched.imm[8]}}, fetched.imm});
    assign take = state_q == Issue && !pred_skip &&
                  !(inst_q.priv && shader_q);
    assign fp_in_v = take && is_fp && state_q == Issue;
    assign fp_out_r = state_q == WaitFp;
    assign ea = rs1 + {{23{inst_q.imm[8]}}, inst_q.imm};
    assign widx = ea[$clog2(M)+1:2];
    assign mem_bad = (is_ld || is_st) &&
                     (ea[1:0] != 0 || 32'(ea[31:2]) >= 32'(M) ||
                      (shader_q && 32'(ea[31:2]) >= 32'(M / 2)));

    always_comb begin
      fp_ops = '0;
      fp_op = fpnew_pkg::FMADD;
      fp_mod = 1'b0;
      unique case (inst_q.op)
        APU_EX_FADD: begin
          fp_op = fpnew_pkg::ADD;
          fp_ops[1] = rs1;
          fp_ops[2] = rs2;
        end
        APU_EX_FSUB: begin
          fp_op = fpnew_pkg::ADD;
          fp_mod = 1'b1;
          fp_ops[1] = rs1;
          fp_ops[2] = rs2;
        end
        APU_EX_FMUL: begin
          fp_op = fpnew_pkg::MUL;
          fp_ops[0] = rs1;
          fp_ops[1] = rs2;
        end
        default: begin
          fp_op = fpnew_pkg::FMADD;
          fp_ops[0] = rs1;
          fp_ops[1] = rs2;
          fp_ops[2] = rs3;
        end
      endcase
    end

    always_comb begin
      alu = '0;
      unique case (inst_q.op)
        APU_EX_LDI:     alu = {{23{inst_q.imm[8]}}, inst_q.imm};
        APU_EX_LDC:     alu = imem_q[pc_q + 4'd1];
        APU_EX_MOV:     alu = rs1;
        APU_EX_FNEG:    alu = rs1 ^ 32'h8000_0000;
        APU_EX_TID:     alu = 32'(thread_q);
        APU_EX_IADD:    alu = rs1 + rs2;
        APU_EX_ISUB:    alu = rs1 - rs2;
        APU_EX_IAND:    alu = rs1 & rs2;
        APU_EX_IOR:     alu = rs1 | rs2;
        APU_EX_IXOR:    alu = rs1 ^ rs2;
        APU_EX_CMPLT:   alu = {31'h0, $signed(rs1) < $signed(rs2)};
        APU_EX_QUADX:   alu = neigh;
        APU_EX_SETMASK: alu = {31'h0, rs1[0]};
        APU_EX_LD:      alu = dmem_q[widx];
        default:        alu = '0;
      endcase
    end

    fpnew_fma #(
      .FpFormat(fpnew_pkg::FP32),
      .NumPipeRegs(1),
      .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic),
      .AuxType(logic)
    ) i_fma (
      .clk_i, .rst_ni,
      .operands_i(fp_ops), .is_boxed_i(3'b111),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(fp_op), .op_mod_i(fp_mod),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(fp_in_v), .in_ready_o(fp_in_r),
      .flush_i(kill),
      .result_o(fp_res), .status_o(fp_st),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(fp_out_v), .out_ready_i(fp_out_r),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; pc_q <= '0; thread_q <= '0; shader_q <= 1'b0; fault_q <= 1'b0;
        mask_q <= {N{1'b1}}; inst_q <= '0; result_q <= '0;
        for (t = 0; t < N; t++) begin
          snap_q[t] <= '0;
          for (r = 0; r < R; r++) rf_q[t][r] <= '0;
        end
        for (t = 0; t < APU_EXEC_IMEM; t++) imem_q[t] <= '0;
        for (t = 0; t < M; t++) dmem_q[t] <= '0;
      end else begin
        if (kill) begin
          state_q <= Idle; fault_q <= 1'b0;
        end else unique case (state_q)
          Idle: if (start_i) begin
            pc_q <= '0; thread_q <= '0; shader_q <= shader_i; fault_q <= 1'b0;
            mask_q <= {N{1'b1}}; state_q <= Fetch;
          end else if (dbg_we_i && dbg_reg_i != 0) begin
            rf_q[dbg_thread_i][dbg_reg_i] <= dbg_wdata_i;
          end else if (imem_we_i) begin
            imem_q[imem_idx_i] <= imem_wdata_i;
          end
          Fetch: begin
            inst_q <= fetched;
            thread_q <= '0;
            for (t = 0; t < N; t++) snap_q[t] <= rf_q[t][fetched.rs1[2:0]];
            if ((shader_q && fetched.priv) || fetched.op > APU_EX_LDC ||
                fetched.rd[3] || fetched.rs1[3] || fetched.rs2[3] || fetched.rs3[3]) begin
              fault_q <= 1'b1; state_q <= Idle;
            end else if (fetched.op == APU_EX_HALT) state_q <= Idle;
            else if (fetched.op == APU_EX_NOP) begin
              pc_q <= pc_q + 4'd1; state_q <= Fetch;
            end else if (fetched.op == APU_EX_BR) begin
              if (|mask_q) begin
                if (br_tgt < 0 || br_tgt >= $signed(11'(APU_EXEC_IMEM))) begin
                  fault_q <= 1'b1; state_q <= Idle;
                end else begin
                  pc_q <= br_tgt[3:0]; state_q <= Fetch;
                end
              end else begin
                pc_q <= pc_q + 4'd1; state_q <= Fetch;
              end
            end else state_q <= Issue;
          end
          Issue: begin
            if (inst_q.priv && shader_q) begin
              fault_q <= 1'b1; state_q <= Idle;
            end else if (inst_q.op == APU_EX_LDC &&
                         pc_q == 4'(APU_EXEC_IMEM - 1)) begin
              fault_q <= 1'b1; state_q <= Idle;
            end else if (pred_skip) state_q <= Next;
            else if (mem_bad) begin
              fault_q <= 1'b1; state_q <= Idle;
            end else if (is_fp) begin
              if (fp_in_v && fp_in_r) state_q <= WaitFp;
            end else begin
              result_q <= alu;
              state_q <= Write;
            end
          end
          WaitFp: if (fp_out_v && fp_out_r) begin
            result_q <= fp_res;
            state_q <= Write;
          end
          Write: begin
            if (is_st) dmem_q[widx] <= rs2;
            else if (inst_q.op == APU_EX_SETMASK) mask_q[thread_q] <= result_q[0];
            else if (inst_q.op == APU_EX_CMPLT) mask_q[thread_q] <= result_q[0];
            else if (inst_q.rd[2:0] != 0) rf_q[thread_q][inst_q.rd[2:0]] <= result_q;
            state_q <= Next;
          end
          Next: begin
            if (thread_q == 2'(N - 1)) begin
              if (inst_q.op == APU_EX_LDC) begin
                if (pc_q >= 4'(APU_EXEC_IMEM - 2))
                  state_q <= Idle;
                else begin
                  pc_q <= pc_q + 4'd2;
                  state_q <= Fetch;
                end
              end else begin
                pc_q <= pc_q + 4'd1;
                state_q <= Fetch;
              end
            end else begin
              thread_q <= thread_q + 2'd1;
              state_q <= Issue;
            end
          end
          default: state_q <= Idle;
        endcase
      end
    end

    logic unused_tm, unused_st;
    assign unused_tm = testmode_i;
    assign unused_st = |fp_st;
  end
endmodule
