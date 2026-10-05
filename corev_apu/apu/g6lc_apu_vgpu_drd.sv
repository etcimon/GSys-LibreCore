// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the DRAW_VBO at byte 908 of the execbuffer g6lc_apu_vgpu_fet
// already accepted. Beat 28 at 64'h8800B380 carries the header in
// bits [127:96]: 12 body dwords, object 0, opcode 8. The next words
// are start 0, count 4, triangle strip 5, and indexed 0. Beat 29 at
// 64'h8800B3A0 carries one instance and max index 3. The low 12 bytes
// of beat 28 are the clear tail and are not part of this command.
// The 960 bytes are not kept. The draw is not executed. This is not
// g6lc_apu_vgpu_drw and not g6lc_apu_vgpu_avail. A failed beat stops
// the read; the request can be repeated. TEX is not executed.

// DrawVboRead (drd): DRAW_VBO at byte 908 of the fetched execbuffer.
module g6lc_apu_vgpu_drd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_drd_cpl_t cpl_o,
  output apu_vgpu_drd_t drd_o,
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
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign drd_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_drd_cpl_t cpl_q;
    apu_vgpu_drd_t drd_q;
    logic beat_q;
    logic [31:0] count_q, prim_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_drd_cpl_t'('0);
    assign drd_o = drd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        drd_q <= '0;
        beat_q <= 1'b0;
        count_q <= '0;
        prim_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (drd_q.valid) begin
            cpl_q.status <= APU_VGPU_DRD_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid) begin
            cpl_q.status <= APU_VGPU_DRD_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_DRD_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            count_q <= '0;
            prim_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_DRAW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus, bad_b0, bad_b1;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          // Header at byte 12 of the beat. Start, count, strip, indexed follow.
          bad_b0 = rd_rsp_data_i[127:96] != APU_VIRGL_DRAW_HDR ||
                   rd_rsp_data_i[159:128] != 32'h0 ||
                   rd_rsp_data_i[191:160] != APU_VIRGL_VERT_COUNT ||
                   rd_rsp_data_i[223:192] != APU_VIRGL_PRIM_STRIP ||
                   rd_rsp_data_i[255:224] != 32'h0;
          // Instance count, then five zeros, max index 3, count-from-so 0.
          bad_b1 = rd_rsp_data_i[31:0] != 32'd1 ||
                   rd_rsp_data_i[63:32] != 32'h0 ||
                   rd_rsp_data_i[95:64] != 32'h0 ||
                   rd_rsp_data_i[127:96] != 32'h0 ||
                   rd_rsp_data_i[159:128] != 32'h0 ||
                   rd_rsp_data_i[191:160] != 32'h0 ||
                   rd_rsp_data_i[223:192] != 32'd3 ||
                   rd_rsp_data_i[255:224] != 32'h0;
          if (bad_bus || (beat_q == 1'b0 && bad_b0) || (beat_q == 1'b1 && bad_b1)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            count_q <= rd_rsp_data_i[191:160];
            prim_q <= rd_rsp_data_i[223:192];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_DRAW_LAST;
            state_q <= Issue;
          end else state_q <= Commit;
        end
        Commit: begin
          if (bad_q || count_q != APU_VIRGL_VERT_COUNT ||
              prim_q != APU_VIRGL_PRIM_STRIP) cpl_q.status <= APU_VGPU_DRD_FAULT;
          else begin
            drd_q.valid <= 1'b1;
            drd_q.count <= count_q;
            drd_q.prim <= prim_q;
            cpl_q.status <= APU_VGPU_DRD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(drd_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_DRD_OK |->
        drd_o.valid && drd_o.count == APU_VIRGL_VERT_COUNT &&
        drd_o.prim == APU_VIRGL_PRIM_STRIP);
    `endif
  end
endmodule

// DrawVboRead (drd) enable-0 fixture: DRAW_VBO at byte 908 of the fetched execbuffer.
module g6lc_apu_vgpu_drd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_drd_cpl_t cpl_o,
  output apu_vgpu_drd_t drd_o,
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
  g6lc_apu_vgpu_drd #(.Enable(Enable)) i_dut (.*);
endmodule
