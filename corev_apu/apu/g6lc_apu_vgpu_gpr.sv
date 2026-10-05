// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the first and last beats of the 64 by 64 clear-word window.
// Both beats are eight copies of 32'hFF1A0D0D. The other beats stay
// in guest memory. This is not g6lc_apu_vgpu_frd and not
// g6lc_apu_vgpu_pxr. The shader is not run. This is not the screenshot.

// ClearWindowRead (gpr): First and last beats of that window.
module g6lc_apu_vgpu_gpr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpw_t gpw_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpr_cpl_t cpl_o,
  output apu_vgpu_gpr_t gpr_o,
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
  localparam logic [APU_VGPU_BEAT_BYTES*8-1:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  function automatic logic beat_bad(input logic [255:0] data);
    beat_bad = data != Pat;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gpr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|gpw_i) | (|cwr_i) |
                        (|ols_i) | (|nxc_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_gpr_cpl_t cpl_q;
    apu_vgpu_gpr_t gpr_q;
    logic beat_q;
    logic [31:0] word_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gpr_cpl_t'('0);
    assign gpr_o = gpr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gpr_q <= '0;
        beat_q <= 1'b0;
        word_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gpr_q.valid) begin
            cpl_q.status <= APU_VGPU_GPR_FAULT;
            state_q <= Done;
          end else if (!gpw_i.valid || !cwr_i.valid || !ols_i.valid || !nxc_i.valid) begin
            cpl_q.status <= APU_VGPU_GPR_EMPTY;
            state_q <= Done;
          end else if (gpw_i.beats != APU_VGPU_GPW_BEATS ||
                       gpw_i.word != APU_VGPU_CLEAR_WORD ||
                       gpw_i.base != APU_VGPU_GPW_ADDR ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       cwr_i.word != gpw_i.word ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       nxc_i.head != 16'd0 || nxc_i.buf_addr != APU_VGPU_EXEC_ADDR) begin
            cpl_q.status <= APU_VGPU_GPR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            word_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_GPW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            word_q <= rd_rsp_data_i[31:0];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_GPW_TAIL;
            state_q <= Issue;
          end else begin
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || word_q != APU_VGPU_CLEAR_WORD || word_q != gpw_i.word)
            cpl_q.status <= APU_VGPU_GPR_FAULT;
          else begin
            gpr_q.valid <= 1'b1;
            gpr_q.word <= word_q;
            gpr_q.first <= APU_VGPU_GPW_ADDR;
            gpr_q.last <= APU_VGPU_GPW_TAIL;
            cpl_q.status <= APU_VGPU_GPR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GPR_OK |->
        gpr_o.valid && gpr_o.word == APU_VGPU_CLEAR_WORD &&
        gpr_o.first == APU_VGPU_GPW_ADDR && gpr_o.last == APU_VGPU_GPW_TAIL &&
        gpr_o.first != gpr_o.last);
    `endif
  end
endmodule

// ClearWindowRead (gpr) enable-0 fixture: First and last beats of that window.
module g6lc_apu_vgpu_gpr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpw_t gpw_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_nxc_t nxc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpr_cpl_t cpl_o,
  output apu_vgpu_gpr_t gpr_o,
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
  g6lc_apu_vgpu_gpr #(.Enable(Enable)) i_dut (.*);
endmodule
