// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One 24-byte virtio_gpu_ctrl_hdr at the scene submit's response address.
// Type is OK_NODATA, the fence bit is set, and the fence is the proven
// scene fence. A failed beat can be retried. A second store does not
// replace the first. This does not store a pixel.

module g6lc_apu_vgpu_rsp
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_att_t att_i,
  input  apu_vgpu_sub_t sub_i,
  input  apu_vgpu_drw_t drw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rsp_cpl_t cpl_o,
  output apu_vgpu_rsp_t rsp_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [191:0] wr_data_o,
  output logic [31:0] wr_len_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rsp_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_data_o = '0;
    assign wr_len_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | wr_ready_i |
                        wr_rsp_valid_i | wr_rsp_ok_i | (|att_i) | (|sub_i) |
                        (|drw_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Issue, WaitRsp, Done } state_e;

    state_e state_q;
    apu_vgpu_rsp_cpl_t cpl_q;
    apu_vgpu_rsp_t rsp_q;
    logic [63:0] addr_q;
    logic [191:0] data_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rsp_cpl_t'('0);
    assign rsp_o = rsp_q;
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_data_o = data_q;
    assign wr_len_o = VGPU_RESP_HDR_BYTES;
    assign wr_rsp_ready_o = state_q == WaitRsp;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rsp_q <= '0;
        addr_q <= '0;
        data_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic shaped;
          shaped = att_i.rt && att_i.vbo && att_i.scan && att_i.next == APU_VGPU_CTL_END &&
                   sub_i.ctx_id == APU_VGPU_CTX_ID && sub_i.size == APU_VGPU_SCENE_BYTES &&
                   sub_i.buf_addr == APU_VGPU_EXEC_ADDR && sub_i.rsp_addr == APU_VGPU_RSP_ADDR &&
                   drw_i.count == APU_VIRGL_VERT_COUNT && drw_i.prim == APU_VIRGL_PRIM_STRIP &&
                   drw_i.next == APU_VGPU_SCENE_BYTES;
          if (rsp_q.valid) begin
            cpl_q <= '{status: APU_VGPU_RSP_FAULT, addr: '0, ctx_id: '0};
            state_q <= Done;
          end else if (!att_i.rt || !att_i.vbo || !att_i.scan || !sub_i.valid || !drw_i.valid) begin
            cpl_q <= '{status: APU_VGPU_RSP_EMPTY, addr: '0, ctx_id: '0};
            state_q <= Done;
          end else if (!shaped) begin
            cpl_q <= '{status: APU_VGPU_RSP_FAULT, addr: '0, ctx_id: '0};
            state_q <= Done;
          end else begin
            addr_q <= sub_i.rsp_addr;
            data_q <= {32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE, VGPU_FLAG_FENCE,
                       VGPU_RESP_OK_NODATA};
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            cpl_q <= '{status: APU_VGPU_RSP_BUS, addr: '0, ctx_id: '0};
          end else begin
            rsp_q.valid <= 1'b1;
            rsp_q.addr <= addr_q;
            rsp_q.ctx_id <= APU_VGPU_CTX_ID;
            rsp_q.fence <= APU_VGPU_SCENE_FENCE;
            cpl_q.status <= APU_VGPU_RSP_OK;
            cpl_q.addr <= addr_q;
            cpl_q.ctx_id <= APU_VGPU_CTX_ID;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rsp_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o) && $stable(wr_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RSP_OK |->
        rsp_o.valid && rsp_o.fence == APU_VGPU_SCENE_FENCE &&
        rsp_o.addr == APU_VGPU_RSP_ADDR);
    `endif
  end
endmodule

module g6lc_apu_vgpu_rsp_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_att_t att_i,
  input  apu_vgpu_sub_t sub_i,
  input  apu_vgpu_drw_t drw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rsp_cpl_t cpl_o,
  output apu_vgpu_rsp_t rsp_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [191:0] wr_data_o,
  output logic [31:0] wr_len_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_rsp #(.Enable(Enable)) i_dut (.*);
endmodule
