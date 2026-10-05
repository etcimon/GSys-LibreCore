// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the guest-rung scene NEXT chain. Avail index 1, consumed
// device index 1, execbuffer, and response. A second store keeps
// the first. The transfer table records nothing. This is later
// than g6lc_apu_vgpu_gnw. This is not g6lc_apu_vgpu_nxk and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// GuestNextKeep (gnk): Guest keep of that guest-rung chain.
// Interplay: GuestNextWalk (gnw) <-> GuestNextKeep (gnk)(gnw, sny). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_gnk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnw_t gnw_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gnk_cpl_t cpl_o,
  output apu_vgpu_gnk_t gnk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gnk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gnw_i) | (|sny_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gnk_cpl_t cpl_q;
    apu_vgpu_gnk_t gnk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gnk_cpl_t'('0);
    assign gnk_o = gnk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gnk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gnk_q.valid) begin
            cpl_q.status <= APU_VGPU_GNK_FAULT;
          end else if (!gnw_i.valid || !sny_i.valid) begin
            cpl_q.status <= APU_VGPU_GNK_EMPTY;
          end else if (gnw_i.head != 16'd0 || gnw_i.avail_idx != 16'd1 ||
                       gnw_i.device_idx != 16'd1 ||
                       gnw_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       gnw_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       gnw_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       gnw_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       gnw_i.buf_addr == APU_VGPU_TFB_CMD ||
                       sny_i.qid != APU_VGPU_QNT_QUEUE ||
                       sny_i.avail_idx != 16'd1) begin
            cpl_q.status <= APU_VGPU_GNK_FAULT;
          end else begin
            gnk_q.valid <= 1'b1;
            gnk_q.head <= gnw_i.head;
            gnk_q.avail_idx <= gnw_i.avail_idx;
            gnk_q.device_idx <= gnw_i.device_idx;
            gnk_q.buf_addr <= gnw_i.buf_addr;
            gnk_q.rsp_addr <= gnw_i.rsp_addr;
            cpl_q.status <= APU_VGPU_GNK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gnk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GNK_OK |->
        gnk_o.valid && gnk_o.avail_idx == 16'd1 &&
        gnk_o.device_idx == 16'd1 &&
        gnk_o.buf_addr == APU_VGPU_EXEC_ADDR);
    `endif
  end
endmodule

// GuestNextKeep (gnk) enable-0 fixture: Guest keep of that guest-rung chain.
module g6lc_apu_vgpu_gnk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnw_t gnw_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gnk_cpl_t cpl_o,
  output apu_vgpu_gnk_t gnk_o
);
  g6lc_apu_vgpu_gnk #(.Enable(Enable)) i_dut (.*);
endmodule
