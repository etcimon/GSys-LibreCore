// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// GET_CAPSET for virgl capset id 1, version 1, after the info refusal.
// The recorded answer is INVALID_PARAMETER. No capset blob is stored.

// CapsetGet (cap): GET_CAPSET. Default-off. No capset blob.
module g6lc_apu_vgpu_cap
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cap_cpl_t cpl_o,
  output apu_vgpu_cap_t cap_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cap_o = '0;
    assign peek_addr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|buf_i) |
                        (|nfo_i) | (|peek_word_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, ReadBody, Commit, Done } state_e;

    state_e state_q;
    apu_vgpu_cap_cpl_t cpl_q;
    apu_vgpu_cap_t cap_q;
    logic [31:0] body_q [0:7];
    logic [2:0] idx_q;
    logic [31:0] base_q;
    logic armed_q;
    logic [31:0] byte_at;

    assign byte_at = base_q + (32'(idx_q) << 2);
    assign peek_addr_o = state_q == ReadBody ? byte_at[APU_VGPU_BUF_ADDRW-1:0] :
                         APU_VGPU_BUF_ADDRW'('0);
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cap_cpl_t'('0);
    assign cap_o = cap_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cap_q <= '0;
        body_q <= '{default: '0};
        idx_q <= '0;
        base_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic [31:0] need;
          need = nfo_i.next + APU_VGPU_CAP_BYTES;
          if (cap_q.refused) begin
            cpl_q.status <= APU_VGPU_CAP_FAULT;
            state_q <= Done;
          end else if (!buf_i.valid || !nfo_i.refused) begin
            cpl_q.status <= APU_VGPU_CAP_EMPTY;
            state_q <= Done;
          end else if (nfo_i.next[1:0] != 2'b00 || need < nfo_i.next ||
                       need > buf_i.size) begin
            cpl_q.status <= APU_VGPU_CAP_FAULT;
            state_q <= Done;
          end else begin
            base_q <= nfo_i.next;
            idx_q <= '0;
            state_q <= ReadBody;
          end
        end
        ReadBody: begin
          body_q[idx_q] <= peek_word_i;
          if (idx_q == 3'd7) state_q <= Commit;
          else idx_q <= idx_q + 3'd1;
        end
        Commit: begin
          if (body_q[0] != VGPU_CMD_GET_CAPSET || body_q[1] != 32'h0 ||
              body_q[2] != 32'h0 || body_q[3] != 32'h0 || body_q[4] != 32'h0 ||
              body_q[5] != 32'h0 || body_q[6] != APU_VGPU_CAPSET_VIRGL ||
              body_q[7] != APU_VGPU_CAPSET_VERSION) begin
            cpl_q.status <= APU_VGPU_CAP_FAULT;
          end else begin
            cap_q.refused <= 1'b1;
            cap_q.resp <= VGPU_RESP_ERR_INVALID_PARAMETER;
            cap_q.next <= base_q + APU_VGPU_CAP_BYTES;
            cpl_q.status <= APU_VGPU_CAP_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cap_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_CAP_OK |->
        cap_o.refused && cap_o.resp == VGPU_RESP_ERR_INVALID_PARAMETER);
    `endif
  end
endmodule

// CapsetGet (cap) enable-0 fixture: GET_CAPSET. Default-off. No capset blob.
module g6lc_apu_vgpu_cap_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_buf_t buf_i,
  input  apu_vgpu_nfo_t nfo_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cap_cpl_t cpl_o,
  output apu_vgpu_cap_t cap_o,
  output logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr_o,
  input  logic [31:0] peek_word_i
);
  g6lc_apu_vgpu_cap #(.Enable(Enable)) i_dut (.*);
endmodule
