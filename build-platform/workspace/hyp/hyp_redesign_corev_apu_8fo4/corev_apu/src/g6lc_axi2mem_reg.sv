// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// hyp8 provenance: REWRITTEN (function of upstream axi2mem; new registered
// implementation for the 8-FO4 SoC ports — ROM and debug-module slaves)
//
// g6lc_axi2mem_reg: typed-AXI slave -> registered simple-memory master.
//
// Unlike the legacy axi2mem (single-cycle, combinational request/response),
// every access is serialized through registered boundary stages:
//   * AW/AR capture + wrap-boundary precompute in the capture cycle (the
//     legacy burst-address function is split out of the per-beat path)
//   * the memory request fields (req/we/addr/be/wdata) are register-driven
//   * the memory read data is captured into a register `RdLat` cycles after
//     the request (covers a registered/banked ROM or debug-module read)
//
// The memory-side contract is a 1-cycle request (req_o asserted for exactly
// one cycle per beat) with combinational read data presented RdLat cycles
// later (banked ROM: 2, registered debug path: 2). Writes complete when the
// request is taken; there is no memory-side ready — the attached memory must
// accept every requested beat (true for bootrom / dm slave window).
//
// AXI4 bursts: FIXED, INCR and WRAP supported on full-width (64-bit)
// aligned accesses, matching the legacy axi2mem contract.

