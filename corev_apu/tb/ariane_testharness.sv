// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 19.03.2017
// Description: Test-harness for Ariane
//              Instantiates an AXI-Bus and memories

`include "axi/assign.svh"
`include "rvfi_types.svh"
`include "iti_types.svh"

`ifdef VERILATOR
`include "custom_uvm_macros.svh"
`else
`include "uvm_macros.svh"
`endif

module ariane_testharness #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg),
  //
  parameter int unsigned AXI_USER_WIDTH    = CVA6Cfg.AxiUserWidth,
  parameter int unsigned AXI_USER_EN       = CVA6Cfg.AXI_USER_EN,
  parameter int unsigned AXI_ADDRESS_WIDTH = 64,
  parameter int unsigned AXI_DATA_WIDTH    = 64,
  parameter bit          InclSimDTM        = 1'b1,
  parameter int unsigned NUM_WORDS         = 2**25,         // memory size
  parameter bit          StallRandomOutput = 1'b0,
  parameter bit          StallRandomInput  = 1'b0,
  parameter int unsigned DramLatency       = 0
) (
  input  logic                           clk_i,
  input  logic                           rtc_i,
  input  logic                           rst_ni,
  output logic [31:0]                    exit_o
);

  // U6.2: physical cores; U6.1 SMT: software harts = cores × NrHarts
  localparam int unsigned NR_CORES =
      (CVA6Cfg.NrCores < 1) ? 1 :
      (CVA6Cfg.NrCores > config_pkg::CVA6_MAX_CORES) ? config_pkg::CVA6_MAX_CORES :
      CVA6Cfg.NrCores;
  localparam int unsigned NR_HARTS_PER_CORE =
      (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  // CLINT/PLIC software contexts scale with total harts (Linux DTS cpu@N count)
  localparam int unsigned NR_HARTS = NR_CORES * NR_HARTS_PER_CORE;
  localparam [7:0] hart_id = '0;

  // RVFI
  localparam type rvfi_instr_t = `RVFI_INSTR_T(CVA6Cfg);
  localparam type rvfi_csr_elmt_t = `RVFI_CSR_ELMT_T(CVA6Cfg);
  localparam type rvfi_csr_t = `RVFI_CSR_T(CVA6Cfg, rvfi_csr_elmt_t);
  localparam type rvfi_to_iti_t = `RVFI_TO_ITI_T(CVA6Cfg);
  localparam type iti_to_encoder_t = `ITI_TO_ENCODER_T(CVA6Cfg);

  // RVFI PROBES
  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg);
  localparam type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t csr;
    rvfi_probes_instr_t instr;
  };

  // disable test-enable
  logic        test_en;
  logic        ndmreset;
  logic        ndmreset_n;
  logic        debug_req_core;
`ifdef G6LC_HAVE_LITEDRAM
  // CLASS1: hold the cluster while C++ drains ELF into LiteDRAM native.
  // Cookie/class-0 does not define G6LC_HAVE_LITEDRAM (SRAM poke stays).
  logic        preload_hold /*verilator public*/ = 1'b1;
`endif

  int          jtag_enable;
  logic        init_done;
  logic [31:0] jtag_exit, dmi_exit;
  logic [31:0] rvfi_exit;
  logic [31:0] tracer_exit;
  logic [NR_CORES-1:0][31:0] core_tracer_exit;
  logic [31:0] tandem_exit;

  logic        jtag_TCK;
  logic        jtag_TMS;
  logic        jtag_TDI;
  logic        jtag_TRSTn;
  logic        jtag_TDO_data;
  logic        jtag_TDO_driven;

  logic        debug_req_valid;
  logic        debug_req_ready;
  logic        debug_resp_valid;
  logic        debug_resp_ready;

  logic        jtag_req_valid;
  logic [6:0]  jtag_req_bits_addr;
  logic [1:0]  jtag_req_bits_op;
  logic [31:0] jtag_req_bits_data;
  logic        jtag_resp_ready;
  logic        jtag_resp_valid;

  logic        dmi_req_valid;
  logic        dmi_resp_ready;
  logic        dmi_resp_valid;

  dm::dmi_req_t  jtag_dmi_req;
  dm::dmi_req_t  dmi_req;

  dm::dmi_req_t  debug_req;
  dm::dmi_resp_t debug_resp;

  assign test_en = 1'b0;

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH       ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH          ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidth ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH          )
  ) slave[ariane_soc::NrSlaves-1:0]();

  // Port 2: AI island desc-fetch DMA master (NrSlaves=3).
  // Driven from gen_ai_island when MatrixEn; idle otherwise.
  ariane_axi::req_t  ai_dma_req;
  ariane_axi::resp_t ai_dma_resp;
  logic              dram_init_done;
  logic [g6lc_ai_island_cfg_pkg::AI_DRAM_MAX_CHANNELS-1:0][31:0]
                     dram_ch_r_beats, dram_ch_w_beats;
  // One island cfg for APB *and* the DRAM slave. Channel/class/shift must
  // not drift between gen_ai_island and i_dram_backend.
  localparam g6lc_ai_island_cfg_pkg::ai_island_cfg_t AiIslandCfg =
`ifdef G6LC_AI_DRAM_CHANS_8
      g6lc_ai_island_cfg_pkg::AiIslandDdr4x8Bringup
`elsif G6LC_AI_DRAM_CHANS_4
      g6lc_ai_island_cfg_pkg::AiIslandDdr4x4Bringup
`elsif G6LC_AI_DRAM_CHANS_2
      g6lc_ai_island_cfg_pkg::AiIslandDdr4x2Bringup
`elsif G6LC_AI_DRAM_CLASS1
      g6lc_ai_island_cfg_pkg::AiIslandDdr4Bringup
`elsif G6LC_AI_DRAM_SIM_CHANS_8
      g6lc_ai_island_cfg_pkg::AiIslandSimChans8
`elsif G6LC_AI_DRAM_SIM_CHANS_4
      g6lc_ai_island_cfg_pkg::AiIslandSimChans4
`elsif G6LC_AI_DRAM_SIM_CHANS_2
      g6lc_ai_island_cfg_pkg::AiIslandSimChans2
`elsif G6LC_AI_DRAM_TIMING
      g6lc_ai_island_cfg_pkg::AiIslandDdr4TimingSim
`else
      g6lc_ai_island_cfg_pkg::AiIslandLatencyDefault
`endif
      ;
  `AXI_ASSIGN_FROM_REQ(slave[2], ai_dma_req)
  `AXI_ASSIGN_TO_RESP(ai_dma_resp, slave[2])

`ifdef G6LC_APU
  localparam int unsigned APU_NB_EXTRA = 3;
  localparam int unsigned APU_GUEST_IDX = ariane_soc::NB_PERIPHERALS;
  localparam int unsigned APU_CTRL_IDX  = ariane_soc::NB_PERIPHERALS + 1;
  localparam int unsigned APU_RAM_IDX   = ariane_soc::NB_PERIPHERALS + 2;
  // Second DRAM rule for the firmware-RAM hole (same master idx, extra rule).
  localparam int unsigned APU_NB_RULES_EXTRA = 1;
`else
  localparam int unsigned APU_NB_EXTRA = 0;
  localparam int unsigned APU_NB_RULES_EXTRA = 0;
`endif
  localparam int unsigned NB_MST = ariane_soc::NB_PERIPHERALS + APU_NB_EXTRA;
  localparam int unsigned NB_RULES = NB_MST + APU_NB_RULES_EXTRA;

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) master[NB_MST-1:0]();

`ifdef G6LC_APU
  logic apu_ram_fault;
  logic apu_fault_reset;
`else
  wire apu_fault_reset = 1'b0;
`endif
  // apu_fault_reset is requested by a supervisor that is NOT reset by
  // ndmreset_n. Gating it here resets the fabric, including a quarantined
  // RAM master, and the RAM fault clears because of that reset.
  rstgen i_rstgen_main (
    .clk_i        ( clk_i                ),
    .rst_ni       ( rst_ni & (~ndmreset) & ~apu_fault_reset ),
    .test_mode_i  ( test_en              ),
    .rst_no       ( ndmreset_n           ),
    .init_no      (                      ) // keep open
  );

  logic [NR_CORES-1:0][CVA6Cfg.VLEN-1:0] cluster_boot;
`ifdef G6LC_APU
  logic apu_fw_ready /*verilator public*/;
  axi_pkg::xbar_rule_64_t apu_guest_rule, apu_ctrl_rule, apu_ram_rule;
  axi_pkg::xbar_rule_64_t apu_dram_lo_rule, apu_dram_hi_rule;
`endif
`ifdef G6LC_HAVE_LITEDRAM
  wire core_rst_n = ndmreset_n & ~preload_hold
