// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded SPIR-V-subset interpreter with an immutable 128-word program
// store. The test transport is program bytes, two integer inputs, and an
// IRQ on completion. Enable=0 elaborates no datapath. Not a Venus frontend,
// not a Mesa ICD, and not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// SpirvSubset (spirv): Bounded SPIR-V-subset interpreter, immutable program store. Default-off. Bytes+IRQ diagnostic transport; FeatureVirgl stays illegal.
// Interplay: SpirvSubset (spirv) --? ApuSys --? ExecCluster (exec). Diagnostic TB client. See AGENTS-impl-interplays.md.
module g6lc_apu_spirv
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic prog_we_i,
  input  logic [6:0] prog_idx_i,
  input  logic [31:0] prog_wdata_i,
  input  logic [7:0] prog_len_i,
  input  logic commit_i,
  input  logic start_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic idle_o,
  output logic busy_o,
  output logic done_o,
  output logic fault_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign idle_o = 1'b1;
    assign busy_o = 1'b0;
    assign done_o = 1'b0;
    assign fault_o = 1'b0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | prog_we_i | commit_i | start_i |
                    (|prog_idx_i) | (|prog_wdata_i) | (|prog_len_i) |
                    (|in_a_i) | (|in_b_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Run, Done, Fault } state_e;
    state_e state_q;
    logic locked_q;
    logic [7:0] len_q;
    logic [7:0] pc_q;
    logic [31:0] imem_q [APU_SPIRV_IMEM_WORDS];
    logic [31:0] ssa_q [APU_SPIRV_IDS];
    logic [1:0] bind_q [APU_SPIRV_IDS];
    logic [APU_SPIRV_IDS-1:0] ssa_v_q;
    logic [APU_SPIRV_IDS-1:0] bind_v_q;
    logic saw_shader_q;
    logic saw_entry_q;
    logic [31:0] in_a_q;
    logic [31:0] in_b_q;
    logic [31:0] result_q;

    logic [7:0] pc_p1, pc_p2, pc_p3, pc_p4;
    logic [31:0] inst0, inst1, inst2, inst3, inst4;
    logic [15:0] spv_op, spv_wc;
    logic [31:0] spv_w1, spv_w2, spv_w3, spv_w4;
    logic spv_bad_len;
    logic [8:0] spv_end;
    logic id2_ok, id3_ok, id4_ok, id1_ok;

    assign idle_o = state_q != Run;
    assign busy_o = state_q == Run;
    assign done_o = state_q == Done;
    assign fault_o = state_q == Fault;
    assign irq_o = state_q == Done;
    assign result_o = result_q;

    assign pc_p1 = pc_q + 8'd1;
    assign pc_p2 = pc_q + 8'd2;
    assign pc_p3 = pc_q + 8'd3;
    assign pc_p4 = pc_q + 8'd4;
    assign inst0 = (pc_q < 8'(APU_SPIRV_IMEM_WORDS)) ? imem_q[pc_q[6:0]] : 32'h0;
    assign inst1 = (pc_p1 < 8'(APU_SPIRV_IMEM_WORDS)) ? imem_q[pc_p1[6:0]] : 32'h0;
    assign inst2 = (pc_p2 < 8'(APU_SPIRV_IMEM_WORDS)) ? imem_q[pc_p2[6:0]] : 32'h0;
    assign inst3 = (pc_p3 < 8'(APU_SPIRV_IMEM_WORDS)) ? imem_q[pc_p3[6:0]] : 32'h0;
    assign inst4 = (pc_p4 < 8'(APU_SPIRV_IMEM_WORDS)) ? imem_q[pc_p4[6:0]] : 32'h0;
    assign spv_op = inst0[15:0];
    assign spv_wc = inst0[31:16];
    assign spv_w1 = inst1;
    assign spv_w2 = inst2;
    assign spv_w3 = inst3;
    assign spv_w4 = inst4;
    assign spv_end = 9'(pc_q) + 9'(spv_wc[7:0]);
    assign spv_bad_len = (spv_wc == 16'd0) || (spv_wc > 16'd16) ||
                         (32'(pc_q) >= 32'(len_q)) ||
                         ((32'(pc_q) + 32'(spv_wc)) > 32'(len_q));
    assign id1_ok = spv_w1 < 32'(APU_SPIRV_IDS);
    assign id2_ok = spv_w2 < 32'(APU_SPIRV_IDS);
    assign id3_ok = spv_w3 < 32'(APU_SPIRV_IDS);
    assign id4_ok = spv_w4 < 32'(APU_SPIRV_IDS);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        locked_q <= 1'b0;
        len_q <= '0;
        pc_q <= '0;
        imem_q <= '{default: '0};
        ssa_q <= '{default: '0};
        bind_q <= '{default: '0};
        ssa_v_q <= '0;
        bind_v_q <= '0;
        saw_shader_q <= 1'b0;
        saw_entry_q <= 1'b0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (prog_we_i && locked_q) begin
            state_q <= Fault;
          end else if (prog_we_i) begin
            imem_q[prog_idx_i] <= prog_wdata_i;
          end else if (commit_i && locked_q) begin
            state_q <= Fault;
          end else if (commit_i) begin
            locked_q <= 1'b1;
            len_q <= prog_len_i;
            if (prog_len_i < 8'd6 || prog_len_i > 8'(APU_SPIRV_IMEM_WORDS))
              state_q <= Fault;
          end else if (start_i && !locked_q) begin
            state_q <= Fault;
          end else if (start_i) begin
            ssa_q <= '{default: '0};
            bind_q <= '{default: '0};
            ssa_v_q <= '0;
            bind_v_q <= '0;
            saw_shader_q <= 1'b0;
            saw_entry_q <= 1'b0;
            result_q <= '0;
            in_a_q <= in_a_i;
            in_b_q <= in_b_i;
            pc_q <= 8'd5;
            if (imem_q[0] != APU_SPIRV_MAGIC || imem_q[3] > 32'(APU_SPIRV_IDS))
              state_q <= Fault;
            else
              state_q <= Run;
          end
        end
        Run: begin
          if (spv_bad_len) begin
            state_q <= Fault;
          end else unique case (spv_op)
            16'd17: begin
              if (spv_w1 != 32'd1) state_q <= Fault;
              else begin
                saw_shader_q <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd15: begin
              if (spv_w1 != 32'd5) state_q <= Fault;
              else begin
                saw_entry_q <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd71: begin
              if (spv_w2 == 32'd33) begin
                if (!id1_ok || spv_w3 > 32'd2) state_q <= Fault;
                else begin
                  bind_q[spv_w1[4:0]] <= spv_w3[1:0];
                  bind_v_q[spv_w1[4:0]] <= 1'b1;
                  pc_q <= spv_end[7:0];
                end
              end else begin
                pc_q <= spv_end[7:0];
              end
            end
            16'd43: begin
              if (!id2_ok) state_q <= Fault;
              else begin
                ssa_q[spv_w2[4:0]] <= spv_w3;
                ssa_v_q[spv_w2[4:0]] <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd59: begin
              if ((!id2_ok) || (spv_w3 != 32'd12 && spv_w3 != 32'd2))
                state_q <= Fault;
              else
                pc_q <= spv_end[7:0];
            end
            16'd61: begin
              if (!id2_ok || !id3_ok || !bind_v_q[spv_w3[4:0]] ||
                  bind_q[spv_w3[4:0]] > 2'd1)
                state_q <= Fault;
              else begin
                ssa_q[spv_w2[4:0]] <= (bind_q[spv_w3[4:0]] == 2'd0) ?
                                      in_a_q : in_b_q;
                ssa_v_q[spv_w2[4:0]] <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd65: begin
              if (!id2_ok || !id3_ok || !bind_v_q[spv_w3[4:0]])
                state_q <= Fault;
              else begin
                bind_q[spv_w2[4:0]] <= bind_q[spv_w3[4:0]];
                bind_v_q[spv_w2[4:0]] <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd128, 16'd132: begin
              if (!id2_ok || !id3_ok || !id4_ok ||
                  !ssa_v_q[spv_w3[4:0]] || !ssa_v_q[spv_w4[4:0]])
                state_q <= Fault;
              else begin
                ssa_q[spv_w2[4:0]] <= (spv_op == 16'd128) ?
                    (ssa_q[spv_w3[4:0]] + ssa_q[spv_w4[4:0]]) :
                    (ssa_q[spv_w3[4:0]] * ssa_q[spv_w4[4:0]]);
                ssa_v_q[spv_w2[4:0]] <= 1'b1;
                pc_q <= spv_end[7:0];
              end
            end
            16'd62: begin
              if (!id1_ok || !id2_ok || !bind_v_q[spv_w1[4:0]] ||
                  bind_q[spv_w1[4:0]] != 2'd2 || !ssa_v_q[spv_w2[4:0]])
                state_q <= Fault;
              else begin
                result_q <= ssa_q[spv_w2[4:0]];
                pc_q <= spv_end[7:0];
              end
            end
            16'd253: begin
              if (!saw_shader_q || !saw_entry_q) state_q <= Fault;
              else state_q <= Done;
            end
            16'd5, 16'd14, 16'd16, 16'd19, 16'd20, 16'd21, 16'd22, 16'd23,
            16'd24, 16'd25, 16'd26, 16'd27, 16'd28, 16'd29, 16'd30, 16'd31,
            16'd32, 16'd33, 16'd54, 16'd56, 16'd72, 16'd248: begin
              pc_q <= spv_end[7:0];
            end
            default: state_q <= Fault;
          endcase
        end
        Done: begin
          if (prog_we_i || commit_i) begin
            state_q <= Fault;
          end else if (start_i) begin
            ssa_q <= '{default: '0};
            bind_q <= '{default: '0};
            ssa_v_q <= '0;
            bind_v_q <= '0;
            saw_shader_q <= 1'b0;
            saw_entry_q <= 1'b0;
            result_q <= '0;
            in_a_q <= in_a_i;
            in_b_q <= in_b_i;
            pc_q <= 8'd5;
            if (imem_q[0] != APU_SPIRV_MAGIC || imem_q[3] > 32'(APU_SPIRV_IDS))
              state_q <= Fault;
            else
              state_q <= Run;
          end
        end
        default: begin
        end
      endcase
    end
  end
endmodule

// SpirvSubset (spirv) enable-0 fixture: bounded SPIR-V-subset interpreter.
module g6lc_apu_spirv_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic prog_we_i,
  input  logic [6:0] prog_idx_i,
  input  logic [31:0] prog_wdata_i,
  input  logic [7:0] prog_len_i,
  input  logic commit_i,
  input  logic start_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic idle_o,
  output logic busy_o,
  output logic done_o,
  output logic fault_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_spirv #(.Enable(Enable)) i_dut (.*);
endmodule
