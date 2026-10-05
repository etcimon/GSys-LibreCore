// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read beat 4 of row 0. (32,0) is byte 128, lane 0.
// (39,0) is byte 156, lane 7. The beat is 64'h88030080.
// This is later than g6lc_apu_vgpu_b3r. The image is not kept.
// The shader is not run.

// ReadbackBeat4 (b4r): (32,0) is byte 128, lane 0 of beat 4. (39,0) is byte 156.
module g6lc_apu_vgpu_b4r
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_b3x_t b3x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b4r_cpl_t cpl_o,
  output apu_vgpu_b4r_t b4r_o,
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
    assign b4r_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|b3x_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_b4r_cpl_t cpl_q;
    apu_vgpu_b4r_t b4r_q;
    logic bad_q, armed_q;
    logic [63:0] addr_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b4r_cpl_t'('0);
    assign b4r_o = b4r_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b4r_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b4r_q.valid) begin
            cpl_q.status <= APU_VGPU_B4R_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !b3x_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_B4R_EMPTY;
            state_q <= Done;
          end else if (gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b3x_i.b0 != APU_VGPU_CLEAR_R ||
                       b3x_i.off24 != APU_VGPU_B3R_AT24 ||
                       b3x_i.off31 != APU_VGPU_B3R_AT31 ||
                       b3x_i.x24 != 7'd24 || b3x_i.x31 != 7'd31 ||
                       b3x_i.r != APU_VGPU_CLEAR_R ||
                       b3x_i.g != APU_VGPU_CLEAR_G ||
                       b3x_i.b != APU_VGPU_CLEAR_B ||
                       b3x_i.a != APU_VGPU_CLEAR_A ||
                       b3x_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_B4R_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_B4R_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    rd_rsp_data_i != Pat ||
                    !bytes_ok(rd_rsp_data_i[31:0]) ||
                    !bytes_ok(rd_rsp_data_i[255:224]);
          if (bad_bus) bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_B4R_FAULT;
          else begin
            b4r_q.valid <= 1'b1;
            b4r_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            b4r_q.off32 <= APU_VGPU_B4R_AT32;
            b4r_q.off39 <= APU_VGPU_B4R_AT39;
            b4r_q.x32 <= 7'd32;
            b4r_q.x39 <= 7'd39;
            b4r_q.r <= APU_VGPU_CLEAR_R;
            b4r_q.g <= APU_VGPU_CLEAR_G;
            b4r_q.b <= APU_VGPU_CLEAR_B;
            b4r_q.a <= APU_VGPU_CLEAR_A;
            cpl_q.status <= APU_VGPU_B4R_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B4R_OK |->
        b4r_o.valid && b4r_o.off32 == APU_VGPU_B4R_AT32 &&
        b4r_o.off39 == APU_VGPU_B4R_AT39 &&
        b4r_o.x32 == 7'd32 && b4r_o.x39 == 7'd39 &&
        b4r_o.r == APU_VGPU_CLEAR_R && b4r_o.a == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

// ReadbackBeat4 (b4r) enable-0 fixture: (32,0) is byte 128, lane 0 of beat 4. (39,0) is byte 156.
module g6lc_apu_vgpu_b4r_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_b3x_t b3x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b4r_cpl_t cpl_o,
  output apu_vgpu_b4r_t b4r_o,
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
  g6lc_apu_vgpu_b4r #(.Enable(Enable)) i_dut (.*);
endmodule
