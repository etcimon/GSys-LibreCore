// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write the 64 by 64 ceiling to 32'h88040000. Eight samples per beat,
// 512 beats, 16384 bytes. The sampler is used one point at a time.
// The image is not kept. A failed sample or a failed beat stops the
// walk; the whole request can be repeated. TEX is not executed.

module g6lc_apu_vgpu_rbf
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_ss_t ss_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_spx_t spx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  apu_vgpu_vbr_t vbr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rbf_cpl_t cpl_o,
  output apu_vgpu_rbf_t rbf_o,
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
  function automatic logic [63:0] beat_addr(input logic [8:0] beat);
    beat_addr = {32'h0, APU_VGPU_CEIL_RB} + (64'(beat) << 5);
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rbf_o = '0;
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
                        wr_rsp_ok_i | (|bcp_i) | (|sbk_i) | (|tbn_i) | (|ss_i) |
                        (|lnr_i) | (|spx_i) | (|vlr_i) | (|vbr_i) | (|vsx_i) |
                        (|y2r_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, Samp, WaitCpl, Take, Issue, WaitWr, Commit, Done
    } state_e;
    state_e state_q;
    apu_vgpu_rbf_cpl_t cpl_q;
    apu_vgpu_rbf_t rbf_q;
    apu_vgpu_rbf_status_e kind_q;
    logic [5:0] x_q, y_q;
    logic [2:0] slot_q;
    logic [255:0] pack_q;
    logic [31:0] word0_q, got_q;
    logic [63:0] wr_addr_q;
    apu_vgpu_smp_status_e st_q;
    logic held_q, xy_ok_q, bad_q, armed_q;
    logic smp_req, smp_rdy, smp_cpl_v, smp_cpl_r;
    apu_vgpu_smp_cpl_t smp_cpl;
    apu_vgpu_smp_t smp_s;

    g6lc_apu_vgpu_smp #(.Enable(1'b1)) i_smp (
      .clk_i, .rst_ni, .bcp_i, .sbk_i, .tbn_i, .ss_i, .lnr_i, .spx_i, .vlr_i,
      .vbr_i, .vsx_i, .y2r_i,
      .x_i({10'b0, x_q}), .y_i({10'b0, y_q}),
      .req_valid_i(smp_req), .req_ready_o(smp_rdy),
      .cpl_valid_o(smp_cpl_v), .cpl_ready_i(smp_cpl_r),
      .cpl_o(smp_cpl), .smp_o(smp_s),
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o, .rd_rsp_ok_i,
      .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i
    );

    assign smp_req = state_q == Samp;
    assign smp_cpl_r = state_q == WaitCpl && held_q;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rbf_cpl_t'('0);
    assign rbf_o = rbf_q;
    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = wr_addr_q;
    assign wr_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign wr_data_o = pack_q;
    assign wr_rsp_ready_o = state_q == WaitWr;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rbf_q <= '0;
        kind_q <= APU_VGPU_RBF_OK;
        x_q <= '0;
        y_q <= '0;
        slot_q <= '0;
        pack_q <= '0;
        word0_q <= '0;
        got_q <= '0;
        wr_addr_q <= '0;
        st_q <= APU_VGPU_SMP_OK;
        held_q <= 1'b0;
        xy_ok_q <= 1'b0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rbf_q.valid) begin
            kind_q <= APU_VGPU_RBF_FAULT;
            state_q <= Commit;
          end else begin
            x_q <= '0;
            y_q <= '0;
            slot_q <= '0;
            pack_q <= '0;
            word0_q <= '0;
            held_q <= 1'b0;
            bad_q <= 1'b0;
            kind_q <= APU_VGPU_RBF_OK;
            state_q <= Samp;
          end
        end
        Samp: if (smp_rdy) state_q <= WaitCpl;
        WaitCpl: if (smp_cpl_v) begin
          if (!held_q) begin
            held_q <= 1'b1;
            got_q <= smp_s.word;
            st_q <= smp_cpl.status;
            xy_ok_q <= smp_s.x == x_q && smp_s.y == y_q;
          end else state_q <= Take;
        end
        Take: begin
          held_q <= 1'b0;
          if (st_q == APU_VGPU_SMP_EMPTY) begin
            kind_q <= APU_VGPU_RBF_EMPTY;
            state_q <= Commit;
          end else if (st_q != APU_VGPU_SMP_OK || !xy_ok_q) begin
            kind_q <= APU_VGPU_RBF_FAULT;
            state_q <= Commit;
          end else begin
            if (x_q == 6'd0 && y_q == 6'd0) word0_q <= got_q;
            case (slot_q)
              3'd0: pack_q[31:0] <= got_q;
              3'd1: pack_q[63:32] <= got_q;
              3'd2: pack_q[95:64] <= got_q;
              3'd3: pack_q[127:96] <= got_q;
              3'd4: pack_q[159:128] <= got_q;
              3'd5: pack_q[191:160] <= got_q;
              3'd6: pack_q[223:192] <= got_q;
              default: pack_q[255:224] <= got_q;
            endcase
            if (slot_q == 3'd7) begin
              wr_addr_q <= beat_addr({y_q, x_q[5:3]});
              state_q <= Issue;
            end else begin
              slot_q <= slot_q + 3'd1;
              x_q <= x_q + 6'd1;
              state_q <= Samp;
            end
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitWr;
        WaitWr: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != wr_addr_q) begin
            kind_q <= APU_VGPU_RBF_FAULT;
            state_q <= Commit;
          end else if (x_q == 6'd63 && y_q == 6'd63) begin
            if (word0_q != lnr_i.origin ||
                wr_addr_q != beat_addr(9'd511)) begin
              kind_q <= APU_VGPU_RBF_FAULT;
              state_q <= Commit;
            end else begin
              rbf_q.valid <= 1'b1;
              rbf_q.word0 <= word0_q;
              rbf_q.bytes <= APU_VGPU_CEIL_BYTES;
              rbf_q.beats <= APU_VGPU_CEIL_BEATS;
              rbf_q.last_addr <= wr_addr_q;
              kind_q <= APU_VGPU_RBF_OK;
              state_q <= Commit;
            end
          end else begin
            slot_q <= '0;
            if (x_q == 6'd63) begin
              x_q <= '0;
              y_q <= y_q + 6'd1;
            end else x_q <= x_q + 6'd1;
            state_q <= Samp;
          end
        end
        Commit: begin
          cpl_q.status <= kind_q;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_RBF_OK |->
        rbf_o.valid && rbf_o.beats == APU_VGPU_CEIL_BEATS);
    `endif
  end
endmodule

module g6lc_apu_vgpu_rbf_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_sbk_t sbk_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_ss_t ss_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  apu_vgpu_spx_t spx_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  apu_vgpu_vbr_t vbr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rbf_cpl_t cpl_o,
  output apu_vgpu_rbf_t rbf_o,
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
  g6lc_apu_vgpu_rbf #(.Enable(Enable)) i_dut (.*);
endmodule
