// Copyright 2017-2019 ETH Zurich and University of Bologna.
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
// Modified by: Etienne Cimon
// Date: 19.03.2017
// Description: CVA6 Top-level module

`include "rvfi_types.svh"
`include "cvxif_types.svh"

module cva6
  import ariane_pkg::*;
#(
    // CVA6 config
    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(
        cva6_config_pkg::cva6_cfg
    ),

    // RVFI PROBES
    parameter type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg),
    parameter type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg),
    parameter type rvfi_probes_t = struct packed {
      rvfi_probes_csr_t   csr;
      rvfi_probes_instr_t instr;
    },

    // branchpredict scoreboard entry
    // this is the struct which we will inject into the pipeline to guide the various
    // units towards the correct branch decision and resolve
    localparam type branchpredict_sbe_t = struct packed {
      cf_t                     cf;               // type of control flow prediction
      logic [CVA6Cfg.VLEN-1:0] predict_address;  // target address at which to jump, or not
      // T21: identity of the BP checkpoint allocated for this control flow at
      // fetch (0 when none: no TAGE fabric, buffer full, not a CF) and the
      // decoded call flag, so the resolve path frees/restores its own
      // checkpoint and re-applies its own RAS effect.
      logic                    ckpt_v;
      logic [7:0]              ckpt_idx;
      logic                    is_call;
    },

    parameter type exception_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] cause;  // cause of exception
      logic [CVA6Cfg.XLEN-1:0] tval;  // additional information of causing exception (e.g.: instruction causing it),
      // address of LD/ST fault
      logic [CVA6Cfg.GPLEN-1:0] tval2;  // additional information when the causing exception in a guest exception
      logic [31:0] tinst;  // transformed instruction information
      logic gva;  // signals when a guest virtual address is written to tval
      logic valid;
    },

    // cache request ports
    // I$ address translation requests
    localparam type icache_areq_t = struct packed {
      logic                    fetch_valid;      // address translation valid
      logic [CVA6Cfg.PLEN-1:0] fetch_paddr;      // physical address in
      exception_t              fetch_exception;  // exception occurred during fetch
    },
    localparam type icache_arsp_t = struct packed {
      logic                    fetch_req;    // address translation request
      logic [CVA6Cfg.VLEN-1:0] fetch_vaddr;  // virtual address out
    },

    // I$ data requests
    localparam type icache_dreq_t = struct packed {
      logic                    req;      // we request a new word
      logic                    kill_s1;  // kill the current request
      logic                    kill_s2;  // kill the last request
      logic                    spec;     // request is speculative
      logic [1:0]              token;    // response ownership token
      logic [CVA6Cfg.VLEN-1:0] vaddr;    // 1st cycle: 12 bit index is taken for lookup
    },
    localparam type icache_drsp_t = struct packed {
      logic                                ready;  // icache is ready
      logic                                valid;  // signals a valid read
      logic [CVA6Cfg.FETCH_WIDTH-1:0]      data;   // 2+ cycle out: tag
      logic [CVA6Cfg.FETCH_USER_WIDTH-1:0] user;   // User bits
      logic [1:0]                          token;  // accepted request's token
      logic [CVA6Cfg.VLEN-1:0]             vaddr;  // virtual address out
      exception_t                          ex;     // we've encountered an exception
    },

    // SMT thread id width (1 when NrHarts==1 → constant-0 tag, inert netlist)
    localparam int unsigned HART_ID_BITS =
        (CVA6Cfg.NrHarts <= 1) ? 1 : $clog2(CVA6Cfg.NrHarts),

    // IF/ID Stage
    // store the decompressed instruction
    localparam type fetch_entry_t = struct packed {
      logic [CVA6Cfg.VLEN-1:0] address;  // the address of the instructions from below
      logic [31:0] instruction;  // instruction word
      branchpredict_sbe_t     branch_predict; // this field contains branch prediction information regarding the forward branch path
      exception_t             ex;             // this field contains exceptions which might have happened earlier, e.g.: fetch exceptions
      logic [HART_ID_BITS-1:0] hart_id;  // U6.1 SMT thread tag (0 when NrHarts==1)
    },
    //JVT struct{base,mode}
    localparam type jvt_t = struct packed {
      logic [CVA6Cfg.XLEN-7:0] base;
      logic [5:0] mode;
    },

    // ID/EX/WB Stage
    localparam type scoreboard_entry_t = struct packed {
      logic [CVA6Cfg.VLEN-1:0] pc;  // PC of instruction
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;      // this can potentially be simplified, we could index the scoreboard entry
      // with the transaction id in any case make the width more generic
      fu_t fu;  // functional unit to use
      fu_op op;  // operation to perform in each functional unit
      logic [REG_ADDR_SIZE-1:0] rs1;  // register source address 1
      logic [REG_ADDR_SIZE-1:0] rs2;  // register source address 2
      logic [REG_ADDR_SIZE-1:0] rd;  // register destination address
      logic [CVA6Cfg.XLEN-1:0] result;  // for unfinished instructions this field also holds the immediate,
      // for unfinished floating-point that are partly encoded in rs2, this field also holds rs2
      // for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
      // this field holds the address of the third operand from the floating-point register file
      logic valid;  // is the result valid
      logic use_imm;  // should we use the immediate as operand b?
      logic use_zimm;  // use zimm as operand a
      logic use_pc;  // set if we need to use the PC as operand a, PC from exception
      exception_t ex;  // exception has occurred
      branchpredict_sbe_t bp;  // branch predict scoreboard data structure
      logic                     is_compressed; // signals a compressed instructions, we need this information at the commit stage if
                                               // we want jump accordingly e.g.: +4, +2
      logic is_macro_instr;  // is an instruction executed as predefined sequence of instructions called macro definition
      logic is_last_macro_instr;  // is last decoded 32bit instruction of macro definition
      logic is_double_rd_macro_instr;  // is double move decoded 32bit instruction of macro definition
      logic vfp;  // is this a vector floating-point instruction?
      logic is_zcmt;  //is a zcmt instruction
      logic [HART_ID_BITS-1:0] hart_id;  // U6.1 SMT thread tag (0 when NrHarts==1)
      // U5 OoO phys tags (0 / unused when OoOEn=0; max 256 PRF)
      logic [7:0] p_rs1;
      logic [7:0] p_rs2;
      logic [7:0] p_rd;
      // U6 Phase5 split FP class: its own tags, because the FP physical file
      // is a separate array. p_frs3 has no integer counterpart -- only FP has
      // a third source, and its architectural number arrives in result[4:0].
      logic [7:0] p_frs1;
      logic [7:0] p_frs2;
      logic [7:0] p_frs3;
      logic [7:0] p_frd;
      logic       ooo_renamed;  // tags valid for PRF operand path
    },
    localparam type writeback_t = struct packed {
      logic valid;  // wb data is valid
      logic [CVA6Cfg.XLEN-1:0] data;  //wb data
      logic ex_valid;  // exception from WB
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;  //transaction ID
    },

    // branch-predict
    // this is the struct we get back from ex stage and we will use it to update
    // all the necessary data structures
    // bp_resolve_t
    localparam type bp_resolve_t = struct packed {
      logic                    valid;           // prediction with all its values is valid
      logic [CVA6Cfg.VLEN-1:0] pc;              // PC of predict or mis-predict
      logic [CVA6Cfg.VLEN-1:0] target_address;  // target address at which to jump, or not
      logic                    is_mispredict;   // set if this was a mis-predict
      logic                    is_taken;        // branch is taken
      cf_t                     cf_type;         // Type of control flow change
      logic [HART_ID_BITS-1:0] hart_id;         // FSE S5: resolving branch's SMT hart (0 if NrHarts==1)
      // Hang-7: restore GHR/RAS ckpt only on real wrong-path (not Return verify bubble)
      logic                    ckpt_restore;
      // R3a: resolving branch's SB trans_id (cancel younger must not use FLU_WB
      // when mult/ALU shares the FLU port the same cycle as branch resolve).
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
      // T21: the resolving CF's BP checkpoint identity (from branch_predict),
      // its call flag and its link address (pc + 2/4) for the RAS re-push.
      logic                    ckpt_v;
      logic [7:0]              ckpt_idx;
      logic                    is_call;
      logic [CVA6Cfg.VLEN-1:0] next_pc;
    },

    // All information needed to determine whether we need to associate an interrupt
    // with the corresponding instruction or not.
    localparam type irq_ctrl_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] mie;
      logic [CVA6Cfg.XLEN-1:0] mip;
      logic [CVA6Cfg.XLEN-1:0] mideleg;
      logic [CVA6Cfg.XLEN-1:0] hideleg;
      logic                    sie;
      logic                    global_enable;
    },

    localparam type lsu_ctrl_t = struct packed {
      logic                             valid;
      logic [CVA6Cfg.VLEN-1:0]          vaddr;
      logic [31:0]                      tinst;
      logic                             hs_ld_st_inst;
      logic                             hlvx_inst;
      logic                             overflow;
      logic                             g_overflow;
      logic [CVA6Cfg.XLEN-1:0]          data;
      // Zacas AMOCAS expected value (operand_c); 0 for non-CAS
      logic [CVA6Cfg.XLEN-1:0]          data_cmp;
      // AMOCAS.Q high halves (0 when not Q)
      logic [CVA6Cfg.XLEN-1:0]          data_hi;
      logic [CVA6Cfg.XLEN-1:0]          data_cmp_hi;
      logic [(CVA6Cfg.XLEN/8)-1:0]      be;
      fu_t                              fu;
      fu_op                             operation;
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
      // T6b: owning SMT hart of the load/store (0 when NrHarts==1) — the
      // store buffer's speculative forwarding is same-hart only under OoO
      // multi-hart.
      logic [HART_ID_BITS-1:0]          hart;
      logic                             is_speculative_load;
      logic                             is_speculative_load_miss;
    },


    localparam type cbo_t = logic [7:0],

    localparam type fu_data_t = struct packed {
      fu_t                              fu;
      fu_op                             operation;
      logic [CVA6Cfg.XLEN-1:0]          operand_a;
      logic [CVA6Cfg.XLEN-1:0]          operand_b;
      logic [CVA6Cfg.XLEN-1:0]          imm;
      // Zacas: expected/compare value for AMOCAS (0 when unused). Not used in addr calc.
      logic [CVA6Cfg.XLEN-1:0]          operand_c;
      // AMOCAS.Q high halves (new=rs2+1, expected=rd+1)
      logic [CVA6Cfg.XLEN-1:0]          operand_b_hi;
      logic [CVA6Cfg.XLEN-1:0]          operand_c_hi;
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
      // T6b: issuing instruction's SMT hart, carried into the LSU so store
      // ownership is known (0 when NrHarts==1).
      logic [HART_ID_BITS-1:0]          hart;
    },

    localparam type icache_req_t = struct packed {
      logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;  // way to replace
      logic [CVA6Cfg.PLEN-1:0] paddr;  // physical address
      logic nc;  // noncacheable
      logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;  // thread id (used as transaction id in Ariane)
    },
    localparam type icache_rtrn_t = struct packed {
      wt_cache_pkg::icache_in_t rtype;  // see definitions above
      logic [CVA6Cfg.ICACHE_LINE_WIDTH-1:0] data;  // full cache line width
      logic [CVA6Cfg.ICACHE_USER_LINE_WIDTH-1:0] user;  // user bits
      struct packed {
        logic                                      vld;  // invalidate only affected way
        logic                                      all;  // invalidate all ways
        logic [CVA6Cfg.ICACHE_INDEX_WIDTH-1:0]     idx;  // physical address to invalidate
        logic [CVA6Cfg.ICACHE_SET_ASSOC_WIDTH-1:0] way;  // way to invalidate
      } inv;  // invalidation vector
      logic [CVA6Cfg.MEM_TID_WIDTH-1:0] tid;  // thread id (used as transaction id in Ariane)
    },

    // D$ data requests
    localparam type dcache_req_i_t = struct packed {
      logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
      logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
      logic [CVA6Cfg.XLEN-1:0]               data_wdata;
      logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
      logic                                  data_req;
      logic                                  data_we;
      logic [(CVA6Cfg.XLEN/8)-1:0]           data_be;
      logic [1:0]                            data_size;
      logic [CVA6Cfg.DcacheIdWidth-1:0]      data_id;
      logic                                  kill_req;
      logic                                  tag_valid;
      cbo_t                                  cbo_op;
    },

    localparam type dcache_req_o_t = struct packed {
      logic                                 data_gnt;
      logic                                 data_rvalid;
      logic [CVA6Cfg.DcacheIdWidth-1:0]     data_rid;
      logic [CVA6Cfg.XLEN-1:0]              data_rdata;
      logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] data_ruser;
    },

    // Accelerator - CVA6
    parameter type accelerator_req_t  = logic,
    parameter type accelerator_resp_t = logic,

    // Accelerator - CVA6's MMU
    parameter type acc_mmu_req_t  = logic,
    parameter type acc_mmu_resp_t = logic,

    // AXI types
    parameter type axi_ar_chan_t = struct packed {
      logic [CVA6Cfg.AxiIdWidth-1:0]   id;
      logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
      axi_pkg::len_t                   len;
      axi_pkg::size_t                  size;
      axi_pkg::burst_t                 burst;
      logic                            lock;
      axi_pkg::cache_t                 cache;
      axi_pkg::prot_t                  prot;
      axi_pkg::qos_t                   qos;
      axi_pkg::region_t                region;
      logic [CVA6Cfg.AxiUserWidth-1:0] user;
    },
    parameter type axi_aw_chan_t = struct packed {
      logic [CVA6Cfg.AxiIdWidth-1:0]   id;
      logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
      axi_pkg::len_t                   len;
      axi_pkg::size_t                  size;
      axi_pkg::burst_t                 burst;
      logic                            lock;
      axi_pkg::cache_t                 cache;
      axi_pkg::prot_t                  prot;
      axi_pkg::qos_t                   qos;
      axi_pkg::region_t                region;
      axi_pkg::atop_t                  atop;
      logic [CVA6Cfg.AxiUserWidth-1:0] user;
    },
    parameter type axi_w_chan_t = struct packed {
      logic [CVA6Cfg.AxiDataWidth-1:0]     data;
      logic [(CVA6Cfg.AxiDataWidth/8)-1:0] strb;
      logic                                last;
      logic [CVA6Cfg.AxiUserWidth-1:0]     user;
    },
    parameter type b_chan_t = struct packed {
      logic [CVA6Cfg.AxiIdWidth-1:0]   id;
      axi_pkg::resp_t                  resp;
      logic [CVA6Cfg.AxiUserWidth-1:0] user;
    },
    parameter type r_chan_t = struct packed {
      logic [CVA6Cfg.AxiIdWidth-1:0]   id;
      logic [CVA6Cfg.AxiDataWidth-1:0] data;
      axi_pkg::resp_t                  resp;
      logic                            last;
      logic [CVA6Cfg.AxiUserWidth-1:0] user;
    },
    parameter type noc_req_t = struct packed {
      axi_aw_chan_t aw;
      logic         aw_valid;
      axi_w_chan_t  w;
      logic         w_valid;
      logic         b_ready;
      axi_ar_chan_t ar;
      logic         ar_valid;
      logic         r_ready;
    },
    parameter type noc_resp_t = struct packed {
      logic    aw_ready;
      logic    ar_ready;
      logic    w_ready;
      logic    b_valid;
      b_chan_t b;
      logic    r_valid;
      r_chan_t r;
    },
    //
    parameter type acc_cfg_t = logic,
    parameter acc_cfg_t AccCfg = '0,
    // CVXIF Types
    parameter type readregflags_t = `READREGFLAGS_T(CVA6Cfg),
    parameter type writeregflags_t = `WRITEREGFLAGS_T(CVA6Cfg),
    parameter type id_t = `ID_T(CVA6Cfg),
    parameter type hartid_t = `HARTID_T(CVA6Cfg),
    parameter type x_compressed_req_t = `X_COMPRESSED_REQ_T(CVA6Cfg, hartid_t),
    parameter type x_compressed_resp_t = `X_COMPRESSED_RESP_T(CVA6Cfg),
    parameter type x_issue_req_t = `X_ISSUE_REQ_T(CVA6Cfg, hartid_t, id_t),
    parameter type x_issue_resp_t = `X_ISSUE_RESP_T(CVA6Cfg, writeregflags_t, readregflags_t),
    parameter type x_register_t = `X_REGISTER_T(CVA6Cfg, hartid_t, id_t, readregflags_t),
    parameter type x_commit_t = `X_COMMIT_T(CVA6Cfg, hartid_t, id_t),
    parameter type x_result_t = `X_RESULT_T(CVA6Cfg, hartid_t, id_t, writeregflags_t),
    parameter type cvxif_req_t =
    `CVXIF_REQ_T(CVA6Cfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t),
    parameter type cvxif_resp_t =
    `CVXIF_RESP_T(CVA6Cfg, x_compressed_resp_t, x_issue_resp_t, x_result_t)
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Reset boot address - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Hard ID reflected as CSR - SUBSYSTEM
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // Level sensitive (async) interrupts - SUBSYSTEM
    // Per SMT hart: [hart][1:0] = {MEIP, SEIP} (width 1 when NrHarts==1 → [0][1:0])
    input logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][1:0] irq_i,
    // Inter-processor (async) interrupt - SUBSYSTEM (one bit per SMT hart)
    input logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] ipi_i,
    // Timer (async) interrupt - SUBSYSTEM (one bit per SMT hart / CLINT slot)
    input logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] time_irq_i,
    // Platform mtime counter value, only used when CVA6Cfg.SstcEn - SUBSYSTEM
    // Sstc keeps the counter in the platform timer (CLINT) and the stimecmp
    // comparator in the hart, so the hart needs to observe the value. Tie to '0
    // when SstcEn is disabled; nothing reads it in that case.
    input logic [63:0] rtc_time_i,
    // Debug (async) request - SUBSYSTEM
    input logic debug_req_i,
    // Probes to build RVFI, can be left open when not used - RVFI
    output rvfi_probes_t rvfi_probes_o,
    // CVXIF request - SUBSYSTEM
    output cvxif_req_t cvxif_req_o,
    // CVXIF response - SUBSYSTEM
    input cvxif_resp_t cvxif_resp_i,
    // Xg6lcai AI CSR sideband for the CVXIF coprocessor (tie inputs 0 when unused)
    output logic [CVA6Cfg.XLEN-1:0] ai_aicfg_o,
    output logic [1:0]              ai_ais_o,
    output logic                    ai_issue_ok_o,
    output logic                    ai_q_en_o,
    output logic [7:0]              ai_qid_o,
    input  logic                    dirty_ai_state_i,
    input  logic                    ai_setcfg_we_i,
    input  logic [CVA6Cfg.XLEN-1:0] ai_setcfg_wdata_i,
    // Xg6lcai PMU group-4 probes (tie 0 when no AI coprocessor)
    input  logic                    ai_pmu_op_i,
    input  logic                    ai_pmu_mma_i,
    input  logic                    ai_pmu_post_i,
    input  logic                    ai_pmu_t0_i,
    input  logic                    ai_pmu_busy_i,
    // noc request, can be AXI or OpenPiton - SUBSYSTEM
    output noc_req_t noc_req_o,
    // noc response, can be AXI or OpenPiton - SUBSYSTEM
    input noc_resp_t noc_resp_i,
    // U6.2 external L1 invalidation (coherence hub). Tie valid=0 when unused.
    // WT and HPDCACHE both consume these: WT turns them into a DCACHE_INV_REQ in
    // wt_axi_adapter, HPDCACHE injects them on its read-response invalidation
    // port (cva6_hpdcache_subsystem), which invalidates the directory line. Only
    // the std path acks without acting. The earlier note here claimed HPDCACHE
    // ignored them, which reads as "multi-core coherence is broken on HPDCACHE
    // configs" — it is not, and g6lc64_stream8 runs NrCores=2 with HPDCACHE_WT.
    //
    // These invalidations do NOT clear the hart-local LR/SC reservation buffer in
    // hpdcache_uncached (only a local store/AMO does). That is sound rather than a
    // gap: the authoritative reservation is the downstream exclusive monitor, so a
    // stale-valid local reservation only lets the SC reach memory, where it is
    // adjudicated. The local buffer can therefore fail an SC early but can never
    // grant one on its own. See the AxLOCK forwarding note in g6lc_l2_top.
    input  logic [63:0] l1_inval_addr_i,
    input  logic        l1_inval_valid_i,
    output logic        l1_inval_ready_o,
    // T9a eWT CMO sideband: Zicbom cache-block ops leave the core on this
    // channel when L2CmoEn propagates them into the hierarchy. cmo_op_o
    // encodes 0=inval, 1=clean, 2=flush; cmo_addr_o is the physical address.
    // When L2CmoEn=0 the core completes the CBO locally (L1 inval / buffer
    // drain) and these ports stay idle — tie ready/done to 0.
    output logic                    cmo_valid_o,
    output logic [1:0]              cmo_op_o,
    output logic [CVA6Cfg.PLEN-1:0] cmo_addr_o,
    input  logic                    cmo_ready_i,
    input  logic                    cmo_done_i,
    // PMU group 2: SoC L2/L3/PF probes (tie 0 for single-core / no hierarchy)
    input  logic        l2_miss_i,
    input  logic        l3_hit_i,
    input  logic        l3_miss_i,
    input  logic        pf_issue_i,
    input  logic        pf_train_i,
    // T9b: posted-write hold cycles at L2 / L3 (group-2 indices 7 / 8)
    input  logic        l2_pwhold_i,
    input  logic        l3_pwhold_i,
    // T9h/M5: L2 prefetcher pulses (group-2 indices 9 / 10)
    input  logic        l2_pf_issue_i,
    input  logic        l2_pf_useful_i
);

  localparam type interrupts_t = struct packed {
    logic [CVA6Cfg.XLEN-1:0] S_SW;
    logic [CVA6Cfg.XLEN-1:0] VS_SW;
    logic [CVA6Cfg.XLEN-1:0] M_SW;
    logic [CVA6Cfg.XLEN-1:0] S_TIMER;
    logic [CVA6Cfg.XLEN-1:0] VS_TIMER;
    logic [CVA6Cfg.XLEN-1:0] M_TIMER;
    logic [CVA6Cfg.XLEN-1:0] S_EXT;
    logic [CVA6Cfg.XLEN-1:0] VS_EXT;
    logic [CVA6Cfg.XLEN-1:0] M_EXT;
    logic [CVA6Cfg.XLEN-1:0] HS_EXT;
    logic [CVA6Cfg.XLEN-1:0] LCOF;
  };

  localparam interrupts_t INTERRUPTS = '{
      S_SW: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_S_SOFT),
      VS_SW: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_VS_SOFT),
      M_SW: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_M_SOFT),
      S_TIMER: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_S_TIMER),
      VS_TIMER: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_VS_TIMER),
      M_TIMER: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_M_TIMER),
      S_EXT: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_S_EXT),
      VS_EXT: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_VS_EXT),
      M_EXT: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_M_EXT),
      HS_EXT: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_HS_EXT),
      LCOF: (CVA6Cfg.XLEN'(1) << (CVA6Cfg.XLEN - 1)) | CVA6Cfg.XLEN'(riscv::IRQ_LCOF)
  };

  // ------------------------------------------
  // Global Signals
  // Signals connecting more than one module
  // ------------------------------------------
  riscv::priv_lvl_t priv_lvl;
  logic v;
  exception_t ex_commit;  // exception from commit stage
  bp_resolve_t resolved_branch;
  bp_resolve_t resolved_branch_fe;
  bp_resolve_t resolved_branch_ctrl;
`ifndef G6LC_FETCH_B
  // G1gq: A-only commit-time JALR salvage redirect. Dropped from B at
  // 3745cfb06; issue_stage still declares the ports under the same guard.
  logic                    g1gq_redir;
  logic [CVA6Cfg.VLEN-1:0] g1gq_tgt;
`endif
  logic [CVA6Cfg.NrHarts-1:0] g1mf_v;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1mf_rd;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1mf_line;
  logic [CVA6Cfg.NrHarts-1:0] g1mf_a3;
  logic [CVA6Cfg.VLEN-1:0] pc_commit;
  logic eret;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_macro_ack;
  logic mbe;  // determines the data endian-ness of the processor

  localparam NumPorts = 4;

  // CVXIF
  cvxif_req_t cvxif_req;
  // CVXIF OUTPUTS
  logic x_compressed_valid;
  x_compressed_req_t x_compressed_req;
  logic x_issue_valid;
  x_issue_req_t x_issue_req;
  logic x_register_valid;
  x_register_t x_register;
  logic x_commit_valid;
  x_commit_t x_commit;
  logic x_result_ready;
  // CVXIF INPUTS
  logic x_compressed_ready;
  x_compressed_resp_t x_compressed_resp;
  logic x_issue_ready;
  x_issue_resp_t x_issue_resp;
  logic x_register_ready;
  logic x_result_valid;
  x_result_t x_result;

  // --------------
  // PCGEN <-> CSR
  // --------------
  logic [CVA6Cfg.VLEN-1:0] trap_vector_base_commit_pcgen;
  logic [CVA6Cfg.VLEN-1:0] epc_commit_pcgen;
  // --------------
  // IF <-> ID
  // --------------
  fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_if_id;
  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_valid_if_id;
  logic [CVA6Cfg.NrIssuePorts-1:0] fetch_ready_id_if;

  // --------------
  // ID <-> ISSUE
  // --------------
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_entry_id_issue, issue_entry_id_issue_prev;
  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_id_issue;
  logic [CVA6Cfg.NrIssuePorts-1:0] issue_entry_valid_id_issue;
  logic [CVA6Cfg.NrIssuePorts-1:0] is_ctrl_fow_id_issue;
  logic [CVA6Cfg.NrIssuePorts-1:0] issue_instr_issue_id;

  // --------------
  // ISSUE <-> EX
  // --------------
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs1_forwarding_id_ex;  // unregistered version of fu_data_o.operanda
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs2_forwarding_id_ex;  // unregistered version of fu_data_o.operandb
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs1;
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs2;
  logic [CVA6Cfg.NrIssuePorts-1:0] rvfi_operand_valid;
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_operand_tid;

  fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_id_ex;
  alu_bypass_t alu_bypass_id_ex;
  logic [CVA6Cfg.VLEN-1:0] pc_id_ex;
  logic [HART_ID_BITS-1:0] branch_hart_id_ex;
  // FP-2: hart of the FPU op in EX — under mixed residency frm/fprec must
  // come from the issuing op's hart, not the active one.
  logic [HART_ID_BITS-1:0] fpu_hart_id_ex;
  logic zcmt_id_ex;
  logic is_compressed_instr_id_ex;
  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_ex;
  // fixed latency units
  logic flu_ready_ex_id;
  logic csr_ready_ex_id;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] flu_trans_id_ex_id;
  logic flu_valid_ex_id;
  logic [CVA6Cfg.XLEN-1:0] flu_result_ex_id;
  exception_t flu_exception_ex_id;
  // ALU
  logic [CVA6Cfg.NrIssuePorts-1:0] alu_valid_id_ex;
  logic [5:0] orig_instr_aes;
  logic [CVA6Cfg.NrIssuePorts-1:0] aes_valid_id_ex;
  // Branches and Jumps
  logic [CVA6Cfg.NrIssuePorts-1:0] branch_valid_id_ex;

  branchpredict_sbe_t branch_predict_id_ex;
  logic resolve_branch_ex_id;
  // LSU
  logic [CVA6Cfg.NrIssuePorts-1:0] lsu_valid_id_ex;
  logic lsu_ready_ex_id;

  logic [CVA6Cfg.TRANS_ID_BITS-1:0] load_trans_id_ex_id;
  logic [CVA6Cfg.XLEN-1:0] load_result_ex_id;
  logic load_valid_ex_id;
  exception_t load_exception_ex_id;

  logic [CVA6Cfg.XLEN-1:0] store_result_ex_id;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] store_trans_id_ex_id;
  logic store_valid_ex_id;
  exception_t store_exception_ex_id;
  // MULT
  logic [CVA6Cfg.NrIssuePorts-1:0] mult_valid_id_ex;
  // FPU
  logic fpu_ready_ex_id;
  logic [CVA6Cfg.NrIssuePorts-1:0] fpu_valid_id_ex;
  logic [1:0] fpu_fmt_id_ex;
  logic [2:0] fpu_rm_id_ex;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] fpu_trans_id_ex_id;
  logic [CVA6Cfg.XLEN-1:0] fpu_result_ex_id;
  logic fpu_valid_ex_id;
  exception_t fpu_exception_ex_id;
  logic fpu_early_valid_ex_id;
  // ALU2
  logic [CVA6Cfg.NrIssuePorts-1:0] alu2_valid_id_ex;
  // Accelerator
  logic stall_acc_id;
  scoreboard_entry_t issue_instr_id_acc;
  logic issue_instr_hs_id_acc;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] acc_trans_id_ex_id;
  logic [CVA6Cfg.XLEN-1:0] acc_result_ex_id;
  logic acc_valid_ex_id;
  exception_t acc_exception_ex_id;
  logic halt_acc_ctrl;
  logic [4:0] acc_resp_fflags;
  logic acc_resp_fflags_valid;
  logic single_step_acc_commit;
  // CSR
  logic [CVA6Cfg.NrIssuePorts-1:0] csr_valid_id_ex;
  logic csr_hs_ld_st_inst_ex;
  // CVXIF
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] x_trans_id_ex_id;
  logic [CVA6Cfg.XLEN-1:0] x_result_ex_id;
  logic x_valid_ex_id;
  exception_t x_exception_ex_id;
  logic x_we_ex_id;
  logic [4:0] x_rd_ex_id;
  logic [CVA6Cfg.NrIssuePorts-1:0] x_issue_valid_id_ex;
  logic x_issue_ready_ex_id;
  logic [31:0] x_off_instr_id_ex;
  logic x_transaction_rejected;
  // --------------
  // EX <-> COMMIT
  // --------------
  // CSR Commit
  logic csr_commit_commit_ex;
  logic dirty_fp_state;
  logic dirty_v_state;
  // LSU Commit
  logic lsu_commit_commit_ex;
  logic lsu_commit_ready_ex_commit;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] lsu_commit_trans_id;
  // T6b-4b: scoreboard reclaim pointer (oldest live slot) — the program-age
  // anchor for dispatch/IQ/LSQ (inside issue_stage) and the store buffer.
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] sb_reclaim;
  // T6b-4b: committing hart per commit port (banked ack routing) and the
  // per-hart dcsr.step vector for cross-hart port-1 gating.
  logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] commit_hart;
  logic [CVA6Cfg.NrHarts-1:0] smt_step_b;
  // T6b: per-hart head of the live scoreboard ring (oldest issued entry's PC
  // per hart). Wired out of the scoreboard for T6b-2 recovery restart; no
  // consumer exists yet.
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:0] sb_head_pc;
  logic [CVA6Cfg.NrHarts-1:0] sb_head_valid;
  logic stall_st_pending_ex;
  logic no_st_pending_ex;
  logic no_st_pending_commit;
  logic shared_tlb_flush_busy_ex;
  logic amo_valid_commit;
  // ACCEL Commit
  logic acc_valid_acc_ex;
  // --------------
  // EX <-> ACC_DISP
  // --------------
  acc_mmu_req_t acc_mmu_req;
  acc_mmu_resp_t acc_mmu_resp;
  // --------------
  // ID <-> COMMIT
  // --------------
  scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_id_commit;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_drop_id_commit;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_replay_id_commit;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_commit_id;
  logic replay_commit_controller;
  logic mem_replay_pc_ctrl_pcgen;

  // --------------
  // RVFI
  // --------------
  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_commit_pointer;
  // --------------
  // COMMIT <-> ID
  // --------------
  logic [CVA6Cfg.NrCommitPorts-1:0][4:0] waddr_commit_id;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] wdata_commit_id;
  logic [CVA6Cfg.NrCommitPorts-1:0] we_gpr_commit_id;
  logic [CVA6Cfg.NrCommitPorts-1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] whart_commit_id;
  logic [CVA6Cfg.NrCommitPorts-1:0] we_fpr_commit_id;
  // --------------
  // CSR <-> *
  // --------------
  logic [4:0] fflags_csr_commit;
  riscv::xs_t fs;
  riscv::xs_t vfs;
  logic [2:0] frm_csr_id_issue_ex;
  logic [6:0] fprec_csr_ex;
  riscv::xs_t vs;
  logic enable_translation_csr_ex;
  logic enable_g_translation_csr_ex;
  logic en_ld_st_translation_csr_ex;
  logic en_ld_st_g_translation_csr_ex;
  riscv::priv_lvl_t ld_st_priv_lvl_csr_ex;
  logic ld_st_v_csr_ex;
  logic sum_csr_ex;
  logic vs_sum_csr_ex;
  logic mxr_csr_ex;
  logic vmxr_csr_ex;
  logic [CVA6Cfg.PPNW-1:0] satp_ppn_csr_ex;
  logic [CVA6Cfg.ASID_WIDTH-1:0] asid_csr_ex;
  logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_csr_ex;
  logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_csr_ex;
  logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_csr_ex;
  logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_csr_ex;
  logic [11:0] csr_addr_ex_csr;
  fu_op csr_op_commit_csr;
  logic [CVA6Cfg.XLEN-1:0] csr_wdata_commit_csr;
  logic [CVA6Cfg.XLEN-1:0] csr_rdata_csr_commit;
  exception_t csr_exception_csr_commit;
  logic tvm_csr_id;
  logic tw_csr_id;
  logic vtw_csr_id;
  logic tsr_csr_id;
  logic hu;
  irq_ctrl_t irq_ctrl_csr_id;
  // T6b-2b: per-hart arrays for the per-lane
  // decode interrupt check under mixed residency (SmtDrainedHandoff=0).
  irq_ctrl_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] irq_ctrl_b;
  riscv::priv_lvl_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] priv_lvl_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] v_b;
  // T6b-3a: the rest of the per-hart decode context (per-lane select in
  // id_stage under mixed residency; scalar outputs above stay the drained /
  // non-lane view).
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] tvm_b, tw_b, vtw_b, tsr_b, hu_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] debug_mode_b;
  riscv::xs_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] fs_b, vfs_b, vs_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][2:0] frm_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][6:0] fprec_b;
  riscv::cbie_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] mcbie_b, scbie_b, hcbie_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] mcbcfe_b, scbcfe_b, hcbcfe_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] mcbze_b, scbze_b, hcbze_b;
  jvt_t [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] jvt_b;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][31:0] mcountinhibit_b;
  logic v_commit_csr;
  logic mbe_commit_csr;
  logic dcache_en_csr_nbdcache;
  logic csr_write_fflags_commit_cs;
  logic icache_en_csr;
  logic acc_cons_en_csr;
  logic debug_mode;
  logic single_step_csr_commit;
  riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg;
  logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr;
  // T6b-2b: active-hart copies of the shared translation/PMP context for the
  // instruction-fetch side (the LSU-side set above follows lsu_ctx_hart).
  logic [CVA6Cfg.PPNW-1:0] fet_satp_ppn_csr_ex;
  logic [CVA6Cfg.ASID_WIDTH-1:0] fet_asid_csr_ex;
  logic [CVA6Cfg.PPNW-1:0] fet_vsatp_ppn_csr_ex;
  logic [CVA6Cfg.ASID_WIDTH-1:0] fet_vs_asid_csr_ex;
  logic [CVA6Cfg.PPNW-1:0] fet_hgatp_ppn_csr_ex;
  logic [CVA6Cfg.VMID_WIDTH-1:0] fet_vmid_csr_ex;
  logic fet_mxr_csr_ex;
  logic fet_vmxr_csr_ex;
  logic fet_mbe_csr_ex;
  riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] fet_pmpcfg;
  logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] fet_pmpaddr;
  // T6b-2b: hart owning the in-flight LSU translation request and the
  // bank-side LSU context select (== smt_active_hart unless mixed residency).
  // lsu_chk_* is the check-stage copy (registered one cycle under mixed
  // residency) that selects the PMP set in the bank.
  logic [HART_ID_BITS-1:0] lsu_hart;
  logic [HART_ID_BITS-1:0] lsu_chk_hart;
  logic [HART_ID_BITS-1:0] lsu_ctx_hart;
  logic [HART_ID_BITS-1:0] lsu_chk_ctx_hart;
  logic [31:0] mcountinhibit_csr_perf;
  //jvt
  jvt_t jvt;
  // trigger module
  logic debug_from_trigger;
  logic break_from_trigger;
  riscv::cbie_t mcbie, scbie, hcbie;
  logic mcbcfe, scbcfe, hcbcfe;
  logic mcbze, scbze, hcbze;
  logic pbmte;
  // ----------------------------
  // Performance Counters <-> *
  // ----------------------------
  logic [11:0] addr_csr_perf;
  logic [CVA6Cfg.XLEN-1:0] data_csr_perf, data_perf_csr;
  logic we_csr_perf;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][31:0] scountovf_perf_csr;
  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] lcofi_perf_csr;

  logic icache_flush_ctrl_cache;
  logic itlb_miss_ex_perf;
  logic dtlb_miss_ex_perf;
  logic dcache_miss_cache_perf;
  logic icache_miss_cache_perf;
  logic [NumPorts-1:0][CVA6Cfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits;
  logic stall_issue;

  // U6.1 SMT (instances after CTRL nets are declared)
  logic [HART_ID_BITS-1:0] smt_active_hart;
  // Decode/RVFI see only the *active* fetch hart's MEIP/SEIP; CSR banks
  // already receive the full per-hart irq_i[] vector (Linux CLINT/PLIC identity).
  logic [1:0] irq_active;
  assign irq_active = irq_i[smt_active_hart];
  // T6b-2b: under mixed residency the LSU-side architectural context follows
  // the hart owning the in-flight load/store translation request; under the
  // drained handoff (and single-hart) it selects exactly today's active-hart
  // context, so behaviour is bit-identical.
  assign lsu_ctx_hart = (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff)
                        ? lsu_hart : smt_active_hart;
  assign lsu_chk_ctx_hart = (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff)
                            ? lsu_chk_hart : smt_active_hart;
  logic                    smt_switch;
  logic                    smt_quiesce, smt_sb_empty;
  logic                    ooo_drained_id;
  // N1c bounded drain force (drained handoff)
  logic                    smt_drain_force;
  logic                    smt_drain_force_wfi;
  logic                    smt_drain_force_abs;
  logic                    smt_drain_forced;
  logic [CVA6Cfg.VLEN-1:0] smt_drain_force_pc;
  logic                    smt_drain_safe;
  logic                    smt_head_wfi, smt_head_plain;
  logic                    smt_t0_extra;
  logic                    smt_t0_rewind;
  logic [CVA6Cfg.VLEN-1:0] smt_t0_alt;
  logic                    smt_switch_hold;  // suppress switches in bootrom page
  logic                    smt_trap_hold;    // I4br: I4z mtvec fetch/tail
  logic                    smt_switch_on_miss;
  logic                    smt_switch_on_quantum;
  logic                    smt_switch_on_starve;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_ready;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_ready_sel;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_dmiss;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_imiss;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_block;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_halt;
  logic [CVA6Cfg.NrHarts-1:0] smt_pause_hint;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_enable;
  logic smt_fetch_fire;
  logic smt_issue_fire;
  logic smt_miss_clear;
  logic smt_long_block;

  // --------------
  // CTRL <-> *
  // --------------
  logic set_pc_ctrl_pcgen;
  logic flush_csr_ctrl;
  logic flush_unissued_instr_ctrl_id;
  logic flush_ctrl_if;
  logic flush_ctrl_id;
  logic flush_ctrl_ex;
  logic flush_ctrl_bp;
  logic flush_tlb_ctrl_ex;
  logic flush_tlb_vvma_ctrl_ex;
  logic flush_tlb_gvma_ctrl_ex;
  logic fence_i_commit_controller;
  logic fence_commit_controller;
  logic sfence_vma_commit_controller;
  logic hfence_vvma_commit_controller;
  logic hfence_gvma_commit_controller;
  logic halt_ctrl;
  logic halt_frontend;
  logic halt_csr_ctrl;
  logic [CVA6Cfg.NrHarts-1:0] smt_csr_hart_halt;
  logic dcache_flush_ctrl_cache;
  logic dcache_flush_ack_cache_ctrl;
  logic set_debug_pc;
  logic flush_commit;
  logic flush_acc;

  icache_areq_t icache_areq_ex_cache;
  icache_arsp_t icache_areq_cache_ex;
  icache_dreq_t icache_dreq_if_cache;
  icache_drsp_t icache_dreq_cache_if;

  amo_req_t amo_req;
  amo_resp_t amo_resp;
  logic sb_full;
  logic spec_cancel;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] sb_cancelled_mask;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] sb_live_mask;
  logic [1:0] mem_phys_valid, mem_mod_valid;
  logic [1:0][CVA6Cfg.PLEN-1:0] mem_phys_addr, mem_mod_addr;
  logic [1:0][CVA6Cfg.TRANS_ID_BITS-1:0] mem_phys_id;
  logic [1:0][$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] mem_phys_hart;
  logic [1:0][1:0] mem_phys_size;
  logic inval_apply_valid;
  logic [63:0] inval_apply_addr;
  // U5 OoO PMU probes (0 when OoOEn=0)
  logic ooo_rename_stall, ooo_iq_full, ooo_rob_full, ooo_lsq_stall, ooo_stl_forward;
  logic ooo_phys_replay;
  // N1d: the port-0 commit head is an unpublished load — the store buffer
  // releases its speculative-store stall while it is set (see store_buffer).
  logic ooo_head_phys_pending;

  // ----------------
  // DCache <-> *
  // ----------------
  dcache_req_i_t [2:0] dcache_req_ports_ex_cache;
  dcache_req_o_t [2:0] dcache_req_ports_cache_ex;
  dcache_req_i_t dcache_req_ports_id_cache;
  dcache_req_o_t dcache_req_ports_cache_id;
  dcache_req_i_t [1:0] dcache_req_ports_acc_cache;
  dcache_req_o_t [1:0] dcache_req_ports_cache_acc;
  logic dcache_commit_wbuffer_empty;
  logic dcache_commit_wbuffer_not_ni;
  logic dcache_pm_void_ack;
  logic dcache_pm_fixup_write;
  logic dcache_pm_fixup_inval;
  logic dcache_pm_fixup_full;

  //RVFI
  lsu_ctrl_t rvfi_lsu_ctrl;
  logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr;
  logic [CVA6Cfg.NrIssuePorts-1:0] rvfi_is_compressed;
  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] rvfi_instr_id;
  rvfi_probes_csr_t rvfi_csr;

  // Accelerator port
  logic [63:0] inval_addr;
  logic inval_valid;
  logic inval_ready;
  // Accelerator-side inv (Ara/CVXIF) OR external multi-core coherence inv
  logic [63:0] acc_inval_addr;
  logic        acc_inval_valid;
  // T9a: third inval source — the local CMO completion path. Only reachable
  // when L2CmoEn=0; lowest priority after acc_inval and l1_inval_*.
  logic [63:0] cmo_lcl_addr;
  logic        cmo_lcl_valid;
  // External inv has priority when accelerator is idle; the local CMO inval
  // is last (it only exists when no hierarchy is present).
  assign inval_addr  = acc_inval_valid ? acc_inval_addr :
                       l1_inval_valid_i ? l1_inval_addr_i : cmo_lcl_addr;
  assign inval_valid = acc_inval_valid | l1_inval_valid_i | cmo_lcl_valid;
  assign l1_inval_ready_o = inval_ready & ~acc_inval_valid;
  if (CVA6Cfg.DCacheType != config_pkg::WT) begin : gen_no_wt_apply
    assign inval_apply_valid = 1'b0;
    assign inval_apply_addr = '0;
  end
  assign mem_mod_valid[0] = (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) && inval_apply_valid;
  assign mem_mod_addr[0] = CVA6Cfg.PLEN'(inval_apply_addr);
  if (CVA6Cfg.CohPolicy == config_pkg::COH_OOO) begin : gen_local_modification
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        mem_mod_valid[1] <= 1'b0;
        mem_mod_addr[1] <= '0;
      end else begin
        mem_mod_valid[1] <= dcache_req_ports_ex_cache[2].data_req &&
                            dcache_req_ports_cache_ex[2].data_gnt;
        if (dcache_req_ports_ex_cache[2].data_req && dcache_req_ports_cache_ex[2].data_gnt)
          mem_mod_addr[1] <= CVA6Cfg.PLEN'({dcache_req_ports_ex_cache[2].address_tag,
                                          dcache_req_ports_ex_cache[2].address_index});
      end
    end
  end else begin : gen_no_local_modification
    assign mem_mod_valid[1] = 1'b0;
    assign mem_mod_addr[1] = '0;
  end

  // --------------
  // CMO sideband routing (T9a eWT)
  // --------------
  // The active cache subsystem drives cmo_req_*; with L2CmoEn the request
  // travels on the external cmo_* ports to the cluster's g6lc_cmo_engine.
  // Without it the core completes the CBO locally: inval → its own L1 through
  // the inval mux above, clean/flush → already ordered by the subsystem's
  // write-buffer drain, so a one-cycle done pulse finishes them.
  logic                    cmo_req_valid;
  logic [1:0]              cmo_req_op;
  logic [CVA6Cfg.PLEN-1:0] cmo_req_addr;
  logic                    cmo_req_ready;
  logic                    cmo_req_done;

  if (CVA6Cfg.L2CmoEn && CVA6Cfg.L2En) begin : gen_cmo_ext
    assign cmo_valid_o   = cmo_req_valid;
    assign cmo_op_o      = cmo_req_op;
    assign cmo_addr_o    = cmo_req_addr;
    assign cmo_req_ready = cmo_ready_i;
    assign cmo_req_done  = cmo_done_i;
    assign cmo_lcl_valid = 1'b0;
    assign cmo_lcl_addr  = '0;
  end else begin : gen_cmo_local
    typedef enum logic [1:0] {CL_IDLE, CL_INVAL, CL_DONE} cl_fsm_e;
    cl_fsm_e cl_fsm_q, cl_fsm_d;
    logic [CVA6Cfg.PLEN-1:0] cl_addr_q, cl_addr_d;

    assign cmo_valid_o = 1'b0;
    assign cmo_op_o    = '0;
    assign cmo_addr_o  = '0;
    // The subsystem only raises cmo_req_valid once its write buffer has
    // drained, so acceptance is unconditional here.
    assign cmo_req_ready = 1'b1;
    // Acceptance posts the INV_REQ onto the dcache return channel the same
    // cycle (wt_axi_adapter), so ready-accept is the apply; done pulses the
    // next cycle. Priority mirrors the inval mux above.
    wire cl_inval_fire = cmo_lcl_valid && inval_ready &&
                         !acc_inval_valid && !l1_inval_valid_i;
    assign cmo_lcl_valid = (cl_fsm_q == CL_INVAL);
    assign cmo_lcl_addr  = 64'(cl_addr_q);

    always_comb begin
      cl_fsm_d  = cl_fsm_q;
      cl_addr_d = cl_addr_q;
      unique case (cl_fsm_q)
        CL_IDLE: if (cmo_req_valid) begin
          cl_addr_d = cmo_req_addr;
          // op 0 = inval → local L1 invalidate; clean/flush → drain already
          // done by the subsystem tracker, complete immediately.
          cl_fsm_d  = (cmo_req_op == 2'd0) ? CL_INVAL : CL_DONE;
        end
        CL_INVAL: if (cl_inval_fire) cl_fsm_d = CL_DONE;
        CL_DONE:  cl_fsm_d = CL_IDLE;
        default:  cl_fsm_d = CL_IDLE;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_cmo_lcl
      if (!rst_ni) begin
        cl_fsm_q     <= CL_IDLE;
        cl_addr_q    <= '0;
        cmo_req_done <= 1'b0;
      end else begin
        cl_fsm_q     <= cl_fsm_d;
        cl_addr_q    <= cl_addr_d;
        cmo_req_done <= (cl_fsm_q == CL_DONE);
      end
    end
    logic unused_lcl_cmo;
    assign unused_lcl_cmo = cmo_ready_i | cmo_done_i;
  end

  // --------------
  // Frontend
  // --------------
  logic [CVA6Cfg.VLEN-1:0] smt_npc_live;
  // T6b-3b: oldest undelivered fetch position (redirect pend > in-flight
  // parcel > NPC cursor) — the frontier a killed fetch stream restarts from.
  logic [CVA6Cfg.VLEN-1:0] smt_fetch_frontier;
  // T6b-3b: oldest undelivered instruction per hart inside the instruction
  // queue — the port view reaches only NrIssuePorts positions, so queued peer
  // entries deeper than the presented slots need this explicit frontier.
  logic [CVA6Cfg.NrHarts-1:0] smt_queue_oldest_valid;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:0] smt_queue_oldest_pc;
  logic [CVA6Cfg.VLEN-1:0] smt_restart_pc;
  logic smt_restart_valid;
  logic [HART_ID_BITS-1:0] smt_outgoing_hart;
  logic [CVA6Cfg.VLEN-1:0] smt_npc_restore;
  logic                    smt_pc_restore;
  // Declared ahead of gen_smt_restart_frontier (slang requires declaration
  // before use); driven below with the rest of the commit-side redirects.
  logic                    smt_arch_redirect_valid;
  logic [HART_ID_BITS-1:0] smt_arch_redirect_hart;
  logic [CVA6Cfg.VLEN-1:0] smt_arch_redirect_pc;

  logic g1fh_csr_a0;
  logic [CVA6Cfg.NrHarts-1:0] g1lq_v;
  logic [CVA6Cfg.NrHarts-1:0][4:0] g1lq_rd;
  logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:4] g1lq_line;
  logic [CVA6Cfg.NrHarts-1:0] g1lq_a3;
  // declared ahead of i_frontend (slang requires declaration before use)
  logic                        peer_restart_active;
  logic [CVA6Cfg.VLEN-1:0]     peer_restart_pc;
`ifdef G6LC_FETCH_B
  assign g1fh_csr_a0 = 1'b0;
  assign g1lq_v = '0;
  assign g1lq_rd = '0;
  assign g1lq_line = '0;
  assign g1lq_a3 = '0;
