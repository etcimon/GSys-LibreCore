// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// hyp8 provenance: REWRITTEN (function of upstream axi2apb_64_32; new
// registered implementation for the 8-FO4 SoC ports — PLIC/UART/timer APB)
//
// g6lc_axi2apb_reg: typed-AXI slave -> APB4 master with a fully registered
// boundary:
//   * request record (AW/AR fields + wrap bounds) captured at accept
//   * APB bus (psel/penable/paddr/pwrite/pwdata) driven from registers
//   * APB response (prdata/pready/pslverr) captured into registers
//
// One transaction at a time; each AXI beat maps to one 32-bit APB access at
// the beat's address (the peripheral windows are 32-bit register files; the
// low address bits select the register — matches the legacy axi2apb usage).
//
// APB waits states are honored: the access phase holds until a captured
// pready — an extra wait state inserted by an adapted peripheral is legal.

module g6lc_axi2apb_reg #(
  parameter int unsigned AXI_ADDR_WIDTH = 64,
  parameter int unsigned AXI_DATA_WIDTH = 64,
  parameter int unsigned APB_ADDR_WIDTH = 32,
  parameter type         axi_req_t      = g6lc_axi_soc::req_slv_t,
  parameter type         axi_resp_t     = g6lc_axi_soc::resp_slv_t
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  input  axi_req_t                    slv_req_i,
  output axi_resp_t                   slv_resp_o,

  output logic                        psel_o,
  output logic                        penable_o,
  output logic                        pwrite_o,
  output logic [APB_ADDR_WIDTH-1:0]   paddr_o,
  output logic [31:0]                 pwdata_o,
  input  logic [31:0]                 prdata_i,
  input  logic                        pready_i,
  input  logic                        pslverr_i
);

  localparam int unsigned LOG_NR_BYTES = $clog2(AXI_DATA_WIDTH/8);

  typedef enum logic [3:0] {
    IDLE, APB_SETUP, APB_ACCESS, RD_SEND, WR_WCAP, SEND_B
  } state_e;

  state_e                      state_q;
  g6lc_axi_soc::id_slv_t       id_q;
  logic [AXI_ADDR_WIDTH-1:0]   ax_addr_q;
  logic [7:0]                  ax_len_q;
  axi_pkg::burst_t             ax_burst_q;
  logic [7:0]                  cnt_q;
  logic [AXI_ADDR_WIDTH-1:0]   req_addr_q;
  logic [AXI_ADDR_WIDTH-1:0]   upper_wrap_q;
  logic                        wr_q;      // transaction is a write
  // captured write beat
  logic [AXI_DATA_WIDTH-1:0]   w_data_q;
  logic [AXI_DATA_WIDTH/8-1:0] w_strb_q;
  logic                        w_last_q;
  // captured APB response
  logic [31:0]                 prdata_q;
  logic                        pslverr_q;
  // registered APB drive
  logic                        psel_q;
  logic                        penable_q;
  logic                        pwrite_q;
  logic [APB_ADDR_WIDTH-1:0]   paddr_q;
  logic [31:0]                 pwdata_q;

  function automatic logic [AXI_ADDR_WIDTH-1:0] get_wrap_boundary (
      input logic [AXI_ADDR_WIDTH-1:0] unaligned_address,
      input logic [7:0]                len);
    logic [AXI_ADDR_WIDTH-1:0] warp_address;
    warp_address                                = '0;
    warp_address[AXI_ADDR_WIDTH-1:LOG_NR_BYTES+1] =
        unaligned_address[AXI_ADDR_WIDTH-1:LOG_NR_BYTES+1] + len;
    return warp_address;
  endfunction

  wire [AXI_ADDR_WIDTH-1:0] aligned_q =
      {ax_addr_q[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {LOG_NR_BYTES{1'b0}}};

  function automatic logic [AXI_ADDR_WIDTH-1:0] next_addr (
      input logic [7:0] cnt);
    return aligned_q + (AXI_ADDR_WIDTH'(cnt) << LOG_NR_BYTES);
  endfunction

  // next beat's address step (combinational off registered fields only)
  function automatic logic [AXI_ADDR_WIDTH-1:0] step_addr ();
    if (ax_burst_q == axi_pkg::BURST_WRAP
        && next_addr(cnt_q + 1) == upper_wrap_q) begin
      return {upper_wrap_q[AXI_ADDR_WIDTH-1:LOG_NR_BYTES],
              {LOG_NR_BYTES{1'b0}}}
             - (AXI_ADDR_WIDTH'(ax_len_q + 1) << LOG_NR_BYTES);
    end
    return next_addr(cnt_q + 1);
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_axi2apb_reg
    if (!rst_ni) begin
      state_q      <= IDLE;
      id_q         <= '0;
      ax_addr_q    <= '0;
      ax_len_q     <= '0;
      ax_burst_q   <= axi_pkg::BURST_FIXED;
      cnt_q        <= '0;
      req_addr_q   <= '0;
      upper_wrap_q <= '0;
      wr_q         <= 1'b0;
      w_data_q     <= '0;
      w_strb_q     <= '0;
      w_last_q     <= 1'b0;
      prdata_q     <= '0;
      pslverr_q    <= 1'b0;
      psel_q       <= 1'b0;
      penable_q    <= 1'b0;
      pwrite_q     <= 1'b0;
      paddr_q      <= '0;
      pwdata_q     <= '0;
    end else begin
      // APB bus defaults: penable follows psel by one cycle (protocol shape);
      // cleared in the cycle after an access completes.
      psel_q    <= 1'b0;
      penable_q <= 1'b0;

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
            wr_q         <= 1'b0;
            // APB setup cycle (registered drive)
            psel_q   <= 1'b1;
            penable_q <= 1'b0;
            pwrite_q <= 1'b0;
            paddr_q  <= APB_ADDR_WIDTH'(slv_req_i.ar.addr);
            state_q  <= APB_SETUP;
          end else if (slv_req_i.aw_valid) begin
            id_q         <= slv_req_i.aw.id;
            ax_addr_q    <= slv_req_i.aw.addr;
            ax_len_q     <= slv_req_i.aw.len;
            ax_burst_q   <= slv_req_i.aw.burst;
            upper_wrap_q <= get_wrap_boundary(slv_req_i.aw.addr,
                                              slv_req_i.aw.len);
            req_addr_q   <= slv_req_i.aw.addr;
            wr_q         <= 1'b1;
            cnt_q        <= '0;
            state_q      <= WR_WCAP;
          end
        end

        // wait for a W beat before driving the write access
        WR_WCAP: begin
          if (slv_req_i.w_valid) begin
            w_data_q <= slv_req_i.w.data;
            w_strb_q <= slv_req_i.w.strb;
            w_last_q <= slv_req_i.w.last;
            psel_q   <= 1'b1;
            pwrite_q <= 1'b1;
            paddr_q  <= APB_ADDR_WIDTH'(req_addr_q);
            pwdata_q <= slv_req_i.w.data[31:0];
            state_q  <= APB_SETUP;
          end
        end

        APB_SETUP: begin
          psel_q    <= 1'b1;
          penable_q <= 1'b1;
          pwrite_q  <= pwrite_q;
          paddr_q   <= paddr_q;
          pwdata_q  <= pwdata_q;
          state_q   <= APB_ACCESS;
        end

        APB_ACCESS: begin
          // hold the access phase until a captured pready
          psel_q    <= 1'b1;
          penable_q <= 1'b1;
          if (pready_i) begin
            prdata_q  <= prdata_i;
            pslverr_q <= pslverr_i;
            psel_q    <= 1'b0;
            penable_q <= 1'b0;
            if (wr_q) begin
              if (w_last_q || (cnt_q == ax_len_q)) begin
                state_q <= SEND_B;
              end else begin
                cnt_q      <= cnt_q + 1;
                req_addr_q <= step_addr();
                state_q    <= WR_WCAP;
              end
            end else begin
              // every read beat is sent before the next APB access starts
              state_q <= RD_SEND;
            end
          end
        end

        RD_SEND: begin
          if (slv_req_i.r_ready) begin
            if (cnt_q == ax_len_q) begin
              state_q <= IDLE;
            end else begin
              cnt_q      <= cnt_q + 1;
              req_addr_q <= step_addr();
              psel_q     <= 1'b1;
              penable_q  <= 1'b0;
              pwrite_q   <= 1'b0;
              paddr_q    <= APB_ADDR_WIDTH'(step_addr());
              state_q    <= APB_SETUP;
            end
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

  always_comb begin
    slv_resp_o = '0;
    slv_resp_o.ar_ready = (state_q == IDLE) && slv_req_i.ar_valid;
    slv_resp_o.aw_ready = (state_q == IDLE) && !slv_req_i.ar_valid
                          && slv_req_i.aw_valid;
    slv_resp_o.w_ready  = (state_q == WR_WCAP) && slv_req_i.w_valid;
    slv_resp_o.b.id     = id_q;
    slv_resp_o.b.resp   = pslverr_q ? axi_pkg::RESP_SLVERR
                                  : axi_pkg::RESP_OKAY;
    slv_resp_o.b_valid  = (state_q == SEND_B);
    slv_resp_o.r.id     = id_q;
    slv_resp_o.r.data   = {{AXI_DATA_WIDTH-32{1'b0}}, prdata_q};
    slv_resp_o.r.resp   = pslverr_q ? axi_pkg::RESP_SLVERR
                                  : axi_pkg::RESP_OKAY;
    slv_resp_o.r.last   = (cnt_q == ax_len_q);
    slv_resp_o.r_valid  = (state_q == RD_SEND);
  end

  assign psel_o    = psel_q;
  assign penable_o = penable_q;
  assign pwrite_o  = pwrite_q;
  assign paddr_o   = paddr_q;
  assign pwdata_o  = pwdata_q;

  // pragma translate_off
  `ifndef VERILATOR
  always_ff @(posedge clk_i) begin
    if (rst_ni && state_q == IDLE && slv_req_i.ar_valid)
      assert (slv_req_i.ar.size <= 3'd3)
        else $fatal(1, "g6lc_axi2apb_reg: read beats > 32-bit unsupported");
    if (rst_ni && state_q == IDLE && slv_req_i.aw_valid)
      assert (slv_req_i.aw.size <= 3'd3)
        else $fatal(1, "g6lc_axi2apb_reg: write beats > 32-bit unsupported");
  end
  `endif
  // pragma translate_on

endmodule
