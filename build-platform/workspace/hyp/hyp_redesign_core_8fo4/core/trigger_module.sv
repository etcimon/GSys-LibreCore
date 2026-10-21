// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
module trigger_module
  import g6lc_core_pkg::*;
  import triggers_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg            = config_pkg::g6lc_cfg_empty,
    parameter type                   exception_t        = logic,
    parameter type                   scoreboard_entry_t = logic,
    parameter int unsigned           N_Triggers         = 4
) (
    input logic clk_i,
    input logic rst_ni,
    input scoreboard_entry_t commit_instr_i,
    input logic [G6LCCfg.NrCommitPorts-1:0] commit_ack_i,
    input exception_t ex_i,
    input riscv::priv_lvl_t priv_lvl_i,
    input logic debug_mode_i,
    input logic mret_i,
    input logic sret_i,
    input logic [G6LCCfg.VLEN-1:0] vaddr_from_lsu_i,
    input logic [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input logic [G6LCCfg.XLEN-1:0] store_result_i,

    input logic [G6LCCfg.XLEN-1:0] scontext_i,

    input logic [G6LCCfg.XLEN-1:0] tdata1_i,
    input logic [G6LCCfg.XLEN-1:0] tdata2_i,
    input logic [G6LCCfg.XLEN-1:0] tdata3_i,
    input logic [G6LCCfg.XLEN-1:0] tselect_i,
    input logic tselect_we,
    input logic tdata1_we,
    input logic tdata2_we,
    input logic tdata3_we,

    output logic [G6LCCfg.XLEN-1:0] tselect_o,
    output logic [G6LCCfg.XLEN-1:0] tdata1_o,
    output logic [G6LCCfg.XLEN-1:0] tdata2_o,
    output logic [G6LCCfg.XLEN-1:0] tdata3_o,
    output logic flush_o,

    output logic break_from_trigger_o,
    output logic debug_from_trigger_o,
    output logic debug_from_mcontrol_o
);

  // Trigger Module Helpers
  logic [$clog2(N_Triggers)-1:0] tselect_q, tselect_d;
  // 64-bit padded views of XLEN-wide inputs (safe for bit-selects beyond XLEN in IS_XLEN32)
  logic [63:0] tdata1_i_64, tdata3_i_64;
  assign tdata1_i_64 = {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata1_i};
  assign tdata3_i_64 = {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata3_i};
  logic [3:0] trigger_type_q[N_Triggers], trigger_type_d[N_Triggers];
  logic [N_Triggers-1:0] priv_match, scontext_match;
  textra32_tdata3_t textra32_tdata3_q[N_Triggers], textra32_tdata3_d[N_Triggers];
  textra64_tdata3_t textra64_tdata3_q[N_Triggers], textra64_tdata3_d[N_Triggers];
  logic [G6LCCfg.XLEN-1:0] tdata2_q[N_Triggers], tdata2_d[N_Triggers];
  logic mcontrol6_debug_d, mcontrol6_debug_q;
  // hyp8 r3/r4: per-trigger match vectors + registered action stage.
  // TWR (CSR write/update + applied-fire bookkeeping), TMA (match unit)
  // and TAC (registered fire capture) are separate blocks. The match unit
  // reads the `*_q` registers ONLY: a CSR write to tdata becomes visible
  // to matching one cycle later. This is architecturally safe because a
  // trigger-register write asserts `flush_o`, serializing the pipe -- no
  // in-flight access can have been meant to see the just-written compare
  // values in the write's own cycle. The icount countdown decrements on
  // `icount32_tdata1_q` and the etrigger/itrigger chain keeps its
  // registered `e_matched_q` flag inside the unit; the fire verdicts
  // capture into *_fire_q (+1 trigger fire latency, tier-2 row).
  logic [N_Triggers-1:0] icnt_fire,    icnt_fire_q;
  logic [N_Triggers-1:0] icnt_brk,     icnt_brk_q;
  logic [N_Triggers-1:0] icnt_dbg,     icnt_dbg_q;
  logic [N_Triggers-1:0] mc6_matched;
  logic [N_Triggers-1:0] mc6_fire,     mc6_fire_q;
  logic [N_Triggers-1:0] etrig_fire,   etrig_fire_q;
  logic [N_Triggers-1:0] etrig_brk,    etrig_brk_q;
  logic [N_Triggers-1:0] etrig_dbg,    etrig_dbg_q;
  logic [N_Triggers-1:0] itrig_fire,   itrig_fire_q;
  logic [N_Triggers-1:0] itrig_brk,    itrig_brk_q;
  logic [N_Triggers-1:0] itrig_dbg,    itrig_dbg_q;
  logic [N_Triggers-1:0] e_set_v,      i_set_v;
  logic e_matched_q, e_matched_d;
  logic mret_reg_q, mret_reg_d;
  logic break_from_trigger_q, break_from_trigger_d;
  logic in_trap_handler_q, in_trap_handler_d;
  logic debug_from_trigger_q, debug_from_trigger_d;
  icount32_tdata1_t icount32_tdata1_q[N_Triggers], icount32_tdata1_d[N_Triggers];
  mcontrol6_32_tdata1_t mcontrol6_32_tdata1_q[N_Triggers], mcontrol6_32_tdata1_d[N_Triggers];
  etrigger32_tdata1_t etrigger32_tdata1_q[N_Triggers], etrigger32_tdata1_d[N_Triggers];
  itrigger32_tdata1_t itrigger32_tdata1_q[N_Triggers], itrigger32_tdata1_d[N_Triggers];


  // svt-stage: begin TWR
  // Trigger CSRs write/update logic
  always_comb begin : write_path
    tselect_d            = tselect_q;
    mcontrol6_debug_d    = mcontrol6_debug_q;
    e_matched_d          = e_matched_q;
    mret_reg_d           = mret_reg_q;
    break_from_trigger_d = break_from_trigger_q;
    in_trap_handler_d    = in_trap_handler_q;
    debug_from_trigger_d = debug_from_trigger_q;
    flush_o              = 1'b0;
    for (int i = 0; i < N_Triggers; i++) begin
      trigger_type_d[i]        = trigger_type_q[i];
      icount32_tdata1_d[i]     = icount32_tdata1_q[i];
      mcontrol6_32_tdata1_d[i] = mcontrol6_32_tdata1_q[i];
      etrigger32_tdata1_d[i]   = etrigger32_tdata1_q[i];
      itrigger32_tdata1_d[i]   = itrigger32_tdata1_q[i];
      textra32_tdata3_d[i]     = textra32_tdata3_q[i];
      textra64_tdata3_d[i]     = textra64_tdata3_q[i];
      tdata2_d[i]              = tdata2_q[i];
    end

    // Trigger module CSRs
    if (tselect_we) begin
      tselect_d = (tselect_i < N_Triggers) ? tselect_i[$clog2(N_Triggers)-1:0] : tselect_q;
    end
    if (tdata1_we) begin
      if ((tdata1_i[31:28] == 4'd3 && G6LCCfg.IS_XLEN32) || (G6LCCfg.IS_XLEN64 && tdata1_i_64[63:60] == 4'd3)) begin
        trigger_type_d[tselect_q] = G6LCCfg.IS_XLEN32 ? tdata1_i[31:28] : tdata1_i_64[63:60];
        icount32_tdata1_d[tselect_q].t_type  = G6LCCfg.IS_XLEN32 ? ((tdata1_i[31:28] == 4'd3 || tdata1_i[31:28] == 4'd15) ? tdata1_i[31:28] : trigger_type_q[tselect_q]) : ((tdata1_i_64[63:60] == 4'd3 || tdata1_i_64[63:60] == 4'd15) ? tdata1_i_64[63:60] : trigger_type_q[tselect_q]);
        icount32_tdata1_d[tselect_q].dmode = G6LCCfg.IS_XLEN32 ? tdata1_i[27] : tdata1_i_64[59];
        icount32_tdata1_d[tselect_q].vs = 0;
        icount32_tdata1_d[tselect_q].vu = 0;
        icount32_tdata1_d[tselect_q].hit = tdata1_i[24];
        icount32_tdata1_d[tselect_q].count = tdata1_i[23:10];
        icount32_tdata1_d[tselect_q].m = tdata1_i[9];
        icount32_tdata1_d[tselect_q].pending = tdata1_i[8];
        icount32_tdata1_d[tselect_q].s = tdata1_i[7];
        icount32_tdata1_d[tselect_q].u = tdata1_i[6];
        icount32_tdata1_d[tselect_q].action = tdata1_i[5:0];
        flush_o = 1'b1;

      end else if ((G6LCCfg.IS_XLEN32 && tdata1_i[31:28] == 4'd6) || (G6LCCfg.IS_XLEN64 && tdata1_i_64[63:60] == 4'd6)) begin
        trigger_type_d[tselect_q] = G6LCCfg.IS_XLEN32 ? tdata1_i[31:28] : tdata1_i_64[63:60];
        mcontrol6_32_tdata1_d[tselect_q].t_type  = G6LCCfg.IS_XLEN32 ? ((tdata1_i[31:28] == 4'd6 || tdata1_i[31:28] == 4'd15) ? tdata1_i[31:28] : trigger_type_q[tselect_q]) : ((tdata1_i_64[63:60] == 4'd6 || tdata1_i_64[63:60] == 4'd15) ? tdata1_i_64[63:60] : trigger_type_q[tselect_q]);
        mcontrol6_32_tdata1_d[tselect_q].dmode = G6LCCfg.IS_XLEN32 ? tdata1_i[27] : tdata1_i_64[59];
        mcontrol6_32_tdata1_d[tselect_q].uncertain = 0;
        mcontrol6_32_tdata1_d[tselect_q].hit1 = tdata1_i[25];
        mcontrol6_32_tdata1_d[tselect_q].vs = 0;
        mcontrol6_32_tdata1_d[tselect_q].vu = 0;
        mcontrol6_32_tdata1_d[tselect_q].hit0 = tdata1_i[22];
        mcontrol6_32_tdata1_d[tselect_q].select = tdata1_i[21];
        mcontrol6_32_tdata1_d[tselect_q].zeroes = '0;
        mcontrol6_32_tdata1_d[tselect_q].size = tdata1_i[18:16];
        mcontrol6_32_tdata1_d[tselect_q].action = tdata1_i[15:12];
        mcontrol6_32_tdata1_d[tselect_q].chain = 0;
        mcontrol6_32_tdata1_d[tselect_q].match = tdata1_i[10:7];
        mcontrol6_32_tdata1_d[tselect_q].m = tdata1_i[6];
        mcontrol6_32_tdata1_d[tselect_q].uncertainen = 0;
        mcontrol6_32_tdata1_d[tselect_q].s = tdata1_i[4];
        mcontrol6_32_tdata1_d[tselect_q].u = tdata1_i[3];
        mcontrol6_32_tdata1_d[tselect_q].execute = tdata1_i[2];
        mcontrol6_32_tdata1_d[tselect_q].store = tdata1_i[1];
        mcontrol6_32_tdata1_d[tselect_q].load = tdata1_i[0];
        flush_o = 1'b1;

      end else if ((tdata1_i[31:28] == 4'd5 && G6LCCfg.IS_XLEN32) || (tdata1_i_64[63:60] == 4'd5 && G6LCCfg.IS_XLEN64)) begin
        trigger_type_d[tselect_q] = G6LCCfg.IS_XLEN32 ? tdata1_i[31:28] : tdata1_i_64[63:60];
        etrigger32_tdata1_d[tselect_q].t_type  = G6LCCfg.IS_XLEN32 ? ((tdata1_i[31:28] == 4'd5 || tdata1_i[31:28] == 4'd15) ? tdata1_i[31:28] : trigger_type_q[tselect_q]) : ((tdata1_i_64[63:60] == 4'd5 || tdata1_i_64[63:60] == 4'd15) ? tdata1_i_64[63:60] : trigger_type_q[tselect_q]);
        etrigger32_tdata1_d[tselect_q].dmode = G6LCCfg.IS_XLEN32 ? tdata1_i[27] : tdata1_i_64[59];
        etrigger32_tdata1_d[tselect_q].hit = G6LCCfg.IS_XLEN32 ? tdata1_i[26] : tdata1_i_64[58];
        etrigger32_tdata1_d[tselect_q].zeroes = '0;
        etrigger32_tdata1_d[tselect_q].vs = 0;
        etrigger32_tdata1_d[tselect_q].vu = 0;
        etrigger32_tdata1_d[tselect_q].zeroed = 0;
        etrigger32_tdata1_d[tselect_q].m = tdata1_i[9];
        etrigger32_tdata1_d[tselect_q].zero = 0;
        etrigger32_tdata1_d[tselect_q].s = tdata1_i[7];
        etrigger32_tdata1_d[tselect_q].u = tdata1_i[6];
        etrigger32_tdata1_d[tselect_q].action = tdata1_i[5:0];

      end else if ((tdata1_i[31:28] == 4'd4 && G6LCCfg.IS_XLEN32) || (tdata1_i_64[63:60] == 4'd4 && G6LCCfg.IS_XLEN64)) begin
        trigger_type_d[tselect_q] = G6LCCfg.IS_XLEN32 ? tdata1_i[31:28] : tdata1_i_64[63:60];
        itrigger32_tdata1_d[tselect_q].t_type  = G6LCCfg.IS_XLEN32 ? ((tdata1_i[31:28] == 4'd4 || tdata1_i[31:28] == 4'd15) ? tdata1_i[31:28] : trigger_type_q[tselect_q]) : ((tdata1_i_64[63:60] == 4'd4 || tdata1_i_64[63:60] == 4'd15) ? tdata1_i_64[63:60] : trigger_type_q[tselect_q]);
        itrigger32_tdata1_d[tselect_q].dmode = G6LCCfg.IS_XLEN32 ? tdata1_i[27] : tdata1_i_64[59];
        itrigger32_tdata1_d[tselect_q].hit = G6LCCfg.IS_XLEN32 ? tdata1_i[26] : tdata1_i_64[58];
        itrigger32_tdata1_d[tselect_q].zeroed = '0;
        itrigger32_tdata1_d[tselect_q].vs = 0;
        itrigger32_tdata1_d[tselect_q].vu = 0;
        itrigger32_tdata1_d[tselect_q].nmi = 0;
        itrigger32_tdata1_d[tselect_q].m = tdata1_i[9];
        itrigger32_tdata1_d[tselect_q].zero = 0;
        itrigger32_tdata1_d[tselect_q].s = tdata1_i[7];
        itrigger32_tdata1_d[tselect_q].u = tdata1_i[6];
        itrigger32_tdata1_d[tselect_q].action = tdata1_i[5:0];
      end
    end
    if (tdata2_we) begin
      tdata2_d[tselect_q] = tdata2_i;
    end
    if (tdata3_we) begin
      if (G6LCCfg.IS_XLEN32) begin  // textra32
        textra32_tdata3_d[tselect_q].mhvalue   = '0;
        textra32_tdata3_d[tselect_q].mhselect  = '0;
        textra32_tdata3_d[tselect_q].zeroes    = '0;
        textra32_tdata3_d[tselect_q].sbytemask = tdata3_i[19:18];
        textra32_tdata3_d[tselect_q].svalue    = tdata3_i[17:2];
        textra32_tdata3_d[tselect_q].sselect   = tdata3_i[1:0];
      end
      if (G6LCCfg.IS_XLEN64) begin  // textra64
        textra64_tdata3_d[tselect_q].mhvalue    = '0;
        textra64_tdata3_d[tselect_q].mhselect   = '0;
        textra64_tdata3_d[tselect_q].zeroes     = '0;
        textra64_tdata3_d[tselect_q].sbytemask  = tdata3_i_64[39:36];
        textra64_tdata3_d[tselect_q].zero_field = '0;
        textra64_tdata3_d[tselect_q].svalue     = tdata3_i_64[33:2];
        textra64_tdata3_d[tselect_q].sselect    = tdata3_i[1:0];
      end
    end


    // hyp8 r3: live icount countdown + registered-action application.
    // The per-i section order (icount -> mcontrol6 -> etrigger ->
    // itrigger) and the within-section write order are unchanged from the
    // serial FSM; only the fire DECISION moved to the *_fire_q registers
    // captured by match_path last cycle (+1 fire latency).
    if (G6LCCfg.SDTRIG) begin
      for (int i = 0; i < N_Triggers; i++) begin
        // icount countdown + applied fire
        if (trigger_type_d[i] == 4'd3 && G6LCCfg.Icount) begin
          break_from_trigger_d = 1'b0;
          if (ex_i.valid) begin
            in_trap_handler_d = 1'b1;
            icount32_tdata1_d[i].count = icount32_tdata1_q[i].count - 1;
          end
          if (|commit_ack_i && (mret_i || sret_i)) in_trap_handler_d = 1'b0;
          if (|commit_ack_i && !in_trap_handler_d && (icount32_tdata1_q[i].count != 0)) begin
            icount32_tdata1_d[i].count = icount32_tdata1_q[i].count - 1;
          end
          if (icnt_fire_q[i]) icount32_tdata1_d[i].pending = 1'b1;
          if (icnt_brk_q[i]) break_from_trigger_d = 1'b1;
          if (icnt_dbg_q[i]) debug_from_trigger_d = 1'b1;
          if (break_from_trigger_q) begin
            icount32_tdata1_d[i].hit = 1'b1;
            icount32_tdata1_d[i].pending = 1'b0;
          end
          if (debug_mode_i && icount32_tdata1_d[i].pending) begin
            icount32_tdata1_d[i].pending = 1'b0;
            icount32_tdata1_d[i].hit = 1'b1;
            debug_from_trigger_d = 1'b0;
          end
        end
        // mcontrol6 applied fire + live debug-mode hit bookkeeping
        if (trigger_type_d[i] == 4'd6 && G6LCCfg.Mcontrol6) begin
          if (mc6_fire_q[i]) mcontrol6_debug_d = 1'b1;
          if (debug_mode_i && mc6_matched[i]) begin
            mcontrol6_32_tdata1_d[i].hit0 = 1'b0;
            mcontrol6_32_tdata1_d[i].hit1 = 1'b1;
            mcontrol6_debug_d = 1'b0;
          end
        end
        // etrigger applied fire + live state
        if (trigger_type_d[i] == 4'd5 && G6LCCfg.Etrigger) begin
          break_from_trigger_d = 1'b0;
          if (e_set_v[i]) e_matched_d = 1'b1;
          if (mret_i || sret_i) mret_reg_d = 1'b1;
          if (etrig_fire_q[i]) begin
            e_matched_d = 1'b0;
            etrigger32_tdata1_d[i].hit = 1'b1;
          end
          if (etrig_brk_q[i]) break_from_trigger_d = 1'b1;
          if (etrig_dbg_q[i]) debug_from_trigger_d = 1'b1;
          if (break_from_trigger_q) begin
            etrigger32_tdata1_d[i].hit = 1'b0;
            break_from_trigger_d = 1'b0;
          end
          if (debug_mode_i && debug_from_trigger_d) begin
            etrigger32_tdata1_d[i].hit = 1'b0;
            debug_from_trigger_d = 1'b0;
          end
        end
        // itrigger applied fire + live state
        if (trigger_type_d[i] == 4'd4 && G6LCCfg.Itrigger) begin
          break_from_trigger_d = 1'b0;
          if (i_set_v[i]) e_matched_d = 1'b1;
          if (mret_i || sret_i) mret_reg_d = 1'b1;
          if (itrig_fire_q[i]) begin
            e_matched_d = 1'b0;
            itrigger32_tdata1_d[i].hit = 1'b1;
          end
          if (itrig_brk_q[i]) break_from_trigger_d = 1'b1;
          if (itrig_dbg_q[i]) debug_from_trigger_d = 1'b1;
          if (break_from_trigger_q) begin
            itrigger32_tdata1_d[i].hit = 1'b0;
            break_from_trigger_d = 1'b0;
          end
          if (debug_mode_i && debug_from_trigger_d) begin
            itrigger32_tdata1_d[i].hit = 1'b0;
            debug_from_trigger_d = 1'b0;
          end
        end
      end
    end
  end
  // svt-stage: end TWR

  // svt-stage: begin TMA
  // hyp8 r3: per-trigger match vectors. hyp8 r4: reads the `*_q`
  // registers only (CSR write visible to matching +1 -- safe: the write
  // asserts flush_o, serializing the pipe). The verdicts capture into
  // *_fire_q and apply next cycle.
  always_comb begin : match_path
    priv_match      = '0;
    scontext_match  = '0;
    icnt_fire       = '0;
    icnt_brk        = '0;
    icnt_dbg        = '0;
    mc6_matched     = '0;
    mc6_fire        = '0;
    etrig_fire      = '0;
    etrig_brk       = '0;
    etrig_dbg       = '0;
    itrig_fire      = '0;
    itrig_brk       = '0;
    itrig_dbg       = '0;
    e_set_v         = '0;
    i_set_v         = '0;
    if (G6LCCfg.SDTRIG) begin
      for (int i = 0; i < N_Triggers; i++) begin
        // icount match
        if (trigger_type_q[i] == 4'd3 && G6LCCfg.Icount) begin
          case(priv_lvl_i) // trigger fires only at its configured priv lvl
            riscv::PRIV_LVL_M: if (icount32_tdata1_q[i].m) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_S: if (icount32_tdata1_q[i].s) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_U: if (icount32_tdata1_q[i].u) priv_match[i] = 1'b1;
            default: priv_match[i] = 1'b0;
          endcase
          // S_MODE context match check
          if (priv_lvl_i == riscv::PRIV_LVL_S && icount32_tdata1_q[i].s) begin
            if (G6LCCfg.IS_XLEN32) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else begin
              scontext_match[i] = match_scontext64(
                scontext_i[31:0],
                textra64_tdata3_q[i].sselect,
                textra64_tdata3_q[i].sbytemask,
                textra64_tdata3_q[i].svalue
              );
            end
            priv_match[i] &= scontext_match[i];
          end
          if ((icount32_tdata1_q[i].count == 0) && priv_match[i] &&
              !icount32_tdata1_q[i].pending && !icount32_tdata1_q[i].hit) begin
            icnt_fire[i] = 1'b1;
            icnt_brk[i]  = (icount32_tdata1_q[i].action == 6'd0);
            icnt_dbg[i]  = (icount32_tdata1_q[i].action == 6'd1);
          end
        end
        // mcontrol6 match
        if (trigger_type_q[i] == 4'd6 && G6LCCfg.Mcontrol6) begin
          case(priv_lvl_i)
            riscv::PRIV_LVL_M: if (mcontrol6_32_tdata1_q[i].m) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_S: if (mcontrol6_32_tdata1_q[i].s) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_U: if (mcontrol6_32_tdata1_q[i].u) priv_match[i] = 1'b1;
            default: priv_match[i] = 1'b0;
          endcase
          if (priv_lvl_i == riscv::PRIV_LVL_S && mcontrol6_32_tdata1_q[i].s) begin
            if (G6LCCfg.IS_XLEN32) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else begin
              scontext_match[i] = match_scontext64(
                scontext_i[31:0],
                textra64_tdata3_q[i].sselect,
                textra64_tdata3_q[i].sbytemask,
                textra64_tdata3_q[i].svalue
              );
            end
            priv_match[i] &= scontext_match[i];
          end
          // the six legs are last-writer-wins in the serial FSM; keep the
          // same order with a priority select (later leg wins).
          if (mcontrol6_32_tdata1_q[i].execute && !mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i] == commit_instr_i.pc && |commit_ack_i);
              4'd1: mc6_matched[i] = (napot_match(
                {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                {{(64 - G6LCCfg.XLEN) {1'b0}}, commit_instr_i.pc}
              ) && |commit_ack_i);
              4'd8: mc6_matched[i] = (tdata2_q[i] != commit_instr_i.pc && |commit_ack_i);
              default: ;
            endcase
          end
          if (mcontrol6_32_tdata1_q[i].execute && mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i][31:0] == orig_instr_i[0]);
              4'd1: mc6_matched[i] = (napot_match({{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                                     {{32{1'b0}}, orig_instr_i[0]}));
              4'd8: mc6_matched[i] = (tdata2_q[i][31:0] != orig_instr_i[0]);
              default: ;
            endcase
          end
          if (mcontrol6_32_tdata1_q[i].store && mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i] == store_result_i);
              4'd1: mc6_matched[i] = (napot_match(
                {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                {{(64 - G6LCCfg.XLEN) {1'b0}}, store_result_i}
              ));
              4'd8: mc6_matched[i] = (tdata2_q[i] != store_result_i);
              default: ;
            endcase
          end
          if (mcontrol6_32_tdata1_q[i].store && !mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i] == vaddr_from_lsu_i);
              4'd1: mc6_matched[i] = (napot_match(
                {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                {{(64 - G6LCCfg.VLEN) {1'b0}}, vaddr_from_lsu_i}
              ));
              4'd8: mc6_matched[i] = (tdata2_q[i] != vaddr_from_lsu_i);
              default: ;
            endcase
          end
          if (mcontrol6_32_tdata1_q[i].load && mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i] == commit_instr_i.result && commit_instr_i.op == 8'h27);
              4'd1: mc6_matched[i] = (napot_match(
                {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                {{(64 - G6LCCfg.XLEN) {1'b0}}, commit_instr_i.result}
              ) && commit_instr_i.op == 8'h27);
              4'd8: mc6_matched[i] = (tdata2_q[i] != commit_instr_i.result && commit_instr_i.op == 8'h27);
              default: ;
            endcase
          end
          if (mcontrol6_32_tdata1_q[i].load && !mcontrol6_32_tdata1_q[i].select) begin
            case (mcontrol6_32_tdata1_q[i].match)
              4'd0: mc6_matched[i] = (tdata2_q[i] == vaddr_from_lsu_i);
              4'd1: mc6_matched[i] = (napot_match(
                {{(64 - G6LCCfg.XLEN) {1'b0}}, tdata2_q[i]},
                {{(64 - G6LCCfg.VLEN) {1'b0}}, vaddr_from_lsu_i}
              ));
              4'd8: mc6_matched[i] = (tdata2_q[i] != vaddr_from_lsu_i);
              default: ;
            endcase
          end
          mc6_fire[i] = priv_match[i] && mc6_matched[i] && !debug_mode_i &&
                        (mcontrol6_32_tdata1_q[i].action == 4'd1);
        end
        // etrigger match
        if (trigger_type_q[i] == 4'd5 && G6LCCfg.Etrigger) begin
          case(priv_lvl_i)
            riscv::PRIV_LVL_M: if (etrigger32_tdata1_q[i].m) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_S: if (etrigger32_tdata1_q[i].s) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_U: if (etrigger32_tdata1_q[i].u) priv_match[i] = 1'b1;
            default: priv_match[i] = 1'b0;
          endcase
          if (priv_lvl_i == riscv::PRIV_LVL_S && etrigger32_tdata1_q[i].s) begin
            if (G6LCCfg.IS_XLEN32) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else begin
              scontext_match[i] = match_scontext64(
                scontext_i[31:0],
                textra64_tdata3_q[i].sselect,
                textra64_tdata3_q[i].sbytemask,
                textra64_tdata3_q[i].svalue
              );
            end
            priv_match[i] &= scontext_match[i];
          end
          e_set_v[i] = tdata2_q[i][ex_i.cause];
          etrig_fire[i] = e_matched_q && priv_match[i] && mret_reg_q &&
                          |commit_ack_i;
          etrig_brk[i]  = etrig_fire[i] &&
                          (etrigger32_tdata1_q[i].action == 6'd0);
          etrig_dbg[i]  = etrig_fire[i] &&
                          (etrigger32_tdata1_q[i].action == 6'd1);
        end
        // itrigger match
        if (trigger_type_q[i] == 4'd4 && G6LCCfg.Itrigger) begin
          case(priv_lvl_i)
            riscv::PRIV_LVL_M: if (itrigger32_tdata1_q[i].m) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_S: if (itrigger32_tdata1_q[i].s) priv_match[i] = 1'b1;
            riscv::PRIV_LVL_U: if (itrigger32_tdata1_q[i].u) priv_match[i] = 1'b1;
            default: priv_match[i] = 1'b0;
          endcase
          if (priv_lvl_i == riscv::PRIV_LVL_S && itrigger32_tdata1_q[i].s) begin
            if (G6LCCfg.IS_XLEN32) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else begin
              scontext_match[i] = match_scontext64(
                scontext_i[31:0],
                textra64_tdata3_q[i].sselect,
                textra64_tdata3_q[i].sbytemask,
                textra64_tdata3_q[i].svalue
              );
            end
            priv_match[i] &= scontext_match[i];
          end
          i_set_v[i] = ex_i.cause[G6LCCfg.XLEN-1] &&
                       tdata2_q[i][ex_i.cause[4:0]];
          itrig_fire[i] = e_matched_q && priv_match[i] && mret_reg_q &&
                          |commit_ack_i;
          itrig_brk[i]  = itrig_fire[i] &&
                          (itrigger32_tdata1_q[i].action == 6'd0);
          itrig_dbg[i]  = itrig_fire[i] &&
                          (itrigger32_tdata1_q[i].action == 6'd1);
        end
      end
    end
  end
  // svt-stage: end TMA

  // svt-stage: begin TAC
  // hyp8 r3: registered action stage -- +1 trigger fire latency.
  always_ff @(posedge clk_i or negedge rst_ni) begin : action_stage
    if (~rst_ni) begin
      icnt_fire_q  <= '0;
      icnt_brk_q   <= '0;
      icnt_dbg_q   <= '0;
      mc6_fire_q   <= '0;
      etrig_fire_q <= '0;
      etrig_brk_q  <= '0;
      etrig_dbg_q  <= '0;
      itrig_fire_q <= '0;
      itrig_brk_q  <= '0;
      itrig_dbg_q  <= '0;
    end else if (G6LCCfg.SDTRIG) begin
      icnt_fire_q  <= icnt_fire;
      icnt_brk_q   <= icnt_brk;
      icnt_dbg_q   <= icnt_dbg;
      mc6_fire_q   <= mc6_fire;
      etrig_fire_q <= etrig_fire;
      etrig_brk_q  <= etrig_brk;
      etrig_dbg_q  <= etrig_dbg;
      itrig_fire_q <= itrig_fire;
      itrig_brk_q  <= itrig_brk;
      itrig_dbg_q  <= itrig_dbg;
    end
  end
  // svt-stage: end TAC



  if (G6LCCfg.IS_XLEN32) begin : gen_read_path_32
    always_comb begin : read_path
      tdata1_o  = '0;
      tselect_o = {{(G6LCCfg.XLEN - $clog2(N_Triggers)) {1'b0}}, tselect_q};
      unique case (trigger_type_q[tselect_q])
        4'd3: tdata1_o = icount32_tdata1_q[tselect_q];
        4'd6: tdata1_o = mcontrol6_32_tdata1_q[tselect_q];
        4'd5: tdata1_o = etrigger32_tdata1_q[tselect_q];
        4'd4: tdata1_o = itrigger32_tdata1_q[tselect_q];
        default: ;
      endcase
      tdata2_o = tdata2_q[tselect_q];
      tdata3_o = textra32_tdata3_q[tselect_q];
    end
  end else begin : gen_read_path_64
    always_comb begin : read_path
      tdata1_o  = '0;
      tselect_o = {{(G6LCCfg.XLEN - $clog2(N_Triggers)) {1'b0}}, tselect_q};
      unique case (trigger_type_q[tselect_q])
        4'd3:
        tdata1_o = {
          icount32_tdata1_q[tselect_q].t_type,
          icount32_tdata1_q[tselect_q].dmode,
          32'd0,
          icount32_tdata1_q[tselect_q][26:0]
        };
        4'd6:
        tdata1_o = {
          mcontrol6_32_tdata1_q[tselect_q].t_type,
          mcontrol6_32_tdata1_q[tselect_q].dmode,
          32'd0,
          mcontrol6_32_tdata1_q[tselect_q][26:0]
        };
        4'd5:
        tdata1_o = {
          etrigger32_tdata1_q[tselect_q].t_type,
          etrigger32_tdata1_q[tselect_q].dmode,
          etrigger32_tdata1_q[tselect_q].hit,
          45'd0,
          etrigger32_tdata1_q[tselect_q][12:0]
        };
        4'd4:
        tdata1_o = {
          itrigger32_tdata1_q[tselect_q].t_type,
          itrigger32_tdata1_q[tselect_q].dmode,
          itrigger32_tdata1_q[tselect_q].hit,
          45'd0,
          itrigger32_tdata1_q[tselect_q][12:0]
        };
        default: ;
      endcase
      tdata2_o = tdata2_q[tselect_q];
      tdata3_o = textra64_tdata3_q[tselect_q];
    end
  end


  always_ff @(posedge clk_i or negedge rst_ni) begin : state_update
    if (~rst_ni) begin
      if (G6LCCfg.SDTRIG) begin
        tselect_q <= '0;
        mcontrol6_debug_q <= 1'b0;
        e_matched_q <= 1'b0;
        mret_reg_q <= 1'b0;
        break_from_trigger_q <= 0;
        debug_from_trigger_q <= 0;
        in_trap_handler_q <= 0;
        for (int i = 0; i < N_Triggers; ++i) begin
          trigger_type_q[i]          <= '0;
          icount32_tdata1_q[i]       <= '0;
          icount32_tdata1_q[i].count <= 1;
          mcontrol6_32_tdata1_q[i]   <= '0;
          textra32_tdata3_q[i]       <= '0;
          textra64_tdata3_q[i]       <= '0;
          tdata2_q[i]                <= '0;
          etrigger32_tdata1_q[i]     <= '0;
          itrigger32_tdata1_q[i]     <= '0;
        end
      end
    end else begin
      if (G6LCCfg.SDTRIG) begin
        trigger_type_q        <= trigger_type_d;
        tselect_q             <= tselect_d;
        tdata2_q              <= tdata2_d;
        icount32_tdata1_q     <= icount32_tdata1_d;
        mcontrol6_32_tdata1_q <= mcontrol6_32_tdata1_d;
        etrigger32_tdata1_q   <= etrigger32_tdata1_d;
        itrigger32_tdata1_q   <= itrigger32_tdata1_d;
        textra32_tdata3_q     <= textra32_tdata3_d;
        textra64_tdata3_q     <= textra64_tdata3_d;
        mcontrol6_debug_q     <= mcontrol6_debug_d;
        break_from_trigger_q  <= break_from_trigger_d;
        debug_from_trigger_q  <= debug_from_trigger_d;
        in_trap_handler_q     <= in_trap_handler_d;
        e_matched_q           <= e_matched_d;
        mret_reg_q            <= mret_reg_d;
      end
    end
  end

  // Outputs
  assign debug_from_trigger_o  = debug_from_trigger_q;
  assign break_from_trigger_o  = break_from_trigger_q;
  assign debug_from_mcontrol_o = mcontrol6_debug_d & ~mcontrol6_debug_q;

  // svt-stage: class TWR value
  // svt-stage: class TMA value
  // svt-stage: class TAC value
endmodule
