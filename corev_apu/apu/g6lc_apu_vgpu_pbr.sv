// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read beat 0 of the guest readback at 64'h88030000. Lane 0 is
// (0,0). Lane 1 is (1,0). Both words are the TEX pair, not the
// clear color. The scene window at 64'h88020000 records nothing.
// This is later than g6lc_apu_vgpu_pbw. This is not
// g6lc_apu_vgpu_ocr. The compiler TEX opcode still returns -26.
// The image is not kept. This is not Mesa glReadPixels.

// ReadbackTexRead (pbr): Guest read of that readback beat.
module g6lc_apu_vgpu_pbr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pbw_t pbw_i,
  input  apu_vgpu_ocx_t ocx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pbr_cpl_t cpl_o,
  output apu_vgpu_pbr_t pbr_o,
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
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign pbr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|pbw_i) | (|ocx_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_pbr_cpl_t cpl_q;
    apu_vgpu_pbr_t pbr_q;
    logic [31:0] origin_q, neighbor_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_pbr_cpl_t'('0);
    assign pbr_o = pbr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        pbr_q <= '0;
        origin_q <= '0;
        neighbor_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (pbr_q.valid) begin
            cpl_q.status <= APU_VGPU_PBR_FAULT;
            state_q <= Done;
          end else if (!pbw_i.valid || !ocx_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_PBR_EMPTY;
            state_q <= Done;
          end else if (pbw_i.base != APU_VGPU_PBW_ADDR ||
                       pbw_i.base == APU_VGPU_OCW_ADDR ||
                       pbw_i.off0 != APU_VGPU_ACW_AT0 ||
                       pbw_i.off1 != APU_VGPU_ACW_AT1 ||
                       pbw_i.x0 != 7'd0 || pbw_i.x1 != 7'd1 ||
                       pbw_i.origin != ocx_i.origin ||
                       pbw_i.neighbor != ocx_i.neighbor ||
                       pbw_i.origin == APU_VGPU_CLEAR_WORD ||
                       pbw_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       pbw_i.origin == pbw_i.neighbor ||
                       pbw_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_PBR_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            origin_q <= pbw_i.origin;
            neighbor_q <= pbw_i.neighbor;
            addr_q <= APU_VGPU_PBW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_OCW_ADDR ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              rd_rsp_data_i[31:0] != origin_q ||
              rd_rsp_data_i[63:32] != neighbor_q ||
              rd_rsp_data_i[31:0] == APU_VGPU_CLEAR_WORD ||
              rd_rsp_data_i[63:32] == APU_VGPU_CLEAR_WORD ||
              rd_rsp_data_i[31:0] == rd_rsp_data_i[63:32])
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_PBR_FAULT;
          else begin
            pbr_q.valid <= 1'b1;
            pbr_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            pbr_q.base <= APU_VGPU_PBW_ADDR;
            pbr_q.off0 <= APU_VGPU_ACW_AT0;
            pbr_q.off1 <= APU_VGPU_ACW_AT1;
            pbr_q.x0 <= 7'd0;
            pbr_q.x1 <= 7'd1;
            pbr_q.origin <= origin_q;
            pbr_q.neighbor <= neighbor_q;
            cpl_q.status <= APU_VGPU_PBR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(pbr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_PBR_OK |->
        pbr_o.valid && pbr_o.base == APU_VGPU_GBW_ADDR &&
        pbr_o.base != APU_VGPU_GPW_ADDR &&
        pbr_o.origin != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ReadbackTexRead (pbr) enable-0 fixture: Guest read of that readback beat.
module g6lc_apu_vgpu_pbr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pbw_t pbw_i,
  input  apu_vgpu_ocx_t ocx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pbr_cpl_t cpl_o,
  output apu_vgpu_pbr_t pbr_o,
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
  g6lc_apu_vgpu_pbr #(.Enable(Enable)) i_dut (.*);
endmodule
