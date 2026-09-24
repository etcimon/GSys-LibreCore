// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One local used element for the linked scene chain. Descriptor 0,
// length 24, is stored first. used.idx advances on the next cycle and
// that advance is the publication. IRQ rises with the index. A cancel
// after the element and before the index does not publish. This does
// not write guest memory and it is not g6lc_apu_vgpu_used.

module g6lc_apu_vgpu_sun
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_cmx_t cmx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sun_cpl_t cpl_o,
  output apu_vgpu_sun_t sun_o,
  output logic [15:0] idx_o,
  output logic irq_o,
  output logic pending_o,
  output logic [31:0] elem_id_o,
  output logic [31:0] elem_len_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sun_o = '0;
    assign idx_o = '0;
    assign irq_o = 1'b0;
    assign pending_o = 1'b0;
    assign elem_id_o = '0;
    assign elem_len_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | irq_ack_i | req_valid_i |
                        cpl_ready_i | (|cmx_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Elem, Publish, Done } state_e;
    state_e state_q;
    apu_vgpu_sun_cpl_t cpl_q;
    apu_vgpu_sun_t sun_q;
    logic [31:0] id_q, len_q;
    logic [15:0] idx_q;
    logic irq_q, armed_q;

    assign idx_o = idx_q;
    assign irq_o = irq_q;
    assign pending_o = state_q == Elem;
    assign elem_id_o = id_q;
    assign elem_len_o = len_q;
    assign req_ready_o = state_q == Idle && rst_ni && !cancel_i;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sun_cpl_t'('0);
    assign sun_o = sun_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sun_q <= '0;
        id_q <= '0;
        len_q <= '0;
        idx_q <= '0;
        irq_q <= 1'b0;
        armed_q <= 1'b0;
      end else begin
        if (state_q == Publish) irq_q <= 1'b1;
        else if (irq_ack_i) irq_q <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            if (sun_q.valid) begin
              cpl_q.status <= APU_VGPU_SUN_FAULT;
              state_q <= Done;
            end else if (!cmx_i.linked) begin
              cpl_q.status <= APU_VGPU_SUN_EMPTY;
              state_q <= Done;
            end else begin
              id_q <= 32'd0;
              len_q <= VGPU_RESP_HDR_BYTES;
              state_q <= Elem;
            end
          end
          Elem: begin
            if (cancel_i) begin
              cpl_q.status <= APU_VGPU_SUN_FAULT;
              state_q <= Done;
            end else begin
              idx_q <= idx_q + 16'd1;
              sun_q.valid <= 1'b1;
              sun_q.idx <= idx_q + 16'd1;
              sun_q.desc_id <= 32'd0;
              sun_q.len <= VGPU_RESP_HDR_BYTES;
              cpl_q.status <= APU_VGPU_SUN_OK;
              state_q <= Publish;
            end
          end
          Publish: state_q <= Done;
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
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(sun_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      pending_o |-> irq_o == 1'b0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SUN_OK |->
        sun_o.valid && sun_o.idx == 16'd1 && sun_o.desc_id == 32'd0 &&
        sun_o.len == VGPU_RESP_HDR_BYTES);
    `endif
  end
endmodule

module g6lc_apu_vgpu_sun_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_cmx_t cmx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sun_cpl_t cpl_o,
  output apu_vgpu_sun_t sun_o,
  output logic [15:0] idx_o,
  output logic irq_o,
  output logic pending_o,
  output logic [31:0] elem_id_o,
  output logic [31:0] elem_len_o
);
  g6lc_apu_vgpu_sun #(.Enable(Enable)) i_dut (.*);
endmodule
