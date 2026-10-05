// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read (63,0) in the readback. The offset is 252, lane 7 of the
// beat at 64'h880300E0. Byte 0 of that lane is red. This is later
// than g6lc_apu_vgpu_tpr. (0,63) is byte 16128 and is not this point.
// The image is not kept. The shader is not run.

// ReadbackX63 (x6r): (63,0) of the readback is byte 252.
module g6lc_apu_vgpu_x6r
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_tpx_t tpx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6r_cpl_t cpl_o,
  output apu_vgpu_x6r_t x6r_o,
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
    assign x6r_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|tpx_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_x6r_cpl_t cpl_q;
    apu_vgpu_x6r_t x6r_q;
    logic bad_q, armed_q;
    logic [63:0] addr_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_x6r_cpl_t'('0);
    assign x6r_o = x6r_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        x6r_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (x6r_q.valid) begin
            cpl_q.status <= APU_VGPU_X6R_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !tpx_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_X6R_EMPTY;
            state_q <= Done;
          end else if (gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tpx_i.b0 != APU_VGPU_CLEAR_R ||
                       tpx_i.r != APU_VGPU_CLEAR_R ||
                       tpx_i.g != APU_VGPU_CLEAR_G ||
                       tpx_i.b != APU_VGPU_CLEAR_B ||
                       tpx_i.a != APU_VGPU_CLEAR_A ||
                       tpx_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tpx_i.off11 != APU_VGPU_TPR_AT11 ||
                       tpx_i.off23 != APU_VGPU_TPR_AT23 ||
                       tpx_i.off063 != APU_VGPU_TPR_AT063 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_X6R_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_X6R_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    rd_rsp_data_i != Pat ||
                    !bytes_ok(rd_rsp_data_i[255:224]);
          if (bad_bus) bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_X6R_FAULT;
          else begin
            x6r_q.valid <= 1'b1;
            x6r_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            x6r_q.offset <= APU_VGPU_X6R_AT;
            x6r_q.x <= 7'd63;
            x6r_q.y <= 7'd0;
            x6r_q.r <= APU_VGPU_CLEAR_R;
            x6r_q.g <= APU_VGPU_CLEAR_G;
            x6r_q.b <= APU_VGPU_CLEAR_B;
            x6r_q.a <= APU_VGPU_CLEAR_A;
            cpl_q.status <= APU_VGPU_X6R_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_X6R_OK |->
        x6r_o.valid && x6r_o.offset == APU_VGPU_X6R_AT &&
        x6r_o.x == 7'd63 && x6r_o.y == 7'd0 &&
        x6r_o.r == APU_VGPU_CLEAR_R && x6r_o.a == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

// ReadbackX63 (x6r) enable-0 fixture: (63,0) of the readback is byte 252.
module g6lc_apu_vgpu_x6r_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_tpx_t tpx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6r_cpl_t cpl_o,
  output apu_vgpu_x6r_t x6r_o,
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
  g6lc_apu_vgpu_x6r #(.Enable(Enable)) i_dut (.*);
endmodule
