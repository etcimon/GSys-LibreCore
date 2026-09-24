// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the scene clear word across a 64 by 64 guest window at
// 64'h88020000. Each beat is eight copies of 32'hFF1A0D0D. 512 beats
// is 16384 bytes. The bytes are not kept in registers. A 64-high
// scissor records nothing. This is not g6lc_apu_vgpu_rbf and not
// g6lc_apu_vgpu_frd. The shader is not run. This is not the screenshot.
// A failed beat stops the write; the request can be repeated.

module g6lc_apu_vgpu_gpw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpw_cpl_t cpl_o,
  output apu_vgpu_gpw_t gpw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [APU_VGPU_BEAT_BYTES*8-1:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  function automatic logic [63:0] beat_addr(input logic [8:0] beat);
    beat_addr = APU_VGPU_GPW_ADDR + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gpw_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|ols_i) | (|nxc_i) |
                        (|cwr_i) | (|cxr_i) | (|fbr_i) | (|fet_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gpw_cpl_t cpl_q;
    apu_vgpu_gpw_t gpw_q;
    logic [8:0] beat_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign wr_data_o = Pat;
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gpw_cpl_t'('0);
    assign gpw_o = gpw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gpw_q <= '0;
        beat_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gpw_q.valid) begin
            cpl_q.status <= APU_VGPU_GPW_FAULT;
            state_q <= Done;
          end else if (!ols_i.valid || !nxc_i.valid || !cwr_i.valid ||
                       !cxr_i.valid || !fbr_i.valid || !fet_i.valid) begin
            cpl_q.status <= APU_VGPU_GPW_EMPTY;
            state_q <= Done;
          end else if (ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA ||
                       ols_i.capset_id == APU_VGPU_CAPSET_VIRGL ||
                       nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                       nxc_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       nxc_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       fbr_i.nr_cbufs != 32'd1 ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_GPW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 9'd0;
            bad_q <= 1'b0;
            addr_q <= beat_addr(9'd0);
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == APU_VGPU_GPW_LAST) begin
            state_q <= Commit;
          end else begin
            beat_q <= beat_q + 9'd1;
            addr_q <= beat_addr(beat_q + 9'd1);
            state_q <= Issue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GPW_LAST || cwr_i.word != APU_VGPU_CLEAR_WORD)
            cpl_q.status <= APU_VGPU_GPW_FAULT;
          else begin
            gpw_q.valid <= 1'b1;
            gpw_q.beats <= APU_VGPU_GPW_BEATS;
            gpw_q.word <= APU_VGPU_CLEAR_WORD;
            gpw_q.base <= APU_VGPU_GPW_ADDR;
            cpl_q.status <= APU_VGPU_GPW_OK;
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
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GPW_OK |->
        gpw_o.valid && gpw_o.beats == APU_VGPU_GPW_BEATS &&
        gpw_o.word == APU_VGPU_CLEAR_WORD && gpw_o.base == APU_VGPU_GPW_ADDR);
    `endif
  end
endmodule

module g6lc_apu_vgpu_gpw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpw_cpl_t cpl_o,
  output apu_vgpu_gpw_t gpw_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_gpw #(.Enable(Enable)) i_dut (.*);
endmodule
