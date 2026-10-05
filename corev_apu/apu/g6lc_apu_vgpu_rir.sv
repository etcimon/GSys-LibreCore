// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the guest used-buffer interrupt reason at 64'h880C0000
// after scene guest ack. The low word is 32'h1. The scene
// status word at 64'h8800E500 records nothing. The pin may
// already have been acknowledged. This is later than
// g6lc_apu_vgpu_riw. This is not g6lc_apu_vgpu_qir and not
// g6lc_apu_vgpu_tir. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferIrqAfterAckKeep (rir): Guest keep of that interrupt reason.
module g6lc_apu_vgpu_rir
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_riw_t riw_i,
  input  apu_vgpu_rux_t rux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rir_cpl_t cpl_o,
  output apu_vgpu_rir_t rir_o,
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
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rir_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|riw_i) | (|rux_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rir_cpl_t cpl_q;
    apu_vgpu_rir_t rir_q;
    logic [31:0] reason_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = APU_VGPU_TIW_ADDR;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rir_cpl_t'('0);
    assign rir_o = rir_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rir_q <= '0;
        reason_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rir_q.valid) begin
            cpl_q.status <= APU_VGPU_RIR_FAULT;
            state_q <= Done;
          end else if (!riw_i.valid || !rux_i.valid) begin
            cpl_q.status <= APU_VGPU_RIR_EMPTY;
            state_q <= Done;
          end else if (riw_i.reason != APU_VGPU_TIW_REASON ||
                       riw_i.used_idx != APU_VGPU_TUW_IDXV ||
                       riw_i.used_idx == 16'd1 ||
                       riw_i.addr != APU_VGPU_TIW_ADDR ||
                       riw_i.addr == APU_VGPU_VIW_ADDR ||
                       rux_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_RIR_FAULT;
            state_q <= Done;
          end else begin
            reason_q <= '0;
            bad_q <= 1'b0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != APU_VGPU_TIW_ADDR ||
                    rd_rsp_addr_i == APU_VGPU_VIW_ADDR ||
                    rd_rsp_len_i != 32'd4 ||
                    rd_rsp_data_i[31:0] != APU_VGPU_TIW_REASON;
          if (bad_bus) bad_q <= 1'b1;
          else reason_q <= rd_rsp_data_i[31:0];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || reason_q != APU_VGPU_TIW_REASON ||
              reason_q != riw_i.reason)
            cpl_q.status <= APU_VGPU_RIR_FAULT;
          else begin
            rir_q.valid <= 1'b1;
            rir_q.reason <= reason_q;
            rir_q.used_idx <= riw_i.used_idx;
            rir_q.addr <= APU_VGPU_TIW_ADDR;
            cpl_q.status <= APU_VGPU_RIR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rir_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RIR_OK |->
        rir_o.valid && rir_o.reason == APU_VGPU_TIW_REASON &&
        rir_o.used_idx == APU_VGPU_TUW_IDXV &&
        rir_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferIrqAfterAckKeep (rir) enable-0 fixture: Guest keep of that interrupt reason.
module g6lc_apu_vgpu_rir_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_riw_t riw_i,
  input  apu_vgpu_rux_t rux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rir_cpl_t cpl_o,
  output apu_vgpu_rir_t rir_o,
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
  g6lc_apu_vgpu_rir #(.Enable(Enable)) i_dut (.*);
endmodule
