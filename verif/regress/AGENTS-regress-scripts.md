# Regress script isolation map

> **Role:** Answer *"which script, which plane (ISS vs RTL), which target, how tall is the stack?"* in one hop.  
> **Governance:** `AGENTS.md` §0.2 (verify in lockstep) · suite catalog `build-platform/src/config/defaults.ts` · status rows `AGENTS-specs-to-tests.md`.  
> **Battery entry:** `verif/regress/stability-regress (profiles: artifact|spike|full|**stream8**).sh` (suite id `stability-regress`).

This file is the **isolation ladder** for residual multicore / H / stream / CAS work. Prefer the **narrowest green gate** that would have caught the bug class before climbing to full CRT or Linux.

---

## 1. Axes (how to classify a failure)

| Axis | Values | How to use |
|------|--------|------------|
| **Plane** | `artifact` · `spike` (ISS) · `veri` (Variane RTL) · `dual-iss` | Fail on Spike first → ISS/test bug or ISA setup (PMP, medeleg). Pass Spike / fail RTL → microarch. Fail both → test or env. |
| **Target / package** | `cv64a6_imafdc_sv39` · `g6lc64_server_math` / `cv64a6_server_math` · `*_ooo_server` · `*_smt2` · `*_stream8` · `*_spec_deep` | Match `DV_TARGET` to the feature under test (Zacas → imafdc or server_math with `RVZacas`; H → server_math with `RVH`). |
| **Stack height** | bare ELF · CRT bare-metal · OpenSBI · Linux | Climb only after the lower stack is green. CRT hang ≠ bare hang. |
| **Feature domain** | stream/CRT · spo/CF · Zacas · H/KVM · vector/Ara · SMT · FO4/timing | Use the domain row in §3; do not mix CAS soft-skip on Spike with hard RTL golden. |
| **Budget** | seconds (Spike directed) · minutes (Variane smoke) · hours (full soak / Linux) | Use `STABILITY_PROFILE` / env knobs; never soft-pass a hard golden. |

**Hard rule — Zacas:** Spike has **no** `zacas`. AMOCAS on ISS may soft-skip or be non-golden. Hard CAS golden is **`mc-mini-veri`** (Variane bare), not `mc-spo-spike`.

**Hard rule — H-edge:** VS entry needs guest-capable memory (open PMP TOR on Spike when PMP regions exist; tests swallow illegal PMP CSR if absent). See `verif/tests/custom/kvm_h/h_edge_diag.S`.

---

## 2. Isolation ladder (narrow → wide)

```
mc-spo-soak / mini compile     artifact only (assemble + optional lint)
        ↓
kvm-h-spike                    Spike H-edge (no Verilator)
mc-spo-spike                   Spike stream×spo/CF (CAS not hard golden)
        ↓
mc-mini-veri                   bare RTL hard CAS + I$ jumps (imafdc preferred)
run-h-edge-veri / kvm-h-tests  H-edge on Variane (server_math)
        ↓
mc-spo-veri                    full CRT stream×spo on Variane (DeepSpec / budget sensitive)
        ↓
server-math-tests / dual-hart  package-level directed
OpenSBI / Linux suites         software stack
```

**Composed battery (AGENTS-todo §4):** `stability-regress.sh`  
Default profile `spike` = `kvm-h-spike` + `mc-spo-spike` + mini **compile** gate.  
Profile `full` also runs mini + H-edge on an existing Variane harness when present.

---

## 3. Script catalog (bring-up / residual focus)

