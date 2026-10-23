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
  // pragma translate_off
  initial begin
    assert (G6LCCfg.XLEN == 64);
    assert (G6LCCfg.SDTRIG == 1'b0);
    assert (N_Triggers == 4);
  end
  // pragma translate_on
  assign type_nibble = tdata1_i[63:60];
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
  // Hyp8: XLEN 64, four triggers. One next-record per type, then a per-slot mux.
  logic [3:0] type_nibble, type_at_sel;
  logic type_we;
  icount32_tdata1_t icount_next;
  mcontrol6_32_tdata1_t mc6_next;
  etrigger32_tdata1_t etrig_next;
  itrigger32_tdata1_t itrig_next;
  logic [63:0] tex64_q0, tex64_q1, tex64_q2, tex64_q3;
  logic [31:0] tex64_n_hi, tex64_n_lo;
  logic [31:0] tex64_0h, tex64_0l, tex64_1h, tex64_1l;
  logic [31:0] tex64_2h, tex64_2l, tex64_3h, tex64_3l;
  // Bare 1-bit selects. A compound guard on a 32-bit mux pays a select load per bit.
  logic td3_0, td3_1, td3_2, td3_3;
  logic td3_0a, td3_0b, td3_0c, td3_0d;
  logic td3_1a, td3_1b, td3_1c, td3_1d;
  logic td3_2a, td3_2b, td3_2c, td3_2d;
  logic td3_3a, td3_3b, td3_3c, td3_3d;
  logic [15:0] tx0a, tx0b, tx0c, tx0d;
  logic [15:0] tx1a, tx1b, tx1c, tx1d;
  logic [15:0] tx2a, tx2b, tx2c, tx2d;
  logic [15:0] tx3a, tx3b, tx3c, tx3d;
  logic [31:0] ic_n, mc_n, et_n, it_n;
  logic [31:0] ic_q0, ic_q1, ic_q2, ic_q3;
  logic [31:0] mc_q0, mc_q1, mc_q2, mc_q3;
  logic [31:0] et_q0, et_q1, et_q2, et_q3;
  logic [31:0] it_q0, it_q1, it_q2, it_q3;
  logic ic3_0, ic3_1, ic3_2, ic3_3;
  logic ic3_0h, ic3_0l, ic3_1h, ic3_1l, ic3_2h, ic3_2l, ic3_3h, ic3_3l;
  logic mc6_0, mc6_1, mc6_2, mc6_3;
  logic mc6_0h, mc6_0l, mc6_1h, mc6_1l, mc6_2h, mc6_2l, mc6_3h, mc6_3l;
  logic et5_0, et5_1, et5_2, et5_3;
  logic et5_0h, et5_0l, et5_1h, et5_1l, et5_2h, et5_2l, et5_3h, et5_3l;
  logic it4_0, it4_1, it4_2, it4_3;
  logic it4_0h, it4_0l, it4_1h, it4_1l, it4_2h, it4_2l, it4_3h, it4_3l;
  logic [15:0] ic_d0h, ic_d0l, ic_d1h, ic_d1l, ic_d2h, ic_d2l, ic_d3h, ic_d3l;
  logic [15:0] mc_d0h, mc_d0l, mc_d1h, mc_d1l, mc_d2h, mc_d2l, mc_d3h, mc_d3l;
  logic [15:0] et_d0h, et_d0l, et_d1h, et_d1l, et_d2h, et_d2l, et_d3h, et_d3l;
  logic [15:0] it_d0h, it_d0l, it_d1h, it_d1l, it_d2h, it_d2l, it_d3h, it_d3l;


  // svt-stage: begin TWR
  // Trigger CSRs write/update logic
  // Hyp8 SDTRIG is off, so the apply/countdown block is not present.
  // Types 3 and 6 still flush on a tdata1 write.
  always_comb begin : write_path
    mcontrol6_debug_d    = mcontrol6_debug_q;
    e_matched_d          = e_matched_q;
    mret_reg_d           = mret_reg_q;
    break_from_trigger_d = break_from_trigger_q;
    in_trap_handler_d    = in_trap_handler_q;
    debug_from_trigger_d = debug_from_trigger_q;
    flush_o              = tdata1_we && ((type_nibble == 4'd3) || (type_nibble == 4'd6));
  end

  // $clog2(N_Triggers) part-select does not fold. N_Triggers is 4.
  assign tselect_d = (tselect_we && (tselect_i[63:2] == '0)) ? tselect_i[1:0] : tselect_q;

  always_comb begin : type_at_sel_dec
    unique case (tselect_q)
      2'd0: type_at_sel = trigger_type_q[0];
      2'd1: type_at_sel = trigger_type_q[1];
      2'd2: type_at_sel = trigger_type_q[2];
      default: type_at_sel = trigger_type_q[3];
    endcase
  end
  assign type_we = tdata1_we && ((type_nibble == 4'd3) || (type_nibble == 4'd6) ||
                                 (type_nibble == 4'd5) || (type_nibble == 4'd4));
  assign trigger_type_d[0] = (type_we && (tselect_q == 2'd0)) ? type_nibble : trigger_type_q[0];
  assign trigger_type_d[1] = (type_we && (tselect_q == 2'd1)) ? type_nibble : trigger_type_q[1];
  assign trigger_type_d[2] = (type_we && (tselect_q == 2'd2)) ? type_nibble : trigger_type_q[2];
  assign trigger_type_d[3] = (type_we && (tselect_q == 2'd3)) ? type_nibble : trigger_type_q[3];

  // One record, then four literal slot muxes. A variable [tselect_q] write chains.
  assign icount_next = '{
    t_type: ((type_nibble == 4'd3) || (type_nibble == 4'd15)) ? type_nibble : type_at_sel,
    dmode: tdata1_i[59],
    vs: 1'b0,
    vu: 1'b0,
    hit: tdata1_i[24],
    count: tdata1_i[23:10],
    m: tdata1_i[9],
    pending: tdata1_i[8],
    s: tdata1_i[7],
    u: tdata1_i[6],
    action: tdata1_i[5:0]
  };
  assign ic_n  = icount_next;
  assign ic_q0 = icount32_tdata1_q[0];
  assign ic_q1 = icount32_tdata1_q[1];
  assign ic_q2 = icount32_tdata1_q[2];
  assign ic_q3 = icount32_tdata1_q[3];
  assign ic3_0 = tdata1_we && (tdata1_i[63:60] == 4'd3) && (tselect_q == 2'd0);
  assign ic3_1 = tdata1_we && (tdata1_i[63:60] == 4'd3) && (tselect_q == 2'd1);
  assign ic3_2 = tdata1_we && (tdata1_i[63:60] == 4'd3) && (tselect_q == 2'd2);
  assign ic3_3 = tdata1_we && (tdata1_i[63:60] == 4'd3) && (tselect_q == 2'd3);
  assign ic3_0h = ic3_0;
  assign ic3_0l = ic3_0;
  assign ic3_1h = ic3_1;
  assign ic3_1l = ic3_1;
  assign ic3_2h = ic3_2;
  assign ic3_2l = ic3_2;
  assign ic3_3h = ic3_3;
  assign ic3_3l = ic3_3;
  assign ic_d0h = ic3_0h ? ic_n[31:16] : ic_q0[31:16];
  assign ic_d0l = ic3_0l ? ic_n[15:0] : ic_q0[15:0];
  assign ic_d1h = ic3_1h ? ic_n[31:16] : ic_q1[31:16];
  assign ic_d1l = ic3_1l ? ic_n[15:0] : ic_q1[15:0];
  assign ic_d2h = ic3_2h ? ic_n[31:16] : ic_q2[31:16];
  assign ic_d2l = ic3_2l ? ic_n[15:0] : ic_q2[15:0];
  assign ic_d3h = ic3_3h ? ic_n[31:16] : ic_q3[31:16];
  assign ic_d3l = ic3_3l ? ic_n[15:0] : ic_q3[15:0];
  assign icount32_tdata1_d[0] = {ic_d0h, ic_d0l};
  assign icount32_tdata1_d[1] = {ic_d1h, ic_d1l};
  assign icount32_tdata1_d[2] = {ic_d2h, ic_d2l};
  assign icount32_tdata1_d[3] = {ic_d3h, ic_d3l};

  assign mc6_next = '{
    t_type: ((type_nibble == 4'd6) || (type_nibble == 4'd15)) ? type_nibble : type_at_sel,
    dmode: tdata1_i[59],
    uncertain: 1'b0,
    hit1: tdata1_i[25],
    vs: 1'b0,
    vu: 1'b0,
    hit0: tdata1_i[22],
    select: tdata1_i[21],
    zeroes: '0,
    size: tdata1_i[18:16],
    action: tdata1_i[15:12],
    chain: 1'b0,
    match: tdata1_i[10:7],
    m: tdata1_i[6],
    uncertainen: 1'b0,
    s: tdata1_i[4],
    u: tdata1_i[3],
    execute: tdata1_i[2],
    store: tdata1_i[1],
    load: tdata1_i[0]
  };
  assign mc_n  = mc6_next;
  assign mc_q0 = mcontrol6_32_tdata1_q[0];
  assign mc_q1 = mcontrol6_32_tdata1_q[1];
  assign mc_q2 = mcontrol6_32_tdata1_q[2];
  assign mc_q3 = mcontrol6_32_tdata1_q[3];
  assign mc6_0 = tdata1_we && (tdata1_i[63:60] == 4'd6) && (tselect_q == 2'd0);
  assign mc6_1 = tdata1_we && (tdata1_i[63:60] == 4'd6) && (tselect_q == 2'd1);
  assign mc6_2 = tdata1_we && (tdata1_i[63:60] == 4'd6) && (tselect_q == 2'd2);
  assign mc6_3 = tdata1_we && (tdata1_i[63:60] == 4'd6) && (tselect_q == 2'd3);
  assign mc6_0h = mc6_0;
  assign mc6_0l = mc6_0;
  assign mc6_1h = mc6_1;
  assign mc6_1l = mc6_1;
  assign mc6_2h = mc6_2;
  assign mc6_2l = mc6_2;
  assign mc6_3h = mc6_3;
  assign mc6_3l = mc6_3;
  assign mc_d0h = mc6_0h ? mc_n[31:16] : mc_q0[31:16];
  assign mc_d0l = mc6_0l ? mc_n[15:0] : mc_q0[15:0];
  assign mc_d1h = mc6_1h ? mc_n[31:16] : mc_q1[31:16];
  assign mc_d1l = mc6_1l ? mc_n[15:0] : mc_q1[15:0];
  assign mc_d2h = mc6_2h ? mc_n[31:16] : mc_q2[31:16];
  assign mc_d2l = mc6_2l ? mc_n[15:0] : mc_q2[15:0];
  assign mc_d3h = mc6_3h ? mc_n[31:16] : mc_q3[31:16];
  assign mc_d3l = mc6_3l ? mc_n[15:0] : mc_q3[15:0];
  assign mcontrol6_32_tdata1_d[0] = {mc_d0h, mc_d0l};
  assign mcontrol6_32_tdata1_d[1] = {mc_d1h, mc_d1l};
  assign mcontrol6_32_tdata1_d[2] = {mc_d2h, mc_d2l};
  assign mcontrol6_32_tdata1_d[3] = {mc_d3h, mc_d3l};

  assign etrig_next = '{
    t_type: ((type_nibble == 4'd5) || (type_nibble == 4'd15)) ? type_nibble : type_at_sel,
    dmode: tdata1_i[59],
    hit: tdata1_i[58],
    zeroes: '0,
    vs: 1'b0,
    vu: 1'b0,
    zeroed: 1'b0,
    m: tdata1_i[9],
    zero: 1'b0,
    s: tdata1_i[7],
    u: tdata1_i[6],
    action: tdata1_i[5:0]
  };
  assign et_n  = etrig_next;
  assign et_q0 = etrigger32_tdata1_q[0];
  assign et_q1 = etrigger32_tdata1_q[1];
  assign et_q2 = etrigger32_tdata1_q[2];
  assign et_q3 = etrigger32_tdata1_q[3];
  assign et5_0 = tdata1_we && (tdata1_i[63:60] == 4'd5) && (tselect_q == 2'd0);
  assign et5_1 = tdata1_we && (tdata1_i[63:60] == 4'd5) && (tselect_q == 2'd1);
  assign et5_2 = tdata1_we && (tdata1_i[63:60] == 4'd5) && (tselect_q == 2'd2);
  assign et5_3 = tdata1_we && (tdata1_i[63:60] == 4'd5) && (tselect_q == 2'd3);
  assign et5_0h = et5_0;
  assign et5_0l = et5_0;
  assign et5_1h = et5_1;
  assign et5_1l = et5_1;
  assign et5_2h = et5_2;
  assign et5_2l = et5_2;
  assign et5_3h = et5_3;
  assign et5_3l = et5_3;
  assign et_d0h = et5_0h ? et_n[31:16] : et_q0[31:16];
  assign et_d0l = et5_0l ? et_n[15:0] : et_q0[15:0];
  assign et_d1h = et5_1h ? et_n[31:16] : et_q1[31:16];
  assign et_d1l = et5_1l ? et_n[15:0] : et_q1[15:0];
  assign et_d2h = et5_2h ? et_n[31:16] : et_q2[31:16];
  assign et_d2l = et5_2l ? et_n[15:0] : et_q2[15:0];
  assign et_d3h = et5_3h ? et_n[31:16] : et_q3[31:16];
  assign et_d3l = et5_3l ? et_n[15:0] : et_q3[15:0];
  assign etrigger32_tdata1_d[0] = {et_d0h, et_d0l};
  assign etrigger32_tdata1_d[1] = {et_d1h, et_d1l};
  assign etrigger32_tdata1_d[2] = {et_d2h, et_d2l};
  assign etrigger32_tdata1_d[3] = {et_d3h, et_d3l};

  assign itrig_next = '{
    t_type: ((type_nibble == 4'd4) || (type_nibble == 4'd15)) ? type_nibble : type_at_sel,
    dmode: tdata1_i[59],
    hit: tdata1_i[58],
    zeroed: '0,
    vs: 1'b0,
    vu: 1'b0,
    nmi: 1'b0,
    m: tdata1_i[9],
    zero: 1'b0,
    s: tdata1_i[7],
    u: tdata1_i[6],
    action: tdata1_i[5:0]
  };
  assign it_n  = itrig_next;
  assign it_q0 = itrigger32_tdata1_q[0];
  assign it_q1 = itrigger32_tdata1_q[1];
  assign it_q2 = itrigger32_tdata1_q[2];
  assign it_q3 = itrigger32_tdata1_q[3];
  assign it4_0 = tdata1_we && (tdata1_i[63:60] == 4'd4) && (tselect_q == 2'd0);
  assign it4_1 = tdata1_we && (tdata1_i[63:60] == 4'd4) && (tselect_q == 2'd1);
  assign it4_2 = tdata1_we && (tdata1_i[63:60] == 4'd4) && (tselect_q == 2'd2);
  assign it4_3 = tdata1_we && (tdata1_i[63:60] == 4'd4) && (tselect_q == 2'd3);
  assign it4_0h = it4_0;
  assign it4_0l = it4_0;
  assign it4_1h = it4_1;
  assign it4_1l = it4_1;
  assign it4_2h = it4_2;
  assign it4_2l = it4_2;
  assign it4_3h = it4_3;
  assign it4_3l = it4_3;
  assign it_d0h = it4_0h ? it_n[31:16] : it_q0[31:16];
  assign it_d0l = it4_0l ? it_n[15:0] : it_q0[15:0];
  assign it_d1h = it4_1h ? it_n[31:16] : it_q1[31:16];
  assign it_d1l = it4_1l ? it_n[15:0] : it_q1[15:0];
  assign it_d2h = it4_2h ? it_n[31:16] : it_q2[31:16];
  assign it_d2l = it4_2l ? it_n[15:0] : it_q2[15:0];
  assign it_d3h = it4_3h ? it_n[31:16] : it_q3[31:16];
  assign it_d3l = it4_3l ? it_n[15:0] : it_q3[15:0];
  assign itrigger32_tdata1_d[0] = {it_d0h, it_d0l};
  assign itrigger32_tdata1_d[1] = {it_d1h, it_d1l};
  assign itrigger32_tdata1_d[2] = {it_d2h, it_d2l};
  assign itrigger32_tdata1_d[3] = {it_d3h, it_d3l};

  // textra32 is the XLEN32 arm. Hyp8 holds the previous value.
  assign textra32_tdata3_d = textra32_tdata3_q;
  // High word: {24'b0, sbytemask, 2'b0, svalue[33:32]}. Low word: {svalue[31:2], sselect}.
  assign tex64_n_hi = {24'b0, tdata3_i[39:36], 2'b0, tdata3_i[33:32]};
  assign tex64_n_lo = {tdata3_i[31:2], tdata3_i[1:0]};
  assign tex64_q0     = textra64_tdata3_q[0];
  assign tex64_q1     = textra64_tdata3_q[1];
  assign tex64_q2     = textra64_tdata3_q[2];
  assign tex64_q3     = textra64_tdata3_q[3];
  assign td3_0 = tdata3_we && (tselect_q == 2'd0);
  assign td3_1 = tdata3_we && (tselect_q == 2'd1);
  assign td3_2 = tdata3_we && (tselect_q == 2'd2);
  assign td3_3 = tdata3_we && (tselect_q == 2'd3);
  assign td3_0a = td3_0;
  assign td3_0b = td3_0;
  assign td3_0c = td3_0;
  assign td3_0d = td3_0;
  assign td3_1a = td3_1;
  assign td3_1b = td3_1;
  assign td3_1c = td3_1;
  assign td3_1d = td3_1;
  assign td3_2a = td3_2;
  assign td3_2b = td3_2;
  assign td3_2c = td3_2;
  assign td3_2d = td3_2;
  assign td3_3a = td3_3;
  assign td3_3b = td3_3;
  assign td3_3c = td3_3;
  assign td3_3d = td3_3;
  assign tx0a = td3_0a ? tex64_n_hi[31:16] : tex64_q0[63:48];
  assign tx0b = td3_0b ? tex64_n_hi[15:0] : tex64_q0[47:32];
  assign tx0c = td3_0c ? tex64_n_lo[31:16] : tex64_q0[31:16];
  assign tx0d = td3_0d ? tex64_n_lo[15:0] : tex64_q0[15:0];
  assign tx1a = td3_1a ? tex64_n_hi[31:16] : tex64_q1[63:48];
  assign tx1b = td3_1b ? tex64_n_hi[15:0] : tex64_q1[47:32];
  assign tx1c = td3_1c ? tex64_n_lo[31:16] : tex64_q1[31:16];
  assign tx1d = td3_1d ? tex64_n_lo[15:0] : tex64_q1[15:0];
  assign tx2a = td3_2a ? tex64_n_hi[31:16] : tex64_q2[63:48];
  assign tx2b = td3_2b ? tex64_n_hi[15:0] : tex64_q2[47:32];
  assign tx2c = td3_2c ? tex64_n_lo[31:16] : tex64_q2[31:16];
  assign tx2d = td3_2d ? tex64_n_lo[15:0] : tex64_q2[15:0];
  assign tx3a = td3_3a ? tex64_n_hi[31:16] : tex64_q3[63:48];
  assign tx3b = td3_3b ? tex64_n_hi[15:0] : tex64_q3[47:32];
  assign tx3c = td3_3c ? tex64_n_lo[31:16] : tex64_q3[31:16];
  assign tx3d = td3_3d ? tex64_n_lo[15:0] : tex64_q3[15:0];
  assign tex64_0h = {tx0a, tx0b};
  assign tex64_0l = {tx0c, tx0d};
  assign tex64_1h = {tx1a, tx1b};
  assign tex64_1l = {tx1c, tx1d};
  assign tex64_2h = {tx2a, tx2b};
  assign tex64_2l = {tx2c, tx2d};
  assign tex64_3h = {tx3a, tx3b};
  assign tex64_3l = {tx3c, tx3d};
  assign textra64_tdata3_d[0] = {tex64_0h, tex64_0l};
  assign textra64_tdata3_d[1] = {tex64_1h, tex64_1l};
  assign textra64_tdata3_d[2] = {tex64_2h, tex64_2l};
  assign textra64_tdata3_d[3] = {tex64_3h, tex64_3l};

  // Indexed store stays one process. Four 64-bit slot muxes measured long elsewhere.
  always_comb begin : wr_tdata2
    tdata2_d = tdata2_q;
    if (tdata2_we) tdata2_d[tselect_q] = tdata2_i;
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
    if (1'b0) begin // Hyp8 SDTRIG is off
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
            if (1'b0) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else if (1'b1) begin
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
            if (1'b0) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else if (1'b1) begin
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
            if (1'b0) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else if (1'b1) begin
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
            if (1'b0) begin
              scontext_match[i] = match_scontext32(
                scontext_i[31:0],
                textra32_tdata3_q[i].sselect,
                textra32_tdata3_q[i].sbytemask,
                textra32_tdata3_q[i].svalue
              );
            end else if (1'b1) begin
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
    end else if (1'b0) begin // Hyp8 SDTRIG is off
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



  if (1'b0) begin : gen_read_path_32
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
      if (1'b0) begin // Hyp8 SDTRIG is off
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
      if (1'b0) begin // Hyp8 SDTRIG is off
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
