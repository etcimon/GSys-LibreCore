// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Fetch the scene header and the 960-byte execbuffer after the
// guest-rung NEXT walk consumed device index 1. One 32-byte
// SUBMIT_3D header at 64'h8800A000, then 30 beats at 64'h8800B000.
// The first command word is the surface CREATE_OBJECT. The buffer
// is not kept. Transfer dest and an unconsumed device index record
// nothing. This is later than g6lc_apu_vgpu_gnx. This is not
// g6lc_apu_vgpu_fet and not g6lc_apu_vgpu_avail.
// g6lc_apu_vgpu_avail still rejects NEXT. TEX is not executed.

// GuestExecFetch (gef): Fetch the execbuffer after GuestNextCheck (gnx).
// Interplay: GuestNextCheck (gnx) <-> GuestExecFetch (gef)(gnx). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_gef
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gef_cpl_t cpl_o,
  output apu_vgpu_gef_t gef_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  function automatic logic [63:0] exec_addr(input logic [5:0] beat);
    exec_addr = APU_VGPU_EXEC_ADDR + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gef_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gnx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gef_cpl_t cpl_q;
    apu_vgpu_gef_t gef_q;
    logic hdr_q;
    logic [5:0] beat_q;
    logic [31:0] cmd0_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gef_cpl_t'('0);
    assign gef_o = gef_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gef_q <= '0;
        hdr_q <= 1'b0;
        beat_q <= '0;
        cmd0_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gef_q.valid) begin
            cpl_q.status <= APU_VGPU_GEF_FAULT;
            state_q <= Done;
          end else if (!gnx_i.valid) begin
            cpl_q.status <= APU_VGPU_GEF_EMPTY;
            state_q <= Done;
          end else if (gnx_i.avail_idx != 16'd1 ||
                       gnx_i.device_idx != 16'd1 ||
                       gnx_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       gnx_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       gnx_i.buf_addr == APU_VGPU_TFB_CMD) begin
            cpl_q.status <= APU_VGPU_GEF_FAULT;
            state_q <= Done;
          end else begin
            hdr_q <= 1'b1;
            beat_q <= '0;
            cmd0_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_HDR_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic [31:0] kind, flags, ctx, pad, size, tail;
          logic bad_hdr;
          kind = rd_rsp_data_i[31:0];
          flags = rd_rsp_data_i[63:32];
          ctx = rd_rsp_data_i[159:128];
          pad = rd_rsp_data_i[191:160];
          size = rd_rsp_data_i[223:192];
          tail = rd_rsp_data_i[255:224];
          bad_hdr = kind != VGPU_CMD_SUBMIT_3D || |flags[31:1] ||
                    ctx != 32'd1 || pad != 32'h0 || tail != 32'h0 ||
                    size != APU_VGPU_SCENE_BYTES;
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              rd_rsp_addr_i == APU_VGPU_TFB_CMD) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (hdr_q && bad_hdr) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (!hdr_q && beat_q == 6'd0 && kind != Cmd0) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (hdr_q) begin
            hdr_q <= 1'b0;
            beat_q <= '0;
            addr_q <= exec_addr(6'd0);
            state_q <= Issue;
          end else begin
            if (beat_q == 6'd0) cmd0_q <= kind;
            if (beat_q == APU_VGPU_EXEC_BEATS - 6'd1) state_q <= Commit;
            else begin
              beat_q <= beat_q + 6'd1;
              addr_q <= exec_addr(beat_q + 6'd1);
              state_q <= Issue;
            end
          end
        end
        Commit: begin
          if (bad_q || cmd0_q != Cmd0) cpl_q.status <= APU_VGPU_GEF_FAULT;
          else begin
            gef_q.valid <= 1'b1;
            gef_q.kind <= VGPU_CMD_SUBMIT_3D;
            gef_q.cmd0 <= cmd0_q;
            gef_q.beats <= APU_VGPU_EXEC_BEATS;
            gef_q.device_idx <= 16'd1;
            cpl_q.status <= APU_VGPU_GEF_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GEF_OK |->
        gef_o.valid && gef_o.beats == APU_VGPU_EXEC_BEATS &&
        gef_o.kind == VGPU_CMD_SUBMIT_3D && gef_o.device_idx == 16'd1);
    `endif
  end
endmodule

// GuestExecFetch (gef) enable-0 fixture: Fetch the execbuffer after GuestNextCheck (gnx).
module g6lc_apu_vgpu_gef_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gef_cpl_t cpl_o,
  output apu_vgpu_gef_t gef_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_gef #(.Enable(Enable)) i_dut (.*);
endmodule
