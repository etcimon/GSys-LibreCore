// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the completed-opcode count, capset id 0, and the response.
// A second store keeps the first. No caps blob is kept. This is not
// g6lc_apu_vgpu_cap. FeatureVirgl stays off.

module g6lc_apu_vgpu_olk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cap_t cap_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_olk_cpl_t cpl_o,
  output apu_vgpu_olk_t olk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign olk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ols_i) | (|nxc_i) | (|cap_i) | (|nfo_i) | (|fet_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_olk_cpl_t cpl_q;
    apu_vgpu_olk_t olk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_olk_cpl_t'('0);
    assign olk_o = olk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        olk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (olk_q.valid) begin
            cpl_q.status <= APU_VGPU_OLK_FAULT;
          end else if (!ols_i.valid || !nxc_i.valid || !fet_i.valid) begin
            cpl_q.status <= APU_VGPU_OLK_EMPTY;
          end else if (ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA ||
                       ols_i.capset_id == APU_VGPU_CAPSET_VIRGL ||
                       ols_i.count == ols_i.resp ||
                       nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                       nxc_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       !cap_i.refused ||
                       cap_i.resp != VGPU_RESP_ERR_INVALID_PARAMETER ||
                       !nfo_i.refused ||
                       nfo_i.resp != VGPU_RESP_ERR_INVALID_PARAMETER ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_OLK_FAULT;
          end else begin
            olk_q.valid <= 1'b1;
            olk_q.count <= ols_i.count;
            olk_q.capset_id <= ols_i.capset_id;
            olk_q.resp <= ols_i.resp;
            cpl_q.status <= APU_VGPU_OLK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(olk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_olk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cap_t cap_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_olk_cpl_t cpl_o,
  output apu_vgpu_olk_t olk_o
);
  g6lc_apu_vgpu_olk #(.Enable(Enable)) i_dut (.*);
endmodule
