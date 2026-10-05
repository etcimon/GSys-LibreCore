// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the 24-byte OK_NODATA at 64'h8800A800 after the guest
// WRITE. The fence is the scene fence, not fence 2. A missing
// fence bit or the transfer response address records nothing.
// This is later than g6lc_apu_vgpu_qso. This is not
// g6lc_apu_vgpu_qol. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneOkNodataRead (qsp): Guest read of that scene response.
module g6lc_apu_vgpu_qsp
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qso_t qso_i,
  input  apu_vgpu_qru_t qru_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsp_cpl_t cpl_o,
  output apu_vgpu_qsp_t qsp_o,
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
  localparam logic [191:0] RespWord = {32'h0, APU_VGPU_CTX_ID, APU_VGPU_SCENE_FENCE,
                                       VGPU_FLAG_FENCE, VGPU_RESP_OK_NODATA};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsp_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|qso_i) | (|qru_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qsp_cpl_t cpl_q;
    apu_vgpu_qsp_t qsp_q;
    logic [31:0] resp_q, flg_q;
    logic [63:0] fence_q, addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = VGPU_RESP_HDR_BYTES;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsp_cpl_t'('0);
    assign qsp_o = qsp_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsp_q <= '0;
        resp_q <= '0;
        flg_q <= '0;
        fence_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsp_q.valid) begin
            cpl_q.status <= APU_VGPU_QSP_FAULT;
            state_q <= Done;
          end else if (!qso_i.valid || !qru_i.valid) begin
            cpl_q.status <= APU_VGPU_QSP_EMPTY;
            state_q <= Done;
          end else if (qso_i.addr != APU_VGPU_RSP_ADDR ||
                       qso_i.addr == APU_VGPU_RFW_ADDR ||
                       qso_i.fence != APU_VGPU_SCENE_FENCE ||
                       qso_i.fence == APU_VGPU_RFW_FENCE ||
                       qso_i.resp != VGPU_RESP_OK_NODATA ||
                       qru_i.rsp_addr != APU_VGPU_RSP_ADDR) begin
            cpl_q.status <= APU_VGPU_QSP_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            resp_q <= '0;
            flg_q <= '0;
            fence_q <= '0;
            addr_q <= APU_VGPU_RSP_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_RFW_ADDR ||
              rd_rsp_len_i != VGPU_RESP_HDR_BYTES ||
              rd_rsp_data_i[191:0] != RespWord ||
              rd_rsp_data_i[127:64] == APU_VGPU_RFW_FENCE ||
              rd_rsp_data_i[63:32] != VGPU_FLAG_FENCE)
            bad_q <= 1'b1;
          else begin
            resp_q <= rd_rsp_data_i[31:0];
            flg_q <= rd_rsp_data_i[63:32];
            fence_q <= rd_rsp_data_i[127:64];
          end
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || fence_q != APU_VGPU_SCENE_FENCE ||
              fence_q == APU_VGPU_RFW_FENCE ||
              flg_q != VGPU_FLAG_FENCE ||
              resp_q != VGPU_RESP_OK_NODATA)
            cpl_q.status <= APU_VGPU_QSP_FAULT;
          else begin
            qsp_q.valid <= 1'b1;
            qsp_q.resp <= resp_q;
            qsp_q.flg <= flg_q;
            qsp_q.fence <= fence_q;
            qsp_q.addr <= APU_VGPU_RSP_ADDR;
            cpl_q.status <= APU_VGPU_QSP_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsp_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSP_OK |->
        qsp_o.valid && qsp_o.fence == APU_VGPU_SCENE_FENCE &&
        qsp_o.addr != APU_VGPU_RFW_ADDR &&
        qsp_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// SceneOkNodataRead (qsp) enable-0 fixture: Guest read of that scene response.
module g6lc_apu_vgpu_qsp_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qso_t qso_i,
  input  apu_vgpu_qru_t qru_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsp_cpl_t cpl_o,
  output apu_vgpu_qsp_t qsp_o,
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
  g6lc_apu_vgpu_qsp #(.Enable(Enable)) i_dut (.*);
endmodule
