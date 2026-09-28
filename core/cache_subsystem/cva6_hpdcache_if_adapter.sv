// Copyright 2023 Commissariat a l'Energie Atomique et aux Energies
//                Alternatives (CEA)
//
// Licensed under the Solderpad Hardware License, Version 2.1 (the “License”);
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Authors: Cesar Fuguet
// Modified by: Etienne Cimon
// Date: February, 2023
// Description: Interface adapter for the CVA6 core
module cva6_hpdcache_if_adapter
//  Parameters
//  {{{
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter hpdcache_pkg::hpdcache_cfg_t HPDcacheCfg = '0,
    parameter type hpdcache_tag_t = logic,
    parameter type hpdcache_req_offset_t = logic,
    parameter type hpdcache_req_sid_t = logic,
    parameter type hpdcache_req_t = logic,
    parameter type hpdcache_rsp_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter bit InvalidateOnFlush = 1'b0,
    parameter bit IsLoadPort = 1'b1
)
//  }}}

//  Ports
//  {{{
(
    //  Clock and active-low reset pins
    input logic clk_i,
    input logic rst_ni,

    //  Port ID
    input hpdcache_req_sid_t hpdcache_req_sid_i,

    //  Request/response ports from/to the CVA6 core
    input  dcache_req_i_t         cva6_req_i,
    output dcache_req_o_t         cva6_req_o,
    input  ariane_pkg::amo_req_t  cva6_amo_req_i,
    output ariane_pkg::amo_resp_t cva6_amo_resp_o,

    //  Dcache flush signal
    input  logic cva6_dcache_flush_i,
    output logic cva6_dcache_flush_ack_o,

    //  Request port to the L1 Dcache
    output logic                        hpdcache_req_valid_o,
    input  logic                        hpdcache_req_ready_i,
    output hpdcache_req_t               hpdcache_req_o,
    output logic                        hpdcache_req_abort_o,
    output hpdcache_tag_t               hpdcache_req_tag_o,
    output hpdcache_pkg::hpdcache_pma_t hpdcache_req_pma_o,

    //  Response port from the L1 Dcache
    input logic          hpdcache_rsp_valid_i,
    input hpdcache_rsp_t hpdcache_rsp_i,

    // T9a eWT CMO sideband (store port only; tie ready/done 0, leave valid
    // open on load adapters). A line CMO (cbo_op inval/clean/flush) still
    // goes into HPDCACHE — it invalidates/flushes the L1 line — but its
    // response is HELD until the cluster engine reports done.
    output logic                        cmo_valid_o,
    output logic [1:0]                  cmo_op_o,
    output logic [CVA6Cfg.PLEN-1:0]     cmo_addr_o,
    input  logic                        cmo_ready_i,
    input  logic                        cmo_done_i
);
  //  }}}

  //  Internal nets and registers
  //  {{{
  typedef enum {
    FLUSH_IDLE,
    FLUSH_PEND
  } flush_fsm_t;

  logic hpdcache_req_is_uncacheable;
  hpdcache_req_t hpdcache_req;
  //  }}}

  //  Request forwarding
  //  {{{
  generate
    //  LOAD request
    //  {{{
    if (IsLoadPort == 1'b1) begin : load_port_gen
      // S4: D$ loads of execute-region .text are uncached. 2jr hang is
      // HPD HIT of a jtab line I$ already holds (lw@0x90 and jtab@0xa8
      // share 64 B line 0x80; 2jr_fencei / 2jr_pad / 2jr_data PASS).
      // I$/D$ nline stalls negative. Full paddr at tag time. Timing:
      // extra execute PMA compares on the load-pma cone; no new flop.
      // Etienne Cimon 2026.
      logic [63:0] load_paddr;
      assign load_paddr = {
        {64 - CVA6Cfg.DCACHE_TAG_WIDTH - CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}},
        cva6_req_i.address_tag,
        cva6_req_i.address_index
      };
      // The execute-region term is GONE, and that is a deliberate reversal of the
      // S4 workaround described above. It excluded every load inside an execute
      // region from D$ allocation — and since ExecuteRegion[0] equals
      // CachedRegion[0] on every HPDCACHE configuration, that disabled L1 D$ load
      // allocation for ALL of DRAM.
      //
      // The "2jr hang" it was avoiding was not a cache hazard at all: it was a
      // FALSE assertion in the bind-attached frontend checker. `kill_s1` is driven
      // from replay_q (frontend.sv:820) while the checker was passed the
      // combinational replay, so one cycle after replay dropped a legal
      // replay-kill tripped "kill_s1 outside misp|flush|replay". Fixed in
      // core/fetch_B/g6lc_fetch_dbg.sv by binding .replay_i(replay_q).
      //
      // Three-arm evidence, g6lc64_stream8 flavour B, arms differing only as
      // stated (architecture/multi-core/README.md):
      //   exclusion ON                    2jr / _pad / _data PASS 534/491/501 cy
      //   exclusion OFF, checker as-was   all three trip the assertion
      //   exclusion OFF, checker fixed    all three PASS 545/497/519 cy
      // mc_boot_sanity passes at 359 cycles in all three arms, so the arms are
      // otherwise equivalent.
      //
      // G6LC_DCACHE_EXEC_UNCACHED restores the old behaviour for bisection.
