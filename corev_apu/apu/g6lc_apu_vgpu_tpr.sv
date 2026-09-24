// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read three points of the readback buffer.
// (1,1) is lane 1 of the row-1 beat. (2,3) is lane 2 of
// 64'h88030300. (0,63) is lane 0 of 64'h88033F00.
// Each lane is the bytes 0D 0D 1A FF. This is later than
// g6lc_apu_vgpu_ryr. No triangle is walked. The image is not kept.
// The shader is not run.

module g6lc_apu_vgpu_tpr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_ryx_t ryx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpr_cpl_t cpl_o,
  output apu_vgpu_tpr_t tpr_o,
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
  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  function automatic logic bytes_ok(input logic [31:0] word);
    bytes_ok = word[7:0] == APU_VGPU_CLEAR_R &&
               word[15:8] == APU_VGPU_CLEAR_G &&
               word[23:16] == APU_VGPU_CLEAR_B &&
               word[31:24] == APU_VGPU_CLEAR_A;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tpr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|ryx_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_tpr_cpl_t cpl_q;
    apu_vgpu_tpr_t tpr_q;
    logic [1:0] beat_q;
    logic bad_q, armed_q;
    logic [63:0] addr_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tpr_cpl_t'('0);
    assign tpr_o = tpr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tpr_q <= '0;
        beat_q <= 2'd0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tpr_q.valid) begin
            cpl_q.status <= APU_VGPU_TPR_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !ryx_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_TPR_EMPTY;
            state_q <= Done;
          end else if (gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       ryx_i.b0 != APU_VGPU_CLEAR_R ||
                       ryx_i.r != APU_VGPU_CLEAR_R ||
                       ryx_i.g != APU_VGPU_CLEAR_G ||
                       ryx_i.b != APU_VGPU_CLEAR_B ||
                       ryx_i.a != APU_VGPU_CLEAR_A ||
                       ryx_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_TPR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 2'd0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_GOF_ROW1_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    rd_rsp_data_i != Pat;
          if (beat_q == 2'd0)
            bad_bus = bad_bus || !bytes_ok(rd_rsp_data_i[63:32]);
          else if (beat_q == 2'd1)
            bad_bus = bad_bus || !bytes_ok(rd_rsp_data_i[95:64]);
          else
            bad_bus = bad_bus || !bytes_ok(rd_rsp_data_i[31:0]);
          if (bad_bus) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 2'd0) begin
            beat_q <= 2'd1;
            addr_q <= APU_VGPU_TPR_AT23_ADDR;
            state_q <= Issue;
          end else if (beat_q == 2'd1) begin
            beat_q <= 2'd2;
            addr_q <= APU_VGPU_TPR_ROW63_ADDR;
            state_q <= Issue;
          end else state_q <= Commit;
        end
        Commit: begin
          if (bad_q || beat_q != 2'd2)
            cpl_q.status <= APU_VGPU_TPR_FAULT;
          else begin
            tpr_q.valid <= 1'b1;
            tpr_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            tpr_q.off11 <= APU_VGPU_TPR_AT11;
            tpr_q.off23 <= APU_VGPU_TPR_AT23;
            tpr_q.off063 <= APU_VGPU_TPR_AT063;
            tpr_q.r <= APU_VGPU_CLEAR_R;
            tpr_q.g <= APU_VGPU_CLEAR_G;
            tpr_q.b <= APU_VGPU_CLEAR_B;
            tpr_q.a <= APU_VGPU_CLEAR_A;
            cpl_q.status <= APU_VGPU_TPR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_TPR_OK |->
        tpr_o.valid && tpr_o.format == APU_VIRGL_FMT_B8G8R8X8 &&
        tpr_o.off11 == APU_VGPU_TPR_AT11 &&
        tpr_o.off23 == APU_VGPU_TPR_AT23 &&
        tpr_o.off063 == APU_VGPU_TPR_AT063 &&
        tpr_o.r == APU_VGPU_CLEAR_R && tpr_o.g == APU_VGPU_CLEAR_G &&
        tpr_o.b == APU_VGPU_CLEAR_B && tpr_o.a == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

module g6lc_apu_vgpu_tpr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_ryx_t ryx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpr_cpl_t cpl_o,
  output apu_vgpu_tpr_t tpr_o,
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
  g6lc_apu_vgpu_tpr #(.Enable(Enable)) i_dut (.*);
endmodule
