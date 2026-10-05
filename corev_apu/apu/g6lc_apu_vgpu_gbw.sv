// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Copy the scanned 64 by 64 window from 64'h88020000 into the guest
// readback buffer at 64'h88030000. Each beat is read, checked, and
// written. The image is not kept. A beat that is not the clear word
// stops the copy. This is not Mesa glReadPixels and not the ceiling
// at 32'h88040000. The shader is not run.

// ReadbackCopy (gbw): Copy of that window into the guest readback buffer.
module g6lc_apu_vgpu_gbw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wfr_t wfr_i,
  input  apu_vgpu_wfk_t wfk_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_vak_t vak_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbw_cpl_t cpl_o,
  output apu_vgpu_gbw_t gbw_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  localparam logic [255:0] Pat = {8{APU_VGPU_CLEAR_WORD}};

  function automatic logic [63:0] src_addr(input logic [8:0] beat);
    src_addr = APU_VGPU_GPW_ADDR + (64'(beat) << 5);
  endfunction

  function automatic logic [63:0] dst_addr(input logic [8:0] beat);
    dst_addr = APU_VGPU_GBW_ADDR + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gbw_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i | wr_rsp_valid_i |
                        wr_rsp_ok_i | (|wfr_i) | (|wfk_i) | (|gpk_i) | (|cwr_i) |
                        (|cxr_i) | (|vak_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, RdIssue, RdWait, WrIssue, WrWait, Commit, Done
    } state_e;
    state_e state_q;
    apu_vgpu_gbw_cpl_t cpl_q;
    apu_vgpu_gbw_t gbw_q;
    logic [8:0] beat_q;
    logic [31:0] word_q, pix10_q, pix63_q;
    logic [255:0] data_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == RdIssue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == RdWait;
    assign wr_valid_o = state_q == WrIssue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign wr_data_o = data_q;
    assign wr_rsp_ready_o = state_q == WrWait;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbw_cpl_t'('0);
    assign gbw_o = gbw_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbw_q <= '0;
        beat_q <= '0;
        word_q <= '0;
        pix10_q <= '0;
        pix63_q <= '0;
        data_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbw_q.valid) begin
            cpl_q.status <= APU_VGPU_GBW_FAULT;
            state_q <= Done;
          end else if (!wfr_i.valid || !wfk_i.valid || !gpk_i.valid ||
                       !cwr_i.valid || !cxr_i.valid || !vak_i.valid) begin
            cpl_q.status <= APU_VGPU_GBW_EMPTY;
            state_q <= Done;
          end else if (wfr_i.word != APU_VGPU_CLEAR_WORD ||
                       wfr_i.pix10 != wfr_i.word ||
                       wfr_i.pix63 != wfr_i.word ||
                       wfr_i.beats != APU_VGPU_GPW_BEATS ||
                       wfr_i.base != APU_VGPU_GPW_ADDR ||
                       wfr_i.tail != APU_VGPU_GPW_TAIL ||
                       wfk_i.word != wfr_i.word ||
                       wfk_i.pix10 != wfr_i.pix10 ||
                       wfk_i.beats != wfr_i.beats ||
                       gpk_i.word != wfr_i.word ||
                       cwr_i.word != wfr_i.word ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       vak_i.ack != APU_VGPU_VIW_REASON ||
                       vak_i.remain != APU_VGPU_VAW_CLEAR) begin
            cpl_q.status <= APU_VGPU_GBW_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 9'd0;
            word_q <= '0;
            pix10_q <= '0;
            pix63_q <= '0;
            bad_q <= 1'b0;
            addr_q <= src_addr(9'd0);
            state_q <= RdIssue;
          end
        end
        RdIssue: if (rd_ready_i) state_q <= RdWait;
        RdWait: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES) ||
                    rd_rsp_data_i != Pat;
          if (bad_bus) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else begin
            data_q <= rd_rsp_data_i;
            if (beat_q == 9'd0) begin
              word_q <= rd_rsp_data_i[31:0];
              pix10_q <= rd_rsp_data_i[63:32];
            end
            addr_q <= dst_addr(beat_q);
            state_q <= WrIssue;
          end
        end
        WrIssue: if (wr_ready_i) state_q <= WrWait;
        WrWait: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == APU_VGPU_GPW_LAST) begin
            pix63_q <= data_q[255:224];
            state_q <= Commit;
          end else begin
            beat_q <= beat_q + 9'd1;
            addr_q <= src_addr(beat_q + 9'd1);
            state_q <= RdIssue;
          end
        end
        Commit: begin
          if (bad_q || beat_q != APU_VGPU_GPW_LAST ||
              word_q != APU_VGPU_CLEAR_WORD || pix10_q != word_q ||
              pix63_q != word_q)
            cpl_q.status <= APU_VGPU_GBW_FAULT;
          else begin
            gbw_q.valid <= 1'b1;
            gbw_q.word <= word_q;
            gbw_q.beats <= APU_VGPU_GPW_BEATS;
            gbw_q.src <= APU_VGPU_GPW_ADDR;
            gbw_q.dst <= APU_VGPU_GBW_ADDR;
            cpl_q.status <= APU_VGPU_GBW_OK;
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
      rd_valid_o && wr_valid_o |-> 1'b0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GBW_OK |->
        gbw_o.valid && gbw_o.word == APU_VGPU_CLEAR_WORD &&
        gbw_o.beats == APU_VGPU_GPW_BEATS &&
        gbw_o.src == APU_VGPU_GPW_ADDR && gbw_o.dst == APU_VGPU_GBW_ADDR &&
        gbw_o.src != gbw_o.dst);
    `endif
  end
endmodule

// ReadbackCopy (gbw) enable-0 fixture: Copy of that window into the guest readback buffer.
module g6lc_apu_vgpu_gbw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wfr_t wfr_i,
  input  apu_vgpu_wfk_t wfk_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_vak_t vak_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbw_cpl_t cpl_o,
  output apu_vgpu_gbw_t gbw_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_gbw #(.Enable(Enable)) i_dut (.*);
endmodule