| Script | Suite id | Plane | Default target | Stack | Domain | Notes |
|--------|----------|-------|----------------|-------|--------|-------|
| `smt2-ai-tensor-track.sh` | `smt2-ai-tensor-track` | artifact→veri→host (staged) | `g6lc64_smt2` + tensor host | bare→OpenSBI→Linux→pytorch | SMT2×AI | **Default profile `fast`** (seconds). Climb: `di`/`hold`/`peel`/`dual`/`tensor`/`mt-soft`/`hard`/`full`. No rebuild unless `SMT2_REBUILD=1`. Map: `smt2-ai-tensor-linux.md` |
| `mc-spo-soak.sh` | `mc-spo-soak` | artifact (+ optional lint) | `cv64a6_ooo_server` | source | stream×spo | Assemble smoke; `MC_SPO_LINT=0` / `MC_SPO_ROUNDS` |
| `mc-spo-spike.sh` | `mc-spo-spike` | spike | `g6lc64_server_math` | CRT via cva6.py | stream×spo/CF/CAS list | `MC_SPO_SPIKE_TESTS`, `ISS_TIMEOUT`, `OUT_DIR=/tmp/...` |
| `mc-mini-veri.sh` | `mc-mini-veri` | veri | `cv64a6_imafdc_sv39` | bare | I$ + **hard AMOCAS** | `MC_MINI_VERI_REBUILD`, `MC_MINI_VERI_TESTS` |
| `mc-spo-veri.sh` | `mc-spo-veri` | veri | server_math | CRT | stream×spo full | `MC_SPO_VERI_FORCE_IMAFDC=1` smoke; `MC_SPO_VERI_REBUILD` |
| `mc-stream-tests.sh` | `mc-stream-tests` | mixed | ooo_server | directed | U6 stream plane | Broader stream catalog |
| `kvm-h-spike.sh` | `kvm-h-spike` | spike | `g6lc64_server_math` | CRT | H-edge | 3/3 Spike green; no Verilator |
| `kvm-h-tests.sh` | `kvm-h-tests` | veri+spike | `g6lc64_server_math` | CRT | H + Sstc | Optional full DV list |
| `monorepo-soak/run-h-edge-veri.sh` | (soak helper) | veri | existing `work-ver` | CRT | H-edge | Reuses server_math TB; not a defaults suite |
| `stability-regress.sh` | `stability-regress` | composed | see profile | see legs | residual battery | §4 entry point |
| `soft-ladder-di-regress.sh` | `soft-ladder-di` | veri (+opt spike) | `work-ver-smt2` / fw64 | bare mini | residual scaffold B1 | **P1** directed DI minis; register optional in `defaults.ts` (P0); `SOFT_LADDER_*` |
| `soft-ladder-opensbi-soak.sh` | `soft-ladder-osbi` | veri | `work-ver-smt2-fw64` | OpenSBI soft/stock | residual scaffold | **P3** cookie **`51b1babe` only**; `PEEL_*` bisect; max RTL peel (see `soft-ladder/README.md`) |
| `remote/testharness_proxy.py` | `remote-testharness` | spike + veri (remote) + py | `work-ver-smt2-fw64-*` (+ `--verlib` I4dp) | bare→OpenSBI→Linux-cap | **MT harness of record** | All SMT Spike/soak/peel/TRACE/I4dp evidence. Classify from `runs/<tag>/run-*.log` (rc=255 ≠ fail). Plan: `architecture/multi-threading/testharness-proxy.md` |
| `dual-iss-regress.sh` | `dual-iss` | dual | server_math | bare | dual plane | `SOFT_LADDER=1` appends B1 minis |
| `stream8-smoke.sh` | `stream8-smoke` | artifact/compile | stream8 | package | stream/Zacas | Contract + mini golden |
| `kvm-h-veri.sh` | `kvm-h-veri` | RTL | stream8 | package | H/KVM | Variane H-edge 3/3 |
| `dual-hart-ci.sh` | `dual-hart-ci` | artifact/lint | smt2 | package | SMT | Path/lint gate |
| `server-math-tests.sh` | `server-math-tests` | veri+spike | server_math | directed | B/H/CMO/memcpy | Package C-light |
| `sv-timing-*.sh` | `sv-timing-*` | FO4 screen | sparse/core | n/a | timing | Not functional ISS; not STA |
| `smoke-tests-cv64a6_*.sh` | `smoke-cv64a6` | mixed | imafdc | compliance subset | baseline | Upstream-style smoke |
| `dv-riscv-*.sh` | `riscv-tests` / arch / compliance | mixed | imafdc | arch | ISA | Long CI |