`endif
  frontend #(
      .CVA6Cfg(CVA6Cfg),
      .bp_resolve_t(bp_resolve_t),
      .fetch_entry_t(fetch_entry_t),
      .icache_dreq_t(icache_dreq_t),
      .icache_drsp_t(icache_drsp_t)
  ) i_frontend (
      .clk_i,
      .rst_ni,
      .boot_addr_i        (boot_addr_i[CVA6Cfg.VLEN-1:0]),
      .flush_bp_i         ((CVA6Cfg.RVU || CVA6Cfg.RVS) ? flush_ctrl_bp : 1'b0),
      // below line is not entirely correct
      .flush_i            (flush_ctrl_if),
      .halt_i             (halt_ctrl),
      .halt_frontend_i    (halt_frontend),
      .set_pc_commit_i    (set_pc_ctrl_pcgen),
`ifdef G6LC_FETCH_B
      .commit_hart_i      (whart_commit_id[0]),
      .mem_replay_pc_i    (mem_replay_pc_ctrl_pcgen),
      .peer_restart_valid_i (peer_restart_active),
      .peer_restart_pc_i    (peer_restart_pc),
`endif
      .pc_commit_i        (pc_commit),
      .ex_valid_i         (ex_commit.valid),
      .resolved_branch_i  (resolved_branch_fe),
      .eret_i             (eret),
      .epc_i              (epc_commit_pcgen),
      .trap_vector_base_i (trap_vector_base_commit_pcgen),
      .set_debug_pc_i     (set_debug_pc),
      .debug_mode_i       (debug_mode),
      .smt_hart_i         (smt_active_hart),
      .smt_restore_i      (smt_pc_restore),
      .smt_npc_restore_i  (smt_npc_restore),
      .npc_q_o            (smt_npc_live),
      .fetch_frontier_pc_o(smt_fetch_frontier),
      .queue_oldest_valid_o(smt_queue_oldest_valid),
      .queue_oldest_pc_o  (smt_queue_oldest_pc),
      .smt_trap_hold_o    (smt_trap_hold),
      .icache_dreq_o      (icache_dreq_if_cache),
      .icache_dreq_i      (icache_dreq_cache_if),
      .fetch_entry_o      (fetch_entry_if_id),
      .fetch_entry_valid_o(fetch_valid_if_id),
      .fetch_entry_ready_i(fetch_ready_id_if)
`ifndef G6LC_FETCH_B
      ,
      .g1fh_csr_a0_o      (g1fh_csr_a0),
      .g1lq_v_o           (g1lq_v),
      .g1lq_rd_o          (g1lq_rd),
      .g1lq_line_o        (g1lq_line),
      .g1lq_a3_o          (g1lq_a3)
`endif
  );

`ifdef G6LC_FETCH_B
  if (CVA6Cfg.NrHarts > 1) begin : gen_smt_restart_frontier
    logic [7:0] decode_valid, queue_valid;
    logic [7:0][7:0] decode_hart, queue_hart;
    logic [7:0][63:0] decode_pc, queue_pc;
    g6lc_fetch_pkg::restart_t selected;
    // T13: instruction-granular next-fetch pc per hart — the restart point
    // for an outgoing hart whose pre-dispatch stream is empty (every
    // delivered instruction is already dispatched): next pc after its
    // youngest dispatched instruction, a CF following the predicted
    // target. The window-aligned fetch frontier (redirect pend / in-flight
    // parcel / npc cursor) is not a legal restart PC: it can land inside a
    // parcel-crossing instruction, and restoring from it decodes an
    // illegal encoding (smt2_ooo_int m34–m36: restart pc=0x80000200 /
    // 0x800007c0, cause=2, tohost=1337).
    logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:0] smt_tail_next_q;
    logic [CVA6Cfg.NrHarts-1:0]                    smt_tail_valid_q;
    logic [CVA6Cfg.NrHarts-1:0][CVA6Cfg.VLEN-1:0] smt_tail_next_d;
    logic [CVA6Cfg.NrHarts-1:0]                    smt_tail_valid_d;
    if (!CVA6Cfg.SmtDrainedHandoff) begin : gen_switch_tail
      always_comb begin
        smt_tail_next_d  = smt_tail_next_q;
        smt_tail_valid_d = smt_tail_valid_q;
        // The highest-index acked slot is the youngest dispatch this
        // cycle; ports are presented in program order.
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          if (issue_entry_valid_id_issue[p] && issue_instr_issue_id[p]) begin
            // A control-flow op is only allowed to arm the tail with its
            // predicted target when the predictor marked the parcel taken
            // (bp.cf != ariane_pkg::NoCF) — then predict_address is its own target.
            // For a not-taken-predicted CF the parcel carries the NEXT
            // downstream CF's predict (the branch-target FIFO head), a
            // stream point unrelated to this op's successor and reachable
            // from the shared predictor state of either hart (m33: a
            // not-taken bnez@0x8000119c armed hart-0's tail with the parked
            // peer's 0x8000010a; the banked restart re-executed the park
            // self-branch). A not-taken CF's successor is pc+ilen.
            smt_tail_next_d[issue_entry_id_issue[p].hart_id] =
                (issue_entry_id_issue[p].fu == CTRL_FLOW &&
                 issue_entry_id_issue[p].bp.cf != ariane_pkg::NoCF)
                    ? issue_entry_id_issue[p].bp.predict_address
                    : issue_entry_id_issue[p].pc + CVA6Cfg.VLEN'(
                        issue_entry_id_issue[p].is_compressed ? 2 : 4);
            smt_tail_valid_d[issue_entry_id_issue[p].hart_id] = 1'b1;
          end
        // Commit-level redirects and mispredicts re-arm the tail at their
        // target: a hart that switches out before its first post-redirect
        // dispatch still restarts on the right path. redirect2 is left
        // out — a peer restart can carry a window-aligned frontier.
        if (smt_arch_redirect_valid) begin
          smt_tail_next_d[smt_arch_redirect_hart]  = smt_arch_redirect_pc;
          smt_tail_valid_d[smt_arch_redirect_hart] = 1'b1;
        end
        if (resolved_branch.valid && resolved_branch.is_mispredict) begin
          smt_tail_next_d[resolved_branch.hart_id]  = resolved_branch.target_address;
          smt_tail_valid_d[resolved_branch.hart_id] = 1'b1;
        end
        // A full flush kills both harts' scoreboards; the commit redirect
        // owns the restart until the next dispatch re-arms the tail.
        if (flush_ctrl_id) smt_tail_valid_d = '0;
      end
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          smt_tail_next_q  <= '0;
          smt_tail_valid_q <= '0;
        end else begin
          smt_tail_next_q  <= smt_tail_next_d;
          smt_tail_valid_q <= smt_tail_valid_d;
        end
      end
    end else begin : gen_switch_tail_tied
      assign smt_tail_next_q  = '0;
      assign smt_tail_valid_q = '0;
      assign smt_tail_next_d  = '0;
      assign smt_tail_valid_d = '0;
    end
    always_comb begin
      decode_valid = '0;
      queue_valid = '0;
      decode_hart = '0;
      queue_hart = '0;
      decode_pc = '0;
      queue_pc = '0;
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        decode_valid[p] = smt_switch && issue_entry_valid_id_issue[p];
        decode_hart[p] = 8'(issue_entry_id_issue[p].hart_id);
        decode_pc[p] = 64'(issue_entry_id_issue[p].pc);
      end
      // The per-hart pending-FIFO head is the outgoing hart's oldest
      // undelivered instruction; it subsumes the presented port slots
      // (undelivered themselves) and reaches queued entries deeper than
      // the NrIssuePorts port view.
      queue_valid[0] = smt_switch && smt_queue_oldest_valid[smt_outgoing_hart];
      queue_hart[0]  = 8'(smt_outgoing_hart);
      queue_pc[0]    = 64'(smt_queue_oldest_pc[smt_outgoing_hart]);
      selected = g6lc_fetch_pkg::restart_frontier(
          CVA6Cfg.NrIssuePorts, 8'(smt_outgoing_hart),
          decode_valid, decode_hart, decode_pc, queue_valid, queue_hart, queue_pc,
          // Drained keeps the proven snap view (its bank is retirement-fed
          // anyway). Mixed banks the instruction-granular tail: the
          // window-aligned fetch frontier is not a restart PC.
          // T13: the selected frontier rides npc_live_i into i_smt_pc_bank
          // and is banked at switch-out — it is the mixed-mode restart
          // authority (inactive-hart retirements must not move the bank).
          CVA6Cfg.SmtDrainedHandoff
              ? '{valid: 1'b1, pc: 64'(smt_npc_live)}
              : '{valid: smt_tail_valid_d[smt_outgoing_hart],
                  pc: 64'(smt_tail_next_d[smt_outgoing_hart])},
          smt_switch && resolved_branch.valid && resolved_branch.is_mispredict,
          8'(resolved_branch.hart_id), 64'(resolved_branch.target_address));
    end
    assign smt_restart_pc = CVA6Cfg.VLEN'(selected.pc);
    assign smt_restart_valid = selected.valid;
  end else begin : gen_smt_restart_single
    assign smt_restart_pc = smt_npc_live;
    assign smt_restart_valid = 1'b1;
  end
`else
  assign smt_restart_pc = smt_npc_live;
  assign smt_restart_valid = 1'b1;
`endif

  logic [CVA6Cfg.NrCommitPorts-1:0] smt_retire_valid;
  logic [CVA6Cfg.NrCommitPorts-1:0][HART_ID_BITS-1:0] smt_retire_hart;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.VLEN-1:0] smt_retire_pc;
  // T6b-2a: mixed-residency recovery plumbing. The primary redirect port is
  // owned by the faulting/committing hart; the second port carries the peer
  // hart's flush restart or an inactive hart's mispredict. Constant-0 under
  // SmtDrainedHandoff and NrHarts==1.
  logic                        smt_arch_redirect2_valid;
  logic [HART_ID_BITS-1:0]     smt_arch_redirect2_hart;
  logic [CVA6Cfg.VLEN-1:0]     smt_arch_redirect2_pc;
  logic                        peer_restart_valid;
  logic [HART_ID_BITS-1:0]     peer_restart_hart;
  for (genvar p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin : gen_smt_retire_pc
    assign smt_retire_valid[p] = commit_ack[p] && !commit_drop_id_commit[p] &&
        !commit_instr_id_commit[p].ex.valid;
    assign smt_retire_hart[p] = commit_instr_id_commit[p].hart_id;
    assign smt_retire_pc[p] = commit_instr_id_commit[p].fu == CTRL_FLOW
        ? commit_instr_id_commit[p].bp.predict_address
        : commit_instr_id_commit[p].pc + CVA6Cfg.VLEN'(commit_instr_id_commit[p].is_compressed ? 2 : 4);
  end
  always_comb begin
    smt_arch_redirect_valid = 1'b0;
    smt_arch_redirect_hart = smt_active_hart;
    smt_arch_redirect_pc = '0;
    if (CVA6Cfg.DebugEn && set_debug_pc) begin
      smt_arch_redirect_valid = 1'b1;
      smt_arch_redirect_pc = CVA6Cfg.VLEN'(CVA6Cfg.DmBaseAddress + CVA6Cfg.HaltAddress);
    end
    if (set_pc_ctrl_pcgen) begin
      smt_arch_redirect_valid = 1'b1;
      smt_arch_redirect_hart = whart_commit_id[0];
      // A memory-order replay refetches the committing PC itself, like halt —
      // banking pc+4 would restart the hart one instruction late.
      smt_arch_redirect_pc = pc_commit + CVA6Cfg.VLEN'(
          (halt_ctrl || mem_replay_pc_ctrl_pcgen) ? 0 : 4);
    end
    if (eret) begin
      smt_arch_redirect_valid = 1'b1;
      smt_arch_redirect_hart = whart_commit_id[0];
      smt_arch_redirect_pc = epc_commit_pcgen;
    end
    if (ex_commit.valid) begin
      smt_arch_redirect_valid = 1'b1;
      smt_arch_redirect_hart = whart_commit_id[0];
      smt_arch_redirect_pc = trap_vector_base_commit_pcgen;
    end
    // T6b-3b: an inactive hart's mispredict is the only redirect without a
    // commit-side owner. When no commit redirect owns this cycle, bank its
    // target on the primary port so the second port can carry the peer
    // restart the same (partial) flush requires. Dead under drained
    // residency — an inactive hart never resolves a branch there — and on
    // every full flush, whose sources all claim this port first.
    if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff &&
        !smt_arch_redirect_valid && resolved_branch.valid &&
        resolved_branch.is_mispredict &&
        resolved_branch.hart_id != smt_active_hart) begin
      smt_arch_redirect_valid = 1'b1;
      smt_arch_redirect_hart = resolved_branch.hart_id;
      smt_arch_redirect_pc = resolved_branch.target_address;
    end
  end

  // T6b-2a/T6b-3b: peer-hart restart on a flush. A FULL flush (flush_ctrl_id)
  // empties BOTH harts' scoreboard entries; the hart that did not own the
  // flush restarts at its scoreboard head (oldest entry it lost), or — when
  // it has no live entry — at its surviving fetch/decode frontier. A PARTIAL
  // flush — flush_if/flush_unissued without flush_ctrl_id, which under
  // fetch_B is a branch mispredict (the hart switch is excluded: the outgoing
  // hart's frontier is already transported by gen_smt_restart_frontier) —
  // globally kills the same pre-dispatch state while BOTH harts' scoreboard
  // entries survive, so the peer restarts at its pre-dispatch frontier only,
  // never sb_head: its scoreboard entries were not lost. The fetch-side
  // candidate is the oldest undelivered fetch position (armed redirect
  // target > in-flight parcel > NPC cursor), so a parcel killed in flight is
  // refetched instead of skipped. Mixed residency only: the whole cone
  // constant-folds under SmtDrainedHandoff and NrHarts==1.
`ifdef G6LC_FETCH_B
  if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff) begin : gen_peer_restart
    logic [7:0] pr_decode_valid, pr_queue_valid;
    logic [7:0][7:0] pr_decode_hart, pr_queue_hart;
    logic [7:0][63:0] pr_decode_pc, pr_queue_pc;
    logic [HART_ID_BITS-1:0] fault_hart;
    logic partial_kill;
    g6lc_fetch_pkg::restart_t pr_selected;
    // A pre-dispatch kill that is neither a full flush nor the hart switch.
    // Under fetch_B the only such source is a branch mispredict — the
    // predicted-correct E3 kill is compiled out — so the flush owner is the
    // resolving hart (witnessed by t6b3_partial_owner).
    assign partial_kill = (flush_ctrl_if || flush_unissued_instr_ctrl_id) &&
                          !flush_ctrl_id && !smt_switch;
    always_comb begin
      // The flush owner: the resolving hart on a partial flush, else the
      // commit-side redirect's target hart, else the committing hart when
      // the flush carries no bank redirect.
      fault_hart = partial_kill ? HART_ID_BITS'(resolved_branch.hart_id)
                   : smt_arch_redirect_valid ? smt_arch_redirect_hart
                                             : whart_commit_id[0];
      pr_decode_valid = '0;
      pr_queue_valid = '0;
      pr_decode_hart = '0;
      pr_queue_hart = '0;
      pr_decode_pc = '0;
      pr_queue_pc = '0;
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
        pr_decode_valid[p] = (flush_ctrl_id || partial_kill) &&
                             issue_entry_valid_id_issue[p];
        pr_decode_hart[p] = 8'(issue_entry_id_issue[p].hart_id);
        pr_decode_pc[p] = 64'(issue_entry_id_issue[p].pc);
      end
      // The lowest-index hart other than the flush owner — exact for NH==2;
      // NH>2 would restart one peer per flush (no such configuration exists).
      peer_restart_hart = '0;
      for (int h = CVA6Cfg.NrHarts - 1; h >= 0; h--)
        if (h != int'(fault_hart)) peer_restart_hart = HART_ID_BITS'(h);
      // Queue-side candidate: the port view reaches only NrIssuePorts
      // positions, so a peer's entries queued deeper behind the faulting
      // hart's presented slots would be killed invisibly. The per-hart
      // pending-FIFO head is the peer's oldest undelivered instruction and
      // subsumes the port entries (undelivered themselves).
      pr_queue_valid[0] = (flush_ctrl_id || partial_kill) &&
                          smt_queue_oldest_valid[peer_restart_hart];
      pr_queue_hart[0]  = 8'(peer_restart_hart);
      pr_queue_pc[0]    = 64'(smt_queue_oldest_pc[peer_restart_hart]);
      pr_selected = g6lc_fetch_pkg::restart_frontier(
          CVA6Cfg.NrIssuePorts, 8'(peer_restart_hart),
          pr_decode_valid, pr_decode_hart, pr_decode_pc,
          pr_queue_valid, pr_queue_hart, pr_queue_pc,
          // The fetch state is a frontier only for the hart the frontend is
          // actually fetching; an inactive peer keeps its banked PC. During
          // the switch beat itself smt_active_hart already names the
          // incoming hart while npc/inflight still hold the outgoing hart's
          // dying stream — the incoming hart's frontier is its banked
          // restore PC, not the stream being killed.
          '{valid: peer_restart_hart == smt_active_hart,
            pc: 64'(smt_switch ? smt_npc_restore : smt_fetch_frontier)},
          1'b0, '0, '0);
    end
    // sb_head is a frontier only on a full flush: on a partial flush the
    // peer's scoreboard entries survive the same-hart cancel and restarting
    // from them would duplicate live work.
    assign peer_restart_pc = flush_ctrl_id && sb_head_valid[peer_restart_hart]
                             ? sb_head_pc[peer_restart_hart]
                             : CVA6Cfg.VLEN'(pr_selected.pc);
`ifdef G6LC_MUT_NO_PEER_RESTART
    // Review-only mutation: no peer restart on a partial flush — the peer's
    // killed pre-dispatch instructions are never refetched.
    assign peer_restart_valid = flush_ctrl_id &&
        (sb_head_valid[peer_restart_hart] || pr_selected.valid);
`else
    assign peer_restart_valid = (flush_ctrl_id &&
        (sb_head_valid[peer_restart_hart] || pr_selected.valid)) ||
        (partial_kill && pr_selected.valid);
`endif
    assign peer_restart_active = peer_restart_valid &&
        (peer_restart_hart == smt_active_hart);
  end else begin : gen_no_peer_restart
    assign peer_restart_valid  = 1'b0;
    assign peer_restart_active = 1'b0;
    assign peer_restart_hart   = '0;
    assign peer_restart_pc     = '0;
  end
