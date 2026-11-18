# Zimop / Zcmop / Zihintntl (main tree) — hyp8 port notes

Status: **landed in `core/`**, cfg-gated, default 0 except the packages listed
below. Isolated leaves: `verif/tb/core/run-zimop-ntl.sh`. No git commit yet.

## Why this wave

RVA23 user-mode software (and later OpenWrt kernels) emit `mop.*` / `c.mop.*`
as padding and `ntl.*` before copies. Without decode those encodings trap.
Architectural effect is NOP / write-0; dual-issue OoO needs no new FU.

`zawrs` is `ZawrsEn` plus `g6lc_zawrs` wait and SMT peer snoop.
`RVZfa` is the F+D extra
FP set (fminm/fleq/fli/fround/fcvtmod); half Zfa follows `XF16`.

## Knobs

| Bit | `cva6_user_cfg_t` / `cva6_cfg_t` | `check_cfg` |
|---|---|---|
| `RVZimop` | mop.r.n / mop.rr.n | none |
| `RVZcmop` | c.mop.n | requires `RVC` (`build_config` forces 0 if `RVC=0`) |
| `RVZihintntl` | ntl.p/pall/s/all | none |
| `RVZfhmin` | flh/fsh, fmv.x.h/h.x, fcvt H↔S/D | requires `RVF`; `XF16` implies it |
| `RVZfa` | fminm/fmaxm, fleq/fltq, fli, fround/froundnx, fcvtmod.w.d | requires `RVF`; D ops follow `RVD` |
| `RVZicclsm` | misaligned integer/FP LS hardware split | AMOs/LRSC/CAS/CBO still trap |
| `RVZa64rs` | LR/SC reservation set ≤64 B | requires `RVA` and `DcacheLineWidth <= 512` |
| `RVZiccif` | aligned ILEN fetch atomicity | I$ line ≥ 32 b |
| `RVZiccrse` | RsrvEventual on cacheable+coherent | requires `RVA` |
| `RVZiccamoa` | AMO atomicity on cacheable+coherent | requires `RVA` |
| `RVZabha` | AMO .B/.H (no LR/SC/CAS) | requires `RVA` |

On: `g6lc64_ooo_int2_l3`, `g6lc64_ooo_int2_l3_v_ai`, `g6lc64_ooo_server`,
`g6lc64_smt2`. DTS tokens `zimop`, `zcmop`, `zihintntl`, `zfhmin`, `zfa`,
`zicclsm`, `za64rs`, `ziccif`, `ziccrse`, `ziccamoa`, `zabha` on the matching
`ariane-*.dts` (including `ariane-linux.dts`). SMT DTS lists `zawrs` (wait-for-peer snoop).

## Encodings

- **mop.r.n**: SYSTEM, funct3=100, `inst[31]=1`, `inst[27]=1`, `inst[24]=1`,
  `inst[23:20]=0`. n = `{inst[30:28], inst[26:25]}`. Writes 0 to `rd`.
- **mop.rr.n**: same with `inst[24]=0` (rs2 is x0–x15). Writes 0 to `rd`.
- **c.mop.n** (n odd 1..15): C1 C.LUI, `{inst[12],inst[6:2]}=0`, `rd` odd
  nonzero (`inst[11:7]`). Expands to `addi x0,x0,0` (0x00000013).
  `c.mop.1 = 16'h6081`.
- **ntl.p/pall/s/all**: `add x0, x0, x2/x3/x4/x5`. Knob clears `rs2` so the
  IQ does not wait on a dummy GPR.
- **fminm/fmaxm**: OP-FP funct5=00101, rm=010/011. fpnew MINMAX RDN/RUP.
- **fleq/fltq**: OP-FP funct5=10100, rm=100/101 on S/D. fpnew CMP RMM/ROD.
- **fli.fmt**: OP-FP funct5=11110, rs2=1, rm=000, `use_zimm`. Table in `g6lc_fp_zfa`.
- **fround/froundnx**: OP-FP funct5=01000, rs2=00100/00101. Round-to-integral-float.
- **fcvtmod.w.d**: OP-FP funct5=11000, fmt=D, rs2=01000, rm=RTZ. Modular wrap.
- **zicclsm**: intra-XLEN-word misaligned LS use existing BE/shift; wrapping
  accesses become two sequential beats (`g6lc_zicclsm.sv`).
- **za64rs**: exact-address LR/SC set in `g6lc_axi_lrsc` (1 address, ≤64 B).
  `g6lc_za64rs` membership + advertise predicate. Do not 64 B-mask the monitor.
- **zawrs**: WRS.NTO `0x00d00073` / WRS.STO `0x01d00073` decode to `WRS_NTO` /
  `WRS_STO` (`ZawrsEn`). `g6lc_zawrs` wait: NOP if no reservation; STO 8-cycle
  timeout; irq wake. Core-local replica from port-0 LR/store commits. SMT
  wait-for-peer: `g6lc_zawrs_peer` snoops the other hart on store/AMO. SMT DTS
  lists `zawrs`.
