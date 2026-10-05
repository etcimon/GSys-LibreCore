// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Descriptor 0 is the header at 64'h8800A000 with NEXT to 1.
// The transfer table and a jump record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_shk. This is
// not g6lc_apu_vgpu_qhx and not g6lc_apu_vgpu_avail. The compiler
// TEX opcode still returns -26. This is not Mesa glReadPixels.

// SceneHeaderAfterNotifyCheck (shx): Header at 64'h8800A000 with NEXT to 1.
module g6lc_apu_vgpu_shx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_shk_t shk_i,
  input  apu_vgpu_shd_t shd_i,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shx_cpl_t cpl_o,
  output apu_vgpu_shx_t shx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign shx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|shk_i) | (|shd_i) | (|srx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_shx_cpl_t cpl_q;
    apu_vgpu_shx_t shx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_shx_cpl_t'('0);
    assign shx_o = shx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        shx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (shx_q.valid) begin
            cpl_q.status <= APU_VGPU_SHX_FAULT;
          end else if (!shk_i.valid || !shd_i.valid || !srx_i.valid) begin
            cpl_q.status <= APU_VGPU_SHX_EMPTY;
          end else if (shk_i.hdr_addr != APU_VGPU_HDR_ADDR ||
                       shk_i.hdr_addr == APU_VGPU_RAB_CMD ||
                       shk_i.hdr_len != APU_VGPU_QSD_LEN ||
                       shk_i.nxt != 16'd1 ||
                       shk_i.nxt == 16'd2 ||
                       shk_i.hdr_addr != shd_i.hdr_addr ||
                       shk_i.nxt != shd_i.nxt ||
                       srx_i.desc_id != APU_VGPU_QRG_DESC ||
                       srx_i.desc_id == 16'd1) begin
            cpl_q.status <= APU_VGPU_SHX_FAULT;
          end else begin
            shx_q.valid <= 1'b1;
            shx_q.hdr_addr <= shk_i.hdr_addr;
            shx_q.nxt <= shk_i.nxt;
            cpl_q.status <= APU_VGPU_SHX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(shx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SHX_OK |->
        shx_o.valid && shx_o.hdr_addr == APU_VGPU_HDR_ADDR &&
        shx_o.nxt == 16'd1);
    `endif
  end
endmodule

// SceneHeaderAfterNotifyCheck (shx) enable-0 fixture: Header at 64'h8800A000 with NEXT to 1.
module g6lc_apu_vgpu_shx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_shk_t shk_i,
  input  apu_vgpu_shd_t shd_i,
  input  apu_vgpu_srx_t srx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_shx_cpl_t cpl_o,
  output apu_vgpu_shx_t shx_o
);
  g6lc_apu_vgpu_shx #(.Enable(Enable)) i_dut (.*);
endmodule