`else
  assign peer_restart_valid  = 1'b0;
  assign peer_restart_active = 1'b0;
  assign peer_restart_hart   = '0;
  assign peer_restart_pc     = '0;
`endif

  // T6b-2a: second bank write. A full flush restarts the peer hart; an
  // inactive hart's mispredict retargets only its own bank (a same-hart
  // commit redirect is older and already owns that slot's write). Both lose
  // to the primary redirect only in the port sense — they write different
  // banks.
  always_comb begin
    smt_arch_redirect2_valid = 1'b0;
    smt_arch_redirect2_hart  = '0;
    smt_arch_redirect2_pc    = '0;
    if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff) begin
      if (peer_restart_valid) begin
        smt_arch_redirect2_valid = 1'b1;
        smt_arch_redirect2_hart  = peer_restart_hart;
        smt_arch_redirect2_pc    = peer_restart_pc;
      end else if (resolved_branch.valid && resolved_branch.is_mispredict &&
                   resolved_branch.hart_id != smt_active_hart &&
                   !(smt_arch_redirect_valid &&
                     smt_arch_redirect_hart == resolved_branch.hart_id)) begin
        smt_arch_redirect2_valid = 1'b1;
        smt_arch_redirect2_hart  = resolved_branch.hart_id;
        smt_arch_redirect2_pc    = resolved_branch.target_address;
      end
    end
  end

  g6lc_smt_pc_bank #(
      .CVA6Cfg(CVA6Cfg)
  ) i_smt_pc_bank (
      .clk_i,
      .rst_ni,
      .boot_addr_i  (boot_addr_i[CVA6Cfg.VLEN-1:0]),
      .npc_live_i      (smt_restart_pc),
      .npc_live_valid_i(smt_restart_valid),
      .redirect_valid_i(smt_arch_redirect_valid),
      .redirect_hart_i (smt_arch_redirect_hart),
      .redirect_pc_i   (smt_arch_redirect_pc),
      .redirect2_valid_i(smt_arch_redirect2_valid),
      .redirect2_hart_i (smt_arch_redirect2_hart),
      .redirect2_pc_i   (smt_arch_redirect2_pc),
      .retire_valid_i  (smt_retire_valid),
      .retire_hart_i   (smt_retire_hart),
      .retire_pc_i     (smt_retire_pc),
      .outgoing_hart_o (smt_outgoing_hart),
      .active_hart_i   (smt_active_hart),
      .switch_i        (smt_switch),
`ifdef G6LC_FETCH_B
      // I10: snapshot npc_live only — EXCEPT the N1c forced-drain rewind,
      // which hands the outgoing hart its latched commit-head PC at switch.
      .npc_alt_valid_i (smt_drain_forced),
      .npc_alt_i       (smt_drain_force_pc),
`else
      .npc_alt_valid_i (smt_t0_rewind),
      .npc_alt_i       (smt_t0_alt),
`endif
      .npc_restore_o(smt_npc_restore),
      .restore_o    (smt_pc_restore)
  );

  // ---------
  // ID
  // ---------
  id_stage #(
      .CVA6Cfg(CVA6Cfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .fetch_entry_t(fetch_entry_t),
      .jvt_t(jvt_t),
      .irq_ctrl_t(irq_ctrl_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .interrupts_t(interrupts_t),
      .INTERRUPTS(INTERRUPTS),
      .x_compressed_req_t(x_compressed_req_t),
      .x_compressed_resp_t(x_compressed_resp_t)
  ) id_stage_i (
      .clk_i,
      .rst_ni,
      .flush_i(flush_ctrl_if),
      .debug_req_i,

      .fetch_entry_i      (fetch_entry_if_id),
      .fetch_entry_valid_i(fetch_valid_if_id),
      .fetch_entry_ready_o(fetch_ready_id_if),
      .g1lq_v_i           (g1lq_v),
      .g1lq_rd_i          (g1lq_rd),
      .g1lq_line_i        (g1lq_line),
      .g1lq_a3_i          (g1lq_a3),
      .commit_instr_i     (commit_instr_id_commit),
      .commit_ack_i       (commit_ack),
      .g1mf_v_i           (g1mf_v),
      .g1mf_rd_i          (g1mf_rd),
      .g1mf_line_i        (g1mf_line),
      .g1mf_a3_i          (g1mf_a3),

      .issue_entry_o      (issue_entry_id_issue),
      .issue_entry_o_prev (issue_entry_id_issue_prev),
      .orig_instr_o       (orig_instr_id_issue),
      .issue_entry_valid_o(issue_entry_valid_id_issue),
      .is_ctrl_flow_o     (is_ctrl_fow_id_issue),
      .issue_instr_ack_i  (issue_instr_issue_id),

      .rvfi_is_compressed_o(rvfi_is_compressed),
      .rvfi_instr_o        (rvfi_instr_id),

      .priv_lvl_i          (priv_lvl),
      .v_i                 (v),
      .fs_i                (fs),
      .vfs_i               (vfs),
      .frm_i               (frm_csr_id_issue_ex),
      .vs_i                (vs),
      .irq_i               (irq_active),
      .irq_ctrl_i          (irq_ctrl_csr_id),
      // T6b-2b: per-hart interrupt/privilege context for the per-lane decode
      // interrupt check under mixed residency (unused inputs when drained).
      .irq_b_i             (irq_i),
      .irq_ctrl_b_i        (irq_ctrl_b),
      .priv_lvl_b_i        (priv_lvl_b),
      .v_b_i               (v_b),
      // T6b-3a: per-hart decode context for the remaining per-lane selects.
      .tvm_b_i             (tvm_b),
      .tw_b_i              (tw_b),
      .vtw_b_i             (vtw_b),
      .tsr_b_i             (tsr_b),
      .hu_b_i              (hu_b),
      .debug_mode_b_i      (debug_mode_b),
      .fs_b_i              (fs_b),
      .vfs_b_i             (vfs_b),
      .vs_b_i              (vs_b),
      .frm_b_i             (frm_b),
      .mcbie_b_i           (mcbie_b),
      .scbie_b_i           (scbie_b),
      .hcbie_b_i           (hcbie_b),
      .mcbcfe_b_i          (mcbcfe_b),
      .scbcfe_b_i          (scbcfe_b),
      .hcbcfe_b_i          (hcbcfe_b),
      .mcbze_b_i           (mcbze_b),
      .scbze_b_i           (scbze_b),
      .hcbze_b_i           (hcbze_b),
      .jvt_b_i             (jvt_b),
      .debug_mode_i        (debug_mode),
      .tvm_i               (tvm_csr_id),
      .tw_i                (tw_csr_id),
      .vtw_i               (vtw_csr_id),
      .tsr_i               (tsr_csr_id),
      .hu_i                (hu),
      .mcbie_i             (mcbie),
      .scbie_i             (scbie),
      .hcbie_i             (hcbie),
      .mcbcfe_i            (mcbcfe),
      .scbcfe_i            (scbcfe),
      .hcbcfe_i            (hcbcfe),
      .mcbze_i             (mcbze),
      .scbze_i             (scbze),
      .hcbze_i             (hcbze),
      .hart_id_i           (hart_id_i),
      .smt_hart_id_i       (smt_active_hart),
      .smt_pause_hint_o    (smt_pause_hint),
      .compressed_ready_i  (x_compressed_ready),
      .compressed_resp_i   (x_compressed_resp),
      .compressed_valid_o  (x_compressed_valid),
      .compressed_req_o    (x_compressed_req),
      .jvt_i               (jvt),
      .debug_from_trigger_i(debug_from_trigger),
      // DCACHE interfaces
      .dcache_req_ports_i  (dcache_req_ports_cache_id),
      .dcache_req_ports_o  (dcache_req_ports_id_cache)
  );

  // ------------------------
  // U6.1 SMT thread fabric
  // NrHarts==1: identity (active=0, no switches). Contention policies
  // (switch-on-miss / quantum RR / anti-starve) elaborate for NrHarts==2.
  // ------------------------
  // U6.1: per-hart WFI halt from CSR banks (not active-only sticky).
  // Sticky-active-only left inactive harts ~ready forever after timer/IPI wake
  // while another hart held the pipeline (dual-WFI without IPI hang).
  assign smt_hart_enable = '1;
  assign smt_fetch_fire  = |(fetch_valid_if_id & fetch_ready_id_if);
  assign smt_issue_fire  = |issue_instr_issue_id;
  // I4bg: ALU lui/addi to t0 (rd==x5, use_imm) just issued.
  // I4bi: also remember PC+size so a later switch can bank that, not npc_q.
  logic smt_t0_imm;
  logic [CVA6Cfg.VLEN-1:0] smt_t0_next_q, smt_t0_next_d;
  always_comb begin
    smt_t0_imm = 1'b0;
    smt_t0_next_d = smt_t0_next_q;
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
      if (issue_instr_issue_id[p] &&
          issue_entry_id_issue[p].fu == ALU &&
          issue_entry_id_issue[p].rd == 5'd5 &&
          issue_entry_id_issue[p].use_imm) begin
        smt_t0_imm = 1'b1;
        smt_t0_next_d = issue_entry_id_issue[p].pc +
            (issue_entry_id_issue[p].is_compressed
                 ? {{CVA6Cfg.VLEN - 2{1'b0}}, 2'b10}
                 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) smt_t0_next_q <= '0;
    else if (CVA6Cfg.NrHarts > 1 && smt_t0_imm) smt_t0_next_q <= smt_t0_next_d;
  end
  // I4bk: fetch-aligned t0_next ([2:0]==0) after addi t0 → bank that PC.
  // I4bl: mid-block after RVI lui t0 ([2:0]==4) → bank 8B line start so
  // lui+addi re-fetch together (I4bj banked +4 and hold-failed 51b1c001).
  // I4bp cave-lui-only line-start reverted (nat lost 51b1d000; peel still 3e4).
  assign smt_t0_alt = (smt_t0_next_q[2:0] == 3'b100)
                          ? {smt_t0_next_q[CVA6Cfg.VLEN-1:3], 3'b000}
                          : smt_t0_next_q;
  assign smt_t0_rewind = |smt_t0_next_q
      && ((smt_t0_next_q[2:0] == 3'b000) || (smt_t0_next_q[2:0] == 3'b100))
      && (smt_t0_alt[CVA6Cfg.VLEN-1:12] == smt_npc_live[CVA6Cfg.VLEN-1:12])
      && (smt_t0_alt < smt_npc_live)
      && ((smt_npc_live - smt_t0_alt) <= {{CVA6Cfg.VLEN - 5{1'b0}}, 5'd16});
`ifdef G6LC_FETCH_B
  logic unused_t0_bank;
  assign unused_t0_bank = smt_t0_rewind | (|smt_t0_alt);
`endif
  assign smt_miss_clear  = ~dcache_miss_cache_perf & ~icache_miss_cache_perf & ~stall_issue;
  assign smt_long_block  = flush_ctrl_ex;

  if (CVA6Cfg.NrHarts <= 1) begin : gen_smt_halt_single
    assign smt_hart_halt = '0;
  end else begin : gen_smt_halt_multi
    assign smt_hart_halt = smt_csr_hart_halt;
  end

  g6lc_hart_state #(
      .CVA6Cfg(CVA6Cfg)
  ) i_smt_hart_state (
      .clk_i,
      .rst_ni,
      .active_hart_i (smt_active_hart),
      .dcache_miss_i (dcache_miss_cache_perf),
      .icache_miss_i (icache_miss_cache_perf),
      .issue_stall_i (stall_issue),
      .long_block_i  (smt_long_block),
      .hart_halt_i   (smt_hart_halt),
      .hart_enable_i (smt_hart_enable),
      .flush_i       (flush_ctrl_if),
      .miss_clear_i  (smt_miss_clear),
      .hart_ready_o  (smt_hart_ready),
      .hart_dmiss_o  (smt_hart_dmiss),
      .hart_imiss_o  (smt_hart_imiss),
      .hart_block_o  (smt_hart_block)
  );

`ifdef G6LC_FETCH_B
  assign smt_switch_hold = 1'b0;
  assign smt_hart_ready_sel = smt_hart_ready;
`else
  // Dual-hart bare-metal SMT switch holds:
  // 1) Sticky: primary has committed outside boot ROM + DRAM grace.
  // 2) Sticky per-hart first-exit: do not eject a hart until *that* hart has
  //    committed outside the boot ROM page (covers peer's first bootrom pass).
  //    Live-NPC hold was too sticky after WFI yield (pin + freeze deadlock).
  logic        smt_boot_done_q;
  logic [7:0]  smt_dram_grace_q;
  logic [CVA6Cfg.NrHarts-1:0] smt_hart_left_rom_q;
  localparam logic [7:0] SMT_DRAM_GRACE = 8'd200;
  if (CVA6Cfg.NrHarts > 1) begin : gen_smt_boot_hold
    logic commit_outside_rom;
    logic active_needs_boot;
    assign commit_outside_rom =
        |commit_ack &&
        (pc_commit[CVA6Cfg.VLEN-1:16] != boot_addr_i[CVA6Cfg.VLEN-1:16]) &&
        (pc_commit[CVA6Cfg.VLEN-1:12] != '0);
    logic active_needs_boot_raw;
    // 16-bit stuck-escape for first-boot hold (dual-ready RR used to eject the
    // peer mid-bootrom after an 8-bit/128 cap; WFI-yield survived because the
    // primary was ~ready).
    logic [15:0] smt_boot_hold_cnt_q;
    localparam logic [15:0] SMT_BOOT_HOLD_CAP = 16'd2048;
    // One-shot exclusive window on each hart's *first* activation after the
    // primary DRAM grace. Pure dual-ready quantum thrash (Q=8) every ~9 cycles
    // never gave peer a contiguous bootrom->peer_pass->tohost run; WFI-yield
    // paths worked because primary left the ready set. This is NOT continuous
    // force-boot — only the first activation per hart.
    logic [CVA6Cfg.NrHarts-1:0] smt_hart_seen_q;
    logic [9:0] smt_first_act_excl_q;
    localparam logic [9:0] SMT_FIRST_ACT_EXCL = 10'd512;
    logic first_act_excl;
    // OpenSBI early boot uses one shared temp stack before lottery/scratch
    // setup. Dual-ready SMT must not interleave two harts on that stack or both
    // fall into _start_hang with no console. Hart 0 alone owns the pipeline for
    // SMT_COLD_EXCL cycles from reset (then dual-ready + first-act resume).
    logic [17:0] smt_cold_q;
    localparam logic [17:0] SMT_COLD_EXCL = 18'd200000;
    logic cold_excl;
    assign active_needs_boot_raw =
        ~smt_hart_left_rom_q[smt_active_hart] & ~smt_hart_halt[smt_active_hart];
    assign active_needs_boot =
        active_needs_boot_raw & (smt_boot_hold_cnt_q < SMT_BOOT_HOLD_CAP);
    assign first_act_excl = (smt_first_act_excl_q != '0);
    // G1df: COLD_EXCL does not outlive boot-hart WFI.
    // G1dg MINI-FAIL: do not also lift after DRAM+grace
    // (hart1 interleaved the shared boot path).
    // SL-C: IPI-seen peer also lifts cold_excl (I4dn). OpenSBI lottery
    // must run the secondary while _boot_status==1; waiting for cookie
    // WFI is status==2 and re-entry amoswaps 2→1 (G1di). Do not lower
    // 200000. Not G3 switch-to-sp0. SMT.
    logic peer_ipi_seen;
    always_comb begin
      peer_ipi_seen = 1'b0;
      for (int unsigned h = 1; h < CVA6Cfg.NrHarts; h++)
        if (smt_hart_seen_q[h]) peer_ipi_seen = 1'b1;
    end
    assign cold_excl = (smt_cold_q < SMT_COLD_EXCL) && ~smt_hart_halt[0] &&
                       ~peer_ipi_seen;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        smt_boot_done_q      <= 1'b0;
        smt_dram_grace_q     <= '0;
        smt_hart_left_rom_q  <= '0;
        smt_boot_hold_cnt_q  <= '0;
        smt_hart_seen_q      <= '0;
        smt_first_act_excl_q <= '0;
        smt_cold_q           <= '0;
      end else begin
        if (smt_cold_q != 18'h3ffff)
          smt_cold_q <= smt_cold_q + 18'd1;
        // I4dn: an incoming IPI is the hart's first real activation request
        // from the boot hart. Mark it seen so smt_hart_ready_sel unmasks it.
        for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++)
          if (ipi_i[h]) smt_hart_seen_q[h] <= 1'b1;
        if (commit_outside_rom) begin
          smt_boot_done_q <= 1'b1;
          if (commit_ack[0])
            smt_hart_left_rom_q[commit_instr_id_commit[0].hart_id] <= 1'b1;
          if (CVA6Cfg.NrCommitPorts > 1 && commit_ack[1])
            smt_hart_left_rom_q[commit_instr_id_commit[1].hart_id] <= 1'b1;
          if (smt_dram_grace_q < SMT_DRAM_GRACE)
            smt_dram_grace_q <= smt_dram_grace_q + 8'd1;
        end
        // Count consecutive cycles the active hart still needs first DRAM exit.
        if (smt_switch) begin
          smt_boot_hold_cnt_q <= '0;
          // Arm one-shot exclusive for a hart that has not yet left ROM.
          // I4dn may already have set seen_q via IPI; !seen would skip
          // exclusive and RR would yank hart1 mid-lottery. smt_switch
          // pulses with active already equal to the incoming hart.
          if (!smt_hart_left_rom_q[smt_active_hart] && smt_boot_done_q &&
              (smt_dram_grace_q >= SMT_DRAM_GRACE)) begin
            smt_hart_seen_q[smt_active_hart] <= 1'b1;
            smt_first_act_excl_q             <= SMT_FIRST_ACT_EXCL;
          end else begin
            smt_first_act_excl_q <= '0;
          end
        end else begin
          if (active_needs_boot_raw) begin
            if (smt_boot_hold_cnt_q != 16'hffff)
              smt_boot_hold_cnt_q <= smt_boot_hold_cnt_q + 16'd1;
          end else begin
            smt_boot_hold_cnt_q <= '0;
          end
          // Mark active as seen even without switch (hart 0 at reset).
          smt_hart_seen_q[smt_active_hart] <= 1'b1;
          if (smt_first_act_excl_q != '0)
            smt_first_act_excl_q <= smt_first_act_excl_q - 10'd1;
        end
      end
    end
    assign smt_switch_hold =
        cold_excl
        | ~smt_boot_done_q
        | (smt_dram_grace_q < SMT_DRAM_GRACE)
        | active_needs_boot
        | first_act_excl;
    // G1di: once the boot hart has left ROM, unseen harts stay not-ready.
    // They become ready when explicitly seen (first switch) or woken by IPI.
    // Late reset-vector fetch amoswaps _boot_status 2→1 (fw_boot_hart
    // returns -1) and the secondary waits forever. TRACE: status 1→2
    // @20480 → 1 @22528. Not G3 switch-to-sp0. Not G1dg DRAM+grace.
    always_comb begin
      smt_hart_ready_sel = smt_hart_ready;
      if (smt_boot_done_q) begin
        for (int unsigned h = 0; h < CVA6Cfg.NrHarts; h++)
          if (!smt_hart_seen_q[h]) smt_hart_ready_sel[h] = 1'b0;
      end
    end
  end else begin : gen_smt_boot_hold_off
    assign smt_switch_hold = 1'b0;
    assign smt_hart_ready_sel = smt_hart_ready;
  end
`endif














  // N1c bounded drain (T10f): resident-hart commit-head classification for
  // the force gate. The head may be killed only while it carries no
  // uncancellable side effect — never an AMO/LR-SC (mid-atomic), never a
  // CSR/privilege op (MRET/SRET/DRET/WFI-class side effects live in the CSR
  // FU), never a memory-order, TLB or cache-block op, and never an exception
  // already bound to commit. WFI is the sole special case and forces
  // immediately: the hart wants to sleep, the peer must run, and re-executing
  // the WFI on the next activation reproduces the sleep.
  // WFI keeps the committed-head form: a WFI head is never phys-masked, and
  // once it commits the hart halts and the drain resolves without a flush.
  assign smt_head_wfi = commit_instr_id_commit[0].valid &&
                        commit_instr_id_commit[0].op == ariane_pkg::WFI;
  assign smt_head_plain = sb_head_valid[smt_active_hart] &&
      !commit_instr_id_commit[0].ex.valid &&
      !ariane_pkg::is_amo(commit_instr_id_commit[0].op) &&
      (commit_instr_id_commit[0].fu != ariane_pkg::CSR) &&
      (commit_instr_id_commit[0].op != ariane_pkg::WFI) &&
      !(commit_instr_id_commit[0].op inside {
          ariane_pkg::FENCE, ariane_pkg::FENCE_I,
          ariane_pkg::SFENCE_VMA, ariane_pkg::HFENCE_VVMA,
          ariane_pkg::HFENCE_GVMA,
          ariane_pkg::CBO_CLEAN, ariane_pkg::CBO_FLUSH,
          ariane_pkg::CBO_INVAL, ariane_pkg::CBO_ZERO});
  // Killing the resident hart is additionally unsafe while a store is
  // pending at commit / in the write buffer (no_st_pending_commit), while an
  // AMO/SC is committed into the LSU and awaiting acceptance (the "cannot
  // cancel in flight" handshake), while a debug redirect owns the resident
  // bank write, or while the hart has no live head PC to restart from.
  assign smt_drain_safe = no_st_pending_commit &&
      sb_head_valid[smt_active_hart] &&
      !(lsu_commit_commit_ex && !lsu_commit_ready_ex_commit) &&
      !(CVA6Cfg.DebugEn && set_debug_pc);

  g6lc_thread_select #(
      .CVA6Cfg(CVA6Cfg)
  ) i_smt_thread_select (
      .clk_i,
      .rst_ni,
      .fetch_fire_i        (smt_fetch_fire),
      .issue_fire_i        (smt_issue_fire),
      .flush_i             (flush_ctrl_if),
      .hold_i              (smt_switch_hold),
      // T6b seam: with SmtDrainedHandoff=1 the selector may switch only on a
      // drained backend (today's coarse handoff). With 0 the switch becomes a
      // fetch-slot policy and hart-tagged ownership (LSQ/store buffer/IQ) keeps
      // the two resident streams disjoint.
      // T6a contract = SB empty + no stores pending + ROB/IQ/LSQ drained.
      // The last three are now explicit at the seam (FP-3); the +smt_stats
      // tail counters show they never outlive sb_empty on WT or HPDCACHE.
      // The g6lc64_ooo_server switch-with-state-resident was the HPDCACHE
      // wbuf grant skid, covered in cva6_hpdcache_wrapper (st_skid_q).
      .drain_ready_i       (CVA6Cfg.SmtDrainedHandoff ?
                            (smt_sb_empty && no_st_pending_commit && !flush_ctrl_id &&
                             ooo_drained_id) : 1'b1),
      .commit_i            (|commit_macro_ack),
      .drain_killable_i    (smt_drain_safe),
      .head_wfi_i          (smt_head_wfi),
      .head_plain_i        (smt_head_plain),
      .head_pc_i           (sb_head_pc[smt_active_hart]),
      .drain_force_o       (smt_drain_force),
      .drain_force_wfi_o   (smt_drain_force_wfi),
      .drain_force_abs_o   (smt_drain_force_abs),
      .drain_forced_o      (smt_drain_forced),
      .drain_force_pc_o    (smt_drain_force_pc),
      .quiesce_o           (smt_quiesce),
      .id_uniss_i          (issue_entry_valid_id_issue[0]),
      .iq_valid_i          (fetch_valid_if_id[0]),
      .t0_imm_i            (smt_t0_imm),
      .trap_hold_i         (smt_trap_hold),
      .hart_ready_i        (smt_hart_ready_sel),
      .hart_dmiss_i        (smt_hart_dmiss),
      .hart_imiss_i        (smt_hart_imiss),
      .hart_block_i        (smt_hart_block),
      .pause_hint_i        (smt_pause_hint),
      .active_hart_o       (smt_active_hart),
      .switch_o            (smt_switch),
      .t0_extra_o          (smt_t0_extra),
      .switch_on_miss_o    (smt_switch_on_miss),
      .switch_on_quantum_o (smt_switch_on_quantum),
      .switch_on_starve_o  (smt_switch_on_starve)
  );

  //pragma translate_off
  // T20: one-ticket-per-dump handshake from the [smt-stall] dump (inside
  // gen_smt_stats, drained SMT targets only) to the HPDCACHE replay-table
  // probe gen_hpd_trace below (any HPDCACHE target). Module-level so that
  // neither generate scope has to name the other.
  int unsigned hpd_ticket = 0;
`ifdef G6LC_FETCH_B
  // N1/T10a drained-handoff observer (+smt_stats). Reads the selector's
  // drain FSM hierarchically (sim-only) and attributes every
  // drain_pending && !drain_ready cycle to a cause bucket. Prints on
  // [smt-drain] every 1M cycles and at final.
  if (CVA6Cfg.NrHarts > 1 && CVA6Cfg.SmtDrainedHandoff) begin : gen_smt_stats
    localparam int unsigned SSNH = CVA6Cfg.NrHarts;
    bit smt_stats_en;
    longint unsigned ss_cycle, ss_switch, ss_drain_req, ss_drain_abort;
    longint unsigned ss_drain_cyc, ss_drain_max;
    longint unsigned ss_hist[8];   // <8,8-15,16-31,32-63,64-127,128-255,256-511,>=512
    longint unsigned ss_w_sb, ss_w_st, ss_w_flushid;
    longint unsigned ss_w_peer, ss_w_hold, ss_w_trap, ss_w_flush;
    longint unsigned ss_force, ss_force_wfi, ss_force_abs;
    longint unsigned ss_retired[SSNH < 4 ? 4 : SSNH];  // padded: prints index 0..3
    longint unsigned ss_drop;
    longint unsigned ss_set_cycle;
    bit ss_prev_dp;
    // N1d/T10g stall dump: when the resident hart retires nothing for
    // SS_STALL_GAP cycles while a drain pends (each further SS_STALL_GAP
    // crossing re-dumps, bounded to SS_DUMP_MAX per run) and again at
    // final, dump the commit-head classification, the LSU/load-unit and
    // WT miss-unit/wbuffer state that arbitrate drain_ready.
    localparam longint unsigned SS_STALL_GAP = 65536;
    localparam int unsigned    SS_DUMP_MAX   = 8;
    longint unsigned ss_last_commit[SSNH];
    int unsigned    ss_dump_cnt;
    longint unsigned ss_dump_milestone;
    // One-ticket-per-dump handshake to the OoO-only deep probe below (the
    // generate scope there does not exist on in-order drained targets).
    int unsigned    ss_dump_id;
    initial begin
      smt_stats_en = $test$plusargs("smt_stats");
      ss_cycle = 0; ss_switch = 0; ss_drain_req = 0; ss_drain_abort = 0;
      ss_drain_cyc = 0; ss_drain_max = 0; ss_set_cycle = 0; ss_prev_dp = 0;
      ss_w_sb = 0; ss_w_st = 0; ss_w_flushid = 0;
      ss_w_peer = 0; ss_w_hold = 0; ss_w_trap = 0; ss_w_flush = 0;
      ss_force = 0; ss_force_wfi = 0; ss_force_abs = 0;
      ss_drop = 0;
      ss_dump_cnt = 0; ss_dump_milestone = 0; ss_dump_id = 0;
      for (int i = 0; i < 8; i++) ss_hist[i] = 0;
      for (int h = 0; h < SSNH; h++) begin
        ss_retired[h] = 0;
        ss_last_commit[h] = 0;
      end
    end
    logic ss_dp, ss_drdy;
    assign ss_dp   = i_smt_thread_select.gen_smt.drain_pending_q;
    assign ss_drdy = smt_sb_empty && no_st_pending_commit && !flush_ctrl_id &&
                     ooo_drained_id;

    function automatic void ss_stall_dump(input string why);
      automatic int unsigned hs;
      automatic int unsigned ih[CVA6Cfg.NrHarts];
      hs = issue_stage_i.i_scoreboard.commit_sel_slot[0];
      for (int h = 0; h < CVA6Cfg.NrHarts; h++) ih[h] = 0;
      for (int unsigned s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
        if (issue_stage_i.i_scoreboard.mem_q[s].issued &&
            int'(issue_stage_i.i_scoreboard.mem_q[s].sbe.hart_id) < CVA6Cfg.NrHarts)
          ih[int'(issue_stage_i.i_scoreboard.mem_q[s].sbe.hart_id)]++;
      $display("[smt-stall] %s cyc=%0d hart=%0d gap=%0d dp=%0d drdy=%0d kill=%0d headv=%0d hwfi=%0d hplain=%0d fcnt=%0d forced=%0d sbem=%0d stp=%0d fid=%0d cmt=%0d sbn=%0d",
               why, ss_cycle, smt_active_hart,
               ss_cycle - ss_last_commit[smt_active_hart],
               ss_dp, ss_drdy, smt_drain_safe,
               sb_head_valid[smt_active_hart], smt_head_wfi, smt_head_plain,
               i_smt_thread_select.gen_smt.drain_force_cnt_q,
               i_smt_thread_select.gen_smt.drain_forced_q,
               smt_sb_empty, no_st_pending_commit, flush_ctrl_id,
               |commit_macro_ack,
               issue_stage_i.i_scoreboard.sb_issued_cnt);
      $display("[smt-stall] head slot=%0d hs0=%0d hs1=%0d pc=%h op=%0d fu=%0d cvld=%0d sbev=%0d issued=%0d canc=%0d exv=%0d repl=%0d ppend=%0d pmod=%0d hart=%0d ih={%0d,%0d}",
               hs,
               issue_stage_i.i_scoreboard.head_slot[0],
               CVA6Cfg.NrHarts > 1 ? issue_stage_i.i_scoreboard.head_slot[1] : 0,
               commit_instr_id_commit[0].pc, commit_instr_id_commit[0].op,
               commit_instr_id_commit[0].fu, commit_instr_id_commit[0].valid,
               issue_stage_i.i_scoreboard.mem_q[hs].sbe.valid,
               issue_stage_i.i_scoreboard.mem_q[hs].issued,
               issue_stage_i.i_scoreboard.mem_q[hs].cancelled,
               commit_instr_id_commit[0].ex.valid,
               issue_stage_i.i_scoreboard.mem_q[hs].replay,
               issue_stage_i.i_scoreboard.phys_pending_i[hs],
               issue_stage_i.i_scoreboard.phys_mod_i,
               commit_instr_id_commit[0].hart_id,
               ih[0], CVA6Cfg.NrHarts > 1 ? ih[1] : 0);
      $display("[smt-stall] ldu st=%0d tid=%0d pvld=%0d paddr=%h dreq=%0d rvld=%0d | stu st=%0d | lsu_cmt=%0d lsu_rdy=%0d | wbem=%0d wbni=%0d",
               int'(ex_stage_i.lsu_i.i_load_unit.state_q),
               ex_stage_i.lsu_i.i_load_unit.load_trans_id_o,
               ex_stage_i.lsu_i.i_load_unit.load_paddr_valid_o,
               ex_stage_i.lsu_i.i_load_unit.load_paddr_o,
               ex_stage_i.lsu_i.i_load_unit.req_port_o.data_req,
               ex_stage_i.lsu_i.i_load_unit.req_port_i.data_rvalid,
               int'(ex_stage_i.lsu_i.i_store_unit.state_q),
               lsu_commit_commit_ex, lsu_commit_ready_ex_commit,
               dcache_commit_wbuffer_empty, dcache_commit_wbuffer_not_ni);
      // The WT miss-unit/wbuffer/adapter line lives in gen_wt_stall_probe
      // below (gen_cache_wt is absent on HPDCACHE drained targets such as
      // g6lc64_ooo_server); it fires off the same ss_dump_id ticket.
      // N1d-2: slot-lifetime bitmaps + staging state. An issued slot with
      // sbe.valid=0 is a zombie head (never wrote back); the iro vector
      // shows which gate holds the in-flight op (operand vs FU credit vs
      // downstream stall), and the store commit-queue head exposes a store
      // whose grant/rvalid never completes.
      begin
        automatic logic [CVA6Cfg.NR_SB_ENTRIES-1:0] iv, vv, cv, rv;
        iv = '0; vv = '0; cv = '0; rv = '0;
        for (int unsigned s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++) begin
          iv[s] = issue_stage_i.i_scoreboard.mem_q[s].issued;
          vv[s] = issue_stage_i.i_scoreboard.mem_q[s].sbe.valid;
          cv[s] = issue_stage_i.i_scoreboard.mem_q[s].cancelled;
          rv[s] = issue_stage_i.i_scoreboard.mem_q[s].replay;
        end
        $display("[smt-stall] sbm iss=%h vld=%h canc=%h repl=%h", iv, vv, cv, rv);
      end
      $display("[smt-stall] dsp ivld=%b iack=%b pc=%h tid=%0d fu=%0d op=%0d hart=%0d | iro raw=%b rs1=%b rs2=%b rs3=%b fub=%b csr=%0d flu=%0d lsu=%0d mul=%0d casq=%0d lrsc=%0d st=%b",
               issue_stage_i.issue_instr_valid_iro,
               issue_stage_i.issue_ack_iro,
               issue_stage_i.issue_instr_iro[0].pc,
               issue_stage_i.issue_instr_iro[0].trans_id,
               issue_stage_i.issue_instr_iro[0].fu,
               issue_stage_i.issue_instr_iro[0].op,
               issue_stage_i.issue_instr_iro[0].hart_id,
               issue_stage_i.i_issue_read_operands.stall_raw,
               issue_stage_i.i_issue_read_operands.stall_rs1,
               issue_stage_i.i_issue_read_operands.stall_rs2,
               issue_stage_i.i_issue_read_operands.stall_rs3,
               issue_stage_i.i_issue_read_operands.fu_busy,
               issue_stage_i.i_issue_read_operands.fus_busy[0].csr,
               issue_stage_i.i_issue_read_operands.flu_ready_i,
               issue_stage_i.i_issue_read_operands.lsu_ready_i,
               issue_stage_i.i_issue_read_operands.mult_valid_q,
               issue_stage_i.i_issue_read_operands.casq_stall,
               issue_stage_i.i_issue_read_operands.lr_sc_pair_q,
               issue_stage_i.i_issue_read_operands.stall_i);
      $display("[smt-stall] stq ccnt=%0d crp=%0d cvld=%0d wrv=%0d cbo=%0d ctid=%0d caddr=%h scnt=%0d",
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_status_cnt_q,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q].valid,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q].wait_rvalid,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q].cbo_op,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q].trans_id,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q].address,
               ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_status_cnt_q);
      // N1d-3: spec-queue residency scan. A load parked in WAIT_PAGE_OFFSET
      // holds on st_pipeline_busy (page_offset match + STQ live); the wedge
      // needs the blocking entry's owner (hart/tid) and its drain status —
      // a peer-hart zombie or an age-misjudged younger entry can never drain
      // while the resident's commit head is the load itself.
      begin
        automatic logic [11:0] s_lpo;
        s_lpo = ex_stage_i.lsu_i.i_store_unit.store_buffer_i.page_offset_i;
        $display("[smt-stall] sqh scnt=%0d srp=%0d swp=%0d ccnt=%0d crp=%0d cwp=%0d oltid=%0d ldtid=%0d ldhart=%0d lpo=%h pom=%0d sbempty=%0d",
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_status_cnt_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_read_pointer_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_write_pointer_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_status_cnt_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_write_pointer_q,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.oldest_live_tid_i,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.load_trans_id_i,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.load_hart_i,
                 s_lpo,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.page_offset_matches_o,
                 ex_stage_i.lsu_i.i_store_unit.store_buffer_i.store_buffer_empty_o);
        for (int unsigned e = 0;
             e < ex_stage_i.lsu_i.i_store_unit.store_buffer_i.DEPTH_SPEC; e++)
          if (ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].valid)
            $display("[smt-stall] sqe i=%0d tid=%0d hart=%0d addr=%h cbo=%0d fk=%0d canc=%0d live=%0d m12=%0d",
                     e,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].trans_id,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].hart,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].address,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].cbo_op,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].fwd_keep,
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.cancelled_mask_i[
                       ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].trans_id],
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.sb_live_i[
                       ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].trans_id],
                     ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[e].address[11:0] == s_lpo);
        $display("[smt-stall] headtid=%0d",
                 issue_stage_i.i_scoreboard.mem_q[hs].sbe.trans_id);
      end
      ss_dump_id = ss_dump_id + 1;
      // T20: hand the ticket to the module-level HPDCACHE replay-table probe
      // (gen_hpd_trace, +hpd_trace) so it dumps the rtab anatomy as well.
      hpd_ticket = hpd_ticket + 1;
    endfunction
    // N1d-2: OoO-only deep anatomy. gen_full_ooo / the second csr_buffer
    // entry do not exist on the in-order drained targets, so the references
    // live in their own generate scope; it fires one cycle after each
    // ss_stall_dump call (bounded transitively by SS_DUMP_MAX + final).
    if (CVA6Cfg.OoOEn) begin : gen_ooo_stall_probe
      function automatic void ss_ooo_dump(input int unsigned hs);
        $display("[smt-stall] dspq rob=%0d iqf=%0d ldf=%0d stf=%0d iqv=%b iqa=%b",
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.rob_full,
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.iq_full,
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.ld_full,
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.st_full,
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.iq_issue_valid,
                 issue_stage_i.gen_full_ooo.i_ooo_dispatch.iq_issue_ack);
        $display("[smt-stall] csrb rdy=%0d cmt=%0d ctid=%0d t0v=%0d t0id=%0d t0a=%h t1v=%0d t1id=%0d t1a=%h",
                 ex_stage_i.csr_ready,
                 ex_stage_i.csr_commit_i,
                 ex_stage_i.commit_tran_id_i,
                 ex_stage_i.csr_buffer_i.tab_q[0].valid,
                 ex_stage_i.csr_buffer_i.tab_q[0].tid,
                 ex_stage_i.csr_buffer_i.tab_q[0].csr_address,
                 ex_stage_i.csr_buffer_i.tab_q[1].valid,
                 ex_stage_i.csr_buffer_i.tab_q[1].tid,
                 ex_stage_i.csr_buffer_i.tab_q[1].csr_address);
        for (int unsigned e = 0; e < issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.DEPTH; e++)
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].valid)
            $display("[smt-stall] iq e=%0d tid=%0d pc=%h fu=%0d op=%0d hart=%0d rdy=%b%b%b sel=%0d%s",
                     e,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.trans_id,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.pc,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.fu,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.op,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.hart_id,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].rs1_rdy,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].rs2_rdy,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].rs3_rdy,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.ready[e],
                     int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.trans_id) == hs
                         ? " <== HEAD" : "");
      endfunction
      int unsigned ss_ooo_seen = 0;
      always @(posedge clk_i) begin
        if (smt_stats_en && ss_dump_id != ss_ooo_seen) begin
          ss_ooo_seen = ss_dump_id;
          ss_ooo_dump(issue_stage_i.i_scoreboard.commit_sel_slot[0]);
        end
      end
      // FP-3 tail counters: cycles where the legacy drain_ready triple
      // (sb_empty && no_st_pending && !flush_id) already holds but ROB/IQ/LSQ
      // are still resident — the window the ooo_drained_id conjunct closes.
      int unsigned ss_tail_lsq = 0, ss_tail_rob = 0, ss_tail_iq = 0,
                   ss_tail_any = 0;
      always @(posedge clk_i) begin
        if (smt_stats_en && rst_ni &&
            smt_sb_empty && no_st_pending_commit && !flush_ctrl_id) begin
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.lsq_busy)
            ss_tail_lsq = ss_tail_lsq + 1;
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q != '0)
            ss_tail_rob = ss_tail_rob + 1;
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.count_q != '0)
            ss_tail_iq = ss_tail_iq + 1;
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.lsq_busy ||
              issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q != '0 ||
              issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.count_q != '0)
            ss_tail_any = ss_tail_any + 1;
        end
      end
      final begin
        if (smt_stats_en)
          $display("[smt-drain] tail lsq=%0d rob=%0d iq=%0d any=%0d",
                   ss_tail_lsq, ss_tail_rob, ss_tail_iq, ss_tail_any);
      end
    end
    // FP-3a: the WT miss-unit/wbuffer/adapter anatomy. gen_cache_wt exists
    // only for DCacheType == WT, so the references get their own scope
    // (HPDCACHE drained targets dump the rest of the anatomy without it).
    if (CVA6Cfg.DCacheType == config_pkg::WT) begin : gen_wt_stall_probe
      int unsigned ss_wt_seen = 0;
      always @(posedge clk_i) begin
        if (smt_stats_en && ss_dump_id != ss_wt_seen) begin
          ss_wt_seen = ss_dump_id;
          $display("[smt-stall] dmu st=%0d mvld=%0d mpaddr=%h mid=%0d mport=%0d mcnt=%0d | wbv=%h | adp rvld=%0d d1st=%0d sinv=%0d",
                   int'(gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.state_q),
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.mshr_vld_q,
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.mshr_q.paddr,
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.mshr_q.id,
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.mshr_q.miss_port_idx,
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_missunit.cnt_q,
                   gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.valid,
                   gen_cache_wt.i_cache_subsystem.i_adapter.dcache_rtrn_vld_q,
                   gen_cache_wt.i_cache_subsystem.i_adapter.dcache_first_q,
                   gen_cache_wt.i_cache_subsystem.i_adapter.self_inval_pend_q);
        end
      end
    end
    // T19: the HPDCACHE pipeline/replay/MSHR anatomy behind a no-grant load
    // port (defect 2 — `ldu st=1 dreq=1` forever after drain forces killed an
    // in-flight miss). core_req_ready drops for every port on rtab_full /
    // a replayable rtab entry / uc_busy / cmo_busy / refill_busy / st1-st2
    // nops; the load-buffer bitmaps show slots whose response never came.
    if (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT ||
        CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WB ||
        CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB) begin : gen_hpd_stall_probe
      int unsigned ss_hpd_seen = 0;
      always @(posedge clk_i) begin
        if (smt_stats_en && ss_dump_id != ss_hpd_seen) begin
          ss_hpd_seen = ss_dump_id;
          $display("[smt-stall] hpd crv=%0d crr=%0d gntq=%b arbv=%b st1v=%0d st2m=%0d rtab v=%b full=%0d empty=%0d fence=%0d pop=%0d | mshr_e=%0d wbuf_e=%0d uc=%0d cmo=%0d refill=%0d | ldbuf v=%h f=%h full=%0d",
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.core_req_valid_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.core_req_ready_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.core_req_arbiter_i.arb_req_gnt_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.core_req_arbiter_i.core_req_valid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_req_valid_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st2_mshr_alloc_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.hpdcache_rtab_i.valid_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.rtab_full,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.rtab_empty_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.rtab_fence,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st0_rtab_pop_try_valid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.mshr_empty_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.wbuf_empty_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.uc_busy_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.cmo_busy_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.refill_busy_i,
                   ex_stage_i.lsu_i.i_load_unit.ldbuf_valid_q,
                   ex_stage_i.lsu_i.i_load_unit.ldbuf_flushed_q,
                   ex_stage_i.lsu_i.i_load_unit.ldbuf_full);
        end
      end
    end
    always @(posedge clk_i) begin
      if (!rst_ni) begin
        ss_prev_dp <= 1'b0;
      end else if (smt_stats_en) begin
        automatic longint unsigned dur;
        ss_cycle = ss_cycle + 1;
        if (ss_dp && !ss_prev_dp) begin
          ss_drain_req = ss_drain_req + 1;
          ss_set_cycle = ss_cycle;
        end
        if (ss_dp && !smt_switch) begin
          ss_drain_cyc = ss_drain_cyc + 1;
          if (!ss_drdy) begin
            if (!smt_sb_empty)                ss_w_sb      = ss_w_sb + 1;
            else if (!no_st_pending_commit)   ss_w_st      = ss_w_st + 1;
            else                              ss_w_flushid = ss_w_flushid + 1;
          end else if (!smt_hart_ready_sel[i_smt_thread_select.gen_smt.drain_peer_q]) begin
            ss_w_peer = ss_w_peer + 1;
          end else if (smt_switch_hold) begin
            ss_w_hold = ss_w_hold + 1;
          end else if (smt_trap_hold) begin
            ss_w_trap = ss_w_trap + 1;
          end else if (i_smt_thread_select.gen_smt.do_switch) begin
            // Grant cycle: drain_pending_q still reads 1 while switch_q has
            // not yet risen — the drain completes next cycle, not a stall.
          end else begin
            ss_w_flush = ss_w_flush + 1;
          end
        end
        if (ss_prev_dp && !ss_dp) begin
          if (smt_switch) begin
            dur = ss_cycle - ss_set_cycle;
            ss_switch = ss_switch + 1;
            if (dur > ss_drain_max) ss_drain_max = dur;
            if (dur < 8)         ss_hist[0] = ss_hist[0] + 1;
            else if (dur < 16)   ss_hist[1] = ss_hist[1] + 1;
            else if (dur < 32)   ss_hist[2] = ss_hist[2] + 1;
            else if (dur < 64)   ss_hist[3] = ss_hist[3] + 1;
            else if (dur < 128)  ss_hist[4] = ss_hist[4] + 1;
            else if (dur < 256)  ss_hist[5] = ss_hist[5] + 1;
            else if (dur < 512)  ss_hist[6] = ss_hist[6] + 1;
            else                 ss_hist[7] = ss_hist[7] + 1;
          end else begin
            ss_drain_abort = ss_drain_abort + 1;
          end
        end
        for (int unsigned p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
          if (commit_ack[p] && commit_drop_id_commit[p])
            ss_drop = ss_drop + 1;
          if (smt_retire_valid[p] && smt_retire_hart[p] < SSNH) begin
            ss_retired[smt_retire_hart[p]] = ss_retired[smt_retire_hart[p]] + 1;
            ss_last_commit[smt_retire_hart[p]] = ss_cycle;
          end
        end
        if (ss_dp && ss_dump_cnt < SS_DUMP_MAX) begin
          if (!ss_prev_dp) ss_dump_milestone = 0;
          if ((ss_cycle - ss_last_commit[smt_active_hart] >=
               ss_dump_milestone + SS_STALL_GAP)) begin
            ss_stall_dump("stall");
            ss_dump_milestone = ss_dump_milestone + SS_STALL_GAP;
            ss_dump_cnt = ss_dump_cnt + 1;
          end
        end else if (!ss_dp) begin
          ss_dump_milestone = 0;
        end
        if (smt_drain_force) ss_force = ss_force + 1;
        if (smt_drain_force_wfi) ss_force_wfi = ss_force_wfi + 1;
        if (smt_drain_force_abs) ss_force_abs = ss_force_abs + 1;
        if (ss_cycle % 1000000 == 0) begin
          $display("[smt-drain] cyc=%0d req=%0d switches=%0d aborts=%0d drain_cyc=%0d max=%0d wait_sb=%0d wait_st=%0d wait_flushid=%0d wait_peer=%0d wait_hold=%0d wait_trap=%0d wait_flush=%0d force=%0d force_wfi=%0d force_abs=%0d hist={%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d} ret={%0d,%0d,%0d,%0d} drop=%0d kill=%0d headv=%0d hwfi=%0d hplain=%0d fcnt=%0d acnt=%0d",
                   ss_cycle, ss_drain_req, ss_switch, ss_drain_abort,
                   ss_drain_cyc, ss_drain_max,
                   ss_w_sb, ss_w_st, ss_w_flushid, ss_w_peer, ss_w_hold,
                   ss_w_trap, ss_w_flush, ss_force, ss_force_wfi, ss_force_abs,
                   ss_hist[0], ss_hist[1], ss_hist[2], ss_hist[3],
                   ss_hist[4], ss_hist[5], ss_hist[6], ss_hist[7],
                   ss_retired[0], SSNH > 1 ? ss_retired[1] : 0,
                   SSNH > 2 ? ss_retired[2] : 0, SSNH > 3 ? ss_retired[3] : 0,
                   ss_drop, smt_drain_safe, sb_head_valid[smt_active_hart],
                   smt_head_wfi, smt_head_plain,
                   i_smt_thread_select.gen_smt.drain_force_cnt_q,
                   i_smt_thread_select.gen_smt.drain_abs_cnt_q);
        end
        ss_prev_dp <= ss_dp;
      end
    end
    final begin
      if (smt_stats_en) begin
        $display("[smt-drain] FINAL cyc=%0d req=%0d switches=%0d aborts=%0d drain_cyc=%0d max=%0d wait_sb=%0d wait_st=%0d wait_flushid=%0d wait_peer=%0d wait_hold=%0d wait_trap=%0d wait_flush=%0d force=%0d force_wfi=%0d force_abs=%0d hist={%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d} ret={%0d,%0d,%0d,%0d} drop=%0d kill=%0d headv=%0d hwfi=%0d hplain=%0d fcnt=%0d acnt=%0d",
                 ss_cycle, ss_drain_req, ss_switch, ss_drain_abort,
                 ss_drain_cyc, ss_drain_max,
                 ss_w_sb, ss_w_st, ss_w_flushid, ss_w_peer, ss_w_hold,
                 ss_w_trap, ss_w_flush, ss_force, ss_force_wfi, ss_force_abs,
                 ss_hist[0], ss_hist[1], ss_hist[2], ss_hist[3],
                 ss_hist[4], ss_hist[5], ss_hist[6], ss_hist[7],
                 ss_retired[0], SSNH > 1 ? ss_retired[1] : 0,
                 SSNH > 2 ? ss_retired[2] : 0, SSNH > 3 ? ss_retired[3] : 0,
                 ss_drop, smt_drain_safe, sb_head_valid[smt_active_hart],
                 smt_head_wfi, smt_head_plain,
                 i_smt_thread_select.gen_smt.drain_force_cnt_q,
                 i_smt_thread_select.gen_smt.drain_abs_cnt_q);
        if (ss_dp || (ss_cycle - ss_last_commit[smt_active_hart]) >= SS_STALL_GAP)
          ss_stall_dump("final");
      end
    end
  end
`endif
  //pragma translate_on

  // U5 full OoO lives in issue_stage (cva6_ooo_dispatch) when OoOEn=1.

  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_ex_id;
  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] wbdata_ex_id;
  exception_t [CVA6Cfg.NrWbPorts-1:0] ex_ex_ex_id;  // exception from execute, ex_stage to id_stage
  logic [CVA6Cfg.NrWbPorts-1:0] wt_valid_ex_id;

  assign trans_id_ex_id[FLU_WB] = flu_trans_id_ex_id;
  assign wbdata_ex_id[FLU_WB]   = flu_result_ex_id;
  assign ex_ex_ex_id[FLU_WB]    = flu_exception_ex_id;
  assign wt_valid_ex_id[FLU_WB] = flu_valid_ex_id;

  assign trans_id_ex_id[STORE_WB] = store_trans_id_ex_id;
  assign wbdata_ex_id[STORE_WB]   = store_result_ex_id;
  assign ex_ex_ex_id[STORE_WB]    = store_exception_ex_id;
  assign wt_valid_ex_id[STORE_WB] = store_valid_ex_id;

  assign trans_id_ex_id[LOAD_WB] = load_trans_id_ex_id;
  assign wbdata_ex_id[LOAD_WB]   = load_result_ex_id;
  assign ex_ex_ex_id[LOAD_WB]    = load_exception_ex_id;
  assign wt_valid_ex_id[LOAD_WB] = load_valid_ex_id;

  assign trans_id_ex_id[FPU_WB] = fpu_trans_id_ex_id;
  assign wbdata_ex_id[FPU_WB]   = fpu_result_ex_id;
  assign ex_ex_ex_id[FPU_WB]    = fpu_exception_ex_id;
  assign wt_valid_ex_id[FPU_WB] = fpu_valid_ex_id;

  if (CVA6Cfg.CvxifEn) begin
    always_comb begin : gen_cvxif_input_assignment
      x_compressed_ready = cvxif_resp_i.compressed_ready;
      x_compressed_resp  = cvxif_resp_i.compressed_resp;
      x_issue_ready      = cvxif_resp_i.issue_ready;
      x_issue_resp       = cvxif_resp_i.issue_resp;
      x_register_ready   = cvxif_resp_i.register_ready;
      x_result_valid     = cvxif_resp_i.result_valid;
      x_result           = cvxif_resp_i.result;
    end

    always_comb begin : gen_cvxif_output_assignment
      cvxif_req.compressed_valid = x_compressed_valid;
      cvxif_req.compressed_req   = x_compressed_req;
      cvxif_req.issue_valid      = x_issue_valid;
      cvxif_req.issue_req        = x_issue_req;
      cvxif_req.register_valid   = x_register_valid;
      cvxif_req.register         = x_register;
      cvxif_req.commit_valid     = x_commit_valid;
      cvxif_req.commit           = x_commit;
      cvxif_req.result_ready     = x_result_ready;
    end
    assign trans_id_ex_id[X_WB] = x_trans_id_ex_id;
    assign wbdata_ex_id[X_WB]   = x_result_ex_id;
    assign ex_ex_ex_id[X_WB]    = x_exception_ex_id;
    assign wt_valid_ex_id[X_WB] = x_valid_ex_id;
  // Exclusive with the CVXIF arm above (asserted below): both would drive the
  // same writeback slot, so the accelerator owns ACC_WB and CVXIF is tied off.
  end else if (CVA6Cfg.EnableAccelerator) begin
    assign cvxif_req = '0;
    assign trans_id_ex_id[ACC_WB] = acc_trans_id_ex_id;
    assign wbdata_ex_id[ACC_WB]   = acc_result_ex_id;
    assign ex_ex_ex_id[ACC_WB]    = acc_exception_ex_id;
    assign wt_valid_ex_id[ACC_WB] = acc_valid_ex_id;
  end else begin
    assign cvxif_req = '0;
    assign x_compressed_ready = '0;
    assign x_compressed_resp = '0;
    assign x_issue_ready = '0;
    assign x_issue_resp = '0;
    assign x_register_ready = '0;
    assign x_result_valid = '0;
    assign x_result = '0;
  end

  if (CVA6Cfg.CvxifEn && CVA6Cfg.EnableAccelerator) begin : gen_err_xif_and_acc
    $error("X-interface and accelerator port cannot be enabled at the same time.");
  end

  // ---------
  // Issue
  // ---------
  issue_stage #(
      .CVA6Cfg(CVA6Cfg),
      .bp_resolve_t(bp_resolve_t),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .exception_t(exception_t),
      .fu_data_t(fu_data_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .writeback_t(writeback_t),
      .x_issue_req_t(x_issue_req_t),
      .x_issue_resp_t(x_issue_resp_t),
      .x_register_t(x_register_t),
      .x_commit_t(x_commit_t)
  ) issue_stage_i (
      .clk_i,
      .rst_ni,
      .phys_valid_i(mem_phys_valid), .phys_addr_i(mem_phys_addr), .phys_id_i(mem_phys_id),
      .phys_hart_i(mem_phys_hart), .phys_size_i(mem_phys_size),
      .mod_valid_i(mem_mod_valid), .mod_addr_i(mem_mod_addr),
      .sb_full_o               (sb_full),
      .sb_empty_o              (smt_sb_empty),
      .spec_cancel_o           (spec_cancel),
      .cancelled_mask_o        (sb_cancelled_mask),
      .sb_live_o               (sb_live_mask),
      // T6b: per-hart oldest-live PC, exported for the T6b-2 recovery
      // restart; no consumer yet.
      .sb_head_pc_o            (sb_head_pc),
      .sb_head_valid_o         (sb_head_valid),
      .flush_unissued_instr_i  (flush_unissued_instr_ctrl_id),
      .flush_i                 (flush_ctrl_id),
      .stall_i                 (stall_acc_id),
      // ID Stage
      .decoded_instr_i         (issue_entry_id_issue),
      .decoded_instr_i_prev    (issue_entry_id_issue_prev),
      .orig_instr_i            (orig_instr_id_issue),
      .decoded_instr_valid_i   (issue_entry_valid_id_issue & {CVA6Cfg.NrIssuePorts{
          !smt_quiesce && !(CVA6Cfg.NrHarts > 1 && halt_ctrl)}}),
      .is_ctrl_flow_i          (is_ctrl_fow_id_issue),
      .decoded_instr_ack_o     (issue_instr_issue_id),
      .g1fh_csr_a0_i           (g1fh_csr_a0),
      .g1fh_hart_i             (smt_active_hart),
      .g1mf_v_o                (g1mf_v),
      .g1mf_rd_o               (g1mf_rd),
      .g1mf_line_o             (g1mf_line),
      .g1mf_a3_o               (g1mf_a3),
`ifndef G6LC_FETCH_B
      // G1gq salvage redirect: A/oracle only (ports guarded in issue_stage.sv).
      .npc_i                   (smt_npc_live),
      .g1gq_redir_o            (g1gq_redir),
      .g1gq_tgt_o              (g1gq_tgt),
`endif
      // Functional Units
      .rs1_forwarding_o        (rs1_forwarding_id_ex),
      .rs2_forwarding_o        (rs2_forwarding_id_ex),
      .fu_data_o               (fu_data_id_ex),
      .alu_bypass_o            (alu_bypass_id_ex),
      .pc_o                    (pc_id_ex),
      .branch_hart_o           (branch_hart_id_ex),
      .fpu_hart_o              (fpu_hart_id_ex),
      .is_zcmt_o               (zcmt_id_ex),
      .is_compressed_instr_o   (is_compressed_instr_id_ex),
      .tinst_o                 (tinst_ex),
      // fixed latency unit ready
      .flu_ready_i             (flu_ready_ex_id),
      .csr_ready_i             (csr_ready_ex_id),
      // ALU
      .alu_valid_o             (alu_valid_id_ex),
      .aes_valid_o             (aes_valid_id_ex),
      // Branches and Jumps
      .branch_valid_o          (branch_valid_id_ex),            // branch is valid
      .branch_predict_o        (branch_predict_id_ex),          // branch predict to ex
      .resolve_branch_i        (resolve_branch_ex_id),          // in order to resolve the branch
      // LSU
      .lsu_ready_i             (lsu_ready_ex_id),
      .lsu_valid_o             (lsu_valid_id_ex),
      // Multiplier
      .mult_valid_o            (mult_valid_id_ex),
      // FPU
      .fpu_ready_i             (fpu_ready_ex_id),
      .fpu_valid_o             (fpu_valid_id_ex),
      .fpu_fmt_o               (fpu_fmt_id_ex),
      .fpu_rm_o                (fpu_rm_id_ex),
      .fpu_early_valid_i       (fpu_early_valid_ex_id),
      // ALU2
      .alu2_valid_o            (alu2_valid_id_ex),
      // CSR
      .csr_valid_o             (csr_valid_id_ex),
      // CVXIF
      .xfu_valid_o             (x_issue_valid_id_ex),
      .xfu_ready_i             (x_issue_ready_ex_id),
      .x_off_instr_o           (x_off_instr_id_ex),
      .hart_id_i               (hart_id_i),
      .x_issue_ready_i         (x_issue_ready),
      .x_issue_resp_i          (x_issue_resp),
      .x_issue_valid_o         (x_issue_valid),
      .x_issue_req_o           (x_issue_req),
      .x_register_ready_i      (x_register_ready),
      .x_register_valid_o      (x_register_valid),
      .x_register_o            (x_register),
      .x_commit_valid_o        (x_commit_valid),
      .x_commit_o              (x_commit),
      .x_transaction_rejected_o(x_transaction_rejected),
      // Accelerator
      .issue_instr_o           (issue_instr_id_acc),
      .issue_instr_hs_o        (issue_instr_hs_id_acc),
      // Commit
      .trans_id_i              (trans_id_ex_id),
      .resolved_branch_i       (resolved_branch),
      .wbdata_i                (wbdata_ex_id),
      .ex_ex_i                 (ex_ex_ex_id),
      .wt_valid_i              (wt_valid_ex_id),
      .x_we_i                  (x_we_ex_id),
      .x_rd_i                  (x_rd_ex_id),

      .waddr_i              (waddr_commit_id),
      .wdata_i              (wdata_commit_id),
      .we_gpr_i             (we_gpr_commit_id),
      .whart_i              (whart_commit_id),
      .we_fpr_i             (we_fpr_commit_id),
      .commit_instr_o       (commit_instr_id_commit),
      .commit_drop_o        (commit_drop_id_commit),
      .commit_replay_o      (commit_replay_id_commit),
      .commit_ack_i         (commit_ack_commit_id),
      // Performance Counters
      .stall_issue_o        (stall_issue),
      .ooo_rename_stall_o   (ooo_rename_stall),
      .ooo_iq_full_o        (ooo_iq_full),
      .ooo_rob_full_o       (ooo_rob_full),
      .ooo_lsq_stall_o      (ooo_lsq_stall),
      .ooo_stl_forward_o    (ooo_stl_forward),
      .ooo_drained_o        (ooo_drained_id),
      .ooo_phys_replay_o    (ooo_phys_replay),
      //RVFI
      .rvfi_issue_pointer_o (rvfi_issue_pointer),
      .rvfi_commit_pointer_o(rvfi_commit_pointer),
      .reclaim_ptr_o         (sb_reclaim),
      .head_phys_pending_o   (ooo_head_phys_pending),
      .rvfi_rs1_o           (rvfi_rs1),
      .rvfi_rs2_o           (rvfi_rs2),
      .rvfi_operand_valid_o (rvfi_operand_valid),
      .rvfi_operand_tid_o   (rvfi_operand_tid),
      .orig_instr_aes_bits  (orig_instr_aes)
  );

  // I8: the front end sees exactly the resolved branch. G1gq forged a second
  // "mispredict" here from a commit-time register-file peek, so the front end and
  // the scoreboard disagreed about what resolved. Reverted — redirect sources are
  // enumerated in architecture/core-fetch/SPEC.md §5.
