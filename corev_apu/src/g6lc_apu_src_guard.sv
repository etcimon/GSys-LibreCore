// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Per-core window guard in front of cluster aggregation. The hart is the
// port parameter, not AXI id, PROT, user, or lock. A firmware hart is a
// wire. Any other hart that addresses firmware RAM or the control window
// is completed here with SLVERR and is not presented downstream.

module g6lc_apu_src_guard #(
  parameter logic [31:0] Hart = 32'h0,
  parameter logic [31:0] FwHart = 32'hffff_ffff,
  parameter logic [63:0] RamBase = 64'h0,
  parameter logic [63:0] RamBytes = 64'h0,
  parameter logic [63:0] CtrlBase = 64'h0,
  parameter logic [63:0] CtrlBytes = 64'h0,
  parameter type axi_req_t = logic,
  parameter type axi_resp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  axi_req_t up_req_i,
  output axi_resp_t up_resp_o,
  output axi_req_t dn_req_o,
  input  axi_resp_t dn_resp_i
);
  localparam logic [31:0] UNASSIGNED = 32'hffff_ffff;
  localparam bit Pass = (FwHart != UNASSIGNED) && (Hart == FwHart);

  function automatic logic in_win(input logic [63:0] addr,
      input logic [63:0] base, input logic [63:0] bytes);
    if (bytes == 64'h0) return 1'b0;
    if (addr < base) return 1'b0;
    return (addr - base) < bytes;
  endfunction
  function automatic logic deny_addr(input logic [63:0] addr);
    return in_win(addr, RamBase, RamBytes) || in_win(addr, CtrlBase, CtrlBytes);
  endfunction

  if (Pass) begin : gen_pass
    assign dn_req_o = up_req_i;
    assign up_resp_o = dn_resp_i;
    logic unused;
    assign unused = clk_i | rst_ni;
  end else begin : gen_filt
    localparam int unsigned IdW = $bits(up_req_i.aw.id);
    localparam int unsigned LenW = $bits(up_req_i.aw.len);
    typedef enum logic [2:0] { WIdle, WFwd, WDrain, WErrB, WFault } wst_e;
    typedef enum logic [1:0] { RIdle, RFwd, RErr } rst_e;
    wst_e wstate_q;
    rst_e rstate_q;
    logic [IdW-1:0] wid_q, rid_q;
    logic [LenW-1:0] wbeats_q, rbeats_q;

    always_comb begin
      dn_req_o = up_req_i;
      dn_req_o.aw_valid = 1'b0;
      dn_req_o.w_valid  = 1'b0;
      dn_req_o.ar_valid = 1'b0;
      dn_req_o.b_ready  = 1'b0;
      dn_req_o.r_ready  = 1'b0;
      up_resp_o = '0;
      unique case (wstate_q)
        WIdle: begin
          if (up_req_i.aw_valid && !deny_addr(up_req_i.aw.addr)) begin
            dn_req_o.aw_valid = 1'b1;
            dn_req_o.w_valid  = up_req_i.w_valid;
            up_resp_o.aw_ready = dn_resp_i.aw_ready;
            up_resp_o.w_ready  = dn_resp_i.w_ready;
          end else if (up_req_i.aw_valid) begin
            up_resp_o.aw_ready = 1'b1;
            up_resp_o.w_ready  = 1'b1;
          end
        end
        WFwd: begin
          dn_req_o.w_valid = up_req_i.w_valid;
          up_resp_o.w_ready = dn_resp_i.w_ready;
          dn_req_o.b_ready = up_req_i.b_ready;
          up_resp_o.b = dn_resp_i.b;
          up_resp_o.b_valid = dn_resp_i.b_valid;
        end
        WDrain: up_resp_o.w_ready = 1'b1;
        WErrB: begin
          up_resp_o.b_valid = 1'b1;
          up_resp_o.b.id = wid_q;
          up_resp_o.b.resp = axi_pkg::RESP_SLVERR;
        end
        WFault: ;
      endcase
      unique case (rstate_q)
        RIdle: begin
          if (up_req_i.ar_valid && !deny_addr(up_req_i.ar.addr)) begin
            dn_req_o.ar_valid = 1'b1;
            up_resp_o.ar_ready = dn_resp_i.ar_ready;
          end else if (up_req_i.ar_valid) begin
            up_resp_o.ar_ready = 1'b1;
          end
        end
        RFwd: begin
          dn_req_o.r_ready = up_req_i.r_ready;
          up_resp_o.r = dn_resp_i.r;
          up_resp_o.r_valid = dn_resp_i.r_valid;
        end
        RErr: begin
          up_resp_o.r_valid = 1'b1;
          up_resp_o.r.id = rid_q;
          up_resp_o.r.resp = axi_pkg::RESP_SLVERR;
          up_resp_o.r.last = (rbeats_q == '0);
        end
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        wstate_q <= WIdle;
        wid_q <= '0;
        wbeats_q <= '0;
      end else unique case (wstate_q)
        WIdle: begin
          if (up_req_i.aw_valid && up_resp_o.aw_ready &&
              !deny_addr(up_req_i.aw.addr)) begin
            wstate_q <= WFwd;
          end else if (up_req_i.aw_valid && up_resp_o.aw_ready) begin
            wid_q <= up_req_i.aw.id;
            wbeats_q <= up_req_i.aw.len;
            wstate_q <= WDrain;
            if (up_req_i.w_valid && up_resp_o.w_ready) begin
              if (up_req_i.w.last != (up_req_i.aw.len == '0)) wstate_q <= WFault;
              else if (up_req_i.aw.len == '0) wstate_q <= WErrB;
              else wbeats_q <= up_req_i.aw.len - 1'b1;
            end
          end
        end
        WFwd: if (dn_resp_i.b_valid && up_req_i.b_ready) wstate_q <= WIdle;
        WDrain: if (up_req_i.w_valid && up_resp_o.w_ready) begin
          if (up_req_i.w.last != (wbeats_q == '0)) wstate_q <= WFault;
          else if (wbeats_q == '0) wstate_q <= WErrB;
          else wbeats_q <= wbeats_q - 1'b1;
        end
        WErrB: if (up_req_i.b_ready) wstate_q <= WIdle;
        WFault: ;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rstate_q <= RIdle;
        rid_q <= '0;
        rbeats_q <= '0;
      end else unique case (rstate_q)
        RIdle: begin
          if (up_req_i.ar_valid && up_resp_o.ar_ready &&
              !deny_addr(up_req_i.ar.addr)) begin
            rstate_q <= RFwd;
          end else if (up_req_i.ar_valid && up_resp_o.ar_ready) begin
            rid_q <= up_req_i.ar.id;
            rbeats_q <= up_req_i.ar.len;
            rstate_q <= RErr;
          end
        end
        RFwd: if (dn_resp_i.r_valid && up_req_i.r_ready && dn_resp_i.r.last)
          rstate_q <= RIdle;
        RErr: if (up_req_i.r_ready) begin
          if (rbeats_q == '0) rstate_q <= RIdle;
          else rbeats_q <= rbeats_q - 1'b1;
        end
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wstate_q inside {WDrain, WErrB, WFault} |->
      !dn_req_o.aw_valid && !dn_req_o.w_valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      rstate_q == RErr |-> !dn_req_o.ar_valid);
    `endif
  end
endmodule
