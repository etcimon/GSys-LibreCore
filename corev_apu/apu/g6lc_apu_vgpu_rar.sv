// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the RESOURCE_ATTACH_BACKING command at 64'h88090000. Beat 0
// is the header, resource 4, and one entry. Beat 1 is address
// 64'h88070000 and length 16384. A 1,228,800-byte length or the
// color-window address records nothing. This is later than
// g6lc_apu_vgpu_rab. This is not g6lc_apu_vgpu_back and not
// g6lc_apu_vgpu_avail. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferAttachRead (rar): Guest command beats of that attach.
module g6lc_apu_vgpu_rar
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rab_t rab_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rar_cpl_t cpl_o,
  output apu_vgpu_rar_t rar_o,
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
  function automatic logic beat_bad(input logic beat, input logic [255:0] data);
    if (beat == 1'b0) begin
      beat_bad = data[31:0] != VGPU_CMD_RESOURCE_ATTACH_BACKING ||
                 data[63:32] != 32'h0 ||
                 data[127:64] != 64'h0 ||
                 data[159:128] != APU_VGPU_CTX_ID ||
                 data[191:160] != 32'h0 ||
                 data[223:192] != APU_VIRGL_RES_RT ||
                 data[255:224] != 32'd1;
    end else begin
      beat_bad = data[63:0] != APU_VGPU_RPW_DST ||
                 data[95:64] != APU_VGPU_GBD_BYTES ||
                 data[95:64] == APU_VGPU_SCAN_BYTES ||
                 data[127:96] != 32'h0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rar_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|rab_i) | (|tfx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rar_cpl_t cpl_q;
    apu_vgpu_rar_t rar_q;
    logic beat_q;
    logic [31:0] len_q, rid_q, cmd_q;
    logic [63:0] gaddr_q, addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rar_cpl_t'('0);
    assign rar_o = rar_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rar_q <= '0;
        beat_q <= 1'b0;
        len_q <= '0;
        rid_q <= '0;
        cmd_q <= '0;
        gaddr_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rar_q.valid) begin
            cpl_q.status <= APU_VGPU_RAR_FAULT;
            state_q <= Done;
          end else if (!rab_i.valid || !tfx_i.valid) begin
            cpl_q.status <= APU_VGPU_RAR_EMPTY;
            state_q <= Done;
          end else if (rab_i.addr != APU_VGPU_RPW_DST ||
                       rab_i.length != APU_VGPU_GBD_BYTES ||
                       rab_i.cmd != VGPU_CMD_RESOURCE_ATTACH_BACKING ||
                       rab_i.resource_id != APU_VIRGL_RES_RT ||
                       tfx_i.stride != APU_VGPU_TFB_STRIDE) begin
            cpl_q.status <= APU_VGPU_RAR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            len_q <= '0;
            rid_q <= '0;
            cmd_q <= '0;
            gaddr_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_RAB_CMD;
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
          end else if (beat_q == 1'b0) begin
            cmd_q <= rd_rsp_data_i[31:0];
            rid_q <= rd_rsp_data_i[223:192];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_RAB_B1;
            state_q <= Issue;
          end else begin
            gaddr_q <= rd_rsp_data_i[63:0];
            len_q <= rd_rsp_data_i[95:64];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || cmd_q != VGPU_CMD_RESOURCE_ATTACH_BACKING ||
              rid_q != APU_VIRGL_RES_RT ||
              gaddr_q != APU_VGPU_RPW_DST ||
              len_q != APU_VGPU_GBD_BYTES ||
              len_q == APU_VGPU_SCAN_BYTES) begin
            cpl_q.status <= APU_VGPU_RAR_FAULT;
          end else begin
            rar_q.valid <= 1'b1;
            rar_q.addr <= gaddr_q;
            rar_q.length <= len_q;
            rar_q.resource_id <= rid_q;
            rar_q.cmd <= cmd_q;
            rar_q.cmd_addr <= APU_VGPU_RAB_CMD;
            cpl_q.status <= APU_VGPU_RAR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rar_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RAR_OK |->
        rar_o.valid && rar_o.addr == APU_VGPU_RPW_DST &&
        rar_o.length == APU_VGPU_GBD_BYTES &&
        rar_o.cmd_addr == APU_VGPU_RAB_CMD);
    `endif
  end
endmodule

// TransferAttachRead (rar) enable-0 fixture: Guest command beats of that attach.
module g6lc_apu_vgpu_rar_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rab_t rab_i,
  input  apu_vgpu_tfx_t tfx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rar_cpl_t cpl_o,
  output apu_vgpu_rar_t rar_o,
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
  g6lc_apu_vgpu_rar #(.Enable(Enable)) i_dut (.*);
endmodule
