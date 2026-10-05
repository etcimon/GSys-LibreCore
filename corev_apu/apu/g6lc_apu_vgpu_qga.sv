// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the guest ack at 64'h8800E510. The low word must be 32'h1.
// Then write 32'h0 over the status word at 64'h8800E500. A
// config-only ack or a zero ack writes nothing. A cancel before
// the read writes nothing. This is later than g6lc_apu_vgpu_qsm.
// This is not g6lc_apu_vgpu_qaw, not g6lc_apu_vgpu_taw, not
// g6lc_apu_vgpu_vaw, and not PLIC source 9. The image is not
// kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// SceneUsedAck (qga): Scene guest ack after that interrupt.
module g6lc_apu_vgpu_qga
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_qsm_t qsm_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qga_cpl_t cpl_o,
  output apu_vgpu_qga_t qga_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qga_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | req_valid_i | cpl_ready_i |
                        rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|qsm_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, RdIssue, RdWait, WrIssue, WrWait, Done
    } state_e;
    state_e state_q;
    apu_vgpu_qga_cpl_t cpl_q;
    apu_vgpu_qga_t qga_q;
    logic armed_q;

    assign rd_valid_o = state_q == RdIssue;
    assign rd_addr_o = APU_VGPU_QGA_ADDR;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == RdWait;
    assign wr_valid_o = state_q == WrIssue;
    assign wr_addr_o = APU_VGPU_QGA_STAT;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_VAW_CLEAR};
    assign wr_rsp_ready_o = state_q == WrWait;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qga_cpl_t'('0);
    assign qga_o = qga_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qga_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qga_q.valid) begin
            cpl_q.status <= APU_VGPU_QGA_FAULT;
            state_q <= Done;
          end else if (!qsm_i.valid) begin
            cpl_q.status <= APU_VGPU_QGA_EMPTY;
            state_q <= Done;
          end else if (cancel_i ||
                       qsm_i.reason != APU_VGPU_QSI_REASON ||
                       qsm_i.used_idx != APU_VGPU_QSU_IDXV ||
                       qsm_i.used_idx == APU_VGPU_TUW_IDXV ||
                       qsm_i.addr != APU_VGPU_QSI_ADDR ||
                       qsm_i.addr == APU_VGPU_TIW_ADDR) begin
            cpl_q.status <= APU_VGPU_QGA_FAULT;
            state_q <= Done;
          end else state_q <= RdIssue;
        end
        RdIssue: if (cancel_i) begin
          cpl_q.status <= APU_VGPU_QGA_FAULT;
          state_q <= Done;
        end else if (rd_ready_i) state_q <= RdWait;
        RdWait: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != APU_VGPU_QGA_ADDR ||
                    rd_rsp_addr_i == APU_VGPU_TAW_ADDR ||
                    rd_rsp_len_i != 32'd4 ||
                    rd_rsp_data_i[31:0] != APU_VGPU_QSI_REASON;
          if (cancel_i || bad_bus || qsm_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_QGA_FAULT;
            state_q <= Done;
          end else state_q <= WrIssue;
        end
        WrIssue: if (wr_ready_i) state_q <= WrWait;
        WrWait: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_QGA_STAT ||
              wr_rsp_addr_i == APU_VGPU_TIW_ADDR) begin
            cpl_q.status <= APU_VGPU_QGA_FAULT;
          end else begin
            qga_q.valid <= 1'b1;
            qga_q.ack <= APU_VGPU_QSI_REASON;
            qga_q.remain <= APU_VGPU_VAW_CLEAR;
            qga_q.used_idx <= APU_VGPU_QSU_IDXV;
            qga_q.ack_addr <= APU_VGPU_QGA_ADDR;
            qga_q.status_addr <= APU_VGPU_QGA_STAT;
            cpl_q.status <= APU_VGPU_QGA_OK;
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
      rd_valid_o && !rd_ready_i |=> rd_valid_o && $stable(rd_addr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o) && $stable(wr_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QGA_OK |->
        qga_o.valid && qga_o.ack == APU_VGPU_QSI_REASON &&
        qga_o.remain == APU_VGPU_VAW_CLEAR &&
        qga_o.used_idx == APU_VGPU_QSU_IDXV &&
        qga_o.ack_addr != APU_VGPU_TAW_ADDR &&
        qga_o.status_addr != APU_VGPU_TIW_ADDR);
    `endif
  end
endmodule

// SceneUsedAck (qga) enable-0 fixture: Scene guest ack after that interrupt.
module g6lc_apu_vgpu_qga_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_qsm_t qsm_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qga_cpl_t cpl_o,
  output apu_vgpu_qga_t qga_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_qga #(.Enable(Enable)) i_dut (.*);
endmodule
