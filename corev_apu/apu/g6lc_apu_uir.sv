// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailUsed then virtio used-buffer ISR (VIRTIO_MMIO_INT_VRING = 1).
// Guest ack of bit 0 lowers the pin. EMPTY and FAULT raise no IRQ.
// Enable=0 elaborates no datapath. Does not edit g6lc_apu_vgpu_avail.
// Not wired into g6lc_apu_sys. FeatureVirgl stays illegal.

// UsedIrq (uir): AvailUsed then virtio used-buffer ISR. Default-off. FeatureVirgl stays illegal.
// Interplay: UsedIrq (uir) --> AvailUsed (avu) ==> ISR bit 0. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_uir
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_uir_cpl_t cpl_o,
  output apu_uir_t uir_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
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
  input  logic wr_rsp_ok_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign uir_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|ack_i) |
                    (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, FireAvu, WaitAvu, Done } state_e;
    state_e state_q;
    apu_uir_cpl_t cpl_q;
    apu_uir_t rec_q;
    logic [31:0] isr_q;
    logic avu_req_v, avu_rdy, avu_cpl, avu_ack;
    apu_avu_req_t req_q;
    apu_avu_cpl_t avu_c;
    apu_avu_t avu_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_uir_cpl_t'('0);
    assign uir_o = rec_q;
    assign irq_o = isr_q[0];
    assign isr_o = isr_q;
    assign avu_req_v = state_q == FireAvu;
    assign avu_ack = state_q == WaitAvu;

    g6lc_apu_avu #(.Enable(1'b1)) i_avu (
      .clk_i, .rst_ni,
      .req_valid_i(avu_req_v), .req_ready_o(avu_rdy), .req_i(req_q),
      .cpl_valid_o(avu_cpl), .cpl_ready_i(avu_ack), .cpl_o(avu_c), .avu_o(avu_rec),
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o, .rd_rsp_ok_i,
      .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o, .wr_ready_i, .wr_addr_o, .wr_len_o, .wr_data_o,
      .wr_rsp_valid_i, .wr_rsp_ready_o, .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        isr_q <= '0;
        req_q <= '0;
      end else begin
        if (ack_valid_i && ack_i[0]) isr_q[0] <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            req_q <= req_i;
            state_q <= FireAvu;
          end
          FireAvu: if (avu_rdy) state_q <= WaitAvu;
          WaitAvu: if (avu_cpl) begin
            if (avu_c.status == APU_AVU_EMPTY) begin
              cpl_q.status <= APU_UIR_EMPTY;
              rec_q.isr <= isr_q;
              rec_q.irq <= isr_q[0];
              state_q <= Done;
            end else if (avu_c.status != APU_AVU_OK || !avu_rec.valid) begin
              cpl_q.status <= APU_UIR_FAULT;
              rec_q.isr <= isr_q;
              rec_q.irq <= isr_q[0];
              state_q <= Done;
            end else begin
              isr_q <= APU_UIR_ISR_VRING;
              rec_q.valid <= 1'b1;
              rec_q.irq <= 1'b1;
              rec_q.isr <= APU_UIR_ISR_VRING;
              rec_q.used_idx <= avu_rec.used_idx;
              rec_q.desc_id <= avu_rec.desc_id;
              cpl_q.status <= APU_UIR_OK;
              state_q <= Done;
            end
          end
          Done: if (cpl_ready_i) state_q <= Idle;
          default: state_q <= Idle;
        endcase
      end
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// UsedIrq (uir) enable-0 fixture: AvailUsed then used-buffer ISR.
module g6lc_apu_uir_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avu_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_uir_cpl_t cpl_o,
  output apu_uir_t uir_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
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
  input  logic wr_rsp_ok_i
);
  g6lc_apu_uir #(.Enable(Enable)) i_dut (.*);
endmodule
