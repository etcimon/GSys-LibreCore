// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the completed-opcode list at 64'h8800E300 after the scene chain
// is accepted and the virgl capset request is still refused. The count
// word is 0 and the capset id is 0. A nonzero count or virgl id 1
// records nothing. No caps blob is stored. This is not
// g6lc_apu_vgpu_cap and not g6lc_apu_vgpu_nfo. FeatureVirgl stays off.
// A failed beat stops the read; the request can be repeated.

// OpcodeList (ols): Completed-opcode list. Default-off. The list is empty.
module g6lc_apu_vgpu_ols
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cap_t cap_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ols_cpl_t cpl_o,
  output apu_vgpu_ols_t ols_o,
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

  function automatic logic beat_bad(input logic [255:0] data);
    beat_bad = data[31:0] != 32'h0 || data[63:32] != 32'h0;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ols_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|nxc_i) | (|cap_i) |
                        (|nfo_i) | (|sfc_i) | (|fet_i) | (|qdr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_ols_cpl_t cpl_q;
    apu_vgpu_ols_t ols_q;
    logic [31:0] count_q, id_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ols_cpl_t'('0);
    assign ols_o = ols_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ols_q <= '0;
        count_q <= '0;
        id_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ols_q.valid) begin
            cpl_q.status <= APU_VGPU_OLS_FAULT;
            state_q <= Done;
          end else if (!nxc_i.valid || !sfc_i.valid || !fet_i.valid ||
                       !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_OLS_EMPTY;
            state_q <= Done;
          end else if (nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                       nxc_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       nxc_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       nxc_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       !cap_i.refused ||
                       cap_i.resp != VGPU_RESP_ERR_INVALID_PARAMETER ||
                       !nfo_i.refused ||
                       nfo_i.resp != VGPU_RESP_ERR_INVALID_PARAMETER ||
                       sfc_i.hdr != APU_VIRGL_SF_HDR ||
                       sfc_i.handle != APU_VIRGL_SURFACE_HANDLE ||
                       sfc_i.resource != APU_VIRGL_RES_RT ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE) begin
            cpl_q.status <= APU_VGPU_OLS_FAULT;
            state_q <= Done;
          end else begin
            count_q <= '0;
            id_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_OLS_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(rd_rsp_data_i)) bad_q <= 1'b1;
          else begin
            count_q <= rd_rsp_data_i[31:0];
            id_q <= rd_rsp_data_i[63:32];
          end
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || count_q != 32'h0 || id_q != 32'h0 ||
              count_q == APU_VGPU_CAPSET_VIRGL ||
              id_q == APU_VGPU_CAPSET_VIRGL ||
              id_q == 32'(APU_VIRGL_DRAW_VBO) ||
              count_q == 32'(APU_VIRGL_CREATE_OBJECT))
            cpl_q.status <= APU_VGPU_OLS_FAULT;
          else begin
            ols_q.valid <= 1'b1;
            ols_q.count <= count_q;
            ols_q.capset_id <= id_q;
            ols_q.resp <= VGPU_RESP_OK_NODATA;
            cpl_q.status <= APU_VGPU_OLS_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ols_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_OLS_OK |->
        ols_o.valid && ols_o.count == 32'h0 && ols_o.capset_id == 32'h0 &&
        ols_o.resp == VGPU_RESP_OK_NODATA &&
        ols_o.capset_id != APU_VGPU_CAPSET_VIRGL);
    `endif
  end
endmodule

// OpcodeList (ols) enable-0 fixture: Completed-opcode list. Default-off. The list is empty.
module g6lc_apu_vgpu_ols_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_cap_t cap_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ols_cpl_t cpl_o,
  output apu_vgpu_ols_t ols_o,
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
  g6lc_apu_vgpu_ols #(.Enable(Enable)) i_dut (.*);
endmodule
