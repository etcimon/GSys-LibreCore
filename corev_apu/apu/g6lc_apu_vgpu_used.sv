// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One local virtq_used element for a virtio-gpu response. The element is
// stored first. used.idx advances on the next cycle, and that advance is
// the publication. IRQ rises with the index and stays high until ack.
// A cancel after the element and before the index does not publish and
// does not raise IRQ. Queue length is 8. This does not read an avail ring
// and does not write guest memory.

// UsedPublish (used): Local used-element publication and its interrupt.
// Interplay: UsedPublish (used) --? UsedGuestWrite (uwr) --? UsedIndexStore (uidx). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_used
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_used_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_used_cpl_t cpl_o,
  output logic [15:0] idx_o,
  output logic irq_o,
  output logic pending_o,
  input  logic [2:0] peek_i,
  output logic [31:0] peek_id_o,
  output logic [31:0] peek_len_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign idx_o = '0;
    assign irq_o = 1'b0;
    assign pending_o = 1'b0;
    assign peek_id_o = '0;
    assign peek_len_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | irq_ack_i | req_valid_i |
                        cpl_ready_i | (|req_i) | (|peek_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Elem, Publish, Done } state_e;
    state_e state_q;
    apu_vgpu_used_req_t req_q;
    apu_vgpu_used_cpl_t cpl_q;
    logic [31:0] id_q [0:APU_VGPU_USED_NUM-1];
    logic [31:0] len_q [0:APU_VGPU_USED_NUM-1];
    logic [15:0] idx_q;
    logic irq_q, armed_q;
    logic [2:0] slot;

    assign slot = idx_q[2:0];
    assign idx_o = idx_q;
    assign irq_o = irq_q;
    assign pending_o = state_q == Elem;
    assign peek_id_o = id_q[peek_i];
    assign peek_len_o = len_q[peek_i];
    assign req_ready_o = state_q == Idle && rst_ni && !cancel_i;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_used_cpl_t'('0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        req_q <= '0;
        cpl_q <= '0;
        idx_q <= '0;
        irq_q <= 1'b0;
        armed_q <= 1'b0;
        for (int i = 0; i < APU_VGPU_USED_NUM; i++) begin
          id_q[i] <= '0;
          len_q[i] <= '0;
        end
      end else begin
        if (state_q == Publish) irq_q <= 1'b1;
        else if (irq_ack_i) irq_q <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            req_q <= req_i;
            cpl_q.idx <= idx_q;
            cpl_q.desc_id <= req_i.desc_id;
            cpl_q.len <= req_i.len;
            if (req_i.idx != idx_q || req_i.len != VGPU_RESP_HDR_BYTES) begin
              cpl_q.ok <= 1'b0;
              state_q <= Done;
            end else begin
              id_q[slot] <= req_i.desc_id;
              len_q[slot] <= req_i.len;
              state_q <= Elem;
            end
          end
          Elem: begin
            if (cancel_i) begin
              cpl_q.ok <= 1'b0;
              state_q <= Done;
            end else begin
              idx_q <= idx_q + 16'd1;
              cpl_q.ok <= 1'b1;
              cpl_q.idx <= idx_q + 16'd1;
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
      pending_o |-> irq_o == 1'b0 && idx_o == $past(idx_o));
    `endif
  end
endmodule

// UsedPublish (used) enable-0 fixture: Local used-element publication and its interrupt.
module g6lc_apu_vgpu_used_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vgpu_used_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_used_cpl_t cpl_o,
  output logic [15:0] idx_o,
  output logic irq_o,
  output logic pending_o,
  input  logic [2:0] peek_i,
  output logic [31:0] peek_id_o,
  output logic [31:0] peek_len_o
);
  g6lc_apu_vgpu_used #(.Enable(Enable)) i_dut (.*);
endmodule