`ifdef G6LC_FETCH_B
  assign resolved_branch_fe = resolved_branch;
`else
  // A/oracle keeps G1gq: late JALR redirect after commit. EX resolved_branch
  // still feeds issue/SB; only the front end and controller see the salvage
  // target. Restored verbatim from 3745cfb06^ so the oracle stays faithful.
  always_comb begin
    resolved_branch_fe = resolved_branch;
    if (g1gq_redir) begin
      resolved_branch_fe.valid          = 1'b1;
      resolved_branch_fe.is_mispredict  = 1'b1;
      resolved_branch_fe.is_taken       = 1'b1;
      resolved_branch_fe.cf_type        = ariane_pkg::JumpR;
      resolved_branch_fe.target_address = g1gq_tgt;
    end
  end
`endif

  // ---------
  // EX
  // ---------
  ex_stage #(
      .CVA6Cfg   (CVA6Cfg),
      .bp_resolve_t(bp_resolve_t),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .fu_data_t(fu_data_t),
      .icache_areq_t(icache_areq_t),
      .icache_arsp_t(icache_arsp_t),
      .icache_dreq_t(icache_dreq_t),
      .icache_drsp_t(icache_drsp_t),
      .lsu_ctrl_t(lsu_ctrl_t),
      .x_result_t(x_result_t),
      .acc_mmu_req_t(acc_mmu_req_t),
      .acc_mmu_resp_t(acc_mmu_resp_t),
      .cbo_t(cbo_t)
  ) ex_stage_i (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .phys_valid_o(mem_phys_valid), .phys_addr_o(mem_phys_addr), .phys_id_o(mem_phys_id),
      .phys_hart_o(mem_phys_hart), .phys_size_o(mem_phys_size),
      .debug_mode_i(debug_mode),
      .flush_i(flush_ctrl_ex),
      .cancelled_mask_i(sb_cancelled_mask),
      .sb_live_i(sb_live_mask),
      .rs1_forwarding_i(rs1_forwarding_id_ex),
      .rs2_forwarding_i(rs2_forwarding_id_ex),
      .fu_data_i(fu_data_id_ex),
      .alu_bypass_i(alu_bypass_id_ex),
      .pc_i(pc_id_ex),
      .branch_hart_i(branch_hart_id_ex),
      .is_zcmt_i(zcmt_id_ex),
      .is_compressed_instr_i(is_compressed_instr_id_ex),
      .tinst_i(tinst_ex),
      // fixed latency units
      .flu_result_o(flu_result_ex_id),
      .flu_trans_id_o(flu_trans_id_ex_id),
      .flu_valid_o(flu_valid_ex_id),
      .flu_exception_o(flu_exception_ex_id),
      .flu_ready_o(flu_ready_ex_id),
      .csr_ready_o(csr_ready_ex_id),
      // ALU
      .alu_valid_i(alu_valid_id_ex),
      .orig_instr_aes_i(orig_instr_aes),
      .aes_valid_i(aes_valid_id_ex),
      // Branches and Jumps
      .branch_valid_i(branch_valid_id_ex),
      .branch_predict_i(branch_predict_id_ex),  // branch predict to ex
      .resolved_branch_o(resolved_branch),
      .resolve_branch_o(resolve_branch_ex_id),
      // CSR
      .csr_valid_i(csr_valid_id_ex),
      .csr_addr_o(csr_addr_ex_csr),
      .csr_commit_i(csr_commit_commit_ex),  // from commit
      .csr_hs_ld_st_inst_o(csr_hs_ld_st_inst_ex),  // signals a Hypervisor Load/Store Instruction
      // MULT
      .mult_valid_i(mult_valid_id_ex),
      // LSU
      .lsu_ready_o(lsu_ready_ex_id),
      .lsu_valid_i(lsu_valid_id_ex),

      .load_result_o   (load_result_ex_id),
      .load_trans_id_o (load_trans_id_ex_id),
      .load_valid_o    (load_valid_ex_id),
      .load_exception_o(load_exception_ex_id),

      .store_result_o   (store_result_ex_id),
      .store_trans_id_o (store_trans_id_ex_id),
      .store_valid_o    (store_valid_ex_id),
      .store_exception_o(store_exception_ex_id),

      .lsu_commit_i            (lsu_commit_commit_ex),           // from commit
      .lsu_commit_ready_o      (lsu_commit_ready_ex_commit),     // to commit
      .commit_tran_id_i        (lsu_commit_trans_id),            // from commit
      .oldest_live_tid_i       (sb_reclaim),
      .head_phys_pending_i     (ooo_head_phys_pending),
      .stall_st_pending_i      (stall_st_pending_ex),
      .shared_tlb_flush_busy_o (shared_tlb_flush_busy_ex),
      .no_st_pending_o         (no_st_pending_ex),
      // FPU
      .fpu_ready_o             (fpu_ready_ex_id),
      .fpu_valid_i             (fpu_valid_id_ex),
      .fpu_fmt_i               (fpu_fmt_id_ex),
      .fpu_rm_i                (fpu_rm_id_ex),
      .fpu_frm_i               (frm_csr_id_issue_ex),
      .fpu_prec_i              (fprec_csr_ex),
      .fpu_hart_i              (fpu_hart_id_ex),
      .fpu_frm_b_i             (frm_b),
      .fpu_prec_b_i            (fprec_b),
      .fpu_trans_id_o          (fpu_trans_id_ex_id),
      .fpu_result_o            (fpu_result_ex_id),
      .fpu_valid_o             (fpu_valid_ex_id),
      .fpu_exception_o         (fpu_exception_ex_id),
      .fpu_early_valid_o       (fpu_early_valid_ex_id),
      // ALU2
      .alu2_valid_i            (alu2_valid_id_ex),
      .amo_valid_commit_i      (amo_valid_commit),
      .amo_req_o               (amo_req),
      .amo_resp_i              (amo_resp),
      // CoreV-X-Interface
      .x_valid_i               (x_issue_valid_id_ex),
      .x_ready_o               (x_issue_ready_ex_id),
      .x_off_instr_i           (x_off_instr_id_ex),
      .x_transaction_rejected_i(x_transaction_rejected),
      .x_trans_id_o            (x_trans_id_ex_id),
      .x_exception_o           (x_exception_ex_id),
      .x_result_o              (x_result_ex_id),
      .x_valid_o               (x_valid_ex_id),
      .x_we_o                  (x_we_ex_id),
      .x_rd_o                  (x_rd_ex_id),
      .x_result_valid_i        (x_result_valid),
      .x_result_i              (x_result),
      .x_result_ready_o        (x_result_ready),
      // Accelerator
      .acc_valid_i             (acc_valid_acc_ex),
      // Accelerator MMU access
      .acc_mmu_req_i           (acc_mmu_req),
      .acc_mmu_resp_o          (acc_mmu_resp),
      // Performance counters
      .itlb_miss_o             (itlb_miss_ex_perf),
      .dtlb_miss_o             (dtlb_miss_ex_perf),
      // Memory Management
      .enable_translation_i    (enable_translation_csr_ex),      // from CSR
      .enable_g_translation_i  (enable_g_translation_csr_ex),    // from CSR
      .en_ld_st_translation_i  (en_ld_st_translation_csr_ex),
      .en_ld_st_g_translation_i(en_ld_st_g_translation_csr_ex),
      .flush_tlb_i             (flush_tlb_ctrl_ex),
      .flush_tlb_vvma_i        (flush_tlb_vvma_ctrl_ex),
      .flush_tlb_gvma_i        (flush_tlb_gvma_ctrl_ex),
      .priv_lvl_i              (priv_lvl),                       // from CSR
      .mbe_i                   (mbe),                            // from CSR
      .v_i                     (v),                              // from CSR
      .ld_st_priv_lvl_i        (ld_st_priv_lvl_csr_ex),          // from CSR
      .ld_st_v_i               (ld_st_v_csr_ex),                 // from CSR
      .sum_i                   (sum_csr_ex),                     // from CSR
      .vs_sum_i                (vs_sum_csr_ex),                  // from CSR
      .mxr_i                   (mxr_csr_ex),                     // from CSR
      .vmxr_i                  (vmxr_csr_ex),                    // from CSR
      .satp_ppn_i              (satp_ppn_csr_ex),                // from CSR
      .asid_i                  (asid_csr_ex),                    // from CSR
      .vsatp_ppn_i             (vsatp_ppn_csr_ex),               // from CSR
      .vs_asid_i               (vs_asid_csr_ex),                 // from CSR
      .hgatp_ppn_i             (hgatp_ppn_csr_ex),               // from CSR
      .vmid_i                  (vmid_csr_ex),                    // from CSR
      .icache_areq_i           (icache_areq_cache_ex),
      .icache_areq_o           (icache_areq_ex_cache),
      // DCACHE interfaces
      .dcache_req_ports_i      (dcache_req_ports_cache_ex),
      .dcache_req_ports_o      (dcache_req_ports_ex_cache),
      .dcache_wbuffer_empty_i  (dcache_commit_wbuffer_empty),
      .dcache_wbuffer_not_ni_i (dcache_commit_wbuffer_not_ni),
      // PMP (LSU check-stage hart's set; == request hart's when the LSU holds
      // a walk, and == the active hart's under drained/single-hart configs)
      .pmpcfg_i                (pmpcfg),
      .pmpaddr_i               (pmpaddr),
      // T6b-2b: fetch-hart identity/context for the instruction-side
      // TLB/PTW/PMP paths; lsu_hart_o reports the translation request owner.
      .fetch_hart_i            (smt_active_hart),
      .lsu_hart_o              (lsu_hart),
      .lsu_chk_hart_o          (lsu_chk_hart),
      .fet_asid_i              (fet_asid_csr_ex),
      .fet_vs_asid_i           (fet_vs_asid_csr_ex),
      .fet_vmid_i              (fet_vmid_csr_ex),
      .fet_satp_ppn_i          (fet_satp_ppn_csr_ex),
      .fet_vsatp_ppn_i         (fet_vsatp_ppn_csr_ex),
      .fet_hgatp_ppn_i         (fet_hgatp_ppn_csr_ex),
      .fet_mxr_i               (fet_mxr_csr_ex),
      .fet_vmxr_i              (fet_vmxr_csr_ex),
      .fet_mbe_i               (fet_mbe_csr_ex),
      .fet_pmpcfg_i            (fet_pmpcfg),
      .fet_pmpaddr_i           (fet_pmpaddr),
      //RVFI
      .rvfi_lsu_ctrl_o         (rvfi_lsu_ctrl),
      .rvfi_mem_paddr_o        (rvfi_mem_paddr)
  );

  // ---------
  // Commit
  // ---------

  // we have to make sure that the whole write buffer path is empty before
  // used e.g. for fence instructions.
  assign no_st_pending_commit = no_st_pending_ex & dcache_commit_wbuffer_empty;

  commit_stage #(
      .CVA6Cfg(CVA6Cfg),
      .exception_t(exception_t),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) commit_stage_i (
      .clk_i,
      .rst_ni,
      .halt_i                 (halt_ctrl),
      .flush_dcache_i         (dcache_flush_ctrl_cache),
      .flush_i                (flush_ctrl_id),
      .exception_o            (ex_commit),
      .dirty_fp_state_o       (dirty_fp_state),
      .single_step_i          (single_step_csr_commit || single_step_acc_commit),
      .step_hart_i            (smt_step_b),
      .commit_instr_i         (commit_instr_id_commit),
      .commit_drop_i          (commit_drop_id_commit),
      .commit_replay_i        (commit_replay_id_commit),
      .commit_ack_o           (commit_ack_commit_id),
      .commit_macro_ack_o     (commit_macro_ack),
      .waddr_o                (waddr_commit_id),
      .wdata_o                (wdata_commit_id),
      .we_gpr_o               (we_gpr_commit_id),
      .whart_o                (whart_commit_id),
      .we_fpr_o               (we_fpr_commit_id),
      .amo_resp_i             (amo_resp),
      .pc_o                   (pc_commit),
      .csr_op_o               (csr_op_commit_csr),
      .csr_wdata_o            (csr_wdata_commit_csr),
      .csr_rdata_i            (csr_rdata_csr_commit),
      .csr_write_fflags_o     (csr_write_fflags_commit_cs),
      .csr_exception_i        (csr_exception_csr_commit),
      .commit_lsu_o           (lsu_commit_commit_ex),
      .commit_lsu_ready_i     (lsu_commit_ready_ex_commit),
      .commit_tran_id_o       (lsu_commit_trans_id),
      .amo_valid_commit_o     (amo_valid_commit),
      .no_st_pending_i        (no_st_pending_commit),
      .shared_tlb_flush_busy_i(shared_tlb_flush_busy_ex),
      .commit_csr_o           (csr_commit_commit_ex),
      .fence_i_o              (fence_i_commit_controller),
      .fence_o                (fence_commit_controller),
      .flush_commit_o         (flush_commit),
      .replay_o               (replay_commit_controller),
      .sfence_vma_o           (sfence_vma_commit_controller),
      .hfence_vvma_o          (hfence_vvma_commit_controller),
      .hfence_gvma_o          (hfence_gvma_commit_controller),
      .break_from_trigger_i   (break_from_trigger)
  );

  assign commit_ack = commit_macro_ack & ~commit_drop_id_commit;

  // T6b-4b: each port's committing hart for banked ack routing.
  for (genvar cmt_h = 0; cmt_h < CVA6Cfg.NrCommitPorts; cmt_h++) begin : gen_commit_hart
    assign commit_hart[cmt_h] = commit_instr_id_commit[cmt_h].hart_id;
  end

  // ---------
  // CSR (U6.1: banked via cva6_smt_csr_bank when NrHarts>1)
  // ---------
  g6lc_smt_csr_bank #(
      .CVA6Cfg           (CVA6Cfg),
      .exception_t       (exception_t),
      .jvt_t             (jvt_t),
      .irq_ctrl_t        (irq_ctrl_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .rvfi_probes_csr_t (rvfi_probes_csr_t),
      .MHPMCounterNum    (MHPMCounterNum)
  ) csr_regfile_i (
      .clk_i,
      .rst_ni,
      .active_hart_i           (smt_active_hart),
      .lsu_hart_i              (lsu_ctx_hart),
      .lsu_chk_hart_i          (lsu_chk_ctx_hart),
      .switch_i                (smt_switch),
      .time_irq_i,
      .rtc_time_i,
      .flush_o                 (flush_csr_ctrl),
      .halt_csr_o              (halt_csr_ctrl),
      .hart_halt_o             (smt_csr_hart_halt),
      .commit_instr_i          (commit_instr_id_commit[0]),
      .commit_ack_i            (commit_ack),
      .commit_hart_i           (commit_hart),
      .boot_addr_i             (boot_addr_i[CVA6Cfg.VLEN-1:0]),
      .hart_id_base_i          (hart_id_i[CVA6Cfg.XLEN-1:0]),
      .ex_i                    (ex_commit),
      .csr_op_i                (csr_op_commit_csr),
      .csr_addr_i              (csr_addr_ex_csr),
      .csr_wdata_i             (csr_wdata_commit_csr),
      .csr_rdata_o             (csr_rdata_csr_commit),
      .dirty_fp_state_i        (dirty_fp_state),
      .csr_write_fflags_i      (csr_write_fflags_commit_cs),
      .dirty_v_state_i         (dirty_v_state),
      .pc_i                    (pc_commit),
      .csr_exception_o         (csr_exception_csr_commit),
      .epc_o                   (epc_commit_pcgen),
      .eret_o                  (eret),
      .trap_vector_base_o      (trap_vector_base_commit_pcgen),
      .priv_lvl_o              (priv_lvl),
      .mbe_o                   (mbe),
      .v_o                     (v),
      .acc_fflags_ex_i         (acc_resp_fflags),
      .acc_fflags_ex_valid_i   (acc_resp_fflags_valid),
      .fs_o                    (fs),
      .vfs_o                   (vfs),
      .fflags_o                (fflags_csr_commit),
      .frm_o                   (frm_csr_id_issue_ex),
      .fprec_o                 (fprec_csr_ex),
      .vs_o                    (vs),
      .irq_ctrl_o              (irq_ctrl_csr_id),
      .irq_ctrl_b_o            (irq_ctrl_b),
      .priv_lvl_b_o            (priv_lvl_b),
      .v_b_o                   (v_b),
      .v_commit_o              (v_commit_csr),
      // T6b-3a: per-bank decode context + per-bank count-inhibit for the PMU.
      .tvm_b_o                 (tvm_b),
      .tw_b_o                  (tw_b),
      .vtw_b_o                 (vtw_b),
      .tsr_b_o                 (tsr_b),
      .hu_b_o                  (hu_b),
      .debug_mode_b_o          (debug_mode_b),
      .fs_b_o                  (fs_b),
      .vfs_b_o                 (vfs_b),
      .vs_b_o                  (vs_b),
      .frm_b_o                 (frm_b),
      .fprec_b_o               (fprec_b),
      .mcbie_b_o               (mcbie_b),
      .scbie_b_o               (scbie_b),
      .hcbie_b_o               (hcbie_b),
      .mcbcfe_b_o              (mcbcfe_b),
      .scbcfe_b_o              (scbcfe_b),
      .hcbcfe_b_o              (hcbcfe_b),
      .mcbze_b_o               (mcbze_b),
      .scbze_b_o               (scbze_b),
      .hcbze_b_o               (hcbze_b),
      .jvt_b_o                 (jvt_b),
      .mcountinhibit_b_o       (mcountinhibit_b),
      .en_translation_o        (enable_translation_csr_ex),
      .en_g_translation_o      (enable_g_translation_csr_ex),
      .en_ld_st_translation_o  (en_ld_st_translation_csr_ex),
      .en_ld_st_g_translation_o(en_ld_st_g_translation_csr_ex),
      .ld_st_priv_lvl_o        (ld_st_priv_lvl_csr_ex),
      .ld_st_v_o               (ld_st_v_csr_ex),
      .csr_hs_ld_st_inst_i     (csr_hs_ld_st_inst_ex),
      .sum_o                   (sum_csr_ex),
      .vs_sum_o                (vs_sum_csr_ex),
      .mxr_o                   (mxr_csr_ex),
      .vmxr_o                  (vmxr_csr_ex),
      .satp_ppn_o              (satp_ppn_csr_ex),
      .asid_o                  (asid_csr_ex),
      .vsatp_ppn_o             (vsatp_ppn_csr_ex),
      .vs_asid_o               (vs_asid_csr_ex),
      .hgatp_ppn_o             (hgatp_ppn_csr_ex),
      .vmid_o                  (vmid_csr_ex),
      .fet_satp_ppn_o          (fet_satp_ppn_csr_ex),
      .fet_asid_o              (fet_asid_csr_ex),
      .fet_vsatp_ppn_o         (fet_vsatp_ppn_csr_ex),
      .fet_vs_asid_o           (fet_vs_asid_csr_ex),
      .fet_hgatp_ppn_o         (fet_hgatp_ppn_csr_ex),
      .fet_vmid_o              (fet_vmid_csr_ex),
      .fet_mxr_o               (fet_mxr_csr_ex),
      .fet_vmxr_o              (fet_vmxr_csr_ex),
      .fet_mbe_o               (fet_mbe_csr_ex),
      .mbe_commit_o            (mbe_commit_csr),
      .irq_i,
      .ipi_i,
      .debug_req_i,
      .set_debug_pc_o          (set_debug_pc),
      .tvm_o                   (tvm_csr_id),
      .tw_o                    (tw_csr_id),
      .vtw_o                   (vtw_csr_id),
      .tsr_o                   (tsr_csr_id),
      .hu_o                    (hu),
      .debug_mode_o            (debug_mode),
      .single_step_o           (single_step_csr_commit),
      .step_b_o                (smt_step_b),
      .icache_en_o             (icache_en_csr),
      .dcache_en_o             (dcache_en_csr_nbdcache),
      .acc_cons_en_o           (acc_cons_en_csr),
      .ai_aicfg_o              (ai_aicfg_o),
      .ai_ais_o                (ai_ais_o),
      .ai_issue_ok_o           (ai_issue_ok_o),
      .ai_q_en_o               (ai_q_en_o),
      .ai_qid_o                (ai_qid_o),
      .dirty_ai_state_i        (dirty_ai_state_i),
      .ai_setcfg_we_i          (ai_setcfg_we_i),
      .ai_setcfg_wdata_i       (ai_setcfg_wdata_i),
      .perf_addr_o             (addr_csr_perf),
      .perf_data_o             (data_csr_perf),
      .perf_data_i             (data_perf_csr),
      .perf_we_o               (we_csr_perf),
      .scountovf_i             (scountovf_perf_csr),
      .lcofi_i                 (lcofi_perf_csr),
      .pmpcfg_o                (pmpcfg),
      .pmpaddr_o               (pmpaddr),
      .fet_pmpcfg_o            (fet_pmpcfg),
      .fet_pmpaddr_o           (fet_pmpaddr),
      .mcountinhibit_o         (mcountinhibit_csr_perf),
      .mcbie_o                 (mcbie),
      .scbie_o                 (scbie),
      .hcbie_o                 (hcbie),
      .mcbcfe_o                (mcbcfe),
      .scbcfe_o                (scbcfe),
      .hcbcfe_o                (hcbcfe),
      .mcbze_o                 (mcbze),
      .scbze_o                 (scbze),
      .hcbze_o                 (hcbze),
      .pbmte_o                 (pbmte),
      .jvt_o                   (jvt),
      //RVFI
      .rvfi_csr_o              (rvfi_csr),
      // Trigger Signals
      .debug_from_trigger_o    (debug_from_trigger),
      .vaddr_from_lsu_i        (rvfi_lsu_ctrl.vaddr),
      .orig_instr_i            (orig_instr_id_issue),
      .store_result_i          (store_result_ex_id),
      .break_from_trigger_o    (break_from_trigger)
  );

  // ------------------------
  // Performance Counters
  // ------------------------
  if (CVA6Cfg.PerfCounterEn) begin : gen_perf_counter
    perf_counters #(
        .CVA6Cfg(CVA6Cfg),
        .bp_resolve_t(bp_resolve_t),
        .exception_t(exception_t),
        .scoreboard_entry_t(scoreboard_entry_t),
        .icache_dreq_t(icache_dreq_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .NumPorts(NumPorts)
    ) perf_counters_i (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .debug_mode_i  (debug_mode),
        .priv_lvl_b_i  (priv_lvl_b),
        .addr_i        (addr_csr_perf),
        .we_i          (we_csr_perf),
        .data_i        (data_csr_perf),
        .data_o        (data_perf_csr),
        .hart_i        (smt_active_hart),
        // T6b-3a: the HPM CSR access belongs to the committing op's hart —
        // the same hart that selects the bank's perf_* sideband.
        .csr_hart_i    (commit_instr_id_commit[0].hart_id),
        .scountovf_o   (scountovf_perf_csr),
        .lcofi_o       (lcofi_perf_csr),
        .commit_instr_i(commit_instr_id_commit),
        .commit_ack_i  (commit_ack),

        .l1_icache_miss_i   (icache_miss_cache_perf),
        .l1_dcache_miss_i   (dcache_miss_cache_perf),
        .itlb_miss_i        (itlb_miss_ex_perf),
        .dtlb_miss_i        (dtlb_miss_ex_perf),
        .sb_full_i          (sb_full),
        .ooo_rename_stall_i (ooo_rename_stall),
        .ooo_iq_full_i      (ooo_iq_full),
        .ooo_rob_full_i     (ooo_rob_full),
        .ooo_lsq_stall_i    (ooo_lsq_stall),
        .ooo_stl_forward_i  (ooo_stl_forward),
        .ooo_phys_replay_i  (ooo_phys_replay),
        .coh_inval_apply_i  (inval_apply_valid),
        .l2_miss_i          (l2_miss_i),
        .l3_hit_i           (l3_hit_i),
        .l3_miss_i          (l3_miss_i),
        .pf_issue_i         (pf_issue_i),
        .pf_train_i         (pf_train_i),
        .l2_pwhold_i        (l2_pwhold_i),
        .l3_pwhold_i        (l3_pwhold_i),
        .l2_pf_issue_i      (l2_pf_issue_i),
        .l2_pf_useful_i     (l2_pf_useful_i),
        .spec_cancel_i      (spec_cancel),
        .smt_drain_force_i  (smt_drain_force),
        .smt_drain_force_wfi_i (smt_drain_force_wfi),
        .smt_drain_force_abs_i (smt_drain_force_abs),
        .ai_pmu_op_i        (ai_pmu_op_i),
        .ai_pmu_mma_i       (ai_pmu_mma_i),
        .ai_pmu_post_i      (ai_pmu_post_i),
        .ai_pmu_t0_i        (ai_pmu_t0_i),
        .ai_pmu_busy_i      (ai_pmu_busy_i),
        .dcache_wbuf_void_ack_i    (dcache_pm_void_ack),
        .dcache_wbuf_fixup_write_i (dcache_pm_fixup_write),
        .dcache_wbuf_fixup_inval_i (dcache_pm_fixup_inval),
        .dcache_wbuf_fixup_full_i  (dcache_pm_fixup_full),
        // TODO this is more complex that that
        // If superscalar then we additionally have to check [1] when transaction 0 succeeded
        .if_empty_i         (~fetch_valid_if_id[0]),
        .ex_i               (ex_commit),
        .eret_i             (eret),
        .resolved_branch_i  (resolved_branch),
        .branch_exceptions_i(flu_exception_ex_id),
        .l1_icache_access_i (icache_dreq_if_cache),
        .l1_dcache_access_i (dcache_req_ports_ex_cache),
        .miss_vld_bits_i    (miss_vld_bits),
        .i_tlb_flush_i      (flush_tlb_ctrl_ex),
        .stall_issue_i      (stall_issue),
        .mcountinhibit_b_i  (mcountinhibit_b)
    );
  end : gen_perf_counter
  else begin : gen_no_perf_counter
    assign data_perf_csr = '0;
    assign scountovf_perf_csr = '0;
    assign lcofi_perf_csr = '0;
  end : gen_no_perf_counter

  // ------------
  // Controller
  // ------------
  always_comb begin
    resolved_branch_ctrl = resolved_branch_fe;
`ifdef G6LC_FETCH_B
    // T19 (defect 1): the active-hart qualifier is a MIXED-residency device —
    // only there can a peer hart resolve a branch while another hart owns the
    // fetch stream. Under the drained handoff every in-flight instruction
    // belongs to the resident hart, so the qualifier can only ever DROP a
    // legitimate kill: the scoreboard then still cancels the branch's younger
    // entries (hart-matched) while the IQ/ID keep the wrong path and the
    // frontend is never redirected — exactly the retired-wrong-path-window
    // signature of the ooocoh-t18 boot (harts 3/7). Keep the filter for mixed
    // residency only; the witness below reports any drained-mode mismatch.
    if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff)
      resolved_branch_ctrl.is_mispredict = g6lc_fetch_pkg::redirect_for_hart(
          1'b1, resolved_branch_fe.valid && resolved_branch_fe.is_mispredict,
          8'(resolved_branch_fe.hart_id), 8'(smt_active_hart));
