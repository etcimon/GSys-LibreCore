// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read (0,0) in the 64 by 64 sample rectangle. The lane is the
// clamp texel, not the clear word and not the (1,0) blend.
// (1,0) records nothing. This is later than g6lc_apu_vgpu_cof.
// The image is not kept. TEX is not the compiler opcode. This is
// not Mesa glReadPixels.

// ColorWindowOffsetOrigin (cor): (0,0) in that rectangle is the clamp texel.
module g6lc_apu_vgpu_cor
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_crd_t crd_i,
  input  apu_vgpu_crx_t crx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cor_cpl_t cpl_o,
  output apu_vgpu_cor_t cor_o,
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
    assign cor_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|crd_i) | (|crx_i) |
                        (|x_i) | (|y_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_cor_cpl_t cpl_q;
    apu_vgpu_cor_t cor_q;
    logic [31:0] word_q, want_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cor_cpl_t'('0);
    assign cor_o = cor_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cor_q <= '0;
        word_q <= '0;
        want_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cor_q.valid) begin
            cpl_q.status <= APU_VGPU_COR_FAULT;
            state_q <= Done;
          end else if (!crd_i.valid || !crx_i.valid) begin
            cpl_q.status <= APU_VGPU_COR_EMPTY;
            state_q <= Done;
          end else if (crd_i.base != APU_VGPU_CSW_DST ||
                       crd_i.base == APU_VGPU_GBW_ADDR ||
                       crd_i.width != APU_VGPU_GBD_W ||
                       crd_i.height != APU_VGPU_GBD_H ||
                       crd_i.origin == APU_VGPU_CLEAR_WORD ||
                       crd_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       crd_i.origin == crd_i.neighbor ||
                       crx_i.word != crd_i.neighbor ||
                       x_i != 7'd0 || y_i != 7'd0) begin
            cpl_q.status <= APU_VGPU_COR_FAULT;
            state_q <= Done;
          end else begin
            want_q <= crd_i.origin;
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_CSW_DST;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
              rd_rsp_data_i[31:0] != want_q ||
              rd_rsp_data_i[31:0] == APU_VGPU_CLEAR_WORD ||
              rd_rsp_data_i[63:32] == rd_rsp_data_i[31:0])
            bad_q <= 1'b1;
          else word_q <= rd_rsp_data_i[31:0];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || word_q != want_q || word_q == APU_VGPU_CLEAR_WORD)
            cpl_q.status <= APU_VGPU_COR_FAULT;
          else begin
            cor_q.valid <= 1'b1;
            cor_q.word <= word_q;
            cor_q.offset <= 16'd0;
            cor_q.x <= 7'd0;
            cor_q.y <= 7'd0;
            cor_q.addr <= addr_q;
            cpl_q.status <= APU_VGPU_COR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cor_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_COR_OK |->
        cor_o.valid && cor_o.x == 7'd0 && cor_o.y == 7'd0 &&
        cor_o.offset == 16'd0 && cor_o.addr == APU_VGPU_CSW_DST &&
        cor_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// ColorWindowOffsetOrigin (cor) enable-0 fixture: (0,0) in that rectangle is the clamp texel.
module g6lc_apu_vgpu_cor_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_crd_t crd_i,
  input  apu_vgpu_crx_t crx_i,
  input  logic [6:0] x_i,
  input  logic [6:0] y_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cor_cpl_t cpl_o,
  output apu_vgpu_cor_t cor_o,
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
  g6lc_apu_vgpu_cor #(.Enable(Enable)) i_dut (.*);
endmodule