- **ziccif**: aligned 32-bit word is a contiguous slice of one I$ line
  (`g6lc_pma_zi`; live `g6lc_icache` `cl_sel`).
- **ziccrse**: aligned W/D LR/SC is reservable when `RVA`.
- **ziccamoa**: aligned W/D AMO; misaligned AMOs still trap.
- **zabha**: OpcodeAmo funct3=000/001; AXI ATOP uses byte/hword strb;
  `g6lc_zabha` subword RMW; WT missunit sign-extends B/H rd.

HLV/HSV share SYSTEM funct3=100 but `inst[31]=0`, so the arms do not overlap.

## OoO

ALU `ADD`, `rs1=rs2=x0`. `need_rd` follows `rd!=0` for mop (writes zero) and
is 0 for ntl (`rd=x0`). No IQ head rule, no port-0 steer, no CSR buffer.

## hyp8 port (do not edit the hyp tree in this drop)

hyp8 is a split of the same decoder at an 8-FO4 budget. Copy the main-tree
arms; do not invent a second encoding.

| Main tree | hyp8 |
|---|---|
| `core/include/config_pkg.sv` user+cfg bits + `check_cfg` | `hyp_redesign_core_8fo4/core/include/config_pkg.sv` |
| `core/include/build_config_pkg.sv` copy / `RVZcmop && RVC` | same path under hyp |
| `core/decoder.sv` SYSTEM `3'b100` zimop **before** HLV | `g6lc_decode_s2.sv` ~line 226 `OpcodeSystem` / `3'b100` |
| `core/decoder.sv` OpcodeOp ADD ntl rs2 clear | `g6lc_decode_s2.sv` OpcodeOp ADD arm |
| `core/decoder.sv` FLH/FSH + OP-FP fmt=H zfhmin | `g6lc_decode_s2.sv` OpcodeLoadFp/StoreFp and OpcodeOpFp fmt check |
| `core/decoder.sv` OpcodeOpFp Zfa rm/rs2 (fminm/fleq/fli/fround/fcvtmod) | `g6lc_decode_s2.sv` OpcodeOpFp funct5 00101/10100/01000/11110/11000 |
| `core/fpu_wrap.sv` FpFmtMask FP16 `XF16\|RVZfhmin`; ADDMUL/DIVSQRT FP16 DISABLED unless XF16 | hyp `fpu_wrap.sv` same |
| `core/fpu_wrap.sv` FCMP unmask rm[2] for fleq/fltq; mux `g6lc_fp_zfa` | hyp `fpu_wrap.sv` same + add `g6lc_fp_zfa.sv` to the hyp Flist |
| `core/cvfpu/src/fpnew_noncomp.sv` MINMAX RDN/RUP, CMP RMM/ROD | hyp cvfpu copy |
| `core/g6lc_fp_zfa.sv` fli table, fround-to-integral, fcvtmod.w.d | copy the file; do not map fround to F2F |
| `core/g6lc_zicclsm.sv` + `load_store_unit.sv` misalign suppress | copy the file; wire between bypass and `lsu_ctrl`; gate load_unit misalign asserts |
| `core/g6lc_za64rs.sv` + `RVZa64rs` check_cfg | copy the file; keep exact-address compare in hyp `g6lc_axi_lrsc` |
| `core/decoder.sv` Zawrs WRS→`WRS_NTO`/`WRS_STO` | `g6lc_decode_s2.sv` WRS arm: emit `WRS_*` not WFI |
| `core/g6lc_zawrs.sv` + `csr_regfile` wait | copy the file; wire enter/wake next to WFI |
| `core/g6lc_zawrs_peer.sv` + `res_snoop_i` | copy the file; snoop other banks on store/AMO; SMT DTS `zawrs` |
| `core/decoder.sv` OpcodeAmo funct3=000/001 | `g6lc_decode_s2.sv` AMO size arms |
| `core/g6lc_zabha.sv` + store_unit amo map | copy the file; map B/H to amo_t; WT missunit B/H sext |
| `core/g6lc_pma_zi.sv` + `RVZiccif`/`RVZiccrse`/`RVZiccamoa` | copy the file and check_cfg; I$ `cl_sel` is already the Ziccif extract |
| `core/compressed_decoder.sv` C.LUI zero-imm | hyp `compressed_decoder.sv` same C.LUI arm |
| package bits | `g6lc64_hyp8_config_pkg.sv`, `g6lc64_hyp8_mc_config_pkg.sv` |
| isolated leaves | rerun `run-zimop-ntl.sh` against the hyp sources, or a hyp decode leaf |

`g6lc_decode_s1` is wiring only. `g6lc_decode_s3` must not re-illegalise a
mop that s2 already accepted. If hyp still has a single `decoder.sv` as well
as the s1/s2/s3 split, patch the live path (`id_stage` instantiate), not the
unused file.

Directed follow-up (not in this drop): `verif/tests/custom/mini_zimop.S` on
`g6lc64_ooo_int2_l3` testharness PGO — `.word 0x89004573` into a0, expect 0.
