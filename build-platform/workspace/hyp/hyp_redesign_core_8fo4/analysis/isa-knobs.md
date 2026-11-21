# hyp8-mc ISA extension knobs — reference

Maps every ISA-related `cva6_cfg_t` knob in the hyp8 multicore config to the
RISC-V extension(s) it gates, the datapath that implements it, whether the
`.dts` advertises it, and its qualification status.

**Advertise contract (binding):** a knob may be set `=1` *and* the extension
named in `verif/regress/remote/hyp8/g6lc-hyp8-mc.dts` (`riscv,isa` /
`riscv,isa-extensions`) only when the full decode→execute path is ported and
directed-verified. Advertising an unimplemented extension traps legal code.
Keep `=0` (and un-advertised) until the dedicated test is green.

## Source-of-truth files

| Concern | File |
|---|---|
| Config knobs | `core/include/g6lc64_hyp8_mc_config_pkg.sv` (`localparam G6LCConfig*` → `cva6_cfg_t` fields) |
| Decode | `core/g6lc_decode_s1.sv`, `g6lc_decode_s2.sv`, `g6lc_decode_s3.sv` |
| FP execute | `core/fpu_wrap.sv`, `core/cvfpu/src/fpnew_noncomp.sv`, `core/g6lc_fp_zfa.sv` |
| Zicclsm | `core/g6lc_zicclsm.sv` |
| Zawrs | `core/g6lc_zawrs.sv`, `core/g6lc_zawrs_peer.sv` |
| PMA-Zi | `core/g6lc_pma_zi.sv` (orphan — not yet wired into a consumer) |
| Za64rs / AMO / LR-SC | `core/g6lc_za64rs.sv` (leaf); reservation monitor `../hyp_redesign_corev_apu_8fo4/corev_apu/src/g6lc_axi_lrsc.sv` + `g6lc_axi_atomics_wrap.sv` (`NRes=8`) |
| Advertise | `verif/regress/remote/hyp8/g6lc-hyp8-mc.dts` (all `cpu@` nodes) |

## Advertised string (current)

```
rv64imafdc_zba_zbb_zbs_zfa_zfhmin_zicboz_zicsr_zifencei_zacas_zcmop
  _ziccif_ziccamoa_ziccrse_zimop_zihintntl
```

## Knob → extension → status

### Base / standard IMADFDC

| Knob | Value | Ext | Path | Advertised | Status |
|---|---|---|---|---|---|
| `G6LCConfigXlen=64` | — | rv64 | — | `rv64` | base |
| `G6LCConfigCExtEn=1` | `RVC` | C / Zca | compressed decode | `c` | done |
| `G6LCConfigAExtEn=1` | `RVA` | A → zaamo, zalrsc | AMO + LR/SC (`g6lc_axi_lrsc`) | `a` (implies zaamo/zalrsc) | done |
| `G6LCConfigBExtEn=1` | `RVB` | B → zba,zbb,zbs,zbc | `g6lc_decode_s2` + ALU | `zba,zbb,zbs` | done; **zbc not yet in string** |
| `G6LCConfigRVF=1`/`RVD=1` | — | F,D / Zcf,Zcd | `fpu_wrap`+fpnew | `f,d` | done |
| `G6LCConfigZcbExtEn=1` | `RVZCB` | Zcb | decode | — | enabled, **not advertised** |
| `G6LCConfigRVZiCond=1` | `RVZiCond` | Zicond | decode+execute | — | enabled, **not advertised** |

### Implemented + advertised (this session's port)

| Knob | Value | Ext | Datapath | Advertised | Status |
|---|---|---|---|---|---|
| `RVZfa=1` | on | **zfa** | `g6lc_decode_s2` (fli/fround/froundnx/fcvtmod/fminm/fmaxm/fleq/fltq) → `fpu_wrap` zfa mux → `g6lc_fp_zfa` + `fpnew_noncomp` RMM/ROD | `zfa` | ported, pending directed-test green |
| `RVZfhmin=1` | on | **zfhmin** | `g6lc_decode_s2` FLH/FSH + fcvt H↔S/D; `fpu_wrap` `FpFmtMask` FP16 slot (`XF16\|RVZfhmin`), FP16 arith disabled | `zfhmin` | ported, pending directed-test green |

### Implemented, config-enabled (=1) — pre-existing

