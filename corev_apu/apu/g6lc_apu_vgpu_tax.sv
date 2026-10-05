// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Ack 32'h1 and remain 0 with used.idx 2. The scene ack at
// 64'h8800E510 and index 1 record nothing. This is later than
// g6lc_apu_vgpu_tar. This is not g6lc_apu_vgpu_vak. TEX is not
// the compiler opcode. This is not Mesa glReadPixels.

// TransferAckCheck (tax): Ack 32'h1 and remain 0 with used.idx 2.
module g6lc_apu_vgpu_tax
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tar_t tar_i,
  input  apu_vgpu_taw_t taw_i,
  input  apu_vgpu_tix_t tix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tax_cpl_t cpl_o,
  output apu_vgpu_tax_t tax_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tax_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tar_i) | (|taw_i) | (|tix_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tax_cpl_t cpl_q;
    apu_vgpu_tax_t tax_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tax_cpl_t'('0);
    assign tax_o = tax_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tax_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tax_q.valid) begin
            cpl_q.status <= APU_VGPU_TAX_FAULT;
          end else if (!tar_i.valid || !taw_i.valid || !tix_i.valid) begin
            cpl_q.status <= APU_VGPU_TAX_EMPTY;
          end else if (tar_i.ack != APU_VGPU_TIW_REASON ||
                       tar_i.remain != APU_VGPU_VAW_CLEAR ||
                       tar_i.used_idx != APU_VGPU_TUW_IDXV ||
                       tar_i.used_idx == 16'd1 ||
                       tar_i.ack == tar_i.remain ||
                       tar_i.ack_addr != APU_VGPU_TAW_ADDR ||
                       tar_i.ack_addr == APU_VGPU_VAW_ADDR ||
                       tar_i.status_addr != APU_VGPU_TIW_ADDR ||
                       tar_i.ack != taw_i.ack ||
                       tar_i.remain != taw_i.remain ||
                       tix_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_TAX_FAULT;
          end else begin
            tax_q.valid <= 1'b1;
            tax_q.ack <= tar_i.ack;
            tax_q.remain <= tar_i.remain;
            tax_q.used_idx <= tar_i.used_idx;
            cpl_q.status <= APU_VGPU_TAX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tax_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TAX_OK |->
        tax_o.valid && tax_o.ack == APU_VGPU_TIW_REASON &&
        tax_o.remain == APU_VGPU_VAW_CLEAR &&
        tax_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TransferAckCheck (tax) enable-0 fixture: Ack 32'h1 and remain 0 with used.idx 2.
module g6lc_apu_vgpu_tax_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tar_t tar_i,
  input  apu_vgpu_taw_t taw_i,
  input  apu_vgpu_tix_t tix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tax_cpl_t cpl_o,
  output apu_vgpu_tax_t tax_o
);
  g6lc_apu_vgpu_tax #(.Enable(Enable)) i_dut (.*);
endmodule
