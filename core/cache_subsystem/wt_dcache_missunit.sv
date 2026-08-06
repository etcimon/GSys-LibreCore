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
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 13.09.2018
// Description: miss controller for WT dcache. Note that the current assumption
// is that the port with the highest index issues writes instead of reads.


module wt_dcache_missunit
  import ariane_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter DCACHE_CL_IDX_WIDTH = 0,
    parameter type dcache_req_t = logic,
    parameter type dcache_rtrn_t = logic,
    parameter logic [CVA6Cfg.MEM_TID_WIDTH-1:0] AmoTxId = 1,  // TX id to be used for AMOs
    parameter int unsigned NumPorts = 4  // number of miss ports
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    // cache management, signals from/to core
    input logic enable_i,  // from CSR
    input  logic                                       flush_i,     // flush request, this waits for pending tx (write, read) to finish and will clear the cache
    output logic flush_ack_o,  // send a single cycle acknowledge signal when the cache is flushed
    output logic miss_o,  // we missed on a ld/st
    // local cache management signals
    input logic wbuffer_empty_i,
    output logic cache_en_o,  // local cache enable signal
    // AMO interface
    input amo_req_t amo_req_i,
    output amo_resp_t amo_resp_o,
    input logic mbe_i,
    // miss handling interface (ld, ptw, wbuffer)
    input logic [NumPorts-1:0] miss_req_i,
    output logic [NumPorts-1:0] miss_ack_o,
    input logic [NumPorts-1:0] miss_nc_i,
    input logic [NumPorts-1:0] miss_we_i,
    input logic [NumPorts-1:0][CVA6Cfg.XLEN-1:0] miss_wdata_i,
    input logic [NumPorts-1:0][CVA6Cfg.DCACHE_USER_WIDTH-1:0] miss_wuser_i,
    input logic [NumPorts-1:0][CVA6Cfg.PLEN-1:0] miss_paddr_i,
    input logic [NumPorts-1:0][CVA6Cfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits_i,
    input logic [NumPorts-1:0][2:0] miss_size_i,
    input logic [NumPorts-1:0][CVA6Cfg.MEM_TID_WIDTH-1:0] miss_id_i,  // used as transaction ID
    // signals that the request collided with a pending read
    output logic [NumPorts-1:0] miss_replay_o,
    // signals response from memory
    output logic [NumPorts-1:0] miss_rtrn_vld_o,
    output logic [CVA6Cfg.MEM_TID_WIDTH-1:0]                  miss_rtrn_id_o,     // only used for writes, set to zero for reads
    // from writebuffer
    input  logic [CVA6Cfg.DCACHE_MAX_TX-1:0][CVA6Cfg.PLEN-1:0]  tx_paddr_i,         // used to check for address collisions with read operations
    input  logic [CVA6Cfg.DCACHE_MAX_TX-1:0]                   tx_vld_i,           // used to check for address collisions with read operations
    // write interface to cache memory
    output logic wr_cl_vld_o,  // writes a full cacheline
    output logic wr_cl_nc_o,  // writes a full cacheline
    output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] wr_cl_we_o,  // writes a full cacheline
    output logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] wr_cl_tag_o,
    output logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx_o,
    output logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] wr_cl_off_o,
    output logic [CVA6Cfg.DCACHE_LINE_WIDTH-1:0] wr_cl_data_o,
    output logic [CVA6Cfg.DCACHE_USER_LINE_WIDTH-1:0] wr_cl_user_o,
    output logic [CVA6Cfg.DCACHE_LINE_WIDTH/8-1:0] wr_cl_data_be_o,
    output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] wr_vld_bits_o,
    // memory interface
    input logic mem_rtrn_vld_i,
    input dcache_rtrn_t mem_rtrn_i,
    output logic mem_data_req_o,
    input logic mem_data_ack_i,
    output dcache_req_t mem_data_o
);

  // functions
  function automatic logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] dcache_way_bin2oh(
      input logic [CVA6Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] in);
    logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  // align the physical address to the specified size:
  // 000: bytes
  // 001: hword
  // 010: word
  // 011: dword
  // 111: DCACHE line
  function automatic logic [CVA6Cfg.PLEN-1:0] paddrSizeAlign(input logic [CVA6Cfg.PLEN-1:0] paddr,
                                                             input logic [2:0] size);
    logic [CVA6Cfg.PLEN-1:0] out;
    out = paddr;
    unique case (size)
      3'b001:  out[0:0] = '0;
      3'b010:  out[1:0] = '0;
      3'b011:  out[2:0] = '0;
      3'b111:  out[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] = '0;
      default: ;
    endcase
    return out;
  endfunction : paddrSizeAlign

  // controller FSM
  // AMO_CAS_* : local load-compare-store for AMOCAS.D (64b cmp||swap is 128b
  // on AXI AtomicCompare; axi_riscv_amos rejects multi-beat atomics).
  typedef enum logic [3:0] {
    IDLE,
    DRAIN,
    AMO,
    FLUSH,
    STORE_WAIT,
    LOAD_WAIT,
    AMO_WAIT,
    AMO_CAS_LD,
    AMO_CAS_LD_WAIT,
    AMO_CAS_ST,
    AMO_CAS_ST_WAIT
  } state_e;
  state_e state_d, state_q;

  // Zacas local RMW (dword CAS)
  logic        cas_local_en;  // size==dword && AMO_CAS1
  logic [63:0] cas_old_d, cas_old_q;
  logic [63:0] cas_new_d, cas_new_q;
  logic        cas_ld_ack, cas_st_ack;
  logic        cas_amo_sel;  // drive AMO paddr/size/tid without ATOP
  // Uncached CAS store updates DRAM only; drop any stale L1 line so later
  // cached loads see the new value (CRT stack lines are often hot).
  logic        cas_inv;

  // MSHR for reads
  typedef struct packed {
    logic [CVA6Cfg.PLEN-1:0]                     paddr;
    logic [2:0]                                  size;
    logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0]         vld_bits;
    logic [CVA6Cfg.MEM_TID_WIDTH-1:0]            id;
    logic                                        nc;
    logic [$clog2(CVA6Cfg.DCACHE_SET_ASSOC)-1:0] repl_way;
    logic [$clog2(NumPorts)-1:0]                 miss_port_idx;
  } mshr_t;

  mshr_t mshr_d, mshr_q;
  logic [$clog2(CVA6Cfg.DCACHE_SET_ASSOC)-1:0] repl_way, inv_way, rnd_way;
  logic mshr_vld_d, mshr_vld_q, mshr_vld_q1;
  logic mshr_allocate;
  logic update_lfsr, all_ways_valid;

  logic enable_d, enable_q;
  logic flush_ack_d, flush_ack_q;
  logic flush_en, flush_done;
  logic mask_reads, lock_reqs;
  logic amo_sel, miss_is_write;
  logic amo_req_d, amo_req_q;
  logic [63:0] amo_rtrn_mux;
  logic [CVA6Cfg.XLEN-1:0] amo_data, amo_data_a, amo_data_b;
  logic [CVA6Cfg.XLEN-1:0] amo_user;  //DCACHE USER ? CVA6Cfg.DCACHE_USER_WIDTH
  logic [CVA6Cfg.PLEN-1:0] tmp_paddr;
  logic [$clog2(NumPorts)-1:0] miss_port_idx;
  logic [DCACHE_CL_IDX_WIDTH-1:0] cnt_d, cnt_q;
  logic [NumPorts-1:0] miss_req_masked_d, miss_req_masked_q;

  logic inv_vld, inv_vld_all, cl_write_en;
  logic load_ack, store_ack, amo_ack;

  logic [NumPorts-1:0] mshr_rdrd_collision_d, mshr_rdrd_collision_q;
  logic [NumPorts-1:0] mshr_rdrd_collision;
  logic tx_rdwr_collision, mshr_rdwr_collision;

  ///////////////////////////////////////////////////////
  // input arbitration and general control sigs
  ///////////////////////////////////////////////////////

  assign cache_en_o = enable_q;
  assign cnt_d = (flush_en) ? cnt_q + 1 : '0;
  assign flush_done = (cnt_q == CVA6Cfg.DCACHE_NUM_WORDS - 1);

  // Per-port load vs in-flight store-TX collision. LZC always prefers lower
  // indices (load ports) over the write-buffer port (NumPorts-1). If a load is
  // stalled on tx_rdwr_collision but still wins arbitration, pending store
  // misses never issue → write buffer cannot drain → TX never frees → deadlock
  // on dense ST→LD streams (fill ≥ ~160 B on imafdc). When a store is pending,
  // mask colliding loads so the store port can be selected and TX can retire.
  logic [NumPorts-1:0] load_tx_collision;
  logic                store_pending;
  logic [NumPorts-1:0] miss_req_base;

  always_comb begin : p_load_tx_coll
    load_tx_collision = '0;
    for (int p = 0; p < NumPorts; p++) begin
      if (miss_req_i[p] && !miss_we_i[p]) begin
        for (int k = 0; k < CVA6Cfg.DCACHE_MAX_TX; k++) begin
          load_tx_collision[p] |=
              (miss_paddr_i[p][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]
               == tx_paddr_i[k][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH])
              && tx_vld_i[k];
        end
      end
    end
  end

  assign store_pending = miss_req_i[NumPorts-1] & miss_we_i[NumPorts-1];

  assign miss_req_base = (lock_reqs)  ? miss_req_masked_q :
                         (mask_reads) ? (miss_we_i & miss_req_i) : miss_req_i;
  assign miss_req_masked_d = (store_pending && !lock_reqs)
                           ? (miss_req_base & ~load_tx_collision)
                           : miss_req_base;
  assign miss_is_write = miss_we_i[miss_port_idx];

  // read port arbiter
  lzc #(
      .WIDTH(NumPorts)
  ) i_lzc_reqs (
      .in_i   (miss_req_masked_d),
      .cnt_o  (miss_port_idx),
      .empty_o()
  );

  always_comb begin : p_ack
    miss_ack_o = '0;
    if (!amo_sel) begin
      miss_ack_o[miss_port_idx] = mem_data_ack_i & mem_data_req_o;
    end
  end

  ///////////////////////////////////////////////////////
  // MSHR and way replacement logic (only for read ops)
  ///////////////////////////////////////////////////////

  // find invalid cache line
  lzc #(
      .WIDTH(CVA6Cfg.DCACHE_SET_ASSOC)
  ) i_lzc_inv (
      .in_i   (~miss_vld_bits_i[miss_port_idx]),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  // generate random cacheline index
  lfsr #(
      .LfsrWidth(8),
      .OutWidth (CVA6Cfg.DCACHE_SET_ASSOC_WIDTH)
  ) i_lfsr_inv (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );

  assign repl_way             = (all_ways_valid) ? rnd_way : inv_way;

  assign mshr_d.size          = (mshr_allocate) ? miss_size_i[miss_port_idx] : mshr_q.size;
  assign mshr_d.paddr         = (mshr_allocate) ? miss_paddr_i[miss_port_idx] : mshr_q.paddr;
  assign mshr_d.vld_bits      = (mshr_allocate) ? miss_vld_bits_i[miss_port_idx] : mshr_q.vld_bits;
  assign mshr_d.id            = (mshr_allocate) ? miss_id_i[miss_port_idx] : mshr_q.id;
  assign mshr_d.nc            = (mshr_allocate) ? miss_nc_i[miss_port_idx] : mshr_q.nc;
  assign mshr_d.repl_way      = (mshr_allocate) ? repl_way : mshr_q.repl_way;
  assign mshr_d.miss_port_idx = (mshr_allocate) ? miss_port_idx : mshr_q.miss_port_idx;

  // currently we only have one outstanding read TX, hence an incoming load clears the MSHR
  assign mshr_vld_d           = (mshr_allocate) ? 1'b1 : (load_ack) ? 1'b0 : mshr_vld_q;

  assign miss_o               = (mshr_allocate) ? ~miss_nc_i[miss_port_idx] : 1'b0;


  for (genvar k = 0; k < NumPorts; k++) begin : gen_rdrd_collision
    assign mshr_rdrd_collision[k]   = (mshr_q.paddr[CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == miss_paddr_i[k][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) && (mshr_vld_q | mshr_vld_q1);
    assign mshr_rdrd_collision_d[k] = (!miss_req_i[k]) ? 1'b0 : mshr_rdrd_collision_q[k] | mshr_rdrd_collision[k];
  end

  // read/write collision, stalls the corresponding request
  // write port[NumPorts-1] collides with MSHR_Q
  assign mshr_rdwr_collision = (mshr_q.paddr[CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == miss_paddr_i[NumPorts-1][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) && mshr_vld_q;

  // read collides with inflight TX
  always_comb begin : p_tx_coll
    tx_rdwr_collision = 1'b0;
    for (int k = 0; k < CVA6Cfg.DCACHE_MAX_TX; k++) begin
      tx_rdwr_collision |= (miss_paddr_i[miss_port_idx][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == tx_paddr_i[k][CVA6Cfg.PLEN-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) && tx_vld_i[k];
    end
  end

  ///////////////////////////////////////////////////////
  // to memory
  ///////////////////////////////////////////////////////

  // if size = 32bit word, select appropriate offset, replicate for openpiton...

  if (CVA6Cfg.RVA) begin
    if (CVA6Cfg.IS_XLEN64) begin : gen_amo_64b_data
      assign amo_data_a = {amo_req_i.operand_b[0+:32], amo_req_i.operand_b[0+:32]};
      assign amo_data_b = amo_req_i.operand_b;
    end else begin : gen_amo_32b_data
      assign amo_data_a = amo_req_i.operand_b[0+:32];
    end
  end

  always_comb begin
    if (CVA6Cfg.RVA) begin
      if (CVA6Cfg.IS_XLEN64) begin
        // Zacas AMOCAS.W: pack {cmp[31:0], swap[31:0]} (matches hpdcache)
        // AMOCAS.D: operand_b is swap; cmp travels in operand_c (adapter/ALU)
        if (CVA6Cfg.RVZacas && amo_req_i.amo_op == AMO_CAS1) begin
          if (amo_req_i.size == 2'b10) begin
            amo_data = {amo_req_i.operand_c[31:0], amo_req_i.operand_b[31:0]};
          end else begin
            // Double-word CAS: low=swap, high=cmp (ALU splits)
            amo_data = amo_req_i.operand_b;
          end
        end else if (amo_req_i.size == 2'b10) begin
          amo_data = amo_data_a;
        end else begin
          amo_data = amo_data_b;
        end
      end else begin
        amo_data = amo_data_a;
      end
      if (CVA6Cfg.DATA_USER_EN) begin
        amo_user = amo_data;
      end else begin
        amo_user = '0;
      end
    end
  end

  if (CVA6Cfg.RVA) begin
    // note: openpiton returns a full cacheline!
    if (CVA6Cfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_rtrn_mux
      if (CVA6Cfg.AxiDataWidth > 64) begin
        assign amo_rtrn_mux = mem_rtrn_i.data[amo_req_i.operand_a[$clog2(
            CVA6Cfg.AxiDataWidth/8
        )-1:3]*64+:64];
      end else begin
        assign amo_rtrn_mux = mem_rtrn_i.data[0+:64];
      end
    end else begin : gen_piton_rtrn_mux
      assign amo_rtrn_mux = mem_rtrn_i.data[amo_req_i.operand_a[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3]*64+:64];
    end

    // BIG ENDIAN CAPABLE logic for amo return value from memory
    logic [63:0] amoResult_LE;
    logic [63:0] amoResult_BE;

    // Little Endian Calculation of return value from memory (when 32bit, we need to sign extend)
    logic [63:0] amoResult_32bitLE;
    assign amoResult_32bitLE = {
      {32{amo_rtrn_mux[amo_req_i.operand_a[2]*32+31]}}, amo_rtrn_mux[amo_req_i.operand_a[2]*32+:32]
    };

    // Big Endian Calculations of return value from memory with AMO operations (Bytes need swapping and sign extension is different)
    logic [63:0] amoResult_64bitBE;
    logic [31:0] amoResult_32bitBE_NoSign;
    logic [63:0] amoResult_32bitBE;
    assign amoResult_64bitBE = {<<8{amo_rtrn_mux}};
    assign amoResult_32bitBE_NoSign = {<<8{amo_rtrn_mux[amo_req_i.operand_a[2]*32+:32]}};
    assign amoResult_32bitBE = {
      {32{amo_rtrn_mux[amo_req_i.operand_a[2]*32+7]}}, amoResult_32bitBE_NoSign
    };  // +7 to the base address to find the sign bit, as in BE the Most Significant Byte is always at the lowest addressed byte.

    assign amoResult_BE = (amo_req_i.size == 2'b10) ? amoResult_32bitBE : amoResult_64bitBE;
    assign amoResult_LE = (amo_req_i.size == 2'b10) ? amoResult_32bitLE : amo_rtrn_mux;

    // Local dword CAS returns the saved old value; ATOP path uses mem rtrn mux.
    assign amo_resp_o.result = (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT})
                                   ? cas_old_q
                                   : (mbe_i ? amoResult_BE : amoResult_LE);
    // end BIG ENDIAN CAPABLE logic for amo return value from memory

    assign amo_req_d = amo_req_i.req;
  end

  // Local RMW for AMOCAS.D (size dword). Word CAS stays on AXI AtomicCompare.
  assign cas_local_en = CVA6Cfg.RVA && CVA6Cfg.RVZacas && CVA6Cfg.IS_XLEN64
      && (amo_req_i.amo_op == AMO_CAS1) && (amo_req_i.size == 2'b11);

  // outgoing memory requests (AMOs are always uncached)
  // cas_amo_sel: CAS.D load/store uses AMO address/tid/nc but plain LD/ST rtype
  assign mem_data_o.tid = (CVA6Cfg.RVA && (amo_sel || cas_amo_sel)) ? AmoTxId : miss_id_i[miss_port_idx];
  assign mem_data_o.nc = (CVA6Cfg.RVA && (amo_sel || cas_amo_sel)) ? 1'b1 : miss_nc_i[miss_port_idx];
  assign mem_data_o.way = (CVA6Cfg.RVA && (amo_sel || cas_amo_sel)) ? '0 : repl_way;
  assign mem_data_o.data = (CVA6Cfg.RVA && cas_amo_sel && (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT}))
                               ? cas_new_q
                               : (CVA6Cfg.RVA && amo_sel) ? amo_data : miss_wdata_i[miss_port_idx];
  assign mem_data_o.user = (CVA6Cfg.RVA && amo_sel) ? amo_user : miss_wuser_i[miss_port_idx];
  assign mem_data_o.size   = (CVA6Cfg.RVA && (amo_sel || cas_amo_sel)) ? {1'b0, amo_req_i.size}
                                                                         : miss_size_i[miss_port_idx];
  // Plain load/store for local CAS.D — no AXI ATOP
  assign mem_data_o.amo_op = (CVA6Cfg.RVA && amo_sel && !cas_amo_sel) ? amo_req_i.amo_op : AMO_NONE;

  assign tmp_paddr         = (CVA6Cfg.RVA && (amo_sel || cas_amo_sel))
                                 ? amo_req_i.operand_a[CVA6Cfg.PLEN-1:0]
                                 : miss_paddr_i[miss_port_idx];
  assign mem_data_o.paddr = paddrSizeAlign(tmp_paddr, mem_data_o.size);

  ///////////////////////////////////////////////////////
  // back-off mechanism for LR/SC completion guarantee
  ///////////////////////////////////////////////////////

  logic sc_fail, sc_pass, sc_backoff_over;
  exp_backoff #(
      .Seed  (3),
      .MaxExp(16)
  ) i_exp_backoff (
      .clk_i,
      .rst_ni,
      .set_i    (sc_fail),
      .clr_i    (sc_pass),
      .is_zero_o(sc_backoff_over)
  );

  ///////////////////////////////////////////////////////
  // responses from memory
  ///////////////////////////////////////////////////////

  // keep track of pending stores
  logic store_sent;
  logic [$clog2(CVA6Cfg.DCACHE_MAX_TX + 1)-1:0] stores_inflight_d, stores_inflight_q;
  assign store_sent = mem_data_req_o & mem_data_ack_i & (mem_data_o.rtype == DCACHE_STORE_REQ);

  assign stores_inflight_d = (store_ack && store_sent) ? stores_inflight_q     :
                             (store_ack)               ? stores_inflight_q - 1 :
                             (store_sent)              ? stores_inflight_q + 1 :
                                                         stores_inflight_q;

  // incoming responses
  always_comb begin : p_rtrn_logic
    load_ack        = 1'b0;
    store_ack       = 1'b0;
    amo_ack         = 1'b0;
    cas_ld_ack      = 1'b0;
    cas_st_ack      = 1'b0;
    inv_vld         = 1'b0;
    inv_vld_all     = 1'b0;
    sc_fail         = 1'b0;
    sc_pass         = 1'b0;
    miss_rtrn_vld_o = '0;
    if (mem_rtrn_vld_i) begin
      unique case (mem_rtrn_i.rtype)
        DCACHE_LOAD_ACK: begin
          if (mshr_vld_q) begin
            load_ack = 1'b1;
            miss_rtrn_vld_o[mshr_q.miss_port_idx] = 1'b1;
          end else if (CVA6Cfg.RVA && (state_q inside {AMO_CAS_LD, AMO_CAS_LD_WAIT})) begin
            // Local AMOCAS.D load completed (no MSHR)
            cas_ld_ack = 1'b1;
          end
        end
        DCACHE_STORE_ACK: begin
          if (CVA6Cfg.RVA && (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT}) && stores_inflight_q > 0) begin
            store_ack  = 1'b1;
            cas_st_ack = 1'b1;
          end else if (stores_inflight_q > 0) begin
            store_ack = 1'b1;
            miss_rtrn_vld_o[NumPorts-1] = 1'b1;
          end
        end
        DCACHE_ATOMIC_ACK: begin
          if (CVA6Cfg.RVA) begin
            if (amo_req_q) begin
              amo_ack = 1'b1;
              // need to set SC backoff counter if
              // this op failed
              if (amo_req_i.amo_op == AMO_SC) begin
                if (amo_resp_o.result > 0) begin
                  sc_fail = 1'b1;
                end else begin
                  sc_pass = 1'b1;
                end
              end
            end
          end
        end
        DCACHE_INV_REQ: begin
          inv_vld     = mem_rtrn_i.inv.vld | mem_rtrn_i.inv.all;
          inv_vld_all = mem_rtrn_i.inv.all;
        end
        // TODO:
        // DCACHE_INT_REQ: begin
        // end
        default: begin
        end
      endcase
    end
  end

  // to write buffer
  assign miss_rtrn_id_o = mem_rtrn_i.tid;

  ///////////////////////////////////////////////////////
  // writes to cache memory
  ///////////////////////////////////////////////////////

  // cacheline write port
  assign wr_cl_nc_o = mshr_q.nc;
  assign wr_cl_vld_o = load_ack | (|wr_cl_we_o);

  assign wr_cl_we_o = (flush_en || cas_inv || inv_vld_all) ? '1 :
                      (inv_vld) ? dcache_way_bin2oh(mem_rtrn_i.inv.way) :
                      (cl_write_en) ? dcache_way_bin2oh(mshr_q.repl_way) : '0;

  assign wr_vld_bits_o = (flush_en || cas_inv || inv_vld) ? '0 :
                         (cl_write_en) ? dcache_way_bin2oh(mshr_q.repl_way) : '0;

  assign wr_cl_idx_o =
      (flush_en) ? cnt_q :
      (cas_inv)  ? amo_req_i.operand_a[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] :
      (inv_vld)  ? mem_rtrn_i.inv.idx[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] :
                   mshr_q.paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH];

  assign wr_cl_tag_o = mshr_q.paddr[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
  assign wr_cl_off_o = mshr_q.paddr[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0];
  assign wr_cl_data_o = mem_rtrn_i.data;
  assign wr_cl_user_o = mem_rtrn_i.user;
  assign wr_cl_data_be_o = (cl_write_en) ? '1 : '0;// we only write complete cachelines into the memory

  // only non-NC responses write to the cache
  assign cl_write_en = load_ack & ~mshr_q.nc;

  ///////////////////////////////////////////////////////
  // main control logic for generating tx
  ///////////////////////////////////////////////////////

  always_comb begin : p_fsm
    // default assignment
    state_d          = state_q;

    flush_ack_o      = 1'b0;
    mem_data_o.rtype = DCACHE_LOAD_REQ;
    mem_data_req_o   = 1'b0;
    amo_resp_o.ack   = 1'b0;
    amo_resp_o.result_hi = '0;
    amo_resp_o.dual_we = 1'b0;
    miss_replay_o    = '0;

    // disabling cache is possible anytime, enabling goes via flush
    enable_d         = enable_q & enable_i;
    flush_ack_d      = flush_ack_q;
    flush_en         = 1'b0;
    amo_sel          = 1'b0;
    cas_amo_sel      = 1'b0;
    cas_inv          = 1'b0;
    cas_old_d        = cas_old_q;
    cas_new_d        = cas_new_q;
    update_lfsr      = 1'b0;
    mshr_allocate    = 1'b0;
    lock_reqs        = 1'b0;
    mask_reads       = mshr_vld_q;

    // interfaces
    unique case (state_q)
      //////////////////////////////////
      // wait for misses / amo ops
      IDLE: begin
        if (flush_i || (enable_i && !enable_q)) begin
          if (wbuffer_empty_i && !mshr_vld_q) begin
            flush_ack_d = flush_i;
            state_d     = FLUSH;
          end else begin
            state_d = DRAIN;
          end
        end else if (CVA6Cfg.RVA && amo_req_i.req) begin
          if (wbuffer_empty_i && !mshr_vld_q) begin
            state_d = AMO;
          end else begin
            state_d = DRAIN;
          end
          // we've got a miss to handle
        end else if (|miss_req_masked_d) begin
          // this is a write miss, just pass through (but check whether write collides with MSHR)
          if (miss_is_write) begin
            // stall in case this write collides with the MSHR address
            if (!mshr_rdwr_collision) begin
              mem_data_req_o   = 1'b1;
              mem_data_o.rtype = DCACHE_STORE_REQ;
              if (!mem_data_ack_i) begin
                state_d = STORE_WAIT;
              end
            end
            // this is a read miss, can only allocate 1 MSHR
            // in case of a load_ack we can accept a new miss, since the MSHR is being cleared
          end else if (!mshr_vld_q || load_ack) begin
            // replay the read request in case the address has collided with MSHR during the time the request was pending
            // i.e., the cache state may have been updated in the mean time due to a refill at the same CL address
            if (mshr_rdrd_collision_d[miss_port_idx]) begin
              miss_replay_o[miss_port_idx] = 1'b1;
              // Previously stalled forever on tx_rdwr_collision (load vs in-flight
              // store TX). That deadlocks when the load port wins arbitration and
              // store misses cannot retire the TX. For write-through, memory already
              // has (or is receiving) the store; allow the load miss to issue. The
              // wbuffer still forwards dirty bytes on the read data path.
            end else begin
              mem_data_req_o   = 1'b1;
              mem_data_o.rtype = DCACHE_LOAD_REQ;
              update_lfsr      = all_ways_valid & mem_data_ack_i;  // need to evict a random way
              mshr_allocate    = mem_data_ack_i;
              if (!mem_data_ack_i) begin
                state_d = LOAD_WAIT;
              end
            end
          end
        end
      end
      //////////////////////////////////
      // wait until this request is acked
      STORE_WAIT: begin
        lock_reqs        = 1'b1;
        mem_data_req_o   = 1'b1;
        mem_data_o.rtype = DCACHE_STORE_REQ;
        if (mem_data_ack_i) begin
          state_d = IDLE;
        end
      end
      //////////////////////////////////
      // wait until this request is acked
      LOAD_WAIT: begin
        lock_reqs        = 1'b1;
        mem_data_req_o   = 1'b1;
        mem_data_o.rtype = DCACHE_LOAD_REQ;
        if (mem_data_ack_i) begin
          update_lfsr   = all_ways_valid;  // need to evict a random way
          mshr_allocate = 1'b1;
          state_d       = IDLE;
        end
      end
      //////////////////////////////////
      // only handle stores, do not accept new read requests
      // wait until MSHR is cleared and wbuffer is empty
      DRAIN: begin
        mask_reads = 1'b1;
        // these are writes, check whether they collide with MSHR
        if (|miss_req_masked_d && !mshr_rdwr_collision) begin
          mem_data_req_o   = 1'b1;
          mem_data_o.rtype = DCACHE_STORE_REQ;
        end

        if (wbuffer_empty_i && !mshr_vld_q) begin
          state_d = IDLE;
        end
      end
      //////////////////////////////////
      // flush the cache
      FLUSH: begin
        // internal flush signal
        flush_en = 1'b1;
        if (flush_done) begin
          state_d     = IDLE;
          flush_ack_o = flush_ack_q;
          flush_ack_d = 1'b0;
          enable_d    = enable_i;
        end
      end
      //////////////////////////////////
      // send out amo op request
      AMO: begin
        if (CVA6Cfg.RVA) begin
          if (cas_local_en) begin
            // AMOCAS.D: local uncached load → compare → store
            state_d = AMO_CAS_LD;
          end else begin
            mem_data_o.rtype = DCACHE_ATOMIC_REQ;
            amo_sel          = 1'b1;
            // if this is an LR, we need to consult the backoff counter
            if ((amo_req_i.amo_op != AMO_LR) || sc_backoff_over) begin
              mem_data_req_o = 1'b1;
              if (mem_data_ack_i) begin
                state_d = AMO_WAIT;
              end
            end
          end
        end
      end
      //////////////////////////////////
      // block and wait until AMO OP returns
      AMO_WAIT: begin
        if (CVA6Cfg.RVA) begin
          amo_sel = 1'b1;
          if (amo_ack) begin
            amo_resp_o.ack = 1'b1;
            state_d        = IDLE;
          end
        end
      end
      //////////////////////////////////
      // AMOCAS.D local RMW: issue uncached load of the CAS address
      AMO_CAS_LD: begin
        if (CVA6Cfg.RVA) begin
          cas_amo_sel      = 1'b1;
          mem_data_o.rtype = DCACHE_LOAD_REQ;
          mem_data_req_o   = 1'b1;
          if (mem_data_ack_i) begin
            state_d = AMO_CAS_LD_WAIT;
          end
        end
      end
      AMO_CAS_LD_WAIT: begin
        if (CVA6Cfg.RVA) begin
          cas_amo_sel = 1'b1;
          if (cas_ld_ack) begin
            // Full 64-bit lane (dword CAS is naturally aligned)
            cas_old_d = amo_rtrn_mux;
            cas_new_d = (amo_rtrn_mux == amo_req_i.operand_c) ? amo_req_i.operand_b
                                                              : amo_rtrn_mux;
            state_d   = AMO_CAS_ST;
          end
        end
      end
      AMO_CAS_ST: begin
        if (CVA6Cfg.RVA) begin
          cas_amo_sel      = 1'b1;
          mem_data_o.rtype = DCACHE_STORE_REQ;
          mem_data_req_o   = 1'b1;
          if (mem_data_ack_i) begin
            state_d = AMO_CAS_ST_WAIT;
          end
        end
      end
      AMO_CAS_ST_WAIT: begin
        if (CVA6Cfg.RVA) begin
          cas_amo_sel = 1'b1;
          if (cas_st_ack) begin
            // Drop L1 line for CAS paddr (uncached store does not update D$).
            cas_inv        = 1'b1;
            amo_resp_o.ack = 1'b1;
            state_d        = IDLE;
          end
        end
      end
      //////////////////////////////////
      default: begin
        // we should never get here
        state_d = IDLE;
      end
    endcase  // state_q
  end

  ///////////////////////////////////////////////////////
  // ff's
  ///////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      state_q               <= FLUSH;
      cnt_q                 <= '0;
      enable_q              <= '0;
      flush_ack_q           <= '0;
      mshr_vld_q            <= '0;
      mshr_vld_q1           <= '0;
      mshr_q                <= '0;
      mshr_rdrd_collision_q <= '0;
      miss_req_masked_q     <= '0;
      amo_req_q             <= '0;
      stores_inflight_q     <= '0;
      cas_old_q             <= '0;
      cas_new_q             <= '0;
    end else begin
      state_q               <= state_d;
      cnt_q                 <= cnt_d;
      enable_q              <= enable_d;
      flush_ack_q           <= flush_ack_d;
      mshr_vld_q            <= mshr_vld_d;
      mshr_vld_q1           <= mshr_vld_q;
      mshr_q                <= mshr_d;
      mshr_rdrd_collision_q <= mshr_rdrd_collision_d;
      miss_req_masked_q     <= miss_req_masked_d;
      amo_req_q             <= amo_req_d;
      stores_inflight_q     <= stores_inflight_d;
      cas_old_q             <= cas_old_d;
      cas_new_q             <= cas_new_d;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
`ifndef VERILATOR

  read_tid :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) mshr_vld_q |-> mem_rtrn_vld_i |-> load_ack |-> mem_rtrn_i.tid == mshr_q.id)
  else $fatal(1, "[l1 dcache missunit] TID of load response doesn't match");

  read_ports :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) |miss_req_i[NumPorts-2:0] |-> miss_we_i[NumPorts-2:0] == 0)
  else $fatal(1, "[l1 dcache missunit] only last port can issue write requests");

  write_port :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) miss_req_i[NumPorts-1] |-> miss_we_i[NumPorts-1])
  else $fatal(1, "[l1 dcache missunit] last port can only issue write requests");

  initial begin
    // assert wrong parameterizations
    assert (NumPorts >= 2)
    else
      $fatal(
          1, "[l1 dcache missunit] at least two ports are required (one read port, one write port)"
      );
  end
`endif
  //pragma translate_on

endmodule  // wt_dcache_missunit
