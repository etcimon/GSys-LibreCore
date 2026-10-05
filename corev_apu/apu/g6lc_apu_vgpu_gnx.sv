// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Guest-rung scene chain: avail index 1, consumed device index
// 1, NEXT from header to execbuffer to WRITE. The transfer
// avail index 2 records nothing. A second store keeps the first.
// This is later than g6lc_apu_vgpu_gnk. This is not
// g6lc_apu_vgpu_avail. g6lc_apu_vgpu_avail still rejects NEXT.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// GuestNextCheck (gnx): Avail index 1 with consumed device index 1.
// Interplay: GuestNextKeep (gnk) <-> GuestNextCheck (gnx)(gnk, gnw, sny). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_gnx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnk_t gnk_i,
  input  apu_vgpu_gnw_t gnw_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gnx_cpl_t cpl_o,
  output apu_vgpu_gnx_t gnx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gnx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gnk_i) | (|gnw_i) | (|sny_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gnx_cpl_t cpl_q;
    apu_vgpu_gnx_t gnx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gnx_cpl_t'('0);
    assign gnx_o = gnx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gnx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gnx_q.valid) begin
            cpl_q.status <= APU_VGPU_GNX_FAULT;
          end else if (!gnk_i.valid || !gnw_i.valid || !sny_i.valid) begin
            cpl_q.status <= APU_VGPU_GNX_EMPTY;
          end else if (gnk_i.avail_idx != 16'd1 ||
                       gnk_i.device_idx != 16'd1 ||
                       gnk_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       gnk_i.head != 16'd0 ||
                       gnk_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       gnk_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       gnk_i.buf_addr != gnw_i.buf_addr ||
                       sny_i.qid != APU_VGPU_QNT_QUEUE) begin
            cpl_q.status <= APU_VGPU_GNX_FAULT;
          end else begin
            gnx_q.valid <= 1'b1;
            gnx_q.avail_idx <= gnk_i.avail_idx;
            gnx_q.device_idx <= gnk_i.device_idx;
            gnx_q.buf_addr <= gnk_i.buf_addr;
            cpl_q.status <= APU_VGPU_GNX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gnx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GNX_OK |->
        gnx_o.valid && gnx_o.avail_idx == 16'd1 &&
        gnx_o.device_idx == 16'd1 &&
        gnx_o.buf_addr == APU_VGPU_EXEC_ADDR);
    `endif
  end
endmodule

// GuestNextCheck (gnx) enable-0 fixture: Avail index 1 with consumed device index 1.
module g6lc_apu_vgpu_gnx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnk_t gnk_i,
  input  apu_vgpu_gnw_t gnw_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gnx_cpl_t cpl_o,
  output apu_vgpu_gnx_t gnx_o
);
  g6lc_apu_vgpu_gnx #(.Enable(Enable)) i_dut (.*);
endmodule
