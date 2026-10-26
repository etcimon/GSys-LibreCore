// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_tlb_miss_router — hyp8 UseSharedTlb=0 miss/return path, extracted
// from g6lc_shared_tlb's bypass arm so the disabled shared table is no
// longer elaborated.  Behaviour is the old bypass exactly:
//
//   * Miss accept is the old registered arbitration: I wins when the
//     S/VS stage enables permit and D is not accessing; D otherwise.
//     The accepted request (owner + vaddr) is registered for the PTW's
//     shared_tlb_access/vaddr handshake.
//   * A returned update (shared_tlb_update_i.valid) is routed to the
//     registered owner: the update record's asid/vmid/hart/content are
//     echoed; v_st_enbl is taken from the LIVE stage-enable inputs
//     selected by the registered owner bit, as the old bypass did.
//   * Flush inputs start a geometry-only walk (READ_SET/APPLY_SET over
//     SharedTlbDepth sets) that blocks new miss accepts for the full
//     2*SharedTlbDepth-cycle quiet window — the old module walked the
//     same FSM under UseSharedTlb=0 while flush_busy_o stayed tied low.
//     Returned updates keep routing during the quiet window.
//
// The module carries no ASID/VMID/hart or flush-address ports: nothing in
// the bypass consumed them — context is echoed from the update record.