`endif
  end
//pragma translate_off
`ifdef G6LC_FETCH_B
  // T19 witness: a drained-handoff mispredict whose hart is not the active
  // hart (should be unreachable; the pre-T19 filter silently dropped it).
  always @(posedge clk_i) begin
    if (rst_ni && CVA6Cfg.NrHarts > 1 && CVA6Cfg.SmtDrainedHandoff &&
        resolved_branch_fe.valid && resolved_branch_fe.is_mispredict &&
        resolved_branch_fe.hart_id != smt_active_hart)
      $display("[misp-hart] t=%0t drained mispredict hart=%0d active=%0d pc=%h tgt=%h",
               $time, resolved_branch_fe.hart_id, smt_active_hart,
               resolved_branch_fe.pc, resolved_branch_fe.target_address);
  end
`endif
//pragma translate_on

  controller #(
      .CVA6Cfg(CVA6Cfg),
      .bp_resolve_t(bp_resolve_t)
  ) controller_i (
      .clk_i,
      .rst_ni,
      // virtualization mode of the committing instruction's hart (T6b-2b;
      // identical to the active hart under drained handoff)
      .v_i                   (v_commit_csr),
      // flush ports
      .set_pc_commit_o       (set_pc_ctrl_pcgen),
      .flush_if_o            (flush_ctrl_if),
      .flush_unissued_instr_o(flush_unissued_instr_ctrl_id),
      .flush_id_o            (flush_ctrl_id),
      .flush_ex_o            (flush_ctrl_ex),
      .flush_bp_o            (flush_ctrl_bp),
      .flush_icache_o        (icache_flush_ctrl_cache),
      .flush_dcache_o        (dcache_flush_ctrl_cache),
      .flush_dcache_ack_i    (dcache_flush_ack_cache_ctrl),
      .flush_tlb_o           (flush_tlb_ctrl_ex),
      .flush_tlb_vvma_o      (flush_tlb_vvma_ctrl_ex),
      .flush_tlb_gvma_o      (flush_tlb_gvma_ctrl_ex),
      .halt_csr_i            (halt_csr_ctrl),
      .halt_acc_i            (halt_acc_ctrl),
      .halt_frontend_o       (halt_frontend),
      .halt_o                (halt_ctrl),
      .smt_switch_i          (smt_switch),
      .drain_force_i         (smt_drain_force),
      // control ports
      .eret_i                (eret),
      .ex_valid_i            (ex_commit.valid),
      .set_debug_pc_i        (set_debug_pc),
      .resolved_branch_i     (resolved_branch_ctrl),
      .flush_csr_i           (flush_csr_ctrl),
      .fence_i_i             (fence_i_commit_controller),
      .fence_i               (fence_commit_controller),
      .sfence_vma_i          (sfence_vma_commit_controller),
      .hfence_vvma_i         (hfence_vvma_commit_controller),
      .hfence_gvma_i         (hfence_gvma_commit_controller),
      .flush_commit_i        (flush_commit),
      .replay_i              (replay_commit_controller),
      .mem_replay_pc_o       (mem_replay_pc_ctrl_pcgen),
      .flush_acc_i           (flush_acc)
  );

  // -------------------
  // Cache Subsystem
  // -------------------

  // Acc dispatcher and store buffer share a dcache request port.
  // Store buffer always has priority access over acc dispatcher.
  dcache_req_i_t [NumPorts-1:0] dcache_req_to_cache;
  dcache_req_o_t [NumPorts-1:0] dcache_req_from_cache;

  // D$ request
  // Since ZCMT is only enabled for embedded class so MMU should be disabled.
  // Cache port 0 is being utilized in implicit read access in ZCMT extension.
  if (CVA6Cfg.RVZCMT & ~(CVA6Cfg.MmuPresent)) begin
    assign dcache_req_to_cache[0] = dcache_req_ports_id_cache;
  end else begin
    assign dcache_req_to_cache[0] = dcache_req_ports_ex_cache[0];
  end
  assign dcache_req_to_cache[1] = dcache_req_ports_ex_cache[1];
  assign dcache_req_to_cache[2] = dcache_req_ports_acc_cache[0];
  assign dcache_req_to_cache[3] = dcache_req_ports_ex_cache[2].data_req ? dcache_req_ports_ex_cache [2] :
                                                                          dcache_req_ports_acc_cache[1];

  // D$ response
  // Since ZCMT is only enabled for embedded class so MMU should be disabled.
  // Cache port 0 is being utilized in implicit read access in ZCMT extension.
  if (CVA6Cfg.RVZCMT & ~(CVA6Cfg.MmuPresent)) begin
    assign dcache_req_ports_cache_id = dcache_req_from_cache[0];
    assign dcache_req_ports_cache_ex[0] = '0;
  end else begin
    assign dcache_req_ports_cache_ex[0] = dcache_req_from_cache[0];
    assign dcache_req_ports_cache_id = '0;
  end
  assign dcache_req_ports_cache_ex[1]  = dcache_req_from_cache[1];
  assign dcache_req_ports_cache_acc[0] = dcache_req_from_cache[2];
  always_comb begin : gen_dcache_req_store_data_gnt
    dcache_req_ports_cache_ex[2]  = dcache_req_from_cache[3];
    dcache_req_ports_cache_acc[1] = dcache_req_from_cache[3];

    // Set gnt signal
    dcache_req_ports_cache_ex[2].data_gnt &= dcache_req_ports_ex_cache[2].data_req;
    dcache_req_ports_cache_acc[1].data_gnt &= !dcache_req_ports_ex_cache[2].data_req;
  end

  if (CVA6Cfg.DCacheType == config_pkg::WT) begin : gen_cache_wt
    // this is a cache subsystem that is compatible with OpenPiton
    wt_cache_subsystem #(
        .CVA6Cfg   (CVA6Cfg),
        .icache_areq_t(icache_areq_t),
        .icache_arsp_t(icache_arsp_t),
        .icache_dreq_t(icache_dreq_t),
        .icache_drsp_t(icache_drsp_t),
        .icache_req_t(icache_req_t),
        .icache_rtrn_t(icache_rtrn_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .NumPorts  (NumPorts),
        .noc_req_t (noc_req_t),
        .noc_resp_t(noc_resp_t)
    ) i_cache_subsystem (
        // to D$
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .boot_addr_i       (boot_addr_i[CVA6Cfg.VLEN-1:0]),
        // I$
        .icache_en_i       (icache_en_csr),
        .icache_flush_i    (icache_flush_ctrl_cache),
        .icache_miss_o     (icache_miss_cache_perf),
        .icache_areq_i     (icache_areq_ex_cache),
        .icache_areq_o     (icache_areq_cache_ex),
        .icache_dreq_i     (icache_dreq_if_cache),
        .icache_dreq_o     (icache_dreq_cache_if),
        // D$
        .dcache_enable_i   (dcache_en_csr_nbdcache),
        .dcache_flush_i    (dcache_flush_ctrl_cache),
        .dcache_flush_ack_o(dcache_flush_ack_cache_ctrl),
        // to commit stage
        .dcache_amo_req_i  (amo_req),
        .dcache_amo_resp_o (amo_resp),
        // T6b-2b: the write-buffer/AMO drain path formats data with the
        // committing hart's endianness (identical under drained handoff).
        .mbe_i             (mbe_commit_csr),
        // from PTW, Load Unit  and Store Unit
        .dcache_miss_o     (dcache_miss_cache_perf),
        .miss_vld_bits_o   (miss_vld_bits),
        .dcache_req_ports_i(dcache_req_to_cache),
        .dcache_req_ports_o(dcache_req_from_cache),
        // write buffer status
        .wbuffer_empty_o   (dcache_commit_wbuffer_empty),
        .wbuffer_not_ni_o  (dcache_commit_wbuffer_not_ni),
        // SL-W PMU events
        .pm_void_ack_o     (dcache_pm_void_ack),
        .pm_fixup_write_o  (dcache_pm_fixup_write),
        .pm_fixup_inval_o  (dcache_pm_fixup_inval),
        .pm_fixup_full_o   (dcache_pm_fixup_full),
        // memory side
        .noc_req_o         (noc_req_o),
        .noc_resp_i        (noc_resp_i),
        .inval_addr_i      (inval_addr),
        .inval_valid_i     (inval_valid),
        .inval_ready_o     (inval_ready),
        .inval_apply_valid_o(inval_apply_valid), .inval_apply_addr_o(inval_apply_addr),
        // T9a eWT CMO sideband
        .cmo_valid_o       (cmo_req_valid),
        .cmo_op_o          (cmo_req_op),
        .cmo_addr_o        (cmo_req_addr),
        .cmo_ready_i       (cmo_req_ready),
        .cmo_done_i        (cmo_req_done)
    );
  end else if (
        CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT ||
        CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WB ||
        CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB
  )
  begin : gen_cache_hpd
    cva6_hpdcache_subsystem #(
        .CVA6Cfg   (CVA6Cfg),
        .icache_areq_t(icache_areq_t),
        .icache_arsp_t(icache_arsp_t),
        .icache_dreq_t(icache_dreq_t),
        .icache_drsp_t(icache_drsp_t),
        .icache_req_t(icache_req_t),
        .icache_rtrn_t(icache_rtrn_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .NumPorts  (NumPorts),
        .axi_ar_chan_t(axi_ar_chan_t),
        .axi_aw_chan_t(axi_aw_chan_t),
        .axi_w_chan_t (axi_w_chan_t),
        .axi_b_chan_t (b_chan_t),
        .axi_r_chan_t (r_chan_t),
        .noc_req_t (noc_req_t),
        .noc_resp_t(noc_resp_t)
    ) i_cache_subsystem (
        .clk_i (clk_i),
        .rst_ni(rst_ni),
        .boot_addr_i   (boot_addr_i[CVA6Cfg.VLEN-1:0]),

        .icache_en_i   (icache_en_csr),
        .icache_flush_i(icache_flush_ctrl_cache),
        .icache_miss_o (icache_miss_cache_perf),
        .icache_areq_i (icache_areq_ex_cache),
        .icache_areq_o (icache_areq_cache_ex),
        .icache_dreq_i (icache_dreq_if_cache),
        .icache_dreq_o (icache_dreq_cache_if),

        .dcache_enable_i   (dcache_en_csr_nbdcache),
        .dcache_flush_i    (dcache_flush_ctrl_cache),
        .dcache_flush_ack_o(dcache_flush_ack_cache_ctrl),
        .dcache_miss_o     (dcache_miss_cache_perf),

        .dcache_amo_req_i (amo_req),
        .dcache_amo_resp_o(amo_resp),

        .dcache_req_ports_i(dcache_req_to_cache),
        .dcache_req_ports_o(dcache_req_from_cache),

        .wbuffer_empty_o (dcache_commit_wbuffer_empty),
        .wbuffer_not_ni_o(dcache_commit_wbuffer_not_ni),

        .hwpf_base_set_i    ('0  /*FIXME*/),
        .hwpf_base_i        ('0  /*FIXME*/),
        .hwpf_base_o        (  /*FIXME*/),
        .hwpf_param_set_i   ('0  /*FIXME*/),
        .hwpf_param_i       ('0  /*FIXME*/),
        .hwpf_param_o       (  /*FIXME*/),
        .hwpf_throttle_set_i('0  /*FIXME*/),
        .hwpf_throttle_i    ('0  /*FIXME*/),
        .hwpf_throttle_o    (  /*FIXME*/),
        .hwpf_status_o      (  /*FIXME*/),

        .noc_req_o (noc_req_o),
        .noc_resp_i(noc_resp_i),
        // U6.2 external L1 inv from coherence hub
        .inval_addr_i (inval_addr),
        .inval_valid_i(inval_valid),
        .inval_ready_o(inval_ready),
        // T9a eWT CMO sideband (response hold lives in the adapter)
        .cmo_valid_o  (cmo_req_valid),
        .cmo_op_o     (cmo_req_op),
        .cmo_addr_o   (cmo_req_addr),
        .cmo_ready_i  (cmo_req_ready),
        .cmo_done_i   (cmo_req_done)
    );
    assign miss_vld_bits = '0;
    assign dcache_pm_void_ack    = 1'b0;
    assign dcache_pm_fixup_write = 1'b0;
    assign dcache_pm_fixup_inval = 1'b0;
    assign dcache_pm_fixup_full  = 1'b0;
  end else begin : gen_cache_wb
    std_cache_subsystem #(
        // note: this only works with one cacheable region
        // not as important since this cache subsystem is about to be
        // deprecated
        .CVA6Cfg       (CVA6Cfg),
        .icache_areq_t (icache_areq_t),
        .icache_arsp_t (icache_arsp_t),
        .icache_dreq_t (icache_dreq_t),
        .icache_drsp_t (icache_drsp_t),
        .icache_req_t  (icache_req_t),
        .icache_rtrn_t (icache_rtrn_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .NumPorts      (NumPorts),
        .axi_ar_chan_t (axi_ar_chan_t),
        .axi_aw_chan_t (axi_aw_chan_t),
        .axi_w_chan_t  (axi_w_chan_t),
        .axi_req_t     (noc_req_t),
        .axi_rsp_t     (noc_resp_t)
    ) i_cache_subsystem (
        // to D$
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .boot_addr_i       (boot_addr_i[CVA6Cfg.VLEN-1:0]),
        .priv_lvl_i        (priv_lvl),
        // I$
        .icache_en_i       (icache_en_csr),
        .icache_flush_i    (icache_flush_ctrl_cache),
        .icache_miss_o     (icache_miss_cache_perf),
        .icache_areq_i     (icache_areq_ex_cache),
        .icache_areq_o     (icache_areq_cache_ex),
        .icache_dreq_i     (icache_dreq_if_cache),
        .icache_dreq_o     (icache_dreq_cache_if),
        // D$
        .dcache_enable_i   (dcache_en_csr_nbdcache),
        .dcache_flush_i    (dcache_flush_ctrl_cache),
        .dcache_flush_ack_o(dcache_flush_ack_cache_ctrl),
        // to commit stage
        .amo_req_i         (amo_req),
        .amo_resp_o        (amo_resp),
        .dcache_miss_o     (dcache_miss_cache_perf),
        // this is statically set to 1 as the std_cache does not have a wbuffer
        .wbuffer_empty_o   (dcache_commit_wbuffer_empty),
        // from PTW, Load Unit  and Store Unit
        .dcache_req_ports_i(dcache_req_to_cache),
        .dcache_req_ports_o(dcache_req_from_cache),
        // memory side
        .axi_req_o         (noc_req_o),
        .axi_resp_i        (noc_resp_i)
    );
    assign dcache_commit_wbuffer_not_ni = 1'b1;
    assign inval_ready                  = 1'b1;
    assign cmo_req_valid                = 1'b0;
    assign cmo_req_op                   = '0;
    assign cmo_req_addr                 = '0;
    assign miss_vld_bits                = '0;
    assign dcache_pm_void_ack           = 1'b0;
    assign dcache_pm_fixup_write        = 1'b0;
    assign dcache_pm_fixup_inval        = 1'b0;
    assign dcache_pm_fixup_full         = 1'b0;
  end

  // ----------------
  // Accelerator
  // ----------------

  if (CVA6Cfg.EnableAccelerator) begin : gen_accelerator
    acc_dispatcher #(
        .CVA6Cfg           (CVA6Cfg),
        .fu_data_t         (fu_data_t),
        .dcache_req_i_t    (dcache_req_i_t),
        .dcache_req_o_t    (dcache_req_o_t),
        .exception_t       (exception_t),
        .scoreboard_entry_t(scoreboard_entry_t),
        .acc_cfg_t         (acc_cfg_t),
        .AccCfg            (AccCfg),
        .acc_req_t         (cvxif_req_t),
        .acc_resp_t        (cvxif_resp_t),
        .accelerator_req_t (accelerator_req_t),
        .accelerator_resp_t(accelerator_resp_t),
        .acc_mmu_req_t     (acc_mmu_req_t),
        .acc_mmu_resp_t    (acc_mmu_resp_t)
    ) i_acc_dispatcher (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .flush_unissued_instr_i(flush_unissued_instr_ctrl_id),
        .flush_ex_i            (flush_ctrl_ex),
        .flush_pipeline_o      (flush_acc),
        .single_step_o         (single_step_acc_commit),
        .acc_cons_en_i         (acc_cons_en_csr),
        .acc_fflags_valid_o    (acc_resp_fflags_valid),
        .acc_fflags_o          (acc_resp_fflags),
        .ld_st_priv_lvl_i      (ld_st_priv_lvl_csr_ex),
        .sum_i                 (sum_csr_ex),
        .pmpcfg_i              (pmpcfg),
        .pmpaddr_i             (pmpaddr),
        .fcsr_frm_i            (frm_csr_id_issue_ex),
        .acc_mmu_en_i          (enable_translation_csr_ex),
        .dirty_v_state_o       (dirty_v_state),
        .issue_instr_i         (issue_instr_id_acc),
        .issue_instr_hs_i      (issue_instr_hs_id_acc),
        .issue_stall_o         (stall_acc_id),
        .fu_data_i             (fu_data_id_ex[0]),
        .commit_instr_i        (commit_instr_id_commit),
        .commit_st_barrier_i   (fence_i_commit_controller | fence_commit_controller),
        .acc_trans_id_o        (acc_trans_id_ex_id),
        .acc_result_o          (acc_result_ex_id),
        .acc_valid_o           (acc_valid_ex_id),
        .acc_exception_o       (acc_exception_ex_id),
        .acc_valid_ex_o        (acc_valid_acc_ex),
        .commit_ack_i          (commit_ack),
        .acc_stall_st_pending_o(stall_st_pending_ex),
        .acc_no_st_pending_i   (no_st_pending_commit),
        .dcache_req_ports_i    (dcache_req_ports_ex_cache),
        .acc_mmu_req_o         (acc_mmu_req),
        .acc_mmu_resp_i        (acc_mmu_resp),
        .ctrl_halt_o           (halt_acc_ctrl),
        .csr_addr_i            (csr_addr_ex_csr),
        .acc_dcache_req_ports_o(dcache_req_ports_acc_cache),
        .acc_dcache_req_ports_i(dcache_req_ports_cache_acc),
        .inval_ready_i         (inval_ready),
        .inval_valid_o         (acc_inval_valid),
        .inval_addr_o          (acc_inval_addr),
        .acc_req_o             (cvxif_req_o),
        .acc_resp_i            (cvxif_resp_i)
    );
  end : gen_accelerator
  else begin : gen_no_accelerator
    assign acc_trans_id_ex_id         = '0;
    assign acc_result_ex_id           = '0;
    assign acc_valid_ex_id            = '0;
    assign acc_exception_ex_id        = '0;
    assign acc_resp_fflags            = '0;
    assign acc_resp_fflags_valid      = '0;
    assign stall_acc_id               = '0;
    assign dirty_v_state              = '0;
    assign acc_valid_acc_ex           = '0;
    assign halt_acc_ctrl              = '0;
    assign stall_st_pending_ex        = '0;
    assign flush_acc                  = '0;
    assign single_step_acc_commit     = '0;

    // D$ connection is unused
    assign dcache_req_ports_acc_cache = '0;

    // MMU access is unused
    assign acc_mmu_req                = '0;

    // No accelerator invalidation — external l1_inval_* still reach the D$
    assign acc_inval_valid            = 1'b0;
    assign acc_inval_addr             = '0;

    // Feed through cvxif
    assign cvxif_req_o                = cvxif_req;
  end : gen_no_accelerator

  // -------------------
  // Parameter Check
  // -------------------
  // pragma translate_off
  initial config_pkg::check_cfg(CVA6Cfg);
  // pragma translate_on

  // -------------------
  // Instruction Tracer
  // -------------------

  //pragma translate_off
`ifdef PITON_ARIANE
  localparam PC_QUEUE_DEPTH = 16;

  logic                                               piton_pc_vld;
  logic [         CVA6Cfg.VLEN-1:0]                   piton_pc;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.VLEN-1:0] pc_data;
  logic [CVA6Cfg.NrCommitPorts-1:0] pc_pop, pc_empty;

  for (genvar i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin : gen_pc_fifo
    cva6_fifo_v3 #(
        .DATA_WIDTH(64),
        .DEPTH(PC_QUEUE_DEPTH),
        .FPGA_EN(CVA6Cfg.FpgaEn)
    ) i_pc_fifo (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   ('0),
        .testmode_i('0),
        .full_o    (),
        .empty_o   (pc_empty[i]),
        .usage_o   (),
        .data_i    (commit_instr_id_commit[i].pc),
        .push_i    (commit_ack[i] & ~commit_instr_id_commit[i].ex.valid),
        .data_o    (pc_data[i]),
        .pop_i     (pc_pop[i])
    );
  end

  rr_arb_tree #(
      .NumIn(CVA6Cfg.NrCommitPorts),
      .DataWidth(64)
  ) i_rr_arb_tree (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (~pc_empty),
      .gnt_o  (pc_pop),
      .data_i (pc_data),
      .gnt_i  (piton_pc_vld),
      .req_o  (piton_pc_vld),
      .data_o (piton_pc),
      .idx_o  ()
  );
`endif  // PITON_ARIANE

`ifndef VERILATOR

  logic [                     31:0]       fetch_instructions     [CVA6Cfg.NrIssuePorts-1:0];
  logic [CVA6Cfg.NrCommitPorts-1:0][63:0] wdata_commit_id_padded;

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; ++i) begin
    assign fetch_instructions[i] = fetch_entry_if_id[i].instruction;
  end

  for (genvar i = 0; i < CVA6Cfg.NrCommitPorts; ++i) begin
    assign wdata_commit_id_padded[i] = {{(64 - CVA6Cfg.XLEN) {1'b0}}, wdata_commit_id[i]};
  end

  instr_tracer #(
      .CVA6Cfg(CVA6Cfg),
      .bp_resolve_t(bp_resolve_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .interrupts_t(interrupts_t),
      .exception_t(exception_t),
      .INTERRUPTS(INTERRUPTS)
  ) instr_tracer_i (
      // .tracer_if(tracer_if),
      .pck(clk_i),
      .rstn(rst_ni),
      .flush_unissued(flush_unissued_instr_ctrl_id),
      .flush_all(flush_ctrl_ex),
      .instruction(fetch_instructions),
      .fetch_valid(id_stage_i.fetch_entry_valid_i),
      .fetch_ack(id_stage_i.fetch_entry_ready_o),
      .issue_ack(issue_stage_i.i_scoreboard.issue_ack_i),
      .issue_sbe(issue_stage_i.i_scoreboard.issue_instr_o),
      .waddr(waddr_commit_id),
      .wdata(wdata_commit_id_padded),
      .we_gpr(we_gpr_commit_id),
      .we_fpr(we_fpr_commit_id),
      .commit_instr(commit_instr_id_commit),
      .commit_ack(commit_ack_commit_id),
      .commit_drop(commit_drop_id_commit),
      .st_valid(ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i),
      .st_paddr(ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i),
      .ld_valid(ex_stage_i.lsu_i.i_load_unit.req_port_o.tag_valid),
      .ld_kill(ex_stage_i.lsu_i.i_load_unit.req_port_o.kill_req),
      .ld_paddr(ex_stage_i.lsu_i.i_load_unit.paddr_i),
      .resolve_branch(resolved_branch),
      .commit_exception(commit_stage_i.exception_o),
      .priv_lvl(priv_lvl),
      .debug_mode(debug_mode),
      .hart_id_i(hart_id_i)
  );

  // mock tracer for Verilator, to be used with spike-dasm
`else

  int f;
  logic [63:0] cycles;

  initial begin
    string fn;
    $sformat(fn, "trace_hart_%0.0f.dasm", hart_id_i);
    f = $fopen(fn, "w");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      cycles <= 0;
    end else begin
      byte mode = "";
      if (CVA6Cfg.DebugEn && debug_mode) mode = "D";
      else begin
        case (priv_lvl)
          riscv::PRIV_LVL_M: mode = "M";
          riscv::PRIV_LVL_S: if (CVA6Cfg.RVS) mode = "S";
          riscv::PRIV_LVL_U: mode = "U";
          default: ;  // Do nothing
        endcase
      end
      for (int i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
        if (commit_ack[i] && !commit_instr_id_commit[i].ex.valid) begin
          $fwrite(f, "%d 0x%0h %s (0x%h) DASM(%h)\n", cycles, commit_instr_id_commit[i].pc, mode,
                  commit_instr_id_commit[i].ex.tval[31:0], commit_instr_id_commit[i].ex.tval[31:0]);
        end else if (commit_ack[i] && commit_instr_id_commit[i].ex.valid) begin
          if (commit_instr_id_commit[i].ex.cause == 2) begin
            $fwrite(f, "Exception Cause: Illegal Instructions, DASM(%h) PC=%h\n",
                    commit_instr_id_commit[i].ex.tval[31:0], commit_instr_id_commit[i].pc);
          end else begin
            if (CVA6Cfg.DebugEn && debug_mode) begin
              $fwrite(f, "%d 0x%0h %s (0x%h) DASM(%h)\n", cycles, commit_instr_id_commit[i].pc,
                      mode, commit_instr_id_commit[i].ex.tval[31:0],
                      commit_instr_id_commit[i].ex.tval[31:0]);
            end else begin
              $fwrite(f, "Exception Cause: %5d, DASM(%h) PC=%h\n",
                      commit_instr_id_commit[i].ex.cause, commit_instr_id_commit[i].ex.tval[31:0],
                      commit_instr_id_commit[i].pc);
            end
          end
        end
      end
      cycles <= cycles + 1;
    end
  end

  final begin
    $fclose(f);
  end
`endif  // VERILATOR
  //pragma translate_on


  //RVFI INSTR
  // Issue-aligned encodings come from id_stage's issue_q (rvfi_instr_id),
  // which carries the fetch instruction through every compaction/splice —
  // correct for any NrIssuePorts, unlike the previous fetch-stage probe.

  cva6_rvfi_probes #(
      .CVA6Cfg            (CVA6Cfg),
      .exception_t        (exception_t),
      .scoreboard_entry_t (scoreboard_entry_t),
      .lsu_ctrl_t         (lsu_ctrl_t),
      .bp_resolve_t       (bp_resolve_t),
      .rvfi_probes_instr_t(rvfi_probes_instr_t),
      .rvfi_probes_csr_t  (rvfi_probes_csr_t),
      .rvfi_probes_t      (rvfi_probes_t)
  ) i_cva6_rvfi_probes (

      .flush_i            (flush_ctrl_if),
      .issue_instr_ack_i  (issue_instr_issue_id),
      .fetch_entry_valid_i(fetch_valid_if_id),
      .instruction_i      (rvfi_instr_id),
      .is_compressed_i    (rvfi_is_compressed),

      .issue_pointer_i (rvfi_issue_pointer),
      .commit_pointer_i(rvfi_commit_pointer),

      .flush_unissued_instr_i(flush_unissued_instr_ctrl_id),
      .decoded_instr_valid_i (issue_entry_valid_id_issue),
      .decoded_instr_ack_i   (issue_instr_issue_id),

      .rs1_i(rvfi_rs1),
      .rs2_i(rvfi_rs2),
      .operand_valid_i(rvfi_operand_valid),
      .operand_tid_i(rvfi_operand_tid),

      .commit_instr_i(commit_instr_id_commit),
      .commit_drop_i (commit_drop_id_commit),
      .ex_commit_i   (ex_commit),
      .priv_lvl_i    (priv_lvl),

      .lsu_ctrl_i  (rvfi_lsu_ctrl),
      .wbdata_i    (wbdata_ex_id),
      .commit_ack_i(commit_ack),
      .mem_paddr_i (rvfi_mem_paddr),
      .debug_mode_i(debug_mode),
      .wdata_i     (wdata_commit_id),

      .csr_i(rvfi_csr),
      .irq_i(irq_active),
      .resolved_branch_i(resolved_branch),
      .flu_trans_id_ex_id_i(flu_trans_id_ex_id),
      .rvfi_probes_o(rvfi_probes_o)

  );

  //pragma translate_off
`ifdef G6LC_FETCH_B
  // T20b: `+smt_handoff_trace` is an alias of `+smt_flow_trace`;
  // `+smt_flow_lo=N +smt_flow_hi=M` window both the handoff and the
  // [smt-probe] kill/req/resp/pop lines (default: whole run, as before), and
  // the handoff line carries the core (hart_id_i) and the cycle.
  bit smt_handoff_trace;
  int unsigned smt_flow_lo, smt_flow_hi, smt_flow_cyc;
  logic smt_flow_on;
  initial begin
    smt_handoff_trace = $test$plusargs("smt_flow_trace") || $test$plusargs("smt_handoff_trace");
    smt_flow_lo = 0;
    smt_flow_hi = 32'hFFFF_FFFF;
    void'($value$plusargs("smt_flow_lo=%0d", smt_flow_lo));
    void'($value$plusargs("smt_flow_hi=%0d", smt_flow_hi));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) smt_flow_cyc = 0;
    else smt_flow_cyc = smt_flow_cyc + 1;
  end
  assign smt_flow_on = smt_handoff_trace && smt_flow_cyc >= smt_flow_lo && smt_flow_cyc <= smt_flow_hi;
  always @(posedge clk_i) begin
    if (rst_ni && smt_flow_on && smt_switch) begin
      $display("[smt-flow] handoff core=%0d cyc=%0d time=%0t from=%0d to=%0d frontier_candidate=%h transport=%h restore=%h empty=%b stores_clear=%b forced=%b force_pc=%h",
               hart_id_i[7:0], smt_flow_cyc, $time, smt_outgoing_hart, smt_active_hart, smt_restart_pc,
               smt_npc_live, smt_npc_restore, smt_sb_empty, no_st_pending_commit,
               smt_drain_forced, smt_drain_force_pc);
      $display("[smt-flow] transport pending=%b target=%h inflight=%b inflight_pc=%h cursor=%h registered=%b registered_pc=%h carry=%b carry_pc=%h ftq=%b ftq_pc=%h",
               i_frontend.redirect_pend_q, i_frontend.redirect_pc_q,
               i_frontend.inflight_q, i_frontend.inflight_addr_q, i_frontend.npc_q,
               i_frontend.icache_valid_q, i_frontend.icache_vaddr_q,
               i_frontend.leftover_valid, i_frontend.leftover_pc,
               i_frontend.ftq_head_valid, i_frontend.ftq_head_vaddr);
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
        $display("[smt-flow] frontier port=%0d decode_v=%b decode_h=%0d decode_pc=%h queue_v=%b queue_h=%0d queue_pc=%h",
                 p, issue_entry_valid_id_issue[p], issue_entry_id_issue[p].hart_id,
                 issue_entry_id_issue[p].pc, fetch_valid_if_id[p], fetch_entry_if_id[p].hart_id,
                 fetch_entry_if_id[p].address);
    end
    // T6b-3b diagnostic (window-gated): which kill eats a pre-dispatch parcel,
    // and what the peer-restart frontier can see at that instant. Prints on
    // every pre-dispatch kill, every I$ request accept, every I$ response
    // (taken or dropped), and every queue->ID transfer.
    if (rst_ni && smt_flow_on && $time > 64'd1040000) begin
      if (flush_ctrl_if || flush_unissued_instr_ctrl_id || flush_ctrl_id) begin
        $display("[smt-probe] kill core=%0d cyc=%0d t=%0t fif=%b uniss=%b fid=%b rb=%b misp=%b rb_h=%0d ex=%b eret=%b spc=%b replay=%b sw=%b act=%0d",
                 hart_id_i[7:0], smt_flow_cyc, $time, flush_ctrl_if, flush_unissued_instr_ctrl_id, flush_ctrl_id,
                 resolved_branch.valid, resolved_branch.is_mispredict,
                 resolved_branch.hart_id, ex_commit.valid, eret,
                 set_pc_ctrl_pcgen, mem_replay_pc_ctrl_pcgen, smt_switch,
                 smt_active_hart);
        $display("[smt-probe] killfe t=%0t npc=%h infl=%b ia=%h pend=%b ppc=%h sb0=%b sb0pc=%h sb1=%b sb1pc=%h pr=%b prh=%0d prpc=%h",
                 $time, i_frontend.npc_q, i_frontend.inflight_q,
                 i_frontend.inflight_addr_q, i_frontend.redirect_pend_q,
                 i_frontend.redirect_pc_q, sb_head_valid[0], sb_head_pc[0],
                 sb_head_valid[CVA6Cfg.NrHarts-1], sb_head_pc[CVA6Cfg.NrHarts-1],
                 peer_restart_valid,
                 peer_restart_hart, peer_restart_pc);
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          $display("[smt-probe] frontier t=%0t port=%0d decode_v=%b decode_h=%0d decode_pc=%h queue_v=%b queue_h=%0d queue_pc=%h",
                   $time, p, issue_entry_valid_id_issue[p],
                   issue_entry_id_issue[p].hart_id, issue_entry_id_issue[p].pc,
                   fetch_valid_if_id[p], fetch_entry_if_id[p].hart_id,
                   fetch_entry_if_id[p].address);
      end
      if (icache_dreq_if_cache.req && icache_dreq_cache_if.ready)
        $display("[smt-probe] req t=%0t va=%h tok=%0d k1=%b k2=%b act=%0d",
                 $time, icache_dreq_if_cache.vaddr, icache_dreq_if_cache.token,
                 icache_dreq_if_cache.kill_s1, icache_dreq_if_cache.kill_s2,
                 smt_active_hart);
      if (icache_dreq_cache_if.valid)
        $display("[smt-probe] resp t=%0t va=%h tok=%0d take=%b kd=%b wv=%b wt=%0d wpf=%b infl=%b ia=%h npc=%h act=%0d",
                 $time, icache_dreq_cache_if.vaddr, icache_dreq_cache_if.token,
                 i_frontend.icache_take, i_frontend.kill_drop,
                 i_frontend.want_valid_q, i_frontend.want_token_q,
                 i_frontend.want_pf_q, i_frontend.inflight_q,
                 i_frontend.inflight_addr_q, i_frontend.npc_q, smt_active_hart);
      for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
        if (fetch_valid_if_id[p] && fetch_ready_id_if[p])
          $display("[smt-probe] pop t=%0t port=%0d h=%0d pc=%h",
                   $time, p, fetch_entry_if_id[p].hart_id,
                   fetch_entry_if_id[p].address);
    end
  end

  // Drained-handoff witness (T6a): integer multi-hart OoO is legal precisely
  // because the thread selector only switches on a drained pipeline. If a
  // switch ever fired with OoO state resident, the hart-blind IQ/ROB/LSQ would
  // silently alias work across harts — report it here. The generate guard also
  // keeps the hierarchical references legal when OoOEn=0.
  if (CVA6Cfg.OoOEn && CVA6Cfg.NrHarts > 1 && CVA6Cfg.SmtDrainedHandoff) begin : gen_ooo_switch_drained
    ooo_switch_drained: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        smt_switch |-> (smt_sb_empty && no_st_pending_commit
                        && !issue_stage_i.gen_full_ooo.i_ooo_dispatch.lsq_busy
                        && issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q == '0
                        && issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.count_q == '0))
    else begin
      $display("[ooo-switch-drained] hart=%0d sbem=%0d sbn=%0d stp=%0d lsqb=%0d rob=%0d iq=%0d fid=%0d miss=%0d quant=%0d starve=%0d forced=%0d",
               smt_active_hart, smt_sb_empty, issue_stage_i.i_scoreboard.sb_issued_cnt,
               no_st_pending_commit,
               issue_stage_i.gen_full_ooo.i_ooo_dispatch.lsq_busy,
               issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q,
               issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.count_q,
               flush_ctrl_id, smt_switch_on_miss, smt_switch_on_quantum,
               smt_switch_on_starve, smt_drain_forced);
      $error("ooo_switch_drained: hart switch with OoO state resident");
    end
  end

  // T6b-2b invariants on the per-access context split. Under the drained
  // handoff every side-select collapses onto the active hart, so the LSU and
  // commit views must equal the fetch view whenever they are sampled.
  if (CVA6Cfg.SmtDrainedHandoff) begin : gen_t6b2b_drained_ctx
    t6b2b_drained_lsu_ctx : assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (lsu_ctx_hart == smt_active_hart) && (lsu_chk_ctx_hart == smt_active_hart))
    else $error("t6b2b: lsu_ctx_hart/lsu_chk_ctx_hart diverged from active hart under drained handoff");
  end

  // T6b-3b residency statistics (+smt_mixed_stats): the evidence that mixed
  // residency actually happened. Counts cycles with every hart holding a
  // live scoreboard entry (sb_head_valid), commits whose owning hart is not
  // the active fetch hart, and per-hart retirements.
  // T6b-4a measurement counters (same plusarg): per-hart residency, fetch
  // share, mispredict/peer-restart attribution, scoreboard occupancy,
  // head-of-line blocking, LSU-context switches and stall-vs-peer-occupancy
  // attribution. OoO-structure occupancy (IQ/ROB/LSQ/PRF) is measured in
  // gen_ms_ooo below — it exists only when OoOEn.
  if (CVA6Cfg.NrHarts > 1) begin : gen_smt_mixed_stats
    bit smt_mixed_stats;
    longint unsigned smt_ms_both_resident, smt_ms_nonactive_commit;
    longint unsigned smt_ms_retired[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_cycles;
    longint unsigned smt_ms_resident[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_fetch_req[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_fetch_parcel[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_mispredict[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_peer_restart[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_ctx_switch;
    // T6b-4b: residual head-of-line = cycles where some hart's head is
    // complete, non-privileged and not PRESENTED on any commit port —
    // the port-availability measure. hol_presented_unacked counts heads
    // presented but not acked (store-buffer backpressure, halt,
    // flush-cycle parking and friends land there).
    longint unsigned smt_ms_hol_residual;
    longint unsigned smt_ms_hol_presented;
    longint unsigned smt_ms_stb_head_stall;
    longint unsigned smt_ms_xcommit;
    longint unsigned smt_ms_stall_rob, smt_ms_stall_iq;
    longint unsigned smt_ms_stall_lsq, smt_ms_stall_ren;
    longint unsigned smt_ms_sb_occ_acc[CVA6Cfg.NrHarts];
    int unsigned smt_ms_sb_occ_max[CVA6Cfg.NrHarts];
    int unsigned sb_occ[CVA6Cfg.NrHarts];
    logic [HART_ID_BITS-1:0] smt_ms_lsu_ctx_q;
    always_comb begin
      for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
        sb_occ[h] = 0;
        for (int s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
          if (issue_stage_i.i_scoreboard.mem_q[s].issued &&
              issue_stage_i.i_scoreboard.mem_q[s].sbe.hart_id == HART_ID_BITS'(h))
            sb_occ[h]++;
      end
    end
    initial begin
      smt_mixed_stats = $test$plusargs("smt_mixed_stats");
      smt_ms_both_resident = 0;
      smt_ms_nonactive_commit = 0;
      smt_ms_cycles = 0;
      smt_ms_ctx_switch = 0;
      smt_ms_hol_residual = 0;
      smt_ms_hol_presented = 0;
      smt_ms_stb_head_stall = 0;
      smt_ms_xcommit = 0;
      smt_ms_stall_rob = 0;
      smt_ms_stall_iq = 0;
      smt_ms_stall_lsq = 0;
      smt_ms_stall_ren = 0;
      smt_ms_lsu_ctx_q = '0;
      for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
        smt_ms_retired[h] = 0;
        smt_ms_resident[h] = 0;
        smt_ms_fetch_req[h] = 0;
        smt_ms_fetch_parcel[h] = 0;
        smt_ms_mispredict[h] = 0;
        smt_ms_peer_restart[h] = 0;
        smt_ms_sb_occ_acc[h] = 0;
        smt_ms_sb_occ_max[h] = 0;
      end
    end
    always @(posedge clk_i) begin
      if (rst_ni && smt_mixed_stats) begin
        smt_ms_cycles++;
        if (&sb_head_valid) smt_ms_both_resident++;
        for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
          if (sb_head_valid[h]) smt_ms_resident[h]++;
          smt_ms_sb_occ_acc[h] += sb_occ[h];
          if (sb_occ[h] > smt_ms_sb_occ_max[h]) smt_ms_sb_occ_max[h] = sb_occ[h];
        end
        for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
          if (commit_ack[p]) begin
            if (commit_instr_id_commit[p].hart_id != smt_active_hart)
              smt_ms_nonactive_commit++;
            if (smt_retire_valid[p]) smt_ms_retired[smt_retire_hart[p]]++;
          end
        end
        // Fetch share: I$ requests issued and parcels delivered to decode,
        // attributed to the hart the frontend is fetching.
        if (icache_dreq_if_cache.req) smt_ms_fetch_req[smt_active_hart]++;
        if (smt_fetch_fire) smt_ms_fetch_parcel[smt_active_hart]++;
        // Branch mispredicts and the partial-kill peer restarts they cause.
        if (resolved_branch.valid && resolved_branch.is_mispredict)
          smt_ms_mispredict[resolved_branch.hart_id]++;
        if (peer_restart_valid && !flush_ctrl_id)
          smt_ms_peer_restart[resolved_branch.hart_id]++;
        // LSU translation-context switches (request hart changes).
        if (lsu_ctx_hart != smt_ms_lsu_ctx_q) smt_ms_ctx_switch++;
        smt_ms_lsu_ctx_q <= lsu_ctx_hart;
        // T6b-4b hol_residual: a hart's head is complete, non-privileged
        // (commit-eligible), yet no port PRESENTED it this cycle — the
        // residual head-of-line the per-hart port rules leave behind.
        // hol_presented_unacked: presented but not acked — store-buffer
        // backpressure, halt, flush-cycle parking and friends.
        begin
          automatic logic res, pres_unack;
          res = 1'b0; pres_unack = 1'b0;
          for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
            automatic int unsigned hs;
            automatic logic priv, acked, presented;
            hs = int'(issue_stage_i.i_scoreboard.head_slot[h]);
            priv = (issue_stage_i.i_scoreboard.mem_q[hs].sbe.valid &&
                    issue_stage_i.i_scoreboard.mem_q[hs].sbe.ex.valid) ||
                   (issue_stage_i.i_scoreboard.mem_q[hs].sbe.fu == ariane_pkg::CSR) ||
                   issue_stage_i.i_scoreboard.mem_q[hs].replay ||
                   (CVA6Cfg.RVA && ariane_pkg::is_amo(
                        issue_stage_i.i_scoreboard.mem_q[hs].sbe.op));
            if (issue_stage_i.i_scoreboard.head_valid[h] &&
                issue_stage_i.i_scoreboard.mem_q[hs].sbe.valid &&
                !issue_stage_i.i_scoreboard.mem_q[hs].cancelled && !priv) begin
              acked = 1'b0; presented = 1'b0;
              for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
                if (issue_stage_i.i_scoreboard.commit_sel_slot[p] ==
                    CVA6Cfg.TRANS_ID_BITS'(hs)) presented = 1'b1;
                if (commit_ack_commit_id[p] &&
                    (issue_stage_i.i_scoreboard.commit_sel_slot[p] ==
                     CVA6Cfg.TRANS_ID_BITS'(hs)))
                  acked = 1'b1;
              end
              if (!presented) res = 1'b1;
              else if (!acked) pres_unack = 1'b1;
            end
          end
          if (res) smt_ms_hol_residual++;
          if (pres_unack) smt_ms_hol_presented++;
        end
        // T6b-4b: a store at port 0 stalled because its tid is not the
        // speculative-queue head, and cross-hart port-1 commits.
        if (commit_instr_id_commit[0].valid &&
            (commit_instr_id_commit[0].fu == ariane_pkg::STORE) &&
            !commit_ack_commit_id[0] &&
            ex_stage_i.lsu_i.i_store_unit.store_buffer_i.spec_head_mismatch)
          smt_ms_stb_head_stall++;
        if (CVA6Cfg.NrCommitPorts > 1 && commit_ack_commit_id[1] &&
            (commit_instr_id_commit[1].hart_id != commit_instr_id_commit[0].hart_id))
          smt_ms_xcommit++;
        // Dispatch stalls while the NON-fetching hart holds >= half of the
        // scoreboard window (the shared-structure pressure witness).
        if (CVA6Cfg.NrHarts == 2) begin
          automatic int unsigned peer_h;
          peer_h = CVA6Cfg.NrHarts - 1 - int'(smt_active_hart);
          if (ooo_rob_full && sb_occ[peer_h] * 2 >= CVA6Cfg.NR_SB_ENTRIES)
            smt_ms_stall_rob++;
          if (ooo_iq_full && sb_occ[peer_h] * 2 >= CVA6Cfg.NR_SB_ENTRIES)
            smt_ms_stall_iq++;
          if (ooo_lsq_stall && sb_occ[peer_h] * 2 >= CVA6Cfg.NR_SB_ENTRIES)
            smt_ms_stall_lsq++;
          if (ooo_rename_stall && sb_occ[peer_h] * 2 >= CVA6Cfg.NR_SB_ENTRIES)
            smt_ms_stall_ren++;
        end
      end
    end
    final begin
      if (smt_mixed_stats) begin
        $display("[smt-mixed] both_resident_cycles=%0d nonactive_commits=%0d",
                 smt_ms_both_resident, smt_ms_nonactive_commit);
        for (int h = 0; h < CVA6Cfg.NrHarts; h++)
          $display("[smt-mixed] retired hart %0d = %0d", h, smt_ms_retired[h]);
        $display("[smt-mixed] cycles=%0d hol_residual=%0d hol_presented_unacked=%0d lsu_ctx_switches=%0d",
                 smt_ms_cycles, smt_ms_hol_residual, smt_ms_hol_presented, smt_ms_ctx_switch);
        $display("[smt-mixed] store_head_mismatch_stall_cycles=%0d cross_hart_port1_commits=%0d",
                 smt_ms_stb_head_stall, smt_ms_xcommit);
        for (int h = 0; h < CVA6Cfg.NrHarts; h++)
          $display("[smt-mixed] hart%0d resident=%0d fetch_req=%0d fetch_parcel=%0d mispredict=%0d peer_restarts_caused=%0d sb_occ_avg=%0d.%02d sb_occ_max=%0d",
                   h, smt_ms_resident[h], smt_ms_fetch_req[h],
                   smt_ms_fetch_parcel[h], smt_ms_mispredict[h],
                   smt_ms_peer_restart[h],
                   smt_ms_cycles ? smt_ms_sb_occ_acc[h] / smt_ms_cycles : 0,
                   smt_ms_cycles ? (100 * smt_ms_sb_occ_acc[h] / smt_ms_cycles) % 100 : 0,
                   smt_ms_sb_occ_max[h]);
        $display("[smt-mixed] stalls_peer_half_sb: rob=%0d iq=%0d lsq=%0d rename=%0d",
                 smt_ms_stall_rob, smt_ms_stall_iq, smt_ms_stall_lsq,
                 smt_ms_stall_ren);
      end
    end
  end

  // T6b-4a: OoO-structure occupancy (IQ/LSQ per hart, ROB/PRF shared — those
  // structures are hart-blind, so per-hart attribution is not meaningful;
  // reported as totals). Separate generate so the hierarchical paths only
  // elaborate when the OoO backend exists.
  if (CVA6Cfg.NrHarts > 1 && CVA6Cfg.OoOEn) begin : gen_ms_ooo_stats
    bit smt_ms_ooo_en;
    longint unsigned smt_ms_o_cycles;
    longint unsigned smt_ms_iq_occ_acc[CVA6Cfg.NrHarts];
    int unsigned smt_ms_iq_occ_max[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_lsq_occ_acc[CVA6Cfg.NrHarts];
    int unsigned smt_ms_lsq_occ_max[CVA6Cfg.NrHarts];
    longint unsigned smt_ms_rob_occ_acc;
    int unsigned smt_ms_rob_occ_max;
    longint unsigned smt_ms_prf_used_acc;
    int unsigned smt_ms_prf_used_max;
    initial begin
      smt_ms_ooo_en = $test$plusargs("smt_mixed_stats");
      smt_ms_o_cycles = 0;
      smt_ms_rob_occ_acc = 0;
      smt_ms_rob_occ_max = 0;
      smt_ms_prf_used_acc = 0;
      smt_ms_prf_used_max = 0;
      for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
        smt_ms_iq_occ_acc[h] = 0;
        smt_ms_iq_occ_max[h] = 0;
        smt_ms_lsq_occ_acc[h] = 0;
        smt_ms_lsq_occ_max[h] = 0;
      end
    end
    always @(posedge clk_i) begin
      if (rst_ni && smt_ms_ooo_en) begin
        automatic int unsigned iq_occ[CVA6Cfg.NrHarts];
        automatic int unsigned lsq_occ[CVA6Cfg.NrHarts];
        automatic int unsigned prf_used;
        smt_ms_o_cycles++;
        for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
          iq_occ[h] = 0;
          lsq_occ[h] = 0;
        end
        for (int e = 0; e < issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.DEPTH; e++)
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].valid)
            iq_occ[int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_iq.q_q[e].sbe.hart_id)]++;
        for (int e = 0; e < issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.LD_ENTRIES; e++)
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[e].valid)
            lsq_occ[int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[e].hart)]++;
        for (int e = 0; e < issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ST_ENTRIES; e++)
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.st_q[e].valid)
            lsq_occ[int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.st_q[e].hart)]++;
        prf_used = 0;
        for (int e = 0; e < issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rename.PRF_ENTRIES; e++)
          if (!issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rename.free_q[e])
            prf_used++;
        for (int h = 0; h < CVA6Cfg.NrHarts; h++) begin
          smt_ms_iq_occ_acc[h] += iq_occ[h];
          smt_ms_lsq_occ_acc[h] += lsq_occ[h];
          if (iq_occ[h] > smt_ms_iq_occ_max[h]) smt_ms_iq_occ_max[h] = iq_occ[h];
          if (lsq_occ[h] > smt_ms_lsq_occ_max[h]) smt_ms_lsq_occ_max[h] = lsq_occ[h];
        end
        smt_ms_rob_occ_acc += int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q);
        if (int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q) > smt_ms_rob_occ_max)
          smt_ms_rob_occ_max = int'(issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_rob.count_q);
        smt_ms_prf_used_acc += prf_used;
        if (prf_used > smt_ms_prf_used_max) smt_ms_prf_used_max = prf_used;
      end
    end
    final begin
      if (smt_ms_ooo_en) begin
        for (int h = 0; h < CVA6Cfg.NrHarts; h++)
          $display("[smt-mixed] hart%0d iq_occ_avg=%0d.%02d iq_occ_max=%0d lsq_occ_avg=%0d.%02d lsq_occ_max=%0d",
                   h,
                   smt_ms_o_cycles ? smt_ms_iq_occ_acc[h] / smt_ms_o_cycles : 0,
                   smt_ms_o_cycles ? (100 * smt_ms_iq_occ_acc[h] / smt_ms_o_cycles) % 100 : 0,
                   smt_ms_iq_occ_max[h],
                   smt_ms_o_cycles ? smt_ms_lsq_occ_acc[h] / smt_ms_o_cycles : 0,
                   smt_ms_o_cycles ? (100 * smt_ms_lsq_occ_acc[h] / smt_ms_o_cycles) % 100 : 0,
                   smt_ms_lsq_occ_max[h]);
        $display("[smt-mixed] rob_occ_avg=%0d.%02d rob_occ_max=%0d prf_used_avg=%0d.%02d prf_used_max=%0d",
                 smt_ms_o_cycles ? smt_ms_rob_occ_acc / smt_ms_o_cycles : 0,
                 smt_ms_o_cycles ? (100 * smt_ms_rob_occ_acc / smt_ms_o_cycles) % 100 : 0,
                 smt_ms_rob_occ_max,
                 smt_ms_o_cycles ? smt_ms_prf_used_acc / smt_ms_o_cycles : 0,
                 smt_ms_o_cycles ? (100 * smt_ms_prf_used_acc / smt_ms_o_cycles) % 100 : 0,
                 smt_ms_prf_used_max);
      end
    end
  end

`ifdef G6LC_FETCH_B
  // T6b-3b: the partial-flush restart contract. The kill set is uniform —
  // every flush_unissued source also raises flush_if, so no queue/decode
  // entry can survive a kill that reached the issue stage — and a
  // pre-dispatch kill that is neither a full flush nor the hart switch is a
  // branch mispredict, whose resolving hart owns the peer restart.
  t6b3_kill_set_uniform : assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      flush_unissued_instr_ctrl_id |-> flush_ctrl_if)
  else $error("t6b3: flush_unissued without flush_if broke kill-set uniformity");

  if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff) begin : gen_t6b3_partial_flush
    t6b3_partial_owner : assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (flush_ctrl_if || flush_unissued_instr_ctrl_id) && !flush_ctrl_id && !smt_switch
        |-> (resolved_branch.valid && resolved_branch.is_mispredict))
    else $error("t6b3: partial flush without a mispredict owner — peer restart hart undefined");
  end
