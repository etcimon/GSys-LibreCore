// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the scene descriptor chain from guest memory after the surface
// is accepted. Beat 0 at 64'h8800E100 carries descriptor 0 (header at
// 64'h8800A000, NEXT to 1) and descriptor 1 (960 bytes at 64'h8800B000,
// NEXT to 2). Beat 1 carries descriptor 2 (24-byte WRITE at
// 64'h8800A800). Beat 2 at 64'h8800E200 is avail index 1 naming
// descriptor 0. INDIRECT, a broken link, and a jumped index record
// nothing. This is not g6lc_apu_vgpu_avail and not g6lc_apu_vgpu_chn.
// g6lc_apu_vgpu_avail still rejects NEXT. A failed beat stops the read.

module g6lc_apu_vgpu_nxc
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_nxc_cpl_t cpl_o,
  output apu_vgpu_nxc_t nxc_o,
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
  localparam logic [31:0] D0Meta = {16'd1, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D1Meta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D2Meta = {16'd0, VIRTQ_DESC_F_WRITE};
  localparam logic [31:0] AvailWord = {16'd1, 16'h0};

  function automatic logic beat_bad(input logic [1:0] beat, input logic [255:0] data);
    if (beat == 2'd0) begin
      beat_bad = data[63:0] != APU_VGPU_HDR_ADDR ||
                 data[95:64] != VGPU_SUBMIT_BYTES ||
                 data[127:96] != D0Meta ||
                 data[191:128] != APU_VGPU_EXEC_ADDR ||
                 data[223:192] != APU_VGPU_SCENE_BYTES ||
                 data[255:224] != D1Meta;
    end else if (beat == 2'd1) begin
      beat_bad = data[63:0] != APU_VGPU_RSP_ADDR ||
                 data[95:64] != VGPU_RESP_HDR_BYTES ||
                 data[127:96] != D2Meta;
    end else begin
      beat_bad = data[31:0] != AvailWord || data[47:32] != 16'd0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign nxc_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|sfc_i) | (|fet_i) |
                        (|iwr_i) | (|qdr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_nxc_cpl_t cpl_q;
    apu_vgpu_nxc_t nxc_q;
    logic [1:0] beat_q;
    logic [15:0] head_q, avail_q;
    logic [31:0] buf_len_q;
    logic [63:0] buf_addr_q, rsp_addr_q, addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_nxc_cpl_t'('0);
    assign nxc_o = nxc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        nxc_q <= '0;
        beat_q <= 2'd0;
        head_q <= '0;
        avail_q <= '0;
        buf_len_q <= '0;
        buf_addr_q <= '0;
        rsp_addr_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (nxc_q.valid) begin
            cpl_q.status <= APU_VGPU_NXC_FAULT;
            state_q <= Done;
          end else if (!sfc_i.valid || !fet_i.valid || !iwr_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_NXC_EMPTY;
            state_q <= Done;
          end else if (sfc_i.hdr != APU_VIRGL_SF_HDR ||
                       sfc_i.handle != APU_VIRGL_SURFACE_HANDLE ||
                       sfc_i.resource != APU_VIRGL_RES_RT ||
                       sfc_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       sfc_i.hdr == sfc_i.handle ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE) begin
            cpl_q.status <= APU_VGPU_NXC_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            head_q <= '0;
            avail_q <= '0;
            buf_len_q <= '0;
            buf_addr_q <= '0;
            rsp_addr_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_NXC_DESC;
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
          end else if (beat_q == 2'd0) begin
            buf_addr_q <= rd_rsp_data_i[191:128];
            buf_len_q <= rd_rsp_data_i[223:192];
            beat_q <= 2'd1;
            addr_q <= APU_VGPU_NXC_LAST;
            state_q <= Issue;
          end else if (beat_q == 2'd1) begin
            rsp_addr_q <= rd_rsp_data_i[63:0];
            beat_q <= 2'd2;
            addr_q <= APU_VGPU_NXC_AVAIL;
            state_q <= Issue;
          end else begin
            avail_q <= rd_rsp_data_i[31:16];
            head_q <= rd_rsp_data_i[47:32];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || head_q != 16'd0 || avail_q != 16'd1 ||
              buf_len_q != APU_VGPU_SCENE_BYTES ||
              buf_addr_q != APU_VGPU_EXEC_ADDR ||
              rsp_addr_q != APU_VGPU_RSP_ADDR ||
              buf_addr_q == rsp_addr_q ||
              head_q == avail_q ||
              32'(head_q) == sfc_i.handle)
            cpl_q.status <= APU_VGPU_NXC_FAULT;
          else begin
            nxc_q.valid <= 1'b1;
            nxc_q.head <= head_q;
            nxc_q.avail_idx <= avail_q;
            nxc_q.buf_len <= buf_len_q;
            nxc_q.buf_addr <= buf_addr_q;
            nxc_q.rsp_addr <= rsp_addr_q;
            cpl_q.status <= APU_VGPU_NXC_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(nxc_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_NXC_OK |->
        nxc_o.valid && nxc_o.head == 16'd0 && nxc_o.avail_idx == 16'd1 &&
        nxc_o.buf_len == APU_VGPU_SCENE_BYTES &&
        nxc_o.buf_addr == APU_VGPU_EXEC_ADDR &&
        nxc_o.rsp_addr == APU_VGPU_RSP_ADDR &&
        nxc_o.head != nxc_o.avail_idx);
    `endif
  end
endmodule

module g6lc_apu_vgpu_nxc_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_nxc_cpl_t cpl_o,
  output apu_vgpu_nxc_t nxc_o,
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
  g6lc_apu_vgpu_nxc #(.Enable(Enable)) i_dut (.*);
endmodule
