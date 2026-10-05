// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 2 at 64'h880D0100 after QueueNotify of queue 0
// after scene guest ack. The scene index 1 and the scene ring
// record nothing. A second store keeps the first. This is later
// than g6lc_apu_vgpu_rak. This is not g6lc_apu_vgpu_qax and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferAvailAfterAckCheck (ray): Avail index 2 at 64'h880D0100 after scene guest ack.
module g6lc_apu_vgpu_ray
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rak_t rak_i,
  input  apu_vgpu_rav_t rav_i,
  input  apu_vgpu_rny_t rny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ray_cpl_t cpl_o,
  output apu_vgpu_ray_t ray_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ray_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rak_i) | (|rav_i) | (|rny_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ray_cpl_t cpl_q;
    apu_vgpu_ray_t ray_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ray_cpl_t'('0);
    assign ray_o = ray_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ray_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ray_q.valid) begin
            cpl_q.status <= APU_VGPU_RAY_FAULT;
          end else if (!rak_i.valid || !rav_i.valid || !rny_i.valid) begin
            cpl_q.status <= APU_VGPU_RAY_EMPTY;
          end else if (rak_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rak_i.avail_idx == 16'd1 ||
                       rak_i.addr != APU_VGPU_QAV_ADDR ||
                       rak_i.addr == APU_VGPU_NXC_AVAIL ||
                       rak_i.avail_idx != rav_i.avail_idx ||
                       rny_i.qid != APU_VGPU_QNT_QUEUE ||
                       rny_i.qid == APU_VGPU_QNT_CURSOR ||
                       rny_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_RAY_FAULT;
          end else begin
            ray_q.valid <= 1'b1;
            ray_q.avail_idx <= rak_i.avail_idx;
            cpl_q.status <= APU_VGPU_RAY_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ray_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RAY_OK |->
        ray_o.valid && ray_o.avail_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TransferAvailAfterAckCheck (ray) enable-0 fixture: Avail index 2 at 64'h880D0100 after scene guest ack.
module g6lc_apu_vgpu_ray_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rak_t rak_i,
  input  apu_vgpu_rav_t rav_i,
  input  apu_vgpu_rny_t rny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ray_cpl_t cpl_o,
  output apu_vgpu_ray_t ray_o
);
  g6lc_apu_vgpu_ray #(.Enable(Enable)) i_dut (.*);
endmodule
