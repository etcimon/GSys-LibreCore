// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Reason 32'h1 at 64'h880C0000 with used.idx 2 after the guest
// used ring after scene guest ack. The scene status word at
// 64'h8800E500 records nothing. Index 1 records nothing. This
// is later than g6lc_apu_vgpu_rir. This is not
// g6lc_apu_vgpu_qix and not g6lc_apu_vgpu_tix. The pin is not
// kept. TEX is not the compiler opcode. This is not Mesa
// glReadPixels.

// TransferIrqAfterAckCheck (rix): Reason 32'h1 at 64'h880C0000 after scene guest ack.
module g6lc_apu_vgpu_rix
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rir_t rir_i,
  input  apu_vgpu_riw_t riw_i,
  input  apu_vgpu_rux_t rux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rix_cpl_t cpl_o,
  output apu_vgpu_rix_t rix_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rix_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rir_i) | (|riw_i) | (|rux_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rix_cpl_t cpl_q;
    apu_vgpu_rix_t rix_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rix_cpl_t'('0);
    assign rix_o = rix_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rix_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rix_q.valid) begin
            cpl_q.status <= APU_VGPU_RIX_FAULT;
          end else if (!rir_i.valid || !riw_i.valid || !rux_i.valid) begin
            cpl_q.status <= APU_VGPU_RIX_EMPTY;
          end else if (rir_i.reason != APU_VGPU_TIW_REASON ||
                       rir_i.used_idx != APU_VGPU_TUW_IDXV ||
                       rir_i.used_idx == 16'd1 ||
                       rir_i.addr != APU_VGPU_TIW_ADDR ||
                       rir_i.addr == APU_VGPU_VIW_ADDR ||
                       rir_i.reason != riw_i.reason ||
                       rir_i.used_idx != riw_i.used_idx ||
                       rux_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_RIX_FAULT;
          end else begin
            rix_q.valid <= 1'b1;
            rix_q.reason <= rir_i.reason;
            rix_q.used_idx <= rir_i.used_idx;
            rix_q.addr <= rir_i.addr;
            cpl_q.status <= APU_VGPU_RIX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rix_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RIX_OK |->
        rix_o.valid && rix_o.reason == APU_VGPU_TIW_REASON &&
        rix_o.used_idx == APU_VGPU_TUW_IDXV &&
        rix_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferIrqAfterAckCheck (rix) enable-0 fixture: Reason 32'h1 at 64'h880C0000 after scene guest ack.
module g6lc_apu_vgpu_rix_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rir_t rir_i,
  input  apu_vgpu_riw_t riw_i,
  input  apu_vgpu_rux_t rux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rix_cpl_t cpl_o,
  output apu_vgpu_rix_t rix_o
);
  g6lc_apu_vgpu_rix #(.Enable(Enable)) i_dut (.*);
endmodule
