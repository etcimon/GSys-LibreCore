// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Copy the 64 by 64 sample rectangle into a guest buffer at
// 64'h88070000 as TRANSFER_FROM_HOST_3D of resource 4. Source is
// 64'h88060000. Beat 0 is the linear sample pair. A clear-colored
// lane stops the copy. This is later than g6lc_apu_vgpu_cox. The
// image is not kept. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// TransferDestCopy (rpw): Guest 64 by 64 TRANSFER_FROM_HOST_3D of the sample rectangle.
module g6lc_apu_vgpu_rpw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cox_t cox_i,
  input  apu_vgpu_csw_t csw_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpw_cpl_t cpl_o,
  output apu_vgpu_rpw_t rpw_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
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
  function automatic logic [63:0] src_addr(input logic [8:0] beat);
    src_addr = APU_VGPU_CSW_DST + (64'(beat) << 5);
  endfunction

  function automatic logic [63:0] dst_addr(input logic [8:0] beat);
    dst_addr = APU_VGPU_RPW_DST + (64'(beat) << 5);
  endfunction

  function automatic logic lanes_ok(input logic [255:0] d);
    lanes_ok = d[31:0] != APU_VGPU_CLEAR_WORD &&
               d[63:32] != APU_VGPU_CLEAR_WORD &&
               d[95:64] != APU_VGPU_CLEAR_WORD &&
               d[127:96] != APU_VGPU_CLEAR_WORD &&
               d[159:128] != APU_VGPU_CLEAR_WORD &&
               d[191:160] != APU_VGPU_CLEAR_WORD &&
               d[223:192] != APU_VGPU_CLEAR_WORD &&
               d[255:224] != APU_VGPU_CLEAR_WORD;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rpw_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i | wr_rsp_valid_i |
                        wr_rsp_ok_i | (|cox_i) | (|csw_i) | (|cxr_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, RdIssue, RdWait, WrIssue, WrWait, Commit, Done
    } state_e;
    state_e state_q;
    apu_vgpu_rpw_cpl_t cpl_q;
    apu_vgpu_rpw_t rpw_q;
    logic [8:0] beat_q;
    logic [31:0] origin_q, neighbor_q;
    logic [255:0] data_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == RdIssue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == RdWait;
    assign wr_valid_o = state_q == WrIssue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign wr_data_o = data_q;
    assign wr_rsp_ready_o = state_q == WrWait;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rpw_cpl_t'('0);
    assign rpw_o = rpw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rpw_q <= '0;
        beat_q <= '0;
        origin_q <= '0;
        neighbor_q <= '0;
        data_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rpw_q.valid) begin
            cpl_q.status <= APU_VGPU_RPW_FAULT;
            state_q <= Done;
          end else if (!cox_i.valid || !csw_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_RPW_EMPTY;
            state_q <= Done;
          end else if (cox_i.word == APU_VGPU_CLEAR_WORD ||
                       cox_i.x != 7'd0 || cox_i.y != 7'd0 ||
                       cox_i.offset != 16'd0 ||
                       cox_i.b0 != cox_i.word[7:0] ||
                       cox_i.b0 == APU_VGPU_CLEAR_R ||
                       csw_i.origin != cox_i.word ||
                       csw_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       csw_i.origin == csw_i.neighbor ||
                       csw_i.dst != APU_VGPU_CSW_DST ||
                       csw_i.src != APU_VGPU_CSW_SRC ||
                       csw_i.beats != APU_VGPU_GPW_BEATS ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_RPW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 9'd0;
            origin_q <= csw_i.origin;
            neighbor_q <= csw_i.neighbor;
            bad_q <= 1'b0;
            addr_q <= src_addr(9'd0);
            state_q <= RdIssue;
          end
        end
        RdIssue: if (rd_ready_i) state_q <= RdWait;
        RdWait: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    !lanes_ok(rd_rsp_data_i);
          if (beat_q == 9'd0 &&
              (rd_rsp_data_i[31:0] != origin_q ||
               rd_rsp_data_i[63:32] != neighbor_q))
            bad_bus = 1'b1;
          if (bad_bus) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else begin
            data_q <= rd_rsp_data_i;
            addr_q <= dst_addr(beat_q);
            state_q <= WrIssue;
          end
        end
        WrIssue: if (wr_ready_i) state_q <= WrWait;
        WrWait: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == APU_VGPU_GPW_LAST) begin
            state_q <= Commit;
          end else begin
            beat_q <= beat_q + 9'd1;
            addr_q <= src_addr(beat_q + 9'd1);
            state_q <= RdIssue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GPW_LAST)
            cpl_q.status <= APU_VGPU_RPW_FAULT;
          else begin
            rpw_q.valid <= 1'b1;
            rpw_q.origin <= origin_q;
            rpw_q.neighbor <= neighbor_q;
            rpw_q.beats <= APU_VGPU_GPW_BEATS;
            rpw_q.src <= APU_VGPU_CSW_DST;
            rpw_q.dst <= APU_VGPU_RPW_DST;
            rpw_q.cmd <= VGPU_CMD_TRANSFER_FROM_HOST_3D;
            rpw_q.resource_id <= APU_VIRGL_RES_RT;
            cpl_q.status <= APU_VGPU_RPW_OK;
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
      rd_valid_o && wr_valid_o |-> 1'b0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(rpw_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RPW_OK |->
        rpw_o.valid && rpw_o.beats == APU_VGPU_GPW_BEATS &&
        rpw_o.src == APU_VGPU_CSW_DST && rpw_o.dst == APU_VGPU_RPW_DST &&
        rpw_o.src != rpw_o.dst &&
        rpw_o.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
        rpw_o.resource_id == APU_VIRGL_RES_RT &&
        rpw_o.neighbor != APU_VGPU_CLEAR_WORD &&
        rpw_o.origin != rpw_o.neighbor);
    `endif
  end
endmodule

// TransferDestCopy (rpw) enable-0 fixture: Guest 64 by 64 TRANSFER_FROM_HOST_3D of the sample rectangle.
module g6lc_apu_vgpu_rpw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cox_t cox_i,
  input  apu_vgpu_csw_t csw_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rpw_cpl_t cpl_o,
  output apu_vgpu_rpw_t rpw_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
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
  g6lc_apu_vgpu_rpw #(.Enable(Enable)) i_dut (.*);
endmodule
