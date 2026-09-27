// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Second DRAM ingress for the AI island. Not on the live testharness path.
//
// The cluster port and the island port join above the channel stripe so both
// still see one address map and one set of per-channel occupancy counters.
// The cluster port wins a simultaneous address handshake. Island IDs are
// prefixed by axi_mux so they cannot alias cluster IDs. An island address
// outside [DramBase, DramBase+DramBytes) is SLVERR and does not enter the
// stripe. Island AxLOCK and ATOP are forced 0; the exclusive monitor stays
// on the cluster port only.
//
// IslandDataWidth may be wider than the channel. The extra beats are produced
// by axi_dw_converter before the join, so the PHYs and the class-0 SRAM stay
// at AXI_DATA_WIDTH. A burst whose byte length exceeds the stripe is still
// the backend's error, not this module's.
//
// Default SoC elaboration does not instantiate this module. See
// architecture/uncore/dram-channel-scaling.md §4.

`include "axi/assign.svh"
`include "axi/typedef.svh"

module g6lc_ai_dram_join #(
    parameter int unsigned AXI_ADDR_WIDTH    = 64,
    parameter int unsigned AXI_DATA_WIDTH    = 64,
    parameter int unsigned AXI_ID_WIDTH      = 4,
    parameter int unsigned AXI_USER_WIDTH    = 1,
    parameter int unsigned ISLAND_DATA_WIDTH = 64,
    parameter int unsigned MAX_AR_OUT        = 2,
    parameter logic [63:0] DRAM_BASE         = 64'h8000_0000,
    parameter logic [63:0] DRAM_BYTES        = 64'h4000_0000,
    parameter bit          FATAL_LOCK        = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic testmode_i,
    input  logic init_done_i,
    AXI_BUS.Slave  cluster,
    AXI_BUS.Slave  island,
    AXI_BUS.Master master
);

  localparam int unsigned MST_ID_WIDTH = AXI_ID_WIDTH + 1;
  localparam int unsigned AW_Q         = (MAX_AR_OUT < 1) ? 1 : MAX_AR_OUT;
  localparam int unsigned PTR_W        = (AW_Q <= 1) ? 1 : $clog2(AW_Q);

  // pragma translate_off
  initial begin
    assert (MAX_AR_OUT >= 1 && MAX_AR_OUT <= 16)
      else $error("g6lc_ai_dram_join: MAX_AR_OUT=%0d not in [1,16]", MAX_AR_OUT);
    assert (ISLAND_DATA_WIDTH >= AXI_DATA_WIDTH)
      else $error("g6lc_ai_dram_join: island width %0d narrower than channel %0d",
                  ISLAND_DATA_WIDTH, AXI_DATA_WIDTH);
    assert ((ISLAND_DATA_WIDTH % AXI_DATA_WIDTH) == 0)
      else $error("g6lc_ai_dram_join: island width must be a multiple of the channel");
  end
  // pragma translate_on

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) island_n ();

  if (ISLAND_DATA_WIDTH == AXI_DATA_WIDTH) begin : gen_island_same
    `AXI_ASSIGN(island_n, island)
  end else begin : gen_island_down
    axi_dw_converter_intf #(
        .AXI_ID_WIDTH            ( AXI_ID_WIDTH      ),
        .AXI_ADDR_WIDTH          ( AXI_ADDR_WIDTH    ),
        .AXI_SLV_PORT_DATA_WIDTH ( ISLAND_DATA_WIDTH ),
        .AXI_MST_PORT_DATA_WIDTH ( AXI_DATA_WIDTH    ),
        .AXI_USER_WIDTH          ( AXI_USER_WIDTH    ),
        .AXI_MAX_READS           ( AW_Q              )
    ) i_down (
        .clk_i,
        .rst_ni,
        .slv ( island   ),
        .mst ( island_n )
    );
  end

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) mux_cl (), mux_is (), mux_slv[1:0] ();

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( MST_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) mux_mst ();

  // Cluster request, held until init_done. Payload is not rewritten.
  assign mux_cl.aw_id     = cluster.aw_id;
  assign mux_cl.aw_addr   = cluster.aw_addr;
  assign mux_cl.aw_len    = cluster.aw_len;
  assign mux_cl.aw_size   = cluster.aw_size;
  assign mux_cl.aw_burst  = cluster.aw_burst;
  assign mux_cl.aw_lock   = cluster.aw_lock;
  assign mux_cl.aw_cache  = cluster.aw_cache;
  assign mux_cl.aw_prot   = cluster.aw_prot;
  assign mux_cl.aw_qos    = cluster.aw_qos;
  assign mux_cl.aw_region = cluster.aw_region;
  assign mux_cl.aw_atop   = cluster.aw_atop;
  assign mux_cl.aw_user   = cluster.aw_user;
  assign mux_cl.aw_valid  = init_done_i && cluster.aw_valid;
  assign cluster.aw_ready = init_done_i && mux_cl.aw_ready;

  assign mux_cl.w_data  = cluster.w_data;
  assign mux_cl.w_strb  = cluster.w_strb;
  assign mux_cl.w_last  = cluster.w_last;
  assign mux_cl.w_user  = cluster.w_user;
  assign mux_cl.w_valid = init_done_i && cluster.w_valid;
  assign cluster.w_ready = init_done_i && mux_cl.w_ready;

  assign cluster.b_id    = mux_cl.b_id;
  assign cluster.b_resp  = mux_cl.b_resp;
  assign cluster.b_user  = mux_cl.b_user;
  assign cluster.b_valid = mux_cl.b_valid;
  assign mux_cl.b_ready  = cluster.b_ready;

  assign mux_cl.ar_id     = cluster.ar_id;
  assign mux_cl.ar_addr   = cluster.ar_addr;
  assign mux_cl.ar_len    = cluster.ar_len;
  assign mux_cl.ar_size   = cluster.ar_size;
  assign mux_cl.ar_burst  = cluster.ar_burst;
  assign mux_cl.ar_lock   = cluster.ar_lock;
  assign mux_cl.ar_cache  = cluster.ar_cache;
  assign mux_cl.ar_prot   = cluster.ar_prot;
  assign mux_cl.ar_qos    = cluster.ar_qos;
  assign mux_cl.ar_region = cluster.ar_region;
  assign mux_cl.ar_user   = cluster.ar_user;
  assign mux_cl.ar_valid  = init_done_i && cluster.ar_valid;
  assign cluster.ar_ready = init_done_i && mux_cl.ar_ready;

  assign cluster.r_id    = mux_cl.r_id;
  assign cluster.r_data  = mux_cl.r_data;
  assign cluster.r_resp  = mux_cl.r_resp;
  assign cluster.r_last  = mux_cl.r_last;
  assign cluster.r_user  = mux_cl.r_user;
  assign cluster.r_valid = mux_cl.r_valid;
  assign mux_cl.r_ready  = cluster.r_ready;

  // ---- island filter: window, lock strip, outstanding cap, cluster priority ----
  logic [4:0] ar_out_q, aw_out_q;
  logic       local_ar_busy, local_r_valid;
  logic [AXI_ID_WIDTH-1:0] local_ar_id;
  logic [7:0] local_ar_left;
  logic       local_aw_busy, local_w_busy, local_b_valid;
  logic [AXI_ID_WIDTH-1:0] local_aw_id;
  logic [AW_Q-1:0] aw_kind_q; // 1 = local SLVERR, 0 = forwarded
  logic [PTR_W-1:0] aw_wr_q, aw_rd_q;
  logic [4:0] aw_n_q;

  function automatic logic addr_in_dram(input logic [AXI_ADDR_WIDTH-1:0] addr,
                                        input logic [7:0] len,
                                        input logic [2:0] size);
    logic [63:0] nbytes;
    logic [63:0] last_b;
    nbytes = (64'(len) + 64'd1) << size;
    last_b = 64'(addr) + nbytes - 64'd1;
    return (64'(addr) >= DRAM_BASE) && (last_b >= 64'(addr)) &&
           (last_b < (DRAM_BASE + DRAM_BYTES));
  endfunction

  wire ar_room = (ar_out_q < 5'(AW_Q));
  wire aw_room = (aw_out_q < 5'(AW_Q)) && (aw_n_q < 5'(AW_Q));
  wire cl_ar   = cluster.ar_valid;
  wire cl_aw   = cluster.aw_valid;
  wire ar_in   = addr_in_dram(island_n.ar_addr, island_n.ar_len, island_n.ar_size);
  wire aw_in   = addr_in_dram(island_n.aw_addr, island_n.aw_len, island_n.aw_size);
  wire aw_head_local = aw_kind_q[aw_rd_q];

  wire take_ar_fwd = init_done_i && ar_room && !cl_ar && island_n.ar_valid && ar_in;
  wire take_ar_loc = init_done_i && ar_room && !cl_ar && island_n.ar_valid && !ar_in &&
                     !local_ar_busy;
  wire take_aw_fwd = init_done_i && aw_room && !cl_aw && island_n.aw_valid && aw_in;
  wire take_aw_loc = init_done_i && aw_room && !cl_aw && island_n.aw_valid && !aw_in &&
                     !local_aw_busy && !local_w_busy && !local_b_valid;

  assign mux_is.ar_id     = island_n.ar_id;
  assign mux_is.ar_addr   = island_n.ar_addr;
  assign mux_is.ar_len    = island_n.ar_len;
  assign mux_is.ar_size   = island_n.ar_size;
  assign mux_is.ar_burst  = island_n.ar_burst;
  assign mux_is.ar_lock   = 1'b0;
  assign mux_is.ar_cache  = island_n.ar_cache;
  assign mux_is.ar_prot   = island_n.ar_prot;
  assign mux_is.ar_qos    = island_n.ar_qos;
  assign mux_is.ar_region = island_n.ar_region;
  assign mux_is.ar_user   = island_n.ar_user;
  assign mux_is.ar_valid  = take_ar_fwd;

  assign mux_is.aw_id     = island_n.aw_id;
  assign mux_is.aw_addr   = island_n.aw_addr;
  assign mux_is.aw_len    = island_n.aw_len;
  assign mux_is.aw_size   = island_n.aw_size;
  assign mux_is.aw_burst  = island_n.aw_burst;
  assign mux_is.aw_lock   = 1'b0;
  assign mux_is.aw_cache  = island_n.aw_cache;
  assign mux_is.aw_prot   = island_n.aw_prot;
  assign mux_is.aw_qos    = island_n.aw_qos;
  assign mux_is.aw_region = island_n.aw_region;
  assign mux_is.aw_atop   = '0;
  assign mux_is.aw_user   = island_n.aw_user;
  assign mux_is.aw_valid  = take_aw_fwd;

  wire fwd_w = (aw_n_q != 5'd0) && !aw_head_local;
  assign mux_is.w_data  = island_n.w_data;
  assign mux_is.w_strb  = island_n.w_strb;
  assign mux_is.w_last  = island_n.w_last;
  assign mux_is.w_user  = island_n.w_user;
  assign mux_is.w_valid = fwd_w && island_n.w_valid;

  // Responses toward the island: a local SLVERR beats a mux response so the
  // two valids are never both presented.
  wire use_local_r = local_r_valid;
  wire use_local_b = local_b_valid;
  assign island_n.r_id    = use_local_r ? local_ar_id : mux_is.r_id;
  assign island_n.r_data  = use_local_r ? '0 : mux_is.r_data;
  assign island_n.r_resp  = use_local_r ? axi_pkg::RESP_SLVERR : mux_is.r_resp;
  assign island_n.r_last  = use_local_r ? (local_ar_left == 8'd0) : mux_is.r_last;
  assign island_n.r_user  = '0;
  assign island_n.r_valid = use_local_r || mux_is.r_valid;
  assign mux_is.r_ready   = island_n.r_ready && !use_local_r;

  assign island_n.b_id    = use_local_b ? local_aw_id : mux_is.b_id;
  assign island_n.b_resp  = use_local_b ? axi_pkg::RESP_SLVERR : mux_is.b_resp;
  assign island_n.b_user  = '0;
  assign island_n.b_valid = use_local_b || mux_is.b_valid;
  assign mux_is.b_ready   = island_n.b_ready && !use_local_b;

  assign island_n.ar_ready = take_ar_loc || (take_ar_fwd && mux_is.ar_ready);
  assign island_n.aw_ready = take_aw_loc || (take_aw_fwd && mux_is.aw_ready);
  assign island_n.w_ready  = (fwd_w && mux_is.w_ready) ||
                             ((aw_n_q != 5'd0) && aw_head_local && local_w_busy);

  wire ar_hs = island_n.ar_valid && island_n.ar_ready;
  wire aw_hs = island_n.aw_valid && island_n.aw_ready;
  wire w_hs  = island_n.w_valid && island_n.w_ready;
  wire r_hs  = island_n.r_valid && island_n.r_ready;
  wire b_hs  = island_n.b_valid && island_n.b_ready;
  wire r_done = r_hs && island_n.r_last;
  wire w_done = w_hs && island_n.w_last;

  logic [4:0] ar_out_d, aw_out_d, aw_n_d;
  always_comb begin
    ar_out_d = ar_out_q;
    if (ar_hs && !r_done)
      ar_out_d = ar_out_q + 5'd1;
    else if (!ar_hs && r_done && (ar_out_q != 5'd0))
      ar_out_d = ar_out_q - 5'd1;
    aw_out_d = aw_out_q;
    if (aw_hs && !b_hs)
      aw_out_d = aw_out_q + 5'd1;
    else if (!aw_hs && b_hs && (aw_out_q != 5'd0))
      aw_out_d = aw_out_q - 5'd1;
    aw_n_d = aw_n_q;
    if (aw_hs && !w_done)
      aw_n_d = aw_n_q + 5'd1;
    else if (!aw_hs && w_done && (aw_n_q != 5'd0))
      aw_n_d = aw_n_q - 5'd1;
  end

  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni && FATAL_LOCK && ar_hs && island_n.ar_lock)
      $error("g6lc_ai_dram_join: island AR.lock is not a DRAM exclusive");
    if (rst_ni && FATAL_LOCK && aw_hs && (island_n.aw_lock || (|island_n.aw_atop)))
      $error("g6lc_ai_dram_join: island AW.lock/ATOP is not a DRAM exclusive");
  end
  // pragma translate_on

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_out_q      <= '0;
      aw_out_q      <= '0;
      local_ar_busy <= 1'b0;
      local_r_valid <= 1'b0;
      local_ar_id   <= '0;
      local_ar_left <= '0;
      local_aw_busy <= 1'b0;
      local_w_busy  <= 1'b0;
      local_b_valid <= 1'b0;
      local_aw_id   <= '0;
      aw_kind_q     <= '0;
      aw_wr_q       <= '0;
      aw_rd_q       <= '0;
      aw_n_q        <= '0;
    end else begin
      ar_out_q <= ar_out_d;
      aw_out_q <= aw_out_d;
      aw_n_q   <= aw_n_d;

      if (take_ar_loc && island_n.ar_valid) begin
        local_ar_busy <= 1'b1;
        local_r_valid <= 1'b1;
        local_ar_id   <= island_n.ar_id;
        local_ar_left <= island_n.ar_len;
      end else if (local_r_valid && island_n.r_ready && use_local_r) begin
        if (local_ar_left == 8'd0) begin
          local_r_valid <= 1'b0;
          local_ar_busy <= 1'b0;
        end else begin
          local_ar_left <= local_ar_left - 8'd1;
        end
      end

      if (aw_hs) begin
        aw_kind_q[aw_wr_q] <= !aw_in;
        aw_wr_q <= (AW_Q <= 1 || aw_wr_q == PTR_W'(AW_Q - 1)) ? '0 : aw_wr_q + 1'b1;
        if (!aw_in) begin
          local_aw_busy <= 1'b1;
          local_w_busy  <= 1'b1;
          local_aw_id   <= island_n.aw_id;
        end
      end
      if (w_done && aw_head_local) begin
        local_w_busy  <= 1'b0;
        local_aw_busy <= 1'b0;
        local_b_valid <= 1'b1;
      end
      if (local_b_valid && b_hs && use_local_b)
        local_b_valid <= 1'b0;
      if (w_done)
        aw_rd_q <= (AW_Q <= 1 || aw_rd_q == PTR_W'(AW_Q - 1)) ? '0 : aw_rd_q + 1'b1;
    end
  end

  `AXI_ASSIGN(mux_slv[0], mux_cl)
  `AXI_ASSIGN(mux_slv[1], mux_is)

  axi_mux_intf #(
      .SLV_AXI_ID_WIDTH ( AXI_ID_WIDTH   ),
      .MST_AXI_ID_WIDTH ( MST_ID_WIDTH   ),
      .AXI_ADDR_WIDTH   ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH   ( AXI_DATA_WIDTH ),
      .AXI_USER_WIDTH   ( AXI_USER_WIDTH ),
      .NO_SLV_PORTS     ( 32'd2          ),
      .MAX_W_TRANS      ( AW_Q           ),
      .FALL_THROUGH     ( 1'b1           ),
      .SPILL_AW         ( 1'b0           ),
      .SPILL_W          ( 1'b0           ),
      .SPILL_B          ( 1'b0           ),
      .SPILL_AR         ( 1'b0           ),
      .SPILL_R          ( 1'b0           )
  ) i_join_mux (
      .clk_i  ( clk_i      ),
      .rst_ni ( rst_ni     ),
      .test_i ( testmode_i ),
      .slv    ( mux_slv ),
      .mst    ( mux_mst    )
  );

  `AXI_ASSIGN(master, mux_mst)

endmodule
