// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Firmware mailbox front-end for g6lc_apu_exec. IMEM/RF load, micro vs
// shader RUN, RF peek, and DMEM peek (headless color readback). Default-off.
// Local SRAM only; not a DRAM LSU and not EGL.

module g6lc_apu_exec_bind
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
  input  logic          op_valid_i,
  output logic          op_ready_o,
  input  apu_mem_op_e   op_i,
  input  apu_exec_job_t exec_i,
  output logic          op_cpl_valid_o,
  input  logic          op_cpl_ready_i,
  output apu_map_cpl_t  op_cpl_o,
  output logic          idle_o
);
  localparam bit ExecEn = ApuCfg.Enable && ApuCfg.ExecEn;

  `ifndef SYNTHESIS
  initial assert (apu_cfg_legal(ApuCfg)) else $fatal(1, "APU exec bind: invalid configuration");
  `endif

  if (!ExecEn) begin : gen_off
    assign op_ready_o = 1'b0;
    assign op_cpl_valid_o = 1'b0;
    assign op_cpl_o = '0;
    assign idle_o = 1'b1;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | enable_i | cancel_i |
                    op_valid_i | op_cpl_ready_i | |op_i | |exec_i;
  end else begin : gen_on
    typedef enum logic [1:0] {Idle, Pulse, WaitRun, Cpl} state_e;
    state_e state_q;
    apu_mem_op_e op_q;
    apu_exec_job_t job_q;
    apu_dma_status_e st_q;
    logic [31:0] data_q;
    logic exec_idle, exec_busy, exec_fault, start, imem_we, dbg_we, shader;
    logic [31:0] dbg_data, dbg_dmem;
    logic take, take_err;

    assign idle_o = state_q == Idle && exec_idle;
    assign take_err = op_valid_i && state_q == Idle && !apu_op_is_exec(op_i);
    assign take = op_valid_i && state_q == Idle && enable_i && !cancel_i &&
                  apu_op_is_exec(op_i) && exec_idle;
    assign op_ready_o = state_q == Idle &&
                        (exec_idle || !op_valid_i || !apu_op_is_exec(op_i));
    assign op_cpl_valid_o = state_q == Cpl;
    assign op_cpl_o = '{status: st_q, slot: '0, resource_id: data_q,
                        context_id: '0, epoch: '0, bytes: '0, tag: '0};
    assign start = take && op_i == APU_MEM_EXEC_RUN;
    assign shader = take ? exec_i.shader : job_q.shader;
    assign imem_we = state_q == Pulse && op_q == APU_MEM_EXEC_IMEM;
    assign dbg_we = state_q == Pulse && op_q == APU_MEM_EXEC_POKE;

    g6lc_apu_exec #(.ApuCfg(ApuCfg)) i_exec (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .cancel_i,
      .start_i(start), .shader_i(shader),
      .imem_we_i(imem_we), .imem_idx_i(job_q.idx), .imem_wdata_i(job_q.inst),
      .idle_o(exec_idle), .busy_o(exec_busy), .fault_o(exec_fault),
      .dbg_thread_i(job_q.thread), .dbg_reg_i(job_q.regno), .dbg_data_o(dbg_data),
      .dbg_dmem_idx_i(job_q.data[5:0]), .dbg_dmem_o(dbg_dmem),
      .dbg_we_i(dbg_we), .dbg_wdata_i(job_q.data)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle; op_q <= APU_MEM_NONE; job_q <= '0;
        st_q <= APU_DMA_OK; data_q <= '0;
      end else if (cancel_i) begin
        state_q <= Idle; st_q <= APU_DMA_CANCELLED;
      end else unique case (state_q)
        Idle: if (take_err) begin
          op_q <= op_i;
          st_q <= APU_DMA_PERMISSION;
          data_q <= '0;
          state_q <= Cpl;
        end else if (take) begin
          op_q <= op_i;
          job_q <= exec_i;
          if (op_i == APU_MEM_EXEC_RUN) state_q <= WaitRun;
          else state_q <= Pulse;
        end
        Pulse: begin
          data_q <= (op_q == APU_MEM_EXEC_PEEK) ? dbg_data :
                    (op_q == APU_MEM_EXEC_DPEEK) ? dbg_dmem : '0;
          st_q <= APU_DMA_OK;
          state_q <= Cpl;
        end
        WaitRun: if (exec_idle) begin
          st_q <= exec_fault ? APU_DMA_PROTOCOL : APU_DMA_OK;
          data_q <= {31'h0, exec_fault};
          state_q <= Cpl;
        end
        Cpl: if (op_cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    logic unused_b;
    assign unused_b = exec_busy | testmode_i;
  end
endmodule