`soft-ladder-build-harness.sh` is the **Verilator build of record** (every `work-ver-*` model
above, the builder's T16/T21 drivers and `./build.sh build` go through it). Its defaults are the
measured recipe of `agents/guides/AGENTS-verilator-performance.md` §7.4a and nothing that
measured zero: the `g6lc` fork compiler (`SOFT_LADDER_VERILATOR_FLAVOUR`, `pinned` = upstream
v5.008 for cross-checks), `build-platform/scripts/verilator-split-loops.vlt`
(`SOFT_LADDER_BUILD_SPLIT_VLT`), `-O2` for the generated C++ (`SOFT_LADDER_BUILD_OPT`), **PGO on**
(`SOFT_LADDER_BUILD_PGO=1`: instrumented build → the in-repo `ooo/ooo_fp_ooo.S` probe run to
completion and to the cycle cap → `-fprofile-use`; layout only, same RVFI stream; set
`SOFT_LADDER_BUILD_PGO_TRAIN=<elf>` for a workload-specific profile), 4 model threads
(`SOFT_LADDER_VERILATOR_THREADS`; the review runners pass 1), and since guide §10 the host ISA
`x86-64-v3` for the `g6lc` flavour on an AVX2+BMI2 host (`SOFT_LADDER_BUILD_MARCH`; `none` =
baseline, `native` = build host; the pinned flavour stays at baseline). Qualification
cross-check rebuilds inside the review runners set `SOFT_LADDER_BUILD_PGO=0` and the pinned
`VERILATOR_ROOT`. The fork runtime header at the current pin (`e900ec45…`) is not yet in the
runners' `qualified` tables — see `AGENTS-build.md`.

Install helpers (`install-spike.sh`, `install-verilator.sh`, …) and `common-riscv-tools.sh` are **tooling**, not functional gates.

---

## 4. Env knobs (quick reference)

| Variable | Scripts | Meaning |
|----------|---------|---------|
| `DV_TARGET` | most | Package / cva6.py target |
| `ISS_TIMEOUT` | `mc-spo-spike` | cva6.py ISS timeout (Spike wall ≈ /10) |
| `MC_SPO_SPIKE_TESTS` | `mc-spo-spike` | Space-separated test name override |
| `MC_SPO_VERI_TESTS` / `FORCE_IMAFDC` / `REBUILD` | `mc-spo-veri` | CRT subset / single-core smoke / rebuild TB |
| `MC_MINI_VERI_TESTS` / `REBUILD` | `mc-mini-veri` | Bare mini subset / rebuild |
| `MC_SPO_LINT` / `MC_SPO_ROUNDS` | `mc-spo-soak` | Lint on/off; assemble rounds |
| `KVM_H_SPIKE_TESTS` / `KVM_H_SPIKE_STEPS` | `kvm-h-spike` | H-edge subset / Spike step bound |
| `STABILITY_PROFILE` | `stability-regress` | `artifact` \| `spike` (default) \| `full` |
| `STABILITY_SKIP_*` | `stability-regress` | Skip individual legs (`HEDGE`, `SPO_SPIKE`, `MINI`, `SOAK`) |
| `OUT_DIR` | spike paths | Prefer Linux `/tmp/...` on WSL+NTFS trees |
| `SOFT_LADDER_VERILATOR_FLAVOUR` / `SOFT_LADDER_BUILD_SPLIT_VLT` / `SOFT_LADDER_BUILD_OPT` / `SOFT_LADDER_BUILD_PGO[_TRAIN,_CYCLES]` / `SOFT_LADDER_VERILATOR_THREADS` / `SOFT_LADDER_BUILD_MARCH` | `soft-ladder-build-harness` | Build of record knobs (defaults `g6lc` / 1 / `-O2` / 1 / 4 / `x86-64-v3` on AVX2 hosts for `g6lc`, else `none`); see §3 |

---

## 5. Failure triage cheat-sheet

| Symptom | First gate | Likely class |
|---------|------------|--------------|
| tohost never written / HTIF spin | Spike log + `tohost` parse (see `kvm-h-spike`) | test exit / managed Spike HTIF |
| IAF on first S/VS insn after `mret` | `h_edge_diag` / bare S-entry | **PMP** default deny S/U/VS |
| mcause ≠ 10 on VS ecall | `h_edge_diag` | not in VS (MPV) or wrong trap |
| AMOCAS “pass” on Spike only | — | **invalid golden**; run `mc-mini-veri` |
| CRT hang ≥40 B fill→verify | `mc-spo-veri` + STQ depth | DeepSpec / `DEPTH_COMMIT` (see §2 CRT notes) |
| DIDNOTCONVERGE dense CRT | I$ way-pred / preload | see `mc-spo-veri` header comments |
| Lint-only fail dual-hart | `dual-hart-ci` | package / flist, not runtime |

---

## 6. Maintenance

- **New residual suite:** add script under `verif/regress/`, register in `defaults.ts`, add a row here + `AGENTS-specs-to-tests.md`.
- **New directed test:** prefer extending an existing testlist (`testlist_mc_stream.yaml`, `testlist_kvm_h.yaml`) over a one-off soak script.
- **Do not** document foundry/NDA PDK paths here (`AGENTS-technology.md` / `pd/pdk/`).


---


---

## 7. Dual-ISS Spike + Verilator (AGENTS-todo section 5)

| Script | Suite id | Plane | Default tests | Golden |
|--------|----------|-------|---------------|--------|
| dual-iss-regress.sh | dual-iss-regress | spike and veri | mini_tohost mini_jumps (+ h_edge_diag if DUAL_ISS_H=1) | tohost both pass (default); optional DUAL_ISS_MODE=trace via cva6.py --iss=spike,veri-testharness |

### Mismatch triage (residual polish only)

| Class | Spike | RTL | Dual-ISS policy |
|-------|-------|-----|-----------------|
| Bare tohost / I-cache jumps | pass | pass | hard golden (default suite) |
| H-edge (VS/ecall/MPV) | pass | pass | optional (DUAL_ISS_H=1); open PMP in test |
| Zacas AMOCAS.W/D | no zacas / soft-skip | hard on mc-mini-veri | never dual-ISS golden |
| Dense CRT stream | ISS OK | budget/hang residual | use mc-spo-veri isolation, not dual-ISS |
| Full instr-trace CSV | may diverge on CSR noise | — | DUAL_ISS_MODE=trace; triage only — do not soft-pass tohost fail |

Requires existing work-ver/Variane_testharness for the active DV_TARGET (default g6lc64_server_math).

---

## 8. R3b Linux Image (AGENTS-todo section 6)

| Script | Suite | Notes |
|--------|-------|-------|
| r3b-linux-image.sh | r3b-linux-image | Contract always; soft-skip without Image; CVA6_R3B_BUILD embeds LINUX_IMAGE |
| fetch-linux-image-hint.sh | (helper) | cva6-sdk / Buildroot operator paths |

Image never committed; lives under build-platform/workspace/smt2-linux/.

---

## 9. Ara / RVV cosim (AGENTS-todo section 7)

| Script | Suite | Notes |
|--------|-------|-------|
| ara-vector-path.sh | ara-vector-path | Artifacts + optional lint |
| ara-vector-cosim.sh | ara-vector-cosim | Soft skip/misa on Variane; ARA_COSIM_LIVE for lmul |
| software/vector/* | (contract) | opensbi-vrf.md + linux.config-fragment |

Never dual-ISS-golden AMOCAS; vector golden is live Ara when misa.V is set.

---

## 10. Zacas residual policy (AGENTS-todo section 8)

| Script | Suite | Notes |
|--------|-------|-------|
| mc-mini-veri.sh | mc-mini-veri | Hard AMOCAS.W/D golden (RTL) |
| zacas-policy.sh | zacas-policy | Q illegal + policy + optional mini W/D |
| software/zacas/README.md | (policy) | Spike never golden; Q deferred |

AMOCAS.Q remains unimplemented (decoder illegal). CAS.D dual-word = HPDCache local RMW.

## Program-order memory oracle over an RVFI trace — `rvfi_memcheck.py` (2026-10-14, T34)

`verif/regress/rvfi_memcheck.py <trace_rvfi_hart_00.dasm> <payload.elf> [--max=N] [--all]
[--watch=0xADDR]` replays the retired loads and stores of a **single-hart** RVFI trace against
a byte-granular memory model seeded from the ELF's PT_LOAD segments (zero elsewhere): every
retired load must return the last retired store's bytes (program order), AMOs are checked as
loads then applied, `sc` applies on success only, MMIO (below DRAM) is skipped. It needs no
ISS — it is the tool for "a stored value read back wrong" classes where Spike cannot run the
platform (Linux on the testharness UART). ~1 M memory operations per 2 s. First use: on the
T32-era depth-2 `g6lc64_ooo` probe trace it named a stale `lw` inside OpenSBI (retire 1,272,815,
`0x80009fec` read 0xfa after `0x8000a11a` stored 0xf9 to `0x8004211c` 27 retirements earlier);
the same 2 M-cycle window on the depth-8 and T33 models is clean, so the race is timing-bound
and the oracle is run over the full kernel boot trace to find the first wrong value
(`t21/q-memcheck-bg.sh`). Limits: one hart (no coherence), no DMA. `cbo.zero` is modelled as a
64-byte zero store of the block containing the address (`CBO_BLOCK_BYTES`, the `.dts`
`riscv,cboz-block-size`) since 2026-10-19 — before that the opcode was skipped, and the T44 trace
(a core zeroing 16 of the 64 bytes) ran with "0 stored mismatches".

**Live mode (2026-10-15, T37).** A 700 M-cycle boot trace is ~45 GB, so the oracle can also be
fed through a FIFO while the model runs: in the run directory `mkfifo trace_rvfi_hart_00.dasm`,
start `cat trace_rvfi_hart_00.dasm | tee >(zstd -1 -T2 -q -o trace_rvfi.dasm.zst) | python3 -u
rvfi_memcheck.py /dev/stdin payload.elf --progress=5000000 > oracle.log`, then the model
*without* `+rvfi_notrace` (the tracer's `$fopen` blocks until the reader is there). Every
`src=stored` mismatch is printed and flushed as it happens, `progress` lines every N
retirements, and the zstd copy (≈ 2 bytes per retirement on OpenSBI's loops, more on the kernel)
keeps `--watch`/`--stop-retire`/`--walk` replays possible afterwards. The memory model holds
stored bytes in 4 KiB pages (data + known bitmap) instead of a per-byte dict, so a whole Linux
boot stays around 1 GB of RSS; the oracle runs at roughly the model's pace (~20–25 k
retirements/s), the FIFO throttles the model if it does not. Launch recipe:
`t21/q-t37-launch.sh`. The other three sim-only per-commit trace files (`trace_hart_0.dasm`,
`iti.traces`, `encaps.traces`) are gated by `+core_notrace` on models built after
2026-10-15; on older models symlink the three names to `/dev/null` before launching.
Two companions: `+rvfi_cycle_stamp` appends ` @<cycle>` to every `core` line of the RVFI trace
(opt-in; the oracle's `retire N` / `line L` then maps to a cycle for an FST window —
`zstd -dc trace_rvfi.dasm.zst | sed -n 'L,Lp'`), and `+hang_dump=N` (`core/cva6.sv`, OoO census
block) prints, after N cycles without a commit ack, the scoreboard head, every IQ entry with its
readiness/bypass bits and `ready[e]`, the LSQ store/load entries, the LSU bypass entries and the
store/load unit states, three times 1000 cycles apart — for a boot that stops retiring where no
probe window is known in advance (T40).
### User space, harts and two-file merge (2026-10-16/17, T39/T42)

- **User space.** The oracle shadows the integer register file from the trace's `x<n>` writes,
  follows every `csrrw/csrrs/csrrc` of `satp` (CSR 0x180) and folds user-half virtual
  addresses (VA < 2^38 while satp.MODE = Sv39) onto physical addresses by walking the Sv39
  tables **in its own memory model** (the kernel wrote them); the walk cache is dropped on
  `sfence.vma` and on satp writes. U-mode loads/stores and the kernel's SUM accesses
  (`copy_to_user`) meet at the same physical byte, so a user process reading what the kernel
  wrote — or the kernel reading what the process wrote — is checked. A user VA with no valid
  leaf stays a `va`-space key (never-stored bytes there are skipped). Before this the user
  phase produced tens of thousands of false `stored` mismatches (the kernel fills pages through
  the linear map, the process reads them through its own VA).
- **Harts.** The tracer prints `core <h>:` per retirement (`rvfi_hart_o`); an SMT core's harts
  share one file in retirement order and the oracle keeps satp and the shadow registers per
  hart, checking all harts against one memory model. Under the drained handoff a `stored`
  mismatch is a real value error; under mixed residency a store retired a few cycles before
  another hart's load may legally be invisible to it.
- **`--merge=<trace2>`.** Two files written with `+rvfi_cycle_stamp` are interleaved by
  cycle (hart 0 first on a tie) — for multi-core runs where each core has its own tracer.
- Offline on a kept trace: `zstd -dc trace_rvfi.dasm.zst | python3 -u rvfi_memcheck.py
  /dev/stdin payload.elf --progress=20000000 > oracle_user.log`.
- **Kernel-half VAs across pgds.** A kernel-half VA whose top-level entry is missing from the
  current process's pgd (Linux copies vmalloc/VMAP entries on `vmalloc_fault`) is walked with
  the other satp roots seen so far, most recent first, so a VMAP stack written under one pgd and
  read under another folds to the same physical bytes instead of a never-stored `va` key.

## Register-level oracle over an RVFI trace — `rvfi_alucheck.py` (2026-10-19, T44)

`verif/regress/rvfi_alucheck.py <trace.dasm> [--start-retire=N] [--stop-retire=N]
[--progress=N] [--max-report=N] [--dump-first=N]` is the complement of the memory oracle for
"every memory value is right but the kernel dies of a garbage pointer": it shadows the integer
register file from the trace's rd writes, recomputes every register-only RV64IMC result (ALU,
logic, shifts, `lui`/`auipc`, `jal`/`jalr` link, mul/div/rem and the `*w` forms, all compressed
forms) from the pre-instruction state and compares it with the value the core wrote, and checks
every retirement's pc against the pc the previous instruction predicts (fall-through, `jal`/`jalr`
target, branch outcome; a trap/interrupt line suspends the check; `sret`/`mret`/`ecall`/`ebreak`/
`wfi` predict nothing). Loads, CSR reads, AMOs and FP moves update the shadow but are not checked.
Starting late is fine (a register is checked once written inside the window). ~250 k
retirements/s. On the T44 trace both counters were 0 (70 M results, 267 M pcs) with the memory
oracle also at 0 — which is what pointed at the sources no oracle covered (`cbo.zero`); the t52
L3 trace (537 M results) is clean as well. Caveat for a trace that ends in a panic: the halt loop
retires `c.j 0` every two cycles to the cycle cap, so `--start-retire` must be placed before it
(the useful retirements of `l1s1z` end near 346 M of its 467 M). **SMT traces (2026-10-21):**
the control-flow check is per hart, and a trap/interrupt line suspends the check for the hart it
names — the tracer now appends ` hart <h>` to its `… exception @ …` lines (an SMT trace
interleaves harts, and a hart-less trap line was charged to the previous `core` line's hart: on
the two-hart `l1s2w` trace that produced 245 false `CF-MISMATCH`es, every one an interrupt entry
after `csrsi sstatus, 2` or an M-timer trap to `0x80000500` on the other hart; the ALU counter was
0 over 116.6 M results across both harts). Older traces without the suffix fall back to the
previous `core` line's hart, so a two-hart trace made before the suffix keeps the false positives
at interrupt entries. The tracer also used to repeat the previous exception's name for interrupts
(a sticky `string`): the periodic `ST_ADDR_MISALIGNED exception` lines of the Linux traces were the
S-timer; interrupts now print as `INTERRUPT_<n>`.