module g6lc_tlb_miss_router #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type tlb_update_g6lc_t = logic,
    parameter int unsigned HYP_EXT = 0
) (
    input logic clk_i,
    input logic rst_ni,

    input logic flush_i,       // flush normal translations
    input logic flush_vvma_i,  // flush vs stage
    input logic flush_gvma_i,  // flush g stage

    input logic s_st_enbl_i,     // s-stage enabled (instruction)
    input logic g_st_enbl_i,     // g-stage enabled (instruction)
    input logic v_i,             // virtualization mode (instruction)
    input logic s_ld_st_enbl_i,  // s-stage enabled (load/store)
    input logic g_ld_st_enbl_i,  // g-stage enabled (load/store)
    input logic ld_st_v_i,       // virtualization mode (load/store)

    input  logic                    itlb_access_i,
    input  logic                    itlb_hit_i,
    input  logic [G6LCCfg.VLEN-1:0] itlb_vaddr_i,

    input  logic                    dtlb_access_i,
    input  logic                    dtlb_hit_i,
    input  logic [G6LCCfg.VLEN-1:0] dtlb_vaddr_i,

    input  logic            shared_tlb_miss_i,
    input  tlb_update_g6lc_t shared_tlb_update_i,

    output tlb_update_g6lc_t itlb_update_o,
    output tlb_update_g6lc_t dtlb_update_o,

    output logic itlb_miss_o,
    output logic dtlb_miss_o,

    output logic                    flush_busy_o,
    output logic                    shared_tlb_access_o,
    output logic                    shared_tlb_hit_o,
    output logic [G6LCCfg.VLEN-1:0] shared_tlb_vaddr_o,
    output logic                    itlb_req_o
);

  localparam int unsigned IW = (G6LCCfg.SharedTlbDepth > 1) ? $clog2(G6LCCfg.SharedTlbDepth) : 1;

  // Geometry-only flush walk: READ_SET/APPLY_SET per set, same shape the
  // shared table's flush FSM takes when its RAMs are absent.  Miss
  // accepts are suppressed for the whole walk (and for any cycle a flush
  // input is asserted), reproducing the old bypass's quiet window.
  typedef enum logic [1:0] {
    IDLE,
    READ_SET,
    APPLY_SET
  } walk_e;
  walk_e walk_q, walk_d;
  logic [IW-1:0] idx_q, idx_d;

  // [1]=instruction side {v_i, g_st_enbl_i, s_st_enbl_i}
  // [0]=load/store side {ld_st_v_i, g_ld_st_enbl_i, s_ld_st_enbl_i}
  logic [1:0][2:0] stage_en;
  logic allow_req, pick_i, pick_d;
  logic ireq_q, dreq_q, owner_i_q;
  logic [G6LCCfg.VLEN-1:0] va_q;

  assign stage_en = {{v_i, g_st_enbl_i, s_st_enbl_i}, {ld_st_v_i, g_ld_st_enbl_i, s_ld_st_enbl_i}};

  assign allow_req = (walk_q == IDLE) && !flush_i && !flush_vvma_i && !flush_gvma_i;
  assign pick_i = allow_req && (|stage_en[1][HYP_EXT:0]) &&
                  itlb_access_i && !itlb_hit_i && !dtlb_access_i;
  assign pick_d = allow_req && (|stage_en[0][HYP_EXT:0]) &&
                  dtlb_access_i && !dtlb_hit_i;

  always_comb begin : p_walk
    walk_d = walk_q;
    idx_d  = idx_q;
    unique case (walk_q)
      IDLE: begin
        if (flush_i || flush_vvma_i || flush_gvma_i) begin
          walk_d = READ_SET;
          idx_d  = '0;
        end
      end
      READ_SET: begin
        walk_d = APPLY_SET;
      end
      APPLY_SET: begin
        if (idx_q == IW'(G6LCCfg.SharedTlbDepth - 1)) begin
          walk_d = IDLE;
          idx_d  = '0;
        end else begin
          walk_d = READ_SET;
          idx_d  = idx_q + 1'b1;
        end
      end
      default: begin
        walk_d = IDLE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      walk_q    <= IDLE;
      idx_q     <= '0;
      ireq_q    <= 1'b0;
      dreq_q    <= 1'b0;
      owner_i_q <= 1'b0;
      va_q      <= '0;
    end else begin
      walk_q <= walk_d;
      idx_q  <= idx_d;
      ireq_q <= pick_i;
      dreq_q <= pick_d;
      if (pick_i) begin
        va_q      <= itlb_vaddr_i;
        owner_i_q <= 1'b1;
      end else if (pick_d) begin
        va_q      <= dtlb_vaddr_i;
        owner_i_q <= 1'b0;
      end
    end
  end

  // registered request presentation (old shared_tlb_access_q /
  // shared_tlb_vaddr_q / itlb_req_q equivalents)
  assign shared_tlb_access_o = ireq_q | dreq_q;
  assign shared_tlb_vaddr_o  = va_q;
  assign itlb_req_o          = ireq_q;

  // miss accounting: the old bypass raised itlb_miss_o/dtlb_miss_o only
  // in the cycle its miss arm fired.
  assign itlb_miss_o = pick_i & shared_tlb_miss_i;
  assign dtlb_miss_o = pick_d & shared_tlb_miss_i;

  assign flush_busy_o = 1'b0;

  // A returned update hits unconditionally under the bypass and routes
  // to the registered owner; context fields echo the update record and
  // v_st_enbl samples the live stage-enable inputs by registered owner.
  assign shared_tlb_hit_o = shared_tlb_update_i.valid;

  tlb_update_g6lc_t reply;
  always_comb begin : p_reply
    reply             = '0;
    reply.valid       = 1'b1;
    reply.vpn         = shared_tlb_update_i.vpn;
    reply.is_page     = shared_tlb_update_i.is_page;
    reply.content     = shared_tlb_update_i.content;
    reply.g_content   = shared_tlb_update_i.g_content;
    reply.v_st_enbl   = stage_en[owner_i_q][HYP_EXT*2:0];
    reply.asid        = shared_tlb_update_i.asid;
    reply.vmid        = shared_tlb_update_i.vmid;
    reply.hart        = shared_tlb_update_i.hart;
    reply.is_napot_64k = shared_tlb_update_i.is_napot_64k;

    itlb_update_o = '0;
    dtlb_update_o = '0;
    if (shared_tlb_update_i.valid) begin
      if (ireq_q) begin
        itlb_update_o = reply;
      end else if (dreq_q) begin
        dtlb_update_o = reply;
      end
    end
  end

  //pragma translate_off
  initial begin
    assert (G6LCCfg.SharedTlbDepth >= 1)
    else $fatal(1, "g6lc_tlb_miss_router requires SharedTlbDepth >= 1 for the flush walk geometry");
    assert (!G6LCCfg.UseSharedTlb)
    else $fatal(1, "g6lc_tlb_miss_router is the UseSharedTlb=0 path; instantiate g6lc_shared_tlb instead");
  end
  //pragma translate_on

endmodule