`ifdef G6LC_APU
      & apu_fw_ready
`endif
      ;
  function void g6lc_tb_preload_hold(input int unsigned on);
    preload_hold = (on != 32'd0);
  endfunction
  export "DPI-C" function g6lc_tb_preload_hold;
`else
  wire core_rst_n = ndmreset_n
`ifdef G6LC_APU
      & apu_fw_ready
`endif
      ;
`endif

  // ---------------
  // Debug
  // ---------------
  assign init_done = rst_ni;

  logic debug_enable;
  initial begin
    if (!$value$plusargs("jtag_rbb_enable=%b", jtag_enable)) jtag_enable = 'h0;
    if ($test$plusargs("debug_disable")) debug_enable = 'h0; else debug_enable = 'h1;
    if (!CVA6Cfg.IS_XLEN32 & !CVA6Cfg.IS_XLEN64) $error("CVA6Cfg.XLEN different from 32 and 64");
  end

  // debug if MUX
  assign debug_req_valid     = (jtag_enable[0]) ? jtag_req_valid     : dmi_req_valid;
  assign debug_resp_ready    = (jtag_enable[0]) ? jtag_resp_ready    : dmi_resp_ready;
  assign debug_req           = (jtag_enable[0]) ? jtag_dmi_req       : dmi_req;
  if (ariane_pkg::RVFI) begin
    assign exit_o              = (jtag_enable[0]) ? jtag_exit          : rvfi_exit;
  end else begin
    assign exit_o              = (jtag_enable[0]) ? jtag_exit          : dmi_exit;
  end
  assign jtag_resp_valid     = (jtag_enable[0]) ? debug_resp_valid   : 1'b0;
  assign dmi_resp_valid      = (jtag_enable[0]) ? 1'b0               : debug_resp_valid;

  // SiFive's SimJTAG Module
  // Converts to DPI calls
  SimJTAG i_SimJTAG (
    .clock                ( clk_i                ),
    .reset                ( ~rst_ni              ),
    .enable               ( jtag_enable[0]       ),
    .init_done            ( init_done            ),
    .jtag_TCK             ( jtag_TCK             ),
    .jtag_TMS             ( jtag_TMS             ),
    .jtag_TDI             ( jtag_TDI             ),
    .jtag_TRSTn           ( jtag_TRSTn           ),
    .jtag_TDO_data        ( jtag_TDO_data        ),
    .jtag_TDO_driven      ( jtag_TDO_driven      ),
    .exit                 ( jtag_exit            )
  );

  dmi_jtag i_dmi_jtag (
    .clk_i            ( clk_i           ),
    .rst_ni           ( rst_ni          ),
    .testmode_i       ( test_en         ),
    .dmi_req_o        ( jtag_dmi_req    ),
    .dmi_req_valid_o  ( jtag_req_valid  ),
    .dmi_req_ready_i  ( debug_req_ready ),
    .dmi_resp_i       ( debug_resp      ),
    .dmi_resp_ready_o ( jtag_resp_ready ),
    .dmi_resp_valid_i ( jtag_resp_valid ),
    .dmi_rst_no       (                 ), // not connected
    .tck_i            ( jtag_TCK        ),
    .tms_i            ( jtag_TMS        ),
    .trst_ni          ( jtag_TRSTn      ),
    .td_i             ( jtag_TDI        ),
    .td_o             ( jtag_TDO_data   ),
    .tdo_oe_o         ( jtag_TDO_driven )
  );

  // SiFive's SimDTM Module
  // Converts to DPI calls
  logic [1:0] debug_req_bits_op;
  assign dmi_req.op = dm::dtm_op_e'(debug_req_bits_op);

  if (InclSimDTM) begin
    SimDTM i_SimDTM (
      .clk                  ( clk_i                 ),
      .reset                ( ~rst_ni               ),
      .debug_req_valid      ( dmi_req_valid         ),
      .debug_req_ready      ( debug_req_ready       ),
      .debug_req_bits_addr  ( dmi_req.addr          ),
      .debug_req_bits_op    ( debug_req_bits_op     ),
      .debug_req_bits_data  ( dmi_req.data          ),
      .debug_resp_valid     ( dmi_resp_valid        ),
      .debug_resp_ready     ( dmi_resp_ready        ),
      .debug_resp_bits_resp ( debug_resp.resp       ),
      .debug_resp_bits_data ( debug_resp.data       ),
      .exit                 ( dmi_exit              )
    );
  end else begin
    assign dmi_req_valid = '0;
    assign debug_req_bits_op = '0;
    assign dmi_exit = 1'b0;
  end

  // this delay window allows the core to read and execute init code
  // from the bootrom before the first debug request can interrupt
  // core. this is needed in cases where an fsbl is involved that
  // expects a0 and a1 to be initialized with the hart id and a
  // pointer to the dev tree, respectively.
  localparam int unsigned DmiDelCycles = 500;

  logic debug_req_core_ungtd;
  int dmi_del_cnt_d, dmi_del_cnt_q;

  assign dmi_del_cnt_d  = (dmi_del_cnt_q) ? dmi_del_cnt_q - 1 : 0;
  assign debug_req_core = (dmi_del_cnt_q) ? 1'b0 :
                          (!debug_enable) ? 1'b0 : debug_req_core_ungtd;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_dmi_del_cnt
    if(!rst_ni) begin
      dmi_del_cnt_q <= DmiDelCycles;
    end else begin
      dmi_del_cnt_q <= dmi_del_cnt_d;
    end
  end

  ariane_axi::req_t    dm_axi_m_req;
  ariane_axi::resp_t   dm_axi_m_resp;

  logic                dm_slave_req;
  logic                dm_slave_we;
  logic [64-1:0]       dm_slave_addr;
  logic [64/8-1:0]     dm_slave_be;
  logic [64-1:0]       dm_slave_wdata;
  logic [64-1:0]       dm_slave_rdata;

  logic                dm_master_req;
  logic [64-1:0]       dm_master_add;
  logic                dm_master_we;
  logic [64-1:0]       dm_master_wdata;
  logic [64/8-1:0]     dm_master_be;
  logic                dm_master_gnt;
  logic                dm_master_r_valid;
  logic [64-1:0]       dm_master_r_rdata;

  // debug module
  dm_top #(
    .NrHarts              ( 1                           ),
    .BusWidth             ( AXI_DATA_WIDTH              ),
    .SelectableHarts      ( 1'b1                        )
  ) i_dm_top (
    .clk_i                ( clk_i                       ),
    .rst_ni               ( rst_ni                      ), // PoR
    .testmode_i           ( test_en                     ),
    .ndmreset_o           ( ndmreset                    ),
    .dmactive_o           (                             ), // active debug session
    .debug_req_o          ( debug_req_core_ungtd        ),
    .unavailable_i        ( '0                          ),
    .hartinfo_i           ( {ariane_pkg::DebugHartInfo} ),
    .slave_req_i          ( dm_slave_req                ),
    .slave_we_i           ( dm_slave_we                 ),
    .slave_addr_i         ( dm_slave_addr               ),
    .slave_be_i           ( dm_slave_be                 ),
    .slave_wdata_i        ( dm_slave_wdata              ),
    .slave_rdata_o        ( dm_slave_rdata              ),
    .master_req_o         ( dm_master_req               ),
    .master_add_o         ( dm_master_add               ),
    .master_we_o          ( dm_master_we                ),
    .master_wdata_o       ( dm_master_wdata             ),
    .master_be_o          ( dm_master_be                ),
    .master_gnt_i         ( dm_master_gnt               ),
    .master_r_valid_i     ( dm_master_r_valid           ),
    .master_r_rdata_i     ( dm_master_r_rdata           ),
    .dmi_rst_ni           ( rst_ni                      ),
    .dmi_req_valid_i      ( debug_req_valid             ),
    .dmi_req_ready_o      ( debug_req_ready             ),
    .dmi_req_i            ( debug_req                   ),
    .dmi_resp_valid_o     ( debug_resp_valid            ),
    .dmi_resp_ready_i     ( debug_resp_ready            ),
    .dmi_resp_o           ( debug_resp                  )
  );


  axi2mem #(
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) i_dm_axi2mem (
    .clk_i      ( clk_i                     ),
    .rst_ni     ( rst_ni                    ),
    .slave      ( master[ariane_soc::Debug] ),
    .req_o      ( dm_slave_req              ),
    .we_o       ( dm_slave_we               ),
    .addr_o     ( dm_slave_addr             ),
    .be_o       ( dm_slave_be               ),
    .user_o     (                           ),
    .data_o     ( dm_slave_wdata            ),
    .user_i     ( '0                        ),
    .data_i     ( dm_slave_rdata            )
  );

  `AXI_ASSIGN_FROM_REQ(slave[1], dm_axi_m_req)
  `AXI_ASSIGN_TO_RESP(dm_axi_m_resp, slave[1])

  axi_adapter #(
    .CVA6Cfg               ( CVA6Cfg                   ),
    .DATA_WIDTH            ( AXI_DATA_WIDTH            ),
    .axi_req_t             ( ariane_axi::req_t         ),
    .axi_rsp_t             ( ariane_axi::resp_t        )
  ) i_dm_axi_master (
    .clk_i                 ( clk_i                     ),
    .rst_ni                ( rst_ni                    ),
    .req_i                 ( dm_master_req             ),
    .type_i                ( ariane_pkg::SINGLE_REQ    ),
    .amo_i                 ( ariane_pkg::AMO_NONE      ),
    .gnt_o                 ( dm_master_gnt             ),
    .addr_i                ( dm_master_add             ),
    .we_i                  ( dm_master_we              ),
    .wdata_i               ( dm_master_wdata           ),
    .be_i                  ( dm_master_be              ),
    .size_i                ( 2'b11                     ), // always do 64bit here and use byte enables to gate
    .id_i                  ( '0                        ),
    .valid_o               ( dm_master_r_valid         ),
    .rdata_o               ( dm_master_r_rdata         ),
    .id_o                  (                           ),
    .critical_word_o       (                           ),
    .critical_word_valid_o (                           ),
    .axi_req_o             ( dm_axi_m_req              ),
    .axi_resp_i            ( dm_axi_m_resp             )
  );


  // ---------------
  // ROM
  // ---------------
  logic                         rom_req;
  logic [AXI_ADDRESS_WIDTH-1:0] rom_addr;
  logic [AXI_DATA_WIDTH-1:0]    rom_rdata;

  axi2mem #(
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) i_axi2rom (
    .clk_i  ( clk_i                   ),
    .rst_ni ( ndmreset_n              ),
    .slave  ( master[ariane_soc::ROM] ),
    .req_o  ( rom_req                 ),
    .we_o   (                         ),
    .addr_o ( rom_addr                ),
    .be_o   (                         ),
    .user_o (                         ),
    .data_o (                         ),
    .user_i ( '0                      ),
    .data_i ( rom_rdata               )
  );

  bootrom i_bootrom (
    .clk_i      ( clk_i     ),
    .req_i      ( rom_req   ),
    .addr_i     ( rom_addr  ),
    .rdata_o    ( rom_rdata )
  );

  // ------------------------------
  // GPIO window (0x4000_0000) / AI island MMIO
  // ------------------------------
  // Module-scope sideband between cluster core0 and island (always present;
  // idle when MatrixEn=0).
  logic        ai_sb_enq;
  logic [7:0]  ai_sb_qid;
  logic [31:0] ai_sb_ticket;
  logic [CVA6Cfg.XLEN-1:0] ai_sb_desc_ptr;
  logic [31:0] ai_isl_last_ticket;
  logic [15:0] ai_isl_last_status;
  logic        ai_isl_has_completion;
  logic        ai_irq;
  logic        apu_irq;
`ifndef G6LC_APU
  assign apu_irq = 1'b0;
`endif

  if (CVA6Cfg.AiCfg.MatrixEn) begin : gen_ai_island
    logic         ai_penable, ai_pwrite, ai_psel, ai_pready, ai_pslverr;
    logic [31:0]  ai_paddr, ai_pwdata, ai_prdata;

    axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH ( AXI_ADDRESS_WIDTH            ),
        .AXI4_RDATA_WIDTH   ( AXI_DATA_WIDTH               ),
        .AXI4_WDATA_WIDTH   ( AXI_DATA_WIDTH               ),
        .AXI4_ID_WIDTH      ( ariane_axi_soc::IdWidthSlave ),
        .AXI4_USER_WIDTH    ( AXI_USER_WIDTH               ),
        .BUFF_DEPTH_SLAVE   ( 2                            ),
        .APB_ADDR_WIDTH     ( 32                           )
    ) i_axi2apb_ai_island (
        .ACLK      ( clk_i                          ),
        .ARESETn   ( ndmreset_n                     ),
        .test_en_i ( test_en                        ),
        .AWID_i    ( master[ariane_soc::GPIO].aw_id     ),
        .AWADDR_i  ( master[ariane_soc::GPIO].aw_addr   ),
        .AWLEN_i   ( master[ariane_soc::GPIO].aw_len    ),
        .AWSIZE_i  ( master[ariane_soc::GPIO].aw_size   ),
        .AWBURST_i ( master[ariane_soc::GPIO].aw_burst  ),
        .AWLOCK_i  ( master[ariane_soc::GPIO].aw_lock   ),
        .AWCACHE_i ( master[ariane_soc::GPIO].aw_cache  ),
        .AWPROT_i  ( master[ariane_soc::GPIO].aw_prot   ),
        .AWREGION_i( master[ariane_soc::GPIO].aw_region ),
        .AWUSER_i  ( master[ariane_soc::GPIO].aw_user   ),
        .AWQOS_i   ( master[ariane_soc::GPIO].aw_qos    ),
        .AWVALID_i ( master[ariane_soc::GPIO].aw_valid  ),
        .AWREADY_o ( master[ariane_soc::GPIO].aw_ready  ),
        .WDATA_i   ( master[ariane_soc::GPIO].w_data    ),
        .WSTRB_i   ( master[ariane_soc::GPIO].w_strb    ),
        .WLAST_i   ( master[ariane_soc::GPIO].w_last    ),
        .WUSER_i   ( master[ariane_soc::GPIO].w_user    ),
        .WVALID_i  ( master[ariane_soc::GPIO].w_valid   ),
        .WREADY_o  ( master[ariane_soc::GPIO].w_ready   ),
        .BID_o     ( master[ariane_soc::GPIO].b_id      ),
        .BRESP_o   ( master[ariane_soc::GPIO].b_resp    ),
        .BVALID_o  ( master[ariane_soc::GPIO].b_valid   ),
        .BUSER_o   ( master[ariane_soc::GPIO].b_user    ),
        .BREADY_i  ( master[ariane_soc::GPIO].b_ready   ),
        .ARID_i    ( master[ariane_soc::GPIO].ar_id     ),
        .ARADDR_i  ( master[ariane_soc::GPIO].ar_addr   ),
        .ARLEN_i   ( master[ariane_soc::GPIO].ar_len    ),
        .ARSIZE_i  ( master[ariane_soc::GPIO].ar_size   ),
        .ARBURST_i ( master[ariane_soc::GPIO].ar_burst  ),
        .ARLOCK_i  ( master[ariane_soc::GPIO].ar_lock   ),
        .ARCACHE_i ( master[ariane_soc::GPIO].ar_cache  ),
        .ARPROT_i  ( master[ariane_soc::GPIO].ar_prot   ),
        .ARREGION_i( master[ariane_soc::GPIO].ar_region ),
        .ARUSER_i  ( master[ariane_soc::GPIO].ar_user   ),
        .ARQOS_i   ( master[ariane_soc::GPIO].ar_qos    ),
        .ARVALID_i ( master[ariane_soc::GPIO].ar_valid  ),
        .ARREADY_o ( master[ariane_soc::GPIO].ar_ready  ),
        .RID_o     ( master[ariane_soc::GPIO].r_id      ),
        .RDATA_o   ( master[ariane_soc::GPIO].r_data    ),
        .RRESP_o   ( master[ariane_soc::GPIO].r_resp    ),
        .RLAST_o   ( master[ariane_soc::GPIO].r_last    ),
        .RUSER_o   ( master[ariane_soc::GPIO].r_user    ),
        .RVALID_o  ( master[ariane_soc::GPIO].r_valid   ),
        .RREADY_i  ( master[ariane_soc::GPIO].r_ready   ),
        .PENABLE   ( ai_penable ),
        .PWRITE    ( ai_pwrite  ),
        .PADDR     ( ai_paddr   ),
        .PSEL      ( ai_psel    ),
        .PWDATA    ( ai_pwdata  ),
        .PRDATA    ( ai_prdata  ),
        .PREADY    ( ai_pready  ),
        .PSLVERR   ( ai_pslverr )
    );

    g6lc_ai_island_apb #(
        .IslandCfg      ( AiIslandCfg ),
        .EnableDmaFetch ( 1'b1 ),
        .AxiDataWidth   ( AXI_DATA_WIDTH ),
        .AxiIdWidth     ( ariane_axi_soc::IdWidth ),
        .axi_req_t      ( ariane_axi::req_t ),
        .axi_resp_t     ( ariane_axi::resp_t ),
        // `+define+G6LC_AI_TB_OVERGRANT` advertises BF16 the PE cannot execute, so the
        // grant-subset-of-datapath guard in g6lc_ai_island_top can be shown to FIRE. Kept
        // here rather than as an `ifdef` inside the config package: two conditional
        // declarations of one localparam make the value unreadable to anything that parses
        // the package without evaluating macros, and the emulator's capability ingest is
        // exactly such a reader. The package states one design; the testbench overrides.
`ifdef G6LC_AI_TB_OVERGRANT
        .DtypeMask      ( g6lc_ai_island_cfg_pkg::AiIslandDtypeMaskOvergrant )
`else
        .DtypeMask      ( g6lc_ai_island_cfg_pkg::AiIslandDtypeMask )
`endif
    ) i_ai_island (
        .clk_i     ( clk_i      ),
        .rst_ni    ( core_rst_n ),
        .testmode_i( test_en    ),
        .psel_i    ( ai_psel    ),
        .penable_i ( ai_penable ),
        .pwrite_i  ( ai_pwrite  ),
        .paddr_i   ( ai_paddr   ),
        .pwdata_i  ( ai_pwdata  ),
        .prdata_o  ( ai_prdata  ),
        .pready_o  ( ai_pready  ),
        .pslverr_o ( ai_pslverr ),
        .irq_o     ( ai_irq     ),
        .sb_enq_valid_i      ( ai_sb_enq              ),
        .sb_qid_i            ( ai_sb_qid              ),
        .sb_ticket_i         ( ai_sb_ticket           ),
        .sb_desc_ptr_i       ( ai_sb_desc_ptr         ),
        .sb_last_ticket_o    ( ai_isl_last_ticket     ),
        .sb_last_status_o    ( ai_isl_last_status     ),
        .sb_has_completion_o ( ai_isl_has_completion  ),
        .axi_dma_req_o       ( ai_dma_req             ),
        .axi_dma_resp_i      ( ai_dma_resp            ),
        .dram_init_done_i    ( dram_init_done         ),
        .ch_r_beats_i        ( dram_ch_r_beats        ),
        .ch_w_beats_i        ( dram_ch_w_beats        )
    );
  end else begin : gen_gpio_err
    assign ai_irq = 1'b0;
    assign ai_isl_last_ticket = '0;
    assign ai_isl_last_status = '0;
    assign ai_dma_req = '0;
    assign ai_isl_has_completion = 1'b0;
    ariane_axi_soc::req_slv_t  gpio_req;
    ariane_axi_soc::resp_slv_t gpio_resp;
    `AXI_ASSIGN_TO_REQ(gpio_req, master[ariane_soc::GPIO])
    `AXI_ASSIGN_FROM_RESP(master[ariane_soc::GPIO], gpio_resp)
    axi_err_slv #(
      .AxiIdWidth ( ariane_axi_soc::IdWidthSlave ),
      .req_t      ( ariane_axi_soc::req_slv_t    ),
      .resp_t     ( ariane_axi_soc::resp_slv_t   )
    ) i_gpio_err_slv (
      .clk_i      ( clk_i      ),
      .rst_ni     ( ndmreset_n ),
      .test_i     ( test_en    ),
      .slv_req_i  ( gpio_req   ),
      .slv_resp_o ( gpio_resp  )
    );
  end


  // ------------------------------
  // Memory + Exclusive Access
  // ------------------------------
  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) dram();

  // Exclusive-monitor outstanding. Live cookie keeps pulp axi_riscv_atomics_wrap
  // (1 AR + 1 AW). S4/CLASS1/SIM_CHANS uses g6lc_axi_atomics_wrap so HPDCACHE
  // split-ID LDEX/STEX still match (address-only); LR/SC still snoops stores.
  // Instance name stays i_axi_riscv_atomics (TB probes).
  localparam int unsigned DRAM_AW_OUT =
      g6lc_ai_island_cfg_pkg::dram_aw_out(AiIslandCfg);

`ifdef G6LC_AI_DRAM_TIMING
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_CLASS1
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_CHANS_2
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_CHANS_4
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_CHANS_8
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_2
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_4
  `define G6LC_AI_EXCL_MULTI
`endif
`ifdef G6LC_AI_DRAM_SIM_CHANS_8
  `define G6LC_AI_EXCL_MULTI
`endif

`ifdef G6LC_AI_EXCL_MULTI
  // SIM_CHANS keeps island MaxAROut=2 so dram_aw_out=1 (cookie identity).
  // g6lc wrap + AMOS deadlock an AMO at 1 write slot; S4/CLASS1 already
  // pass 8. Do not change cookie pulp DRAM_AW_OUT.
  localparam int unsigned DRAM_EXCL_AW =
      (DRAM_AW_OUT < unsigned'(2)) ? unsigned'(8) : DRAM_AW_OUT;
  g6lc_axi_atomics_wrap #(
    .AXI_ADDR_WIDTH     ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH     ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH       ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH     ( AXI_USER_WIDTH               ),
    .AXI_MAX_WRITE_TXNS ( DRAM_EXCL_AW ),
    .RISCV_WORD_WIDTH   ( 64 ),
    // One reservation per software hart. A single global reservation livelocks
    // two harts contending on *different* addresses (g6lc_axi_lrsc header), so
    // this is sized from the SoC's own hart count rather than left at a
    // default. NR_HARTS = NR_CORES x NrHarts.
    //
    // `+define+G6LC_AI_LRSC_SINGLE_RES` forces the pre-fix depth of 1. It
    // exists so the disjoint LR/SC gate can be shown to FAIL on the old
    // behaviour: a test that has never failed is not an oracle, and the
    // same-address snoop gate cannot distinguish the two designs. Keep it --
    // rediscovering this negative costs a full harness rebuild.
`ifdef G6LC_AI_LRSC_SINGLE_RES
    .NRes               ( 1 )
`else
    .NRes               ( (NR_HARTS < 1) ? 1 : NR_HARTS )
`endif
  ) i_axi_riscv_atomics (
    .clk_i,
    .rst_ni ( ndmreset_n               ),
    .slv    ( master[ariane_soc::DRAM] ),
    .mst    ( dram                     )
  );
`else
  axi_riscv_atomics_wrap #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               ),
    .AXI_MAX_WRITE_TXNS ( DRAM_AW_OUT ),
    .RISCV_WORD_WIDTH   ( 64 )
  ) i_axi_riscv_atomics (
    .clk_i,
    .rst_ni ( ndmreset_n               ),
    .slv    ( master[ariane_soc::DRAM] ),
    .mst    ( dram                     )
  );
`endif

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) dram_delayed();

  axi_delayer_intf #(
    .AXI_ID_WIDTH        ( ariane_axi_soc::IdWidthSlave ),
    .AXI_ADDR_WIDTH      ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH      ( AXI_DATA_WIDTH               ),
    .AXI_USER_WIDTH      ( AXI_USER_WIDTH               ),
    .STALL_RANDOM_INPUT  ( StallRandomInput             ),
    .STALL_RANDOM_OUTPUT ( StallRandomOutput            ),
    .FIXED_DELAY_INPUT   ( 0                            ),
    .FIXED_DELAY_OUTPUT  ( 0                            )
  ) i_axi_delayer (
    .clk_i  ( clk_i        ),
    .rst_ni ( ndmreset_n   ),
    .slv    ( dram         ),
    .mst    ( dram_delayed )
  );

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               )
  ) dram_lat();

  // Memory-latency instrument (see module header): the delayer's stream_delay
  // is single-slot per-handshake and its counter truncates at 4 bits, so it
  // could not model access latency. DramLatency==0 is a pure-wire bypass.
  g6lc_tb_dram_latency #(
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH               ),
    .Latency        ( DramLatency                  ),
    .Depth          ( 32                           )
  ) i_dram_latency (
    .clk_i  ( clk_i        ),
    .rst_ni ( ndmreset_n   ),
    .slv    ( dram_delayed ),
    .mst    ( dram_lat     )
  );

  // SoC DRAM slave. Class/channels/shift come from AiIslandCfg (same as the
  // island APB). Class 1 is +define+G6LC_AI_DRAM_CLASS1+G6LC_HAVE_LITEDRAM.
  g6lc_ai_dram_backend #(
    .DramClass      ( AiIslandCfg.DramClass            ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave     ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH                ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH                   ),
    .AXI_USER_WIDTH ( AXI_USER_WIDTH                   ),
    .AXI_USER_EN    ( AXI_USER_EN                      ),
    .NUM_WORDS      ( NUM_WORDS                        ),
    .NrChannels     ( AiIslandCfg.DramChannels         ),
    .ChanShift      ( AiIslandCfg.DramChanShift        ),
    .MaxAROut       ( AiIslandCfg.MaxAROut             )
  ) i_dram_backend (
    .clk_i      ( clk_i        ),
    .rst_ni     ( ndmreset_n   ),
    .rst_sram_ni( rst_ni       ),
    .testmode_i ( test_en      ),
    .slave      ( dram_lat     ),
    .init_done_o( dram_init_done ),
    .ch_r_beats_o ( dram_ch_r_beats ),
    .ch_w_beats_o ( dram_ch_w_beats )
  );

  // Remote v5.008 cannot look up CVA6Cfg.DcacheLineWidth (struct member
  // missing on the elaborated parameter). Use the target package constants.
  localparam int unsigned L1D_LINE_B = cva6_config_pkg::CVA6ConfigDcacheLineWidth / 8;
  localparam int unsigned L1I_LINE_B = cva6_config_pkg::CVA6ConfigIcacheLineWidth / 8;
  localparam int unsigned L2_LINE_B  = unsigned'(64);

  // pragma translate_off
  // Core pipelines (I$/D$/L2) share this slave. A line fill must not straddle
  // a stripe or axi_demux will park the whole burst on the first channel.
  initial begin
    automatic int unsigned nch, shift, stripe, l2b, l1d, l1i;
    nch   = AiIslandCfg.DramChannels;
    shift = AiIslandCfg.DramChanShift;
    if (nch > 1) begin
      stripe = unsigned'(1) << shift;
      l2b = L2_LINE_B;
      l1d = L1D_LINE_B;
      l1i = L1I_LINE_B;
      if (l2b > stripe)
        $error("ariane_testharness: L2 line %0d B exceeds DRAM stripe %0d B", l2b, stripe);
      if (l1d > stripe)
        $error("ariane_testharness: D$ line %0d B exceeds DRAM stripe %0d B", l1d, stripe);
      if (l1i > stripe)
        $error("ariane_testharness: I$ line %0d B exceeds DRAM stripe %0d B", l1i, stripe);
    end
  end
  // pragma translate_on

  // ---------------
  // AXI Xbar
  // ---------------

  axi_pkg::xbar_rule_64_t [NB_RULES-1:0] addr_map;

`ifdef G6LC_APU
  // OpenSBI-visible testharness map. Split DRAM around firmware RAM.
  // addr_decode last-match-wins: a full DRAM rule at a higher array index
  // than the RAM rule aliases 0x90000000. Locked by tb_g6lc_apu_th_osbi
  // and software/apu-fw/test/osbi_check.c. Not an OpenSBI firmware boot.
  assign addr_map = '{
    '{ idx: ariane_soc::Debug,    start_addr: ariane_soc::DebugBase,    end_addr: ariane_soc::DebugBase + ariane_soc::DebugLength       },
    '{ idx: ariane_soc::ROM,      start_addr: ariane_soc::ROMBase,      end_addr: ariane_soc::ROMBase + ariane_soc::ROMLength           },
    '{ idx: ariane_soc::CLINT,    start_addr: ariane_soc::CLINTBase,    end_addr: ariane_soc::CLINTBase + ariane_soc::CLINTLength       },
    '{ idx: ariane_soc::PLIC,     start_addr: ariane_soc::PLICBase,     end_addr: ariane_soc::PLICBase + ariane_soc::PLICLength         },
    '{ idx: ariane_soc::UART,     start_addr: ariane_soc::UARTBase,     end_addr: ariane_soc::UARTBase + ariane_soc::UARTLength         },
    '{ idx: ariane_soc::Timer,    start_addr: ariane_soc::TimerBase,    end_addr: ariane_soc::TimerBase + ariane_soc::TimerLength       },
    '{ idx: ariane_soc::SPI,      start_addr: ariane_soc::SPIBase,      end_addr: ariane_soc::SPIBase + ariane_soc::SPILength           },
    '{ idx: ariane_soc::Ethernet, start_addr: ariane_soc::EthernetBase, end_addr: ariane_soc::EthernetBase + ariane_soc::EthernetLength },
    '{ idx: ariane_soc::GPIO,     start_addr: ariane_soc::GPIOBase,     end_addr: ariane_soc::GPIOBase + ariane_soc::GPIOLength         },
    apu_dram_lo_rule,
    apu_guest_rule,
    apu_ctrl_rule,
    apu_ram_rule,
    apu_dram_hi_rule
  };
`else
  assign addr_map = '{
    '{ idx: ariane_soc::Debug,    start_addr: ariane_soc::DebugBase,    end_addr: ariane_soc::DebugBase + ariane_soc::DebugLength       },
    '{ idx: ariane_soc::ROM,      start_addr: ariane_soc::ROMBase,      end_addr: ariane_soc::ROMBase + ariane_soc::ROMLength           },
    '{ idx: ariane_soc::CLINT,    start_addr: ariane_soc::CLINTBase,    end_addr: ariane_soc::CLINTBase + ariane_soc::CLINTLength       },
    '{ idx: ariane_soc::PLIC,     start_addr: ariane_soc::PLICBase,     end_addr: ariane_soc::PLICBase + ariane_soc::PLICLength         },
    '{ idx: ariane_soc::UART,     start_addr: ariane_soc::UARTBase,     end_addr: ariane_soc::UARTBase + ariane_soc::UARTLength         },
    '{ idx: ariane_soc::Timer,    start_addr: ariane_soc::TimerBase,    end_addr: ariane_soc::TimerBase + ariane_soc::TimerLength       },
    '{ idx: ariane_soc::SPI,      start_addr: ariane_soc::SPIBase,      end_addr: ariane_soc::SPIBase + ariane_soc::SPILength           },
    '{ idx: ariane_soc::Ethernet, start_addr: ariane_soc::EthernetBase, end_addr: ariane_soc::EthernetBase + ariane_soc::EthernetLength },
    '{ idx: ariane_soc::GPIO,     start_addr: ariane_soc::GPIOBase,     end_addr: ariane_soc::GPIOBase + ariane_soc::GPIOLength         },
    '{ idx: ariane_soc::DRAM,     start_addr: ariane_soc::DRAMBase,     end_addr: ariane_soc::DRAMBase + ariane_soc::DRAMLength         }
  };
`endif

  // Multi-core + L2 miss-fill needs multi-outstanding on the xbar demux.
  // Max*=1 (legacy single-core) silently stalls AR when an ID is still
  // occupied on another master port or the ID counter is full — seen as L2
  // stuck in S_MISS_AR with axi2mem IDLE and demux ar_valid=0 (OpenSBI hang
  // at 0x80000080). Match hub OT depth (4) with headroom for L2 line fills.
  localparam axi_pkg::xbar_cfg_t AXI_XBAR_CFG = '{
    NoSlvPorts: unsigned'(ariane_soc::NrSlaves),
    NoMstPorts: unsigned'(NB_MST),
    MaxMstTrans: unsigned'(8),
    MaxSlvTrans: unsigned'(8),
    FallThrough: 1'b0,
    LatencyMode: axi_pkg::NO_LATENCY,
    AxiIdWidthSlvPorts: unsigned'(ariane_axi_soc::IdWidth),
    AxiIdUsedSlvPorts: unsigned'(ariane_axi_soc::IdWidth),
    UniqueIds: 1'b0,
    AxiAddrWidth: unsigned'(AXI_ADDRESS_WIDTH),
    AxiDataWidth: unsigned'(AXI_DATA_WIDTH),
    NoAddrRules: unsigned'(NB_RULES)
  };

  axi_xbar_intf #(
    .AXI_USER_WIDTH ( AXI_USER_WIDTH          ),
    .Cfg            ( AXI_XBAR_CFG            ),
    .rule_t         ( axi_pkg::xbar_rule_64_t )
  ) i_axi_xbar (
    .clk_i                 ( clk_i      ),
    .rst_ni                ( ndmreset_n ),
    .test_i                ( test_en    ),
    .slv_ports             ( slave      ),
    .mst_ports             ( master     ),
    .addr_map_i            ( addr_map   ),
    .en_default_mst_port_i ( '0         ),
    .default_mst_port_i    ( '0         )
  );

`ifdef G6LC_APU
  // Opt-in APU load compositor: guest/control + firmware RAM + DRAM hole +
  // hart-1 boot PC. Testharness only stitches xbar masters. DMA stays idle.
  // Hart pins come from the xbar port index in the upper ID bits.
  // Port 0 is the cluster. The per-core guard has already kept every
  // other hart out of these windows, so that port is the firmware hart.
  // Debug and DMA ports are hart 0. The low ID bits are the master's own
  // id, not a hart. AXI PROT is not an input.
  ariane_axi_soc::req_slv_t  apu_guest_req, apu_ctrl_req, apu_ram_req;
  ariane_axi_soc::resp_slv_t apu_guest_rsp, apu_ctrl_rsp, apu_ram_rsp;
  logic [ariane_soc::NumSources-1:0] apu_irq_vec_in, apu_irq_vec_out;
  `AXI_ASSIGN_TO_REQ(apu_guest_req, master[APU_GUEST_IDX])
  `AXI_ASSIGN_FROM_RESP(master[APU_GUEST_IDX], apu_guest_rsp)
  `AXI_ASSIGN_TO_REQ(apu_ctrl_req, master[APU_CTRL_IDX])
  `AXI_ASSIGN_FROM_RESP(master[APU_CTRL_IDX], apu_ctrl_rsp)
  `AXI_ASSIGN_TO_REQ(apu_ram_req, master[APU_RAM_IDX])
  `AXI_ASSIGN_FROM_RESP(master[APU_RAM_IDX], apu_ram_rsp)
  assign apu_irq_vec_in = '0;
  logic [31:0] apu_ram_aw_hart, apu_ram_ar_hart;
  logic [31:0] apu_ctrl_aw_hart, apu_ctrl_ar_hart;
  g6lc_apu_xbar_hart #(
      .IdxW($clog2(ariane_soc::NrSlaves)),
      .IdW(ariane_axi_soc::IdWidthSlave),
      .FwHart(32'(g6lc_apu_cfg_pkg::ApuHarness.FirmwareHart)),
      .ClusterPort(0)
  ) i_ram_hart (
      .aw_id_i(apu_ram_req.aw.id),
      .ar_id_i(apu_ram_req.ar.id),
      .aw_hart_o(apu_ram_aw_hart),
      .ar_hart_o(apu_ram_ar_hart)
  );
  g6lc_apu_xbar_hart #(
      .IdxW($clog2(ariane_soc::NrSlaves)),
      .IdW(ariane_axi_soc::IdWidthSlave),
      .FwHart(32'(g6lc_apu_cfg_pkg::ApuHarness.FirmwareHart)),
      .ClusterPort(0)
  ) i_ctrl_hart (
      .aw_id_i(apu_ctrl_req.aw.id),
      .ar_id_i(apu_ctrl_req.ar.id),
      .aw_hart_o(apu_ctrl_aw_hart),
      .ar_hart_o(apu_ctrl_ar_hart)
  );
  g6lc_apu_th_load #(
    .ApuCfg(g6lc_apu_cfg_pkg::ApuHarness),
    .CoreCfg(CVA6Cfg),
    .AppBoot(ariane_soc::ROMBase),
    .DramBase(ariane_soc::DRAMBase),
    .DramBytes(ariane_soc::DRAMLength),
    .GuestIdx(APU_GUEST_IDX),
    .CtrlIdx(APU_CTRL_IDX),
    .RamIdx(APU_RAM_IDX),
    .DramIdx(ariane_soc::DRAM),
    .NumCores(NR_CORES),
    .Vlen(CVA6Cfg.VLEN),
    .HexFile("apu_fw.hex"),
    .NumSources(ariane_soc::NumSources),
    .axi4_req_t(ariane_axi_soc::req_slv_t),
    .axi4_rsp_t(ariane_axi_soc::resp_slv_t)
  ) i_apu_load (
    .clk_i, .rst_ni(ndmreset_n), .testmode_i(test_en),
    .guest_req_i(apu_guest_req), .guest_rsp_o(apu_guest_rsp),
    .control_req_i(apu_ctrl_req), .control_rsp_o(apu_ctrl_rsp),
    .ram_req_i(apu_ram_req), .ram_rsp_o(apu_ram_rsp),
    .control_aw_hart_i(apu_ctrl_aw_hart),
    .control_ar_hart_i(apu_ctrl_ar_hart),
    .ram_aw_hart_i(apu_ram_aw_hart),
    .ram_ar_hart_i(apu_ram_ar_hart),
    .irq_sources_i(apu_irq_vec_in), .irq_sources_o(apu_irq_vec_out),
    .plic_irq_o(apu_irq), .fw_ready_o(apu_fw_ready),
    .boot_addr_core_o(cluster_boot),
    .guest_rule_o(apu_guest_rule), .control_rule_o(apu_ctrl_rule),
    .ram_rule_o(apu_ram_rule),
    .dram_lo_rule_o(apu_dram_lo_rule), .dram_hi_rule_o(apu_dram_hi_rule),
    .dma_req_o(), .dma_rsp_i('0),
    .ram_fault_o(apu_ram_fault)
  );
  // Pad reset, not ndmreset_n: this output gates ndmreset_n.
  g6lc_apu_fault_sup #(.Enable(1'b1)) i_apu_fault (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .fault_i(apu_ram_fault),
      .reset_o(apu_fault_reset)
  );
`endif

  // ---------------
  // CLINT (scaled to total software harts = NR_CORES × NrHarts)
  // ---------------
  logic [NR_HARTS-1:0] ipi;
  logic [NR_HARTS-1:0] timer_irq;
  logic [63:0] clint_mtime;

  ariane_axi_soc::req_slv_t  axi_clint_req;
  ariane_axi_soc::resp_slv_t axi_clint_resp;

  clint #(
    .CVA6Cfg        ( CVA6Cfg                      ),
    .AXI_ADDR_WIDTH ( AXI_ADDRESS_WIDTH            ),
    .AXI_DATA_WIDTH ( AXI_DATA_WIDTH               ),
    .AXI_ID_WIDTH   ( ariane_axi_soc::IdWidthSlave ),
    .NR_CORES       ( NR_HARTS                     ), // one MSIP/MTIMECMP per mhartid
    .axi_req_t      ( ariane_axi_soc::req_slv_t    ),
    .axi_resp_t     ( ariane_axi_soc::resp_slv_t   )
  ) i_clint (
    .clk_i       ( clk_i          ),
    .rst_ni      ( ndmreset_n     ),
    .testmode_i  ( test_en        ),
    .axi_req_i   ( axi_clint_req  ),
    .axi_resp_o  ( axi_clint_resp ),
    .rtc_i       ( rtc_i          ),
    .timer_irq_o ( timer_irq      ),
    .ipi_o       ( ipi            ),
    .mtime_o     ( clint_mtime    )
  );

  `AXI_ASSIGN_TO_REQ(axi_clint_req, master[ariane_soc::CLINT])
  `AXI_ASSIGN_FROM_RESP(master[ariane_soc::CLINT], axi_clint_resp)

  // ---------------
  // Peripherals
  // ---------------
  logic tx, rx;
  // Full PLIC target vector (2 × CVA6_MAX_CORES); fan-out slices NR_CORES below
  logic [ariane_soc::NumTargets-1:0] irqs;

  ariane_peripherals #(
    .AxiAddrWidth ( AXI_ADDRESS_WIDTH            ),
    .AxiDataWidth ( AXI_DATA_WIDTH               ),
    .AxiIdWidth   ( ariane_axi_soc::IdWidthSlave ),
    .AxiUserWidth ( AXI_USER_WIDTH               ),
`ifndef VERILATOR
    .InclUART     ( 1'b1                     ),
`else
    .InclUART     ( 1'b0                     ),
`endif
    .InclSPI      ( 1'b0                     ),
    .InclEthernet ( 1'b0                     )
  ) i_ariane_peripherals (
    .clk_i     ( clk_i                        ),
    .rst_ni    ( ndmreset_n                   ),
    .plic      ( master[ariane_soc::PLIC]     ),
    .uart      ( master[ariane_soc::UART]     ),
    .spi       ( master[ariane_soc::SPI]      ),
    .ethernet  ( master[ariane_soc::Ethernet] ),
    .timer     ( master[ariane_soc::Timer]    ),
    .irq_o     ( irqs                         ),
    .ai_irq_i  ( ai_irq                       ),
    .apu_irq_i ( apu_irq                      ),
    .rx_i      ( rx                           ),
    .tx_o      ( tx                           ),
    .eth_txck  ( ),
    .eth_rxck  ( ),
    .eth_rxctl ( ),
    .eth_rxd   ( ),
    .eth_rst_n ( ),
    .eth_tx_en ( ),
    .eth_txd   ( ),
    .phy_mdio  ( ),
    .eth_mdc   ( ),
    .mdio      ( ),
    .mdc       ( ),
    .spi_clk_o ( ),
    .spi_mosi  ( ),
    .spi_miso  ( ),
    .spi_ss    ( )
  );

  uart_bus #(.BAUD_RATE(115200), .PARITY_EN(0)) i_uart_bus (.rx(tx), .tx(rx), .rx_en(1'b1));

  // ---------------
  // Core / Cluster (U6.2)
  // ---------------
  // Shared AXI toward the SoC xbar (cluster or single core + optional L2).
  ariane_axi::req_t    axi_ariane_req;
  ariane_axi::resp_t   axi_ariane_resp;
  rvfi_probes_t rvfi_probes;
  rvfi_csr_t rvfi_csr;
  rvfi_instr_t [CVA6Cfg.NrCommitPorts-1:0]  rvfi_instr;
  rvfi_to_iti_t rvfi_to_iti;
  iti_to_encoder_t iti_to_encoder;

  // Per-core × SMT-hart IRQ: PLIC context 2*global_hart + {0=MEIP,1=SEIP}
  // CLINT slots indexed by global mhartid = core*NrHarts + local_hart
  logic [NR_CORES-1:0][NR_HARTS_PER_CORE-1:0][1:0] core_irqs;
  logic [NR_CORES-1:0][NR_HARTS_PER_CORE-1:0]      core_ipi;
  logic [NR_CORES-1:0][NR_HARTS_PER_CORE-1:0]      core_timer_irq;
  logic [NR_CORES-1:0]                             core_debug_req;

  for (genvar c = 0; c < NR_CORES; c++) begin : gen_core_irq
`ifdef SPIKE_TANDEM
    assign core_debug_req[c] = 1'b0;
`else
    assign core_debug_req[c] = (c == 0) ? debug_req_core : 1'b0;
`endif
    for (genvar h = 0; h < NR_HARTS_PER_CORE; h++) begin : gen_hart_irq
      // PLIC targets: need 2 * NR_HARTS contexts (capped by NumTargets=16)
      assign core_irqs[c][h] =
          irqs[2*(c * NR_HARTS_PER_CORE + h) +: 2];
      assign core_ipi[c][h]       = ipi[c * NR_HARTS_PER_CORE + h];
      assign core_timer_irq[c][h] = timer_irq[c * NR_HARTS_PER_CORE + h];
    end
  end

  // Observer taps for the [mc_cache] counters (sim-only use, see below).
  logic mc_l2_miss, mc_l3_hit, mc_l3_miss;

  // Always use the cluster wrapper: N=1 is identity (no hub), N>1 is coherent.
  // L2 is owned by the cluster when L2En (avoids double-instantiation).
`ifndef G6LC_APU
  always_comb begin
    for (int unsigned c = 0; c < NR_CORES; c++)
      cluster_boot[c] = ariane_soc::ROMBase[CVA6Cfg.VLEN-1:0];
  end
`endif
  g6lc_cluster #(
    .CVA6Cfg        ( CVA6Cfg             ),
    .NR_CORES       ( NR_CORES            ),
    .L2_ENABLE      ( CVA6Cfg.L2En        ),
    .IDENTITY_FAST  ( 1'b1                ),
    // Inclusive L1 (+ L2 when L3En) back-inval on LLC victim — stream plane
    // × multicore coherence for U6.2 / L3 hierarchy. The TB override is off;
    // policy comes from CVA6Cfg.L3InclusiveEn.
    .INCLUSIVE_L3   ( 1'b0                ),
`ifdef G6LC_APU
    .PerCoreBoot     ( 1'b1 ),
    .SrcGuard        ( 1'b1 ),
    .FwHart          ( 32'(g6lc_apu_cfg_pkg::ApuHarness.FirmwareHart) ),
    .GuardRamBase    ( g6lc_apu_cfg_pkg::ApuHarness.FirmwareRamBase ),
    .GuardRamBytes   ( g6lc_apu_cfg_pkg::ApuHarness.FirmwareRamBytes ),
    .GuardCtrlBase   ( g6lc_apu_cfg_pkg::ApuHarness.ControlBase ),
    .GuardCtrlBytes  ( g6lc_apu_cfg_pkg::ApuHarness.ControlLength ),
`endif
    .AXI_ADDR_WIDTH ( ariane_axi::AddrWidth ),
    .AXI_DATA_WIDTH ( ariane_axi::DataWidth ),
    .AXI_ID_WIDTH   ( ariane_axi::IdWidth   ),
    .AXI_USER_WIDTH ( ariane_axi::UserWidth ),
    .axi_req_t      ( ariane_axi::req_t   ),
    .axi_resp_t     ( ariane_axi::resp_t  ),
    .rvfi_probes_t  ( rvfi_probes_t       )
  ) i_cluster (
    .clk_i          ( clk_i               ),
    .rst_ni         ( core_rst_n          ),
    .boot_addr_i      ( ariane_soc::ROMBase[CVA6Cfg.VLEN-1:0] ),
    .boot_addr_core_i ( cluster_boot                         ),
    .irq_i          ( core_irqs           ),
    .ipi_i          ( core_ipi            ),
    .time_irq_i     ( core_timer_irq      ),
    .rtc_time_i     ( clint_mtime         ),
    .debug_req_i    ( core_debug_req      ),
    .mem_req_o      ( axi_ariane_req      ),
    .mem_resp_i     ( axi_ariane_resp     ),
    .rvfi_probes_o  ( rvfi_probes         ),
    .l2_miss_o      ( mc_l2_miss          ),
    .l3_hit_o       ( mc_l3_hit           ),
    .l3_miss_o      ( mc_l3_miss          ),
    .pf_issue_o     (                     ),
    .pf_train_o     (                     ),
    .ai_sb_enq_valid_o( ai_sb_enq         ),
    .ai_sb_qid_o      ( ai_sb_qid         ),
    .ai_sb_ticket_o   ( ai_sb_ticket      ),
    .ai_sb_desc_ptr_o ( ai_sb_desc_ptr    ),
    .ai_isl_has_completion_i( ai_isl_has_completion ),
    .ai_isl_last_ticket_i   ( ai_isl_last_ticket    ),
    .ai_isl_last_status_i   ( ai_isl_last_status    )
  );

  `AXI_ASSIGN_FROM_REQ(slave[0], axi_ariane_req)
  `AXI_ASSIGN_TO_RESP(axi_ariane_resp, slave[0])

  // -------------
  // Simulation Helper Functions
  // -------------
  // check for response errors
  // +quiet_axi skips the $warning flood (soft-ladder nat/peel I/O).
  always_ff @(posedge clk_i) begin : p_assert
    if (!$test$plusargs("quiet_axi")) begin
      if (axi_ariane_req.r_ready &&
        axi_ariane_resp.r_valid &&
        axi_ariane_resp.r.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR}) begin
        $warning("R Response Errored");
      end
      if (axi_ariane_req.b_ready &&
        axi_ariane_resp.b_valid &&
        axi_ariane_resp.b.resp inside {axi_pkg::RESP_DECERR, axi_pkg::RESP_SLVERR}) begin
        $warning("B Response Errored");
      end
    end
  end

    cva6_iti #(
        .CVA6Cfg   (CVA6Cfg),
        .CAUSE_LEN  (iti_pkg::CAUSE_LEN),
        .ITYPE_LEN (iti_pkg::ITYPE_LEN),
        .IRETIRE_LEN (iti_pkg::IRETIRE_LEN),
        .block_mode(0),
        .rvfi_to_iti_t(rvfi_to_iti_t),
        .iti_to_encoder_t(iti_to_encoder_t)
    ) i_cva6_iti (
        .clk_i  (clk_i),
        .rst_ni (ndmreset_n),
        // inputs from rvfi
        .valid_i(rvfi_to_iti.valid),
        .rvfi_to_iti_i(rvfi_to_iti),
        .valid_o(),
        .iti_to_encoder_o(iti_to_encoder)
    );

    logic                    packet_valid;
    te_pkg::it_packet_type_e [0:0] packet_type;
    logic [te_pkg::P_LEN-1:0] packet_length;
    logic [te_pkg::PAYLOAD_LEN-1:0] packet_payload;

    logic                           encap_valid;
    encap_pkg::encap_fifo_entry_s   encap_fifo_entry_i;
    encap_pkg::encap_fifo_entry_s   encap_fifo_entry_o;
    logic                           encap_fifo_full;
    logic                           encap_fifo_empty;
    logic                           encap_fifo_pop;

    rv_tracer #(
        .N(1),
        .ONLY_BRANCHES(1)
    ) i_encoder(
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .valid_i             (iti_to_encoder.valid),
        .itype_i             (iti_to_encoder.itype),
        .cause_i             (iti_to_encoder.cause),
        .tval_i              (iti_to_encoder.tval),
        .priv_i              (iti_to_encoder.priv),
        .iaddr_i             (iti_to_encoder.iaddr),
        .iretire_i           (iti_to_encoder.iretire),
        .ilastsize_i         (iti_to_encoder.ilastsize),
        .time_i              (iti_to_encoder.cycles),
        .tvec_i              ('0),
        .epc_i               ('0),
        // Backpressure when the TB encapsulator FIFO is full (dense CF streams
        // used to $stop on fifo_v3 full_write with ready hardwired to 1).
        .encapsulator_ready_i(~encap_fifo_full),
        .paddr_i             ('0),
        .pwrite_i            ('0),
        .psel_i              ('0),
        .penable_i           ('0),
        .pwdata_i            ('0),
        .packet_valid_o      (packet_valid),
        .packet_type_o       (packet_type),
        .packet_length_o     (packet_length),
        .packet_payload_o    (packet_payload),
        .stall_o             (),
        .pready_o            (),
        .prdata_o            ()
    );

    encapsulator i_encapsulator (
        .clk_i              (clk_i),
        .valid_i            (packet_valid),
        .packet_length_i    (packet_length),
        .flow_i             ('0),
        .timestamp_present_i('1),
        //.srcid_i(),
        .timestamp_i        (rvfi_to_iti.cycles),
        //.type_i(),
        .trace_payload_i    (packet_payload),
        .valid_o            (encap_valid),
        .encap_fifo_entry_o (encap_fifo_entry_i)
    );

    fifo_v3 # (
        .DEPTH(16),
        .dtype(encap_pkg::encap_fifo_entry_s)
    ) i_fifo_encap (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   ('0),
        .testmode_i('0),
        .full_o    (encap_fifo_full),
        .empty_o   (encap_fifo_empty),
        .usage_o   (),
        .data_i    (encap_fifo_entry_i),
        .push_i    (encap_valid && !encap_fifo_full),
        .data_o    (encap_fifo_entry_o),
        .pop_i     (encap_fifo_pop)
    );
    localparam DATA_LEN = 8;

    logic                           slicer_valid;
    logic [DATA_LEN-1:0]            slice;
    logic [$clog2(DATA_LEN)-4:0]    valid_bytes;

    slicer_DPTI #(
        .SLICE_LEN(DATA_LEN),
        .NO_TIME ('0)
    ) i_slicer (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .valid_i           (!encap_fifo_empty),
        .encap_fifo_entry_i(encap_fifo_entry_o),
        .fifo_full_i       ('0), // usrFull DPTI in ariane_xilinx
        .valid_o           (slicer_valid),
        .slice_o           (slice),
        .done_o            (encap_fifo_pop)
    );

  cva6_rvfi #(
      .CVA6Cfg   (CVA6Cfg),
      .rvfi_instr_t(rvfi_instr_t),
      .rvfi_csr_t(rvfi_csr_t),
      .rvfi_probes_instr_t(rvfi_probes_instr_t),
      .rvfi_probes_csr_t(rvfi_probes_csr_t),
      .rvfi_probes_t(rvfi_probes_t),
      .rvfi_to_iti_t(rvfi_to_iti_t)
  ) i_cva6_rvfi (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .rvfi_probes_i(rvfi_probes),
      .rvfi_instr_o (rvfi_instr),
      .rvfi_to_iti_o   (rvfi_to_iti),
      .rvfi_csr_o   (rvfi_csr)
  );

  rvfi_tracer  #(
    .CVA6Cfg(CVA6Cfg),
    .rvfi_instr_t(rvfi_instr_t),
    .rvfi_csr_t(rvfi_csr_t),
    //
    .HART_ID(hart_id),
    .DEBUG_START(0),
    .DEBUG_STOP(0)
  ) i_rvfi_tracer (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .rvfi_i(rvfi_instr),
    .rvfi_csr_i(rvfi_csr),
    .end_of_test_o(core_tracer_exit[0])
  );

`ifdef SPIKE_TANDEM
  assign tracer_exit = core_tracer_exit[0];
`else
  always_comb begin : mc_exit_select
    tracer_exit = '0;
    for (int unsigned c = 0; c < NR_CORES; c++) begin
      if (core_tracer_exit[c][0] &&
          (!tracer_exit[0] || ((|core_tracer_exit[c][31:1]) && !(|tracer_exit[31:1]))))
        tracer_exit = core_tracer_exit[c];
    end
  end
`endif

  //  Secondary-core trace visibility.
  //
  //  `g6lc_cluster` forwards only core 0's probes on its scalar `rvfi_probes_o`
  //  (`assign rvfi_probes_o = core_rvfi[0];`), so every trace-based check above —
  //  including the "Simulation terminated" marker the regression classifier treats
  //  as proof a run really finished — is blind to cores 1..N-1. That is how a
  //  secondary-core problem can hide indefinitely, and it is the observability
  //  requirement in AGENTS.md 0.1(6).
  //
  //  Widening that port is an RTL interface change with a wide blast radius: it is
  //  consumed by ariane.sv, the Xilinx and Altera tops, ariane_gate_tb and the APU
  //  benches, and a missing pin is an error here (%Error-PINMISSING), so every
  //  instantiation would have to change. This observer closes the visibility half
  //  with no RTL change at all, by tapping the cluster's per-core probe array
  //  hierarchically from the testbench.
  //
  //  Deliberately NOT wired to end_of_test: core 0's `tracer_exit` drives
  //  `rvfi_exit` and therefore simulation termination, so a secondary core reaching
  //  its own halt must not end the run. These tracers observe; they never terminate.
  //  Multi-core VERDICT, not just visibility.
  //
  //  The pass criterion is core 0's `tracer_exit`, so a run in which a secondary
  //  core never executed a single instruction still reported SUCCESS. That is not a
  //  hypothetical: this review spent a long stretch unable to tell "hart 1 never
  //  ran" from "hart 1 ran but the shared line was stale", precisely because no
  //  verdict covered the secondary cores.
  //
  //  So every instantiated core must retire at least one instruction by the time
  //  core 0 declares the test over. That is deliberately the weakest useful
  //  criterion: a secondary core parked in an idle loop is indistinguishable from a
  //  hung one without test-specific knowledge, so requiring progress at the end
  //  would fail legitimate tests, while requiring "it ran at all" cannot.
  //
  //  It is safe for every configuration here: the bootrom sends ALL harts to
  //  DRAM_BASE with no parking, so even a single-hart test executes the mhartid
  //  check on each core before branching. With NR_CORES == 1 the check is empty.
  //  On multi-core SMT targets the cluster additionally clock-holds secondary
  //  cores until an IPI or a bounded counter releases them; a never-retired
  //  secondary there is an expected hold (exit 125), not a hang.
  logic [NR_CORES-1:0] core_retired;
  logic [NR_CORES-1:0] mc_retire_pulse;
  logic [NR_CORES-1:0] mc_hang_frozen;
  assign mc_hang_frozen[0] = 1'b0;
  logic [NR_CORES-1:0] mc_held;
  assign mc_held[0] = 1'b0;
  if ((NR_CORES > 1) && (CVA6Cfg.NrHarts > 1)) begin : gen_hold_probe
    for (genvar c = 1; c < NR_CORES; c++) begin : gen_core_hold
      assign mc_held[c] = !i_cluster.gen_core[c].gen_boot_icg.rel;
    end
  end else begin : gen_no_hold_probe
    for (genvar c = 1; c < NR_CORES; c++) begin : gen_core_free
      assign mc_held[c] = 1'b0;
    end
  end
  logic mc_all_silent_held;
  assign mc_all_silent_held = ((~core_retired & ~mc_held) == '0);

  //  Injected-error control for the verdict itself. A verdict that has never been
  //  observed to fail is indistinguishable from one that cannot fail -- the exact
  //  trap this review keeps finding in its own controls. +mc_verdict_fault makes the
  //  secondary cores appear silent, so a normally-passing test must come out as a
  //  multi-core failure with exit code 127.
  logic mc_fault_inject;
  initial mc_fault_inject = $test$plusargs("mc_verdict_fault");

  //  An explicit reduction loop, not `rvfi_instr[N-1:0].valid`: a range on the
  //  instance part of a dotted reference is illegal SystemVerilog.
  logic core0_any_retire;
  always_comb begin
    core0_any_retire = 1'b0;
    for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++)
      core0_any_retire |= rvfi_instr[i].valid;
  end

  assign mc_retire_pulse[0] = core0_any_retire;

  always_comb begin
    mc_retire_is_wfi[0] = 1'b0;
    for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++)
      if (rvfi_instr[i].valid && rvfi_instr[i].insn == MC_WFI_INSN) mc_retire_is_wfi[0] = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : mc_retire_track
    if (!rst_ni) core_retired[0] <= 1'b0;
    else if (core0_any_retire) core_retired[0] <= 1'b1;
  end

  for (genvar c = 1; c < NR_CORES; c++) begin : gen_secondary_trace
    rvfi_csr_t                                sec_rvfi_csr;
    rvfi_instr_t [CVA6Cfg.NrCommitPorts-1:0]  sec_rvfi_instr;
    rvfi_to_iti_t                             sec_rvfi_to_iti;

    cva6_rvfi #(
        .CVA6Cfg   (CVA6Cfg),
        .rvfi_instr_t(rvfi_instr_t),
        .rvfi_csr_t(rvfi_csr_t),
        .rvfi_probes_instr_t(rvfi_probes_instr_t),
        .rvfi_probes_csr_t(rvfi_probes_csr_t),
        .rvfi_probes_t(rvfi_probes_t),
        .rvfi_to_iti_t(rvfi_to_iti_t)
    ) i_cva6_rvfi_sec (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .rvfi_probes_i(i_cluster.core_rvfi[c]),
        .rvfi_instr_o (sec_rvfi_instr),
        .rvfi_to_iti_o(sec_rvfi_to_iti),
        .rvfi_csr_o   (sec_rvfi_csr)
    );

    rvfi_tracer #(
        .CVA6Cfg(CVA6Cfg),
        .rvfi_instr_t(rvfi_instr_t),
        .rvfi_csr_t(rvfi_csr_t),
        .HART_ID(8'(c * ((CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts))),
        .DEBUG_START(0),
        .DEBUG_STOP(0)
    ) i_rvfi_tracer_sec (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .rvfi_i(sec_rvfi_instr),
        .rvfi_csr_i(sec_rvfi_csr),
        .end_of_test_o(core_tracer_exit[c]  /* observer only: must not terminate the simulation */)
    );

    logic sec_any_retire;
    always_comb begin
      sec_any_retire = 1'b0;
      for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++)
        sec_any_retire |= sec_rvfi_instr[i].valid;
    end

    assign mc_retire_pulse[c] = sec_any_retire;

    always_comb begin
      mc_retire_is_wfi[c] = 1'b0;
      for (int unsigned i = 0; i < CVA6Cfg.NrCommitPorts; i++)
        if (sec_rvfi_instr[i].valid && sec_rvfi_instr[i].insn == MC_WFI_INSN)
          mc_retire_is_wfi[c] = 1'b1;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : mc_retire_track_sec
      if (!rst_ni) core_retired[c] <= 1'b0;
      else if (sec_any_retire && !mc_fault_inject) core_retired[c] <= 1'b1;
    end

    //  Freeze this core's observed liveness once it has started, simulating a hang.
    always_ff @(posedge clk_i or negedge rst_ni) begin : mc_hang_fault_track
      if (!rst_ni) mc_hang_frozen[c] <= 1'b0;
      else if (mc_hang_fault_inject && core_retired[c]) mc_hang_frozen[c] <= 1'b1;
    end
  end

  //  Per-core retirement-gap measurement.
  //
  //  The verdict above only asks whether a core EVER retired, so a core that runs
  //  and then hangs still passes. The obvious fix -- require recent retirement --
  //  needs a threshold, and a threshold picked without data is a guess that will
  //  either miss hangs or fail legitimate stalls. So this measures the largest gap
  //  between retirements per core and reports it; the number decides whether a hard
  //  bound is defensible.
  //
  //  An idle park loop KEEPS RETIRING (it retires its own branch every few cycles),
  //  which is what makes a gap bound workable at all: a parked core and a hung core
  //  are distinguishable here, unlike by PC alone.
  //
  //  MEASURED before choosing the bound, across the cross-core tests, the
  //  miss-streaming stress and the single-hart suite: the largest gap anywhere is
  //  **71 cycles**, and cores parked in a loop show 23-30. MC_GAP_LIMIT is set two
  //  orders of magnitude above that, so it cannot fire on a cache miss, a DRAM
  //  stall or a park -- only on a core that has genuinely stopped.
  //
  //  WFI is the one legitimate way to stop retiring. It is excluded by the
  //  INSTRUCTION, read from RVFI, rather than by a hierarchical reference to
  //  `csr_regfile.wfi_q`: the register path runs through `gen_std` or `gen_acc`
  //  depending on configuration, and this review has already been bitten once by a
  //  probe wired to a hierarchy that moved (`i_cva6_icache`).
  //  WFI = 0x10500073. A core whose LAST retirement was a WFI is asleep by
  //  instruction, not hung, and is exempt from the gap bound.
  localparam logic [31:0] MC_WFI_INSN  = 32'h1050_0073;
  localparam int unsigned MC_GAP_LIMIT = 5000;

  int unsigned mc_gap_cur   [NR_CORES];
  int unsigned mc_gap_max   [NR_CORES];
  logic        mc_last_wfi  [NR_CORES];
  logic [NR_CORES-1:0] mc_retire_is_wfi;

  always_ff @(posedge clk_i or negedge rst_ni) begin : mc_gap_track
    if (!rst_ni) begin
      for (int unsigned c = 0; c < NR_CORES; c++) begin
        mc_gap_cur[c]  <= 0;
        mc_gap_max[c]  <= 0;
        mc_last_wfi[c] <= 1'b0;
      end
    end else begin
      for (int unsigned c = 0; c < NR_CORES; c++) begin
        //  Only count once a core has started: the pre-boot gap is not a hang.
        if (core_retired[c]) begin
          if (mc_retire_pulse[c] && !mc_hang_frozen[c]) begin
            if (mc_gap_cur[c] > mc_gap_max[c]) mc_gap_max[c] <= mc_gap_cur[c];
            mc_gap_cur[c]  <= 0;
            mc_last_wfi[c] <= mc_retire_is_wfi[c];
          end else begin
            mc_gap_cur[c] <= mc_gap_cur[c] + 1;
          end
        end
      end
    end
  end

  //  A core is hung if it started, has not retired for MC_GAP_LIMIT cycles, and is
  //  not asleep in WFI. +mc_hang_fault freezes the secondaries' retire pulse once
  //  they have started, which is the injected-error control for this check: without
  //  it, a bound that never fires is indistinguishable from one that cannot.
  logic mc_hang_fault_inject;
  initial mc_hang_fault_inject = $test$plusargs("mc_hang_fault");

  logic mc_any_hung;
  always_comb begin
    mc_any_hung = 1'b0;
    for (int unsigned c = 0; c < NR_CORES; c++)
      if (core_retired[c] && !mc_last_wfi[c] && mc_gap_cur[c] >= MC_GAP_LIMIT)
        mc_any_hung = 1'b1;
  end

  //  Observer-only cache counters. l2_hit_o/l2_miss_o/l2_bypass_o are
  //  single-cycle pulses inside g6lc_l2_top; l3_hit_o/l3_miss_o are cluster
  //  outputs. The l2 hit/bypass taps are hierarchical because the cluster does
  //  not forward them; gen_l2 exists iff L2_ENABLE || CVA6Cfg.L2En and the TB
  //  passes L2_ENABLE=CVA6Cfg.L2En, so the guard mirrors that condition.
  //pragma translate_off
  longint unsigned mc_cnt_l2_hit, mc_cnt_l2_miss, mc_cnt_l2_bypass,
                   mc_cnt_l3_hit, mc_cnt_l3_miss,
                   mc_cnt_l2_selfinv, mc_cnt_l3_selfinv;
  logic mc_l2_hit_obs, mc_l2_bypass_obs, mc_l2_selfinv_obs, mc_l3_selfinv_obs;
  if (CVA6Cfg.L2En) begin : gen_mc_cache_l2
    assign mc_l2_hit_obs    = i_cluster.gen_l2.i_l2.l2_hit_o;
    assign mc_l2_bypass_obs = i_cluster.gen_l2.i_l2.l2_bypass_o;
    // l2_selfinv_hit_o: inval-match (WT write self-inval or L3 back-inval)
    // actually cleared a live line — "lines purged by writes".
    assign mc_l2_selfinv_obs = i_cluster.gen_l2.i_l2.l2_selfinv_hit_o;
  end else begin : gen_mc_cache_nol2
    assign mc_l2_hit_obs    = 1'b0;
    assign mc_l2_bypass_obs = 1'b0;
    assign mc_l2_selfinv_obs = 1'b0;
  end
  if (CVA6Cfg.L3En) begin : gen_mc_cache_l3
    assign mc_l3_selfinv_obs = i_cluster.gen_l3.i_l3.l3_selfinv_hit_o;
  end else begin : gen_mc_cache_nol3
    assign mc_l3_selfinv_obs = 1'b0;
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      mc_cnt_l2_hit    <= mc_cnt_l2_hit    + mc_l2_hit_obs;
      mc_cnt_l2_miss   <= mc_cnt_l2_miss   + mc_l2_miss;
      mc_cnt_l2_bypass <= mc_cnt_l2_bypass + mc_l2_bypass_obs;
      mc_cnt_l3_hit    <= mc_cnt_l3_hit    + mc_l3_hit;
      mc_cnt_l3_miss   <= mc_cnt_l3_miss   + mc_l3_miss;
      mc_cnt_l2_selfinv <= mc_cnt_l2_selfinv + mc_l2_selfinv_obs;
      mc_cnt_l3_selfinv <= mc_cnt_l3_selfinv + mc_l3_selfinv_obs;
    end else begin
      mc_cnt_l2_hit    <= '0;
      mc_cnt_l2_miss   <= '0;
      mc_cnt_l2_bypass <= '0;
      mc_cnt_l3_hit    <= '0;
      mc_cnt_l3_miss   <= '0;
      mc_cnt_l2_selfinv <= '0;
      mc_cnt_l3_selfinv <= '0;
    end
  end
  //pragma translate_on

  //  +l2_trace: per-event trace of the L2 (and L3, iff enabled) tag/FSM
  //  interface for cross-model divergence hunting — pure observer, one
  //  $fwrite per event per instance into l2_trace.log (override the path
  //  with +l2_trace_file=<path>). Format "L<2|3> cyc=<n> <ev> ..." with a
  //  free-running cycle counter, so the traces of a flop-tag and an
  //  SRAM-tag build are expected identical up to the first behavioural
  //  divergence. Hierarchical enum-literal reads are not portable, so
  //  L2T_S_* mirror g6lc_l2_top's state_e encoding (S_TAG=1, S_SERVE=4).
  //pragma translate_off
  int l2t_fd = 0;
  longint unsigned l2t_cyc;
  localparam logic [3:0] L2T_S_TAG = 4'd1, L2T_S_SERVE = 4'd4;
  initial begin
    if ($test$plusargs("l2_trace")) begin
      string l2t_path;
      if (!$value$plusargs("l2_trace_file=%s", l2t_path))
        l2t_path = "l2_trace.log";
      l2t_fd = $fopen(l2t_path, "w");
      if (l2t_fd == 0) $fatal(1, "L2_TRACE_OPEN path=%s", l2t_path);
    end
  end
  final begin
    if (l2t_fd != 0) $fclose(l2t_fd);
  end
  always_ff @(posedge clk_i) begin
    if (!rst_ni) l2t_cyc <= '0;
    else         l2t_cyc <= l2t_cyc + 1'b1;
  end
  if (CVA6Cfg.L2En) begin : gen_l2t_l2
    always_ff @(posedge clk_i) begin
      if (l2t_fd != 0 && rst_ni) begin
        if (i_cluster.gen_l2.i_l2.slv_req_i.ar_valid &&
            i_cluster.gen_l2.i_l2.slv_resp_o.ar_ready)
          $fwrite(l2t_fd, "L2 cyc=%0d ar addr=%h id=%h cache=%h lock=%b\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.slv_req_i.ar.addr, i_cluster.gen_l2.i_l2.slv_req_i.ar.id,
                  i_cluster.gen_l2.i_l2.slv_req_i.ar.cache, i_cluster.gen_l2.i_l2.slv_req_i.ar.lock);
        if (i_cluster.gen_l2.i_l2.slv_req_i.aw_valid &&
            i_cluster.gen_l2.i_l2.slv_resp_o.aw_ready)
          $fwrite(l2t_fd, "L2 cyc=%0d aw addr=%h id=%h atop=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.slv_req_i.aw.addr, i_cluster.gen_l2.i_l2.slv_req_i.aw.id,
                  i_cluster.gen_l2.i_l2.slv_req_i.aw.atop);
        if (i_cluster.gen_l2.i_l2.l2_hit_o)
          $fwrite(l2t_fd, "L2 cyc=%0d hit addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.addr_q, i_cluster.gen_l2.i_l2.gen_l2.id_q);
        if (i_cluster.gen_l2.i_l2.l2_miss_o)
          $fwrite(l2t_fd, "L2 cyc=%0d miss addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.addr_q, i_cluster.gen_l2.i_l2.gen_l2.id_q);
        if (i_cluster.gen_l2.i_l2.l2_bypass_o)
          $fwrite(l2t_fd, "L2 cyc=%0d bypass addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.slv_req_i.aw_valid ?
                  i_cluster.gen_l2.i_l2.slv_req_i.aw.addr : i_cluster.gen_l2.i_l2.slv_req_i.ar.addr,
                  i_cluster.gen_l2.i_l2.slv_req_i.aw_valid ?
                  i_cluster.gen_l2.i_l2.slv_req_i.aw.id : i_cluster.gen_l2.i_l2.slv_req_i.ar.id);
        if (i_cluster.gen_l2.i_l2.gen_l2.tag_write && i_cluster.gen_l2.i_l2.gen_l2.tag_wvalid)
          $fwrite(l2t_fd, "L2 cyc=%0d install idx=%h way=%h tag=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.tag_windex, i_cluster.gen_l2.i_l2.gen_l2.tag_wway,
                  i_cluster.gen_l2.i_l2.gen_l2.tag_wtag);
        if (i_cluster.gen_l2.i_l2.gen_l2.tag_write && !i_cluster.gen_l2.i_l2.gen_l2.tag_wvalid)
          $fwrite(l2t_fd, "L2 cyc=%0d wclr idx=%h way=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.tag_windex, i_cluster.gen_l2.i_l2.gen_l2.tag_wway);
        if (i_cluster.gen_l2.i_l2.gen_l2.tag_match_inval)
          $fwrite(l2t_fd, "L2 cyc=%0d inv idx=%h tag=%h addr=%h src=%s\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.tag_match_index, i_cluster.gen_l2.i_l2.gen_l2.tag_match_tag,
                  i_cluster.gen_l2.i_l2.l2_back_inval_valid_i ?
                  i_cluster.gen_l2.i_l2.l2_back_inval_addr_i : i_cluster.gen_l2.i_l2.gen_l2.self_inval_addr,
                  i_cluster.gen_l2.i_l2.l2_back_inval_valid_i ? "l3" : "self");
        if (i_cluster.gen_l2.i_l2.gen_l2.state_q == L2T_S_TAG &&
            !i_cluster.gen_l2.i_l2.gen_l2.tag_row_valid)
          $fwrite(l2t_fd, "L2 cyc=%0d steal addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.addr_q, i_cluster.gen_l2.i_l2.gen_l2.id_q);
        if (i_cluster.gen_l2.i_l2.gen_l2.state_q == L2T_S_SERVE &&
            i_cluster.gen_l2.i_l2.gen_l2.serve_beat_q == '0 &&
            i_cluster.gen_l2.i_l2.slv_resp_o.r_valid && i_cluster.gen_l2.i_l2.slv_req_i.r_ready)
          $fwrite(l2t_fd, "L2 cyc=%0d serve addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.gen_l2.serve_addr_q, i_cluster.gen_l2.i_l2.gen_l2.serve_id_q);
        if (i_cluster.gen_l2.i_l2.l2_evict_valid_o && i_cluster.gen_l2.i_l2.l2_evict_ready_i)
          $fwrite(l2t_fd, "L2 cyc=%0d evict addr=%h\n", l2t_cyc,
                  i_cluster.gen_l2.i_l2.l2_evict_addr_o);
      end
    end
  end
  if (CVA6Cfg.L3En) begin : gen_l2t_l3
    always_ff @(posedge clk_i) begin
      if (l2t_fd != 0 && rst_ni) begin
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar_valid &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_resp_o.ar_ready)
          $fwrite(l2t_fd, "L3 cyc=%0d ar addr=%h id=%h cache=%h lock=%b\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar.addr,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar.id,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar.cache,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar.lock);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw_valid &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_resp_o.aw_ready)
          $fwrite(l2t_fd, "L3 cyc=%0d aw addr=%h id=%h atop=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw.addr,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw.id,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw.atop);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_hit_o)
          $fwrite(l2t_fd, "L3 cyc=%0d hit addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.addr_q, i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.id_q);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_miss_o)
          $fwrite(l2t_fd, "L3 cyc=%0d miss addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.addr_q, i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.id_q);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_bypass_o)
          $fwrite(l2t_fd, "L3 cyc=%0d bypass addr=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw_valid ?
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.aw.addr :
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.ar.addr);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_write &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_wvalid)
          $fwrite(l2t_fd, "L3 cyc=%0d install idx=%h way=%h tag=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_windex,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_wway,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_wtag);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_write &&
            !i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_wvalid)
          $fwrite(l2t_fd, "L3 cyc=%0d wclr idx=%h way=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_windex,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_wway);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_match_inval)
          $fwrite(l2t_fd, "L3 cyc=%0d inv idx=%h tag=%h addr=%h src=%s\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_match_index,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_match_tag,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_back_inval_valid_i ?
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_back_inval_addr_i :
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.self_inval_addr,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_back_inval_valid_i ? "l3" : "self");
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.state_q == L2T_S_TAG &&
            !i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.tag_row_valid)
          $fwrite(l2t_fd, "L3 cyc=%0d steal addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.addr_q,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.id_q);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.state_q == L2T_S_SERVE &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.serve_beat_q == '0 &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_resp_o.r_valid &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.slv_req_i.r_ready)
          $fwrite(l2t_fd, "L3 cyc=%0d serve addr=%h id=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.serve_addr_q,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.gen_l2.serve_id_q);
        if (i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_evict_valid_o &&
            i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_evict_ready_i)
          $fwrite(l2t_fd, "L3 cyc=%0d evict addr=%h\n", l2t_cyc,
                  i_cluster.gen_l3.i_l3.i_l3_as_l2.l2_evict_addr_o);
      end
    end
  end
  //pragma translate_on

  //  Report in a `final` block, not from the clocked process. The C++ side leaves
  //  its loop as soon as `exit_o[0]` is set, so a $display issued in that same
  //  cycle never reaches the log -- measured: the run exited 127 with no reason
  //  printed, which is exactly the "verdict with no diagnosis" this review keeps
  //  complaining about elsewhere.
  //pragma translate_off
  final begin
    if (!(&core_retired)) begin
      if (mc_all_silent_held)
        $display("*** [mc_verdict] HELD: core(s) still clock-held at end of test, held_mask=%b retired_mask=%b (exit code 125)",
                 mc_held, core_retired);
      else
        $display("*** [mc_verdict] FAIL: core(s) retired no instruction, retired_mask=%b held_mask=%b (exit code 127)",
                 core_retired, mc_held);
    end else
      $display("*** [mc_verdict] all %0d core(s) retired instructions", NR_CORES);
    $display("*** [mc_verdict] program exit code %0d", tracer_exit[31:1]);
    for (int unsigned c = 0; c < NR_CORES; c++)
      $display("*** [mc_gap] core %0d max retirement gap %0d cycles (limit %0d, wfi=%0b)",
               c, mc_gap_max[c], MC_GAP_LIMIT, mc_last_wfi[c]);
    if (mc_any_hung)
      $display("*** [mc_verdict] FAIL: a core ran and then stopped retiring (exit code 126)");
    $display("*** [mc_cache] l2_hit=%0d l2_miss=%0d l2_bypass=%0d l3_hit=%0d l3_miss=%0d l2_selfinv=%0d l3_selfinv=%0d dram_latency=%0d",
             mc_cnt_l2_hit, mc_cnt_l2_miss, mc_cnt_l2_bypass, mc_cnt_l3_hit, mc_cnt_l3_miss,
             mc_cnt_l2_selfinv, mc_cnt_l3_selfinv, DramLatency);
  end
  //pragma translate_on

`ifdef SPIKE_TANDEM
    spike #(
        .CVA6Cfg ( CVA6Cfg ),
        .rvfi_instr_t(rvfi_instr_t),
        .rvfi_csr_t(rvfi_csr_t)
    ) i_spike (
        .clk_i,
        .rst_ni,
        .clint_tick_i   ( rtc_i    ),
        .rvfi_i         ( rvfi_instr ),
        .rvfi_csr_i     ( rvfi_csr ),
        .end_of_test_o  ( tandem_exit )
    );
    initial begin
        $display("Running binary in tandem mode");
    end

    bit tandem_timeout_enable;
    bit [31:0] tandem_timeout;
    localparam TANDEM_TIMEOUT_THRESHOLD = 60;

    // Tandem timeout logic
    always_ff @(posedge clk_i) begin
        if(tandem_timeout > TANDEM_TIMEOUT_THRESHOLD)
            tandem_timeout_enable <= 0;
        else if (tracer_exit)
            tandem_timeout_enable <= 1;

        if (tandem_timeout_enable)
            tandem_timeout <= tandem_timeout + 1;
    end

    always_ff @(posedge clk_i) begin
        if (tandem_exit || (tandem_timeout > TANDEM_TIMEOUT_THRESHOLD)) begin
            rvfi_exit <= tracer_exit;
        end

    end
`else
    //  Fold the multi-core verdict in: keep core 0's done bit, but override the
    //  exit code with a distinctive 127 so a silent secondary core cannot report
    //  SUCCESS. exit_o>>1 is the exit code the C++ side reports.
    //  Exit 126 for a core that ran and then STOPPED, distinct from 127 (a core
    //  that never ran at all) so the log says which failure occurred. When every
    //  still-silent core is held by the cluster's boot clock gate (expected on
    //  multi-core SMT targets) the code is 125 instead of 127.
    assign rvfi_exit = (tracer_exit[0] && !(&core_retired))
                       ? (mc_all_silent_held ? {31'd125, 1'b1} : {31'd127, 1'b1})
                     : (tracer_exit[0] && mc_any_hung)      ? {31'd126, 1'b1}
                                                            : tracer_exit;
`endif

`ifdef VERILATOR
    initial begin
        string verbosity;
        if ($value$plusargs("UVM_VERBOSITY=%s",verbosity)) begin
          uvm_set_verbosity_level(verbosity);
          `uvm_info("ariane_testharness", $sformatf("Set UVM_VERBOSITY to %s", verbosity), UVM_NONE)
        end
    end
`endif


`ifdef AXI_SVA
  // AXI 4 Assertion IP integration - You will need to get your own copy of this IP if you want
  // to use it
  Axi4PC #(
    .DATA_WIDTH(ariane_axi_soc::DataWidth),
    .WID_WIDTH(ariane_axi_soc::IdWidthSlave),
    .RID_WIDTH(ariane_axi_soc::IdWidthSlave),
    .AWUSER_WIDTH(ariane_axi_soc::UserWidth),
    .WUSER_WIDTH(ariane_axi_soc::UserWidth),
    .BUSER_WIDTH(ariane_axi_soc::UserWidth),
    .ARUSER_WIDTH(ariane_axi_soc::UserWidth),
    .RUSER_WIDTH(ariane_axi_soc::UserWidth),
    .ADDR_WIDTH(ariane_axi_soc::AddrWidth)
  ) i_Axi4PC (
    .ACLK(clk_i),
    .ARESETn(ndmreset_n),
    .AWID(dram.aw_id),
    .AWADDR(dram.aw_addr),
    .AWLEN(dram.aw_len),
    .AWSIZE(dram.aw_size),
    .AWBURST(dram.aw_burst),
    .AWLOCK(dram.aw_lock),
    .AWCACHE(dram.aw_cache),
    .AWPROT(dram.aw_prot),
    .AWQOS(dram.aw_qos),
    .AWREGION(dram.aw_region),
    .AWUSER(dram.aw_user),
    .AWVALID(dram.aw_valid),
    .AWREADY(dram.aw_ready),
    .WLAST(dram.w_last),
    .WDATA(dram.w_data),
    .WSTRB(dram.w_strb),
    .WUSER(dram.w_user),
    .WVALID(dram.w_valid),
    .WREADY(dram.w_ready),
    .BID(dram.b_id),
    .BRESP(dram.b_resp),
    .BUSER(dram.b_user),
    .BVALID(dram.b_valid),
    .BREADY(dram.b_ready),
    .ARID(dram.ar_id),
    .ARADDR(dram.ar_addr),
    .ARLEN(dram.ar_len),
    .ARSIZE(dram.ar_size),
    .ARBURST(dram.ar_burst),
    .ARLOCK(dram.ar_lock),
    .ARCACHE(dram.ar_cache),
    .ARPROT(dram.ar_prot),
    .ARQOS(dram.ar_qos),
    .ARREGION(dram.ar_region),
    .ARUSER(dram.ar_user),
    .ARVALID(dram.ar_valid),
    .ARREADY(dram.ar_ready),
    .RID(dram.r_id),
    .RLAST(dram.r_last),
    .RDATA(dram.r_data),
    .RRESP(dram.r_resp),
    .RUSER(dram.r_user),
    .RVALID(dram.r_valid),
    .RREADY(dram.r_ready),
    .CACTIVE('0),
    .CSYSREQ('0),
    .CSYSACK('0)
  );
`endif
endmodule

`include "g6lc_apu_xbar_hart.sv"
`include "../apu/g6lc_apu_fault_sup.sv"
