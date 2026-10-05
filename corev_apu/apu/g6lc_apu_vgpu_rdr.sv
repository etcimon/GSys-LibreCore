// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the 512 ceiling beats at 32'h88040000. Beat 0's low word must
// match the write record. Beat 24's low word must match the stored
// (0,3) sample. The image is not kept. A failed beat stops the walk;
// the whole request can be repeated. TEX is not executed.

// CeilingBeatRead (rdr): Read the 512 ceiling beats back.
module g6lc_apu_vgpu_rdr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rbk_t rbk_i,
  input  apu_vgpu_smx_t smx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rdr_cpl_t cpl_o,
  output apu_vgpu_rdr_t rdr_o,
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
  function automatic logic [63:0] beat_addr(input logic [9:0] beat);
    beat_addr = {32'h0, APU_VGPU_CEIL_RB} + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rdr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|rbk_i) | (|smx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rdr_cpl_t cpl_q;
    apu_vgpu_rdr_t rdr_q;
    logic [9:0] beat_q;
    logic [31:0] word0_q, at03_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rdr_cpl_t'('0);
    assign rdr_o = rdr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rdr_q <= '0;
        beat_q <= '0;
        word0_q <= '0;
        at03_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rdr_q.valid) begin
            cpl_q.status <= APU_VGPU_RDR_FAULT;
            state_q <= Done;
          end else if (!rbk_i.valid || !smx_i.valid) begin
            cpl_q.status <= APU_VGPU_RDR_EMPTY;
            state_q <= Done;
          end else if (rbk_i.beats != APU_VGPU_CEIL_BEATS ||
                       rbk_i.last_addr != beat_addr(10'd511) ||
                       rbk_i.word0 == smx_i.word || smx_i.word == 32'h0) begin
            cpl_q.status <= APU_VGPU_RDR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= '0;
            word0_q <= '0;
            at03_q <= '0;
            bad_q <= 1'b0;
            addr_q <= beat_addr(10'd0);
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 10'd0 && rd_rsp_data_i[31:0] != rbk_i.word0) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 10'd24 && rd_rsp_data_i[31:0] != smx_i.word) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else begin
            if (beat_q == 10'd0) word0_q <= rd_rsp_data_i[31:0];
            if (beat_q == 10'd24) at03_q <= rd_rsp_data_i[31:0];
            if (beat_q == 10'd511) state_q <= Commit;
            else begin
              beat_q <= beat_q + 10'd1;
              addr_q <= beat_addr(beat_q + 10'd1);
              state_q <= Issue;
            end
          end
        end
        Commit: begin
          if (bad_q || word0_q != rbk_i.word0 || at03_q != smx_i.word) begin
            cpl_q.status <= APU_VGPU_RDR_FAULT;
          end else begin
            rdr_q.valid <= 1'b1;
            rdr_q.word0 <= word0_q;
            rdr_q.at03 <= at03_q;
            rdr_q.beats <= APU_VGPU_CEIL_BEATS;
            cpl_q.status <= APU_VGPU_RDR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_RDR_OK |->
        rdr_o.valid && rdr_o.beats == APU_VGPU_CEIL_BEATS &&
        rdr_o.word0 != rdr_o.at03);
    `endif
  end
endmodule

// CeilingBeatRead (rdr) enable-0 fixture: Read the 512 ceiling beats back.
module g6lc_apu_vgpu_rdr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rbk_t rbk_i,
  input  apu_vgpu_smx_t smx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rdr_cpl_t cpl_o,
  output apu_vgpu_rdr_t rdr_o,
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
  g6lc_apu_vgpu_rdr #(.Enable(Enable)) i_dut (.*);
endmodule
