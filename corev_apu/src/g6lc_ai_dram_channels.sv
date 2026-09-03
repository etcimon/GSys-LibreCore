// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// I3 class-1 multi-channel LiteDRAM. Each channel is one gen.py --sim
// litedram_core (64-bit DDR4-2400 nameplate 19 GB/s). NrChannels is a
// power of two in [1, AI_DRAM_MAX_CHANNELS]. Stripe select is
// addr[ChanShift +: $clog2(NrChannels)] (default 64-byte).
//
// Not elaborated on the live DramClass=0 fixture. One generated core is
// one channel; N channels = N wrap instances, not a wider PHY.

`include "axi/assign.svh"

module g6lc_ai_dram_channels
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned NrChannels     = 1,
    parameter int unsigned ChanShift      = AI_DRAM_CHAN_SHIFT_DEFAULT,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter int unsigned MaxAROut       = AI_MAX_AR_OUT_DRAM
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic testmode_i,
    AXI_BUS.Slave slave,
    output logic init_done_o,
    // SoC-side occupancy (S5). Not island CAP; testharness may leave open.
    output logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats_o,
    output logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_w_beats_o
);

  localparam int unsigned SelW = (NrChannels > 1) ? $clog2(NrChannels) : 1;
  typedef logic [SelW-1:0] sel_t;

  // pragma translate_off
  initial begin
    assert (dram_channels_ok(NrChannels))
      else $error("g6lc_ai_dram_channels: NrChannels=%0d not in {1,2,4,8}", NrChannels);
    assert (MaxAROut >= 1 && MaxAROut <= 16)
      else $error("g6lc_ai_dram_channels: MaxAROut=%0d not in [1,16]", MaxAROut);
    assert (ChanShift >= 3 && ChanShift <= 16)
      else $error("g6lc_ai_dram_channels: ChanShift=%0d out of range", ChanShift);
  end
  // pragma translate_on

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) ch[NrChannels-1:0]();

  logic [NrChannels-1:0] ch_init_done;
  assign init_done_o = &ch_init_done;

  logic [NrChannels-1:0][31:0] ch_r_live, ch_w_live;
  always_comb begin
    ch_r_beats_o = '0;
    ch_w_beats_o = '0;
    for (int unsigned i = 0; i < NrChannels; i++) begin
      ch_r_beats_o[i] = ch_r_live[i];
      ch_w_beats_o[i] = ch_w_live[i];
    end
  end

  // CLASS1 testharness ELF preload (G6LC_LITEDRAM_PRELOAD from make verilate).
  // Directed GEMM TBs do not define it — no DPI, pl_req tied off.
  logic        pl_pend;
  logic [25:0] pl_na;
  logic [255:0] pl_data;
  logic [31:0] pl_be;
  sel_t        pl_sel;
  logic [NrChannels-1:0] pl_gnt, pl_idle;

`ifdef G6LC_LITEDRAM_PRELOAD
  import "DPI-C" function int g6lc_pl_try_pop(
      output longint unsigned addr,
      output longint unsigned d0,
      output longint unsigned d1,
      output longint unsigned d2,
      output longint unsigned d3,
      output int unsigned be);

  function int g6lc_litedram_pl_busy();
    g6lc_litedram_pl_busy = int'(pl_pend || !pl_idle[pl_sel]);
  endfunction
  export "DPI-C" function g6lc_litedram_pl_busy;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pl_pend <= 1'b0;
      pl_na   <= '0;
      pl_data <= '0;
      pl_be   <= '0;
      pl_sel  <= '0;
    end else if (!pl_pend) begin
      automatic longint unsigned a, d0, d1, d2, d3;
      automatic int unsigned be;
      if (g6lc_pl_try_pop(a, d0, d1, d2, d3, be) != 0) begin
        pl_pend <= 1'b1;
        pl_na   <= a[30:5];
        pl_data <= {d3, d2, d1, d0};
        pl_be   <= be;
        if (NrChannels == 1)
          pl_sel <= '0;
        else
          pl_sel <= sel_t'(a[ChanShift +: SelW]);
      end
    end else if (pl_gnt[pl_sel]) begin
      pl_pend <= 1'b0;
    end
  end
