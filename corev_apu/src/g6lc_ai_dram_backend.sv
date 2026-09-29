// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// I3 DRAM backend behind the testharness AXI atomics/delayer.
// This is the **SoC DRAM slave** (cluster mem_req + island DMA), not an
// island-private PHY. Core I$/D$/PTW/L2 and NrCores already miss here.
// DramClass=0 N=1: existing axi2mem + sram (I3-lite identity). init_done_o = 1.
// DramClass=0 N>1: same stripe demux as class 1, SRAM per channel (sim).
// DramClass=1: LiteDRAM AXI4 slave at this seam after `vendor sync litedram`.
//   Port contract (do not invent instance names until the vendor tree exists):
//   - AXI4 slave width/ID/addr match the xbar (live 64-bit, IdWidthSlave).
//   - sys clock = clk_i; DRAM clock CDC lives inside the LiteDRAM wrapper,
//     never a second async reset into this module.
//   - AXI-Lite CSR (init/calib/status) is a later generate, not a silent
//     SRAM fallback.
//   - init_done_o stays 0 until calib; testharness may leave it unconnected.
// DramClass=2: LPDDR5 SKU only — same $error until a licensed PHY exists.
// Timing: class 0 N=1 is combinational-behind-sram (existing axi2mem path).
// Class 1 elaborates behind G6LC_AI_DRAM_CLASS1 + G6LC_HAVE_LITEDRAM (native wrap).

`include "axi/assign.svh"

module g6lc_ai_dram_backend
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned DramClass      = AI_DRAM_SIM_AXI,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter int unsigned AXI_USER_EN    = 0,
    parameter int unsigned NUM_WORDS      = 2 ** 25,
    parameter int unsigned NrChannels     = 1,
    parameter int unsigned ChanShift      = AI_DRAM_CHAN_SHIFT_DEFAULT,
    parameter int unsigned MaxAROut       = AI_MAX_AR_OUT_DRAM,
    // Class 2 rate socket. Default off: DramClass 2 still $error.
    parameter bit          Class2Model    = 1'b0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic rst_sram_ni,
    input  logic testmode_i,
    AXI_BUS.Slave slave,
    output logic init_done_o,
    // SoC-side occupancy (S5). Island CAP stays aggregate GEMM.
    output logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats_o,
    output logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_w_beats_o
);

  if (DramClass == AI_DRAM_SIM_AXI && NrChannels == 1) begin : gen_sim_axi
    assign init_done_o = 1'b1;

    logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_q, ch_w_q;
    assign ch_r_beats_o = ch_r_q;
    assign ch_w_beats_o = ch_w_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ch_r_q <= '0;
        ch_w_q <= '0;
      end else begin
        if (slave.w_valid && slave.w_ready)
          ch_w_q[0] <= ch_w_q[0] + 32'd1;
        if (slave.r_valid && slave.r_ready)
          ch_r_q[0] <= ch_r_q[0] + 32'd1;
      end
    end
    // [0] is the only live channel; upper slices stay 0 from reset.

    logic                         req, we;
    logic [AXI_ADDR_WIDTH-1:0]    addr;
    logic [AXI_DATA_WIDTH/8-1:0]  be;
    logic [AXI_DATA_WIDTH-1:0]    wdata, rdata;
    logic [AXI_USER_WIDTH-1:0]    wuser, ruser;

    axi2mem #(
        .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_USER_WIDTH ( AXI_USER_WIDTH )
    ) i_axi2mem (
        .clk_i  ( clk_i      ),
        .rst_ni ( rst_ni     ),
        .slave  ( slave      ),
        .req_o  ( req        ),
        .we_o   ( we         ),
        .addr_o ( addr       ),
        .be_o   ( be         ),
        .user_o ( wuser      ),
        .data_o ( wdata      ),
        .user_i ( ruser      ),
        .data_i ( rdata      )
    );

    sram #(
        .DATA_WIDTH ( AXI_DATA_WIDTH ),
        .USER_WIDTH ( AXI_USER_WIDTH ),
        .USER_EN    ( AXI_USER_EN    ),
`ifdef VERILATOR
        .SIM_INIT   ( "none"         ),