module g6lc_axi2mem_reg #(
  parameter int unsigned AXI_ADDR_WIDTH = 64,
  parameter int unsigned AXI_DATA_WIDTH = 64,
  // cycles from req_o beat to rdata_i valid (combinational memory: 1)
  parameter int unsigned RD_LAT         = 2,
  parameter type         axi_req_t      = g6lc_axi_soc::req_slv_t,
  parameter type         axi_resp_t     = g6lc_axi_soc::resp_slv_t
) (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  axi_req_t   slv_req_i,
  output axi_resp_t  slv_resp_o,

  output logic                         req_o,
  output logic                         we_o,
  output logic [AXI_ADDR_WIDTH-1:0]    addr_o,
  output logic [AXI_DATA_WIDTH/8-1:0]  be_o,
  output logic [AXI_DATA_WIDTH-1:0]    wdata_o,
  input  logic [AXI_DATA_WIDTH-1:0]    rdata_i
);

  localparam int unsigned LOG_NR_BYTES = $clog2(AXI_DATA_WIDTH/8);

  typedef enum logic [2:0] {
    IDLE, READ_WAIT, READ_SEND, WRITE_BEAT, WRITE_WAIT, SEND_B
  } state_e;

  state_e                        state_q;
  // captured request record
  g6lc_axi_soc::id_slv_t           id_q;
  logic [AXI_ADDR_WIDTH-1:0]       ax_addr_q;
  logic [7:0]                      ax_len_q;
  axi_pkg::burst_t                 ax_burst_q;
  logic [7:0]                      cnt_q;
  logic [AXI_ADDR_WIDTH-1:0]       req_addr_q;
  // wrap bounds computed at capture (registered — off the beat path)
  logic [AXI_ADDR_WIDTH-1:0]       upper_wrap_q;
  // registered memory request fields
  logic                            req_q;
  logic                            we_q;
  // registered write-beat record
  logic [AXI_DATA_WIDTH-1:0]       w_data_q;
  logic [AXI_DATA_WIDTH/8-1:0]     w_strb_q;
  logic                            w_last_q;
  logic                            w_pending_q;
  // registered read data capture
  logic [AXI_DATA_WIDTH-1:0]       r_data_q;
  logic [3:0]                      rd_wait_q;

  // ---------------- captured-request / wrap-boundary ----------------

  function automatic logic [AXI_ADDR_WIDTH-1:0] get_wrap_boundary (
      input logic [AXI_ADDR_WIDTH-1:0] unaligned_address,
      input logic [7:0]                len);
    // upper address of the wrap window (legacy axi2mem algorithm)
    logic [AXI_ADDR_WIDTH-1:0] warp_address;
    warp_address                                = '0;
    warp_address[AXI_ADDR_WIDTH-1:LOG_NR_BYTES+1] =
        unaligned_address[AXI_ADDR_WIDTH-1:LOG_NR_BYTES+1] + len;
    return warp_address;
  endfunction

  function automatic logic [AXI_ADDR_WIDTH-1:0] next_addr (
      input logic [AXI_ADDR_WIDTH-1:0] aligned,
      input logic [7:0]                cnt);
    return aligned + (AXI_ADDR_WIDTH'(cnt) << LOG_NR_BYTES);
  endfunction

  logic [AXI_ADDR_WIDTH-1:0] aligned_q;
  assign aligned_q = {ax_addr_q[AXI_ADDR_WIDTH-1:LOG_NR_BYTES],
                      {LOG_NR_BYTES{1'b0}}};
  wire [AXI_ADDR_WIDTH-1:0] cons_addr = next_addr(aligned_q, cnt_q);

  // ---------------- main FSM (all datapath state is registered) ---------

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_axi2mem_reg
    if (!rst_ni) begin
      state_q     <= IDLE;
      id_q        <= '0;
      ax_addr_q   <= '0;
      ax_len_q    <= '0;
      ax_burst_q  <= axi_pkg::BURST_FIXED;
      cnt_q       <= '0;
      req_addr_q  <= '0;
      upper_wrap_q <= '0;
      req_q       <= 1'b0;
      we_q        <= 1'b0;
      w_data_q    <= '0;
      w_strb_q    <= '0;
      w_last_q    <= 1'b0;
      w_pending_q <= 1'b0;
      r_data_q    <= '0;
      rd_wait_q   <= '0;
    end else begin
      // defaults: single-cycle request pulse
      req_q <= 1'b0;
      we_q  <= 1'b0;

      case (state_q)
        IDLE: begin
          cnt_q <= '0;
          if (slv_req_i.ar_valid) begin
            id_q         <= slv_req_i.ar.id;
            ax_addr_q    <= slv_req_i.ar.addr;
            ax_len_q     <= slv_req_i.ar.len;
            ax_burst_q   <= slv_req_i.ar.burst;
            upper_wrap_q <= get_wrap_boundary(slv_req_i.ar.addr,
                                              slv_req_i.ar.len);
            req_addr_q   <= slv_req_i.ar.addr;
            // issue the first beat's request from the captured fields
            req_q    <= 1'b1;
            rd_wait_q <= 4'(RD_LAT);
            state_q  <= READ_WAIT;
          end else if (slv_req_i.aw_valid) begin
            id_q         <= slv_req_i.aw.id;
            ax_addr_q    <= slv_req_i.aw.addr;
            ax_len_q     <= slv_req_i.aw.len;
            ax_burst_q   <= slv_req_i.aw.burst;
            upper_wrap_q <= get_wrap_boundary(slv_req_i.aw.addr,
                                              slv_req_i.aw.len);
            req_addr_q   <= slv_req_i.aw.addr;
            cnt_q        <= '0;
            state_q      <= WRITE_WAIT;
          end
        end

        // ---- reads: one beat at a time; request then RdLat-cycle data ----
        READ_WAIT: begin
          if (rd_wait_q <= 1) begin
            r_data_q <= rdata_i;
            state_q  <= READ_SEND;
          end else begin
            rd_wait_q <= rd_wait_q - 1;
          end
        end

        READ_SEND: begin
          if (slv_req_i.r_ready) begin
            if (cnt_q == ax_len_q) begin
              state_q <= IDLE;
            end else begin
              // issue next beat
              cnt_q <= cnt_q + 1;
              unique case (ax_burst_q)
                axi_pkg::BURST_WRAP: begin
                  if (next_addr(aligned_q, cnt_q + 1) == upper_wrap_q) begin
                    req_addr_q <= {upper_wrap_q[AXI_ADDR_WIDTH-1:LOG_NR_BYTES],
                                   {LOG_NR_BYTES{1'b0}}}
                                  - (AXI_ADDR_WIDTH'(ax_len_q + 1)
                                     << LOG_NR_BYTES);
                  end else begin
                    req_addr_q <= next_addr(aligned_q, cnt_q + 1);
                  end
                end
                default: req_addr_q <= next_addr(aligned_q, cnt_q + 1);
              endcase
              req_q     <= 1'b1;
              rd_wait_q <= 4'(RD_LAT);
              state_q   <= READ_WAIT;
            end
          end
        end

        // ---- writes: capture a W beat, then issue one request pulse ------
        WRITE_WAIT: begin
          if (slv_req_i.w_valid) begin
            w_data_q    <= slv_req_i.w.data;
            w_strb_q    <= slv_req_i.w.strb;
            w_last_q    <= slv_req_i.w.last;
            w_pending_q <= 1'b1;
            req_q       <= 1'b1;
            we_q        <= 1'b1;
            state_q     <= WRITE_BEAT;
          end
        end

        WRITE_BEAT: begin
          // write lands on the cycle after the request pulse; next beat
          w_pending_q <= 1'b0;
          if (w_last_q || (cnt_q == ax_len_q)) begin
            state_q <= SEND_B;
          end else begin
            cnt_q <= cnt_q + 1;
            unique case (ax_burst_q)
              axi_pkg::BURST_WRAP: begin
                if (next_addr(aligned_q, cnt_q + 1) == upper_wrap_q) begin
                  req_addr_q <= {upper_wrap_q[AXI_ADDR_WIDTH-1:LOG_NR_BYTES],
                                 {LOG_NR_BYTES{1'b0}}}
                                - (AXI_ADDR_WIDTH'(ax_len_q + 1)
                                   << LOG_NR_BYTES);
                end else begin
                  req_addr_q <= next_addr(aligned_q, cnt_q + 1);
                end
              end
              default: req_addr_q <= next_addr(aligned_q, cnt_q + 1);
            endcase
            state_q <= WRITE_WAIT;
          end
        end

        SEND_B: begin
          if (slv_req_i.b_ready) begin
            state_q <= IDLE;
          end
        end

        default: state_q <= IDLE;
      endcase
    end
  end

  // ---------------- outputs -------------------------------------------

  // AXI slave side
  always_comb begin
    slv_resp_o = '0;
    slv_resp_o.ar_ready = (state_q == IDLE) && slv_req_i.ar_valid;
    slv_resp_o.aw_ready = (state_q == IDLE) && !slv_req_i.ar_valid
                          && slv_req_i.aw_valid;
    slv_resp_o.w_ready  = (state_q == WRITE_WAIT) && slv_req_i.w_valid;

    slv_resp_o.b.id     = id_q;
    slv_resp_o.b.resp   = axi_pkg::RESP_OKAY;
    slv_resp_o.b.user   = '0;
    slv_resp_o.b_valid  = (state_q == SEND_B);

    slv_resp_o.r.id     = id_q;
    slv_resp_o.r.data   = r_data_q;
    slv_resp_o.r.resp   = axi_pkg::RESP_OKAY;
    slv_resp_o.r.last   = (cnt_q == ax_len_q);
    slv_resp_o.r.user   = '0;
    slv_resp_o.r_valid  = (state_q == READ_SEND);
  end

  // memory side (registered request fields)
  assign req_o   = req_q;
  assign we_o    = we_q;
  assign addr_o  = req_addr_q;
  assign be_o    = w_strb_q;
  assign wdata_o = w_data_q;

  // pragma translate_off
  `ifndef VERILATOR
  initial begin
    assert (AXI_DATA_WIDTH == 64)
      else $fatal(1, "g6lc_axi2mem_reg: 64-bit data path only");
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q == IDLE && slv_req_i.ar_valid)
      assert (slv_req_i.ar.size == LOG_NR_BYTES[2:0])
        else $fatal(1, "g6lc_axi2mem_reg: read must be full data width");
    if (rst_ni && state_q == IDLE && slv_req_i.aw_valid)
      assert (slv_req_i.aw.size == LOG_NR_BYTES[2:0])
        else $fatal(1, "g6lc_axi2mem_reg: write must be full data width");
  end
  `endif
  // pragma translate_on

endmodule
