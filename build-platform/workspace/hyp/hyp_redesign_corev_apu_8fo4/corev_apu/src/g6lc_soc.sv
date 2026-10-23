// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// hyp8 provenance: REWRITTEN (synthesizable SoC top; structure derived from
// the upstream testbench harness + peripherals — all simulation-only logic
// (DPI, SimJTAG/SimDTM, TB memories, trace hooks) removed)
//
// g6lc_soc: LibreCore SoC top (single physical hart, g6lc64_ooo config).
//
//   clk_core_i   g6lc_hart + L1/L2 pipeline clock
//   clk_uncore_i SoC fabric clock (xbar, CLINT/PLIC, debug, APB peripherals)
//
// The hart's AXI master crosses clk_core -> clk_uncore inside g6lc_hart
// (vendor axi_cdc gray FIFOs); in this draft both inputs may be tied to the
// same clock — the CDC seam is real and stays (H13).
//
// Memory map and interrupt IDs are identical to g6lc_soc (pkg) so the
// device tree is unchanged:
//   Debug 0x0000_0000  ROM 0x0001_0000  CLINT 0x0200_0000
//   PLIC  0x0C00_0000  UART 0x1000_0000  Timer 0x1800_0000
//   SPI   0x2000_0000  Eth 0x3000_0000   GPIO  0x4000_0000
//   DRAM  0x8000_0000 (exported as dram_axi_req_o/dram_axi_resp_i)
//
// Timing (8-FO4 budget): the crossbar runs with CUT_ALL_PORTS (vendor
// spill registers on every demux/mux channel — rank-4 request/response
// registering at every SoC port); the ROM and debug slaves sit behind
// registered simple-mem bridges (g6lc_axi2mem_reg / axi2mem); the APB
// peripherals sit behind g6lc_axi2apb_reg (registered request + registered
// response). See notes/decisions.md.