`else
        .SIM_INIT   ( "zeros"        ),
`endif
        .NUM_WORDS  ( NUM_WORDS      )
    ) i_sram (
        .clk_i   ( clk_i      ),
        .rst_ni  ( rst_sram_ni ),
        .req_i   ( req        ),
        .we_i    ( we         ),
        .addr_i  ( addr[$clog2(NUM_WORDS)-1+$clog2(AXI_DATA_WIDTH/8):$clog2(AXI_DATA_WIDTH/8)] ),
        .wuser_i ( wuser      ),
        .wdata_i ( wdata      ),
        .be_i    ( be         ),
        .ruser_o ( ruser      ),
        .rdata_o ( rdata      )
    );
  end else if (DramClass == AI_DRAM_SIM_AXI) begin : gen_sim_stripe
    // Class-0 N>1: same axi_demux stripe as class 1, SRAM per channel.
    // N=1 does not enter here (cookie / HARD identity).
    localparam int unsigned SelW     = $clog2(NrChannels);
    localparam int unsigned ChWords  = NUM_WORDS / NrChannels;
    localparam int unsigned ByteOffW = $clog2(AXI_DATA_WIDTH / 8);
    typedef logic [SelW-1:0] sel_t;

    assign init_done_o = 1'b1;

    logic [NrChannels-1:0][31:0] ch_r_live, ch_w_live;
    always_comb begin
      ch_r_beats_o = '0;
      ch_w_beats_o = '0;
      for (int unsigned i = 0; i < NrChannels; i++) begin
        ch_r_beats_o[i] = ch_r_live[i];
        ch_w_beats_o[i] = ch_w_live[i];
      end
    end

    // pragma translate_off
    initial begin
      assert (dram_channels_ok(NrChannels))
        else $error("g6lc_ai_dram_backend: NrChannels=%0d not in {1,2,4,8}", NrChannels);
      assert ((NUM_WORDS % NrChannels) == 0)
        else $error("g6lc_ai_dram_backend: NUM_WORDS not divisible by NrChannels");
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni && slave.ar_valid && slave.ar_ready) begin
        automatic int unsigned nbytes;
        nbytes = (unsigned'(slave.ar_len) + 1) << unsigned'(slave.ar_size);
        if (!dram_burst_fits_stripe(NrChannels, ChanShift, slave.ar_addr, nbytes))
          $error("g6lc_ai_dram_backend: AR burst straddles stripe addr=%h len=%0d size=%0d",
                 slave.ar_addr, slave.ar_len, slave.ar_size);
      end
      if (rst_ni && slave.aw_valid && slave.aw_ready) begin
        automatic int unsigned nbytes;
        nbytes = (unsigned'(slave.aw_len) + 1) << unsigned'(slave.aw_size);
        if (!dram_burst_fits_stripe(NrChannels, ChanShift, slave.aw_addr, nbytes))
          $error("g6lc_ai_dram_backend: AW burst straddles stripe addr=%h len=%0d size=%0d",
                 slave.aw_addr, slave.aw_len, slave.aw_size);
      end
    end
    // pragma translate_on

    AXI_BUS #(
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
        .AXI_USER_WIDTH ( AXI_USER_WIDTH )
    ) ch[NrChannels-1:0]();

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

    sel_t aw_sel, ar_sel;
    assign aw_sel = sel_t'(slave.aw_addr[ChanShift +: SelW]);
    assign ar_sel = sel_t'(slave.ar_addr[ChanShift +: SelW]);

    axi_demux_intf #(
        .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_USER_WIDTH ( AXI_USER_WIDTH ),
        .NO_MST_PORTS   ( NrChannels     ),
        .MAX_TRANS      ( 8              ),
        // Same AXI ID may target a new channel after B/R.last (core WT of
        // consecutive 64 B lines). Occupied-ID lock would pin that ID to ch0.
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
      logic                         req, we;
      logic [AXI_ADDR_WIDTH-1:0]    addr, local_a;
      logic [AXI_DATA_WIDTH/8-1:0]  be;
      logic [AXI_DATA_WIDTH-1:0]    wdata, rdata;
      logic [AXI_USER_WIDTH-1:0]    wuser, ruser;

      // Drop stripe-select bits so each SRAM is dense NUM_WORDS/N.
      assign local_a = {{SelW{1'b0}}, addr[AXI_ADDR_WIDTH-1:ChanShift+SelW],
                        addr[ChanShift-1:0]};

      // Register slice between the demux and the combinational axi2mem slave.
      // The demux's whole-struct request process and axi2mem's single ready/valid
      // process otherwise form a Verilator scheduling loop; the cut adds one
      // cycle per channel on this simulation-only class-0 model.
      AXI_BUS #(
          .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
          .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
          .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
          .AXI_USER_WIDTH ( AXI_USER_WIDTH )
      ) ch_cut();

      axi_cut_intf #(
          .ADDR_WIDTH ( AXI_ADDR_WIDTH ),
          .DATA_WIDTH ( AXI_DATA_WIDTH ),
          .ID_WIDTH   ( AXI_ID_WIDTH   ),
          .USER_WIDTH ( AXI_USER_WIDTH )
      ) i_ch_cut (
          .clk_i,
          .rst_ni,
          .in  ( ch[i]  ),
          .out ( ch_cut )
      );

      axi2mem #(
          .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
          .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
          .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
          .AXI_USER_WIDTH ( AXI_USER_WIDTH )
      ) i_axi2mem (
          .clk_i  ( clk_i   ),
          .rst_ni ( rst_ni  ),
          .slave  ( ch_cut  ),
          .req_o  ( req     ),
          .we_o   ( we      ),
          .addr_o ( addr    ),
          .be_o   ( be      ),
          .user_o ( wuser   ),
          .data_o ( wdata   ),
          .user_i ( ruser   ),
          .data_i ( rdata   )
      );

      sram #(
          .DATA_WIDTH ( AXI_DATA_WIDTH ),
          .USER_WIDTH ( AXI_USER_WIDTH ),
          .USER_EN    ( AXI_USER_EN    ),
