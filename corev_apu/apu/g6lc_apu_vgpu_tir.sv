// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the used-buffer interrupt reason at 64'h880C0000. The low
// word is 32'h1. The scene status word at 64'h8800E500 records
// nothing. The pin may already have been acknowledged. This is
// later than g6lc_apu_vgpu_tiw. This is not g6lc_apu_vgpu_vir.
// The image is not kept. TEX is not the compiler opcode. This is
// not Mesa glReadPixels.

// TransferIrqRead (tir): Guest read of that interrupt reason.
module g6lc_apu_vgpu_tir
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tiw_t tiw_i,
  input  apu_vgpu_tux_t tux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tir_cpl_t cpl_o,
  output apu_vgpu_tir_t tir_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tir_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|tiw_i) | (|tux_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_tir_cpl_t cpl_q;
    apu_vgpu_tir_t tir_q;
    logic [31:0] reason_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = APU_VGPU_TIW_ADDR;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tir_cpl_t'('0);
    assign tir_o = tir_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tir_q <= '0;
        reason_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tir_q.valid) begin
            cpl_q.status <= APU_VGPU_TIR_FAULT;
            state_q <= Done;
          end else if (!tiw_i.valid || !tux_i.valid) begin
            cpl_q.status <= APU_VGPU_TIR_EMPTY;
            state_q <= Done;
          end else if (tiw_i.reason != APU_VGPU_TIW_REASON ||
                       tiw_i.used_idx != APU_VGPU_TUW_IDXV ||
                       tiw_i.used_idx == 16'd1 ||
                       tiw_i.addr != APU_VGPU_TIW_ADDR ||
                       tiw_i.addr == APU_VGPU_VIW_ADDR ||
                       tux_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_TIR_FAULT;
            state_q <= Done;
          end else begin
            reason_q <= '0;
            bad_q <= 1'b0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != APU_VGPU_TIW_ADDR ||
                    rd_rsp_addr_i == APU_VGPU_VIW_ADDR ||
                    rd_rsp_len_i != 32'd4 ||
                    rd_rsp_data_i[31:0] != APU_VGPU_TIW_REASON;
          if (bad_bus) bad_q <= 1'b1;
          else reason_q <= rd_rsp_data_i[31:0];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || reason_q != APU_VGPU_TIW_REASON ||
              reason_q != tiw_i.reason)
            cpl_q.status <= APU_VGPU_TIR_FAULT;
          else begin
            tir_q.valid <= 1'b1;
            tir_q.reason <= reason_q;
            tir_q.used_idx <= tiw_i.used_idx;
            tir_q.addr <= APU_VGPU_TIW_ADDR;
            cpl_q.status <= APU_VGPU_TIR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tir_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TIR_OK |->
        tir_o.valid && tir_o.reason == APU_VGPU_TIW_REASON &&
        tir_o.used_idx == APU_VGPU_TUW_IDXV &&
        tir_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferIrqRead (tir) enable-0 fixture: Guest read of that interrupt reason.
module g6lc_apu_vgpu_tir_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tiw_t tiw_i,
  input  apu_vgpu_tux_t tux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tir_cpl_t cpl_o,
  output apu_vgpu_tir_t tir_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_tir #(.Enable(Enable)) i_dut (.*);
endmodule
