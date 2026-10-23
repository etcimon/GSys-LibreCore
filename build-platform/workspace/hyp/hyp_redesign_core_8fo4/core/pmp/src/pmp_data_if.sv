// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
//-----------------------------------------------------------------------------
// Copyright 2024 Robert Bosch GmbH
//
// SPDX-License-Identifier: SHL-0.51
//
// Original Author: Coralie Allioux - Robert Bosch France SAS
//-----------------------------------------------------------------------------

module pmp_data_if
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg       = config_pkg::g6lc_cfg_empty,
    parameter type                   icache_areq_t = logic,
    parameter type                   exception_t   = logic,
    // Data-side verdict presentation. 0 = the reference one-cycle MMU
    // contract: combinational pass-through plus a same-cycle data PMP
    // verdict (the LSU's store_unit/load_unit consume lsu_paddr_o and
    // lsu_exception_o in the request cycle; they do not wait on
    // lsu_valid_o). 2 = the hyp8 staged variant, which delays the
    // response fields two edges so they land with the pmp's registered
    // verdict — legal ONLY for consumers that hold their request, wait
    // on lsu_valid_o, and route the delayed response by requester,
    // which the current LSU does not do.
    parameter int unsigned           DATA_VERDICT_STAGES = 0
) (
    input logic clk_i,
    input logic rst_ni,
    // IF interface
    input icache_areq_t icache_areq_i,
    output icache_areq_t icache_areq_o,
    input [G6LCCfg.VLEN-1:0] icache_fetch_vaddr_i,  // current request vaddr (tval + response currency key)
    // LSU interface
    // this is a more minimalistic interface because the actual addressing logic is handled
    // in the LSU as we distinguish load and stores, what we do here is simple address translation
    input logic lsu_valid_i,  // request lsu access
    input logic [G6LCCfg.PLEN-1:0] lsu_paddr_i,  // physical address in
    input logic [G6LCCfg.VLEN-1:0] lsu_vaddr_i,  // virtual address in, for tval only
    input exception_t lsu_exception_i,  // lsu exception coming from MMU, or misaligned exception
    input logic lsu_is_store_i,  // the translation is requested by a store
    output logic lsu_valid_o,  // translation is valid
    output logic [G6LCCfg.PLEN-1:0] lsu_paddr_o,  // translated address
    output exception_t lsu_exception_o,  // address translation threw an exception
    // General control signals
    input riscv::priv_lvl_t priv_lvl_i,
    input logic v_i,
    input riscv::priv_lvl_t ld_st_priv_lvl_i,
    input logic ld_st_v_i,
    // PMP (load/store request hart's context — T6b-2b)
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] pmpcfg_i,
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] pmpaddr_i,
    // PMP (fetch hart's context — identical values under NrHarts==1 or
    // SmtDrainedHandoff)
    input riscv::pmpcfg_t [avoid_neg(G6LCCfg.NrPMPEntries-1):0] fet_pmpcfg_i,
    input logic [avoid_neg(G6LCCfg.NrPMPEntries-1):0][G6LCCfg.PLEN-3:0] fet_pmpaddr_i
);
  logic pmp_if_allow;
  logic data_allow_o;

  // Wires to PMP checks
  riscv::pmp_access_t pmp_access_type;

  logic no_locked_data, no_locked_if;

  //-----------------------
  // Instruction Interface
  //-----------------------

  // hyp8: the fetch areq record is registered so it stays aligned with the
  // PMP's own registered request boundary — the verdict (and the PMA
  // execute-region check) is applied at the verdict cycle, one after the
  // request is presented (H15: no fetch side effect before the verdict).
  icache_areq_t if_req_q;
  logic [G6LCCfg.VLEN-1:0] if_fetch_vaddr_q;
  logic                  if_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_if_req
    if (~rst_ni) begin
      if_req_q         <= '0;
      if_fetch_vaddr_q <= '0;
      if_v_q           <= 1'b0;
    end else begin
      if_req_q         <= icache_areq_i;
      if_fetch_vaddr_q <= icache_fetch_vaddr_i;
      if_v_q           <= v_i;
    end
  end

  // check for execute flag on memory — evaluate the registered address so
  // the PMA decode shares the PMP verdict cycle
  logic match_any_execute_region_q;
  assign match_any_execute_region_q = config_pkg::is_inside_execute_regions(
      G6LCCfg, {{64 - G6LCCfg.PLEN{1'b0}}, if_req_q.fetch_paddr}
  );

  // hyp8: the standing response is presented only while it still answers
  // the address on the request pins. if_req_q snapshots the MMU/PMA reply
  // every cycle, so on a request change (the READ_V W1-overlap accept is
  // the in-window case) it can still hold the previous request's verdict;
  // an early-READ consumer would stitch that stale tag onto the new
  // index — the I$ issued a refill one page down at a 4K crossing
  // (vaq=0x80013000 -> AR=0x80012000). The request vaddr is already
  // registered beside the response, so the key costs one compare.
  logic if_rsp_current;
  assign if_rsp_current = (if_fetch_vaddr_q == icache_fetch_vaddr_i);

  logic [G6LCCfg.XLEN-1:0] if_fetch_vaddr_xlen;
  always_comb begin : instr_interface
    icache_areq_o.fetch_valid     = if_req_q.fetch_valid && if_rsp_current;
    icache_areq_o.fetch_paddr     = if_req_q.fetch_paddr;
    icache_areq_o.fetch_exception = if_req_q.fetch_exception;

    // if it didn't match any execute region throw an `Instruction Access Fault` (PMA)
    // or if PMP reject the access
    // Per RISCV privilege spec, a page fault has higher priority than access
    // fault, therefore do not change the exception type in case of double
    // exception
    if (if_req_q.fetch_valid && if_rsp_current) begin
      if (icache_areq_o.fetch_exception.cause != riscv::INSTR_PAGE_FAULT) begin
        if (!match_any_execute_region_q || !pmp_if_allow) begin
          icache_areq_o.fetch_exception.cause = riscv::INSTR_ACCESS_FAULT;
          icache_areq_o.fetch_exception.valid = 1'b1;
          // For exception, the virtual address is required for tval, if no MMU is
          // instantiated then it will be equal to physical address
          if (G6LCCfg.TvalEn) begin
            icache_areq_o.fetch_exception.tval = if_fetch_vaddr_xlen;
          end
          if (G6LCCfg.RVH) begin
            icache_areq_o.fetch_exception.tval2 = '0;
            icache_areq_o.fetch_exception.tinst = '0;
            icache_areq_o.fetch_exception.gva   = if_v_q;
          end
        end
      end
    end
  end

  if (G6LCCfg.VLEN >= G6LCCfg.XLEN) begin
    assign if_fetch_vaddr_xlen = if_fetch_vaddr_q[G6LCCfg.XLEN-1:0];
  end else begin
    assign if_fetch_vaddr_xlen = G6LCCfg.XLEN'(if_fetch_vaddr_q);
  end

  // Instruction fetch — the pmp registers these inputs internally; the
  // verdict lands with if_req_q.
  pmp #(
      .G6LCCfg(G6LCCfg)
  ) i_pmp_if (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .addr_i       (icache_areq_i.fetch_paddr),
      .priv_lvl_i   (priv_lvl_i),
      // we will always execute on the instruction fetch port
      .access_type_i(riscv::ACCESS_EXEC),
      // Configuration — fetch hart's PMP (T6b-2b)
      .conf_addr_i  (fet_pmpaddr_i),
      .conf_i       (fet_pmpcfg_i),
      .allow_o      (pmp_if_allow)
  );

  //-----------------------
  // Data Interface
  //-----------------------
  if (DATA_VERDICT_STAGES == 0) begin : gen_data_comb
    // Reference one-cycle MMU contract: the LSU presents the request and
    // consumes lsu_paddr_o / lsu_exception_o in the same cycle
    // (store_unit decides on dtlb_hit_i in IDLE and posts paddr_to_sb
    // one cycle later). lsu_valid_o is a pass-through, not a response
    // handshake; the data PMP verdict is combinational on the live
    // request (REG_VERDICT=0 instance).
    logic [G6LCCfg.XLEN-1:0] lsu_vaddr_xlen;
    if (G6LCCfg.VLEN >= G6LCCfg.XLEN) begin
      assign lsu_vaddr_xlen = lsu_vaddr_i[G6LCCfg.XLEN-1:0];
    end else begin
      assign lsu_vaddr_xlen = G6LCCfg.XLEN'(lsu_vaddr_i);
    end

    always_comb begin : data_interface
      lsu_valid_o     = lsu_valid_i;
      lsu_paddr_o     = lsu_paddr_i;
      lsu_exception_o = lsu_exception_i;
      pmp_access_type = lsu_is_store_i ? riscv::ACCESS_WRITE : riscv::ACCESS_READ;

      // If translation is not enabled, check the paddr immediately against PMPs
      if (lsu_valid_i && !data_allow_o) begin
        lsu_exception_o.valid = 1'b1;

        if (G6LCCfg.TvalEn) begin
          lsu_exception_o.tval = lsu_vaddr_xlen;
        end

        if (lsu_is_store_i) begin
          lsu_exception_o.cause = riscv::ST_ACCESS_FAULT;
        end else begin
          lsu_exception_o.cause = riscv::LD_ACCESS_FAULT;
        end
        if (G6LCCfg.RVH) begin
          lsu_exception_o.tval2 = '0;
          lsu_exception_o.tinst = '0;
          lsu_exception_o.gva   = ld_st_v_i;
        end
      end
    end

    // Load/store PMP check — combinational verdict on the live request.
    pmp #(
        .G6LCCfg     (G6LCCfg),
        .REG_VERDICT (1'b0)
    ) i_pmp_data (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .addr_i       (lsu_paddr_i),
        .priv_lvl_i   (ld_st_priv_lvl_i),
        .access_type_i(pmp_access_type),
        // Configuration
        .conf_addr_i  (pmpaddr_i),
        .conf_i       (pmpcfg_i),
        .allow_o      (data_allow_o)
    );
  end else if (DATA_VERDICT_STAGES == 2) begin : gen_data_staged
    // hyp8: the data-side PMP verdict is applied at the T3 verdict cycle —
    // the request record is registered once to present a stable address to
    // the pmp (req_q), the pmp's own boundary registers it again, and a
    // second request stage (req2_q) holds the response fields until
    // data_allow_o lands (H15: no side effect before the verdict). This
    // mode REQUIRES consumers that hold their request, wait on
    // lsu_valid_o, and route the delayed response by requester — the
    // current LSU does not do that (it consumes paddr/exception in the
    // request cycle), so this mode is preserved but unqualified.
    logic                    lsu_req_valid_q;
    logic [G6LCCfg.PLEN-1:0] lsu_req_paddr_q;
    logic [G6LCCfg.VLEN-1:0] lsu_req_vaddr_q;
    exception_t              lsu_req_exception_q;
    logic                    lsu_req_is_store_q;
    riscv::priv_lvl_t        lsu_req_priv_q;
    logic                    lsu_req_v_q;
    logic                    lsu_req2_valid_q;
    logic [G6LCCfg.PLEN-1:0] lsu_req2_paddr_q;
    logic [G6LCCfg.VLEN-1:0] lsu_req2_vaddr_q;
    exception_t              lsu_req2_exception_q;
    logic                    lsu_req2_is_store_q;
    logic                    lsu_req2_v_q;
    logic [G6LCCfg.XLEN-1:0] lsu_req2_vaddr_xlen;
    if (G6LCCfg.VLEN >= G6LCCfg.XLEN) begin
      assign lsu_req2_vaddr_xlen = lsu_req2_vaddr_q[G6LCCfg.XLEN-1:0];
    end else begin
      assign lsu_req2_vaddr_xlen = G6LCCfg.XLEN'(lsu_req2_vaddr_q);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_lsu_req
      if (~rst_ni) begin
        lsu_req_valid_q <= 1'b0;
        lsu_req_paddr_q <= '0;
        lsu_req_vaddr_q <= '0;
        lsu_req_exception_q <= '0;
        lsu_req_is_store_q  <= 1'b0;
        lsu_req_priv_q      <= riscv::PRIV_LVL_M;
        lsu_req_v_q         <= 1'b0;
        lsu_req2_valid_q    <= 1'b0;
        lsu_req2_paddr_q    <= '0;
        lsu_req2_vaddr_q    <= '0;
        lsu_req2_exception_q <= '0;
        lsu_req2_is_store_q <= 1'b0;
        lsu_req2_v_q        <= 1'b0;
      end else begin
        lsu_req_valid_q     <= lsu_valid_i;
        lsu_req_paddr_q     <= lsu_paddr_i;
        lsu_req_vaddr_q     <= lsu_vaddr_i;
        lsu_req_exception_q <= lsu_exception_i;
        lsu_req_is_store_q  <= lsu_is_store_i;
        lsu_req_priv_q      <= ld_st_priv_lvl_i;
        lsu_req_v_q         <= ld_st_v_i;
        // T3 verdict-cycle stage, aligned with the pmp's registered verdict
        lsu_req2_valid_q    <= lsu_req_valid_q;
        lsu_req2_paddr_q    <= lsu_req_paddr_q;
        lsu_req2_vaddr_q    <= lsu_req_vaddr_q;
        lsu_req2_exception_q <= lsu_req_exception_q;
        lsu_req2_is_store_q <= lsu_req_is_store_q;
        lsu_req2_v_q        <= lsu_req_v_q;
      end
    end

    always_comb begin : data_interface
      // T2-registered request + T3 PMP verdict applied at the verdict cycle
      lsu_valid_o     = lsu_req2_valid_q;
      lsu_paddr_o     = lsu_req2_paddr_q;
      lsu_exception_o = lsu_req2_exception_q;
      pmp_access_type = lsu_req_is_store_q ? riscv::ACCESS_WRITE : riscv::ACCESS_READ;

      // If translation is not enabled, check the paddr immediately against PMPs
      if (lsu_req2_valid_q && !data_allow_o) begin
        lsu_exception_o.valid = 1'b1;

        if (G6LCCfg.TvalEn) begin
          lsu_exception_o.tval = lsu_req2_vaddr_xlen;
        end

        if (lsu_req2_is_store_q) begin
          lsu_exception_o.cause = riscv::ST_ACCESS_FAULT;
        end else begin
          lsu_exception_o.cause = riscv::LD_ACCESS_FAULT;
        end
        if (G6LCCfg.RVH) begin
          lsu_exception_o.tval2 = '0;
          lsu_exception_o.tinst = '0;
          lsu_exception_o.gva   = lsu_req2_v_q;
        end
      end
    end

    // Load/store PMP check — the pmp registers the req_q fields internally;
    // its verdict lands with req2_q.
    pmp #(
        .G6LCCfg(G6LCCfg)
    ) i_pmp_data (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .addr_i       (lsu_req_paddr_q),
        .priv_lvl_i   (lsu_req_priv_q),
        .access_type_i(pmp_access_type),
        // Configuration
        .conf_addr_i  (pmpaddr_i),
        .conf_i       (pmpcfg_i),
        .allow_o      (data_allow_o)
    );
  end else begin : gen_data_bad_stages
    $error("pmp_data_if: DATA_VERDICT_STAGES must be 0 or 2");
  end

  // ----------------
  // Assert for PMPs
  // ----------------

  // synthesis translate_off
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      no_locked_data <= 1'b0;
    end else begin
      if (ld_st_priv_lvl_i == riscv::PRIV_LVL_M) begin
        no_locked_data <= 1'b1;
        for (int i = 0; i < G6LCCfg.NrPMPEntries; i++) begin
          if (pmpcfg_i[i].locked && pmpcfg_i[i].addr_mode != riscv::OFF) begin
            no_locked_data <= no_locked_data & 1'b0;
          end else no_locked_data <= no_locked_data & 1'b1;
        end
        if (no_locked_data == 1'b1) assert (data_allow_o == 1'b1);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      no_locked_if <= 1'b0;
    end else begin
      if (priv_lvl_i == riscv::PRIV_LVL_M) begin
        no_locked_if <= 1'b1;
        for (int i = 0; i < G6LCCfg.NrPMPEntries; i++) begin
          if (fet_pmpcfg_i[i].locked && fet_pmpcfg_i[i].addr_mode != riscv::OFF) begin
            no_locked_if <= no_locked_if & 1'b0;
          end else no_locked_if <= no_locked_if & 1'b1;
        end
        if (no_locked_if == 1'b1) assert (pmp_if_allow == 1'b1);
      end
    end
  end
  // synthesis translate_on
endmodule
