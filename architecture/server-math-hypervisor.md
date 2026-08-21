# U9 Hypervisor + U10 server-math (AVX-like) profile

Plan of record: `remaining-upgrade-sequence.md`. Spec anchors: Priv II `#hypervisor`,
Sstc (`stimecmp`/`vstimecmp`), Unpriv Vector, CMO `#cmo`, B-bitmanip.

## U9.0 — Sstc × H (guest timers) — **implemented**

| Item | Spec | RTL |
|------|------|-----|
| `vstimecmp` / `vstimecmph` | Sstc + H | `csr_regfile.sv`, CSR `0x24D`/`0x25D` |
| `henvcfg.STCE` | Sstc + H | `henvcfg` bit 63 (RV64) / `henvcfgh` bit 31 (RV32) |
| VS alias of `stimecmp` | When `V=1` | Redirects R/W to `vstimecmp` if STCE pair set |
| `mip.VSTIP` hardwired | guest_time ≥ vstimecmp | When `menvcfg.STCE && henvcfg.STCE` |
| `check_cfg` | Was illegal | **`SstcEn && RVH` now legal** |

## U9.1 — htimedelta + multi-context PLIC — **implemented**

| Item | Spec | RTL |
|------|------|-----|
| `htimedelta` / `htimedeltah` | Priv H | `csr_regfile.sv` CSR `0x605`/`0x615` |
| Guest time | `mtime + htimedelta` | Feeds VSTIP compare + `time` under `V=1` |
| PLIC N contexts | 2×hart (M/S) | `NumTargets=16`; harness `irqs[2*c +: 2]` |
| Directed smoke | — | `verif/tests/custom/sstc_h/vstimecmp_htimedelta.S` |

## U9.2 — VS entry litmus + trap polish — **implemented**

| Item | Spec | RTL / test |
|------|------|------------|
| STCE fail under V → virtual-instr | Sstc×H | `stimecmp` R/W uses `virtual_*_access_exception` when `V=1` |
| HVIP vs hardwired VSTIP | Sstc×H | HVIP write masks `VSTIP` when STCE pair on |
| VS entry + VSTIP pending | Priv H | Directed: mip/hip.VSTIP, `mret`→VS, stimecmp alias, ecall VS |
| G-stage two-stage + G-only | `#hypervisor` / Sv39x4 | PTW `G_INTERMED` / `G_FINAL` / S-only paths in `cva6_ptw.sv` |

## U9.x — remaining H surface (when `RVH=1`)

| Item | Status |
|------|--------|
| HS CSRs (`hstatus`, `hedeleg`, `hgatp`, …) | Implemented under `RVH` |
| `hfence.vvma` / `hfence.gvma` | Decoder + commit + MMU flush |
| `hlv*` / `hsv*` | Decoder (load/store FU) |
| G-stage walk | **Present** (two-stage + G-only bare VS); full KVM stress still open |
| `hgeie` / `hgeip` multi-guest EIDs | Stub (always 0) |

Default shipping configs keep **`HExtEn=0`**. Enable via server package.
`g6lc64_smt2` is **`HExtEn=0`**; stream8 / server_math{,_v} are **`HExtEn=1`**.
Turning H on smt2 is a **package + DTS `h` + H-edge soak**, not a living-G1
recover edit — `architecture/multi-threading/soft-ladder/CONTRACT.md` §6.5
(EXTRACT must not inject over an I$ guest page fault).

## U10 — AVX-like server math (RISC-V mapping) — **C-light production**

| x86 / server need | RISC-V | Profile status |
|-------------------|--------|----------------|
| Wide memcpy/memset | **RVV** `vle`/`vse` + LMUL | **U10ᵇ scaffold** — Ara flist open (`_v` pkg) |
| Block zero | **Zicboz** multi-beat line | **Done** (U7ᶜ + server pkg) |
| Stream prefetch | **Zicbop** + HPDCACHE HWPF | **Done** — HINT + `HwPrefetchEn=1` |
| Bit/byte glue | **RVB** (Zba/Zbb/Zbs) | **Done** — on in server package |
| Crypto bulk | **ZKN** | **Done** — on in server package |
| Cache-line size | **Zic64b**-class L2 line | **Done** — L2 auto 64 B line after infer |

### Config packages

| Package | Role |
|---------|------|
| `g6lc64_server_math_config_pkg.sv` | **Default U10 host**: H+Sstc, RVB/ZKN/Zicbo*, **HPDCACHE_WT**, HWPF, dual-issue, **NrCores=2**, L2 auto-size, RVV=0, CVXIF=1 |
| `g6lc64_server_math_v_config_pkg.sv` | Same + **RVV=1**, **CvxifEn=0** when Ara is on the flist |

Production knobs (C-light):

- Scoreboard 16, load-buf 8, wbuf 8, MemTid 4 / DcacheId 3 (HPDCACHE legal)
- L2 geometry **0 → inferred** (`build_config_pkg`: max(256 KiB, N×128 KiB))
- Snoop filter entries **0 → 64×NrCores** when multi-core
- `OoOEn=0` (full 4-issue OoO is `g6lc64_ooo_server`)

### Directed tests (optional suite)

| Test | Path |
|------|------|
| misa B/H + ANDN | `verif/tests/custom/server_math/u10_misa_bhz.S` |
| cbo.zero / memset | `verif/tests/custom/server_math/u10_cboz_memset.S` |
| Scalar stream memcpy | `verif/tests/custom/server_math/u10_memcpy_stream.S` |
| List / regress | `testlist_server_math.yaml`, `verif/regress/server-math-tests.{sh,ps1}` |

```
cva6-build test --suite server-math-tests
cva6-build verify --target g6lc64_server_math   # opt-in lint/synth
```

Not in default `verify.targets` / `defaultSuites`.

### U10ᵇ Ara / RVV

See `ara-vector-attach.md`. No Ara RTL vendored; accelerator seam is pre-existing.

## Best-practice enable order

1. Bring up **server package** single-core (`NrCores=1` override) with H+Sstc — guest timer litmus  
2. Enable **NrCores=2** + L2 — SMP host  
3. Attach **Ara/vector** → switch to `_v` package + Linux `riscv,isa-extensions += "v"`  
4. Measure memcpy/memset vs scalar CBO path  

## Observability / `.dts`

- `misa`: B and H set from config; V when `_v` package  
- `.dts`: `riscv,isa-extensions` with `h`, `sstc`, `zicboz`, `zbb`, optional `v`  
- PMU: existing miss/load events; HWPF activity via D$ traffic  
