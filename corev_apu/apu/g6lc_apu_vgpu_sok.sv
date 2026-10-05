// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the 24-byte virtio OK_NODATA at 64'h8800A800 after the
// guest-named WRITE descriptor after scene QueueNotify. The
// fence is the scene fence, not fence 2. The descriptor table
// and the transfer response record nothing. This is later than
// g6lc_apu_vgpu_swx. This is not g6lc_apu_vgpu_qok, not
// g6lc_apu_vgpu_qso, and not g6lc_apu_vgpu_gcw. The image is not
// kept. The compiler TEX opcode still returns -26. This is not
// Mesa glReadPixels.

// SceneOkAfterNotify (sok): Scene OK_NODATA after that WRITE.
module g6lc_apu_vgpu_sok
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_swx_t swx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sok_cpl_t cpl_o,
  output apu_vgpu_sok_t sok_o,
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
  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_SCENE_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sok_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|swx_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_sok_cpl_t cpl_q;
    apu_vgpu_sok_t sok_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = VGPU_RESP_HDR_BYTES;
    assign wr_data_o = RespBeat;
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sok_cpl_t'('0);
    assign sok_o = sok_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sok_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sok_q.valid) begin
            cpl_q.status <= APU_VGPU_SOK_FAULT;
            state_q <= Done;
          end else if (!swx_i.valid) begin
            cpl_q.status <= APU_VGPU_SOK_EMPTY;
            state_q <= Done;
          end else if (swx_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       swx_i.rsp_addr == APU_VGPU_RFW_ADDR ||
                       swx_i.rsp_addr == APU_VGPU_SWD_ADDR ||
                       swx_i.rsp_addr == APU_VGPU_EXEC_ADDR) begin
            cpl_q.status <= APU_VGPU_SOK_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_RSP_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q ||
              wr_rsp_addr_i == APU_VGPU_RFW_ADDR ||
              wr_rsp_addr_i == APU_VGPU_SWD_ADDR)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_SOK_FAULT;
          else begin
            sok_q.valid <= 1'b1;
            sok_q.resp <= VGPU_RESP_OK_NODATA;
            sok_q.fence <= APU_VGPU_SCENE_FENCE;
            sok_q.addr <= APU_VGPU_RSP_ADDR;
            cpl_q.status <= APU_VGPU_SOK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sok_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SOK_OK |->
        sok_o.valid && sok_o.addr == APU_VGPU_RSP_ADDR &&
        sok_o.addr != APU_VGPU_RFW_ADDR &&
        sok_o.fence == APU_VGPU_SCENE_FENCE &&
        sok_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// SceneOkAfterNotify (sok) enable-0 fixture: Scene OK_NODATA after that WRITE.
module g6lc_apu_vgpu_sok_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_swx_t swx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sok_cpl_t cpl_o,
  output apu_vgpu_sok_t sok_o,
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
  g6lc_apu_vgpu_sok #(.Enable(Enable)) i_dut (.*);
endmodule