`ifdef G6LC_DCACHE_EXEC_UNCACHED
      assign hpdcache_req_is_uncacheable =
          !config_pkg::is_inside_cacheable_regions(CVA6Cfg, load_paddr) ||
          config_pkg::is_inside_execute_regions(CVA6Cfg, load_paddr);
`else
      assign hpdcache_req_is_uncacheable =
          !config_pkg::is_inside_cacheable_regions(CVA6Cfg, load_paddr);
`endif

      //    Request forwarding
      assign hpdcache_req_valid_o = cva6_req_i.data_req;
      assign hpdcache_req.addr_offset = cva6_req_i.address_index;
      assign hpdcache_req.wdata = '0;
      assign hpdcache_req.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
      assign hpdcache_req.be = cva6_req_i.data_be;
      assign hpdcache_req.size = hpdcache_pkg::hpdcache_req_size_t'(cva6_req_i.data_size);
      assign hpdcache_req.sid = hpdcache_req_sid_i;
      assign hpdcache_req.tid = cva6_req_i.data_id;
      assign hpdcache_req.need_rsp = 1'b1;
      assign hpdcache_req.phys_indexed = 1'b0;
      assign hpdcache_req.addr_tag = '0;  // unused on virtually indexed request
      assign hpdcache_req.pma.uncacheable = 1'b0;
      assign hpdcache_req.pma.io = 1'b0;
      assign hpdcache_req.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      assign hpdcache_req_abort_o = cva6_req_i.kill_req;
      assign hpdcache_req_tag_o = cva6_req_i.address_tag;
      assign hpdcache_req_pma_o.uncacheable = hpdcache_req_is_uncacheable;
      assign hpdcache_req_pma_o.io = 1'b0;
      assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;

      //    Response forwarding
      assign cva6_req_o.data_rvalid = hpdcache_rsp_valid_i;
      assign cva6_req_o.data_rdata = hpdcache_rsp_i.rdata;
      assign cva6_req_o.data_rid = hpdcache_rsp_i.tid;
      assign cva6_req_o.data_gnt = hpdcache_req_ready_i;
      // CMO sideband is a store-port facility
      assign cmo_valid_o = 1'b0;
      assign cmo_op_o    = '0;
      assign cmo_addr_o  = '0;
      logic unused_cmo_ld;
      assign unused_cmo_ld = cmo_ready_i | cmo_done_i;

      //  Assertions
      //  {{{
      //    pragma translate_off
      flush_on_load_port_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) (cva6_dcache_flush_i == 1'b0))
      else $error("Flush unsupported on load adapters");
      //    pragma translate_on
      //  }}}
    end  //  }}}

         //  {{{
    else begin : store_amo_gen
      //  STORE/AMO request
      logic                 [63:0] amo_addr;
      hpdcache_req_offset_t        amo_addr_offset;
      hpdcache_tag_t               amo_tag;
      logic amo_is_word, amo_is_word_hi;
      logic                           [63:0] amo_data;
      logic                           [ 7:0] amo_data_be;
      hpdcache_pkg::hpdcache_req_op_t        amo_op;
      logic                           [31:0] amo_resp_word;
      logic                                  amo_pending_q;

      hpdcache_req_t                         hpdcache_req_amo;
      hpdcache_req_t                         hpdcache_req_store;
      hpdcache_req_t                         hpdcache_req_flush;
      hpdcache_req_t                         hpdcache_req_casd;

      flush_fsm_t flush_fsm_q, flush_fsm_d;

      logic forward_store, forward_amo, forward_flush, forward_casd;
      hpdcache_pkg::hpdcache_req_op_t store_op;

      // T9a eWT CMO response hold — state (logic is below the CAS.D FSM)
      logic                    cmo_pend_q, cmo_pend_d;
      logic                    cmo_sb_gnt_q, cmo_sb_gnt_d;
      logic                    cmo_served_q, cmo_served_d;
      logic                    cmo_rsp_seen_q, cmo_rsp_seen_d;
      logic                    cmo_done_seen_q, cmo_done_seen_d;
      logic [CVA6Cfg.PLEN-1:0] cmo_addr_q, cmo_addr_d;
      logic [1:0]              cmo_op_q, cmo_op_d;

      // AMOCAS.D: 64b expected + 64b swap cannot fit in one req wdata.
      // Local RMW in the adapter (same spirit as wt_dcache_missunit AMO_CAS_*).
      typedef enum logic [3:0] {
        CASD_IDLE,
        CASD_LD,
        CASD_LD_WAIT,
        CASD_LD_HI,
        CASD_LD_HI_WAIT,
        CASD_ST,
        CASD_ST_WAIT,
        CASD_ST_HI,
        CASD_ST_HI_WAIT,
        CASD_INVAL,
        CASD_INVAL_WAIT,
        CASD_DONE
      } casd_fsm_e;
      casd_fsm_e casd_fsm_q, casd_fsm_d;
      logic [63:0] casd_old_q, casd_old_d;
      logic [63:0] casd_old_hi_q, casd_old_hi_d;
      logic        casd_do_store_q, casd_do_store_d;
      logic        casd_is_quad_q, casd_is_quad_d;
      logic        is_casd_req;
      logic        casd_busy;

      //  DCACHE flush request
      //  {{{
      always_ff @(posedge clk_i or negedge rst_ni) begin : flush_ff
        if (!rst_ni) begin
          flush_fsm_q <= FLUSH_IDLE;
        end else begin
          flush_fsm_q <= flush_fsm_d;
        end
      end

      always_comb begin : flush_comb
        forward_flush = 1'b0;
        cva6_dcache_flush_ack_o = 1'b0;

        flush_fsm_d = flush_fsm_q;

        case (flush_fsm_q)
          FLUSH_IDLE: begin
            // T9a: hold off a pipeline flush while a CMO response is being
            // held — the flush's tid='0 response would otherwise be
            // swallowed at the rvalid seam and the flush would never ack.
            if (cva6_dcache_flush_i && !cmo_pend_q) begin
              forward_flush = 1'b1;
              if (hpdcache_req_ready_i) begin
                flush_fsm_d = FLUSH_PEND;
              end
            end
          end
          FLUSH_PEND: begin
            if (hpdcache_rsp_valid_i) begin
              if (hpdcache_rsp_i.tid == '0) begin
                cva6_dcache_flush_ack_o = 1'b1;
                flush_fsm_d = FLUSH_IDLE;
              end
            end
          end
          default: begin
          end
        endcase
      end
      //  }}}

      // CBO logic
      //  {{{
      always_comb begin : store_cmo_comb
        store_op = hpdcache_pkg::HPDCACHE_REQ_STORE;

        if (CVA6Cfg.RVZiCbom || CVA6Cfg.RVZiCboz) begin
          case (cva6_req_i.cbo_op)
            ariane_pkg::CBO_INVAL: store_op = hpdcache_pkg::HPDCACHE_REQ_CMO_INVAL_NLINE;
            ariane_pkg::CBO_CLEAN: store_op = hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_NLINE;
            ariane_pkg::CBO_FLUSH: store_op = hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_NLINE;
            // Zicboz: the store buffer drains a committed cbo.zero as
            // full-line zero STORE beats (line-aligned, each tagged
            // CBO_ZERO). Plain STORE updates memory for memcpy/memset.
            ariane_pkg::CBO_ZERO:  store_op = hpdcache_pkg::HPDCACHE_REQ_STORE;
            default: ;  // store - above
          endcase
        end
      end
      //  }}}


      //  AMO logic
      //  {{{
      always_comb begin : amo_op_comb
        amo_addr = cva6_amo_req_i.operand_a;
        amo_addr_offset = amo_addr[0+:HPDcacheCfg.reqOffsetWidth];
        amo_tag = amo_addr[HPDcacheCfg.reqOffsetWidth+:HPDcacheCfg.tagWidth];
        unique case (cva6_amo_req_i.amo_op)
          ariane_pkg::AMO_LR:   amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_LR;
          ariane_pkg::AMO_SC:   amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_SC;
          ariane_pkg::AMO_SWAP: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_SWAP;
          ariane_pkg::AMO_ADD:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_ADD;
          ariane_pkg::AMO_AND:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_AND;
          ariane_pkg::AMO_OR:   amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_OR;
          ariane_pkg::AMO_XOR:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_XOR;
          ariane_pkg::AMO_MAX:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MAX;
          ariane_pkg::AMO_MAXU: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MAXU;
          ariane_pkg::AMO_MIN:  amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MIN;
          ariane_pkg::AMO_MINU: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_MINU;
          // Zacas: reuse reserved opcode slot; compute in hpdcache_amo with packed cmp||swap
          ariane_pkg::AMO_CAS1: amo_op = hpdcache_pkg::HPDCACHE_REQ_AMO_CAS;
          default:              amo_op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
        endcase
      end
      //  }}}

      //  Request forwarding
      //  {{{
      assign hpdcache_req_is_uncacheable = !config_pkg::is_inside_cacheable_regions(
          CVA6Cfg,
          {
            {64 - CVA6Cfg.DCACHE_TAG_WIDTH - CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}},
            hpdcache_req.addr_tag,
            {CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}}
          }
      );

      assign amo_is_word = (cva6_amo_req_i.size == 2'b10);
      assign amo_is_word_hi = cva6_amo_req_i.operand_a[2];
      if (CVA6Cfg.IS_XLEN64) begin : amo_data_64_gen
        // Zacas AMOCAS.W pack {cmp[31:0], swap[31:0]}; D uses swap only.
        // Full 8-byte BE for AMOCAS.W so the cmp half is not stripped before
        // axi_riscv_amos (AtomicCompare uses the whole W data word).
        assign amo_data = (cva6_amo_req_i.amo_op == ariane_pkg::AMO_CAS1)
            ? (amo_is_word
                ? {cva6_amo_req_i.operand_c[31:0], cva6_amo_req_i.operand_b[31:0]}
                : cva6_amo_req_i.operand_b)
            : (amo_is_word ? {2{cva6_amo_req_i.operand_b[0+:32]}} : cva6_amo_req_i.operand_b);
        assign amo_data_be = (cva6_amo_req_i.amo_op == ariane_pkg::AMO_CAS1 && amo_is_word)
            ? 8'hff
            : (amo_is_word_hi ? 8'hf0 : amo_is_word ? 8'h0f : 8'hff);
      end else begin : amo_data_32_gen
        assign amo_data    = {32'b0, cva6_amo_req_i.operand_b};
        assign amo_data_be = 8'h0f;
      end

      assign hpdcache_req_amo = '{
              addr_offset: amo_addr_offset,
              wdata: amo_data,
              op: amo_op,
              be: amo_data_be,
              size: hpdcache_pkg::hpdcache_req_size_t'(cva6_amo_req_i.size),
              sid: hpdcache_req_sid_i,
              tid: '1,
              need_rsp: 1'b1,
              phys_indexed: 1'b1,
              addr_tag: amo_tag,
              pma: '{
                  // Cacheable LR installs the line (UC_AMO_WRITE_DATA) which
                  // snoops and kills the uncached LR/SC reservation. Bypass
                  // L1 for LR/SC only; AMO ADD/etc stay cacheable.
                  uncacheable: hpdcache_req_is_uncacheable
                               || (cva6_amo_req_i.amo_op == ariane_pkg::AMO_LR)
                               || (cva6_amo_req_i.amo_op == ariane_pkg::AMO_SC),
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign hpdcache_req_store = '{
              addr_offset: cva6_req_i.address_index,
              wdata: cva6_req_i.data_wdata,
              op: store_op,
              be: cva6_req_i.data_be,
              size: hpdcache_pkg::hpdcache_req_size_t'(cva6_req_i.data_size),
              sid: hpdcache_req_sid_i,
              tid: '0,
              // CMO requests need a response; so does every cbo.zero drain
              // beat (CBO_ZERO is forwarded as a plain STORE but the store
              // buffer's CBO protocol waits for one data_rvalid per beat,
              // and HPDCACHE only responds when need_rsp is set).
              need_rsp:
              (store_op
               !=
               hpdcache_pkg::HPDCACHE_REQ_STORE)
              || (cva6_req_i.cbo_op == ariane_pkg::CBO_ZERO),
              phys_indexed: 1'b1,
              addr_tag: cva6_req_i.address_tag,
              pma: '{
                  uncacheable: hpdcache_req_is_uncacheable,
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign hpdcache_req_flush = '{
              addr_offset: '0,
              addr_tag: '0,
              wdata: '0,
              op:
              InvalidateOnFlush
              ?
              hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL
              :
              hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_ALL,
              be: '0,
              size: '0,
              sid: hpdcache_req_sid_i,
              tid: '0,
              need_rsp: 1'b1,
              phys_indexed: 1'b0,
              pma: '{
                  uncacheable: 1'b0,
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      // AMOCAS.D/Q local multi-beat RMW (128b Q or 64b D; word CAS uses AMO path)
      assign is_casd_req = CVA6Cfg.RVZacas && cva6_amo_req_i.req &&
                           (cva6_amo_req_i.amo_op == ariane_pkg::AMO_CAS1) &&
                           (!amo_is_word || cva6_amo_req_i.is_quad);
      // is_quad forces multi-beat even if size bits look like dword
      wire is_casq_req = is_casd_req && cva6_amo_req_i.is_quad;
      assign casd_busy = (casd_fsm_q != CASD_IDLE);

      // CAS.D local RMW FSM
      always_comb begin : casd_fsm_comb
        casd_fsm_d      = casd_fsm_q;
        casd_old_d      = casd_old_q;
        casd_old_hi_d   = casd_old_hi_q;
        casd_do_store_d = casd_do_store_q;
        casd_is_quad_d  = casd_is_quad_q;
        forward_casd    = 1'b0;
        unique case (casd_fsm_q)
          CASD_IDLE: begin
            casd_do_store_d = 1'b0;
            casd_is_quad_d  = 1'b0;
            if (is_casd_req && !amo_pending_q) begin
              casd_is_quad_d = cva6_amo_req_i.is_quad;
              casd_fsm_d = CASD_LD;
            end
          end
          CASD_LD: begin
            forward_casd = 1'b1;
            if (hpdcache_req_ready_i) begin
              casd_fsm_d = CASD_LD_WAIT;
            end
          end
          CASD_LD_WAIT: begin
            if (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1)) begin
              casd_old_d = hpdcache_rsp_i.rdata[0];
              if (casd_is_quad_q) begin
                casd_fsm_d = CASD_LD_HI;
              end else if (hpdcache_rsp_i.rdata[0] == cva6_amo_req_i.operand_c) begin
                casd_do_store_d = 1'b1;
                casd_fsm_d      = CASD_ST;
              end else begin
                casd_do_store_d = 1'b0;
                casd_fsm_d      = CASD_INVAL;
              end
            end
          end
          CASD_LD_HI: begin
            forward_casd = 1'b1;
            if (hpdcache_req_ready_i) casd_fsm_d = CASD_LD_HI_WAIT;
          end
          CASD_LD_HI_WAIT: begin
            if (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1)) begin
              casd_old_hi_d = hpdcache_rsp_i.rdata[0];
              if ((casd_old_q == cva6_amo_req_i.operand_c) &&
                  (hpdcache_rsp_i.rdata[0] == cva6_amo_req_i.operand_c_hi)) begin
                casd_do_store_d = 1'b1;
                casd_fsm_d = CASD_ST;
              end else begin
                casd_do_store_d = 1'b0;
                casd_fsm_d = CASD_INVAL;
              end
            end
          end
          CASD_ST: begin
            forward_casd = 1'b1;
            if (hpdcache_req_ready_i) begin
              casd_fsm_d = CASD_ST_WAIT;
            end
          end
          CASD_ST_WAIT: begin
            if (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1)) begin
              casd_fsm_d = casd_is_quad_q ? CASD_ST_HI : CASD_INVAL;
            end
          end
          CASD_ST_HI: begin
            forward_casd = 1'b1;
            if (hpdcache_req_ready_i) casd_fsm_d = CASD_ST_HI_WAIT;
          end
          CASD_ST_HI_WAIT: begin
            if (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1)) begin
              casd_fsm_d = CASD_INVAL;
            end
          end
          CASD_INVAL: begin
            forward_casd = 1'b1;
            if (hpdcache_req_ready_i) begin
              casd_fsm_d = CASD_INVAL_WAIT;
            end
          end
          CASD_INVAL_WAIT: begin
            if (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1)) begin
              casd_fsm_d = CASD_DONE;
            end
          end
          CASD_DONE: begin
            casd_fsm_d = CASD_IDLE;
          end
          default: casd_fsm_d = CASD_IDLE;
        endcase
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin : casd_ff
        if (!rst_ni) begin
          casd_fsm_q      <= CASD_IDLE;
          casd_old_q      <= '0;
          casd_old_hi_q   <= '0;
          casd_do_store_q <= 1'b0;
          casd_is_quad_q  <= 1'b0;
        end else begin
          casd_fsm_q      <= casd_fsm_d;
          casd_old_q      <= casd_old_d;
          casd_old_hi_q   <= casd_old_hi_d;
          casd_do_store_q <= casd_do_store_d;
          casd_is_quad_q  <= casd_is_quad_d;
        end
      end

      // Build CAS.D load / store / inval requests (tid='1 so AMO path owns rsp)
      always_comb begin : casd_req_comb
        hpdcache_req_casd = '0;
        hpdcache_req_casd.addr_offset = amo_addr_offset;
        hpdcache_req_casd.addr_tag = amo_tag;
        hpdcache_req_casd.sid = hpdcache_req_sid_i;
        hpdcache_req_casd.tid = '1;
        hpdcache_req_casd.need_rsp = 1'b1;
        hpdcache_req_casd.phys_indexed = 1'b1;
        hpdcache_req_casd.size = hpdcache_pkg::hpdcache_req_size_t'(2'b11);  // dword
        hpdcache_req_casd.be = 8'hff;
        hpdcache_req_casd.pma.uncacheable = 1'b1;  // force UC path
        hpdcache_req_casd.pma.io = 1'b0;
        hpdcache_req_casd.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
        unique case (casd_fsm_q)
          CASD_LD, CASD_LD_HI: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
            hpdcache_req_casd.wdata = '0;
            if (casd_fsm_q == CASD_LD_HI) begin
              // second dword at addr+8
              hpdcache_req_casd.addr_offset = amo_addr_offset + 8;
            end
          end
          CASD_ST: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_STORE;
            hpdcache_req_casd.wdata = cva6_amo_req_i.operand_b;  // swap lo
          end
          CASD_ST_HI: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_STORE;
            hpdcache_req_casd.wdata = cva6_amo_req_i.operand_b_hi;
            hpdcache_req_casd.addr_offset = amo_addr_offset + 8;
          end
          CASD_INVAL: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_CMO_INVAL_NLINE;
            hpdcache_req_casd.wdata = '0;
            hpdcache_req_casd.be = '0;
            hpdcache_req_casd.pma.uncacheable = 1'b0;
          end
          default: ;
        endcase
      end

      // T9a eWT CMO response hold
      //  {{{
      // A line CMO (inval/clean/flush on the store port) is sent to HPDCACHE
      // AND — under L2CmoEn — issued on the cmo_* sideband to the cluster
      // engine. The CMO's hpdcache response (tid='0) is then swallowed at the
      // response-forwarding seam below and the store port's data_rvalid is
      // released only once cmo_done_i has ALSO arrived, so a retiring CBO is
      // ordered behind the whole hierarchy, not just the L1 op.
      // !cmo_pend_q && !cmo_served_q makes the issue single-shot: a core
      // that keeps data_req raised after the grant (the sideband contract
      // says drop on grant, but a held request must never re-arm the hold
      // registers) can neither re-issue the CMO nor wipe rsp_seen/done_seen
      // — cmo_served_q latches the issue until data_req actually drops, so
      // even after release the held request cannot fire a second CMO, and
      // the repeated hpdcache grants it would cause are masked below.
      wire store_is_cmo = forward_store &&
                          (cva6_req_i.cbo_op == ariane_pkg::CBO_INVAL ||
                           cva6_req_i.cbo_op == ariane_pkg::CBO_CLEAN ||
                           cva6_req_i.cbo_op == ariane_pkg::CBO_FLUSH);
      wire cmo_issue = CVA6Cfg.L2CmoEn && store_is_cmo && hpdcache_req_ready_i &&
                       !cmo_pend_q && !cmo_served_q;
      wire cmo_rsp_now = cmo_pend_q && hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '0);
      wire cmo_rel = cmo_pend_q && (cmo_rsp_seen_q || cmo_rsp_now) &&
                     (cmo_done_seen_q || cmo_done_i);

      assign cmo_valid_o = cmo_pend_q && !cmo_sb_gnt_q;
      assign cmo_op_o    = cmo_op_q;
      assign cmo_addr_o  = cmo_addr_q;

      always_comb begin : cmo_hold_comb
        cmo_pend_d      = cmo_pend_q;
        cmo_sb_gnt_d    = cmo_sb_gnt_q;
        cmo_served_d    = cmo_served_q;
        cmo_rsp_seen_d  = cmo_rsp_seen_q;
        cmo_done_seen_d = cmo_done_seen_q;
        cmo_addr_d      = cmo_addr_q;
        cmo_op_d        = cmo_op_q;
        if (cmo_issue) begin
          cmo_pend_d      = 1'b1;
          cmo_sb_gnt_d    = 1'b0;
          cmo_served_d    = 1'b1;
          cmo_rsp_seen_d  = 1'b0;
          cmo_done_seen_d = 1'b0;
          cmo_addr_d = CVA6Cfg.PLEN'({cva6_req_i.address_tag, cva6_req_i.address_index});
          cmo_op_d   = (cva6_req_i.cbo_op == ariane_pkg::CBO_INVAL) ? 2'd0 :
                       (cva6_req_i.cbo_op == ariane_pkg::CBO_CLEAN) ? 2'd1 : 2'd2;
        end
        if (!cva6_req_i.data_req) cmo_served_d = 1'b0;
        if (cmo_pend_q) begin
          if (cmo_valid_o && cmo_ready_i) cmo_sb_gnt_d = 1'b1;
          if (cmo_rsp_now) cmo_rsp_seen_d = 1'b1;
          if (cmo_done_i)  cmo_done_seen_d = 1'b1;
          if (cmo_rel)     cmo_pend_d = 1'b0;
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin : cmo_hold_ff
        if (!rst_ni) begin
          cmo_pend_q      <= 1'b0;
          cmo_sb_gnt_q    <= 1'b0;
          cmo_served_q    <= 1'b0;
          cmo_rsp_seen_q  <= 1'b0;
          cmo_done_seen_q <= 1'b0;
          cmo_addr_q      <= '0;
          cmo_op_q        <= '0;
        end else begin
          cmo_pend_q      <= cmo_pend_d;
          cmo_sb_gnt_q    <= cmo_sb_gnt_d;
          cmo_served_q    <= cmo_served_d;
          cmo_rsp_seen_q  <= cmo_rsp_seen_d;
          cmo_done_seen_q <= cmo_done_seen_d;
          cmo_addr_q      <= cmo_addr_d;
          cmo_op_q        <= cmo_op_d;
        end
      end
      //  }}}

      assign forward_store = cva6_req_i.data_req & ~casd_busy;
      // Word CAS / other AMOs go through HPDCACHE AMO path; dword CAS is local
      assign forward_amo = cva6_amo_req_i.req & ~is_casd_req & ~casd_busy;

      // A held CMO store is forwarded to HPDCACHE exactly once (at
      // cmo_issue); further grants of the still-raised request are masked
      // so HPDCACHE does not repeat the CMO and produce stray tid='0
      // responses that would leak through the rvalid seam after release.
      assign hpdcache_req_valid_o =
          (forward_amo & ~amo_pending_q) |
          (forward_store & ~(store_is_cmo & cmo_served_q)) |
          forward_flush | forward_casd;

      // Payload mux must use the same masked store term as req_valid: while
      // a served CMO request is held, a concurrent flush/AMO carries its
      // own payload rather than re-sending the stale store request.
      assign hpdcache_req = forward_casd  ? hpdcache_req_casd :
                            forward_amo   ? hpdcache_req_amo :
                            (forward_store & ~(store_is_cmo & cmo_served_q))
                                          ? hpdcache_req_store : hpdcache_req_flush;

      assign hpdcache_req_abort_o = 1'b0;  // unused on physically indexed requests
      assign hpdcache_req_tag_o = '0;  // unused on physically indexed requests
      assign hpdcache_req_pma_o.uncacheable = 1'b0;
      assign hpdcache_req_pma_o.io = 1'b0;
      assign hpdcache_req_pma_o.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
      //  }}}

      //  Response forwarding
      //  {{{
      ariane_pkg::amo_resp_t cva6_amo_resp;
      if (CVA6Cfg.IS_XLEN64) begin : amo_resp_64_gen
        assign amo_resp_word = amo_is_word_hi
                             ? hpdcache_rsp_i.rdata[0][32 +: 32]
                             : hpdcache_rsp_i.rdata[0][0  +: 32];
      end else begin : amo_resp_32_gen
        assign amo_resp_word = hpdcache_rsp_i.rdata[0];
      end

      // T9a seam: while a CMO is held, its tid='0 response is swallowed and
      // rvalid is released only when the hpdcache rsp AND cmo_done_i are in.
      assign cva6_req_o.data_rvalid =
          (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid != '1) && !cmo_rsp_now) ||
          cmo_rel;
      assign cva6_req_o.data_rdata = hpdcache_rsp_i.rdata;
      assign cva6_req_o.data_rid = hpdcache_rsp_i.tid;
      assign cva6_req_o.data_gnt = hpdcache_req_ready_i & ~casd_busy;

      // Normal AMO rsp, or CAS.D completion
      assign cva6_amo_resp.ack = (casd_fsm_q == CASD_DONE) ||
          (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1) && !casd_busy &&
           !(casd_fsm_q inside {CASD_LD_WAIT, CASD_LD_HI_WAIT, CASD_ST_WAIT,
                                CASD_ST_HI_WAIT, CASD_INVAL_WAIT}));
      assign cva6_amo_resp.result = (casd_fsm_q == CASD_DONE)
          ? casd_old_q
          : (amo_is_word ? {{32{amo_resp_word[31]}}, amo_resp_word}
                         : hpdcache_rsp_i.rdata[0]);
      assign cva6_amo_resp.result_hi = (casd_fsm_q == CASD_DONE) ? casd_old_hi_q : '0;
      assign cva6_amo_resp.dual_we = (casd_fsm_q == CASD_DONE) && casd_is_quad_q;
      //  }}}

      always_ff @(posedge clk_i or negedge rst_ni) begin : amo_pending_ff
        if (!rst_ni) begin
          amo_pending_q   <= 1'b0;
          cva6_amo_resp_o <= '0;
        end else begin
          // Stay pending while CAS.D multi-step is in flight, or while a
          // normal AMO has been accepted and its ack not yet returned.
          if (casd_busy || (casd_fsm_q == CASD_DONE)) begin
            amo_pending_q <= 1'b1;
          end else if (cva6_amo_resp_o.ack) begin
            amo_pending_q <= 1'b0;
          end else if (~amo_pending_q & forward_amo & hpdcache_req_ready_i) begin
            amo_pending_q <= 1'b1;
          end else if (amo_pending_q & ~cva6_amo_resp_o.ack) begin
            amo_pending_q <= 1'b1;
          end else begin
            amo_pending_q <= 1'b0;
          end

          if (cva6_amo_resp_o.ack) begin
            cva6_amo_resp_o <= '0;
          end else if (cva6_amo_resp.ack) begin
            cva6_amo_resp_o <= cva6_amo_resp;
          end
        end
      end

      //  Assertions
      //  {{{
      //    pragma translate_off
      forward_one_request_assert :
      assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1) ($onehot0(
          {forward_store, forward_amo, forward_flush, forward_casd}
      )))
      else $error("Only one request shall be forwarded");
      //    pragma translate_on
      //  }}}
    end
    //  }}}
  endgenerate

  assign hpdcache_req_o = hpdcache_req;
  //  }}}
endmodule
