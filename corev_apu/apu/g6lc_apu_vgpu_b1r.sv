// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read beat 1 of row 0. (8,0) is byte 32, lane 0. (15,0) is byte
// 60, lane 7. The beat is 64'h88030020. (7,0) is byte 28 in the
// base beat and is not this beat. The image is not kept.
// The shader is not run.

// ReadbackBeat1 (b1r): Beat 1 of row 0, bytes 32 and 60.
module g6lc_apu_vgpu_b1r
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_p7x_t p7x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b1r_cpl_t cpl_o,
  output apu_vgpu_b1r_t b1r_o,
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
    assign b1r_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|p7x_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_b1r_cpl_t cpl_q;
    apu_vgpu_b1r_t b1r_q;
    logic bad_q, armed_q;
    logic [63:0] addr_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b1r_cpl_t'('0);
    assign b1r_o = b1r_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b1r_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b1r_q.valid) begin
            cpl_q.status <= APU_VGPU_B1R_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !p7x_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_B1R_EMPTY;
            state_q <= Done;
          end else if (gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       p7x_i.b0 != APU_VGPU_CLEAR_R ||
                       p7x_i.offset != APU_VGPU_P7R_AT ||
                       p7x_i.x != 7'd7 || p7x_i.y != 7'd0 ||
                       p7x_i.r != APU_VGPU_CLEAR_R ||
                       p7x_i.g != APU_VGPU_CLEAR_G ||
                       p7x_i.b != APU_VGPU_CLEAR_B ||
                       p7x_i.a != APU_VGPU_CLEAR_A ||
                       p7x_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_B1R_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_B1R_ADDR;
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
            cpl_q.status <= APU_VGPU_B1R_FAULT;
          else begin
            b1r_q.valid <= 1'b1;
            b1r_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            b1r_q.off8 <= APU_VGPU_B1R_AT8;
            b1r_q.off15 <= APU_VGPU_B1R_AT15;
            b1r_q.x8 <= 7'd8;
            b1r_q.x15 <= 7'd15;
            b1r_q.r <= APU_VGPU_CLEAR_R;
            b1r_q.g <= APU_VGPU_CLEAR_G;
            b1r_q.b <= APU_VGPU_CLEAR_B;
            b1r_q.a <= APU_VGPU_CLEAR_A;
            cpl_q.status <= APU_VGPU_B1R_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B1R_OK |->
        b1r_o.valid && b1r_o.off8 == APU_VGPU_B1R_AT8 &&
        b1r_o.off15 == APU_VGPU_B1R_AT15 &&
        b1r_o.x8 == 7'd8 && b1r_o.x15 == 7'd15 &&
        b1r_o.r == APU_VGPU_CLEAR_R && b1r_o.a == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

// ReadbackBeat1 (b1r) enable-0 fixture: Beat 1 of row 0, bytes 32 and 60.
module g6lc_apu_vgpu_b1r_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_p7x_t p7x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b1r_cpl_t cpl_o,
  output apu_vgpu_b1r_t b1r_o,
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
  g6lc_apu_vgpu_b1r #(.Enable(Enable)) i_dut (.*);
endmodule