`endif

  // T6b-3 exit: a switch must never degrade a commit-level flush. Mixed
  // residency keeps the full flush (controller.sv SwitchGuardMut off); the
  // drained witness asserts the coincidence never happens there — if it fires,
  // the legacy fine-grain drain is not airtight (report, do not fix here).
  if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff) begin : gen_t6b3_switch_flush_guard
    t6b3_switch_keeps_commit_flush : assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        smt_switch && controller_i.commit_flush |-> flush_ctrl_id)
    else $error("t6b3: switch degraded a commit-level flush under mixed residency");
  end
  if (CVA6Cfg.NrHarts > 1 && CVA6Cfg.SmtDrainedHandoff) begin : gen_t6b3_drained_switch_witness
    t6b3_drained_switch_no_commit_flush : assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        smt_switch |-> !controller_i.commit_flush)
    else $error("t6b3: switch coincident with commit-level flush under drained handoff");
  end

  // Read-only load round-trip observer on the core's load port. Requests are
  // paired to responses by data_id/data_rid, which the load unit allocates from
  // its load buffer, so an outstanding tag is unique. idx is the index half of
  // the address, the part that is valid at grant; the tag arrives a cycle later
  // and would be the wrong address here. Ownership is the scheduler's active
  // hart: the LSU carries no hart id, and under the drained handoff in-flight
  // work belongs to one hart, so the reader censors any sample whose request
  // and response disagree rather than attributing it.
  bit smt_rtt_trace;
  int unsigned smt_rtt_cycle;
  initial smt_rtt_trace = $test$plusargs("smt_rtt_trace");
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      smt_rtt_cycle = 0;
    end else if (smt_rtt_trace) begin
      smt_rtt_cycle = smt_rtt_cycle + 1;
      if (dcache_req_ports_ex_cache[1].data_req && dcache_req_ports_cache_ex[1].data_gnt)
        $display("[smt-rtt] req cycle=%0d tag=%0d idx=%h active=%0d", smt_rtt_cycle,
                 dcache_req_ports_ex_cache[1].data_id,
                 dcache_req_ports_ex_cache[1].address_index, smt_active_hart);
      // kill_req applies to the most recent request, whose id the load unit
      // retains; data_id already points at the next free slot by then.
      if (dcache_req_ports_ex_cache[1].kill_req)
        $display("[smt-rtt] kill cycle=%0d tag=%0d active=%0d", smt_rtt_cycle,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_last_id_q, smt_active_hart);
      if (dcache_req_ports_cache_ex[1].data_rvalid)
        $display("[smt-rtt] resp cycle=%0d tag=%0d active=%0d", smt_rtt_cycle,
                 dcache_req_ports_cache_ex[1].data_rid, smt_active_hart);
    end
  end

  // T6b-3 exit diagnostics (+smt_dup_trace): duplicate-commit investigation.
  // Per-cycle dump over a fixed window measured in scoreboard trace cycles
  // (issue_stage_i.i_scoreboard.smt_flow_cycle) so every record lines up with
  // the [smt-flow] alloc/retire lines. Covers the whole commit -> bank-eret
  // -> controller-flush -> redirect / peer-restart -> fetch-frontier chain
  // plus every scoreboard slot carrying the suspect PC.
  if (CVA6Cfg.NrHarts > 1 && !CVA6Cfg.SmtDrainedHandoff) begin : gen_smt_dup_trace
    bit smt_dup_trace;
    int unsigned dup_lo, dup_hi;
    localparam logic [CVA6Cfg.VLEN-1:0] DupPc = CVA6Cfg.VLEN'(64'h0000000080000118);
    initial begin
      smt_dup_trace = $test$plusargs("smt_dup_trace");
      dup_lo = 901060;
      dup_hi = 901170;
      void'($value$plusargs("smt_dup_lo=%0d", dup_lo));
      void'($value$plusargs("smt_dup_hi=%0d", dup_hi));
    end
    always @(posedge clk_i) begin
      if (rst_ni && smt_dup_trace &&
          issue_stage_i.i_scoreboard.smt_flow_cycle >= dup_lo &&
          issue_stage_i.i_scoreboard.smt_flow_cycle <= dup_hi) begin
        // commit ports + the op the CSR bank was presented
        for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++)
          $display("[smt-dup] cyc=%0d cmt p=%0d ack=%b ackid=%b id=%0d pc=%h h=%0d fu=%0d op=%0d v=%b d=%b ex=%b",
                   issue_stage_i.i_scoreboard.smt_flow_cycle, p, commit_ack[p],
                   commit_ack_commit_id[p], issue_stage_i.i_scoreboard.commit_sel_slot[p],
                   commit_instr_id_commit[p].pc, commit_instr_id_commit[p].hart_id,
                   commit_instr_id_commit[p].fu, commit_instr_id_commit[p].op,
                   commit_instr_id_commit[p].valid, commit_drop_id_commit[p],
                   commit_instr_id_commit[p].ex.valid);
        $display("[smt-dup] cyc=%0d bank h0id=%0d sel=%b%b op_in=%0d opg0=%0d opg1=%0d mret=%b%b we=%b%b rd=%b%b eretb=%b%b eret=%b priv=%0d%0d mpp=%0d%0d epc=%h",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 commit_instr_id_commit[0].hart_id,
                 csr_regfile_i.gen_banked.commit_sel[0],
                 csr_regfile_i.gen_banked.commit_sel[1],
                 8'(csr_op_commit_csr), 8'(csr_regfile_i.gen_banked.csr_op_g[0]),
                 8'(csr_regfile_i.gen_banked.csr_op_g[1]),
                 csr_regfile_i.gen_banked.gen_csr[0].i_csr.mret,
                 csr_regfile_i.gen_banked.gen_csr[1].i_csr.mret,
                 csr_regfile_i.gen_banked.gen_csr[0].i_csr.csr_we,
                 csr_regfile_i.gen_banked.gen_csr[1].i_csr.csr_we,
                 csr_regfile_i.gen_banked.gen_csr[0].i_csr.csr_read,
                 csr_regfile_i.gen_banked.gen_csr[1].i_csr.csr_read,
                 csr_regfile_i.gen_banked.eret_b[0],
                 csr_regfile_i.gen_banked.eret_b[1], eret,
                 csr_regfile_i.gen_banked.priv_b[0],
                 csr_regfile_i.gen_banked.priv_b[1],
                 csr_regfile_i.gen_banked.gen_csr[0].i_csr.mstatus_q.mpp,
                 csr_regfile_i.gen_banked.gen_csr[1].i_csr.mstatus_q.mpp,
                 epc_commit_pcgen);
        // controller flush outputs and the inputs that drive them
        $display("[smt-dup] cyc=%0d ctl fif=%b fid=%b uniss=%b fex=%b fbp=%b spc=%b sw=%b halt=%b hfe=%b replay=%b csrfl=%b exv=%b exc=%h eret_i=%b act=%0d out=%0d rest_v=%b rest=%h nrest=%h pc_cmt=%h wh=%b%b",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 flush_ctrl_if, flush_ctrl_id, flush_unissued_instr_ctrl_id,
                 flush_ctrl_ex, flush_ctrl_bp, set_pc_ctrl_pcgen, smt_switch,
                 halt_ctrl, halt_frontend, mem_replay_pc_ctrl_pcgen,
                 flush_csr_ctrl, ex_commit.valid, ex_commit.cause[15:0], eret,
                 smt_active_hart, smt_outgoing_hart, smt_pc_restore,
                 smt_npc_restore, smt_npc_live, pc_commit,
                 whart_commit_id[0], whart_commit_id[CVA6Cfg.NrCommitPorts-1]);
        // resolved branch raw / as filtered for the controller and frontend
        $display("[smt-dup] cyc=%0d rb v=%b misp=%b cmisp=%b h=%0d pc=%h tgt=%h | fe_rfa=%b fe_outr=%b fe_ismisp=%b",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 resolved_branch.valid, resolved_branch.is_mispredict,
                 resolved_branch_ctrl.is_mispredict, resolved_branch.hart_id,
                 resolved_branch.pc, resolved_branch.target_address,
                 i_frontend.resolution_for_active, i_frontend.misp_outranked,
                 i_frontend.is_mispredict);
        // banked redirects and the peer-restart candidates that fed them
        $display("[smt-dup] cyc=%0d red v=%b h=%0d pc=%h | v2=%b h2=%0d pc2=%h | pk=%b fh=%0d prv=%b pra=%b prh=%0d prpc=%h selv=%b selpc=%h fet=%h qold=%b qpc0=%h qpc1=%h pcnt=%0d/%0d",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 smt_arch_redirect_valid, smt_arch_redirect_hart,
                 smt_arch_redirect_pc, smt_arch_redirect2_valid,
                 smt_arch_redirect2_hart, smt_arch_redirect2_pc,
                 gen_peer_restart.partial_kill, gen_peer_restart.fault_hart,
                 peer_restart_valid, peer_restart_active, peer_restart_hart,
                 peer_restart_pc, gen_peer_restart.pr_selected.valid,
                 gen_peer_restart.pr_selected.pc, smt_fetch_frontier,
                 smt_queue_oldest_valid, smt_queue_oldest_pc[0],
                 smt_queue_oldest_pc[CVA6Cfg.NrHarts-1],
                 i_frontend.i_instr_queue.gen_pend_frontier.pend_cnt_q[0],
                 i_frontend.i_instr_queue.gen_pend_frontier.pend_cnt_q[CVA6Cfg.NrHarts-1]);
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          $display("[smt-dup] cyc=%0d cand p=%0d dv=%b dh=%0d dpc=%h | dec_v=%b dec_h=%0d dec_pc=%h | fe_v=%b fe_h=%0d fe_pc=%h fe_rdy=%b",
                   issue_stage_i.i_scoreboard.smt_flow_cycle, p,
                   gen_peer_restart.pr_decode_valid[p],
                   gen_peer_restart.pr_decode_hart[p],
                   gen_peer_restart.pr_decode_pc[p],
                   issue_entry_valid_id_issue[p], issue_entry_id_issue[p].hart_id,
                   issue_entry_id_issue[p].pc, fetch_valid_if_id[p],
                   fetch_entry_if_id[p].hart_id, fetch_entry_if_id[p].address,
                   fetch_ready_id_if[p]);
        // frontend redirect bookkeeping, NPC selection and the I$ interface
        $display("[smt-dup] cyc=%0d fe pend=%b ppc=%h rinfl=%b rlost=%b rhit=%b rhold=%b racc=%b rtrap=%b infl=%b ia=%h npc=%h archv=%b src=%0d apc=%h faddr=%h seq=%h ifrdy=%b req=%b rva=%h rrdy=%b resp=%b rspva=%h take=%b ks2=%b icv=%b icva=%h sham=%0d",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 i_frontend.redirect_pend_q, i_frontend.redirect_pc_q,
                 i_frontend.redirect_inflight_q, i_frontend.redirect_lost_q,
                 i_frontend.redirect_hit, i_frontend.redirect_hold,
                 i_frontend.redirect_accept, i_frontend.redirect_trap_q,
                 i_frontend.inflight_q, i_frontend.inflight_addr_q,
                 i_frontend.npc_q, i_frontend.arch_valid, i_frontend.arch_src,
                 i_frontend.arch_pc, i_frontend.fetch_address,
                 i_frontend.seq_base, i_frontend.if_ready,
                 icache_dreq_if_cache.req, icache_dreq_if_cache.vaddr,
                 icache_dreq_cache_if.ready, icache_dreq_cache_if.valid,
                 icache_dreq_cache_if.vaddr, i_frontend.icache_take,
                 i_frontend.kill_s2, i_frontend.icache_valid_q,
                 i_frontend.icache_vaddr_q,
                 i_frontend.i_instr_queue.shamt);
        // mixed-residency tail registers and the events that arm them
        for (int p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          if (issue_entry_valid_id_issue[p] && issue_instr_issue_id[p])
            $display("[smt-dup] cyc=%0d tarm p=%0d eh=%0d epc=%h efu=%0d ecf=%0d epred=%h -> %h",
                     issue_stage_i.i_scoreboard.smt_flow_cycle, p,
                     issue_entry_id_issue[p].hart_id, issue_entry_id_issue[p].pc,
                     issue_entry_id_issue[p].fu, issue_entry_id_issue[p].bp.cf,
                     issue_entry_id_issue[p].bp.predict_address,
                     (issue_entry_id_issue[p].fu == CTRL_FLOW &&
                      issue_entry_id_issue[p].bp.cf != ariane_pkg::NoCF)
                         ? issue_entry_id_issue[p].bp.predict_address
                         : issue_entry_id_issue[p].pc + CVA6Cfg.VLEN'(
                             issue_entry_id_issue[p].is_compressed ? 2 : 4));
        $display("[smt-dup] cyc=%0d tail vq=%b%b q0=%h q1=%h | archa=%b ah=%0d apc=%h | flushb=%b",
                 issue_stage_i.i_scoreboard.smt_flow_cycle,
                 gen_smt_restart_frontier.smt_tail_valid_q[1],
                 gen_smt_restart_frontier.smt_tail_valid_q[0],
                 gen_smt_restart_frontier.smt_tail_next_q[0],
                 gen_smt_restart_frontier.smt_tail_next_q[1],
                 smt_arch_redirect_valid, smt_arch_redirect_hart,
                 smt_arch_redirect_pc, flush_ctrl_id);
        // every scoreboard slot holding a copy of the suspect instruction
        for (int s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
          if (issue_stage_i.i_scoreboard.mem_q[s].sbe.pc == DupPc)
            $display("[smt-dup] cyc=%0d sb s=%0d gen=%0d iss=%b can=%b v=%b h=%0d fu=%0d op=%0d ex=%b rep=%b",
                     issue_stage_i.i_scoreboard.smt_flow_cycle, s,
                     issue_stage_i.i_scoreboard.smt_flow_generation[s],
                     issue_stage_i.i_scoreboard.mem_q[s].issued,
                     issue_stage_i.i_scoreboard.mem_q[s].cancelled,
                     issue_stage_i.i_scoreboard.mem_q[s].sbe.valid,
                     issue_stage_i.i_scoreboard.mem_q[s].sbe.hart_id,
                     issue_stage_i.i_scoreboard.mem_q[s].sbe.fu,
                     issue_stage_i.i_scoreboard.mem_q[s].sbe.op,
                     issue_stage_i.i_scoreboard.mem_q[s].sbe.ex.valid,
                     issue_stage_i.i_scoreboard.mem_q[s].replay);
      end
    end
  end
`endif

  // T16 diagnostic probe (+ld_trace): where does the 4th consumed L1-missing
  // load stall on the HPDCACHE server profile? Event lines (load-port
  // handshakes, HPDCACHE miss/refill traffic) print whenever armed; the full
  // per-cycle state dump is confined to [+ld_lo, +ld_hi] (default
  // 14,800-15,100, the mc_l2_write_read hang window). Read-only, sim-only.
  bit ld_trace;
  int unsigned ld_lo, ld_hi, ld_cycle;
  initial begin
    ld_trace = $test$plusargs("ld_trace");
    ld_lo = 14800;
    ld_hi = 15100;
    void'($value$plusargs("ld_lo=%0d", ld_lo));
    void'($value$plusargs("ld_hi=%0d", ld_hi));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      ld_cycle = 0;
    end else if (ld_trace) begin
      ld_cycle = ld_cycle + 1;
      // --- load-unit <-> D$ load port (index 1) events, always on when armed
      if (dcache_req_ports_ex_cache[1].data_req && dcache_req_ports_cache_ex[1].data_gnt)
        $display("[ld-trace] c=%0d h=%0d LU-REQ id=%0d idx=%h tid=%0d st=%0d ldbuf_v=%b",
                 ld_cycle, hart_id_i[7:0], dcache_req_ports_ex_cache[1].data_id,
                 dcache_req_ports_ex_cache[1].address_index,
                 ex_stage_i.lsu_i.i_load_unit.load_trans_id_o,
                 ex_stage_i.lsu_i.i_load_unit.state_q,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_valid_q);
      if (dcache_req_ports_ex_cache[1].tag_valid)
        $display("[ld-trace] c=%0d h=%0d LU-TAG tag=%h kill=%b last_id=%0d",
                 ld_cycle, hart_id_i[7:0], dcache_req_ports_ex_cache[1].address_tag,
                 dcache_req_ports_ex_cache[1].kill_req,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_last_id_q);
      if (dcache_req_ports_cache_ex[1].data_rvalid)
        $display("[ld-trace] c=%0d h=%0d LU-RSP rid=%0d rdata=%h ldbuf_v=%b ldbuf_tid=%0d",
                 ld_cycle, hart_id_i[7:0], dcache_req_ports_cache_ex[1].data_rid,
                 dcache_req_ports_cache_ex[1].data_rdata,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_valid_q,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_q[dcache_req_ports_cache_ex[1].data_rid].trans_id);
      if (ex_stage_i.lsu_i.i_load_unit.valid_o)
        $display("[ld-trace] c=%0d h=%0d LU-WB tid=%0d ex=%b", ld_cycle, hart_id_i[7:0],
                 ex_stage_i.lsu_i.i_load_unit.trans_id_o,
                 ex_stage_i.lsu_i.i_load_unit.ex_o.valid);
      // --- per-cycle state inside the window
      if (ld_cycle >= ld_lo && ld_cycle <= ld_hi) begin
        $display("[ld-trace] c=%0d h=%0d LU st=%0d vin=%b pop=%b tid=%0d paddr_v=%b paddr=%h req=%b gnt=%b tagv=%b kill=%b rvalid=%b rid=%0d ldbuf_v=%b last=%0d flush=%b",
                 ld_cycle, hart_id_i[7:0], ex_stage_i.lsu_i.i_load_unit.state_q,
                 ex_stage_i.lsu_i.i_load_unit.valid_i, ex_stage_i.lsu_i.i_load_unit.pop_ld_o,
                 ex_stage_i.lsu_i.i_load_unit.load_trans_id_o,
                 ex_stage_i.lsu_i.i_load_unit.load_paddr_valid_o,
                 ex_stage_i.lsu_i.i_load_unit.load_paddr_o,
                 dcache_req_ports_ex_cache[1].data_req, dcache_req_ports_cache_ex[1].data_gnt,
                 dcache_req_ports_ex_cache[1].tag_valid, dcache_req_ports_ex_cache[1].kill_req,
                 dcache_req_ports_cache_ex[1].data_rvalid, dcache_req_ports_cache_ex[1].data_rid,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_valid_q,
                 ex_stage_i.lsu_i.i_load_unit.ldbuf_last_id_q, flush_ctrl_ex);
        for (int i = 0; i < CVA6Cfg.NrLoadBufEntries; i++)
          if (ex_stage_i.lsu_i.i_load_unit.ldbuf_valid_q[i])
            $display("[ld-trace] c=%0d h=%0d LDBUF[%0d] tid=%0d off=%h op=%0d flushed=%b", ld_cycle,
                     hart_id_i[7:0], i, ex_stage_i.lsu_i.i_load_unit.ldbuf_q[i].trans_id,
                     ex_stage_i.lsu_i.i_load_unit.ldbuf_q[i].address_offset,
                     ex_stage_i.lsu_i.i_load_unit.ldbuf_q[i].operation,
                     ex_stage_i.lsu_i.i_load_unit.ldbuf_flushed_q[i]);
        // scoreboard commit head (port 0) + issue pointer
        $display("[ld-trace] c=%0d h=%0d SB head=%0d pc=%h issued=%b valid=%b fu=%0d op=%0d ex=%b cancelled=%b replay=%b phys_pending=%b phys_replay=%b issue_ptr=%0d ack=%b flush_id=%b",
                 ld_cycle, hart_id_i[7:0], issue_stage_i.i_scoreboard.commit_pointer_q[0],
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].sbe.pc,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].issued,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].sbe.valid,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].sbe.fu,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].sbe.op,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].sbe.ex.valid,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].cancelled,
                 issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.commit_pointer_q[0]].replay,
                 issue_stage_i.phys_pending[issue_stage_i.i_scoreboard.commit_pointer_q[0]],
                 issue_stage_i.phys_replay[issue_stage_i.i_scoreboard.commit_pointer_q[0]],
                 issue_stage_i.i_scoreboard.issue_pointer_q, commit_ack, flush_ctrl_id);
      end
    end
  end
  if (CVA6Cfg.OoOEn) begin : gen_ld_trace_lsq
    always @(posedge clk_i) begin
      if (rst_ni && ld_trace && ld_cycle >= ld_lo && ld_cycle <= ld_hi) begin
        // same derivation as g6lc_ooo_dispatch's LD_N
        for (int i = 0; i < ((CVA6Cfg.LsqLoadEntries == 0) ? 8 : CVA6Cfg.LsqLoadEntries); i++)
          if (issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].valid)
            $display("[ld-trace] c=%0d h=%0d LSQ[%0d] id=%0d hart=%0d addr_v=%b addr=%h done=%b pc=%h",
                     ld_cycle, hart_id_i[7:0], i,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].id,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].hart,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].addr_v,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].addr,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].done,
                     issue_stage_i.gen_full_ooo.i_ooo_dispatch.i_lsq.ld_q[i].pc);
      end
    end
  end
  if (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT ||
      CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WB ||
      CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB) begin : gen_ld_trace_hpd
    // adapter load port (requester 1), hpdcache core miss path, miss handler,
    // MSHR and the memory read channel of the subsystem
    always @(posedge clk_i) begin
      if (rst_ni && ld_trace) begin
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_valid[1] &&
            gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_ready[1])
          $display("[ld-trace] c=%0d h=%0d HPD-REQ tid=%0d off=%h abort=%b", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req[1].tid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req[1].addr_offset,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_abort[1]);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_abort[1])
          $display("[ld-trace] c=%0d h=%0d HPD-ABORT tag=%h", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_tag[1]);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp_valid[1])
          $display("[ld-trace] c=%0d h=%0d HPD-RSP tid=%0d sid=%0d err=%b aborted=%b", ld_cycle,
                   hart_id_i[7:0], gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].tid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].sid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].error,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].aborted);
        // st1 MSHR check result (hit = pending miss on that line -> rtab)
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_alloc ||
            gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_alloc_and_link)
          $display("[ld-trace] c=%0d h=%0d HPD-RTAB-ALLOC sid=%0d tid=%0d nline=%h link=%b deps mshr_hit=%b mshr_full=%b mshr_ready=%b wbuf_hit=%b wbuf_nr=%b dir_unav=%b dir_fetch=%b pend=%b rtab_full=%b",
                   ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_req.req.sid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_req.req.tid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_req_nline,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_alloc_and_link,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.mshr_hit,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.mshr_full,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.mshr_ready,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.wbuf_hit,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.wbuf_not_ready,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.dir_unavailable,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.dir_fetch,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st1_rtab_deps.pend_trans,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.rtab_full);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st0_rtab_pop_try_valid &&
            gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.st0_rtab_pop_try_ready)
          $display("[ld-trace] c=%0d h=%0d HPD-RTAB-POP", ld_cycle, hart_id_i[7:0]);
        // MSHR allocation: the slot the hpdcache_mshr indexes vs. the mem id it emits
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc)
          $display("[ld-trace] c=%0d h=%0d MSHR-ALLOC nline=%h sid=%0d tid=%0d need_rsp=%b pf=%b -> alloc_set=%0d alloc_way=%0d full=%b valid_q=%b mshrSets=%0d mshrWays=%0d",
                   ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc_nline,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc_sid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc_tid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc_need_rsp,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_alloc_is_prefetch,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.alloc_set,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.alloc_way_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.full_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.mshr_valid_q,
                   // same derivation as cva6_hpdcache_subsystem::hpdcacheSetConfig
                   (CVA6Cfg.NrLoadBufEntries < 16) ? 1 : CVA6Cfg.NrLoadBufEntries / 2,
                   (CVA6Cfg.NrLoadBufEntries < 16) ? CVA6Cfg.NrLoadBufEntries : 2);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_check &&
            gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_hit)
          $display("[ld-trace] c=%0d h=%0d MSHR-HIT nline=%h", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_check_nline);
        // miss handler -> memory read request / response and the MSHR ack
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_valid_o &&
            gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_ready_i)
          $display("[ld-trace] c=%0d h=%0d MEM-RD id=%0d addr=%h", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_o.mem_req_id,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_o.mem_req_addr);
        if (gen_cache_hpd.i_cache_subsystem.dcache_read_resp_valid &&
            gen_cache_hpd.i_cache_subsystem.dcache_read_resp_ready)
          $display("[ld-trace] c=%0d h=%0d MEM-RSP id=%0d last=%b err=%0d", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.dcache_read_resp.mem_resp_r_id,
                   gen_cache_hpd.i_cache_subsystem.dcache_read_resp.mem_resp_r_last,
                   gen_cache_hpd.i_cache_subsystem.dcache_read_resp.mem_resp_r_error);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack)
          $display("[ld-trace] c=%0d h=%0d MSHR-ACK r_id=%0d set=%0d way=%0d -> entry need_rsp=%b sid=%0d tid=%0d tag=%h cache_set=%0d pf=%b core_rsp=%b",
                   ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_fifo_resp_meta_rdata.r_id,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_set,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_way,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_need_rsp,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_src_id,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_req_id,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_cache_tag,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_cache_set,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mshr_ack_is_prefetch,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_core_rsp_valid);
        if (gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_core_rsp_valid)
          $display("[ld-trace] c=%0d h=%0d REFILL-RSP sid=%0d tid=%0d", ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_core_rsp_sid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_core_rsp_tid);
        if (ld_cycle >= ld_lo && ld_cycle <= ld_hi)
          $display("[ld-trace] c=%0d h=%0d HPD st: req_v=%b rdy=%b rsp_v=%b mshr_empty=%b mshr_full=%b mshr_valid=%b rtab_empty=%b rtab_full=%b refill_busy=%b refill_req=%b miss_fsm=%0d refill_fsm=%0d mem_rd_v=%b mem_rd_rdy=%b rsp_meta_rok=%b",
                   ld_cycle, hart_id_i[7:0],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_valid[1],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_ready[1],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp_valid[1],
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.miss_mshr_empty,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.full_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.hpdcache_mshr_i.mshr_valid_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.rtab_empty,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.rtab_full,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.refill_busy,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.refill_req_valid,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.miss_req_fsm_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_fsm_q,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_valid_o,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.mem_req_ready_i,
                   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i.refill_fifo_resp_meta_rok);
      end
    end
  end

  // T20 diagnostic probe (+hpd_trace): HPDCACHE replay-table anatomy behind
  // the core-0 wedge of ooocoh-t19-server-osbi-48M (`rtab v=1111 full=1` with
  // MSHR/wbuf empty and no refill -- four parked requests whose dependencies
  // can never resolve, so core_req_ready_o is low for every port forever).
  //   * [hpd-rtab] full dump (pipeline st0/st1/st2, arbiter, every rtab entry
  //     with its request, deps and age, pop FSM, wbuf/miss/flush inputs) on
  //     every [smt-stall] ticket (hpd_ticket), on every rtab alloc / pop /
  //     commit / rollback inside [+hpd_lo, +hpd_hi] (default 38.9M-39.1M), and
  //     once per "LEAK" episode: rtab non-empty, nothing replayable, MSHR /
  //     wbuf / flush / pipeline all idle for HPD_LEAK_IDLE cycles (always on
  //     when armed -- a leaked entry is caught wherever it happens).
  //   * [hpd-ev] one-line events inside the window: st1 abort (with the st1
  //     request it hits), load-port kill_req (with the load-unit state), the
  //     T19 adapter hold/held_fire/abort_q, load-port req/gnt/rsp, refill
  //     rtab update + MSHR ack, flush ack, uc/cmo handoff.
  //   * T20b: `+hpd_rtab_trace` is an alias of `+hpd_trace`; `+hpd_core=N`
  //     restricts the probe to core N (hart_id_i / NrHarts; default 0 = the
  //     wedged core, -1 = every core); `[hpd-ev] LEVEL` lines on every change
  //     of rtab_full (always) and of core_req_valid/ready (inside the window);
  //     a periodic "full" dump every HPD_FULL_PERIOD cycles while rtab_full
  //     persists (the life of the four parked entries, with their age).
  // Read-only, sim-only (hierarchical reads), gated by the plusarg.
  bit hpd_trace;
  int unsigned hpd_lo, hpd_hi, hpd_cycle;
  int hpd_core;
  initial begin
    hpd_trace = $test$plusargs("hpd_trace") || $test$plusargs("hpd_rtab_trace");
    hpd_lo = 38900000;
    hpd_hi = 39100000;
    hpd_core = 0;
    void'($value$plusargs("hpd_lo=%0d", hpd_lo));
    void'($value$plusargs("hpd_hi=%0d", hpd_hi));
    void'($value$plusargs("hpd_core=%0d", hpd_core));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) hpd_cycle = 0;
    else hpd_cycle = hpd_cycle + 1;
  end
  if (CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT ||
      CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WB ||
      CVA6Cfg.DCacheType == config_pkg::HPDCACHE_WT_WB) begin : gen_hpd_trace
