// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One guest store of used.idx. The store is the 16-bit index, little
// endian, at a 2-byte-aligned address. The local index must already be
// nonzero and the used element must already have been written. A second
// store does not replace it. This does not write the element, and it is
// not g6lc_apu_queue.

// UsedIndexStore (uidx): One guest store of used.idx. Default-off. Not a second element and not a descriptor chain.
module g6lc_apu_vgpu_uidx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [63:0] addr_i,
  input  logic [15:0] used_idx_i,
  input  logic elem_wrote_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_uidx_cpl_t cpl_o,
  output logic wrote_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [15:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign wrote_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | elem_wrote_i |
                        wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|addr_i) |
                        (|used_idx_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;
    typedef struct packed {
      apu_vgpu_uidx_status_e status;
      logic do_write;
      logic [15:0] idx;
      logic [63:0] addr;
    } dec_t;

    state_e state_q;
    apu_vgpu_uidx_cpl_t cpl_q;
    logic wrote_q, armed_q;
    logic [15:0] idx_q;
    logic [63:0] addr_q;

    function automatic dec_t decode(
      input logic [63:0] addr,
      input logic [15:0] used_idx,
      input logic elem_wrote,
      input logic wrote
    );
      decode = '0;
      if (used_idx == 16'h0) begin
        decode.status = APU_VGPU_UIDX_EMPTY;
      end else if (!elem_wrote || wrote || addr == 64'h0 || addr[0] != 1'b0 ||
                   (addr + 64'(VGPU_USED_IDX_BYTES)) < addr) begin
        decode.status = APU_VGPU_UIDX_FAULT;
      end else begin
        decode.status = APU_VGPU_UIDX_OK;
        decode.do_write = 1'b1;
        decode.idx = used_idx;
        decode.addr = addr;
      end
    endfunction

    assign wrote_o = wrote_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_uidx_cpl_t'('0);
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_data_o = idx_q;
    assign wr_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        wrote_q <= 1'b0;
        armed_q <= 1'b0;
        idx_q <= '0;
        addr_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          dec_t got;
          got = decode(addr_i, used_idx_i, elem_wrote_i, wrote_q);
          if (!got.do_write) begin
            cpl_q <= '{status: got.status, idx: '0, addr: '0};
            state_q <= Done;
          end else begin
            idx_q <= got.idx;
            addr_q <= got.addr;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          apu_vgpu_uidx_cpl_t nxt;
          nxt = '0;
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            nxt.status = APU_VGPU_UIDX_BUS;
          end else begin
            nxt.status = APU_VGPU_UIDX_OK;
            nxt.idx = idx_q;
            nxt.addr = addr_q;
            wrote_q <= 1'b1;
          end
          cpl_q <= nxt;
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
      cpl_valid_o && cpl_o.status != APU_VGPU_UIDX_OK |->
        cpl_o.idx == 16'h0 && cpl_o.addr == 64'h0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(wrote_o));
    `endif
  end
endmodule

// UsedIndexStore (uidx) enable-0 fixture: One guest store of used.idx. Default-off. Not a second element.
module g6lc_apu_vgpu_uidx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  logic [63:0] addr_i,
  input  logic [15:0] used_idx_i,
  input  logic elem_wrote_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_uidx_cpl_t cpl_o,
  output logic wrote_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [15:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_uidx #(.Enable(Enable)) i_dut (.*);
endmodule
