// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E0 + G1 + G1b — younger-cancel keep predicate.
//
// E0: I4m–cf exemptions (one function, two scoreboard sites).
// G1: sp-based callee-saved window (s0–s11 / ra) as a class — not I4af
// (stall all x8) and not another c.mv pair. SI still LOAD-only (cont.5).
// G1b: c.mv a0,s* restore class (offset_ptr_raw is a0←s0).
// G1c: c.mv s*,a0 save class (offset_ptr_raw is s0←a0).
// G1d: addi sp,sp,* (rd==x2 && rs1==x2).
// G1e: ALU self-add on a0–a7 (c.add a1,a5 / c.addiw a5,0).
// G1f: c.mv a*,a0 (offset_ptr is a5←a0).
// G1g: all ALU rd==a0 (load_be32 or a0,t0,t1). P3 is a third high-bit
// pointer (not fdt, not fdt+0x28, not 0/0x28/0x50). Do not re-land G0/W1/G6.
// G1h: IRO drop of execute-region-base forward on c.mv a0↔s*
// (s0 was boot 0x80000000; 2nd load_be32 read _start+8). Not a keep.
// G1i unresolved_a0 hold-FAIL — do not re-land.
// G1k: IRO LOAD — cached RF pointer beats a non-cached rs1 forward.
// G1o: IRO stall STORE rs2==ra while a same-hart jal/jalr (CTRL_FLOW
// rd==ra) is still issued. P6 0x65: sd ra stored P5's link.
// G1ae: same stall also when that jal is cancelled (sbe.valid; cancel
// sets valid and clears still_issued). TRACE: jal wrote after sd.
// G1af spec STQ no-forward HOLD-FAIL — do not re-land.
// G1ag: barrier stalls STORE ra while an older same-hart link-jal
// is still a valid ID head (pc < store.pc). Not G1i.
// G1ah: STQ spec entry that forwarded to a load is fwd_keep —
// cancel/flush must still drain it. Not G1af (all spec nofwd).
// G1ai: IRO stall STORE ra while a same-hart addi sp is still
// issued or on an earlier port. TRACE: sd fetched with sp=0x80008000.
// G1aj LOAD ra waits any STORE ra HOLD-FAIL — do not re-land.
// G1ak LOAD ra waits older STORE ra HOLD-FAIL — do not re-land.
// G1al: barrier stalls STORE ra while an older same-hart addi sp
// is still a valid ID head (pc < store.pc). Not G1ai (SB).
// G1an: IRO stall a use while a same-hart LOAD of that rs is
// still_issued or cancelled-valid (raw_checker misses cancel).
// TRACE G1am: c.ldsp t3 left t3=0xed. Not G1aj/G1ak.
// G1ao: STQ last-forward hold — replay to the next same-PA load
// after the store drains. Not G1af (all spec nofwd).
// G1ap 2-deep LSU ready MINI-HANG — do not re-land.
// G1aq: keep I$ line while an older NoCF is unconsumed before a
// Branch (G1y is Jump only). Not G1z/aa/ab/ac/G1ap.
// G1at ALU-li alloc on flush_unissued — HOLD-FAIL wfi-exit
// mepc=0x7204/6 hart1 sp=0. Do not re-land.
// G1p: IRO hold EX PC; only capture an acked CF (do not default pc_n
// to 0). Jal next_pc=4 + I4as dropped we_gpr — RF stayed P5 0x14c.
// G1q: I4as does not drop we_gpr to ra for CTRL_FLOW (jal/jalr link).
// G1r: branch_unit uses the issuing instr PC (IRO operand_c), not
// the shared EX pc_o. P6 jal must not retire P5's next_pc.
// G1s: commit still we_gpr a cancelled CTRL_FLOW rd==ra (page-0
// results stay dropped). Keep already has that predicate.
// G1t: a link-jal that IRO acks is not unissued fallthrough — allocate
// and keep branch_valid even when flush_unissued.
// G1u: |branch_valid forces flu result/tid from the branch port
// (ex_stage). I4ak ALU steal must not drop the jal link.
// G1v: SB alloc of a link-jal stores pc+ilen in sbe.result (not the
// J-imm). Commit/G1s can retire the link if flu never overwrites it.
// G1w: flu WB of a link-jal sets valid but keeps that alloc result
// when it already has high bits (do not take P5's 0x14c).
// G1x: link-jal is valid at alloc (like FU NONE) so commit writes
// the G1v link without waiting for flu. EX still resolves.
//
// Timing: 5-bit compares on the existing cancel cone; G1h is a 64-bit
// equality OR on the existing IRO forward mux. No sequential logic.