`define HPDT      gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache
`define HPDT_CTRL gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i
`define HPDT_RTAB gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_ctrl_i.hpdcache_rtab_i
`define HPDT_ARB  gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.core_req_arbiter_i
`define HPDT_MH   gen_cache_hpd.i_cache_subsystem.i_dcache.i_hpdcache.hpdcache_miss_handler_i
`define HPDT_LDA  gen_cache_hpd.i_cache_subsystem.i_dcache.gen_cva6_hpdcache_load_if_adapter[1].i_cva6_hpdcache_load_if_adapter.load_port_gen
`define HPDT_LDU  ex_stage_i.lsu_i.i_load_unit
    // same value as cva6_hpdcache_subsystem::hpdcacheSetConfig (rtabEntries)
    localparam int unsigned HPD_RTAB_N = 4;
    localparam int unsigned HPD_LEAK_IDLE = 256;
    localparam int unsigned HPD_FULL_PERIOD = 10000;
    localparam int unsigned HPD_NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
    int unsigned hpd_age[HPD_RTAB_N];
    int unsigned hpd_seen_ticket = 0;
    int unsigned hpd_idle_cnt = 0;
    int unsigned hpd_full_last = 0;
    bit hpd_leak_reported = 0;
    bit hpd_leak_logged_once = 0;
    bit hpd_full_q = 0, hpd_crv_q = 0, hpd_crr_q = 0, hpd_lvl_seen = 0;
    logic hpd_in_win, hpd_idle, hpd_on;
    assign hpd_in_win = hpd_cycle >= hpd_lo && hpd_cycle <= hpd_hi;
    // core filter: hart_id_i is the core's base hart id (NrHarts per core)
    assign hpd_on = hpd_trace && (hpd_core < 0 ||
                                  (int'(hart_id_i[7:0]) / int'(HPD_NH)) == hpd_core);
    // nothing in flight that could still clear a dependency bit
    assign hpd_idle = (|`HPDT_RTAB.valid_q) && !`HPDT_CTRL.st0_rtab_pop_try_valid &&
                      `HPDT_CTRL.mshr_empty_i && `HPDT_CTRL.wbuf_empty_i &&
                      `HPDT_CTRL.flush_empty_i && !`HPDT_CTRL.refill_busy_i &&
                      !`HPDT_CTRL.refill_req_valid_i && !`HPDT_CTRL.st1_req_valid_q &&
                      !`HPDT_CTRL.st2_mshr_alloc_q && !`HPDT_CTRL.st2_dir_updt_q &&
                      !`HPDT_CTRL.st2_flush_alloc_q && !`HPDT_CTRL.uc_busy_i &&
                      !`HPDT_CTRL.cmo_busy_i;

    function automatic void hpd_rtab_dump(input string why);
      $display("[hpd-rtab] %s c=%0d h=%0d | st0 crv=%0d crr=%0d arbv=%b gntd=%b gntq=%b fxwait=%0d fxgnt=%b op=%0d off=%h tid=%0d sid=%0d nrsp=%0d pi=%0d tag=%h abort_in=%0d | st1 v=%0d rtab=%0d op=%0d addr=%h tid=%0d sid=%0d nrsp=%0d pi=%0d err=%0d abort=%0d ptr=%0d dirhit=%0d mshrhit=%0d mshrfull=%0d missrdy=%0d chk=%0d chkhit=%0d wbrdhit=%0d wbwrrdy=%0d flchk=%0d flrdy=%0d npt=%0d alloc=%0d link=%0d commit=%0d rback=%0d rspv=%0d rspab=%0d | st2 m=%0d d=%0d f=%0d | mshr_e=%0d wbuf_e=%0d flush_e=%0d refill_busy=%0d refill_req=%0d uc=%0d cmo=%0d flushbusy=%0d",
               why, hpd_cycle, hart_id_i[7:0],
               `HPDT_CTRL.core_req_valid_i, `HPDT_CTRL.core_req_ready_o,
               `HPDT_ARB.core_req_valid, `HPDT_ARB.arb_req_gnt_d, `HPDT_ARB.arb_req_gnt_q,
               `HPDT_ARB.req_arbiter_i.wait_q, `HPDT_ARB.req_arbiter_i.gnt_q,
               int'(`HPDT_CTRL.core_req_i.op), `HPDT_CTRL.core_req_i.addr_offset,
               `HPDT_CTRL.core_req_i.tid, `HPDT_CTRL.core_req_i.sid,
               `HPDT_CTRL.core_req_i.need_rsp, `HPDT_CTRL.core_req_i.phys_indexed,
               `HPDT_CTRL.core_req_tag_i, `HPDT_CTRL.core_req_abort_i,
               `HPDT_CTRL.st1_req_valid_q, `HPDT_CTRL.st1_req.from_rtab,
               int'(`HPDT_CTRL.st1_req.req.op), `HPDT_CTRL.st1_req_addr,
               `HPDT_CTRL.st1_req.req.tid, `HPDT_CTRL.st1_req.req.sid,
               `HPDT_CTRL.st1_req.req.need_rsp, `HPDT_CTRL.st1_req.req.phys_indexed,
               `HPDT_CTRL.st1_req.is_error, `HPDT_CTRL.st1_req_abort,
               `HPDT_CTRL.st1_rtab_pop_try_ptr_q, `HPDT_CTRL.st1_dir_hit,
               `HPDT_CTRL.st1_mshr_hit_i, `HPDT_CTRL.st1_mshr_alloc_full_i,
               `HPDT_CTRL.st1_mshr_alloc_ready_i,
               `HPDT_CTRL.st1_rtab_check, `HPDT_CTRL.st1_rtab_check_hit,
               `HPDT_CTRL.wbuf_read_hit_i, `HPDT_CTRL.wbuf_write_ready_i,
               `HPDT_CTRL.flush_check_hit_i, `HPDT_CTRL.flush_alloc_ready_i,
               `HPDT_CTRL.st1_no_pend_trans,
               `HPDT_CTRL.st1_rtab_alloc, `HPDT_CTRL.st1_rtab_alloc_and_link,
               `HPDT_CTRL.st1_rtab_pop_try_commit, `HPDT_CTRL.st1_rtab_pop_try_rback,
               `HPDT_CTRL.st1_rsp_valid, `HPDT_CTRL.st1_rsp_aborted,
               `HPDT_CTRL.st2_mshr_alloc_q, `HPDT_CTRL.st2_dir_updt_q, `HPDT_CTRL.st2_flush_alloc_q,
               `HPDT_CTRL.mshr_empty_i, `HPDT_CTRL.wbuf_empty_i, `HPDT_CTRL.flush_empty_i,
               `HPDT_CTRL.refill_busy_i, `HPDT_CTRL.refill_req_valid_i,
               `HPDT_CTRL.uc_busy_i, `HPDT_CTRL.cmo_busy_i, `HPDT_CTRL.flush_busy_i);
      $display("[hpd-rtab] %s c=%0d h=%0d | rtab v=%b head=%b tail=%b ready=%b nodeps=%b fence=%b fence_only=%0d npt=%0d full=%0d empty=%0d popv=%0d popst=%0d popsel=%b popnext=%b popgnt=%b | alloc=%0d link=%0d free=%b chk=%0d chknl=%h chkhit=%b chktail=%b | pop_try=%0d ptr=%0d commit=%0d cptr=%0d rback=%0d rptr=%0d | missrdy=%0d refill=%0d rnl=%h rway=%0d wbsel=%b wbaddr=%h wbrd=%0d wbhit=%0d%0d%0d wbnr=%0d flrdy=%0d flack=%0d flnl=%h | mshr_v=%b refill_fsm=%0d miss_fsm=%0d rok=%0d",
               why, hpd_cycle, hart_id_i[7:0],
               `HPDT_RTAB.valid_q, `HPDT_RTAB.head_q, `HPDT_RTAB.tail_q, `HPDT_RTAB.ready,
               `HPDT_RTAB.nodeps, `HPDT_RTAB.fence_bv, `HPDT_RTAB.fence_only,
               `HPDT_RTAB.no_pend_trans_i, `HPDT_RTAB.full_o, `HPDT_RTAB.empty_o,
               `HPDT_RTAB.pop_try_valid_o, int'(`HPDT_RTAB.pop_try_state_q),
               `HPDT_RTAB.pop_sel, `HPDT_RTAB.pop_try_next_q, `HPDT_RTAB.pop_gnt,
               `HPDT_RTAB.alloc_i, `HPDT_RTAB.alloc_and_link_i, `HPDT_RTAB.free_alloc,
               `HPDT_RTAB.check_i, `HPDT_RTAB.check_nline_i, `HPDT_RTAB.check_hit,
               `HPDT_RTAB.match_check_tail,
               `HPDT_RTAB.pop_try_i, `HPDT_RTAB.pop_try_ptr_o,
               `HPDT_RTAB.pop_commit_i, `HPDT_RTAB.pop_commit_ptr_i,
               `HPDT_RTAB.pop_rback_i, `HPDT_RTAB.pop_rback_ptr_i,
               `HPDT_RTAB.miss_ready_i, `HPDT_RTAB.refill_i, `HPDT_RTAB.refill_nline_i,
               `HPDT_RTAB.refill_way_index_i,
               `HPDT_RTAB.wbuf_sel, `HPDT_RTAB.wbuf_addr_o, `HPDT_RTAB.wbuf_is_read_o,
               `HPDT_RTAB.wbuf_hit_open_i, `HPDT_RTAB.wbuf_hit_pend_i, `HPDT_RTAB.wbuf_hit_sent_i,
               `HPDT_RTAB.wbuf_not_ready_i, `HPDT_RTAB.flush_ready_i,
               `HPDT_RTAB.flush_ack_i, `HPDT_RTAB.flush_ack_nline_i,
               `HPDT_MH.hpdcache_mshr_i.mshr_valid_q, int'(`HPDT_MH.refill_fsm_q),
               int'(`HPDT_MH.miss_req_fsm_q), `HPDT_MH.refill_fifo_resp_meta_rok);
      for (int unsigned e = 0; e < HPD_RTAB_N; e++) begin
        $display("[hpd-rtab] %s c=%0d h=%0d |  e%0d v=%0d head=%0d tail=%0d next=%0d age=%0d op=%0d addr=%h nline=%h off=%h tid=%0d sid=%0d nrsp=%0d pi=%0d err=%0d uc=%0d wayf=%0d deps mh=%0d mf=%0d mr=%0d wm=%0d wh=%0d wnr=%0d du=%0d df=%0d fh=%0d fnr=%0d pt=%0d",
                 why, hpd_cycle, hart_id_i[7:0], e,
                 `HPDT_RTAB.valid_q[e], `HPDT_RTAB.head_q[e], `HPDT_RTAB.tail_q[e],
                 `HPDT_RTAB.next_q[e], hpd_age[e],
                 int'(`HPDT_RTAB.req_q[e].req.req.op), `HPDT_RTAB.addr[e], `HPDT_RTAB.nline[e],
                 `HPDT_RTAB.req_q[e].req.req.addr_offset,
                 `HPDT_RTAB.req_q[e].req.req.tid, `HPDT_RTAB.req_q[e].req.req.sid,
                 `HPDT_RTAB.req_q[e].req.req.need_rsp, `HPDT_RTAB.req_q[e].req.req.phys_indexed,
                 `HPDT_RTAB.error_q[e], `HPDT_RTAB.req_q[e].req.req.pma.uncacheable,
                 `HPDT_RTAB.req_q[e].way_fetch,
                 `HPDT_RTAB.deps_q[e].mshr_hit, `HPDT_RTAB.deps_q[e].mshr_full,
                 `HPDT_RTAB.deps_q[e].mshr_ready, `HPDT_RTAB.deps_q[e].write_miss,
                 `HPDT_RTAB.deps_q[e].wbuf_hit, `HPDT_RTAB.deps_q[e].wbuf_not_ready,
                 `HPDT_RTAB.deps_q[e].dir_unavailable, `HPDT_RTAB.deps_q[e].dir_fetch,
                 `HPDT_RTAB.deps_q[e].flush_hit, `HPDT_RTAB.deps_q[e].flush_not_ready,
                 `HPDT_RTAB.deps_q[e].pend_trans);
      end
      $display("[hpd-rtab] %s c=%0d h=%0d | ldu st=%0d vin=%0d tid=%0d vaddr=%h paddr=%h dtlb=%0d dreq=%0d gnt=%0d tagv=%0d kill=%0d rvld=%0d rid=%0d flush=%0d canc=%0d ldbuf v=%h f=%h last=%0d widx=%0d | adp hold=%0d abort_q=%0d pend=%0d held=%0d fire=%0d withdrawn=%0d hold_off=%h hold_tid=%0d | port1 v=%0d rdy=%0d abort=%0d off=%h tid=%0d tag=%h",
               why, hpd_cycle, hart_id_i[7:0],
               int'(`HPDT_LDU.state_q), `HPDT_LDU.valid_i, `HPDT_LDU.lsu_ctrl_i.trans_id,
               `HPDT_LDU.lsu_ctrl_i.vaddr, `HPDT_LDU.paddr_i, `HPDT_LDU.dtlb_hit_i,
               `HPDT_LDU.req_port_o.data_req, `HPDT_LDU.req_port_i.data_gnt,
               `HPDT_LDU.req_port_o.tag_valid, `HPDT_LDU.req_port_o.kill_req,
               `HPDT_LDU.req_port_i.data_rvalid, `HPDT_LDU.req_port_i.data_rid,
               `HPDT_LDU.flush_i, `HPDT_LDU.cancelled_request,
               `HPDT_LDU.ldbuf_valid_q, `HPDT_LDU.ldbuf_flushed_q, `HPDT_LDU.ldbuf_last_id_q,
               `HPDT_LDU.ldbuf_windex,
               `HPDT_LDA.hold_q, `HPDT_LDA.abort_q, `HPDT_LDA.req_pend_q, `HPDT_LDA.held,
               `HPDT_LDA.held_fire, `HPDT_LDA.req_withdrawn,
               `HPDT_LDA.hold_req_q.addr_offset, `HPDT_LDA.hold_req_q.tid,
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_valid[1],
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_ready[1],
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_abort[1],
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req[1].addr_offset,
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req[1].tid,
               gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_tag[1]);
    endfunction

    // compact one-liner used by the windowed events
    function automatic void hpd_rtab_brief(input string ev);
      $display("[hpd-ev] c=%0d h=%0d %s | rtab v=%b head=%b ready=%b fence=%b npt=%0d popv=%0d popst=%0d crv=%0d crr=%0d gntq=%b st1v=%0d st1op=%0d st1addr=%h st1tid=%0d st1sid=%0d st1rtab=%0d st1ptr=%0d abort=%0d mshr_v=%b wbuf_e=%0d refill_busy=%0d uc=%0d",
               hpd_cycle, hart_id_i[7:0], ev,
               `HPDT_RTAB.valid_q, `HPDT_RTAB.head_q, `HPDT_RTAB.ready, `HPDT_RTAB.fence_bv,
               `HPDT_RTAB.no_pend_trans_i, `HPDT_RTAB.pop_try_valid_o,
               int'(`HPDT_RTAB.pop_try_state_q),
               `HPDT_CTRL.core_req_valid_i, `HPDT_CTRL.core_req_ready_o, `HPDT_ARB.arb_req_gnt_q,
               `HPDT_CTRL.st1_req_valid_q, int'(`HPDT_CTRL.st1_req.req.op), `HPDT_CTRL.st1_req_addr,
               `HPDT_CTRL.st1_req.req.tid, `HPDT_CTRL.st1_req.req.sid, `HPDT_CTRL.st1_req.from_rtab,
               `HPDT_CTRL.st1_rtab_pop_try_ptr_q, `HPDT_CTRL.st1_req_abort,
               `HPDT_MH.hpdcache_mshr_i.mshr_valid_q, `HPDT_CTRL.wbuf_empty_i,
               `HPDT_CTRL.refill_busy_i, `HPDT_CTRL.uc_busy_i);
    endfunction

    always @(posedge clk_i) begin
      if (!rst_ni) begin
        for (int unsigned e = 0; e < HPD_RTAB_N; e++) hpd_age[e] = 0;
        hpd_idle_cnt = 0;
        hpd_leak_reported = 0;
      end else if (hpd_on) begin
        // ---- per-entry residency age (cycles since the entry became valid)
        for (int unsigned e = 0; e < HPD_RTAB_N; e++)
          hpd_age[e] = `HPDT_RTAB.valid_q[e] ? hpd_age[e] + 1 : 0;
        // ---- ticket from the [smt-stall] dump
        if (hpd_ticket != hpd_seen_ticket) begin
          hpd_seen_ticket = hpd_ticket;
          hpd_rtab_dump("ticket");
        end
        // ---- T20b level changes: rtab_full always, core_req valid/ready in the window
        if (!hpd_lvl_seen || `HPDT_RTAB.full_o != hpd_full_q ||
            (hpd_in_win && (`HPDT_CTRL.core_req_valid_i != hpd_crv_q ||
                            `HPDT_CTRL.core_req_ready_o != hpd_crr_q))) begin
          $display("[hpd-ev] c=%0d h=%0d LEVEL rtab_full=%0d crv=%0d crr=%0d rtab v=%b head=%b ready=%b | mshr_e=%0d wbuf_e=%0d refill_busy=%0d refill_req=%0d uc=%0d cmo=%0d fence=%0d st1v=%0d st2m=%0d st2d=%0d gntq=%b",
                   hpd_cycle, hart_id_i[7:0], `HPDT_RTAB.full_o,
                   `HPDT_CTRL.core_req_valid_i, `HPDT_CTRL.core_req_ready_o,
                   `HPDT_RTAB.valid_q, `HPDT_RTAB.head_q, `HPDT_RTAB.ready,
                   `HPDT_CTRL.mshr_empty_i, `HPDT_CTRL.wbuf_empty_i, `HPDT_CTRL.refill_busy_i,
                   `HPDT_CTRL.refill_req_valid_i, `HPDT_CTRL.uc_busy_i, `HPDT_CTRL.cmo_busy_i,
                   `HPDT_RTAB.fence_o, `HPDT_CTRL.st1_req_valid_q, `HPDT_CTRL.st2_mshr_alloc_q,
                   `HPDT_CTRL.st2_dir_updt_q, `HPDT_ARB.arb_req_gnt_q);
          hpd_lvl_seen = 1;
          hpd_full_q = `HPDT_RTAB.full_o;
          hpd_crv_q = `HPDT_CTRL.core_req_valid_i;
          hpd_crr_q = `HPDT_CTRL.core_req_ready_o;
        end
        // ---- T20b periodic dump while the replay table stays full
        if (`HPDT_RTAB.full_o) begin
          if (hpd_cycle - hpd_full_last >= HPD_FULL_PERIOD) begin
            hpd_full_last = hpd_cycle;
            hpd_rtab_dump("full-periodic");
          end
        end else begin
          hpd_full_last = hpd_cycle;
        end
        // ---- leak episode: parked entries with nothing left to release them
        if (hpd_idle) begin
          hpd_idle_cnt = hpd_idle_cnt + 1;
          if (hpd_idle_cnt == HPD_LEAK_IDLE && !hpd_leak_reported) begin
            hpd_leak_reported = 1;
            hpd_rtab_dump("LEAK");
            if (!hpd_leak_logged_once) begin
              hpd_leak_logged_once = 1;
              $display("[hpd-rtab] LEAK first episode at c=%0d h=%0d", hpd_cycle, hart_id_i[7:0]);
            end
          end
        end else begin
          hpd_idle_cnt = 0;
          if (!(|`HPDT_RTAB.valid_q)) hpd_leak_reported = 0;
        end
        // ---- windowed events
        if (hpd_in_win) begin
          if (`HPDT_CTRL.st1_rtab_alloc || `HPDT_CTRL.st1_rtab_alloc_and_link) begin
            $display("[hpd-ev] c=%0d h=%0d RTAB-ALLOC link=%0d entry=%b op=%0d addr=%h nline=%h tid=%0d sid=%0d nrsp=%0d uc=%0d rtab_src=%0d dirhit=%0d dirfetch=%0d mshrhit=%0d mshrfull=%0d missrdy=%0d victunav=%0d victdirty=%0d wbrdhit=%0d wbwrrdy=%0d npt=%0d deps mh=%0d mf=%0d mr=%0d wm=%0d wh=%0d wnr=%0d du=%0d df=%0d fh=%0d fnr=%0d pt=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_CTRL.st1_rtab_alloc_and_link,
                     `HPDT_RTAB.free_alloc, int'(`HPDT_CTRL.st1_req.req.op), `HPDT_CTRL.st1_req_addr,
                     `HPDT_CTRL.st1_req_nline, `HPDT_CTRL.st1_req.req.tid, `HPDT_CTRL.st1_req.req.sid,
                     `HPDT_CTRL.st1_req.req.need_rsp, `HPDT_CTRL.st1_req_is_uncacheable,
                     `HPDT_CTRL.st1_req.from_rtab, `HPDT_CTRL.st1_dir_hit, `HPDT_CTRL.st1_dir_hit_fetch,
                     `HPDT_CTRL.st1_mshr_hit_i, `HPDT_CTRL.st1_mshr_alloc_full_i,
                     `HPDT_CTRL.st1_mshr_alloc_ready_i, `HPDT_CTRL.st1_dir_victim_unavailable,
                     `HPDT_CTRL.st1_dir_victim_dirty, `HPDT_CTRL.wbuf_read_hit_i,
                     `HPDT_CTRL.wbuf_write_ready_i, `HPDT_CTRL.st1_no_pend_trans,
                     `HPDT_CTRL.st1_rtab_deps.mshr_hit, `HPDT_CTRL.st1_rtab_deps.mshr_full,
                     `HPDT_CTRL.st1_rtab_deps.mshr_ready, `HPDT_CTRL.st1_rtab_deps.write_miss,
                     `HPDT_CTRL.st1_rtab_deps.wbuf_hit, `HPDT_CTRL.st1_rtab_deps.wbuf_not_ready,
                     `HPDT_CTRL.st1_rtab_deps.dir_unavailable, `HPDT_CTRL.st1_rtab_deps.dir_fetch,
                     `HPDT_CTRL.st1_rtab_deps.flush_hit, `HPDT_CTRL.st1_rtab_deps.flush_not_ready,
                     `HPDT_CTRL.st1_rtab_deps.pend_trans);
            hpd_rtab_dump(`HPDT_CTRL.st1_rtab_alloc_and_link ? "alloc-link" : "alloc");
          end
          if (`HPDT_CTRL.st0_rtab_pop_try_valid && `HPDT_CTRL.st0_rtab_pop_try_ready) begin
            hpd_rtab_brief("RTAB-POP");
            hpd_rtab_dump("pop");
          end
          if (`HPDT_CTRL.st1_rtab_pop_try_commit) hpd_rtab_brief("RTAB-COMMIT");
          if (`HPDT_CTRL.st1_rtab_pop_try_rback) begin
            hpd_rtab_brief("RTAB-RBACK");
            hpd_rtab_dump("rback");
          end
          if (`HPDT_CTRL.core_req_abort_i)
            $display("[hpd-ev] c=%0d h=%0d ABORT st1v=%0d st1_abort=%0d gntq=%b abortv=%b st1 op=%0d addr=%h tid=%0d sid=%0d nrsp=%0d pi=%0d rtab=%0d rspv=%0d rspab=%0d | ldu st=%0d kill=%0d tagv=%0d | adp abort_q=%0d hold=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_CTRL.st1_req_valid_q, `HPDT_CTRL.st1_req_abort,
                     `HPDT_ARB.arb_req_gnt_q, `HPDT_ARB.core_req_abort,
                     int'(`HPDT_CTRL.st1_req.req.op), `HPDT_CTRL.st1_req_addr,
                     `HPDT_CTRL.st1_req.req.tid, `HPDT_CTRL.st1_req.req.sid,
                     `HPDT_CTRL.st1_req.req.need_rsp, `HPDT_CTRL.st1_req.req.phys_indexed,
                     `HPDT_CTRL.st1_req.from_rtab, `HPDT_CTRL.st1_rsp_valid, `HPDT_CTRL.st1_rsp_aborted,
                     int'(`HPDT_LDU.state_q), `HPDT_LDU.req_port_o.kill_req, `HPDT_LDU.req_port_o.tag_valid,
                     `HPDT_LDA.abort_q, `HPDT_LDA.hold_q);
          if (`HPDT_LDU.req_port_o.kill_req)
            $display("[hpd-ev] c=%0d h=%0d KILLREQ ldu st=%0d vin=%0d tid=%0d vaddr=%h paddr=%h dtlb=%0d flush=%0d canc=%0d ex=%0d exptw=%0d dreq=%0d gnt=%0d tagv=%0d ldbuf v=%h f=%h last=%0d | gntq=%b st1v=%0d st1pi=%0d st1rtab=%0d st1tid=%0d st1sid=%0d st1addr=%h -> abort=%0d",
                     hpd_cycle, hart_id_i[7:0], int'(`HPDT_LDU.state_q), `HPDT_LDU.valid_i,
                     `HPDT_LDU.lsu_ctrl_i.trans_id, `HPDT_LDU.lsu_ctrl_i.vaddr, `HPDT_LDU.paddr_i,
                     `HPDT_LDU.dtlb_hit_i, `HPDT_LDU.flush_i, `HPDT_LDU.cancelled_request,
                     `HPDT_LDU.ex_i.valid, `HPDT_LDU.ex_ptw_i,
                     `HPDT_LDU.req_port_o.data_req, `HPDT_LDU.req_port_i.data_gnt,
                     `HPDT_LDU.req_port_o.tag_valid, `HPDT_LDU.ldbuf_valid_q, `HPDT_LDU.ldbuf_flushed_q,
                     `HPDT_LDU.ldbuf_last_id_q, `HPDT_ARB.arb_req_gnt_q, `HPDT_CTRL.st1_req_valid_q,
                     `HPDT_CTRL.st1_req.req.phys_indexed, `HPDT_CTRL.st1_req.from_rtab,
                     `HPDT_CTRL.st1_req.req.tid, `HPDT_CTRL.st1_req.req.sid, `HPDT_CTRL.st1_req_addr,
                     `HPDT_CTRL.st1_req_abort);
          if (`HPDT_LDA.req_withdrawn || `HPDT_LDA.held_fire || `HPDT_LDA.abort_q)
            $display("[hpd-ev] c=%0d h=%0d HELD withdrawn=%0d held=%0d fire=%0d abort_q=%0d hold_q=%0d pend=%0d dreq=%0d rdy=%0d gntd=%b hold off=%h tid=%0d | ldu st=%0d flush=%0d canc=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_LDA.req_withdrawn, `HPDT_LDA.held,
                     `HPDT_LDA.held_fire, `HPDT_LDA.abort_q, `HPDT_LDA.hold_q, `HPDT_LDA.req_pend_q,
                     `HPDT_LDU.req_port_o.data_req,
                     gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_req_ready[1],
                     `HPDT_ARB.arb_req_gnt_d, `HPDT_LDA.hold_req_q.addr_offset, `HPDT_LDA.hold_req_q.tid,
                     int'(`HPDT_LDU.state_q), `HPDT_LDU.flush_i, `HPDT_LDU.cancelled_request);
          if (`HPDT_LDU.req_port_o.data_req && `HPDT_LDU.req_port_i.data_gnt)
            $display("[hpd-ev] c=%0d h=%0d LDU-GNT tid=%0d id=%0d vaddr=%h st=%0d ldbuf_v=%h",
                     hpd_cycle, hart_id_i[7:0], `HPDT_LDU.lsu_ctrl_i.trans_id, `HPDT_LDU.req_port_o.data_id,
                     `HPDT_LDU.lsu_ctrl_i.vaddr, int'(`HPDT_LDU.state_q), `HPDT_LDU.ldbuf_valid_q);
          if (`HPDT_LDU.req_port_o.tag_valid)
            $display("[hpd-ev] c=%0d h=%0d LDU-TAG tag=%h kill=%0d st=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_LDU.req_port_o.address_tag,
                     `HPDT_LDU.req_port_o.kill_req, int'(`HPDT_LDU.state_q));
          if (`HPDT_LDU.req_port_i.data_rvalid)
            $display("[hpd-ev] c=%0d h=%0d LDU-RSP rid=%0d ldbuf_v=%h f=%h sid_rsp=%0d aborted=%0d err=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_LDU.req_port_i.data_rid, `HPDT_LDU.ldbuf_valid_q,
                     `HPDT_LDU.ldbuf_flushed_q,
                     gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].sid,
                     gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].aborted,
                     gen_cache_hpd.i_cache_subsystem.i_dcache.dcache_rsp[1].error);
          // every accepted st0 request (any port) with its arbiter view
          if (`HPDT_CTRL.core_req_valid_i && `HPDT_CTRL.core_req_ready_o)
            $display("[hpd-ev] c=%0d h=%0d ST0-ACCEPT gnt=%b op=%0d off=%h tid=%0d sid=%0d nrsp=%0d pi=%0d uc=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_ARB.arb_req_gnt_d, int'(`HPDT_CTRL.core_req_i.op),
                     `HPDT_CTRL.core_req_i.addr_offset, `HPDT_CTRL.core_req_i.tid, `HPDT_CTRL.core_req_i.sid,
                     `HPDT_CTRL.core_req_i.need_rsp, `HPDT_CTRL.core_req_i.phys_indexed,
                     `HPDT_CTRL.core_req_i.pma.uncacheable);
          if (`HPDT_CTRL.refill_updt_rtab_i)
            hpd_rtab_brief("REFILL-UPDT");
          if (`HPDT_MH.mshr_ack)
            $display("[hpd-ev] c=%0d h=%0d MSHR-ACK r_id=%0d set=%0d way=%0d tag=%h cset=%0d sid=%0d tid=%0d nrsp=%0d mshr_v=%b",
                     hpd_cycle, hart_id_i[7:0], `HPDT_MH.refill_fifo_resp_meta_rdata.r_id,
                     `HPDT_MH.mshr_ack_set, `HPDT_MH.mshr_ack_way, `HPDT_MH.mshr_ack_cache_tag,
                     `HPDT_MH.mshr_ack_cache_set, `HPDT_MH.mshr_ack_src_id, `HPDT_MH.mshr_ack_req_id,
                     `HPDT_MH.mshr_ack_need_rsp, `HPDT_MH.hpdcache_mshr_i.mshr_valid_q);
          if (`HPDT.miss_mshr_alloc)
            $display("[hpd-ev] c=%0d h=%0d MSHR-ALLOC nline=%h sid=%0d tid=%0d nrsp=%0d mshr_v=%b",
                     hpd_cycle, hart_id_i[7:0], `HPDT.miss_mshr_alloc_nline, `HPDT.miss_mshr_alloc_sid,
                     `HPDT.miss_mshr_alloc_tid, `HPDT.miss_mshr_alloc_need_rsp,
                     `HPDT_MH.hpdcache_mshr_i.mshr_valid_q);
          if (`HPDT_CTRL.flush_ack_i)
            $display("[hpd-ev] c=%0d h=%0d FLUSH-ACK nline=%h", hpd_cycle, hart_id_i[7:0],
                     `HPDT_CTRL.flush_ack_nline_i);
          if (`HPDT_CTRL.uc_req_valid_o || `HPDT_CTRL.cmo_req_valid_o)
            $display("[hpd-ev] c=%0d h=%0d HANDOFF uc=%0d cmo=%0d op=%0d addr=%h tid=%0d sid=%0d nrsp=%0d rtab=%0d uc_busy=%0d cmo_busy=%0d",
                     hpd_cycle, hart_id_i[7:0], `HPDT_CTRL.uc_req_valid_o, `HPDT_CTRL.cmo_req_valid_o,
                     int'(`HPDT_CTRL.st1_req.req.op), `HPDT_CTRL.st1_req_addr, `HPDT_CTRL.st1_req.req.tid,
                     `HPDT_CTRL.st1_req.req.sid, `HPDT_CTRL.st1_req.req.need_rsp, `HPDT_CTRL.st1_req.from_rtab,
                     `HPDT_CTRL.uc_busy_i, `HPDT_CTRL.cmo_busy_i);
        end
      end
    end
`undef HPDT
`undef HPDT_CTRL
`undef HPDT_RTAB
`undef HPDT_ARB
`undef HPDT_MH
`undef HPDT_LDA
`undef HPDT_LDU
  end

  // T20 diagnostic probe (+win_trace): the whole fetch-window lifecycle around
  // a mispredict, for the hart-5 wrong-path commit of ooocoh-t19-server-osbi-48M
  // (window 0x800086e8 delivered after the taken `beqz` at 0x8001b690). One
  // [win] line per event inside [+win_lo, +win_hi] (default 38.76M-38.78M),
  // optionally filtered to one global hart (+win_hart=N, N = hart_id_i +
  // smt_active_hart; default: every hart of the core):
  //   KILL  controller flush_if / flush_unissued / flush_id, resolved_branch,
  //         the frontend's is_mispredict / kill_s1 / kill_s2 / bp_fire / replay,
  //         the redirect encoder (arch_src/arch_pc), NPC, FTQ head, token want
  //         state, bp_pend filter, IQ flush, cf_hold
  //   REQ   I$ request accepted (vaddr, token, demand/pf)
  //   RSP   I$ response (vaddr, token, take, kill_drop, want state)
  //   LBUF  loop-buffer inject (vaddr, take)
  //   PUSH  realigner window presented to the instruction queue: source,
  //         window vaddr, leftover carry, per-slot pc/instr/valid/consumed,
  //         cf_type, predict_address, the IQ FIFOs written, replay
  //   FTQ   push (vaddr, taken) / pop (head) / flush (expression)
  //   POP   instruction queue -> ID handoff per port (pc, hart, insn)
  //   ISS   ID -> issue handshake per port (pc, hart, scoreboard issue ptr)
  //   PCBANK (T20b, NrHarts > 1) every g6lc_smt_pc_bank write source: retire
  //         ports (hart, next pc), primary/secondary redirect (hart, pc, the
  //         set_pc/eret/ex/mem_replay cause), the switch (outgoing hart,
  //         npc_live / forced-drain alt value), smt_pc_restore with the
  //         npc_restore value, and both bank entries after the write.
  // T20b: `+fe_trace` / `+fe_lo` / `+fe_hi` are aliases of `+win_trace` /
  // `+win_lo` / `+win_hi`; `+fe_core=N` restricts the probe to core N
  // (hart_id_i / NrHarts; default -1 = every core).
  // Read-only, sim-only (hierarchical reads into i_frontend / the IQ).
  bit win_trace;
  int unsigned win_lo, win_hi, win_cycle;
  int win_hart, win_core;
  initial begin
    win_trace = $test$plusargs("win_trace") || $test$plusargs("fe_trace");
    win_lo = 38760000;
    win_hi = 38780000;
    win_hart = -1;
    win_core = -1;
    void'($value$plusargs("win_lo=%0d", win_lo));
    void'($value$plusargs("win_hi=%0d", win_hi));
    void'($value$plusargs("fe_lo=%0d", win_lo));
    void'($value$plusargs("fe_hi=%0d", win_hi));
    void'($value$plusargs("win_hart=%0d", win_hart));
    void'($value$plusargs("fe_core=%0d", win_core));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) win_cycle = 0;
    else win_cycle = win_cycle + 1;
  end
