// Copyright 2023 Commissariat a l'Energie Atomique et aux Energies
//                Alternatives (CEA)
//
// Licensed under the Solderpad Hardware License, Version 2.1 (the “License”);
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Authors: Cesar Fuguet
// Modified by: Etienne Cimon (ICACHE_RDTXID sized localparam)
// Date: February, 2023
// Description: CVA6 cache subsystem integrating standard CVA6's
//              instruction cache and the Core-V High-Performance L1
//              data cache (CV-HPDcache).

module cva6_hpdcache_subsystem
//  Parameters
//  {{{
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type icache_areq_t = logic,
    parameter type icache_arsp_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic,
    parameter type icache_req_t = logic,
    parameter type icache_rtrn_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter int NumPorts = 4,
    parameter int NrHwPrefetchers = 4,
    // AXI types
    parameter type axi_ar_chan_t = logic,
    parameter type axi_aw_chan_t = logic,
    parameter type axi_w_chan_t = logic,
    parameter type axi_b_chan_t = logic,
    parameter type axi_r_chan_t = logic,
    parameter type noc_req_t = logic,
    parameter type noc_resp_t = logic
)
//  }}}

//  Ports
//  {{{
(

    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Reset value for the in-flight I$ fetch address
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,

    //  AXI port to upstream memory/peripherals
    //  {{{
    // noc request, can be AXI or OpenPiton - SUBSYSTEM
    output noc_req_t  noc_req_o,
    // noc response, can be AXI or OpenPiton - SUBSYSTEM
    input  noc_resp_t noc_resp_i,
    //  }}}

    //  I$
    //  {{{
    // Instruction cache enable - CSR_REGFILE
    input logic icache_en_i,
    // Flush the instruction cache - CONTROLLER
    input logic icache_flush_i,
    // instruction cache miss - PERF_COUNTERS
    output logic icache_miss_o,
    // Input address translation request - EX_STAGE
    input icache_areq_t icache_areq_i,
    // Output address translation request - EX_STAGE
    output icache_arsp_t icache_areq_o,
    // Input data translation request - FRONTEND
    input icache_dreq_t icache_dreq_i,
    // Output data translation request - FRONTEND
    output icache_drsp_t icache_dreq_o,
    //   }}}

    //  D$
    //  {{{
    //    Cache management
    // Data cache enable - CSR_REGFILE
    input  logic dcache_enable_i,
    // Data cache flush - CONTROLLER
    input  logic dcache_flush_i,
    // Flush acknowledge - CONTROLLER
    output logic dcache_flush_ack_o,
    // Load or store miss - PERF_COUNTERS
    output logic dcache_miss_o,

    // AMO request - EX_STAGE
    input  ariane_pkg::amo_req_t                 dcache_amo_req_i,
    // AMO response - EX_STAGE
    output ariane_pkg::amo_resp_t                dcache_amo_resp_o,
    // Data cache input request ports - EX_STAGE
    input  dcache_req_i_t         [NumPorts-1:0] dcache_req_ports_i,
    // Data cache output request ports - EX_STAGE
    output dcache_req_o_t         [NumPorts-1:0] dcache_req_ports_o,
    // Write buffer status to know if empty - EX_STAGE
    output logic                                 wbuffer_empty_o,
    // Write buffer status to know if not non idempotent - EX_STAGE
    output logic                                 wbuffer_not_ni_o,

    //  Hardware memory prefetcher configuration
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0]       hwpf_base_set_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0][63:0] hwpf_base_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic [NrHwPrefetchers-1:0][63:0] hwpf_base_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0]       hwpf_param_set_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0][63:0] hwpf_param_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic [NrHwPrefetchers-1:0][63:0] hwpf_param_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0]       hwpf_throttle_set_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic [NrHwPrefetchers-1:0][63:0] hwpf_throttle_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic [NrHwPrefetchers-1:0][63:0] hwpf_throttle_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic [               63:0]       hwpf_status_o,

    // U6.2 external L1 invalidation (coherence hub → D$). Tie valid=0 if unused.
    input  logic [63:0] inval_addr_i,
    input  logic        inval_valid_i,
    output logic        inval_ready_o,
    // T9a eWT CMO sideband (store adapter; response hold lives there)
    output logic                    cmo_valid_o,
    output logic [1:0]              cmo_op_o,
    output logic [CVA6Cfg.PLEN-1:0] cmo_addr_o,
    input  logic                    cmo_ready_i,
    input  logic                    cmo_done_i
    //  }}}
);
  //  }}}

  function int unsigned __minu(int unsigned x, int unsigned y);
    return x < y ? x : y;
  endfunction

  function int unsigned __maxu(int unsigned x, int unsigned y);
    return y < x ? x : y;
  endfunction

  //  I$ instantiation
  //  {{{
  logic icache_miss_valid, icache_miss_ready;
  icache_req_t icache_miss;

  logic icache_miss_resp_valid;
  icache_rtrn_t icache_miss_resp;

  localparam logic [CVA6Cfg.MEM_TID_WIDTH-1:0] ICACHE_RDTXID =
      {1'b1, {CVA6Cfg.MEM_TID_WIDTH - 1{1'b0}}};

  g6lc_icache #(
      .CVA6Cfg(CVA6Cfg),
      .icache_areq_t(icache_areq_t),
      .icache_arsp_t(icache_arsp_t),
      .icache_dreq_t(icache_dreq_t),
      .icache_drsp_t(icache_drsp_t),
      .icache_req_t(icache_req_t),
      .icache_rtrn_t(icache_rtrn_t),
      .RdTxId(ICACHE_RDTXID)
  ) i_g6lc_icache (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .boot_addr_i   (boot_addr_i),
      .flush_i       (icache_flush_i),
      .en_i          (icache_en_i),
      .miss_o        (icache_miss_o),
      .areq_i        (icache_areq_i),
      .areq_o        (icache_areq_o),
      .dreq_i        (icache_dreq_i),
      .dreq_o        (icache_dreq_o),
      .mem_rtrn_vld_i(icache_miss_resp_valid),
      .mem_rtrn_i    (icache_miss_resp),
      .mem_data_req_o(icache_miss_valid),
      .mem_data_ack_i(icache_miss_ready),
      .mem_data_o    (icache_miss)
  );
  //  }}}

  //  D$ instantiation
  //  {{{
  `include "hpdcache_typedef.svh"

  //    0: Page-Table Walk (PTW)
  //    1: Load unit
  //    2: Accelerator load
  //    3: Store/AMO
  //    .
  //    .
  //    .
  //    NumPorts: Hardware Memory Prefetcher (hwpf)
  localparam int HPDCACHE_NREQUESTERS = NumPorts + 1;

  function automatic hpdcache_pkg::hpdcache_user_cfg_t hpdcacheSetConfig();
    hpdcache_pkg::hpdcache_user_cfg_t userCfg;
    userCfg.nRequesters = HPDCACHE_NREQUESTERS;
    userCfg.paWidth = CVA6Cfg.PLEN;
    userCfg.wordWidth = CVA6Cfg.XLEN;
    userCfg.sets = CVA6Cfg.DCACHE_NUM_WORDS;
    userCfg.ways = CVA6Cfg.DCACHE_SET_ASSOC;
    userCfg.clWords = CVA6Cfg.DCACHE_LINE_WIDTH / userCfg.wordWidth;
    userCfg.reqWords = 1;
    userCfg.reqTransIdWidth = CVA6Cfg.DcacheIdWidth;
    userCfg.reqSrcIdWidth = 3;  // Up to 8 requesters
    userCfg.victimSel = hpdcache_pkg::HPDCACHE_VICTIM_RANDOM;
    userCfg.dataWaysPerRamWord = __minu(CVA6Cfg.DCACHE_SET_ASSOC, 128 / CVA6Cfg.XLEN);
    userCfg.dataSetsPerRam = CVA6Cfg.DCACHE_NUM_WORDS;
    userCfg.dataRamByteEnable = 1'b1;
    userCfg.accessWords = __maxu(CVA6Cfg.AxiDataWidth / userCfg.wordWidth, userCfg.reqWords);
    // G6LC T16: the MSHR set count must be a power of two. HPDcache indexes the
    // MSHR with nline[0 +: clog2(mshrSets)] and sizes the RAM at exactly
    // mshrSets words, so a non-power-of-two count (NrLoadBufEntries=24 -> 12
    // sets, 4 index bits) lets every line whose low nline bits are 12..15
    // allocate a set that does not exist: the entry write is dropped and the
    // refill ack reads word 0 — another miss's tid — so one load retires with
    // a foreign line and the other never completes (g6lc64_ooo_server:
    // the fourth consecutive consumed L1 miss hung mc_l2_write_read). Round
    // the set count up; MEM_TID_WIDTH is checked against the rounded geometry.
    userCfg.mshrSets = CVA6Cfg.NrLoadBufEntries < 16 ? 1 : 2 ** $clog2(CVA6Cfg.NrLoadBufEntries / 2);
    userCfg.mshrWays = CVA6Cfg.NrLoadBufEntries < 16 ? CVA6Cfg.NrLoadBufEntries : 2;
    userCfg.mshrWaysPerRamWord = CVA6Cfg.NrLoadBufEntries < 16 ? CVA6Cfg.NrLoadBufEntries : 2;
    userCfg.mshrSetsPerRam = userCfg.mshrSets;
    userCfg.mshrRamByteEnable = 1'b1;
    userCfg.mshrUseRegbank = (CVA6Cfg.NrLoadBufEntries < 16);
    userCfg.cbufEntries = CVA6Cfg.WtDcacheWbufDepth;
    userCfg.refillCoreRspFeedthrough = 1'b1;
    if (CVA6Cfg.NOCType == config_pkg::NOC_TYPE_L15_BIG_ENDIAN || CVA6Cfg.NOCType == config_pkg::NOC_TYPE_L15_LITTLE_ENDIAN) begin
      // OpenPiton needs a larger refill FIFO to store as many invalidations as in-flight requests (plus some extra to be safe)
      userCfg.refillFifoDepth = (userCfg.mshrSets * userCfg.mshrWays) + 10;
    end else begin
      userCfg.refillFifoDepth = 2 * (CVA6Cfg.DCACHE_LINE_WIDTH / CVA6Cfg.AxiDataWidth);
    end
    userCfg.wbufDirEntries = CVA6Cfg.WtDcacheWbufDepth;
    userCfg.wbufDataEntries = CVA6Cfg.WtDcacheWbufDepth;
    userCfg.wbufWords = 1;
    userCfg.wbufTimecntWidth = 3;
    userCfg.rtabEntries = 4;
    userCfg.flushEntries = CVA6Cfg.WtDcacheWbufDepth;  /*FIXME add additional CVA6 parameter*/
    userCfg.flushFifoDepth = CVA6Cfg.WtDcacheWbufDepth;  /*FIXME add additional CVA6 parameter*/
    userCfg.memAddrWidth = CVA6Cfg.AxiAddrWidth;
    userCfg.memIdWidth = CVA6Cfg.MEM_TID_WIDTH;
    userCfg.memDataWidth = CVA6Cfg.AxiDataWidth;
    userCfg.wtEn =
        (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT) ||
        (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB);
    userCfg.wbEn =
        (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WB) ||
        (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB);
    userCfg.lowLatency = 1'b1;
    userCfg.eccEn = 1'b0;  /*FIXME add additional CVA6 parameter*/
    userCfg.eccScrubberEn = 1'b0;  /*FIXME: add additional CVA6 parameter*/
    return userCfg;
  endfunction

  localparam hpdcache_pkg::hpdcache_user_cfg_t HPDcacheUserCfg = hpdcacheSetConfig();
  localparam hpdcache_pkg::hpdcache_cfg_t HPDcacheCfg = hpdcache_pkg::hpdcacheBuildConfig(
      HPDcacheUserCfg
  );

  `HPDCACHE_TYPEDEF_MEM_ATTR_T(hpdcache_mem_addr_t, hpdcache_mem_id_t, hpdcache_mem_data_t,
                               hpdcache_mem_be_t, HPDcacheCfg);
  `HPDCACHE_TYPEDEF_MEM_REQ_T(hpdcache_mem_req_t, hpdcache_mem_addr_t, hpdcache_mem_id_t);
  `HPDCACHE_TYPEDEF_MEM_RESP_R_T(hpdcache_mem_resp_r_t, hpdcache_mem_id_t, hpdcache_mem_data_t);
  `HPDCACHE_TYPEDEF_MEM_REQ_W_T(hpdcache_mem_req_w_t, hpdcache_mem_data_t, hpdcache_mem_be_t);
  `HPDCACHE_TYPEDEF_MEM_RESP_W_T(hpdcache_mem_resp_w_t, hpdcache_mem_id_t);

  `HPDCACHE_TYPEDEF_REQ_ATTR_T(hpdcache_req_offset_t, hpdcache_data_word_t, hpdcache_data_be_t,
                               hpdcache_req_data_t, hpdcache_req_be_t, hpdcache_req_sid_t,
                               hpdcache_req_tid_t, hpdcache_tag_t, HPDcacheCfg);
  `HPDCACHE_TYPEDEF_REQ_T(hpdcache_req_t, hpdcache_req_offset_t, hpdcache_req_data_t,
                          hpdcache_req_be_t, hpdcache_req_sid_t, hpdcache_req_tid_t,
                          hpdcache_tag_t);
  `HPDCACHE_TYPEDEF_RSP_T(hpdcache_rsp_t, hpdcache_req_data_t, hpdcache_req_sid_t,
                          hpdcache_req_tid_t);

  typedef logic [HPDcacheCfg.u.wbufTimecntWidth-1:0] hpdcache_wbuf_timecnt_t;
  typedef logic [HPDcacheCfg.nlineWidth-1:0] hpdcache_nline_t;

  logic                 dcache_read_ready;
  logic                 dcache_read_valid;
  hpdcache_mem_req_t    dcache_read;

  logic                 dcache_read_resp_ready;
  logic                 dcache_read_resp_valid;
  hpdcache_mem_resp_r_t dcache_read_resp;

  logic                 dcache_write_ready;
  logic                 dcache_write_valid;
  hpdcache_mem_req_t    dcache_write;

  logic                 dcache_write_data_ready;
  logic                 dcache_write_data_valid;
  hpdcache_mem_req_w_t  dcache_write_data;

  logic                 dcache_write_resp_ready;
  logic                 dcache_write_resp_valid;
  hpdcache_mem_resp_w_t dcache_write_resp;

  logic                 dcache_resp_read_inval;
  hpdcache_nline_t      dcache_resp_read_inval_nline;
  // Intermediate: L15/NoC inv OR external coherence inv
  logic                 noc_inval_valid;
  hpdcache_nline_t      noc_inval_nline;
  logic                 ext_inval_valid;
  hpdcache_nline_t      ext_inval_nline;
  // nline = paddr >> clOffsetWidth (see hpdcache_pkg buildCfg)
  localparam int unsigned HPDC_LINE_OFF = HPDcacheCfg.clOffsetWidth;

  cva6_hpdcache_wrapper #(
      .CVA6Cfg(CVA6Cfg),
      .HPDcacheCfg(HPDcacheCfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .NumPorts(NumPorts),
      .NrHwPrefetchers(NrHwPrefetchers),
      .hpdcache_mem_addr_t(hpdcache_mem_addr_t),
      .hpdcache_mem_id_t(hpdcache_mem_id_t),
      .hpdcache_mem_data_t(hpdcache_mem_data_t),
      .hpdcache_mem_be_t(hpdcache_mem_be_t),
      .hpdcache_mem_req_t(hpdcache_mem_req_t),
      .hpdcache_mem_req_w_t(hpdcache_mem_req_w_t),
      .hpdcache_mem_resp_r_t(hpdcache_mem_resp_r_t),
      .hpdcache_mem_resp_w_t(hpdcache_mem_resp_w_t),
      .hpdcache_req_offset_t(hpdcache_req_offset_t),
      .hpdcache_data_word_t(hpdcache_data_word_t),
      .hpdcache_req_data_t(hpdcache_req_data_t),
      .hpdcache_req_be_t(hpdcache_req_be_t),
      .hpdcache_req_sid_t(hpdcache_req_sid_t),
      .hpdcache_req_tid_t(hpdcache_req_tid_t),
      .hpdcache_tag_t(hpdcache_tag_t),
      .hpdcache_req_t(hpdcache_req_t),
      .hpdcache_rsp_t(hpdcache_rsp_t),
      .hpdcache_wbuf_timecnt_t(hpdcache_wbuf_timecnt_t),
      .hpdcache_data_be_t(hpdcache_data_be_t)
  ) i_dcache (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .dcache_enable_i(dcache_enable_i),
      .dcache_flush_i(dcache_flush_i),
      .dcache_flush_ack_o(dcache_flush_ack_o),
      .dcache_miss_o(dcache_miss_o),
      .dcache_amo_req_i(dcache_amo_req_i),
      .dcache_amo_resp_o(dcache_amo_resp_o),
      .dcache_req_ports_i(dcache_req_ports_i),
      .dcache_req_ports_o(dcache_req_ports_o),
      .wbuffer_empty_o(wbuffer_empty_o),
      .wbuffer_not_ni_o(wbuffer_not_ni_o),
      .hwpf_base_set_i(hwpf_base_set_i),
      .hwpf_base_i(hwpf_base_i),
      .hwpf_base_o(hwpf_base_o),
      .hwpf_param_set_i(hwpf_param_set_i),
      .hwpf_param_i(hwpf_param_i),
      .hwpf_param_o(hwpf_param_o),
      .hwpf_throttle_set_i(hwpf_throttle_set_i),
      .hwpf_throttle_i(hwpf_throttle_i),
      .hwpf_throttle_o(hwpf_throttle_o),
      .hwpf_status_o(hwpf_status_o),

      .dcache_mem_req_read_ready_i(dcache_read_ready),
      .dcache_mem_req_read_valid_o(dcache_read_valid),
      .dcache_mem_req_read_o(dcache_read),

      .dcache_mem_resp_read_ready_o(dcache_read_resp_ready),
      .dcache_mem_resp_read_valid_i(dcache_read_resp_valid),
      .dcache_mem_resp_read_i(dcache_read_resp),

      .dcache_mem_resp_read_inval_i(dcache_resp_read_inval),
      .dcache_mem_resp_read_inval_nline_i(dcache_resp_read_inval_nline),

      .dcache_mem_req_write_ready_i(dcache_write_ready),
      .dcache_mem_req_write_valid_o(dcache_write_valid),
      .dcache_mem_req_write_o(dcache_write),

      .dcache_mem_req_write_data_ready_i(dcache_write_data_ready),
      .dcache_mem_req_write_data_valid_o(dcache_write_data_valid),
      .dcache_mem_req_write_data_o(dcache_write_data),

      .dcache_mem_resp_write_ready_o(dcache_write_resp_ready),
      .dcache_mem_resp_write_valid_i(dcache_write_resp_valid),
      .dcache_mem_resp_write_i(dcache_write_resp),

      .cmo_valid_o(cmo_valid_o),
      .cmo_op_o   (cmo_op_o),
      .cmo_addr_o (cmo_addr_o),
      .cmo_ready_i(cmo_ready_i),
      .cmo_done_i (cmo_done_i)
  );

  if (CVA6Cfg.NOCType == config_pkg::NOC_TYPE_L15_BIG_ENDIAN || CVA6Cfg.NOCType == config_pkg::NOC_TYPE_L15_LITTLE_ENDIAN) begin
    ///////////////////////////////////////////////////////
    // memory plumbing, either use 64bit AXI port or native
    // L15 cache interface (derived from OpenSPARC CCX).
    ///////////////////////////////////////////////////////

    localparam NUM_PORTS_ADAPTER = 4;
    localparam NUM_PORTS_ADAPTER_WIDTH = $clog2(NUM_PORTS_ADAPTER);
    // Adapter HPDC-L1.5 Request Ports type
    // 0: Maximum priority 
    // NUM_PORTS_ADAPTER - 1 : Less priority 
    localparam [NUM_PORTS_ADAPTER_WIDTH-1:0] ICACHE_PORT = 0;
    localparam [NUM_PORTS_ADAPTER_WIDTH-1:0] DCACHE_READ_PORT = 1;
    localparam [NUM_PORTS_ADAPTER_WIDTH-1:0] DCACHE_WRITE_PORT = 2;
    localparam [NUM_PORTS_ADAPTER_WIDTH-1:0] DCACHE_AMO_PORT = 3;

    typedef logic [NUM_PORTS_ADAPTER_WIDTH-1:0] req_portid_t;
    //L15 adapter instantiation
    //{{{
    cva6_hpdcache_subsystem_l15_adapter #(
        .CVA6Cfg(CVA6Cfg),

        .NumPorts       (NUM_PORTS_ADAPTER),
        .IcachePort     (ICACHE_PORT),
        .DcacheReadPort (DCACHE_READ_PORT),
        .DcacheWritePort(DCACHE_WRITE_PORT),
        .DcacheAmoPort  (DCACHE_AMO_PORT),

        .HPDcacheMemDataWidth(CVA6Cfg.DCACHE_LINE_WIDTH),
        .L15BusWidth         (l15_pkg::L15_DATA_BUS_WIDTH),

        .icache_req_t  (icache_req_t),
        .icache_rtrn_t (icache_rtrn_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),

        .l15_req_t (noc_req_t),
        .l15_rtrn_t(noc_resp_t),

        .hpdcache_mem_req_t   (hpdcache_mem_req_t),
        .hpdcache_mem_req_w_t (hpdcache_mem_req_w_t),
        .hpdcache_mem_resp_r_t(hpdcache_mem_resp_r_t),
        .hpdcache_mem_resp_w_t(hpdcache_mem_resp_w_t),
        .hpdcache_mem_id_t    (hpdcache_mem_id_t),
        .hpdcache_mem_addr_t  (hpdcache_mem_addr_t),
        .hpdcache_nline_t     (hpdcache_nline_t),
        .req_portid_t         (req_portid_t)
    ) i_l15_adapter (
        .clk_i,
        .rst_ni,

        .icache_miss_valid_i(icache_miss_valid),
        .icache_miss_ready_o(icache_miss_ready),
        .icache_miss_i      (icache_miss),

        .icache_miss_resp_valid_o(icache_miss_resp_valid),
        .icache_miss_resp_o      (icache_miss_resp),

        .dcache_read_ready_o(dcache_read_ready),
        .dcache_read_valid_i(dcache_read_valid),
        .dcache_read_i      (dcache_read),

        .dcache_read_resp_ready_i(dcache_read_resp_ready),
        .dcache_read_resp_valid_o(dcache_read_resp_valid),
        .dcache_read_resp_o      (dcache_read_resp),

        .dcache_inval_valid_o(noc_inval_valid),
        .dcache_inval_o      (noc_inval_nline),

        .dcache_write_ready_o(dcache_write_ready),
        .dcache_write_valid_i(dcache_write_valid),
        .dcache_write_i      (dcache_write),

        .dcache_write_data_ready_o(dcache_write_data_ready),
        .dcache_write_data_valid_i(dcache_write_data_valid),
        .dcache_write_data_i      (dcache_write_data),

        .dcache_write_resp_ready_i(dcache_write_resp_ready),
        .dcache_write_resp_valid_o(dcache_write_resp_valid),
        .dcache_write_resp_o      (dcache_write_resp),

        .l15_req_o (noc_req_o),
        .l15_rtrn_i(noc_resp_i)
    );
    // External inv ORed with L15 (external wins address if both same cycle).
    // The L15 path delivers invalidations natively inside its response stream, so
    // it needs no retention here; the AXI branch does, and adds it there.
    assign ext_inval_valid = inval_valid_i;
    assign ext_inval_nline =
        hpdcache_nline_t'(inval_addr_i[HPDC_LINE_OFF +: HPDcacheCfg.nlineWidth]);
    assign dcache_resp_read_inval = noc_inval_valid | ext_inval_valid;
    assign dcache_resp_read_inval_nline = ext_inval_valid ? ext_inval_nline : noc_inval_nline;
    assign inval_ready_o = 1'b1;
    //}}}
  end else begin

    //  Retention state and read-response taps. Declared HERE, ahead of the
    //  arbiter that consumes them: declaring them after the instantiation is a
    //  use-before-declaration that Verilator tolerates but yosys-slang correctly
    //  rejects, so the synth stage failed while lint passed. Only the AXI path
    //  needs these; the L15 path receives invalidations natively in its response
    //  stream.
    hpdcache_nline_t      ext_inv_nline_q;
    logic                 inv_inject;
    logic                 inv_evt_injected;
    logic                 inv_evt_backpressured;
    logic                 axi_rresp_valid;
    logic                 axi_rresp_ready;
    hpdcache_mem_resp_r_t axi_rresp;

    //  AXI arbiter instantiation
    //  {{{
    cva6_hpdcache_subsystem_axi_arbiter #(
        .CVA6Cfg              (CVA6Cfg),
        .hpdcache_mem_id_t    (hpdcache_mem_id_t),
        .hpdcache_mem_req_t   (hpdcache_mem_req_t),
        .hpdcache_mem_req_w_t (hpdcache_mem_req_w_t),
        .hpdcache_mem_resp_r_t(hpdcache_mem_resp_r_t),
        .hpdcache_mem_resp_w_t(hpdcache_mem_resp_w_t),
        .icache_req_t         (icache_req_t),
        .icache_rtrn_t        (icache_rtrn_t),

        .AxiAddrWidth (CVA6Cfg.AxiAddrWidth),
        .AxiDataWidth (CVA6Cfg.AxiDataWidth),
        .AxiIdWidth   (CVA6Cfg.AxiIdWidth),
        .AxiUserWidth (CVA6Cfg.AxiUserWidth),
        .axi_ar_chan_t(axi_ar_chan_t),
        .axi_aw_chan_t(axi_aw_chan_t),
        .axi_w_chan_t (axi_w_chan_t),
        .axi_b_chan_t (axi_b_chan_t),
        .axi_r_chan_t (axi_r_chan_t),
        .axi_req_t    (noc_req_t),
        .axi_rsp_t    (noc_resp_t)
    ) i_axi_arbiter (
        .clk_i,
        .rst_ni,

        .icache_miss_valid_i(icache_miss_valid),
        .icache_miss_ready_o(icache_miss_ready),
        .icache_miss_i      (icache_miss),
        .icache_miss_id_i   (hpdcache_mem_id_t'(ICACHE_RDTXID)),

        .icache_miss_resp_valid_o(icache_miss_resp_valid),
        .icache_miss_resp_o      (icache_miss_resp),

        .dcache_read_ready_o(dcache_read_ready),
        .dcache_read_valid_i(dcache_read_valid),
        .dcache_read_i      (dcache_read),

        .dcache_read_resp_ready_i(axi_rresp_ready),
        .dcache_read_resp_valid_o(axi_rresp_valid),
        .dcache_read_resp_o      (axi_rresp),

        .dcache_write_ready_o(dcache_write_ready),
        .dcache_write_valid_i(dcache_write_valid),
        .dcache_write_i      (dcache_write),

        .dcache_write_data_ready_o(dcache_write_data_ready),
        .dcache_write_data_valid_i(dcache_write_data_valid),
        .dcache_write_data_i      (dcache_write_data),

        .dcache_write_resp_ready_i(dcache_write_resp_ready),
        .dcache_write_resp_valid_o(dcache_write_resp_valid),
        .dcache_write_resp_o      (dcache_write_resp),

        .axi_req_o (noc_req_o),
        .axi_resp_i(noc_resp_i)
    );
    //  }}}

    //  U6.2: external coherence invalidations, RETAINED until HPDCACHE consumes them.
    //
    //  Why this exists. HPDCACHE only ever acts on a read response — and on the
    //  invalidation payload riding it — inside
    //
    //      if (mem_resp_read_valid_i) ... mem_resp_read_miss_valid = 1'b1;  (hpdcache.sv)
    //
    //  The previous code waved `inval_valid_i` at `dcache_resp_read_inval` while
    //  tying `inval_ready_o = 1'b1`: it claimed unconditional acceptance for a path
    //  that only landed if a genuine read response happened to be valid in the very
    //  same cycle. An observer that is NOT missing in its D$ — the common case for a
    //  hart spinning on a flag it already cached — has no read response in flight, so
    //  its invalidation was acknowledged and silently discarded and it span on stale
    //  data forever. Reproduced with a one-variable control (see
    //  architecture/multi-core/README.md): with D$ load allocation on, hart 0 never
    //  observes hart 1's store (code 9 at 320416 cycles) where the uncached arm sees
    //  it in 6449.
    //
    //  Injecting a response cycle is legitimate, not a hack: an invalidation-only
    //  response is a first-class case in the miss handler — it is how the
    //  OpenPiton/L15 port delivers invalidations at all. `hpdcache_miss_handler.sv`
    //  writes the metadata FIFO on `mem_resp_inval_i` regardless of `r_last`,
    //  explicitly does NOT write the data FIFO (`& ~mem_resp_inval_i`), derives
    //  `mem_resp_ready_o` from metadata space alone, and in REFILL_IDLE takes
    //  `is_inval` to REFILL_INVAL without touching the MSHR (`mshr_ack = ~is_inval`).
    //  So the injected cycle needs no data, no `r_last` and no MSHR entry.
    //
    //  An invalidation must OWN its cycle: `is_inval` diverts the FSM to REFILL_INVAL
    //  instead of refilling, so piggybacking it on a real response would DROP that
    //  refill. Hence `inv_inject` is qualified with `~axi_rresp_valid` and a real
    //  response always wins the channel.
    //
    //  `inval_ready_o` now reports real occupancy, so the inval bus holds the request
    //  instead of losing it — one entry suffices precisely because the producer is
    //  back-pressured rather than lied to.
    //
    //  Timing: one 2:1 mux on the read-response valid/inval fields plus one flop and
    //  an nline register; no change to the response data path.
    assign noc_inval_valid = 1'b0;
    assign noc_inval_nline = '0;

    //  Retention extracted into g6lc_inval_retain so its contract can be unit
    //  tested: the overflow path is unreachable from software (the upstream inval
    //  bus buffers per core, so the slot never filled in any full-core test), and
    //  an end-to-end pass cannot tell a retention that fills and drains correctly
    //  from one that never fills at all.
    g6lc_inval_retain #(
        .nline_t(hpdcache_nline_t),
        .DEPTH  (1)
    ) i_inval_retain (
        .clk_i,
        .rst_ni,
        .inval_valid_i (inval_valid_i),
        .inval_nline_i (
            hpdcache_nline_t'(inval_addr_i[HPDC_LINE_OFF +: HPDcacheCfg.nlineWidth])),
        .inval_ready_o (inval_ready_o),
        .resp_valid_i  (axi_rresp_valid),
        .resp_ready_i  (dcache_read_resp_ready),
        .inject_o      (inv_inject),
        .inject_nline_o(ext_inv_nline_q),
        .evt_injected_o     (inv_evt_injected),
        .evt_backpressured_o(inv_evt_backpressured)
    );

    assign ext_inval_valid = inv_inject;
    assign ext_inval_nline = ext_inv_nline_q;

    assign dcache_read_resp_valid       = axi_rresp_valid | inv_inject;
    assign dcache_read_resp             = axi_rresp;
    assign dcache_resp_read_inval       = inv_inject;
    assign dcache_resp_read_inval_nline = ext_inv_nline_q;

    //  Never let the arbiter see an acknowledge for a cycle we stole.
    assign axi_rresp_ready = dcache_read_resp_ready & ~inv_inject;

    //  Sim-only observation of this retention, because the end-to-end test alone
    //  cannot distinguish a retention that fills and drains correctly from one that
    //  never fills at all — both would pass identically. `injected` counts
    //  invalidations actually delivered on a stolen response cycle; `backpressured`
    //  counts cycles where the producer was held off because the slot was full,
    //  which is the only direct evidence the one-entry depth is ever exercised.
    //pragma translate_off
    // verilog_lint: waive always-ff-non-reset
    int unsigned inv_injected_cnt = 0;
    int unsigned inv_backpressured_cnt = 0;
    always_ff @(posedge clk_i) begin : ext_inval_observe
      if (rst_ni) begin
        if (inv_evt_injected) inv_injected_cnt <= inv_injected_cnt + 1;
        if (inv_evt_backpressured) inv_backpressured_cnt <= inv_backpressured_cnt + 1;
      end
    end
    final begin
      $display("[hpdc_inv] injected=%0d backpressured=%0d", inv_injected_cnt,
               inv_backpressured_cnt);
    end
    //pragma translate_on
  end

  //  I$/D$ memory-id partitioning — ELABORATION guard, not simulation-only.
  //
  //  The read-response demux in cva6_hpdcache_subsystem_axi_arbiter routes purely
  //  by id: `mem_resp_read_rt[i] = (i == icache_miss_id_i) ? 0 : 1`, i.e. the
  //  response whose id equals ICACHE_RDTXID goes to the I$ and everything else to
  //  the D$. ICACHE_RDTXID is {1'b1, 0...} — the MSB of MEM_TID_WIDTH — so the
  //  scheme is only safe while every D$ id stays below that bit. D$ miss ids are
  //  {mshr_alloc_way, mshr_set}, which is why the bound is
  //  clog2(mshrSets*mshrWays) + 1.
  //
  //  Violate it and a D$ refill carries the I$'s id: its response is delivered to
  //  the instruction cache, the load never completes, and the core hangs with no
  //  error anywhere. That is a silent routing defect of exactly the kind this
  //  review has been repairing elsewhere (the Ara/core AXI mux routed responses by
  //  an identifier that was not exclusive either).
  //
  //  The same condition was already checked below, but inside `pragma
  //  translate_off` — so a configuration that violates it SYNTHESIZES and only
  //  complains in simulation. Promoted here to a generate-scope $error, matching
  //  the treatment given to the OoO hart/FP legality guards, so such a
  //  configuration cannot be built at all.
  //
  //  Note the current margin is zero, not comfortable: g6lc64_stream8 has
  //  NrLoadBufEntries=8 -> mshrSets*mshrWays = 8 -> requires MEM_TID_WIDTH >= 4 and
  //  supplies exactly 4. Raising NrLoadBufEntries to 16 would need 5 and, without
  //  this guard, would have aliased silently.
  if (CVA6Cfg.MEM_TID_WIDTH <
      ($clog2(HPDcacheCfg.u.mshrSets * HPDcacheCfg.u.mshrWays) + 1)) begin : gen_err_memtid_miss
    $error("MEM_TID_WIDTH too small: D$ miss ids would alias ICACHE_RDTXID and the ",
           "arbiter would deliver D$ refills to the I$");
  end
  //  G6LC T16: the MSHR is indexed by nline[0 +: clog2(sets)] and the slot id is
  //  {way, set}; both silently alias unless sets and ways are powers of two.
  if (((HPDcacheCfg.u.mshrSets & (HPDcacheCfg.u.mshrSets - 1)) != 0) ||
      ((HPDcacheCfg.u.mshrWays & (HPDcacheCfg.u.mshrWays - 1)) != 0)) begin : gen_err_mshr_geometry
    $error("HPDcache MSHR sets/ways must be powers of two: a non-power-of-two set ",
           "count lets nline index a set that does not exist and misroutes refills");
  end
  if (CVA6Cfg.MEM_TID_WIDTH < ($clog2(HPDcacheCfg.u.wbufDirEntries) + 1)) begin : gen_err_memtid_wbuf
    $error("MEM_TID_WIDTH too small: D$ write ids would alias ICACHE_RDTXID");
  end
  if (CVA6Cfg.MEM_TID_WIDTH > CVA6Cfg.AxiIdWidth) begin : gen_err_memtid_axi
    $error("MEM_TID_WIDTH exceeds AxiIdWidth: ids would be truncated on the AXI port");
  end

  //  Assertions
  //  {{{
  //  pragma translate_off
  initial begin : initial_assertions
    assert (HPDcacheCfg.u.reqSrcIdWidth >= $clog2(HPDcacheCfg.u.nRequesters))
    else $fatal(1, "HPDCACHE_REQ_SRC_ID_WIDTH is not wide enough");
    assert (CVA6Cfg.MEM_TID_WIDTH >= ($clog2(HPDcacheCfg.u.mshrSets * HPDcacheCfg.u.mshrWays) + 1))
    else $fatal(1, "MEM_TID_WIDTH shall allow to uniquely identify all D$ and I$ miss requests ");
    assert (CVA6Cfg.MEM_TID_WIDTH >= ($clog2(HPDcacheCfg.u.wbufDirEntries) + 1))
    else $fatal(1, "MEM_TID_WIDTH shall allow to uniquely identify all D$ write requests ");
    assert (CVA6Cfg.MEM_TID_WIDTH <= CVA6Cfg.AxiIdWidth)
    else $fatal(1, "MEM_TID_WIDTH shall be less or equal to the AxiIdWidth");
  end

  a_invalid_instruction_fetch :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) icache_dreq_o.valid |-> (|icache_dreq_o.data) !== 1'hX)
  else
    $warning(
        1,
        "[l1 dcache] reading invalid instructions: vaddr=%08X, data=%08X",
        icache_dreq_o.vaddr,
        icache_dreq_o.data
    );

  a_invalid_write_data :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) dcache_req_ports_i[2].data_req |-> |dcache_req_ports_i[2].data_be |-> (|dcache_req_ports_i[2].data_wdata) !== 1'hX)
  else
    $warning(
        1,
        "[l1 dcache] writing invalid data: paddr=%016X, be=%02X, data=%016X",
        {
          dcache_req_ports_i[2].address_tag, dcache_req_ports_i[2].address_index
        },
        dcache_req_ports_i[2].data_be,
        dcache_req_ports_i[2].data_wdata
    );

  for (genvar j = 0; j < 2; j++) begin : gen_assertion
    a_invalid_read_data :
    assert property (
      @(posedge clk_i) disable iff (!rst_ni) dcache_req_ports_o[j].data_rvalid && ~dcache_req_ports_i[j].kill_req |-> (|dcache_req_ports_o[j].data_rdata) !== 1'hX)
    else
      $warning(
          1,
          "[l1 dcache] reading invalid data on port %01d: data=%016X",
          j,
          dcache_req_ports_o[j].data_rdata
      );
  end
  //  pragma translate_on
  //  }}}

endmodule : cva6_hpdcache_subsystem
