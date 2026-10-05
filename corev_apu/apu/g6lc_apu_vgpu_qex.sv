// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Scene descriptor 1 is the execbuffer at 64'h8800B000 with NEXT
// to 2. The header descriptor and a jump record nothing. A
// second store keeps the first. This is later than
// g6lc_apu_vgpu_qek. This is not g6lc_apu_vgpu_qfx and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneDesc1Check (qex): Execbuffer at 64'h8800B000 with NEXT to 2.
module g6lc_apu_vgpu_qex
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qek_t qek_i,
  input  apu_vgpu_qed_t qed_i,
  input  apu_vgpu_qsf_t qsf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qex_cpl_t cpl_o,
  output apu_vgpu_qex_t qex_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qex_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qek_i) | (|qed_i) | (|qsf_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qex_cpl_t cpl_q;
    apu_vgpu_qex_t qex_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qex_cpl_t'('0);
    assign qex_o = qex_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qex_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qex_q.valid) begin
            cpl_q.status <= APU_VGPU_QEX_FAULT;
          end else if (!qek_i.valid || !qed_i.valid || !qsf_i.valid) begin
            cpl_q.status <= APU_VGPU_QEX_EMPTY;
          end else if (qek_i.exec_addr != APU_VGPU_EXEC_ADDR ||
                       qek_i.exec_addr == APU_VGPU_HDR_ADDR ||
                       qek_i.exec_len != APU_VGPU_SCENE_BYTES ||
                       qek_i.nxt != 16'd2 ||
                       qek_i.nxt == 16'd1 ||
                       qek_i.exec_addr != qed_i.exec_addr ||
                       qek_i.nxt != qed_i.nxt ||
                       qsf_i.nxt != 16'd1 ||
                       qsf_i.nxt == 16'd2) begin
            cpl_q.status <= APU_VGPU_QEX_FAULT;
          end else begin
            qex_q.valid <= 1'b1;
            qex_q.exec_addr <= qek_i.exec_addr;
            qex_q.nxt <= qek_i.nxt;
            cpl_q.status <= APU_VGPU_QEX_OK;
          end
          state_q <= Done;
        end
        Done: begin
          if (!armed_q) armed_q <= 1'b1;
          else if (cpl_ready_i) begin
            armed_q <= 1'b0;
            state_q <= Idle;
          end
        end
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(qex_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QEX_OK |->
        qex_o.valid && qex_o.exec_addr == APU_VGPU_EXEC_ADDR &&
        qex_o.nxt == 16'd2);
    `endif
  end
endmodule

// SceneDesc1Check (qex) enable-0 fixture: Execbuffer at 64'h8800B000 with NEXT to 2.
module g6lc_apu_vgpu_qex_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qek_t qek_i,
  input  apu_vgpu_qed_t qed_i,
  input  apu_vgpu_qsf_t qsf_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qex_cpl_t cpl_o,
  output apu_vgpu_qex_t qex_o
);
  g6lc_apu_vgpu_qex #(.Enable(Enable)) i_dut (.*);
endmodule