package g6lc_sb_keep;
  import config_pkg::*;
  import ariane_pkg::*;

  // ABI callee-saved: s0–s1 (x8–x9), s2–s11 (x18–x27).
  function automatic logic callee_saved(input logic [4:0] r);
    callee_saved = (r == 5'd8) || (r == 5'd9) ||
                   ((r >= 5'd18) && (r <= 5'd27));
  endfunction

  // ra / alternate-link plus callee-saved.
  function automatic logic abi_keep_reg(input logic [4:0] r);
    abi_keep_reg = (r == 5'd1) || (r == 5'd5) || callee_saved(r);
  endfunction

  // ABI args a0–a7 (x10–x17).
  function automatic logic arg_reg(input logic [4:0] r);
    arg_reg = (r >= 5'd10) && (r <= 5'd17);
  endfunction

  // G1b/c: c.mv a0↔s* (pointer save/restore).
  function automatic logic cmv_abi_ptr(
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2,
      input logic       use_imm
  );
    cmv_abi_ptr = !use_imm && rs1 == 5'd0 &&
                  ((callee_saved(rd) && rs2 == 5'd10) ||
                   (rd == 5'd10 && callee_saved(rs2)));
  endfunction

  // Non-zero execute-region base (boot 0x80000000 / sign-ext alias / bootrom).
  // NULL (0) is a legal c.mv immediate-like copy — do not treat as boot.
  function automatic logic exec_region_base(
      input cva6_cfg_t   cfg,
      input logic [63:0] v
  );
    exec_region_base = 1'b0;
    for (int unsigned k = 0; k < NrMaxRules; k++) begin
      if (k < cfg.NrExecuteRegionRules &&
          v != 64'b0 &&
          v == cfg.ExecuteRegionAddrBase[k]) begin
        exec_region_base = 1'b1;
      end
    end
  endfunction

  // G1d / G1ai: addi sp,sp,* (c.addi16sp). Frame adjust.
  function automatic logic addi_sp(
      input fu_t        fu,
      input logic [4:0] rd,
      input logic [4:0] rs1
  );
    addi_sp = fu == ALU && rd == 5'd2 && rs1 == 5'd2;
  endfunction

  // G1ax leftover-RVI CF skip unresolved_cf — HOLD-FAIL plat_hc=80.
  // Do not re-land.

  // G1ay: ALU/LOAD dest (c.li / c.ldsp). Not CTRL_FLOW.
  function automatic logic nocf_dest(
      input fu_t        fu,
      input logic [4:0] rd
  );
    nocf_dest = (fu == ALU || fu == LOAD) && rd != 5'd0;
  endfunction

  // G1bg: architectural older same-line NoCF dest vs a resolving
  // Branch. SB order can put c.li after beq@0x4d4; bmiss then
  // cancels it. Not G1at (no alloc on flush). SMT+SS.
  // G1bh: same predicate lets that dest issue while the Branch is
  // still unresolved_cf. Not G1ax.
  function automatic logic keep_prefix(
      input cva6_cfg_t   cfg,
      input fu_t         fu,
      input logic [4:0]  rd,
      input logic [63:0] pc,
      input logic [63:0] branch_pc,
      input cf_t         cf_type
  );
    keep_prefix = cfg.SuperscalarEn && cfg.NrHarts > 1 &&
                  cf_type == Branch &&
                  nocf_dest(fu, rd) &&
                  (pc < branch_pc) &&
                  (pc[63:3] == branch_pc[63:3]);
  endfunction

  // G1t: jal/jalr that writes ra. Not a keep — alloc / EX valid.
  function automatic logic link_jal(
      input logic       ss,
      input fu_t        fu,
      input logic [4:0] rd
  );
    link_jal = ss && fu == CTRL_FLOW && rd == 5'd1;
  endfunction

  // G1v: jal/jalr link = instr PC + 2/4. Not a keep.
  function automatic logic [63:0] link(
      input logic [63:0] pc,
      input logic        is_compressed
  );
    link = pc + (is_compressed ? 64'd2 : 64'd4);
  endfunction

  // G1w: keep alloc-time pc+ilen over flu data.
  function automatic logic keep_alloc_link(
      input cva6_cfg_t   cfg,
      input fu_t         fu,
      input logic [4:0]  rd,
      input logic [63:0] result
  );
    keep_alloc_link = cfg.SuperscalarEn && cfg.NrHarts > 1 &&
                      link_jal(cfg.SuperscalarEn, fu, rd) &&
                      |result[63:12];
  endfunction

  // SB alloc: unissued flush still takes a link-jal (IRO already acked).
  // SI / no-link: identity on !flush_unissued.
  // G1at ALU-li alloc HOLD-FAIL — do not re-land.
// G1ax leftover-RVI skip unresolved_cf HOLD-FAIL — do not re-land.
// G1ay: same-line Branch waits for older unissued ALU/LOAD dest.
// G1bg: keep older same-line NoCF dest on Branch bmiss. Not G1at.
  function automatic logic alloc(
      input cva6_cfg_t  cfg,
      input logic       flush_unissued,
      input fu_t        fu,
      input logic [4:0] rd
  );
    alloc = !flush_unissued ||
            (cfg.NrHarts > 1 && link_jal(cfg.SuperscalarEn, fu, rd));
  endfunction

  function automatic logic keep(
      input cva6_cfg_t cfg,
      input fu_t       fu,
      input fu_op      op,
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2,
      input logic       use_imm
  );
    logic ss;
    ss = cfg.SuperscalarEn;
    keep = 1'b0;
    // G1 + I4n/ai/bn: stack save of ra / s* / a0 / a6
    if (ss && fu == STORE && !is_amo(op) &&
        (abi_keep_reg(rs2) || rs2 == 5'd10 || rs2 == 5'd16)) begin
      keep = 1'b1;
    end else if (ss && fu == CTRL_FLOW && rd == 5'd1) begin
      keep = 1'b1;
    // G1 + I4aj: addi s*,sp. G1d: addi sp,sp,*
    end else if (ss && fu == ALU && callee_saved(rd) && rs1 == 5'd2) begin
      keep = 1'b1;
    end else if (ss && fu == ALU && rd == 5'd2 && rs1 == 5'd2) begin
      keep = 1'b1;
    end else if (ss && fu == ALU && rd == 5'd10 && rs1 == 5'd10) begin
      keep = 1'b1;
    // G1g: any ALU write of a0 (BE or a0,t0,t1)
    end else if (ss && fu == ALU && rd == 5'd10) begin
      keep = 1'b1;
    // G1e: c.add / c.addiw of an arg (offset_ptr a1+=a5, a5+=0)
    end else if (ss && fu == ALU && rd == rs1 && arg_reg(rd)) begin
      keep = 1'b1;
    end else if (ss && fu == ALU && !use_imm && rs1 == 5'd0 &&
                 ((rd == 5'd10 && callee_saved(rs2)) ||
                  (callee_saved(rd) && rs2 == 5'd10) ||
                  (arg_reg(rd) && rs2 == 5'd10))) begin
      keep = 1'b1;
    end else if (ss && fu == ALU && use_imm &&
                 (rd == 5'd5 || rd == 5'd6) &&
                 (rs1 == rd || rs1 == 5'd0)) begin
      keep = 1'b1;
    // G1 + I4m/al/aq/cb: link / s* from sp; still keep LOAD rs1==s0/a0
    end else if (fu == LOAD &&
                 (!ss || rd == 5'd1 || rd == 5'd5 ||
                  rs1 == 5'd8 || rs1 == 5'd10 ||
                  (callee_saved(rd) && rs1 == 5'd2))) begin
      keep = 1'b1;
    end
  endfunction

endpackage
