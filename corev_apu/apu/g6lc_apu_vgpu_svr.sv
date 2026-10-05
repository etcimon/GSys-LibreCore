// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read SET_SAMPLER_VIEWS at byte 632 after the inline write is
// accepted. Beat 19 at 64'h8800B260 carries the header in bits
// [223:192]: 3 body dwords, object 0, opcode 10, and the fragment
// stage in bits [255:224]. Beat 20 at 64'h8800B280 carries slot 0
// and sampler-view handle 5. The sampler-state handle in beat 19
// and the inline-write header in beat 20 are not part of this
// check. No texture is bound. This is not g6lc_apu_vgpu_svb and
// not g6lc_apu_vgpu_avail. A failed beat stops the read; the
// request can be repeated. TEX is not executed.

// SamplerViewRead (svr): Sampler view of the fetched draw.
module g6lc_apu_vgpu_svr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_svr_cpl_t cpl_o,
  output apu_vgpu_svr_t svr_o,
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
  localparam logic [31:0] Stage = 32'(APU_VIRGL_SHADER_FRAGMENT);

  function automatic logic beat_bad(input logic beat, input logic [255:0] data);
    if (beat == 1'b0) begin
      beat_bad = data[223:192] != APU_VIRGL_SVB_HDR ||
                 data[255:224] != Stage;
    end else begin
      beat_bad = data[31:0] != 32'h0 ||
                 data[63:32] != APU_VIRGL_SV_HANDLE;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign svr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|cxr_i) | (|cwr_i) | (|fbr_i) |
                        (|vbf_i) | (|iwr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_svr_cpl_t cpl_q;
    apu_vgpu_svr_t svr_q;
    logic beat_q;
    logic [31:0] stage_q, slot_q, handle_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_svr_cpl_t'('0);
    assign svr_o = svr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        svr_q <= '0;
        beat_q <= 1'b0;
        stage_q <= '0;
        slot_q <= '0;
        handle_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (svr_q.valid) begin
            cpl_q.status <= APU_VGPU_SVR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid || !cwr_i.valid ||
                       !fbr_i.valid || !vbf_i.valid || !iwr_i.valid) begin
            cpl_q.status <= APU_VGPU_SVR_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE ||
                       vwx_i.x_neg != 16'd0 || vwx_i.y_neg != 16'd0 ||
                       vwx_i.x_pos != 16'd640 || vwx_i.y_pos != 16'd480 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       vbf_i.stride != APU_VIRGL_VERT_STRIDE ||
                       vbf_i.offset != 32'h0 ||
                       vbf_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       iwr_i.resource != vbf_i.resource) begin
            cpl_q.status <= APU_VGPU_SVR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            stage_q <= '0;
            slot_q <= '0;
            handle_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_SVB_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            stage_q <= rd_rsp_data_i[255:224];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_SVB_LAST;
            state_q <= Issue;
          end else begin
            slot_q <= rd_rsp_data_i[31:0];
            handle_q <= rd_rsp_data_i[63:32];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || stage_q != Stage || slot_q != 32'h0 ||
              handle_q != APU_VIRGL_SV_HANDLE ||
              stage_q == slot_q || handle_q == stage_q)
            cpl_q.status <= APU_VGPU_SVR_FAULT;
          else begin
            svr_q.valid <= 1'b1;
            svr_q.stage <= stage_q;
            svr_q.slot <= slot_q;
            svr_q.handle <= handle_q;
            cpl_q.status <= APU_VGPU_SVR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(svr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SVR_OK |->
        svr_o.valid && svr_o.stage == Stage && svr_o.slot == 32'h0 &&
        svr_o.handle == APU_VIRGL_SV_HANDLE && svr_o.stage != svr_o.slot &&
        svr_o.handle != svr_o.stage);
    `endif
  end
endmodule

// SamplerViewRead (svr) enable-0 fixture: Sampler view of the fetched draw.
module g6lc_apu_vgpu_svr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_svr_cpl_t cpl_o,
  output apu_vgpu_svr_t svr_o,
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
  g6lc_apu_vgpu_svr #(.Enable(Enable)) i_dut (.*);
endmodule
