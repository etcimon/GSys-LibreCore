// Copyright 2023 Commissariat a l'Energie Atomique et aux Energies
//                Alternatives (CEA)
//
// Licensed under the Solderpad Hardware License, Version 2.1 (the “License”);
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Authors: Cesar Fuguet
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
    input hpdcache_rsp_t hpdcache_rsp_i
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
      assign hpdcache_req_is_uncacheable = !config_pkg::is_inside_cacheable_regions(
          CVA6Cfg,
          {
            {64 - CVA6Cfg.DCACHE_TAG_WIDTH{1'b0}}
            , cva6_req_i.address_tag
            , {CVA6Cfg.DCACHE_INDEX_WIDTH{1'b0}}
          }
      );

      //    Request forwarding
      assign hpdcache_req_valid_o = cva6_req_i.data_req;
      assign hpdcache_req.addr_offset = cva6_req_i.address_index;
      assign hpdcache_req.wdata = '0;
      assign hpdcache_req.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
      assign hpdcache_req.be = cva6_req_i.data_be;
      assign hpdcache_req.size = cva6_req_i.data_size;
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

      // AMOCAS.D: 64b expected + 64b swap cannot fit in one req wdata.
      // Local RMW in the adapter (same spirit as wt_dcache_missunit AMO_CAS_*).
      typedef enum logic [2:0] {
        CASD_IDLE,
        CASD_LD,
        CASD_LD_WAIT,
        CASD_ST,
        CASD_ST_WAIT,
        CASD_INVAL,
        CASD_INVAL_WAIT,
        CASD_DONE
      } casd_fsm_e;
      casd_fsm_e casd_fsm_q, casd_fsm_d;
      logic [63:0] casd_old_q, casd_old_d;
      logic        casd_do_store_q, casd_do_store_d;
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
            if (cva6_dcache_flush_i) begin
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
            // Zicboz: U7ᶜ store_unit multi-beats full D$ line as zero STOREs
            // (line-aligned). First beat may still tag CBO_ZERO; subsequent
            // beats use CBO_NONE. Plain STORE updates memory for memcpy/memset.
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
            {64 - CVA6Cfg.DCACHE_TAG_WIDTH{1'b0}}
            , hpdcache_req.addr_tag,
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
              size: cva6_amo_req_i.size,
              sid: hpdcache_req_sid_i,
              tid: '1,
              need_rsp: 1'b1,
              phys_indexed: 1'b1,
              addr_tag: amo_tag,
              pma: '{
                  uncacheable: hpdcache_req_is_uncacheable,
                  io: 1'b0,
                  wr_policy_hint: hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO
              }
          };

      assign hpdcache_req_store = '{
              addr_offset: cva6_req_i.address_index,
              wdata: cva6_req_i.data_wdata,
              op: store_op,
              be: cva6_req_i.data_be,
              size: cva6_req_i.data_size,
              sid: hpdcache_req_sid_i,
              tid: '0,
              need_rsp:
              store_op
              !=
              hpdcache_pkg::HPDCACHE_REQ_STORE,  // CMO requests need a response
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

      // AMOCAS.D detection (size != word → dword for Zacas path)
      assign is_casd_req = CVA6Cfg.RVZacas && cva6_amo_req_i.req &&
                           (cva6_amo_req_i.amo_op == ariane_pkg::AMO_CAS1) &&
                           !amo_is_word;
      assign casd_busy = (casd_fsm_q != CASD_IDLE);

      // CAS.D local RMW FSM
      always_comb begin : casd_fsm_comb
        casd_fsm_d      = casd_fsm_q;
        casd_old_d      = casd_old_q;
        casd_do_store_d = casd_do_store_q;
        forward_casd    = 1'b0;
        unique case (casd_fsm_q)
          CASD_IDLE: begin
            casd_do_store_d = 1'b0;
            if (is_casd_req && !amo_pending_q) begin
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
              if (hpdcache_rsp_i.rdata[0] == cva6_amo_req_i.operand_c) begin
                casd_do_store_d = 1'b1;
                casd_fsm_d      = CASD_ST;
              end else begin
                // mismatch: keep mem; still drop any hot L1 line
                casd_do_store_d = 1'b0;
                casd_fsm_d      = CASD_INVAL;
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
              casd_fsm_d = CASD_INVAL;
            end
          end
          CASD_INVAL: begin
            // Drop L1 line so a following cached load refills from DRAM
            // (uncached store does not update D$).
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
            // one-cycle ack to core
            casd_fsm_d = CASD_IDLE;
          end
          default: casd_fsm_d = CASD_IDLE;
        endcase
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin : casd_ff
        if (!rst_ni) begin
          casd_fsm_q      <= CASD_IDLE;
          casd_old_q      <= '0;
          casd_do_store_q <= 1'b0;
        end else begin
          casd_fsm_q      <= casd_fsm_d;
          casd_old_q      <= casd_old_d;
          casd_do_store_q <= casd_do_store_d;
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
        hpdcache_req_casd.size = 2'b11;  // dword
        hpdcache_req_casd.be = 8'hff;
        hpdcache_req_casd.pma.uncacheable = 1'b1;  // force UC path
        hpdcache_req_casd.pma.io = 1'b0;
        hpdcache_req_casd.pma.wr_policy_hint = hpdcache_pkg::HPDCACHE_WR_POLICY_AUTO;
        unique case (casd_fsm_q)
          CASD_LD: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_LOAD;
            hpdcache_req_casd.wdata = '0;
          end
          CASD_ST: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_STORE;
            hpdcache_req_casd.wdata = cva6_amo_req_i.operand_b;  // swap
          end
          CASD_INVAL: begin
            hpdcache_req_casd.op = hpdcache_pkg::HPDCACHE_REQ_CMO_INVAL_NLINE;
            hpdcache_req_casd.wdata = '0;
            hpdcache_req_casd.be = '0;
            // CMO uses cacheable address for nline select
            hpdcache_req_casd.pma.uncacheable = 1'b0;
          end
          default: ;
        endcase
      end

      assign forward_store = cva6_req_i.data_req & ~casd_busy;
      // Word CAS / other AMOs go through HPDCACHE AMO path; dword CAS is local
      assign forward_amo = cva6_amo_req_i.req & ~is_casd_req & ~casd_busy;

      assign hpdcache_req_valid_o =
          (forward_amo & ~amo_pending_q) | forward_store | forward_flush | forward_casd;

      assign hpdcache_req = forward_casd  ? hpdcache_req_casd :
                            forward_amo   ? hpdcache_req_amo :
                            forward_store ? hpdcache_req_store : hpdcache_req_flush;

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

      assign cva6_req_o.data_rvalid = hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid != '1);
      assign cva6_req_o.data_rdata = hpdcache_rsp_i.rdata;
      assign cva6_req_o.data_rid = hpdcache_rsp_i.tid;
      assign cva6_req_o.data_gnt = hpdcache_req_ready_i & ~casd_busy;

      // Normal AMO rsp, or CAS.D completion
      assign cva6_amo_resp.ack = (casd_fsm_q == CASD_DONE) ||
          (hpdcache_rsp_valid_i && (hpdcache_rsp_i.tid == '1) && !casd_busy &&
           !(casd_fsm_q inside {CASD_LD_WAIT, CASD_ST_WAIT, CASD_INVAL_WAIT}));
      assign cva6_amo_resp.result = (casd_fsm_q == CASD_DONE)
          ? casd_old_q
          : (amo_is_word ? {{32{amo_resp_word[31]}}, amo_resp_word}
                         : hpdcache_rsp_i.rdata[0]);
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