`else
  assign pl_pend = 1'b0;
  assign pl_na   = '0;
  assign pl_data = '0;
  assign pl_be   = '0;
  assign pl_sel  = '0;
`endif

  for (genvar gi = 0; gi < int'(NrChannels); gi++) begin : gen_occ
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ch_r_live[gi] <= '0;
        ch_w_live[gi] <= '0;
      end else begin
        if (ch[gi].w_valid && ch[gi].w_ready)
          ch_w_live[gi] <= ch_w_live[gi] + 32'd1;
        if (ch[gi].r_valid && ch[gi].r_ready)
          ch_r_live[gi] <= ch_r_live[gi] + 32'd1;
      end
    end
  end

  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni && (NrChannels > 1) && slave.ar_valid && slave.ar_ready) begin
      automatic int unsigned nbytes;
      nbytes = (unsigned'(slave.ar_len) + 1) << unsigned'(slave.ar_size);
      if (!dram_burst_fits_stripe(NrChannels, ChanShift, slave.ar_addr, nbytes))
        $error("g6lc_ai_dram_channels: AR burst straddles stripe addr=%h len=%0d size=%0d",
               slave.ar_addr, slave.ar_len, slave.ar_size);
    end
    if (rst_ni && (NrChannels > 1) && slave.aw_valid && slave.aw_ready) begin
      automatic int unsigned nbytes;
      nbytes = (unsigned'(slave.aw_len) + 1) << unsigned'(slave.aw_size);
      if (!dram_burst_fits_stripe(NrChannels, ChanShift, slave.aw_addr, nbytes))
        $error("g6lc_ai_dram_channels: AW burst straddles stripe addr=%h len=%0d size=%0d",
               slave.aw_addr, slave.aw_len, slave.aw_size);
    end
  end
  // pragma translate_on

  sel_t aw_sel, ar_sel;
  if (NrChannels == 1) begin : gen_sel1
    assign aw_sel = '0;
    assign ar_sel = '0;
  end else begin : gen_seln
    assign aw_sel = sel_t'(slave.aw_addr[ChanShift +: SelW]);
    assign ar_sel = sel_t'(slave.ar_addr[ChanShift +: SelW]);
  end

  axi_demux_intf #(
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH ),
      .NO_MST_PORTS   ( NrChannels     ),
      .MAX_TRANS      ( 8              ),
      .UNIQUE_IDS     ( 1'b1           ),
      .AXI_LOOK_BITS  ( AXI_ID_WIDTH   )
  ) i_chan_demux (
      .clk_i,
      .rst_ni,
      .test_i          ( testmode_i ),
      .slv_aw_select_i ( aw_sel     ),
      .slv_ar_select_i ( ar_sel     ),
      .slv             ( slave      ),
      .mst             ( ch         )
  );

  for (genvar i = 0; i < int'(NrChannels); i++) begin : gen_ch
    g6lc_ai_litedram_wrap #(
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
        .AXI_USER_WIDTH ( AXI_USER_WIDTH ),
        .ForceInitDone  ( 1'b1 ),
        .NrArSlots      ( MaxAROut ),
        .NrAwSlots      ( MaxAROut )
    ) i_wrap (
        .clk_i,
        .rst_ni,
        .slave       ( ch[i] ),
        .init_done_o ( ch_init_done[i] ),
        .pl_req_i    ( pl_pend && (sel_t'(i) == pl_sel) ),
        .pl_gnt_o    ( pl_gnt[i] ),
        .pl_na_i     ( pl_na ),
        .pl_data_i   ( pl_data ),
        .pl_be_i     ( pl_be ),
        .pl_idle_o   ( pl_idle[i] )
    );
  end

endmodule
