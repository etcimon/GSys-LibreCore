// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the TRANSFER_FROM_HOST_3D command at 64'h88080000. Beat 0
// is the header and the box origin. Beat 1 is the 64 by 64 size
// and resource 4. Beat 2 is packed stride 256. A 640-wide box or
// a 2560-byte row records nothing. This is later than
// g6lc_apu_vgpu_tfb. This is not g6lc_apu_vgpu_rdb and not
// g6lc_apu_vgpu_avail. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferBoxRead (tfr): Guest command beats of that transfer.
module g6lc_apu_vgpu_tfr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfb_t tfb_i,
  input  apu_vgpu_rox_t rox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfr_cpl_t cpl_o,
  output apu_vgpu_tfr_t tfr_o,
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
  function automatic logic [63:0] beat_addr(input logic [1:0] beat);
    beat_addr = APU_VGPU_TFB_CMD + (64'(beat) << 5);
  endfunction

  function automatic logic beat_bad(input logic [1:0] beat, input logic [255:0] data);
    if (beat == 2'd0) begin
      beat_bad = data[31:0] != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                 data[63:32] != 32'h0 ||
                 data[127:64] != 64'h0 ||
                 data[159:128] != APU_VGPU_CTX_ID ||
                 data[191:160] != 32'h0 ||
                 data[223:192] != 32'h0 ||
                 data[255:224] != 32'h0;
    end else if (beat == 2'd1) begin
      beat_bad = data[31:0] != 32'h0 ||
                 data[63:32] != 32'(APU_VGPU_GBD_W) ||
                 data[95:64] != 32'(APU_VGPU_GBD_H) ||
                 data[127:96] != 32'h1 ||
                 data[191:128] != 64'h0 ||
                 data[223:192] != APU_VIRGL_RES_RT ||
                 data[255:224] != 32'h0;
    end else begin
      beat_bad = data[31:0] != APU_VGPU_TFB_STRIDE ||
                 data[63:32] != 32'h0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tfr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|tfb_i) | (|rox_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_tfr_cpl_t cpl_q;
    apu_vgpu_tfr_t tfr_q;
    logic [1:0] beat_q;
    logic [15:0] x_q, y_q, w_q, h_q;
    logic [31:0] stride_q, rid_q, cmd_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tfr_cpl_t'('0);
    assign tfr_o = tfr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tfr_q <= '0;
        beat_q <= 2'd0;
        x_q <= '0;
        y_q <= '0;
        w_q <= '0;
        h_q <= '0;
        stride_q <= '0;
        rid_q <= '0;
        cmd_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tfr_q.valid) begin
            cpl_q.status <= APU_VGPU_TFR_FAULT;
            state_q <= Done;
          end else if (!tfb_i.valid || !rox_i.valid) begin
            cpl_q.status <= APU_VGPU_TFR_EMPTY;
            state_q <= Done;
          end else if (tfb_i.x != 16'd0 || tfb_i.y != 16'd0 ||
                       tfb_i.width != APU_VGPU_GBD_W ||
                       tfb_i.height != APU_VGPU_GBD_H ||
                       tfb_i.res_w != APU_VGPU_RT_W ||
                       tfb_i.res_h != APU_VGPU_RT_H ||
                       tfb_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       tfb_i.resource_id != APU_VIRGL_RES_RT ||
                       rox_i.x != 7'd0 || rox_i.y != 7'd0) begin
            cpl_q.status <= APU_VGPU_TFR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            x_q <= '0;
            y_q <= '0;
            w_q <= '0;
            h_q <= '0;
            stride_q <= '0;
            rid_q <= '0;
            cmd_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_TFB_CMD;
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
            cmd_q <= rd_rsp_data_i[31:0];
            x_q <= rd_rsp_data_i[207:192];
            y_q <= rd_rsp_data_i[239:224];
            beat_q <= 2'd1;
            addr_q <= APU_VGPU_TFB_B1;
            state_q <= Issue;
          end else if (beat_q == 2'd1) begin
            w_q <= rd_rsp_data_i[47:32];
            h_q <= rd_rsp_data_i[79:64];
            rid_q <= rd_rsp_data_i[223:192];
            beat_q <= 2'd2;
            addr_q <= APU_VGPU_TFB_B2;
            state_q <= Issue;
          end else begin
            stride_q <= rd_rsp_data_i[31:0];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || cmd_q != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
              x_q != 16'd0 || y_q != 16'd0 ||
              w_q != APU_VGPU_GBD_W || h_q != APU_VGPU_GBD_H ||
              rid_q != APU_VIRGL_RES_RT ||
              stride_q != APU_VGPU_TFB_STRIDE ||
              stride_q == APU_VGPU_TFB_ROW) begin
            cpl_q.status <= APU_VGPU_TFR_FAULT;
          end else begin
            tfr_q.valid <= 1'b1;
            tfr_q.x <= x_q;
            tfr_q.y <= y_q;
            tfr_q.width <= w_q;
            tfr_q.height <= h_q;
            tfr_q.stride <= stride_q;
            tfr_q.resource_id <= rid_q;
            tfr_q.cmd <= cmd_q;
            tfr_q.addr <= APU_VGPU_TFB_CMD;
            cpl_q.status <= APU_VGPU_TFR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tfr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TFR_OK |->
        tfr_o.valid && tfr_o.x == 16'd0 && tfr_o.y == 16'd0 &&
        tfr_o.width == APU_VGPU_GBD_W && tfr_o.stride == APU_VGPU_TFB_STRIDE &&
        tfr_o.addr == APU_VGPU_TFB_CMD);
    `endif
  end
endmodule

// TransferBoxRead (tfr) enable-0 fixture: Guest command beats of that transfer.
module g6lc_apu_vgpu_tfr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfb_t tfb_i,
  input  apu_vgpu_rox_t rox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfr_cpl_t cpl_o,
  output apu_vgpu_tfr_t tfr_o,
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
  g6lc_apu_vgpu_tfr #(.Enable(Enable)) i_dut (.*);
endmodule