`ifdef G6LC_FETCH_B
  if (CVA6Cfg.FtqDepth != 0) begin : gen_win_trace
    localparam int unsigned WIN_NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
    logic win_on, win_cf_hold_q;
    int unsigned win_ghart;
    assign win_ghart = int'(hart_id_i[7:0]) + int'(smt_active_hart);
    assign win_on = win_trace && rst_ni && win_cycle >= win_lo && win_cycle <= win_hi &&
                    (win_hart < 0 || win_ghart == win_hart) &&
                    (win_core < 0 || (int'(hart_id_i[7:0]) / int'(WIN_NH)) == win_core);
    assign win_cf_hold_q = i_frontend.gen_ftq.cf_hold_q;
    always @(posedge clk_i) begin
      if (win_on) begin
        // ---- kills / redirects
        if (flush_ctrl_if || flush_unissued_instr_ctrl_id || flush_ctrl_id ||
            resolved_branch.valid || i_frontend.is_mispredict || i_frontend.kill_s1 ||
            i_frontend.kill_s2 || i_frontend.bp_fire || i_frontend.replay ||
            i_frontend.replay_q || i_frontend.arch_valid || smt_switch || smt_pc_restore) begin
          $display("[win] c=%0d h=%0d KILL fif=%0d uniss=%0d fid=%0d | rb v=%0d misp=%0d taken=%0d cf=%0d pc=%h tgt=%h rbh=%0d tid=%0d | ctrl_misp=%0d fe_misp=%0d res_act=%0d outranked=%0d k1=%0d k2=%0d bpf=%0d fl=%0d rp=%0d rpq=%0d rpaddr=%h | arch v=%0d src=%0d pc=%h step=%0d reseed=%0d | npc_q=%h npc_d=%h faddr=%h | ftq hv=%0d head=%h push=%0d pv=%h pop=%0d cfhold=%0d | want v=%0d tok=%0d addr=%h hart=%0d pf=%0d reqtok=%0d | bp_pend=%0d tgt=%h ttl=%0d | redir pend=%0d pc=%h infl=%0d ia=%h | iqflush=%0d iqrdy=%0d una=%0d lov=%0d lopc=%h | ex=%0d eret=%0d spc=%0d sw=%0d restore=%0d act=%0d | sb iptr=%0d cptr=%0d",
                   win_cycle, win_ghart, flush_ctrl_if, flush_unissued_instr_ctrl_id, flush_ctrl_id,
                   resolved_branch.valid, resolved_branch.is_mispredict, resolved_branch.is_taken,
                   int'(resolved_branch.cf_type), resolved_branch.pc, resolved_branch.target_address,
                   resolved_branch.hart_id, resolved_branch.trans_id,
                   resolved_branch_ctrl.is_mispredict, i_frontend.is_mispredict,
                   i_frontend.resolution_for_active, i_frontend.misp_outranked,
                   i_frontend.kill_s1, i_frontend.kill_s2, i_frontend.bp_fire, i_frontend.flush_i,
                   i_frontend.replay, i_frontend.replay_q, i_frontend.replay_addr_q,
                   i_frontend.arch_valid, int'(i_frontend.arch_src), i_frontend.arch_pc,
                   i_frontend.arch_step, i_frontend.arch_reseed,
                   i_frontend.npc_q, i_frontend.npc_d, i_frontend.fetch_address,
                   i_frontend.ftq_head_valid, i_frontend.ftq_head_vaddr, i_frontend.ftq_push,
                   i_frontend.ftq_push_vaddr, i_frontend.ftq_pop, win_cf_hold_q,
                   i_frontend.want_valid_q, i_frontend.want_token_q, i_frontend.want_addr_q,
                   i_frontend.want_hart_q, i_frontend.want_pf_q, i_frontend.req_token_q,
                   i_frontend.bp_pend_q, i_frontend.bp_tgt_q, i_frontend.bp_misp_ttl_q,
                   i_frontend.redirect_pend_q, i_frontend.redirect_pc_q, i_frontend.inflight_q,
                   i_frontend.inflight_addr_q,
                   i_frontend.i_instr_queue.flush_i, i_frontend.instr_queue_ready,
                   i_frontend.serving_unaligned, i_frontend.leftover_valid, i_frontend.leftover_pc,
                   ex_commit.valid, eret, set_pc_ctrl_pcgen, smt_switch, smt_pc_restore,
                   smt_active_hart,
                   issue_stage_i.i_scoreboard.issue_pointer_q,
                   issue_stage_i.i_scoreboard.commit_pointer_q[0]);
        end
        // ---- I$ request accepted
        if (icache_dreq_if_cache.req && icache_dreq_cache_if.ready)
          $display("[win] c=%0d h=%0d REQ va=%h tok=%0d demand=%0d pf=%0d spec=%0d k1=%0d k2=%0d ftq_head=%h hv=%0d npc_q=%h",
                   win_cycle, win_ghart, icache_dreq_if_cache.vaddr, icache_dreq_if_cache.token,
                   i_frontend.demand_req, i_frontend.pf_req, icache_dreq_if_cache.spec,
                   i_frontend.kill_s1, i_frontend.kill_s2, i_frontend.ftq_head_vaddr,
                   i_frontend.ftq_head_valid, i_frontend.npc_q);
        // ---- I$ response
        if (icache_dreq_cache_if.valid)
          $display("[win] c=%0d h=%0d RSP va=%h tok=%0d take=%0d kdrop=%0d want v=%0d tok=%0d addr=%h hart=%0d pf=%0d | bp_pend=%0d tgt=%h | k1=%0d k2=%0d fl=%0d mp=%0d bpf=%0d rpq=%0d | ex=%0d",
                   win_cycle, win_ghart, icache_dreq_cache_if.vaddr, icache_dreq_cache_if.token,
                   i_frontend.icache_take, i_frontend.kill_drop,
                   i_frontend.want_valid_q, i_frontend.want_token_q, i_frontend.want_addr_q,
                   i_frontend.want_hart_q, i_frontend.want_pf_q,
                   i_frontend.bp_pend_q, i_frontend.bp_tgt_q,
                   i_frontend.kill_s1, i_frontend.kill_s2, i_frontend.flush_i,
                   i_frontend.is_mispredict, i_frontend.bp_fire, i_frontend.replay_q,
                   icache_dreq_cache_if.ex.valid);
        // ---- loop-buffer inject
        if (i_frontend.lbuf_inject)
          $display("[win] c=%0d h=%0d LBUF va=%h take=%0d hit=%0d bp_pend=%0d tgt=%h fl=%0d mp=%0d k1=%0d k2=%0d",
                   win_cycle, win_ghart, i_frontend.ftq_head_vaddr, i_frontend.icache_take,
                   i_frontend.lbuf_hit, i_frontend.bp_pend_q, i_frontend.bp_tgt_q,
                   i_frontend.flush_i, i_frontend.is_mispredict, i_frontend.kill_s1,
                   i_frontend.kill_s2);
        // ---- window presented to the instruction queue (realigner valid)
        if (i_frontend.icache_take) begin
          $display("[win] c=%0d h=%0d PUSH src=%s va=%h una=%0d lopc=%h vmask=%b cons=%b iqpush=%b isq=%b dsq=%b full=%b rdy=%0d replay=%0d rpaddr=%h cf=[%0d %0d %0d %0d] pred=%h fl=%0d mp=%0d k1=%0d k2=%0d bpf=%0d stamp_hart=%0d",
                   win_cycle, win_ghart,
                   icache_dreq_cache_if.valid ? "ICACHE" : "LBUF",
                   i_frontend.realigner_vaddr, i_frontend.serving_unaligned, i_frontend.leftover_pc,
                   i_frontend.instruction_valid, i_frontend.instr_queue_consumed,
                   i_frontend.i_instr_queue.push_instr_fifo, i_frontend.i_instr_queue.idx_is_q,
                   i_frontend.i_instr_queue.idx_ds_q, i_frontend.i_instr_queue.instr_queue_full,
                   i_frontend.instr_queue_ready, i_frontend.replay, i_frontend.replay_addr,
                   int'(i_frontend.cf_type[0]), int'(i_frontend.cf_type[1 % CVA6Cfg.INSTR_PER_FETCH]),
                   int'(i_frontend.cf_type[2 % CVA6Cfg.INSTR_PER_FETCH]),
                   int'(i_frontend.cf_type[3 % CVA6Cfg.INSTR_PER_FETCH]),
                   i_frontend.predict_address, i_frontend.flush_i, i_frontend.is_mispredict,
                   i_frontend.kill_s1, i_frontend.kill_s2, i_frontend.bp_fire, smt_active_hart);
          for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++)
            if (i_frontend.instruction_valid_raw[s])
              $display("[win] c=%0d h=%0d PUSH  slot%0d pc=%h insn=%h v=%0d cons=%0d cf=%0d bht v=%0d t=%0d",
                       win_cycle, win_ghart, s, i_frontend.addr[s], i_frontend.instr[s],
                       i_frontend.instruction_valid[s], i_frontend.instr_queue_consumed[s],
                       int'(i_frontend.cf_type[s]), i_frontend.bht_prediction_shifted[s].valid,
                       i_frontend.bht_prediction_shifted[s].taken);
        end
        // ---- FTQ push / pop / flush
        if (i_frontend.ftq_push || i_frontend.ftq_pop ||
            (i_frontend.flush_i | i_frontend.is_mispredict | i_frontend.bp_fire |
             i_frontend.replay_q | i_frontend.smt_restore_flush))
          $display("[win] c=%0d h=%0d FTQ push=%0d pv=%h taken=%0d tgt=%h pop=%0d head=%h hv=%0d flush=%0d (fl=%0d mp=%0d bpf=%0d rpq=%0d rst=%0d) demand=%0d dfire=%0d lbuf=%0d if_ready=%0d cfhold=%0d full=%0d",
                   win_cycle, win_ghart, i_frontend.ftq_push, i_frontend.ftq_push_vaddr,
                   i_frontend.bp_fire, i_frontend.predict_address, i_frontend.ftq_pop,
                   i_frontend.ftq_head_vaddr, i_frontend.ftq_head_valid,
                   (i_frontend.flush_i | i_frontend.is_mispredict | i_frontend.bp_fire |
                    i_frontend.replay_q | i_frontend.smt_restore_flush),
                   i_frontend.flush_i, i_frontend.is_mispredict, i_frontend.bp_fire,
                   i_frontend.replay_q, i_frontend.smt_restore_flush,
                   i_frontend.demand_req, i_frontend.demand_fire, i_frontend.lbuf_consume,
                   i_frontend.if_ready, win_cf_hold_q, i_frontend.ftq_full);
        // ---- IQ -> ID
        for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          if (fetch_valid_if_id[p] && fetch_ready_id_if[p])
            $display("[win] c=%0d h=%0d POP port=%0d pc=%h insn=%h hart=%0d cf=%0d pred=%h",
                     win_cycle, win_ghart, p, fetch_entry_if_id[p].address,
                     fetch_entry_if_id[p].instruction, fetch_entry_if_id[p].hart_id,
                     int'(fetch_entry_if_id[p].branch_predict.cf),
                     fetch_entry_if_id[p].branch_predict.predict_address);
        // ---- ID -> issue
        for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++)
          if (issue_entry_valid_id_issue[p] && issue_instr_issue_id[p])
            $display("[win] c=%0d h=%0d ISS port=%0d pc=%h hart=%0d fu=%0d op=%0d iptr=%0d",
                     win_cycle, win_ghart, p, issue_entry_id_issue[p].pc,
                     issue_entry_id_issue[p].hart_id, int'(issue_entry_id_issue[p].fu),
                     int'(issue_entry_id_issue[p].op),
                     issue_stage_i.i_scoreboard.issue_pointer_q);
        // ---- commit side: every retire / drop / replay-refetch, and every
        //      memory-order violation the LSQ reports (the suspected path for
        //      defect 1: a wrong-path load cancelled by the mispredict that
        //      also carries the mem-order `replay` flag is honoured at commit
        //      as a refetch of its own -- wrong-path -- PC).
        for (int unsigned p = 0; p < CVA6Cfg.NrCommitPorts; p++)
          if (commit_ack[p])
            $display("[win] c=%0d h=%0d CMT port=%0d pc=%h tid=%0d hart=%0d fu=%0d drop=%0d replay=%0d flush_commit=%0d mem_replay_pc=%0d spc=%0d",
                     win_cycle, win_ghart, p, commit_instr_id_commit[p].pc,
                     commit_instr_id_commit[p].trans_id, commit_instr_id_commit[p].hart_id,
                     int'(commit_instr_id_commit[p].fu), commit_drop_id_commit[p],
                     commit_replay_id_commit[p], flush_commit, mem_replay_pc_ctrl_pcgen,
                     set_pc_ctrl_pcgen);
        if (issue_stage_i.i_scoreboard.mem_violation_i)
          $display("[win] c=%0d h=%0d MEMVIOL tid=%0d pc=%h issued=%0d cancelled=%0d replay=%0d cmask=%0d bmiss=%0d sb iptr=%0d cptr=%0d",
                   win_cycle, win_ghart, issue_stage_i.i_scoreboard.mem_violation_id_i,
                   issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.mem_violation_id_i].sbe.pc,
                   issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.mem_violation_id_i].issued,
                   issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.mem_violation_id_i].cancelled,
                   issue_stage_i.i_scoreboard.mem_q[issue_stage_i.i_scoreboard.mem_violation_id_i].replay,
                   issue_stage_i.i_scoreboard.cancelled_mask_o[issue_stage_i.i_scoreboard.mem_violation_id_i],
                   issue_stage_i.i_scoreboard.bmiss,
                   issue_stage_i.i_scoreboard.issue_pointer_q,
                   issue_stage_i.i_scoreboard.commit_pointer_q[0]);
        if (resolved_branch.valid && resolved_branch.is_mispredict) begin
          // the scoreboard window the cancel loop walks, with each entry's state
          for (int unsigned s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
            if (issue_stage_i.i_scoreboard.mem_q[s].issued)
              $display("[win] c=%0d h=%0d BMISS-SB slot=%0d pc=%h fu=%0d issued=1 valid=%0d cancelled=%0d replay=%0d cmask=%0d hart=%0d",
                       win_cycle, win_ghart, s, issue_stage_i.i_scoreboard.mem_q[s].sbe.pc,
                       int'(issue_stage_i.i_scoreboard.mem_q[s].sbe.fu),
                       issue_stage_i.i_scoreboard.mem_q[s].sbe.valid,
                       issue_stage_i.i_scoreboard.mem_q[s].cancelled,
                       issue_stage_i.i_scoreboard.mem_q[s].replay,
                       issue_stage_i.i_scoreboard.cancelled_mask_o[s],
                       issue_stage_i.i_scoreboard.mem_q[s].sbe.hart_id);
        end
      end
    end
    // ---- T20b: PC-bank writes (g6lc_smt_pc_bank), SMT targets only. One line
    //      per cycle in which any bank write source is active, plus the
    //      restore beat; the bank entries printed are the post-write values
    //      (sampled on the next edge, i.e. "after" the listed write).
    if (CVA6Cfg.NrHarts > 1) begin : gen_win_pcbank
      always @(posedge clk_i) begin
        if (win_on && ((|smt_retire_valid) || smt_arch_redirect_valid || smt_arch_redirect2_valid ||
                       smt_switch || smt_pc_restore || smt_drain_forced)) begin
          $display("[win] c=%0d h=%0d PCBANK retire v=%b h0=%0d pc0=%h h1=%0d pc1=%h | redir v=%0d h=%0d pc=%h (spc=%0d halt=%0d mem_replay=%0d eret=%0d ex=%0d pc_commit=%h) | redir2 v=%0d h=%0d pc=%h | switch=%0d out=%0d live_v=%0d live=%h alt_v=%0d alt=%h | restore=%0d npc_restore=%h act=%0d | bank0=%h bank1=%h",
                   win_cycle, win_ghart, smt_retire_valid,
                   smt_retire_hart[0], smt_retire_pc[0],
                   smt_retire_hart[CVA6Cfg.NrCommitPorts > 1 ? 1 : 0],
                   smt_retire_pc[CVA6Cfg.NrCommitPorts > 1 ? 1 : 0],
                   smt_arch_redirect_valid, smt_arch_redirect_hart, smt_arch_redirect_pc,
                   set_pc_ctrl_pcgen, halt_ctrl, mem_replay_pc_ctrl_pcgen, eret, ex_commit.valid,
                   pc_commit,
                   smt_arch_redirect2_valid, smt_arch_redirect2_hart, smt_arch_redirect2_pc,
                   smt_switch, smt_outgoing_hart, smt_restart_valid, smt_restart_pc,
                   smt_drain_forced, smt_drain_force_pc,
                   smt_pc_restore, smt_npc_restore, smt_active_hart,
                   i_smt_pc_bank.gen_banked.npc_bank_q[0], i_smt_pc_bank.gen_banked.npc_bank_q[1]);
        end
      end
    end
    // ---- T21e: RAS events (TAGE fabric, RASDepth != 0): every speculative
    //      push / pop at consume and every restore (mispredict: own effect
    //      re-applied; clear: frontier context), with the fetch bank's
    //      {tos, cnt, top} before and the restore payload. Inside the fe
    //      window only.
    if (CVA6Cfg.FtqDepth != 0 && CVA6Cfg.BPType == config_pkg::TAGE_LITE &&
        CVA6Cfg.RASDepth != 0) begin : gen_win_ras
      always @(posedge clk_i) begin
        if (win_on && (i_frontend.ras_push || i_frontend.ras_pop || i_frontend.ras_restore)) begin
          $display("[win] c=%0d h=%0d RAS push=%0d ra=%h pop=%0d pred_v=%0d pred=%h | restore=%0d own=%0d hart=%0d tos=%0d cnt=%0d top=%h repop=%0d repush=%0d repush_ra=%h | bank tos=%0d cnt=%0d",
                   win_cycle, win_ghart, i_frontend.ras_push, i_frontend.ras_update,
                   i_frontend.ras_pop, i_frontend.ras_predict.valid, i_frontend.ras_predict.ra,
                   i_frontend.ras_restore, i_frontend.ras_restore_own, int'(i_frontend.ras_restore_hart),
                   int'(i_frontend.ras_restore_tos), int'(i_frontend.ras_restore_cnt), i_frontend.ras_restore_top,
                   i_frontend.gen_ras.i_ras.restore_pop_i, i_frontend.gen_ras.i_ras.restore_push_i,
                   i_frontend.gen_ras.i_ras.restore_push_ra_i,
                   int'(i_frontend.ras_snap_tos), int'(i_frontend.ras_snap_cnt));
        end
      end
    end
    // ---- T21: direction-override chain per fetch window (TAGE fabric only):
    //      which stage of TAGE -> loop -> statistical corrector produced the
    //      direction each conditional-branch slot saw. Rows are indexed by the
    //      slot's own address bits, as gen_prediction_shifted does.
    if (CVA6Cfg.FtqDepth != 0 && CVA6Cfg.BPType == config_pkg::TAGE_LITE) begin : gen_win_bp_chain
      localparam int unsigned BPC_W = (CVA6Cfg.INSTR_PER_FETCH > 1) ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
      int unsigned bpc_row;
      always @(posedge clk_i) begin
        if (win_on && i_frontend.icache_take) begin
          for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
            if (i_frontend.instruction_valid_raw[s] && i_frontend.is_branch[s]) begin
              bpc_row = int'(i_frontend.addr[s][BPC_W:1]) % CVA6Cfg.INSTR_PER_FETCH;
              $display("[win] c=%0d h=%0d BPCHAIN slot%0d pc=%h vpc=%h row=%0d tage v=%0d t=%0d | loop v=%0d t=%0d | sc v=%0d t=%0d | used v=%0d t=%0d cf=%0d",
                       win_cycle, win_ghart, s, i_frontend.addr[s], i_frontend.vpc_bht, bpc_row,
                       i_frontend.gen_tage_lite.i_bp_top.tage_pred[bpc_row].valid,
                       i_frontend.gen_tage_lite.i_bp_top.tage_pred[bpc_row].taken,
                       i_frontend.gen_tage_lite.i_bp_top.loop_pred[bpc_row].valid,
                       i_frontend.gen_tage_lite.i_bp_top.loop_pred[bpc_row].taken,
                       i_frontend.gen_tage_lite.i_bp_top.sc_pred[bpc_row].valid,
                       i_frontend.gen_tage_lite.i_bp_top.sc_pred[bpc_row].taken,
                       i_frontend.bht_prediction_shifted[s].valid,
                       i_frontend.bht_prediction_shifted[s].taken, int'(i_frontend.cf_type[s]));
            end
          end
        end
      end
    end
    // ---- T21: BP checkpoint association (TAGE fabric with BPCkptDepth != 0).
    //      Checkpoints are allocated per consumed CF slot at predict time and
    //      addressed by the index the instruction carries back at resolve. A
    //      shadow of the slot pc behind every allocated entry checks that each
    //      resolve/restore reads its own snapshot (`mismatch` must stay 0 --
    //      the order-paired FIFO this replaced mismatched on every OoO
    //      resolution), and counts the fallbacks: a resolve whose entry is
    //      gone (`dead`: cleared by a switch/replay flush or reclaimed by an
    //      older mispredict), a restore without a live entry, and windows
    //      that were not checkpointed because the bank was full (`refused`).
    //      `+ckpt_trace` prints the events inside the `+fe_lo/+fe_hi` window;
    //      `[ckpt] final` always prints the totals per core.
    if (CVA6Cfg.BPType == config_pkg::TAGE_LITE && CVA6Cfg.BPCkptDepth != 0 &&
        CVA6Cfg.RASDepth != 0) begin : gen_ckpt_trace
      localparam int unsigned CK_NH = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
      localparam int unsigned CK_D  = CVA6Cfg.BPCkptDepth;
      bit ckpt_trace;
      initial ckpt_trace = $test$plusargs("ckpt_trace");
      logic [63:0] ck_shadow_pc [CK_NH][CK_D];
      int unsigned ck_allocs, ck_pops, ck_pop_mismatch, ck_pop_dead, ck_restores,
                   ck_restore_mismatch, ck_restore_dropped, ck_refused, ck_clears;
      // mispredict census by resolved cf class (Branch / Return / JumpR+Jump)
      int unsigned ck_misp_br, ck_misp_ret, ck_misp_jmp, ck_res_br, ck_res_ret, ck_res_jmp;
      int unsigned ck_psel, ck_csel, ck_idx;
      initial begin
        ck_allocs = 0; ck_pops = 0; ck_pop_mismatch = 0; ck_pop_dead = 0; ck_restores = 0;
        ck_restore_mismatch = 0; ck_restore_dropped = 0; ck_refused = 0; ck_clears = 0;
        ck_misp_br = 0; ck_misp_ret = 0; ck_misp_jmp = 0; ck_res_br = 0; ck_res_ret = 0; ck_res_jmp = 0;
      end
      always @(posedge clk_i) begin
        if (rst_ni) begin
          if (resolved_branch.valid) begin
            case (resolved_branch.cf_type)
              ariane_pkg::Branch: begin ck_res_br++;  if (resolved_branch.is_mispredict) ck_misp_br++;  end
              ariane_pkg::Return: begin ck_res_ret++; if (resolved_branch.is_mispredict) ck_misp_ret++; end
              default:            begin ck_res_jmp++; if (resolved_branch.is_mispredict) ck_misp_jmp++; end
            endcase
          end
          ck_psel = int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.psel);
          ck_csel = int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.csel);
          ck_idx  = int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.pop_slot);
          if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.clear_i ||
              i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.flush_i) ck_clears++;
          // resolve side
          if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.restore_i) begin
            ck_restores++;
            if (!i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.restore_valid_o) begin
              ck_restore_dropped++;
              if (ckpt_trace && win_cycle >= win_lo && win_cycle <= win_hi)
                $display("[ckpt] c=%0d core=%0d RESTORE-DROPPED pc=%h ckpt_v=%0d idx=%0d span=%0d",
                         win_cycle, int'(hart_id_i[7:0]) / int'(CK_NH), resolved_branch.pc,
                         resolved_branch.ckpt_v, ck_idx,
                         int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.span[ck_csel]));
            end else if (ck_shadow_pc[ck_csel][ck_idx] != 64'(resolved_branch.pc)) begin
              ck_restore_mismatch++;
              if (ckpt_trace && win_cycle >= win_lo && win_cycle <= win_hi)
                $display("[ckpt] c=%0d core=%0d RESTORE-MISMATCH pc=%h entry_pc=%h idx=%0d cf=%0d",
                         win_cycle, int'(hart_id_i[7:0]) / int'(CK_NH), resolved_branch.pc,
                         ck_shadow_pc[ck_csel][ck_idx], ck_idx, int'(resolved_branch.cf_type));
            end else if (ckpt_trace && win_cycle >= win_lo && win_cycle <= win_hi) begin
              $display("[ckpt] c=%0d core=%0d RESTORE pc=%h idx=%0d cf=%0d call=%0d ras tos=%0d cnt=%0d top=%h",
                       win_cycle, int'(hart_id_i[7:0]) / int'(CK_NH), resolved_branch.pc, ck_idx,
                       int'(resolved_branch.cf_type), resolved_branch.is_call,
                       int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.entry_ras_tos_o),
                       int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.entry_ras_cnt_o),
                       i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.entry_ras_top_o);
            end
          end else if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.pop_i &&
                       i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.pop_v_i) begin
            ck_pops++;
            if (!i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.pop_live) ck_pop_dead++;
            else if (ck_shadow_pc[ck_csel][ck_idx] != 64'(resolved_branch.pc)) begin
              ck_pop_mismatch++;
              if (ckpt_trace && win_cycle >= win_lo && win_cycle <= win_hi)
                $display("[ckpt] c=%0d core=%0d POP-MISMATCH pc=%h entry_pc=%h idx=%0d cf=%0d",
                         win_cycle, int'(hart_id_i[7:0]) / int'(CK_NH), resolved_branch.pc,
                         ck_shadow_pc[ck_csel][ck_idx], ck_idx, int'(resolved_branch.cf_type));
            end
          end
          // allocation side
          if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.alloc_en) begin
            for (int unsigned s = 0; s < CVA6Cfg.INSTR_PER_FETCH; s++) begin
              if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.push_i[s]) begin
                ck_shadow_pc[ck_psel][int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.alloc_idx_o[s]) % CK_D] =
                    64'(i_frontend.addr[s]);
                ck_allocs++;
              end
            end
          end else if (i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.push_cnt != '0 &&
                       !i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.restore_i &&
                       !i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.flush_i &&
                       !i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.clear_i) begin
            ck_refused++;
            if (ckpt_trace && win_cycle >= win_lo && win_cycle <= win_hi)
              $display("[ckpt] c=%0d core=%0d ALLOC-REFUSED span=%0d want=%0d", win_cycle,
                       int'(hart_id_i[7:0]) / int'(CK_NH),
                       int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.span[ck_psel]),
                       int'(i_frontend.gen_tage_lite.i_bp_top.gen_ckpt.i_ckpt.push_cnt));
          end
        end
      end
      final
        $display("[ckpt] final core=%0d allocs=%0d pops=%0d pop_mismatch=%0d pop_dead=%0d restores=%0d restore_mismatch=%0d restore_dropped=%0d refused=%0d clears=%0d | resolves br=%0d ret=%0d jmp=%0d mispredicts br=%0d ret=%0d jmp=%0d",
                 int'(hart_id_i[7:0]) / int'(CK_NH), ck_allocs, ck_pops, ck_pop_mismatch, ck_pop_dead,
                 ck_restores, ck_restore_mismatch, ck_restore_dropped, ck_refused, ck_clears,
                 ck_res_br, ck_res_ret, ck_res_jmp, ck_misp_br, ck_misp_ret, ck_misp_jmp);
    end
  end
`endif

  initial begin
    assert (!(CVA6Cfg.SuperscalarEn && CVA6Cfg.EnableAccelerator))
    else $fatal(1, "Accelerator is not supported by superscalar pipeline");
  end
  //pragma translate_on

endmodule  // ariane
