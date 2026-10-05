// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read beat 0 of the guest buffer at 64'h88070000. Lane 0 is (0,0).
// Lane 1 is (1,0). Both words are the linear sample pair. This is
// later than g6lc_apu_vgpu_rpw. The image is not kept. TEX is not
// the compiler opcode. This is not Mesa glReadPixels.

// TransferDestRead (rpr): Beat 0 of that guest buffer read back.
module g6lc_apu_vgpu_rpr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_cox_t cox_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpr_cpl_t cpl_o,
  output apu_vgpu_rpr_t rpr_o,
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
    assign rpr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|rpw_i) | (|cox_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rpr_cpl_t cpl_q;
    apu_vgpu_rpr_t rpr_q;
    logic [31:0] origin_q, neighbor_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rpr_cpl_t'('0);
    assign rpr_o = rpr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rpr_q <= '0;
        origin_q <= '0;
        neighbor_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rpr_q.valid) begin
            cpl_q.status <= APU_VGPU_RPR_FAULT;
            state_q <= Done;
          end else if (!rpw_i.valid || !cox_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_RPR_EMPTY;
            state_q <= Done;
          end else if (rpw_i.src != APU_VGPU_CSW_DST ||
                       rpw_i.dst != APU_VGPU_RPW_DST ||
                       rpw_i.dst == APU_VGPU_CSW_DST ||
                       rpw_i.dst == APU_VGPU_GBW_ADDR ||
                       rpw_i.beats != APU_VGPU_GPW_BEATS ||
                       rpw_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       rpw_i.resource_id != APU_VIRGL_RES_RT ||
                       rpw_i.origin != cox_i.word ||
                       rpw_i.origin == APU_VGPU_CLEAR_WORD ||
                       rpw_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       rpw_i.origin == rpw_i.neighbor ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_RPR_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            origin_q <= rpw_i.origin;
            neighbor_q <= rpw_i.neighbor;
            addr_q <= APU_VGPU_RPW_DST;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
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
            cpl_q.status <= APU_VGPU_RPR_FAULT;
          else begin
            rpr_q.valid <= 1'b1;
            rpr_q.origin <= origin_q;
            rpr_q.neighbor <= neighbor_q;
            rpr_q.off0 <= APU_VGPU_ACW_AT0;
            rpr_q.off1 <= APU_VGPU_ACW_AT1;
            rpr_q.x0 <= 7'd0;
            rpr_q.x1 <= 7'd1;
            rpr_q.base <= APU_VGPU_RPW_DST;
            cpl_q.status <= APU_VGPU_RPR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rpr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RPR_OK |->
        rpr_o.valid && rpr_o.base == APU_VGPU_RPW_DST &&
        rpr_o.base != APU_VGPU_CSW_DST &&
        rpr_o.off1 == APU_VGPU_ACW_AT1 &&
        rpr_o.neighbor != APU_VGPU_CLEAR_WORD &&
        rpr_o.origin != rpr_o.neighbor);
    `endif
  end
endmodule

// TransferDestRead (rpr) enable-0 fixture: Beat 0 of that guest buffer read back.
module g6lc_apu_vgpu_rpr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_cox_t cox_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpr_cpl_t cpl_o,
  output apu_vgpu_rpr_t rpr_o,
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
  g6lc_apu_vgpu_rpr #(.Enable(Enable)) i_dut (.*);
endmodule