| Knob | Value | Ext | Datapath | Advertised | Status |
|---|---|---|---|---|---|
| `RVZacas=1` | on | **zacas** | AMOCAS.W/D decode→`g6lc_axi_lrsc` | `zacas` | done |
| `RVZimop=1` | on | **zimop** | mop.r.n/mop.rr.n → write-0 NOP | `zimop` | decode-only, done |
| `RVZcmop=1` | on | **zcmop** | c.mop.n → `addi x0,x0,0` (needs RVC) | `zcmop` | decode-only, done |
| `RVZihintntl=1` | on | **zihintntl** | ntl.* drop dummy rs2 wait | `zihintntl` | decode-only, done |
| `RVZiCbom/RVZiCboz/RVZiCbop=1` | on | zicbom/zicboz/zicbop | decode→store_unit→stb_drain→`wt_dcache cmo_op` | `zicboz` only | zicbom/zicbop **enabled not advertised** |
| `RVZicclsm=1` | on | **zicclsm** | `g6lc_zicclsm` two-beat LSU splitter (XLEN-word-wrap misaligned ldst; AMO/LRSC/CBO excluded) | — | implemented, **not advertised** |
| `RVZicntr=1`/`RVZihpm=1` | on | zicntr/zihpm | `perf_counters` | — | enabled, **not advertised** |
| `RVZiccif/RVZiccrse/RVZiccamoa=1` | on | ziccif/ziccrse/ziccamoa | PMA/AMO property advertisements | all three | done |
| `ZihintpauseEn=1` | on | zihintpause | hint pause | — | enabled, **not advertised** |
| `ZawrsEn=1` | on | **zawrs** | `g6lc_zawrs`+`g6lc_zawrs_peer` | — | enabled, **not advertised** |
| `SstcEn/SscofpmfEn/SvpbmtEn/SvnapotEn=1` | on | sstc/sscofpmf/svpbmt/svnapot | privileged/PMU | — | enabled, **not advertised** |
| `ZKN=1` | on | Zkn → **zbkb,zbkc,zbkx,zknd,zkne** | `g6lc_decode_s2` crypto ops + `core/aes.sv` | — | implemented, **not advertised** |

### Enabled but pending qualification (=0 knobs)

| Knob | Value | Ext | Datapath | Advertised | Blocker |
|---|---|---|---|---|---|
| `RVZa64rs=0` | **off** | **za64rs** | reservation monitor `g6lc_axi_lrsc` already implements ≤64B naturally-aligned region reservations + overlap invalidation, `NRes=8`=harts | no | needs `tb_g6lc_za64rs*` + `hyp8_smp_lrsc*` directed green, then flip + advertise |
| `RVZabha=0` | **off** | **zabha** | AMO .B/.H + miss-unit sign-extend | no | datapath not ported |
| *(pma-zi)* | n/a | **pma-zi** | `g6lc_pma_zi.sv` exists but is an **orphan** (no consumer wired) | no | needs wiring + qualification |

### Disabled upstream-style (intentionally off)

| Knob | Value | Ext | Reason |
|---|---|---|---|
| `G6LCConfigVExtEn=0` | `RVV` off | V/zve* | Ara cone pushes Verilator elab >104 GiB; mc `.dts` advertises no `v`/`zve` |
| `G6LCConfigHExtEn=0` | `RVH` off | H | always disabled |
| `G6LCConfigF16En/AltEn/F8En/FVecEn=0` | XF16/XF16ALT/XF8/XFVec off | half/f8/vec FP | Zfhmin covers the needed H-load/store+fcvt subset only |
| `G6LCConfigZcmpExtEn=0` | `RVZCMP` off | Zcmp | cmpswap — not ported |
| `G6LCConfigCvxifEn=0` | off | CVXIF | issue-port-0 only → illegal-instr on multi-issue |
| `RVZCMT=0` | off | Zcmt | not ported |

## Required mc ISA string vs current advertise — gap

Target (user-specified):
`v64imafdc_zicbom_zicbop_zicboz_ziccamoa_ziccif_zicclsm_ziccrse_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zimop_za64rs_zaamo_zalrsc_zawrs_zfa_zfhmin_zca_zcb_zcd_zcmop_zba_zbb_zbc_zbkb_zbkc_zbkx_zbs_zknd_zkne`

| Class | Extensions | State |
|---|---|---|
| **Advertised now** | i,m,a,f,d,c, zba,zbb,zbs, zfa,zfhmin, zicboz, zicsr,zifencei, zacas, zcmop, ziccif,ziccamoa,ziccrse, zimop, zihintntl | in `.dts` |
| **Implemented, not yet advertised** | zicbom,zicbop, zicclsm, zicntr, zicond, zihintpause, zihpm, zawrs, zcb, sstc,sscofpmf,svpbmt,svnapot, zknd,zkne,zbkb,zbkc,zbkx,zbc, zca,zcd (implied) | config=1, `.dts` missing → **advertise-gap to close once each is directed-green** |
| **Pending (=0)** | za64rs, zabha, pma-zi | implement/qualify then flip+advertise |

> `zaamo`/`zalrsc` are covered by the `a` base letter; `zca`/`zcd` are implied
> by `c`/`d`. The explicit `zk*`/`zbk*`/`zbc` names are implemented under
> `ZKN`/`RVB` but absent from the current `.dts` string — add them when the
> crypto/bitmanip directed suite is green.

## How to flip a knob safely

1. Port/verify decode (`g6lc_decode_s2/s3`) **and** execute (the datapath file
   above) — never advertise decode-only for a computational extension.
2. Run the dedicated bench: `verif/tb/core/tb_g6lc_<ext>*.sv` and/or a
   `verif/tests/custom/hyp8_<ext>.S` directed program on the remote harness.
3. On green: set the `localparam`/`cva6_cfg_t` field `=1`, add the extension
   name to **every** `cpu@` node's `riscv,isa` + `riscv,isa-extensions` in
   `g6lc-hyp8-mc.dts`.
4. Rebuild the mc model (`cycprog-model.sh`) and re-run the OpenWrt witness +
   directed suite; ingest to tracedb (`ingest.py`) and confirm no new etype.