`include "axi/assign.svh"
`include "register_interface/assign.svh"
`include "register_interface/typedef.svh"

module g6lc_soc #(
  parameter config_pkg::g6lc_cfg_t G6LCCfg =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg),
  parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_config_pkg::HypCfg,
  parameter int unsigned AXI_ADDRESS_WIDTH = 64,
  parameter int unsigned AXI_DATA_WIDTH    = 64,
  parameter int unsigned AXI_USER_WIDTH    = G6LCCfg.AxiUserWidth
) (
  input  logic                        clk_core_i,
  input  logic                        clk_uncore_i,
  input  logic                        rst_ni,
  // real-time counter clock for the CLINT (may equal clk_uncore_i)
  input  logic                        rtc_i,
  // static per-boot inputs (as the upstream harness provides)
  input  logic [G6LCCfg.VLEN-1:0]     boot_addr_i,
  input  logic [G6LCCfg.XLEN-1:0]     hart_id_i,
  // DFT/scan enable for the SoC fabric
  input  logic                        test_mode_i,
  // external PLIC interrupt sources [NumSources-1:7]; sources 0..6 are
  // local (UART, SPI(0), Ethernet(0), timer[6:3])
  input  logic [g6lc_soc::NumSources-1:7] ext_irq_i,
  // JTAG debug transport
  input  logic                        jtag_tck_i,
  input  logic                        jtag_tms_i,
  input  logic                        jtag_trst_ni,
  input  logic                        jtag_tdi_i,
  output logic                        jtag_tdo_o,
  output logic                        jtag_tdo_oen_o,
  // UART pins
  input  logic                        uart_rx_i,
  output logic                        uart_tx_o,
  // exported DRAM AXI slave port (off-chip memory controller attaches)
  output g6lc_axi_soc::req_slv_t      dram_axi_req_o,
  input  g6lc_axi_soc::resp_slv_t     dram_axi_resp_i
);

  localparam int unsigned NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned NB_MST = g6lc_soc::NB_PERIPHERALS;

  logic ndmreset;
  logic ndmreset_n;
  logic core_rst_n;
  // dm_top debug_req_o is per-hart; g6lc_hart takes a single request for
  // the physical core — any-hart halt enters debug (upstream wiring had
  // NrHarts==1, so this reduces to a pass-through).
  logic [NH-1:0] debug_req_core;

  // ---------------------------------------------------------------------
  // reset: rstgen per clock domain, gated by the debug module's ndmreset
  // (as in the upstream harness). The uncore side resets the fabric; the
  // core side feeds g6lc_hart.rst_ni.
  // ---------------------------------------------------------------------
  rstgen i_rstgen_uncore (
    .clk_i       ( clk_uncore_i            ),
    .rst_ni      ( rst_ni & (~ndmreset)    ),
    .test_mode_i ( test_mode_i             ),
    .rst_no      ( ndmreset_n              ),
    .init_no     (                         )
  );

  rstgen i_rstgen_core (
    .clk_i       ( clk_core_i              ),
    .rst_ni      ( rst_ni & (~ndmreset)    ),
    .test_mode_i ( test_mode_i             ),
    .rst_no      ( core_rst_n              ),
    .init_no     (                         )
  );

  // ---------------------------------------------------------------------
  // AXI crossbar — vendor axi_xbar with CUT_ALL_PORTS: a spill register on
  // every channel of every port (rank-4 boundary registering).
  // ---------------------------------------------------------------------
  g6lc_axi::req_t        [g6lc_soc::NrSlaves-1:0] slv_req;
  g6lc_axi::resp_t       [g6lc_soc::NrSlaves-1:0] slv_resp;
  g6lc_axi_soc::req_slv_t  [NB_MST-1:0]           mst_req;
  g6lc_axi_soc::resp_slv_t [NB_MST-1:0]           mst_resp;

  localparam int unsigned NB_RULES = NB_MST;

  axi_pkg::xbar_rule_64_t [NB_RULES-1:0] addr_map;
  assign addr_map = '{
    '{ idx: g6lc_soc::Debug,    start_addr: g6lc_soc::DebugBase,
       end_addr: g6lc_soc::DebugBase + g6lc_soc::DebugLength       },
    '{ idx: g6lc_soc::ROM,      start_addr: g6lc_soc::ROMBase,
       end_addr: g6lc_soc::ROMBase + g6lc_soc::ROMLength           },
    '{ idx: g6lc_soc::CLINT,    start_addr: g6lc_soc::CLINTBase,
       end_addr: g6lc_soc::CLINTBase + g6lc_soc::CLINTLength       },
    '{ idx: g6lc_soc::PLIC,     start_addr: g6lc_soc::PLICBase,
       end_addr: g6lc_soc::PLICBase + g6lc_soc::PLICLength         },
    '{ idx: g6lc_soc::UART,     start_addr: g6lc_soc::UARTBase,
       end_addr: g6lc_soc::UARTBase + g6lc_soc::UARTLength         },
    '{ idx: g6lc_soc::Timer,    start_addr: g6lc_soc::TimerBase,
       end_addr: g6lc_soc::TimerBase + g6lc_soc::TimerLength       },
    '{ idx: g6lc_soc::SPI,      start_addr: g6lc_soc::SPIBase,
       end_addr: g6lc_soc::SPIBase + g6lc_soc::SPILength           },
    '{ idx: g6lc_soc::Ethernet, start_addr: g6lc_soc::EthernetBase,
       end_addr: g6lc_soc::EthernetBase + g6lc_soc::EthernetLength },
    '{ idx: g6lc_soc::GPIO,     start_addr: g6lc_soc::GPIOBase,
       end_addr: g6lc_soc::GPIOBase + g6lc_soc::GPIOLength         },
    '{ idx: g6lc_soc::DRAM,     start_addr: g6lc_soc::DRAMBase,
       end_addr: g6lc_soc::DRAMBase + g6lc_soc::DRAMLength         }
  };

  localparam axi_pkg::xbar_cfg_t AXI_XBAR_CFG = '{
    NoSlvPorts:  unsigned'(g6lc_soc::NrSlaves),
    NoMstPorts:  unsigned'(NB_MST),
    MaxMstTrans: unsigned'(8),
    MaxSlvTrans: unsigned'(8),
    FallThrough: 1'b0,
    // hyp8: spill registers on every port/channel — the SoC-side rank-4
    // boundary cut (covers axi_demux/axi_mux interior paths).
    LatencyMode: axi_pkg::CUT_ALL_PORTS,
    AxiIdWidthSlvPorts: unsigned'(g6lc_axi_soc::IdWidth),
    AxiIdUsedSlvPorts:  unsigned'(g6lc_axi_soc::IdWidth),
    UniqueIds:   1'b0,
    AxiAddrWidth: unsigned'(AXI_ADDRESS_WIDTH),
    AxiDataWidth: unsigned'(AXI_DATA_WIDTH),
    NoAddrRules:  unsigned'(NB_RULES)
  };

  axi_xbar #(
    .Cfg          ( AXI_XBAR_CFG            ),
    .ATOPs        ( 1'b1                    ),
    .slv_aw_chan_t( g6lc_axi::aw_chan_t     ),
    .mst_aw_chan_t( g6lc_axi_soc::aw_chan_slv_t ),
    .w_chan_t     ( g6lc_axi::w_chan_t      ),
    .slv_b_chan_t ( g6lc_axi::b_chan_t      ),
    .mst_b_chan_t ( g6lc_axi_soc::b_chan_slv_t ),
    .slv_ar_chan_t( g6lc_axi::ar_chan_t     ),
    .mst_ar_chan_t( g6lc_axi_soc::ar_chan_slv_t ),
    .slv_r_chan_t ( g6lc_axi::r_chan_t      ),
    .mst_r_chan_t ( g6lc_axi_soc::r_chan_slv_t ),
    .slv_req_t    ( g6lc_axi::req_t         ),
    .slv_resp_t   ( g6lc_axi::resp_t        ),
    .mst_req_t    ( g6lc_axi_soc::req_slv_t ),
    .mst_resp_t   ( g6lc_axi_soc::resp_slv_t ),
    .rule_t       ( axi_pkg::xbar_rule_64_t )
  ) i_axi_xbar (
    .clk_i                 ( clk_uncore_i       ),
    .rst_ni                ( ndmreset_n         ),
    .test_i                ( test_mode_i        ),
    .slv_ports_req_i       ( slv_req            ),
    .slv_ports_resp_o      ( slv_resp           ),
    .mst_ports_req_o       ( mst_req            ),
    .mst_ports_resp_i      ( mst_resp           ),
    .addr_map_i            ( addr_map           ),
    .en_default_mst_port_i ( '0                 ),
    .default_mst_port_i    ( '0                 )
  );

  // xbar slave port 2 is reserved (upstream uses it for a second DMA
  // master); tie it idle.
  assign slv_req[2] = '0;

  // ---------------------------------------------------------------------
  // DRAM — exported master port
  // ---------------------------------------------------------------------
  assign dram_axi_req_o      = mst_req[g6lc_soc::DRAM];
  assign mst_resp[g6lc_soc::DRAM] = dram_axi_resp_i;

  // ---------------------------------------------------------------------
  // CLINT (one MSIP/MTIMECMP per software hart)
  // ---------------------------------------------------------------------
  logic [NH-1:0] ipi;
  logic [NH-1:0] timer_irq;
  logic [63:0]   clint_mtime;

  g6lc_axi_soc::req_slv_t  axi_clint_req;
  g6lc_axi_soc::resp_slv_t axi_clint_resp;
  assign axi_clint_req            = mst_req[g6lc_soc::CLINT];
  assign mst_resp[g6lc_soc::CLINT] = axi_clint_resp;

  clint #(
    .G6LCCfg        ( G6LCCfg                    ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH          ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH             ),
    .AXI_ID_WIDTH   ( g6lc_axi_soc::IdWidthSlave ),
    .NR_CORES       ( NH                         ),
    .axi_req_t      ( g6lc_axi_soc::req_slv_t    ),
    .axi_resp_t     ( g6lc_axi_soc::resp_slv_t   )
  ) i_clint (
    .clk_i       ( clk_uncore_i   ),
    .rst_ni      ( ndmreset_n     ),
    .testmode_i  ( test_mode_i    ),
    .axi_req_i   ( axi_clint_req  ),
    .axi_resp_o  ( axi_clint_resp ),
    .rtc_i       ( rtc_i          ),
    .timer_irq_o ( timer_irq      ),
    .ipi_o       ( ipi            ),
    .mtime_o     ( clint_mtime    )
  );

  // ---------------------------------------------------------------------
  // PLIC — axi2apb (registered) -> apb_to_reg -> REG_BUS -> plic_top
  // ---------------------------------------------------------------------
  logic [g6lc_soc::NumTargets-1:0] irqs;
  logic [g6lc_soc::NumSources-1:0] irq_sources;

  logic         plic_penable;
  logic         plic_pwrite;
  logic [31:0]  plic_paddr;
  logic         plic_psel;
  logic [31:0]  plic_pwdata;
  logic [31:0]  plic_prdata;
  logic         plic_pready;
  logic         plic_pslverr;

  // local PLIC sources: 0 = UART, 1 = SPI (unused), 2 = Ethernet (unused),
  // 6:3 = APB timer, 7.. = external pins
  assign irq_sources[g6lc_soc::NumSources-1:7] = ext_irq_i;
  assign irq_sources[2:1] = 2'b0;

  g6lc_axi2apb_reg #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH    ),
    .APB_ADDR_WIDTH ( 32                )
  ) i_axi2apb_plic (
    .clk_i     ( clk_uncore_i   ),
    .rst_ni    ( ndmreset_n     ),
    .slv_req_i ( mst_req[g6lc_soc::PLIC]  ),
    .slv_resp_o( mst_resp[g6lc_soc::PLIC] ),
    .psel_o    ( plic_psel      ),
    .penable_o ( plic_penable   ),
    .pwrite_o  ( plic_pwrite    ),
    .paddr_o   ( plic_paddr     ),
    .pwdata_o  ( plic_pwdata    ),
    .prdata_i  ( plic_prdata    ),
    .pready_i  ( plic_pready    ),
    .pslverr_i ( plic_pslverr   )
  );

  REG_BUS #(
    .ADDR_WIDTH ( 32 ),
    .DATA_WIDTH ( 32 )
  ) plic_reg_bus (clk_uncore_i);

  apb_to_reg i_apb_to_reg_plic (
    .clk_i     ( clk_uncore_i ),
    .rst_ni    ( ndmreset_n   ),
    .penable_i ( plic_penable ),
    .pwrite_i  ( plic_pwrite  ),
    .paddr_i   ( plic_paddr   ),
    .psel_i    ( plic_psel    ),
    .pwdata_i  ( plic_pwdata  ),
    .prdata_o  ( plic_prdata  ),
    .pready_o  ( plic_pready  ),
    .pslverr_o ( plic_pslverr ),
    .reg_o     ( plic_reg_bus )
  );

  `REG_BUS_TYPEDEF_ALL(plic, logic[31:0], logic[31:0], logic[3:0])
  plic_req_t plic_req;
  plic_rsp_t plic_rsp;

  `REG_BUS_ASSIGN_TO_REQ(plic_req, plic_reg_bus)
  `REG_BUS_ASSIGN_FROM_RSP(plic_reg_bus, plic_rsp)

  plic_top #(
    .N_SOURCE    ( g6lc_soc::NumSources  ),
    .N_TARGET    ( g6lc_soc::NumTargets  ),
    .MAX_PRIO    ( g6lc_soc::MaxPriority ),
    .reg_req_t   ( plic_req_t            ),
    .reg_rsp_t   ( plic_rsp_t            )
  ) i_plic (
    .clk_i         ( clk_uncore_i ),
    .rst_ni        ( ndmreset_n   ),
    .req_i         ( plic_req     ),
    .resp_o        ( plic_rsp     ),
    .le_i          ( '0           ), // 0:level 1:edge
    .irq_sources_i ( irq_sources  ),
    .eip_targets_o ( irqs         )
  );

  // ---------------------------------------------------------------------
  // UART — axi2apb (registered) -> apb_uart
  // ---------------------------------------------------------------------
  logic         uart_penable;
  logic         uart_pwrite;
  logic [31:0]  uart_paddr;
  logic         uart_psel;
  logic [31:0]  uart_pwdata;
  logic [31:0]  uart_prdata;
  logic         uart_pready;
  logic         uart_pslverr;

  g6lc_axi2apb_reg #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH    ),
    .APB_ADDR_WIDTH ( 32                )
  ) i_axi2apb_uart (
    .clk_i     ( clk_uncore_i   ),
    .rst_ni    ( ndmreset_n     ),
    .slv_req_i ( mst_req[g6lc_soc::UART]  ),
    .slv_resp_o( mst_resp[g6lc_soc::UART] ),
    .psel_o    ( uart_psel      ),
    .penable_o ( uart_penable   ),
    .pwrite_o  ( uart_pwrite    ),
    .paddr_o   ( uart_paddr     ),
    .pwdata_o  ( uart_pwdata    ),
    .prdata_i  ( uart_prdata    ),
    .pready_i  ( uart_pready    ),
    .pslverr_i ( uart_pslverr   )
  );

  apb_uart i_apb_uart (
    .CLK     ( clk_uncore_i      ),
    .RSTN    ( ndmreset_n        ),
    .PSEL    ( uart_psel         ),
    .PENABLE ( uart_penable      ),
    .PWRITE  ( uart_pwrite       ),
    .PADDR   ( uart_paddr[4:2]   ),
    .PWDATA  ( uart_pwdata       ),
    .PRDATA  ( uart_prdata       ),
    .PREADY  ( uart_pready       ),
    .PSLVERR ( uart_pslverr      ),
    .INT     ( irq_sources[0]    ),
    .OUT1N   (                   ),
    .OUT2N   (                   ),
    .RTSN    (                   ),
    .DTRN    (                   ),
    .CTSN    ( 1'b0              ),
    .DSRN    ( 1'b0              ),
    .DCDN    ( 1'b0              ),
    .RIN     ( 1'b0              ),
    .SIN     ( uart_rx_i         ),
    .SOUT    ( uart_tx_o         )
  );

  // ---------------------------------------------------------------------
  // Timer — axi2apb (registered) -> apb_timer (registered response)
  // ---------------------------------------------------------------------
  logic         timer_penable;
  logic         timer_pwrite;
  logic [31:0]  timer_paddr;
  logic         timer_psel;
  logic [31:0]  timer_pwdata;
  logic [31:0]  timer_prdata;
  logic         timer_pready;
  logic         timer_pslverr;

  g6lc_axi2apb_reg #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH    ),
    .APB_ADDR_WIDTH ( 32                )
  ) i_axi2apb_timer (
    .clk_i     ( clk_uncore_i   ),
    .rst_ni    ( ndmreset_n     ),
    .slv_req_i ( mst_req[g6lc_soc::Timer]  ),
    .slv_resp_o( mst_resp[g6lc_soc::Timer] ),
    .psel_o    ( timer_psel     ),
    .penable_o ( timer_penable  ),
    .pwrite_o  ( timer_pwrite   ),
    .paddr_o   ( timer_paddr    ),
    .pwdata_o  ( timer_pwdata   ),
    .prdata_i  ( timer_prdata   ),
    .pready_i  ( timer_pready   ),
    .pslverr_i ( timer_pslverr  )
  );

  apb_timer #(
    .APB_ADDR_WIDTH ( 32 ),
    .TIMER_CNT      ( 2  )
  ) i_timer (
    .HCLK    ( clk_uncore_i      ),
    .HRESETn ( ndmreset_n        ),
    .PSEL    ( timer_psel        ),
    .PENABLE ( timer_penable     ),
    .PWRITE  ( timer_pwrite      ),
    .PADDR   ( timer_paddr       ),
    .PWDATA  ( timer_pwdata      ),
    .PRDATA  ( timer_prdata      ),
    .PREADY  ( timer_pready      ),
    .PSLVERR ( timer_pslverr     ),
    .irq_o   ( irq_sources[6:3]  )
  );

  // ---------------------------------------------------------------------
  // Unused peripheral windows — combinational SLVERR responder on the
  // (already spill-registered) xbar master ports, as upstream.
  // ---------------------------------------------------------------------
  for (genvar i = 0; i < NB_MST; i++) begin : gen_err_slave
    if (i == g6lc_soc::GPIO || i == g6lc_soc::Ethernet
        || i == g6lc_soc::SPI) begin : gen_slverr
      always_comb begin
        mst_resp[i]          = '0;
        mst_resp[i].aw_ready = 1'b1;
        mst_resp[i].ar_ready = 1'b1;
        mst_resp[i].w_ready  = 1'b1;
        mst_resp[i].b_valid  = mst_req[i].aw_valid;
        mst_resp[i].b.id     = mst_req[i].aw.id;
        mst_resp[i].b.resp   = axi_pkg::RESP_SLVERR;
        mst_resp[i].b.user   = '0;
        mst_resp[i].r_valid  = mst_req[i].ar_valid;
        mst_resp[i].r.id     = mst_req[i].ar.id;
        mst_resp[i].r.resp   = axi_pkg::RESP_SLVERR;
        mst_resp[i].r.data   = 'hdeadbeef;
        mst_resp[i].r.last   = 1'b1;
        mst_resp[i].r.user   = '0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Boot ROM — registered simple-mem bridge (request + banked read)
  // ---------------------------------------------------------------------
  logic                         rom_req;
  logic                         rom_we;
  logic [AXI_ADDRESS_WIDTH-1:0] rom_addr;
  logic [AXI_DATA_WIDTH/8-1:0]  rom_be;
  logic [AXI_DATA_WIDTH-1:0]    rom_wdata;
  logic [AXI_DATA_WIDTH-1:0]    rom_rdata;

  g6lc_axi2mem_reg #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH    ),
    .RD_LAT         ( 3                 )
  ) i_axi2rom (
    .clk_i     ( clk_uncore_i              ),
    .rst_ni    ( ndmreset_n                ),
    .slv_req_i ( mst_req[g6lc_soc::ROM]    ),
    .slv_resp_o( mst_resp[g6lc_soc::ROM]   ),
    .req_o     ( rom_req                   ),
    .we_o      ( rom_we                    ),
    .addr_o    ( rom_addr                  ),
    .be_o      ( rom_be                    ),
    .wdata_o   ( rom_wdata                 ),
    .rdata_i   ( rom_rdata                 )
  );

  // bootrom (hyp8: banked registered read, +1 over the emit's addr_q stage)
  bootrom i_bootrom (
    .clk_i   ( clk_uncore_i ),
    .req_i   ( rom_req      ),
    .addr_i  ( rom_addr     ),
    .rdata_o ( rom_rdata    )
  );

  // ---------------------------------------------------------------------
  // Debug module — dmi_jtag -> dm_top; slave window via the registered
  // simple-mem bridge (dm_top registers request and response, and dm_mem
  // registers its decode — RD_LAT=4: req -> slave_req_q -> dm_mem req_q ->
  // rdata_q -> slave_rdata_q).
  // ---------------------------------------------------------------------
  dm::dmi_req_t  dmi_req;
  dm::dmi_resp_t dmi_resp;
  logic          dmi_req_valid;
  logic          dmi_req_ready;
  logic          dmi_resp_valid;
  logic          dmi_resp_ready;

  // hyp8: the DTM (dmi_jtag) stays on the raw POR like upstream — it must
  // remain accessible across ndmreset pulses.
  dmi_jtag i_dmi_jtag (
    .clk_i            ( clk_uncore_i   ),
    .rst_ni           ( rst_ni         ),
    .testmode_i       ( test_mode_i    ),
    .dmi_req_o        ( dmi_req        ),
    .dmi_req_valid_o  ( dmi_req_valid  ),
    .dmi_req_ready_i  ( dmi_req_ready  ),
    .dmi_resp_i       ( dmi_resp       ),
    .dmi_resp_ready_o ( dmi_resp_ready ),
    .dmi_resp_valid_i ( dmi_resp_valid ),
    .dmi_rst_no       (                ),
    .tck_i            ( jtag_tck_i     ),
    .tms_i            ( jtag_tms_i     ),
    .trst_ni          ( jtag_trst_ni   ),
    .td_i             ( jtag_tdi_i     ),
    .td_o             ( jtag_tdo_o     ),
    .tdo_oe_o         ( jtag_tdo_oen_o )
  );

  logic                         dm_slave_req;
  logic                         dm_slave_we;
  logic [AXI_ADDRESS_WIDTH-1:0] dm_slave_addr;
  logic [AXI_DATA_WIDTH/8-1:0]  dm_slave_be;
  logic [AXI_DATA_WIDTH-1:0]    dm_slave_wdata;
  logic [AXI_DATA_WIDTH-1:0]    dm_slave_rdata;

  logic                dm_master_req;
  logic [63:0]         dm_master_add;
  logic                dm_master_we;
  logic [63:0]         dm_master_wdata;
  logic [63/8-1:0]     dm_master_be;
  logic                dm_master_gnt;
  logic                dm_master_r_valid;
  logic [63:0]         dm_master_r_rdata;

  g6lc_axi2mem_reg #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH    ),
    // hyp8: RD_LAT=4 — req_q beat -> dm_top.slave_req_q (+1) -> dm_mem
    // registered request bundle (+1) -> comb decode -> rdata_q (+1) ->
    // dm_top.slave_rdata_q (+1) = 4 cycles, matching the rd_wait counter.
    .RD_LAT         ( 4                 )
  ) i_axi2dm (
    .clk_i     ( clk_uncore_i              ),
    .rst_ni    ( ndmreset_n                ),
    .slv_req_i ( mst_req[g6lc_soc::Debug]  ),
    .slv_resp_o( mst_resp[g6lc_soc::Debug] ),
    .req_o     ( dm_slave_req              ),
    .we_o      ( dm_slave_we               ),
    .addr_o    ( dm_slave_addr             ),
    .be_o      ( dm_slave_be               ),
    .wdata_o   ( dm_slave_wdata            ),
    .rdata_i   ( dm_slave_rdata            )
  );

  dm_top #(
    .NrHarts          ( NH             ),
    .BusWidth         ( AXI_DATA_WIDTH ),
    .SelectableHarts  ( 1'b1           )
  ) i_dm_top (
    .clk_i            ( clk_uncore_i       ),
    .rst_ni           ( ndmreset_n         ),
    .testmode_i       ( test_mode_i        ),
    .ndmreset_o       ( ndmreset           ),
    .dmactive_o       (                    ),
    .debug_req_o      ( debug_req_core     ),
    .unavailable_i    ( '0                 ),
    .hartinfo_i       ( {NH{g6lc_core_pkg::DebugHartInfo}} ),
    .slave_req_i      ( dm_slave_req       ),
    .slave_we_i       ( dm_slave_we        ),
    .slave_addr_i     ( dm_slave_addr      ),
    .slave_be_i       ( dm_slave_be        ),
    .slave_wdata_i    ( dm_slave_wdata     ),
    .slave_rdata_o    ( dm_slave_rdata     ),
    .master_req_o     ( dm_master_req      ),
    .master_add_o     ( dm_master_add      ),
    .master_we_o      ( dm_master_we       ),
    .master_wdata_o   ( dm_master_wdata    ),
    .master_be_o      ( dm_master_be       ),
    .master_gnt_i     ( dm_master_gnt      ),
    .master_r_valid_i ( dm_master_r_valid  ),
    .master_r_rdata_i ( dm_master_r_rdata  ),
    .dmi_rst_ni       ( rst_ni             ),
    .dmi_req_valid_i  ( dmi_req_valid      ),
    .dmi_req_ready_o  ( dmi_req_ready      ),
    .dmi_req_i        ( dmi_req            ),
    .dmi_resp_valid_o ( dmi_resp_valid     ),
    .dmi_resp_ready_i ( dmi_resp_ready     ),
    .dmi_resp_o       ( dmi_resp           )
  );

  // debug module bus master -> xbar slave port 1 (via the adapted
  // axi_adapter — registered request assembly, group-8/9 form)
  g6lc_axi::req_t  dm_axi_m_req;
  g6lc_axi::resp_t dm_axi_m_resp;
  assign slv_req[1]       = dm_axi_m_req;
  assign dm_axi_m_resp    = slv_resp[1];

  axi_adapter #(
    .G6LCCfg    ( G6LCCfg           ),
    .DATA_WIDTH ( AXI_DATA_WIDTH    ),
    .axi_req_t  ( g6lc_axi::req_t   ),
    .axi_rsp_t  ( g6lc_axi::resp_t  )
  ) i_dm_axi_master (
    .clk_i                 ( clk_uncore_i      ),
    .rst_ni                ( ndmreset_n        ),
    .req_i                 ( dm_master_req     ),
    .type_i                ( g6lc_core_pkg::SINGLE_REQ ),
    .amo_i                 ( g6lc_core_pkg::AMO_NONE   ),
    .gnt_o                 ( dm_master_gnt     ),
    .addr_i                ( dm_master_add     ),
    .we_i                  ( dm_master_we      ),
    .wdata_i               ( dm_master_wdata   ),
    .be_i                  ( dm_master_be      ),
    .size_i                ( 2'b11             ),
    .id_i                  ( '0                ),
    .valid_o               ( dm_master_r_valid ),
    .rdata_o               ( dm_master_r_rdata ),
    .id_o                  (                   ),
    .critical_word_o       (                   ),
    .critical_word_valid_o (                   ),
    .axi_req_o             ( dm_axi_m_req      ),
    .axi_resp_i            ( dm_axi_m_resp     )
  );

  // ---------------------------------------------------------------------
  // Hart — g6lc_hart (core clock domain; noc crosses to uncore via the
  // hart's internal axi_cdc; irq/ipi/time_irq/debug_req two-flop sync'd)
  // ---------------------------------------------------------------------
  logic [NH-1:0][1:0] hart_irq;
  for (genvar h = 0; h < NH; h++) begin : gen_hart_irq
    assign hart_irq[h] = irqs[2*h +: 2];
  end

  g6lc_hart #(
    .G6LCCfg ( G6LCCfg ),
    .HypCfg  ( HypCfg  )
  ) i_hart (
    .clk_i               ( clk_core_i    ),
    .clk_uncore_i        ( clk_uncore_i  ),
    .rst_ni              ( core_rst_n    ),
    .boot_addr_i         ( boot_addr_i   ),
    .hart_id_i           ( hart_id_i     ),
    .irq_i               ( hart_irq      ),
    .ipi_i               ( ipi           ),
    .time_irq_i          ( timer_irq     ),
    .rtc_time_i          ( clint_mtime   ),
    .debug_req_i         ( |debug_req_core ),
    .core_wfi_all_o      (               ),
    .core_wake_o         (               ),
    .rvfi_probes_o       (               ),
    .noc_req_o           ( slv_req[0]    ),
    .noc_resp_i          ( slv_resp[0]   ),
    .l1_inval_addr_i     ( '0            ),
    .l1_inval_valid_i    ( 1'b0          ),
    .l1_inval_ready_o    (               ),
    .cmo_valid_o         (               ),
    .cmo_op_o            (               ),
    .cmo_addr_o          (               ),
    .cmo_ready_i         ( 1'b0          ),
    .cmo_done_i          ( 1'b0          ),
    .l2_miss_i           ( 1'b0          ),
    .l3_hit_i            ( 1'b0          ),
    .l3_miss_i           ( 1'b0          ),
    .pf_issue_i          ( 1'b0          ),
    .pf_train_i          ( 1'b0          ),
    .l2_pwhold_i         ( 1'b0          ),
    .l3_pwhold_i         ( 1'b0          ),
    .l2_pf_issue_i       ( 1'b0          ),
    .l2_pf_useful_i      ( 1'b0          ),
    .ai_sb_enq_valid_o   (               ),
    .ai_sb_enq_ready_i   ( 1'b0          ),
    .ai_sb_enq_ticket_i  ( '0            ),
    .ai_sb_qid_o         (               ),
    .ai_sb_ticket_o      (               ),
    .ai_sb_desc_ptr_o    (               ),
    .ai_isl_attached_i   ( 1'b0          ),
    .ai_isl_has_completion_i ( 1'b0      ),
    .ai_isl_retired_valid_i  ( 1'b0      ),
    .ai_isl_retired_ticket_i ( '0        ),
    .ai_isl_last_ticket_i    ( '0        ),
    .ai_isl_last_status_i    ( '0        )
  );

  //pragma translate_off
  // M3 bring-up probe (+soc_trace): hart-AR → xbar → ROM slave path.
  logic soc_trace;
  int unsigned soc_lo, soc_hi;
  int unsigned soc_cyc = 0;
  initial begin
    soc_trace = $test$plusargs("soc_trace");
    soc_lo = 0;
    soc_hi = 3000;
    void'($value$plusargs("trace_from=%d", soc_lo));
    void'($value$plusargs("trace_to=%d", soc_hi));
  end
  always_ff @(posedge clk_uncore_i) begin
    if (!ndmreset_n) begin
      soc_cyc = 0;
    end else begin
      soc_cyc++;
    end
    if (ndmreset_n && soc_trace && soc_cyc >= soc_lo && soc_cyc <= soc_hi &&
        (slv_req[0].ar_valid || mst_req[g6lc_soc::ROM].ar_valid || rom_req ||
         mst_resp[g6lc_soc::ROM].r_valid || slv_resp[0].r_valid)) begin
      $display("[soc] t=%0t | slv0 arv=%b arr=%b araddr=%h arid=%h rv=%b rr=%b | rom arv=%b arr=%b addr=%h id=%h rv=%b rr=%b rdata=%h rlast=%b | romreq=%b romaddr=%h romrdata=%h",
        $time,
        slv_req[0].ar_valid, slv_resp[0].ar_ready, slv_req[0].ar.addr, slv_req[0].ar.id,
        slv_resp[0].r_valid, slv_req[0].r_ready,
        mst_req[g6lc_soc::ROM].ar_valid, mst_resp[g6lc_soc::ROM].ar_ready,
        mst_req[g6lc_soc::ROM].ar.addr, mst_req[g6lc_soc::ROM].ar.id,
        mst_resp[g6lc_soc::ROM].r_valid, mst_req[g6lc_soc::ROM].r_ready,
        mst_resp[g6lc_soc::ROM].r.data, mst_resp[g6lc_soc::ROM].r.last,
        rom_req, rom_addr, rom_rdata);
    end
  end
  //pragma translate_on

endmodule
