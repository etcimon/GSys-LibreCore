// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:  axi_adapter.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Modified by: Etienne Cimon
 * Date:   1.8.2018
 *
 * Description: Manages communication with the AXI Bus
 */
//import std_cache_pkg::*;

module axi_adapter #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned DATA_WIDTH = 256,
    parameter logic        CRITICAL_WORD_FIRST   = 0, // the AXI subsystem needs to support wrapping reads for this feature
    parameter int unsigned CACHELINE_BYTE_OFFSET = 8,
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni, // Asynchronous reset active low

    input logic req_i,
    input g6lc_core_pkg::ad_req_t type_i,
    input g6lc_core_pkg::amo_t amo_i,
    output logic gnt_o,
    input logic [G6LCCfg.XLEN-1:0] addr_i,
    input logic we_i,
    input logic [(DATA_WIDTH/G6LCCfg.AxiDataWidth)-1:0][G6LCCfg.AxiDataWidth-1:0] wdata_i,
    input logic [(DATA_WIDTH/G6LCCfg.AxiDataWidth)-1:0][(G6LCCfg.AxiDataWidth/8)-1:0] be_i,
    input logic [1:0] size_i,
    input logic [G6LCCfg.AxiIdWidth-1:0] id_i,
    // read port
    output logic valid_o,
    output logic [(DATA_WIDTH/G6LCCfg.AxiDataWidth)-1:0][G6LCCfg.AxiDataWidth-1:0] rdata_o,
    output logic [G6LCCfg.AxiIdWidth-1:0] id_o,
    // critical word - read port
    output logic [G6LCCfg.AxiDataWidth-1:0] critical_word_o,
    output logic critical_word_valid_o,
    // AXI port
    output axi_req_t axi_req_o,
    input axi_rsp_t axi_resp_i
);
  localparam BURST_SIZE = (DATA_WIDTH / G6LCCfg.AxiDataWidth) - 1;
  localparam ADDR_INDEX = ($clog2(
      DATA_WIDTH / G6LCCfg.AxiDataWidth
  ) > 0) ? $clog2(
      DATA_WIDTH / G6LCCfg.AxiDataWidth
  ) : 1;
  localparam MAX_OUTSTANDING_AW = G6LCCfg.MaxOutstandingStores;
  localparam MAX_OUTSTANDING_AW_CNT_WIDTH = $clog2(
      MAX_OUTSTANDING_AW + 1
  ) > 0 ? $clog2(
      MAX_OUTSTANDING_AW + 1
  ) : 1;

  typedef logic [MAX_OUTSTANDING_AW_CNT_WIDTH-1:0] outstanding_aw_cnt_t;

  enum logic [3:0] {
    IDLE,
    WAIT_B_VALID,
    WAIT_AW_READY,
    WAIT_LAST_W_READY,
    WAIT_LAST_W_READY_AW_READY,
    WAIT_AW_READY_BURST,
    WAIT_R_VALID,
    WAIT_R_VALID_MULTIPLE,
    COMPLETE_READ,
    WAIT_AMO_R_VALID
  }
      state_q, state_d;

  // counter for AXI transfers
  logic [ADDR_INDEX-1:0] cnt_d, cnt_q;
  logic [(DATA_WIDTH/G6LCCfg.AxiDataWidth)-1:0][G6LCCfg.AxiDataWidth-1:0]
      cache_line_d, cache_line_q;
  // save the address for a read, as we allow for non-cacheline aligned accesses
  logic [(DATA_WIDTH/G6LCCfg.AxiDataWidth)-1:0] addr_offset_d, addr_offset_q;
  logic [G6LCCfg.AxiIdWidth-1:0] id_d, id_q;
  logic [ADDR_INDEX-1:0] index;
  // save the atomic operation and size
  g6lc_core_pkg::amo_t amo_d, amo_q;
  logic [1:0] size_d, size_q;
  // outstanding write transactions counter
  outstanding_aw_cnt_t outstanding_aw_cnt_q, outstanding_aw_cnt_d;
  logic any_outstanding_aw;

  assign any_outstanding_aw = outstanding_aw_cnt_q != '0;

  // hyp8: registered request assembly (svt-plan boundary). An incoming
  // request is captured whole — type/we/amo/addr/size/id plus every W
  // beat — into the pend record; the FSM and all AXI channel fields then
  // read only the slots. gnt_o marks the capture (the source may drop the
  // request the same cycle), the record frees on the internal consume
  // event `req_done` — the same channel-completion points the
  // combinational version granted on. AXI valid/ready is unchanged.
  localparam int unsigned NB = DATA_WIDTH / G6LCCfg.AxiDataWidth;
  logic                                              req_pend_q;
  logic                                              req_we_q;
  g6lc_core_pkg::ad_req_t                            req_type_q;
  g6lc_core_pkg::amo_t                               req_amo_q;
  logic [G6LCCfg.XLEN-1:0]                           req_addr_q;
  logic [NB-1:0][G6LCCfg.AxiDataWidth-1:0]           req_wdata_q;
  logic [NB-1:0][(G6LCCfg.AxiDataWidth/8)-1:0]       req_be_q;
  logic [1:0]                                        req_size_q;
  logic [G6LCCfg.AxiIdWidth-1:0]                     req_id_q;
  logic                                              req_take, req_done;

  wire wr_allow = !any_outstanding_aw ||
                  ((id_i == id_q) && (amo_i == g6lc_core_pkg::AMO_NONE));
  wire rd_allow = !any_outstanding_aw;
  assign req_take = req_i && (state_q == IDLE) && !req_pend_q &&
                    (we_i ? wr_allow : rd_allow);

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_req_pend
    if (!rst_ni) begin
      req_pend_q  <= 1'b0;
      req_we_q    <= 1'b0;
      req_type_q  <= g6lc_core_pkg::SINGLE_REQ;
      req_amo_q   <= g6lc_core_pkg::AMO_NONE;
      req_addr_q  <= '0;
      req_wdata_q <= '0;
      req_be_q    <= '0;
      req_size_q  <= '0;
      req_id_q    <= '0;
    end else begin
      if (req_done) req_pend_q <= 1'b0;
      if (req_take) begin
        req_pend_q  <= 1'b1;
        req_we_q    <= we_i;
        req_type_q  <= type_i;
        req_amo_q   <= amo_i;
        req_addr_q  <= addr_i;
        req_wdata_q <= wdata_i;
        req_be_q    <= be_i;
        req_size_q  <= size_i;
        req_id_q    <= id_i;
      end
    end
  end

  always_comb begin : axi_fsm
    // Default assignments
    axi_req_o.aw_valid  = 1'b0;
    // Cast to AXI address width — hyp8: every channel field reads the
    // captured pend record, never the live request pins.
    axi_req_o.aw.addr   = req_addr_q;
    axi_req_o.aw.prot   = 3'b0;
    axi_req_o.aw.region = 4'b0;
    axi_req_o.aw.len    = 8'b0;
    axi_req_o.aw.size   = {1'b0, req_size_q};  // 1, 2, 4 or 8 bytes
    axi_req_o.aw.burst  = axi_pkg::BURST_INCR;  // Use BURST_INCR for AXI regular transaction
    axi_req_o.aw.lock   = 1'b0;
    axi_req_o.aw.cache  = axi_pkg::CACHE_MODIFIABLE;
    axi_req_o.aw.qos    = 4'b0;
    axi_req_o.aw.id     = req_id_q;
    axi_req_o.aw.atop   = atop_from_amo(req_amo_q);
    axi_req_o.aw.user   = '0;

    axi_req_o.ar_valid  = 1'b0;
    // Cast to AXI address width
    axi_req_o.ar.addr   = req_addr_q;
    // in case of a single request or wrapping transfer we can simply begin at the address, if we want to request a cache-line
    // with an incremental transfer we need to output the corresponding base address of the cache line
    if (!CRITICAL_WORD_FIRST && req_type_q != g6lc_core_pkg::SINGLE_REQ) begin
      axi_req_o.ar.addr[CACHELINE_BYTE_OFFSET-1:0] = '0;
    end
    axi_req_o.ar.prot = 3'b0;
    axi_req_o.ar.region = 4'b0;
    axi_req_o.ar.len = 8'b0;
    axi_req_o.ar.size = {1'b0, req_size_q};  // 1, 2, 4 or 8 bytes
    axi_req_o.ar.burst  = (CRITICAL_WORD_FIRST ? axi_pkg::BURST_WRAP : axi_pkg::BURST_INCR); // wrapping transfer in case of a critical word first strategy
    axi_req_o.ar.lock = 1'b0;
    axi_req_o.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    axi_req_o.ar.qos = 4'b0;
    axi_req_o.ar.id = req_id_q;
    axi_req_o.ar.user = '0;

    axi_req_o.w_valid = 1'b0;
    axi_req_o.w.data = req_wdata_q[0];
    axi_req_o.w.strb = req_be_q[0];
    axi_req_o.w.last = 1'b0;
    axi_req_o.w.user = '0;

    axi_req_o.b_ready = 1'b0;
    axi_req_o.r_ready = 1'b0;

    // hyp8: upstream gnt marks the pend-slot capture; the internal
    // consume event req_done fires at the channel-completion points the
    // combinational version granted on and frees the record.
    gnt_o = req_take;
    req_done = 1'b0;
    valid_o = 1'b0;
    id_o = axi_resp_i.r.id;

    critical_word_o = axi_resp_i.r.data;
    critical_word_valid_o = 1'b0;
    rdata_o = cache_line_q;

    state_d = state_q;
    cnt_d = cnt_q;
    cache_line_d = cache_line_q;
    addr_offset_d = addr_offset_q;
    id_d = id_q;
    amo_d = amo_q;
    size_d = size_q;
    index = '0;

    outstanding_aw_cnt_d = outstanding_aw_cnt_q;

    case (state_q)

      IDLE: begin
        cnt_d = '0;
        // we have a captured pending request
        if (req_pend_q) begin
          // is this a read or write?
          // write
          if (req_we_q) begin
            // multiple outstanding write transactions are only
            // allowed if they are guaranteed not to be reordered
            // i.e. same ID — checked again at issue: a B response can
            // retire an outstanding AW while the record sat in the slot.
            if (!any_outstanding_aw || ((req_id_q == id_q) && (req_amo_q == g6lc_core_pkg::AMO_NONE))) begin
              // the data is valid
              axi_req_o.aw_valid = 1'b1;
              axi_req_o.w_valid  = 1'b1;
              // store-conditional requires exclusive access
              axi_req_o.aw.lock  = req_amo_q == g6lc_core_pkg::AMO_SC;
              // its a single write
              if (req_type_q == g6lc_core_pkg::SINGLE_REQ) begin
                // only a single write so the data is already the last one
                axi_req_o.w.last = 1'b1;
                // single req is consumed here
                req_done = axi_resp_i.aw_ready & axi_resp_i.w_ready;
                case ({
                  axi_resp_i.aw_ready, axi_resp_i.w_ready
                })
                  2'b11:   state_d = WAIT_B_VALID;
                  2'b01:   state_d = WAIT_AW_READY;
                  2'b10:   state_d = WAIT_LAST_W_READY;
                  default: state_d = IDLE;
                endcase

                if (axi_resp_i.aw_ready) begin
                  id_d   = req_id_q;
                  amo_d  = req_amo_q;
                  size_d = req_size_q;
                end

                // its a request for the whole cache line
              end else begin
                // bursts of AMOs unsupported
                assert (req_amo_q == g6lc_core_pkg::AMO_NONE)
                else $fatal(1, "Bursts of atomic operations are not supported");

                axi_req_o.aw.len = BURST_SIZE[7:0];  // number of bursts to do
                axi_req_o.w.data = req_wdata_q[0];
                axi_req_o.w.strb = req_be_q[0];

                if (axi_resp_i.w_ready) cnt_d = BURST_SIZE[ADDR_INDEX-1:0] - 1;
                else cnt_d = BURST_SIZE[ADDR_INDEX-1:0];

                case ({
                  axi_resp_i.aw_ready, axi_resp_i.w_ready
                })
                  2'b11:   state_d = WAIT_LAST_W_READY;
                  2'b01:   state_d = WAIT_LAST_W_READY_AW_READY;
                  2'b10:   state_d = WAIT_LAST_W_READY;
                  default: ;
                endcase
              end
            end
            // read
          end else begin
            // only multiple outstanding write transactions are allowed
            if (!any_outstanding_aw) begin

              axi_req_o.ar_valid = 1'b1;
              // load-reserved requires exclusive access
              axi_req_o.ar.lock = req_amo_q == g6lc_core_pkg::AMO_LR;

              req_done = axi_resp_i.ar_ready;
              if (req_type_q != g6lc_core_pkg::SINGLE_REQ) begin
                assert (req_amo_q == g6lc_core_pkg::AMO_NONE)
                else $fatal(1, "Bursts of atomic operations are not supported");

                axi_req_o.ar.len = BURST_SIZE[7:0];
                cnt_d = BURST_SIZE[ADDR_INDEX-1:0];
              end

              if (axi_resp_i.ar_ready) begin
                state_d = (req_type_q == g6lc_core_pkg::SINGLE_REQ) ? WAIT_R_VALID : WAIT_R_VALID_MULTIPLE;
                addr_offset_d = req_addr_q[ADDR_INDEX-1+3:3];
              end
            end
          end
        end
      end

      // ~> from single write
      WAIT_AW_READY: begin
        axi_req_o.aw_valid = 1'b1;

        if (axi_resp_i.aw_ready) begin
          req_done = 1'b1;
          state_d  = WAIT_B_VALID;
          id_d     = req_id_q;
          amo_d    = req_amo_q;
          size_d   = req_size_q;
        end
      end

      // ~> we need to wait for an aw_ready and there is at least one outstanding write
      WAIT_LAST_W_READY_AW_READY: begin
        axi_req_o.w_valid = 1'b1;
        axi_req_o.w.last  = (cnt_q == '0);
        if (req_type_q == g6lc_core_pkg::SINGLE_REQ) begin
          axi_req_o.w.data = req_wdata_q[0];
          axi_req_o.w.strb = req_be_q[0];
        end else begin
          axi_req_o.w.data = req_wdata_q[BURST_SIZE[ADDR_INDEX-1:0]-cnt_q];
          axi_req_o.w.strb = req_be_q[BURST_SIZE[ADDR_INDEX-1:0]-cnt_q];
        end
        axi_req_o.aw_valid = 1'b1;
        // we are here because we want to write a cache line
        axi_req_o.aw.len   = BURST_SIZE[7:0];
        // we got an aw_ready
        case ({
          axi_resp_i.aw_ready, axi_resp_i.w_ready
        })
          // we got an aw ready
          2'b01: begin
            // are there any outstanding transactions?
            if (cnt_q == 0) state_d = WAIT_AW_READY_BURST;
            else  // yes, so reduce the count and stay here
              cnt_d = cnt_q - 1;
          end
          2'b10:   state_d = WAIT_LAST_W_READY;
          2'b11: begin
            // we are finished
            if (cnt_q == 0) begin
              state_d  = WAIT_B_VALID;
              req_done = 1'b1;
              // there are outstanding transactions
            end else begin
              state_d = WAIT_LAST_W_READY;
              cnt_d   = cnt_q - 1;
            end
          end
          default: ;
        endcase

      end

      // ~> all data has already been sent, we are only waiting for the aw_ready
      WAIT_AW_READY_BURST: begin
        axi_req_o.aw_valid = 1'b1;
        axi_req_o.aw.len   = BURST_SIZE[7:0];

        if (axi_resp_i.aw_ready) begin
          state_d  = WAIT_B_VALID;
          req_done = 1'b1;
        end
      end

      // ~> from write, there is an outstanding write
      WAIT_LAST_W_READY: begin
        axi_req_o.w_valid = 1'b1;

        if (req_type_q != g6lc_core_pkg::SINGLE_REQ) begin
          axi_req_o.w.data = req_wdata_q[BURST_SIZE[ADDR_INDEX-1:0]-cnt_q];
          axi_req_o.w.strb = req_be_q[BURST_SIZE[ADDR_INDEX-1:0]-cnt_q];
        end

        // this is the last write
        if (cnt_q == '0) begin
          axi_req_o.w.last = 1'b1;
          if (axi_resp_i.w_ready) begin
            state_d  = WAIT_B_VALID;
            req_done = 1'b1;
          end
        end else if (axi_resp_i.w_ready) begin
          cnt_d = cnt_q - 1;
        end
      end

      // ~> finish write transaction
      WAIT_B_VALID: begin
        id_o = axi_resp_i.b.id;

        // Write is valid
        if (axi_resp_i.b_valid && !any_outstanding_aw) begin
          axi_req_o.b_ready = 1'b1;

          // some atomics must wait for read data
          // we only accept it after accepting bvalid
          if (amo_returns_data(amo_q)) begin
            if (axi_resp_i.r_valid) begin
              // return read data if valid
              valid_o           = 1'b1;
              axi_req_o.r_ready = 1'b1;
              state_d           = IDLE;
              rdata_o           = axi_resp_i.r.data;
            end else begin
              // wait otherwise
              state_d = WAIT_AMO_R_VALID;
            end
          end else begin
            valid_o = 1'b1;
            state_d = IDLE;

            // store-conditional response
            if (amo_q == g6lc_core_pkg::AMO_SC) begin
              if (axi_resp_i.b.resp == axi_pkg::RESP_EXOKAY) begin
                // success -> return 0
                rdata_o = 'b0;
              end else begin
                // failure -> when request is 64-bit, return 1;
                // when request is 32-bit place a 1 in both upper
                // and lower half words. The right word will be
                // realigned/masked externally
                rdata_o = size_q == 2'b10 ? (1'b1 << 32) | 64'b1 : 64'b1;
              end
            end
          end
          // if the request was not an atomic we can possibly issue
          // other requests while waiting for the response
        end else begin
          // An atomic is excluded from this early release: it must stay in the
          // FSM until its B (and R, for a fetch-type AMO) has returned, or the
          // read half could be reordered against a later write.
          if ((amo_q == g6lc_core_pkg::AMO_NONE) && (outstanding_aw_cnt_q != MAX_OUTSTANDING_AW)) begin
            state_d = IDLE;
            outstanding_aw_cnt_d = outstanding_aw_cnt_q + 1;
          end
        end
      end

      // ~> some atomics wait for read data
      WAIT_AMO_R_VALID: begin
        // acknowledge data and terminate atomic
        if (axi_resp_i.r_valid) begin
          axi_req_o.r_ready = 1'b1;
          state_d           = IDLE;
          valid_o           = 1'b1;
          rdata_o           = axi_resp_i.r.data;
        end
      end

      // ~> cacheline read, single read
      WAIT_R_VALID_MULTIPLE, WAIT_R_VALID: begin
        if (CRITICAL_WORD_FIRST) index = addr_offset_q + (BURST_SIZE[ADDR_INDEX-1:0] - cnt_q);
        else index = BURST_SIZE[ADDR_INDEX-1:0] - cnt_q;

        // reads are always wrapping here
        axi_req_o.r_ready = 1'b1;
        // this is the first read a.k.a the critical word
        if (axi_resp_i.r_valid) begin
          if (CRITICAL_WORD_FIRST) begin
            // this is the first word of a cacheline read, e.g.: the word which was causing the miss
            if (state_q == WAIT_R_VALID_MULTIPLE && cnt_q == BURST_SIZE) begin
              critical_word_valid_o = 1'b1;
              critical_word_o       = axi_resp_i.r.data;
            end
          end else begin
            // check if the address offset matches - then we are getting the critical word
            if (index == addr_offset_q) begin
              critical_word_valid_o = 1'b1;
              critical_word_o       = axi_resp_i.r.data;
            end
          end

          // this is the last read
          if (axi_resp_i.r.last) begin
            id_d    = axi_resp_i.r.id;
            state_d = COMPLETE_READ;
          end

          // save the word
          if (state_q == WAIT_R_VALID_MULTIPLE) begin
            cache_line_d[index] = axi_resp_i.r.data;

          end else cache_line_d[0] = axi_resp_i.r.data;

          // Decrease the counter
          cnt_d = cnt_q - 1;
        end
      end
      // ~> read is complete
      COMPLETE_READ: begin
        valid_o = 1'b1;
        state_d = IDLE;
        id_o    = id_q;
      end

      default: state_d = IDLE;
    endcase

    // This process handles B responses when accepting
    // multiple outstanding write transactions
    if (any_outstanding_aw && axi_resp_i.b_valid) begin
      axi_req_o.b_ready = 1'b1;
      valid_o = 1'b1;
      // Right hand side contains non-registered signal as we want
      // to preserve a possible increment from the WAIT_B_VALID state
      outstanding_aw_cnt_d = outstanding_aw_cnt_d - 1;
    end
  end

  // ----------------
  // Registers
  // ----------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      // start in flushing state and initialize the memory
      state_q              <= IDLE;
      cnt_q                <= '0;
      cache_line_q         <= '0;
      addr_offset_q        <= '0;
      id_q                 <= '0;
      amo_q                <= g6lc_core_pkg::AMO_NONE;
      size_q               <= '0;
      outstanding_aw_cnt_q <= '0;
    end else begin
      state_q              <= state_d;
      cnt_q                <= cnt_d;
      cache_line_q         <= cache_line_d;
      addr_offset_q        <= addr_offset_d;
      id_q                 <= id_d;
      amo_q                <= amo_d;
      size_q               <= size_d;
      outstanding_aw_cnt_q <= outstanding_aw_cnt_d;
    end
  end

  function automatic axi_pkg::atop_t atop_from_amo(g6lc_core_pkg::amo_t amo);
    axi_pkg::atop_t result = 6'b000000;

    unique case (amo)
      g6lc_core_pkg::AMO_NONE: result = {axi_pkg::ATOP_NONE, 4'b0000};
      g6lc_core_pkg::AMO_SWAP: result = {axi_pkg::ATOP_ATOMICSWAP};
      g6lc_core_pkg::AMO_ADD:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_ADD};
      g6lc_core_pkg::AMO_AND:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_CLR};
      g6lc_core_pkg::AMO_OR:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SET};
      g6lc_core_pkg::AMO_XOR:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_EOR};
      g6lc_core_pkg::AMO_MAX:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SMAX};
      g6lc_core_pkg::AMO_MAXU:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_UMAX};
      g6lc_core_pkg::AMO_MIN:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SMIN};
      g6lc_core_pkg::AMO_MINU:
      result = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_UMIN};
      // Zacas AMOCAS → AXI ATOMICCMP (compare||swap in W data; adapter packs)
      g6lc_core_pkg::AMO_CAS1: result = {axi_pkg::ATOP_ATOMICCMP};
      g6lc_core_pkg::AMO_CAS2: result = {axi_pkg::ATOP_NONE, 4'b0000};  // reserved
      default: result = 6'b000000;
    endcase

    return result;
  endfunction

  function automatic logic amo_returns_data(g6lc_core_pkg::amo_t amo);
    axi_pkg::atop_t atop = atop_from_amo(amo);
    logic           is_load = atop[5:4] == axi_pkg::ATOP_ATOMICLOAD;
    logic           is_swap_or_cmp = atop[5:4] == axi_pkg::ATOP_ATOMICSWAP[5:4];
    return is_load || is_swap_or_cmp;
  endfunction

endmodule
