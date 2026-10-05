// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the used element at 64'h880B0000 and used.idx 2 at
// 64'h880B0008 after the guest OK_NODATA after scene guest ack.
// Descriptor 0 or index 1 records nothing. This is later than
// g6lc_apu_vgpu_ruw. This is not g6lc_apu_vgpu_qul and not
// g6lc_apu_vgpu_tur. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferUsedAfterAckKeep (rul): Guest keep of that used element.
module g6lc_apu_vgpu_rul
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ruw_t ruw_i,
  input  apu_vgpu_roy_t roy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rul_cpl_t cpl_o,
  output apu_vgpu_rul_t rul_o,
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
  function automatic logic [63:0] step_addr(input logic beat);
    step_addr = beat == 1'b0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
  endfunction

  function automatic logic [31:0] step_len(input logic beat);
    step_len = beat == 1'b0 ? 32'd8 : 32'd4;
  endfunction

  function automatic logic beat_bad(input logic beat, input logic [255:0] data);
    if (beat == 1'b0)
      beat_bad = data[31:0] != APU_VGPU_TUW_ID ||
                 data[31:0] == 32'd0 ||
                 data[63:32] != VGPU_RESP_HDR_BYTES;
    else
      beat_bad = data[15:0] != 16'd0 ||
                 data[31:16] != APU_VGPU_TUW_IDXV ||
                 data[31:16] == 16'd1;
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rul_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|ruw_i) | (|roy_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rul_cpl_t cpl_q;
    apu_vgpu_rul_t rul_q;
    logic beat_q;
    logic [31:0] id_q, len_q;
    logic [15:0] idx_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = step_len(beat_q);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rul_cpl_t'('0);
    assign rul_o = rul_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rul_q <= '0;
        beat_q <= 1'b0;
        id_q <= '0;
        len_q <= '0;
        idx_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rul_q.valid) begin
            cpl_q.status <= APU_VGPU_RUL_FAULT;
            state_q <= Done;
          end else if (!ruw_i.valid || !roy_i.valid) begin
            cpl_q.status <= APU_VGPU_RUL_EMPTY;
            state_q <= Done;
          end else if (ruw_i.elem_id != APU_VGPU_TUW_ID ||
                       ruw_i.elem_id == 32'd0 ||
                       ruw_i.used_idx != APU_VGPU_TUW_IDXV ||
                       ruw_i.used_idx == 16'd1 ||
                       ruw_i.elem_addr != APU_VGPU_TUW_ELEM ||
                       ruw_i.elem_addr == APU_VGPU_GCW_ELEM ||
                       ruw_i.idx_addr != APU_VGPU_TUW_IDX ||
                       roy_i.fence != APU_VGPU_RFW_FENCE) begin
            cpl_q.status <= APU_VGPU_RUL_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            id_q <= '0;
            len_q <= '0;
            idx_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_TUW_ELEM;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != step_len(beat_q);
          if (bad_bus || beat_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            id_q <= rd_rsp_data_i[31:0];
            len_q <= rd_rsp_data_i[63:32];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_TUW_IDX;
            state_q <= Issue;
          end else begin
            idx_q <= rd_rsp_data_i[31:16];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || id_q != APU_VGPU_TUW_ID || id_q == 32'd0 ||
              len_q != VGPU_RESP_HDR_BYTES ||
              idx_q != APU_VGPU_TUW_IDXV || idx_q == 16'd1)
            cpl_q.status <= APU_VGPU_RUL_FAULT;
          else begin
            rul_q.valid <= 1'b1;
            rul_q.elem_id <= id_q;
            rul_q.elem_len <= len_q;
            rul_q.used_idx <= idx_q;
            rul_q.elem_addr <= APU_VGPU_TUW_ELEM;
            rul_q.idx_addr <= APU_VGPU_TUW_IDX;
            cpl_q.status <= APU_VGPU_RUL_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rul_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RUL_OK |->
        rul_o.valid && rul_o.elem_id == APU_VGPU_TUW_ID &&
        rul_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TransferUsedAfterAckKeep (rul) enable-0 fixture: Guest keep of that used element.
module g6lc_apu_vgpu_rul_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ruw_t ruw_i,
  input  apu_vgpu_roy_t roy_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rul_cpl_t cpl_o,
  output apu_vgpu_rul_t rul_o,
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
  g6lc_apu_vgpu_rul #(.Enable(Enable)) i_dut (.*);
endmodule
