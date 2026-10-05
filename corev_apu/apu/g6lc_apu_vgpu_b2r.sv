// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read beat 2 of row 0. (16,0) is byte 64, lane 0.
// (23,0) is byte 92, lane 7. The beat is 64'h88030040.
// This is later than g6lc_apu_vgpu_b7r. The image is not kept.
// The shader is not run.

// ReadbackBeat2 (b2r): (16,0) is byte 64, lane 0 of beat 2. (23,0) is byte 92.
module g6lc_apu_vgpu_b2r
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_b7x_t b7x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2r_cpl_t cpl_o,
  output apu_vgpu_b2r_t b2r_o,
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
    assign b2r_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gbd_i) | (|b7x_i) |
                        (|cxr_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_b2r_cpl_t cpl_q;
    apu_vgpu_b2r_t b2r_q;
    logic bad_q, armed_q;
    logic [63:0] addr_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b2r_cpl_t'('0);
    assign b2r_o = b2r_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b2r_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b2r_q.valid) begin
            cpl_q.status <= APU_VGPU_B2R_FAULT;
            state_q <= Done;
          end else if (!gbd_i.valid || !b7x_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_B2R_EMPTY;
            state_q <= Done;
          end else if (gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b7x_i.b0 != APU_VGPU_CLEAR_R ||
                       b7x_i.off56 != APU_VGPU_B7R_AT56 ||
                       b7x_i.off63 != APU_VGPU_X6R_AT ||
                       b7x_i.x56 != 7'd56 || b7x_i.x63 != 7'd63 ||
                       b7x_i.r != APU_VGPU_CLEAR_R ||
                       b7x_i.g != APU_VGPU_CLEAR_G ||
                       b7x_i.b != APU_VGPU_CLEAR_B ||
                       b7x_i.a != APU_VGPU_CLEAR_A ||
                       b7x_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480) begin
            cpl_q.status <= APU_VGPU_B2R_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_B2R_ADDR;
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
            cpl_q.status <= APU_VGPU_B2R_FAULT;
          else begin
            b2r_q.valid <= 1'b1;
            b2r_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            b2r_q.off16 <= APU_VGPU_B2R_AT16;
            b2r_q.off23 <= APU_VGPU_B2R_AT23;
            b2r_q.x16 <= 7'd16;
            b2r_q.x23 <= 7'd23;
            b2r_q.r <= APU_VGPU_CLEAR_R;
            b2r_q.g <= APU_VGPU_CLEAR_G;
            b2r_q.b <= APU_VGPU_CLEAR_B;
            b2r_q.a <= APU_VGPU_CLEAR_A;
            cpl_q.status <= APU_VGPU_B2R_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B2R_OK |->
        b2r_o.valid && b2r_o.off16 == APU_VGPU_B2R_AT16 &&
        b2r_o.off23 == APU_VGPU_B2R_AT23 &&
        b2r_o.x16 == 7'd16 && b2r_o.x23 == 7'd23 &&
        b2r_o.r == APU_VGPU_CLEAR_R && b2r_o.a == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

// ReadbackBeat2 (b2r) enable-0 fixture: (16,0) is byte 64, lane 0 of beat 2. (23,0) is byte 92.
module g6lc_apu_vgpu_b2r_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_b7x_t b7x_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2r_cpl_t cpl_o,
  output apu_vgpu_b2r_t b2r_o,
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
  g6lc_apu_vgpu_b2r #(.Enable(Enable)) i_dut (.*);
endmodule