`ifdef VERILATOR
          .SIM_INIT   ( "none"         ),
`else
          .SIM_INIT   ( "zeros"        ),
`endif
          .NUM_WORDS  ( ChWords        )
      ) i_sram (
          .clk_i   ( clk_i       ),
          .rst_ni  ( rst_sram_ni ),
          .req_i   ( req         ),
          .we_i    ( we          ),
          .addr_i  ( local_a[$clog2(ChWords)-1+ByteOffW:ByteOffW] ),
          .wuser_i ( wuser       ),
          .wdata_i ( wdata       ),
          .be_i    ( be          ),
          .ruser_o ( ruser       ),
          .rdata_o ( rdata       )
      );
    end
  end else if (DramClass == AI_DRAM_LPDDR5 && !Class2Model) begin : gen_no_lpddr5
    // Class 2 stays a refused elaboration. A licensed LPDDR5 PHY is a later
    // plan; this branch must not borrow the class-1 LiteDRAM wrapper.
    assign init_done_o  = 1'b0;
    assign ch_r_beats_o = '0;
    assign ch_w_beats_o = '0;
    initial $error("g6lc_ai_dram_backend: DramClass=2 (LPDDR5) has no PHY");
  end else if (DramClass == AI_DRAM_LPDDR5) begin : gen_class2_model
    // Rate socket. Not a PHY and not gen_sim_axi. The log of the directed
    // test says "model". Beats are accepted and counted; data is not stored.
    logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_w_q;
    assign init_done_o  = rst_ni;
    assign ch_r_beats_o = '0;
    assign ch_w_beats_o = ch_w_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) ch_w_q <= '0;
      else if (slave.w_valid && slave.w_ready) ch_w_q[0] <= ch_w_q[0] + 32'd1;
    end
    assign slave.aw_ready = rst_ni;
    assign slave.w_ready  = rst_ni;
    assign slave.ar_ready = rst_ni;
    assign slave.b_valid  = 1'b0;
    assign slave.b_id     = '0;
    assign slave.b_resp   = axi_pkg::RESP_OKAY;
    assign slave.b_user   = '0;
    assign slave.r_valid  = 1'b0;
    assign slave.r_id     = '0;
    assign slave.r_data   = '0;
    assign slave.r_resp   = axi_pkg::RESP_OKAY;
    assign slave.r_last   = 1'b0;
    assign slave.r_user   = '0;
  end else begin : gen_need_litedram
    // Class 1: N independent LiteDRAM controllers (one gen.py --sim core
    // each). Testharness CLASS1/CHANS_* elaborate this; default is class 0.
    g6lc_ai_dram_channels #(
        .NrChannels     ( NrChannels     ),
        .ChanShift      ( ChanShift      ),
        .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
        .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
        .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
        .AXI_USER_WIDTH ( AXI_USER_WIDTH ),
        .MaxAROut       ( MaxAROut       )
    ) i_dram_channels (
        .clk_i,
        .rst_ni,
        .testmode_i,
        .slave        ( slave ),
        .init_done_o  ( init_done_o ),
        .ch_r_beats_o ( ch_r_beats_o ),
        .ch_w_beats_o ( ch_w_beats_o )
    );
  end

endmodule
