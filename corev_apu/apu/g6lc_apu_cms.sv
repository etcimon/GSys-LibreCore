// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// AvailNext then a 32-byte immutable snapshot of the first payload
// window. A later guest store at that address does not change the
// snapshot. A second snapshot faults until reset. Enable=0 elaborates
// no datapath. Does not edit g6lc_apu_vgpu_avail. Not wired into
// g6lc_apu_sys. FeatureVirgl stays illegal.

// CmdSnap (cms): AvailNext first-payload snapshot that survives guest mutation. Default-off. FeatureVirgl stays illegal.
// Interplay: CmdSnap (cms) --> AvailNext (avn) ==> first payload SRAM. --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_cms
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_cms_cpl_t cpl_o,
  output apu_cms_t cms_o,
  input  logic [2:0] snap_idx_i,
  output logic [31:0] snap_word_o,
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
    assign cms_o = '0;
    assign snap_word_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                    rd_rsp_valid_i | rd_rsp_ok_i | (|req_i) | (|snap_idx_i) |
                    (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireAvn, WaitAvn, RdPay, WaitPay, Done
    } state_e;
    state_e state_q;
    apu_cms_cpl_t cpl_q;
    apu_cms_t rec_q;
    logic locked_q;
    logic [31:0] snap_q [APU_CMS_WORDS];
    logic [63:0] pay_addr_q;
    logic [31:0] pay_len_q;
    logic pay_rd, avn_rd_v, avn_rd_r, avn_rsp_v, avn_rsp_r;
    logic [63:0] avn_rd_addr;
    logic [31:0] avn_rd_len;
    logic avn_req_v, avn_rdy, avn_cpl, avn_ack;
    apu_avn_req_t req_q;
    apu_avn_cpl_t avn_c;
    apu_avn_t avn_rec;
    logic pay_ok;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_cms_cpl_t'('0);
    assign cms_o = rec_q;
    assign snap_word_o = rec_q.valid ? snap_q[snap_idx_i] : 32'h0;
    assign pay_rd = state_q == RdPay;
    assign rd_valid_o = pay_rd || avn_rd_v;
    assign rd_addr_o = pay_rd ? pay_addr_q : avn_rd_addr;
    assign rd_len_o = pay_rd ? pay_len_q : avn_rd_len;
    assign rd_rsp_ready_o = (state_q == WaitPay) || avn_rsp_r;
    assign avn_rd_r = rd_ready_i && !pay_rd;
    assign avn_rsp_v = rd_rsp_valid_i && (state_q == WaitAvn);
    assign avn_req_v = state_q == FireAvn;
    assign avn_ack = state_q == WaitAvn;
    assign pay_ok = (avn_rec.first_len != 32'd0) &&
                    (avn_rec.first_len <= 32'(APU_CMS_BYTES)) &&
                    (avn_rec.first_len[1:0] == 2'd0) &&
                    (avn_rec.first_addr[1:0] == 2'd0);

    g6lc_apu_avn #(.Enable(1'b1)) i_avn (
      .clk_i, .rst_ni,
      .req_valid_i(avn_req_v), .req_ready_o(avn_rdy), .req_i(req_q),
      .cpl_valid_o(avn_cpl), .cpl_ready_i(avn_ack), .cpl_o(avn_c), .avn_o(avn_rec),
      .rd_valid_o(avn_rd_v), .rd_ready_i(avn_rd_r),
      .rd_addr_o(avn_rd_addr), .rd_len_o(avn_rd_len),
      .rd_rsp_valid_i(avn_rsp_v), .rd_rsp_ready_o(avn_rsp_r),
      .rd_rsp_ok_i(rd_rsp_ok_i), .rd_rsp_addr_i(rd_rsp_addr_i),
      .rd_rsp_len_i(rd_rsp_len_i), .rd_rsp_data_i(rd_rsp_data_i)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        locked_q <= 1'b0;
        snap_q <= '{default: '0};
        pay_addr_q <= '0;
        pay_len_q <= '0;
        req_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          req_q <= req_i;
          if (locked_q) begin
            cpl_q.status <= APU_CMS_FAULT;
            state_q <= Done;
          end else state_q <= FireAvn;
        end
        FireAvn: if (avn_rdy) state_q <= WaitAvn;
        WaitAvn: if (avn_cpl) begin
          if (avn_c.status == APU_AVN_EMPTY) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_CMS_EMPTY;
            state_q <= Done;
          end else if (avn_c.status != APU_AVN_OK || !avn_rec.valid || !pay_ok) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_CMS_FAULT;
            state_q <= Done;
          end else begin
            pay_addr_q <= avn_rec.first_addr;
            pay_len_q <= avn_rec.first_len;
            rec_q.addr <= avn_rec.first_addr;
            rec_q.bytes <= avn_rec.first_len;
            state_q <= RdPay;
          end
        end
        RdPay: if (rd_ready_i) state_q <= WaitPay;
        WaitPay: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != pay_addr_q ||
              rd_rsp_len_i != pay_len_q) begin
            rec_q.valid <= 1'b0;
            cpl_q.status <= APU_CMS_FAULT;
            state_q <= Done;
          end else begin
            snap_q[0] <= rd_rsp_data_i[31:0];
            snap_q[1] <= rd_rsp_data_i[63:32];
            snap_q[2] <= rd_rsp_data_i[95:64];
            snap_q[3] <= rd_rsp_data_i[127:96];
            snap_q[4] <= rd_rsp_data_i[159:128];
            snap_q[5] <= rd_rsp_data_i[191:160];
            snap_q[6] <= rd_rsp_data_i[223:192];
            snap_q[7] <= rd_rsp_data_i[255:224];
            rec_q.valid <= 1'b1;
            rec_q.locked <= 1'b1;
            rec_q.word0 <= rd_rsp_data_i[31:0];
            locked_q <= 1'b1;
            cpl_q.status <= APU_CMS_OK;
            state_q <= Done;
          end
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// CmdSnap (cms) enable-0 fixture: AvailNext first-payload snapshot.
module g6lc_apu_cms_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_avn_req_t req_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_cms_cpl_t cpl_o,
  output apu_cms_t cms_o,
  input  logic [2:0] snap_idx_i,
  output logic [31:0] snap_word_o,
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
  g6lc_apu_cms #(.Enable(Enable)) i_dut (.*);
endmodule
