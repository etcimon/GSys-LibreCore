// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read all 512 beats of the 64 by 64 window at 64'h88020000.
// Every beat is eight copies of 32'hFF1A0D0D. The image is not kept.
// (0,0) is the low word of beat 0. (1,0) is byte 4 of that beat.
// (63,63) is the top lane of the last beat at 64'h88023FE0.
// A 64-high scissor reads nothing. This is not g6lc_apu_vgpu_gpr,
// not g6lc_apu_vgpu_frd, and not g6lc_apu_vgpu_pxr.
// The shader is not run. A failed beat stops the walk.

// ClearWindowScan (wfr): Every beat of the 64 by 64 clear-word window.
module g6lc_apu_vgpu_wfr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vak_t vak_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wfr_cpl_t cpl_o,
  output apu_vgpu_wfr_t wfr_o,
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

  function automatic logic [63:0] beat_addr(input logic [8:0] beat);
    beat_addr = APU_VGPU_GPW_ADDR + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign wfr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|vak_i) | (|gpk_i) |
                        (|cwr_i) | (|cxr_i) | (|ols_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_wfr_cpl_t cpl_q;
    apu_vgpu_wfr_t wfr_q;
    logic [8:0] beat_q;
    logic [31:0] word_q, pix10_q, pix63_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_wfr_cpl_t'('0);
    assign wfr_o = wfr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        wfr_q <= '0;
        beat_q <= '0;
        word_q <= '0;
        pix10_q <= '0;
        pix63_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (wfr_q.valid) begin
            cpl_q.status <= APU_VGPU_WFR_FAULT;
            state_q <= Done;
          end else if (!vak_i.valid || !gpk_i.valid || !cwr_i.valid ||
                       !cxr_i.valid || !ols_i.valid) begin
            cpl_q.status <= APU_VGPU_WFR_EMPTY;
            state_q <= Done;
          end else if (vak_i.ack != APU_VGPU_VIW_REASON ||
                       vak_i.remain != APU_VGPU_VAW_CLEAR ||
                       vak_i.used_idx != 16'd1 ||
                       gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.first != APU_VGPU_GPW_ADDR ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       gpk_i.word != cwr_i.word ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0) begin
            cpl_q.status <= APU_VGPU_WFR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 9'd0;
            word_q <= '0;
            pix10_q <= '0;
            pix63_q <= '0;
            bad_q <= 1'b0;
            addr_q <= beat_addr(9'd0);
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    rd_rsp_data_i != Pat;
          if (bad_bus) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 9'd0) begin
            word_q <= rd_rsp_data_i[31:0];
            pix10_q <= rd_rsp_data_i[63:32];
            beat_q <= 9'd1;
            addr_q <= beat_addr(9'd1);
            state_q <= Issue;
          end else if (beat_q == APU_VGPU_GPW_LAST) begin
            pix63_q <= rd_rsp_data_i[255:224];
            state_q <= Commit;
          end else begin
            beat_q <= beat_q + 9'd1;
            addr_q <= beat_addr(beat_q + 9'd1);
            state_q <= Issue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GPW_LAST ||
              word_q != APU_VGPU_CLEAR_WORD || pix10_q != word_q ||
              pix63_q != word_q || gpk_i.word != word_q)
            cpl_q.status <= APU_VGPU_WFR_FAULT;
          else begin
            wfr_q.valid <= 1'b1;
            wfr_q.word <= word_q;
            wfr_q.pix10 <= pix10_q;
            wfr_q.pix63 <= pix63_q;
            wfr_q.beats <= APU_VGPU_GPW_BEATS;
            wfr_q.base <= APU_VGPU_GPW_ADDR;
            wfr_q.tail <= APU_VGPU_GPW_TAIL;
            cpl_q.status <= APU_VGPU_WFR_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_WFR_OK |->
        wfr_o.valid && wfr_o.beats == APU_VGPU_GPW_BEATS &&
        wfr_o.word == APU_VGPU_CLEAR_WORD && wfr_o.pix10 == wfr_o.word &&
        wfr_o.pix63 == wfr_o.word && wfr_o.base == APU_VGPU_GPW_ADDR &&
        wfr_o.tail == APU_VGPU_GPW_TAIL);
    `endif
  end
endmodule

// ClearWindowScan (wfr) enable-0 fixture: Every beat of the 64 by 64 clear-word window.
module g6lc_apu_vgpu_wfr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vak_t vak_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wfr_cpl_t cpl_o,
  output apu_vgpu_wfr_t wfr_o,
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
  g6lc_apu_vgpu_wfr #(.Enable(Enable)) i_dut (.*);
endmodule
