# AGENTS workflow todo / pending-log

Live tracker for agent work. **Retrieval contract:** every open item below cites the architecture /
progress files that hold its priors (why it exists, seams, acceptance). Open those first; this file
is the queue, not the design.

| Layer | Open first | Role |
|-------|------------|------|
| Prime directive / nav | [`AGENTS.md`](AGENTS.md) · [`agents/spec/INDEX.md`](agents/spec/INDEX.md) | Spec→code map, SoC §0, standing disciplines |
| Programs of record | [`architecture/README.md`](architecture/README.md) · [`architecture/router-core-upgrade-program.md`](architecture/router-core-upgrade-program.md) · [`architecture/remaining-upgrade-sequence.md`](architecture/remaining-upgrade-sequence.md) | U1–U10 plan, live next, scaffold contract |
| Spec ⇄ RTL / tests | [`AGENTS-specs-to-impl.md`](AGENTS-specs-to-impl.md) · [`AGENTS-specs-to-tests.md`](AGENTS-specs-to-tests.md) · [`AGENTS-specs-coverage.md`](AGENTS-specs-coverage.md) | Status vocabulary + suite/testlist rows |
| Host / verify | [`AGENTS-build-platform.md`](AGENTS-build-platform.md) · [`AGENTS-build.md`](AGENTS-build.md) · [`build-platform/AGENTS.md`](build-platform/AGENTS.md) | CLI, residual soaks, probe→verify |
| Philosophy / SoC envelope | [`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md) · [`AGENTS-configuration.md`](AGENTS-configuration.md) · [`agents/guides/AGENTS-soc-readiness.md`](agents/guides/AGENTS-soc-readiness.md) | Timing, verify-in-lockstep, target SoC |

## Current phase
**Soft ladder (DI OpenSBI) + multi-threading topology path on smt2.**  
Program spine: `architecture/remaining-upgrade-sequence.md` §0/§4 · residual matrix
`AGENTS-build-platform.md` §5–§7 · live RTL table `architecture/README.md` ·  
**soft ladder** `architecture/multi-threading/soft-ladder/` ·  
**topology** `architecture/multi-threading/fdt-topology-soft-ladder.md`.

### Landed plane (state + priors to retrieve)

| Track | State | Priors / architecture / progress |
|-------|--------|----------------------------------|
| **Zacas AMOCAS.W/D** | `RVZacas` on `cv64a6_server_math{,_v}`, `cv64a6_ooo_server`, `cv64a6_imafdc_sv39`; decode + 3rd-op RF + `amo_alu` + WT/HPDCache/AXI CAS | Spec: `agents/spec/riscv-spec-I-5.9-zacas.html` · `#ext:zacas` · impl row `AGENTS-specs-to-impl.md` (Zacas) · tests `AGENTS-specs-to-tests.md` (mc-stream / gaps) · packages under `core/include/*config_pkg.sv` |
| **Directed multicore suite** | `testlist_mc_stream` — stream, AMOCAS, st-fwd, fence, CAS lock, **CF×stream**, CAS×stream, mispred×stream | `architecture/multi-core/README.md` · `architecture/l2-l3-cache/README.md` · U6/p6 notes in `remaining-upgrade-sequence.md` · `verif/tests/testlist_mc_stream.yaml` · asm `verif/tests/custom/multicore/` |
| **Spike soak** | `stability-regress` + `mc-spo-spike` / `mc-spo-soak` / `kvm-h-spike` | Scripts `verif/regress/mc-spo-{spike,soak}.sh` · suite registry `build-platform/src/config/defaults.ts` · host residual `AGENTS-build-platform.md` §4–§5 |
| **RTL mini golden** | `mc-mini-veri` hard PASS AMOCAS.W/D (no soft-skip); **cataloged** in `defaults.ts` | `verif/regress/mc-mini-veri.sh` · `mini_amocas_{w,d}.S` · suite id `mc-mini-veri` · TB `corev_apu/tb/ariane_tb.cpp` · Zacas impl row |
| **RTL full CRT residual** | imafdc **9/9** + `g6lc64_server_math` L2 **9/9** (DeepSpec STQ); dual-hart-ci residual revalidated (lint soft when host-skewed; dual-park ELF; R3 skippable) | suite id `mc-spo-veri` · `verif/regress/mc-spo-veri.sh` · FSE: `architecture/speculative-execution/` · `agents/guides/AGENTS-speculation.md` |
| **FTQ / frontend** | Mispredict reseed + demand fixes for bare-metal green | Guide `agents/guides/AGENTS-branch-prediction.md` · scaffold `architecture/branch-prediction/README.md` · RTL `core/frontend/{frontend,cva6_ftq}.sv` |
| **Structural FO4** | sparse_ex/frontend residual close @ **2.5 GHz** (screening ≠ STA) | Package `sv-timing/AGENTS.md` · `sv-timing/architecture/MONOREPO-SOAK.md` · `FREQUENCY-CLOSURE.md` · host `AGENTS-build-platform.md` §6.1 / §7 · plan `architecture/build-platform-opensta-from-timing.md` · philosophy §2.8 in `AGENTS-coding-philosophy.md` |
| **R3a dual-hart OpenSBI** | `fw_payload` + WSL SUCCESS; **R3b gate** `r3b-linux-image` (Image external) | `architecture/multi-threading/smt2-bringup.md` · `smt-linux-rootfs.md` · `dts-linux-smt.md` · `software/smt2-linux/` · suites `smt-linux-*` / `opensbi-linux-boot` · `AGENTS-dts-validation.md` |
| **Soft ladder (DI OpenSBI residual scaffold)** | **P0 done:** optional suites `soft-ladder-di` / `soft-ladder-osbi` + diag `diag-soft-ladder-paths` in `defaults.ts`. Max **B1 RTL** promotion; oracle temporary. Cookie **51b1babe**; peels through strlen; **iter-012 FDT lenp open** (soft getprop holding) | `soft-ladder/README.md` (P0–P6) · `ITERATION` · `b3-sim-harness` · suites in `defaults.ts` · `AGENTS-specs-to-tests.md` |
| **FDT topology plan** | `NrCores`×`NrHarts` (threads/core), stream vs SMT `cpu-map`, issue width non-DT; gates before `/proc/cpuinfo` | `architecture/multi-threading/fdt-topology-soft-ladder.md` · `ariane-smt2.dts` · `ariane-stream8.dts` |
| **Ara / RVV** | Attach + DTS + directed; **VRF/cosim gate** `ara-vector-cosim` (live lmul opt) | `architecture/ara-vector-attach.md` · `agents/guides/AGENTS-vector.md` · `agents/vendor/AGENTS-vendor-ara.md` · `agents/spec/riscv-spec-I-9-vector.html` · suite `ara-vector-path` |
| **H / KVM** | U9 + **H-edge Spike+RTL 3/3** (`kvm-h-spike` / Variane server_math) | `architecture/server-math-hypervisor.md` · remaining-upgrade Phase B · `agents/spec/riscv-spec-II-5.*-hypervisor*.html` · impl Hypervisor row · `verif/tests/custom/kvm_h/` · suite `kvm-h-tests` |

Standing disciplines remain active (`AGENTS.md` §0.4–§0.6). Keep
`AGENTS-specs-to-{impl,tests,coverage}.md` in lockstep on ISA-visible / suite edits
(Zacas already **partial W/D** in the working-tree maps).

### Practical next (edge of implementation — ordered)

Do **not** reopen soft-skip CAS or re-litigate green mini RTL unless a hard fail reappears.
Isolation ladder (narrow → wide): `mc-mini-veri` → `mc-spo-spike` → `mc-spo-veri` → OpenSBI/Linux
(see also diagnosis intent in `AGENTS-build-platform.md` residual soaks;
`verif/regress/AGENTS-regress-scripts.md`).

**Active edge (residual scaffold + SMT topology) — build-platform home, RTL-max:**

Phases: **P0** platform register → **P1** directed mini → **P2** B1 RTL → **P3** osbi climb/peel → **P4** retire soft → **P5** B2 policy only → **P6** generalize.  
Full map: `architecture/multi-threading/soft-ladder/README.md`.

| # | Item | Phase | Status / next action |
|---|------|-------|----------------------|
| **SL-0** | **Register residual suites in build-platform** | P0 | **Done.** Optional `soft-ladder-di` + `soft-ladder-osbi` in `defaults.ts` (not `defaultSuites`); diag `diag-soft-ladder-paths`; maps in `AGENTS-specs-to-tests.md` / `AGENTS-build-platform.md` / `AGENTS-regress-scripts.md`. |
| **SL-A** | **iter-012 FDT `lenp` / `PEEL_FDT_GETPROP`** | P1–P2 | **Open.** Pin: mepc=`0x80012eb2` mcause=6 mtval=`0x80012b2a`. Soft getprop = **holding** cookie green, not done. |
| | Bisects **all negative** | P2 | Dual-commit; STQ-nofwd; force SI; ALU/NONE cancel-exempt — same pin; **reverted**. |
| | Next | **P2 RTL** | Probes: namelen_ entry args **OK** (fdt=`0x8001e000`, lenp stack); by_offset entry a0=**0** a2=s3=**`0x12b2a`**. **s2/s3 clobber** between entry and first by_offset (`check_node`/`next_tag`). RTL: RF/scoreboard s-reg or spill restore under DI. Soft getprop holding. |
| | Priors | | `soft-ladder/{README,ITERATION,b1-rtl-residuals,b3-sim-harness}.md` · oracle `software/smt2-linux/soft-ladder/` · soak script |
| **SL-B** | Peel soft getprop + real printf | P3–P4 | **Blocked on SL-A RTL.** Then drop BANR holding; `plat_hc==2` without soft FDT. |
| **SL-C** | Topology truth (smt2) | P6 / topology | After SL-B: stock DTB, `hart_count==2`, R3/R3b, cpuinfo; `fdt-topology-soft-ladder.md` A5–B. |
| **SL-D** | Stream plane vs SMT | P6 | Orthogonal: stream8 N=2 T=1; do not merge with smt2 DI residual until FDT walk trusted. |
| **SL-E** | Optional DTS generator | later | Only when third topology would triple-maintain hand DTS. |

Soft-ladder SUCCESS = trapdump **`51b1babe` only** (not harness tohost SUCCESS) — suite metadata.  
Harness preference: `SOFT_LADDER_HARNESS=work-ver-smt2-fw64` (FETCH_WIDTH≥64).  
Oracle (temporary): `python software/smt2-linux/soft-ladder/mk_plat_skip.py` — shrink on peels; P4 retires.

**AI matrix card (`Xg6lcai`) + licensing — new track, scaffold only:**

Phases **P0** scaffold → **P1** CVXIF T0/T1 → **P2** observability/DFT → **P3** T2 descriptor engine →
**P4** decouple `EnableAccelerator` → **P5** PCIe endpoint + virtio → **P6** torch backend.
Parallel **island track I0–I4** (throughput silicon, does not renumber P0–P6):
`architecture/ai-matrix/scaling-100tops.md` §11.
Full map: `architecture/ai-matrix/README.md` · transport `architecture/uncore/pcie-endpoint.md`.

| # | Item | Phase | Status / next action |
|---|------|-------|----------------------|
| **AI-0** | ~~Tier decision: withhold the AI delta (tier P case 2)?~~ | P0 | **CLOSED — NOT ADOPTED. The AI plane rides the normal open path (tier R, dual-licensed); NOTHING IS BLOCKED.** Three findings: (1) the boundary is not clean — the delta necessarily lands in `csr_regfile.sv`/`decoder.sv`/`perf_counters.sv` (tier R) and `config_pkg.sv`/`build_config_pkg.sv`/`cva6.sv` (tier **U**, Apache-2.0 WITH SHL-2.0), so only leaf modules were ever separable; (2) it inverted its own rationale — the stated moat was the descriptor engine + verification collateral + software stack, but `verif/tests/custom/ai/**` and `software/**` are tier T (**MIT**), so it withheld the easy-to-copy MAC array and gave away the hard part; (3) it bought a freeze, not a moat. Terms are **left to the reader in the LICENSE files**: integrators take CERN-OHL-S-2.0, operators read `LICENSE.GSys-Commercial` §3.7 (AI/datacentre in-house, unchanged and undiminished — it was always a *scope*, not a right depending on the carve-out). Tier P case 2 stays **defined but classifies no path**; `E-PWITHHELD` now guards *conveyance*, not creation, and is dormant. Priors: `architecture/ai-matrix/README.md` §7 · `AGENTS-licensing.md` → *Applied case*. |
| **AI-L** | **Counsel review of the licensing pass** | P0 | **Open.** Review `LICENSE.GSys-Commercial` §3.7 (AI/datacentre in-house scope over the whole tier-R corpus) + §4.1(ii) + §4.5, `NOTICE` §2(e), and the tier-P split. Also decide whether to pursue a `LicenseRef-GSys-OHL-SN` service-use variant (AGPL-for-hardware) — **deliberately not adopted**: it would forfeit CERN-OHL-S identity and compatibility. Both `LICENSE.GSys-Commercial:15-18` and `TRADEMARKS.md:7-8` already require counsel. |
| **AI-L2** | ~~Consolidate tier R into tier P / squash post-fork history~~ | — | **Considered and rejected — do not reopen without an explicit rights-holder decision.** The open path stays as-is (tier R remains dual-licensed). History rewriting could not achieve the goal in any case: `origin/master` is published, and a grant made in a published version is irrevocable regardless of later history. Reasoning recorded in `AGENTS-licensing.md` → *internal-production / service-use gap*. |
| **AI-1** | Seam: CVXIF `COPRO_G6LC_AI` (option B) | P1 | **Live green on `ai-matrix-p1`.** Full T0/T1 + PMU/RVFI + acc `tc_sram` + aiperm + queue T0 + island MMIO. **`ai-matrix-veri` 10/10 PASS**. Still open: MBIST, FO4, smt2 ownership, PLIC. |
| **AI-P3** | T2 descriptor engine + SoC attach | P3 | **Done for spine.** AXI + sideband + PLIC-8 + DMA fetch/store + `wr_cpl_en`. Suite green. GEMM compute is **AI-S3 / I1-lite** (below). |
| **AI-E2** | **Three pre-implementation contract corrections** | P0 | **Applied to `isa-encoding.md`; review open.** Surfaced only by the scaling review, all made before any implementation exists (so not version bumps): (1) **INT4 had no encoding** — `dtype[13:12]` is fully allocated, so `aicfg[21:20]` `ew` and `[22]` `sp24` were carved from reserved space, reading `0` on parts that lack them; (2) **the T2 descriptor was not self-describing** — it inherited dtype from a mutable CSR, which is a race for a ms-long engine and undefined for host-side doorbell submission, so type now travels in `flags[14:8]` and the engine may not read `aicfg`; (3) **no QoS/preemption contract** — added §7.1 (bounded work quantum, restartability at a `k` boundary, priority classes in `flags[19:16]`, per-queue isolation, watchdog). |
| **AI-E** | **Freeze the `Xg6lcai` ISA / CSR / descriptor contract** | P0 | **Drafted — `architecture/ai-matrix/isa-encoding.md` (version 1), review open.** custom-2 (`0x5B`); custom-3 is taken by the CVXIF example. CSRs `0x800-0x803` (URW), `0x5C0-0x5C2` (SRW), `0x7C8` (MRW) — verified clear of `CSR_ICACHE/DCACHE/ACC_CONS` at `core/include/riscv_pkg.sv:655-658`. Normative for **both** seams; a seam that needs an encoding change is a defect in the doc, not a fork. Review targets: operand-class table (§2), s32→s8 round-half-to-even rule (§3.5), descriptor layout (§7). |
| **AI-E3** | **`mstatus.xs` is READ-ONLY — contract defect, corrected pre-implementation** | P0 | **Applied to `isa-encoding.md` §4/§5/§6; review open.** Version 1 said to "un-hardwire `mstatus.xs`" and let software write it. The privileged spec (`specs/riscv-spec.html:72955-73090`) says `mstatus` has "the FS[1:0] and VS[1:0] **WARL** fields and the XS[1:0] **read-only** field"; that "**every additional extension with state provides a CSR field that encodes the equivalent of the XS states**"; and that XS "reports the **maximum** status value across all user-extension status fields". XS is a *summary, never a control*. Also: "in harts without additional user extensions requiring new state, the XS field is read-only zero" — so today's hardwire is **spec-required, not a bug**. Correction: allocate **`aistatus[7:6]` = `ais`** (Off/Initial/Clean/Dirty, URW) as the extension's own status field; `mstatus.xs` becomes a read-only summary of it; the illegal-instruction gate tests **`ais`**, not `xs`. Caught before any RTL existed, so no version bump (cf. AI-E2). |
| **AI-X** | **`mstatus.xs` read-only summary driven from `aistatus.ais`** | P1 | **Done.** CSR `aistatus.ais` drives `mstatus.xs`/`vsstatus.xs`; coprocessor reads `ais` over sideband and rejects issue when Off; Dirty pulses from exec write back into `aistatus`. |
| **AI-2** | **`g6lc64_server_math_v` violates the superscalar/accelerator assert** | — | **Open, pre-existing, independent of AI work.** Package sets `SuperscalarEn=1 / NrIssuePorts=2` (`core/include/g6lc64_server_math_v_config_pkg.sv:99-101`) **and** `RVV=1` (`:118`), violating `core/cva6.sv:2216`. Survives only because the assert is `translate_off initial` and Ara is normally a stub — a real sim should `$fatal` at t=0. Blocks option D; **shared** with the vector track. |
| **AI-3** | T2 descriptor engine address-checking | P3 | **Landed in spine.** `g6lc_ai_addr_check` per-queue `[base,limit)` + R/W; engine checks ptr_a/b/c/scale/done before accept. Standalone smoke rejects OOR and W-only. Still open: scrub/bank-partition between queues; bind checker in front of real DMA master. |
| **AI-S0** | ~~Size the 100-TOPS class~~ | I0 | **Done — `architecture/ai-matrix/scaling-100tops.md`.** Froze the definition (100 TOPS ≙ dense INT8, peak, 2 ops/MAC, no sparsity/INT4 multiplier); derived DRAM BW = (2/T)×MAC-rate ⇒ 391 GB/s at blocking T=256; machine balance ≈125 MAC/byte. Reversed three draft positions: chiplets **deferred** behind a die-size gate, island knobs **out of** `cva6_cfg_t`, on-die SRAM **8–32 MB** not 32–128 MB. |
| **AI-S1** | ~~SKU decision: latency/decode vs throughput/serving~~ | I0 | **Closed — BOTH, STAGED: latency SKU first, throughput SKU by cluster replication** (`scaling-100tops.md` §5.1). Rationale: at `T=512` the throughput SKU needs only 195 GB/s of GEMM bandwidth, while the latency SKU must buy ~400 GB/s anyway for batch-1 weight streaming — **so the expensive subsystem is built and measured first and covers both**, and adding compute later is pure cluster replication. Track order changes to I1 → I3 → (latency tape-out) → I2. Five binding conditions in §5.1: `T`/accumulator/DRAM frozen at I1; cluster is the only replication unit and the NoC cut line is set at I1; capability window ships at I1; cluster-**cooperative** blocking from the first cluster (independent per-cluster blocking collapses effective `T` to 64 and demands ~1.6 TB/s); both SKUs quoted with §12 metrics. |
| **AI-S2** | Seam decoupled from throughput target | I0 | **Recorded.** ~99.7% of island arithmetic never crosses a core seam, so the card SKU may ship on **seam B**; option D is now a small-SKU/latency feature. **Consequence: AI-2 is off the card's critical path** (still blocks the vector track). `README.md` §2 amendment. |
| **AI-S3** | Island RTL: cluster → memory → (latency SKU) → NoC/N clusters → PD | I1, I3, I2, I4 | **I1 AccTile*=256 / PeLanes=256; I3-lite multi-beat + B oct-drain + trail C-store + multi-out AR (depth 2) + PMU→CAP.** 256^3 **83.7k cy**. Suite 28/28. **ai-tensor:** SoftIsland + cosim + stream/WaitPolicy/fetch + depth/history + ProbeReport JSON + NumPy/TF + C ABI + RTL adapter. Next: wider NoC; board UIO/eventfd; HARD RTL lab. |
| **AI-5** | **`cv32a65x` lint baseline is stale — pre-existing, NOT AI** | — | **Open, unrelated to this track; do not attribute it to AiCfg.** `verify --lint` reports **190 warnings vs baseline 146** (`build-platform/src/config/defaults.ts:1185`) and fails the gate; `cv64a6_imafdc_sv39` drifts the other way (410 vs baseline 483, passes). Attribution measured with the platform's exact `lintArgs`: the entire AI config surface accounts for **0** warnings — the only `config_pkg`-family citation is the pre-existing `build_config_pkg.sv:287` `AXI_USER_EN` WIDTHEXPAND. Top contributors are `core/ooo/g6lc_rob.sv` (**27**), `cva6_hpdcache_if_adapter.sv` (**17**), `csr_regfile.sv` (**16**) — i.e. U5 OoO + cache work. The baseline comment itself says it was last re-measured 2026-08-06; commits have landed since. Action: re-measure and ratchet both baselines, or fix `g6lc_rob.sv`'s ASCRANGE/WIDTHEXPAND. |
| **AI-S4** | Card power/thermal envelope | I4 / P5 | **Open.** Estimated 60–80 W typical / 100–150 W peak ⇒ the 75 W slot budget is insufficient: 8-pin aux, boot-time power negotiation, and a mandatory DVFS/throttle cap loop. `architecture/uncore/pcie-endpoint.md` §3.1. All figures unmeasured — replace at I4. |

---

1. ~~**Register residual suites in build-platform**~~ **done** — `mc-mini-veri` + `mc-spo-veri`
   in `defaults.ts` (`optional: true`, not in `defaultSuites`); listed by `test --list`;
   Spike Zacas soft-skip remains honest (RTL mini = CAS golden). Maps:
   `AGENTS-specs-to-tests.md`, `AGENTS-build-platform.md` §4/§6.

2. ~~**Full CRT `mc-spo-veri` green**~~ **done (imafdc + server_math L2)** —
   - **imafdc** `FORCE_IMAFDC=1`: **9/9** hard PASS (log `mc-spo-veri-full-smoke.log`).
   - **`g6lc64_server_math`** (HPDCACHE_WT + L2, `NrCores=2`, bare-metal single-hart CRT):
     **9/9** hard PASS after same `DeepSpecEn=1` STQ deepen (log
     `mc-spo-veri-server-math-full.log`). Compact linker + Verilator 5.008.
   Root cause was STQ `DEPTH_COMMIT=4` (hang ≥40 B fill→verify). Dual-hart live CRT
   optional on multi-hart packages; smt2 dual_park LIVE_HARD greened (hold+grace).  
   **Priors:** `mc-spo-veri.sh` · `mini_stream_plane.S` · `store_buffer.sv` ·
   `cv64a6_imafdc_sv39_config_pkg.sv` · `g6lc64_server_math_config_pkg.sv`.

3. **H-edge directed diagnostics** (10 narrow + CF) — **Spike 3/3 hard green** (suite
   `kvm-h-spike`: h_edge_diag + kvm_h_stress + hlv_hsv_smoke). Covers hedeleg WARL,
   VTSR/VTVM/VTW cause 22, VS ecall to M (cause 10) + MPV sticky, dual VS re-entry.
   Spike footgun: default PMP denies S/VS fetch until TOR open (or PMP CSRs absent —
   illegal swallowed). **Spike + RTL Variane 3/3 hard green** on g6lc64_server_math (~1.5–2k cycles).
   SPV and tval/tinst polish optional if later litmus fails. Extends U9 + kvm-h-tests.
   **Priors:** verif/regress/kvm-h-spike.sh · verif/tests/custom/kvm_h/h_edge_diag.S ·
   architecture/server-math-hypervisor.md · Phase B · agents/spec/riscv-spec-II-5.* ·
   Hypervisor row in AGENTS-specs-to-impl.md · suites kvm-h-spike / kvm-h-tests.

4. **Stability battery + regress isolation map** — **landed**: isolation map
   `verif/regress/AGENTS-regress-scripts.md` (axes: target / ISS vs RTL / stack height / feature)
   + composed suite `stability-regress` (`verif/regress/stability-regress.sh`).
   Profiles: `artifact` | `spike` | `full` | **`stream8`** (spike + mini CAS on
   `work-ver-stream8` + `kvm-h-veri` + `stream8-smoke` live). FO4 optional outside this battery.
   **Priors:** `AGENTS.md` §0.2 · `AGENTS-specs-to-tests.md` · `AGENTS-build-platform.md` §4–§5 ·
   `mc-spo-*.sh` · `kvm-h-spike.sh` · `mc-mini-veri.sh`.

5. **Dual-ISS Spike+Verilator tandem polish** — **landed**: suite `dual-iss-regress`
   (tohost golden: mini_tohost + mini_jumps; optional `DUAL_ISS_H=1` for h_edge_diag;
   `DUAL_ISS_MODE=trace` via cva6.py). Zacas never dual-ISS golden. Mismatch triage in
   `verif/regress/AGENTS-regress-scripts.md` §7.
   **Priors:** `verif/regress/dual-iss-regress.sh` · `verif/sim/cva6.py` ·
   `AGENTS-build-platform.md` §5 · `AGENTS-specs-to-tests.md` · `defaults.ts`.

6. **R3b Linux `Image`** — **gate landed** (`r3b-linux-image`): contract always;
   soft-skip without external Image; `CVA6_R3B_BUILD=1` embeds Image via
   `build-opensbi-smt2.sh --linux`. Full shell//proc/cpuinfo still lab when Image present.
   **Priors:** `verif/regress/r3b-linux-image.sh` · `fetch-linux-image-hint.sh` ·
   `smt-linux-rootfs.md` · `software/smt2-linux/` · `smt-linux-r3-cosim` · `opensbi-linux-boot`.

7. **OpenSBI VRF + `CONFIG_RISCV_ISA_V` + Ara cosim** — **gate landed**:
   `software/vector/` (opensbi-vrf.md + linux.config-fragment) + suite `ara-vector-cosim`
   (soft skip/misa on Variane; live `v_memcpy_lmul` via `ARA_COSIM_LIVE=1` + server_math_v rebuild).
   Full multi-task OpenSBI VRF + kernel still lab when Image/_v TB provisioned.
   **Priors:** `verif/regress/ara-vector-cosim.sh` · `software/vector/` ·
   `architecture/ara-vector-attach.md` · `AGENTS-vector.md` · `testlist_ara_vector.yaml`.

8. ~~**AMOCAS.Q deferred**~~ **done (functional)** — `zacas-policy` hard green 4/4:
   odd-pair illegal + W/D/Q mini on Variane; plan `architecture/zacas-amocas-q.md`.
   Decode/pair RF/128b multi-beat RMW/dual WB; Spike never CAS golden.  
   **Priors:** `verif/regress/zacas-policy.sh` · `mini_amocas_{w,d,q,q_illegal}.S` ·
   `software/zacas/` · `architecture/zacas-amocas-q.md` · maps Zacas rows.

9. **Lab-only FO4/STA** — **host re-validated** (`s9-lab-gate`: doctor + lab-run fixture +
   retune guard). Still **lab-blocked**: S3b-lab `fo4-v1.toml` retune from **real** STA;
   S4b OpenROAD+LEF under `pd/pdk/`; full `./build.sh verify` when tools provisioned
   (`S9_FULL_VERIFY=1`). Do **not** retune FO4 from synthetic fixture STA.  
   **Priors:** `verif/regress/s9-lab-gate.sh` · `architecture/build-platform-opensta-from-timing.md`
   · `AGENTS-build-platform.md` §7 · `sv-timing/architecture/STA-HANDOFF.md` ·
   `architecture/build-platform-workspace-lifecycle.md` · `AGENTS-technology.md` ·
   verify gate `AGENTS.md` §0.2 / `build-platform/AGENTS.md` §4.6.

10. ~~**Dual-hart residual re-validation**~~ **done (host residual)** - suite
   `dual-hart-ci`: artifacts + boot-path + dual-park ELF compile; rootfs preflight with
   `SMT2_SKIP_R3=1` / `DUAL_HART_SKIP_R3=1` by default; smt2 lint soft-skips when only
   Windows OSS CAD PE is present under WSL (hard: `DUAL_HART_REQUIRE_LINT=1` + Linux-native
   `verilator_bin`). Optional `DUAL_HART_PARK_SPIKE=1` + bare dual-park. **Live smt2 Variane green** (boot hold + DRAM grace + peer switch fixes): bare
   `mini_tohost` + `smt_dual_park` + `smt_peer_tohost` on `work-ver-smt2`. R3 Linux cosim still lab/Image-external.
   **Priors:** `verif/regress/dual-hart-ci.sh` · `smt_dual_park.S` · `smt-linux-rootfs.sh` ·
   `architecture/multi-threading/smt2-bringup.md`.

11. ~~**Optional growth stream8-class**~~ **promoted (config + DTS + smoke)** —
    package `g6lc64_stream8` (NrCores=2, RVZacas, DeepSpec, L2, H; C-light),
    `ariane-stream8.dts`, suite `stream8-smoke` (optional). **Live RTL green** on
    Linux Verilator 5.008 (`work-ver-stream8`): AMOCAS.W/D/Q + stream plane SUCCESS;
    lint via `linux-eda-suite` / `$HOME/tools/verilator-v5.008`; **full CRT `mc-spo-veri` 9/9** + **H-edge Variane 3/3** (`kvm-h-veri` on work-ver-stream8).
    Branding/publication only if a rebrand branch merges here.
    **Priors:** `architecture/stream8-class.md` · `g6lc64_stream8_config_pkg.sv` ·
    `verif/regress/stream8-smoke.sh` · `multi-core/README.md` · `AGENTS-configuration.md`.

12. **Soft ladder DI OpenSBI (active)** — promote binary peels → B1 RTL / B2 firmware / B3
    harness. Oracle moved `tmp-dual-ci` → `software/smt2-linux/soft-ladder/`.
    Peels landed: spin, cmpx, CSR, c.mv, fdt_match, malloc, strlen (FETCH_WIDTH=64).
    **Open:** `b1-fdt-lenp-store` / `PEEL_FDT_GETPROP` (iter-012). Soft getprop default.
    Bisects all negative (reverted): dual-commit, STQ-nofwd, force SI issue — same pin.
    **Next:** a2/s3 call-boundary / structure-load / dual-fetch; then peel getprop + printf.
    Suites: `soft-ladder-opensbi-soak.sh`, `soft-ladder-di-regress.sh`.
    **Priors:** `architecture/multi-threading/soft-ladder/*` · `smt2-bringup.md` ·
    `fdt-topology-soft-ladder.md` · `core/{store_buffer,load_unit,issue_read_operands,commit_stage}.sv`.

13. **Multi-threading topology (cpu-map / cpuinfo / threads-per-core)** — plan landed
    (`fdt-topology-soft-ladder.md`): `S = NrCores × NrHarts`; smt2 = 1×2 SMT; stream8 = 2×1;
    issue width not DT-visible. **Blocked on soft-ladder SL-A/B** before trusting `plat_hc`
    or `/proc/cpuinfo`. DTS: `ariane-smt2.dts` / `ariane-stream8.dts`; RTL mhartid/CLINT already
    `N×T`. After FDT natural: `plat_hc==2`, R3/R3b, cpuinfo count; then stream residual;
    optional DTS generator for hybrid N×T (S≤8).
    **Priors:** `dts-linux-smt.md` · `smt-linux-rootfs.md` · `software/smt2-linux/` ·
    `AGENTS-dts-validation.md` · `g6lc_cluster.sv` · `ariane_testharness.sv`.

## Standing disciplines (apply every pass, per applicability)
Six **co-equal** upkeep rules; run each pass when it applies (none overrides the SoC prime directive):
1. Keep `agents/spec/INDEX.md` spec statuses current.
2. Log todos here in `AGENTS-todo.md`.
3. Apply the contributor-licensing policy (`AGENTS-licensing.md`) — **code edits only**; never for
   `AGENTS*`/`agents/**`/`specs/**`/`docs/**`. Requires `.active-contributor` + `.licensing-policy` or errors.
4. Apply the coding-philosophy checklist (`AGENTS-coding-philosophy.md`) using the target SoC context
   in `AGENTS-configuration.md` — **all code edits**; include a timing-impact note, review &
   validation checklist, `.dts`/spec/config alignment note, and SoC-context compatibility statement
   when applicable.
5. Maintain spec traceability (`AGENTS.md` §0.6): update `AGENTS-specs-to-impl.md` on ISA-visible RTL
   edits, `AGENTS-specs-to-tests.md` on test-suite/testlist edits, and re-derive `AGENTS-specs-coverage.md`.
6. Maintain Linux device-tree cross-validation (`AGENTS.md` §0.6): for device-tree-visible RTL/config
   changes, run `build-platform/scripts/fetch-linux-dts.{sh,ps1}` (sparse/blobless checkout), follow
   the procedure in `AGENTS-dts-validation.md`, and update the matching row.

## Phases
1. [x] Create `AGENTS.md` main guider.
2. [x] Create `agents/spec/INDEX.md` substructure guider.
3. [x] Create first 4 per-purpose guides (`branch-prediction`, `l2l3-cache`, `ram-memory`, `speculation`).
4. [x] Exemplar spec sub-files (RVWMO, PMA, PMP, Sv39).
5. [x] Spec-complete pass — write all remaining `agents/spec/*.html` files.
6. [x] Update `agents/spec/INDEX.md` rows from `pending` to `done` as files land.
7. [x] SoC-readiness prime directive — `AGENTS.md` section 0 + `agents/guides/AGENTS-soc-readiness.md`, grounded in verified loci (`tc_clk.sv`, `tc_sram.sv`, `cva6_fifo_v3.sv`, `config_pkg.sv`, CVXIF, `verif/`), wired into substructure map + navigation.
8. [x] Deep-review pass — added direct spec quotations, exact `file:line` CVA6 loci, and `.dts` linkages to all `agents/spec/*.html` sub-files.
9. [x] Contributor-licensing governance — `AGENTS-licensing.md` + `.active-contributor{,.example}` + `.licensing-policy{,.example}`; referenced from `AGENTS.md` section 0.4 and substructure map; active contributor `Etienne Cimon`, policy (source of truth `.licensing-policy`) `DEFAULT_TO_FILE_LICENSE` + `ALLOW_PERSONAL_LICENSE`/`PERSONAL_LICENSE=LicenseRef-Proprietary` + `SELECT_MOST_PERMISSIVE` (fallback) + `ADD_CONTRIBUTOR_NAME`: net-new contributor files → proprietary/Etienne Cimon (`LICENSE.Proprietary`), fallback Solderpad `Apache-2.0 WITH SHL-2.1`. Bulk relicense of Etienne Cimon MIT → `LicenseRef-Proprietary` applied 2026-07-31.
10. [~] Optional additional purpose guides (`AGENTS-fpu.md`, etc.) as feature work requires.
    - [x] `agents/guides/AGENTS-vector.md` (U10ᵇ RVV/Ara; wired into `AGENTS.md` §2/§3).
11. [x] Coding-philosophy / target-SoC-configuration governance — `AGENTS-coding-philosophy.md` +
    `AGENTS-configuration.md`; referenced from `AGENTS.md` section 0.5, substructure map, and carry-over
    checklist; co-equal with licensing and SoC prime directive.
12. [~] Build platform (`build-platform/`, Bun + TypeScript) — cross-platform toolchain/test
    orchestration driven by the repo-root `.config.ts`; bootstrappers `build.sh`/`build.ps1`; root
    pointer `AGENTS-build.md` → `build-platform/AGENTS.md`. Code is **LicenseRef-Proprietary / Etienne Cimon** per
    `.licensing-policy` (full text `build-platform/LICENSE`).
    - [x] Scaffold (package.json/tsconfig/bunfig/.gitignore), zero-runtime-deps design.
    - [x] Config surface: `.config.ts` + typed `schema.ts` + `defaults.ts` + `load.ts` (merge/validate).
    - [x] Platform layer: `os.ts`, `exec.ts` (Bun.spawn), `shell.ts` (pwsh/bash/zsh + runBashScript).
    - [x] Workspace: `layout.ts` + `discovery.ts` (glob discovery + size/mtime change-detection manifests).
    - [x] CLI: `doctor`, `config`, `clean`, `tools`, `setup`, `build`, `test` + rich help; `context.ts`/`childEnv`.
    - [x] Tooling: `locations.ts`, `detect.ts` (host probes incl. detect-only VCS/Questa/Vivado/OpenROAD), `submodules.ts` (git sync).
    - [x] `bun test` bridge to `verif/regress` suites (`tests/runner.ts`), opt-in exec via `CVA6_BUILD_RUN_HW=1`.
    - [x] Validated: `bunx tsc --noEmit` clean; `bun test` green (2 pass / 1 skip); `doctor`/`config`/`setup --dry-run` run.
    - [x] Tool install recipes (`tooling/recipes.ts`): verilator + spike reuse `verif/regress/install-*.sh`; riscv-gcc prebuilt fetch; iverilog via package manager.
    - [x] OS package bootstrap (`packageManagers.ts`: choco/apt/dnf/pacman/zypper/brew), gated by `--allow-system-install`/`platform.allowSystemInstall`.
    - [x] Python venv provisioner (`python/venv.ts`) → `workspace/tooling/python-venv` (pinned inline reqs + repo `requirements.txt`).
    - [x] `setup --install` orchestrates prerequisites → venv → recipes (validated via `--dry-run`; typecheck clean, `bun test` green).
    - [x] Regression catalog: all `verif/regress` scripts modelled as grouped suites (`defaults.ts`) with tools/submodule/UVM/openSource metadata.
    - [x] `test` selection + preflight: `--list` / `<id>` / `--suite` / `--group` / `--all` / `--open-source`; missing-dep suites skip (not fail); `DV_TARGET` wired.
    - [x] Cross-OS CI `.github/workflows/build-platform.yml`: verify matrix (win/ubuntu/mac) + on-demand ubuntu open-source smoke.
    - [x] Prereqs rounded out (apt/dnf `curl`/`wget`/`automake`, apt `python3-venv`) so the package manager covers what pip/bun don't.
    - [x] `status` command (one-glance setup/params: SoC target + toolchain provisioning + core→uncore→board→foundry
      subsystems) + top-level source-able `setenv.sh`/`setenv.ps1` that bootstrap Bun, `bun install`, expose the
      `cva6-build` command (wrapping `build.sh`/`build.ps1`), and print `cva6-build status`. Root `README.md` gains the
      agentic-first, build-platform-led "core → product" vision + getting-started. Validated: `bash -n setenv.sh` OK,
      `setenv.ps1` parses, `tsc --noEmit` clean, `bun test` 49 pass/1 skip.
    - [x] Production-suite catalog: `ooo-l3-tests`, `server-math-tests`, `kvm-h-tests`, `dual-hart-ci`,
      `smt-linux-*`, `spec-deep-*` (optional/lengthy; not in `defaultSuites`).
    - [x] SoC envelope aligned with `AGENTS-configuration.md` §1.1 (1250 MHz / 0.8 V / tsmc12ffc-class).
    - [x] `verify.formalTasks` ← U5 OoO scaffolds (`core/ooo/formal/{freelist,rob,cancel}.sby`); per-task workdirs.
    - [x] Wire `discovery.ts` change-detection into `build` (core RTL + flists; skip verilate when unchanged; `--force`).
    - [x] `status` surfaces verify targets / formal tasks / opt-in production packages + suites.
    - [ ] Optional Windows VS Build Tools provisioning (config flag present; provisioning logic TODO).
    - [ ] Physical-design flow (OpenROAD/SiliconCompiler/PDK) off `pd/synth` (currently detect-only).
    - [x] Sim stage reliability on Windows: `resolveBashBinary()` prefers Git for Windows over Cygwin
      when both exist; `runBashScript` / `runRegressScript` / doctor / status surface flavor.
    - [x] `verify --sim` preflight (`simPreflight.ts`): bash/riscv-gcc/verilator/make (+ spike/WSL
      warnings); fails closed when required tools missing (dry-run still plans suites).
    - [x] `timings lab-run`: one-shot sta_smoke materialize → fo4-golden → sta-handoff; probe matrix
      entries for lab-run / sta-handoff / verify --sim.
    - [x] `lab-report.json` + `lab-report.md` from lab-run; CI `build-platform.yml` runs
      `timings lab-run` on win/ubuntu/mac and asserts report artifacts.
    - [x] `timings doctor` — package/FO4 model inventory, PD tools, sim preflight, S3b-lab
      retune checklist; CI runs doctor + lab-run.
    - [x] Offline S3a self-test: synthetic `opensta_paths.rpt` fixture injected by lab-run
      (overlap_score > 0 without OpenSTA binary); `--no-sta-fixture` / `--inject-sta-fixture`.
      CI asserts numeric overlap_score on win/ubuntu/mac; unit test `injectStaFixture fills…`.
    - [x] **Host offline track closed** (S0–S3a fixture, S4a scaffold, doctor, lab-report).
      Next is lab-only (S3b-lab FO4 retune, S4b LEF) or RTL residual.
    - [x] **S3b-lab host propose** — `timings retune-propose` + `retunePropose.ts`; auto after
      `lab-run`; flags synthetic fixture so operators never retune fo4-v1 from offline S3a;
      CI asserts `retune-proposal.{md,json}`.
    - [x] **Structural FO4 monorepo soak (package-first, no build-platform):**
      `sv-timing/tools/monorepo_soak.py` + `svt.py monorepo-soak` on real `core/` sparse flists;
      `architecture/MONOREPO-SOAK.md`; coding philosophy §2.8 + review checklist.
    - [x] **Soak → from-timing → OpenSTA path:** `--correct/--emit` package + recipe;
      `verif/regress/monorepo-soak-from-timing.{sh,ps1}`; first WSL run sparse_ex
      analyze 106 paths / FO4 441.5→99 dry-run; emit integrity reparse still open (P15).
    - [x] Plan of record: granular workspace **clean** + **`--from-timing`** soak hand-off —
      `architecture/build-platform-workspace-lifecycle.md` (artifact taxonomy, subcommands, age
      filters, allowlisted `work-ver`, timings validate contract; keeps `sv-timing/` independent).
    - [x] **C0** `clean status` inventory (purpose map, sizes/ages, allowlist guard) +
      `src/workspace/clean.ts`; bare `clean` keeps today’s `workspace/build` behaviour.
    - [x] **C1** Purpose subcommands (`diag|verify|formal|timings|cache|manifests|downloads|man|dts`)
      + `--older-than <Nd|Nh|Nm>` + `--target`/`--compartment` (child expand) + rich `--help`;
      unit tests `test/clean.test.ts`.
    - [x] **C2** Opt-in `clean sim` (repo-root `work-ver/` allowlist) + `tooling`/`all`/`firmware`/`workspace`
      require `--yes`; refuse paths outside allowlist.
    - [x] **T0** `timings validate --from-timing <dir>` — structural check of portable.f + analyze/correct
      JSON (+ optional `--require-emit`); `validateTimingsOutDir` / `resolveFromTimingDir` in
      `tooling/timings.ts`.
    - [x] **T1** Plumb `--from-timing` into `test` / `diag` preflight (env `CVA6_FROM_TIMING` /
      `FROM_TIMING` via `runSuite` options); structure gate fails the command before suites/diags run.
      Default soaks still exercise **live** RTL (no emit flist swap). Suite scripts consume env
      (`svt_maybe_from_timing` / `Test-SvtFromTiming`).
    - [x] **T1b** `timings compile|analyze|correct --output|-o <dir>` materializes a full package
      (`portable.f`, report JSON, `param-map.json`, `ir.sqlite`, `stamp.json`, optional `corrected/`);
      `resolveTimingsOutputDir` + post-compile validate.
    - [x] **T2** Expert `--use-emit` on `test` / `build` / `verify` (default off) via
      `applyFromTimingFlags` → `CVA6_TIMINGS_EMIT_FLIST`; never auto-merges into `core/` (sv-timing NG4).
      Lint/synth remain on live RTL.
    - [x] **T3a** `stamp.json` on compile + `clean --execution all|last|failed|ok` (stamp-aware
      package select under timings/diag children).
    - [x] **T3b** Soak dashboards: `timings summary|dashboard`, `summarizeTimingsPackage`,
      `soak-dashboard.json`; auto-print after compile/validate and `test --from-timing` (structural FO4 only).
    - [x] **Docs** Top-level `AGENTS-build-platform.md` command structure + residual open list;
      `AGENTS-build.md` points there; Zacas/RVV status reconciled in specs maps + sub-files.
    - [x] **OpenSTA plan** `architecture/build-platform-opensta-from-timing.md` (S0–S5); host S0
      `timings sta-handoff` + `tooling/staHandoff.ts` (review-only `seeds.sdc`, `fo4_paths.csv`,
      `correlate.json`); suite `timings-sta-handoff`; `clean sta`; probe `opensta`/`sta`.
    - [x] **Broader FROM_TIMING** — `mc-spo-soak` validates package; optional `SVT_STA_HANDOFF=1`.
    - [x] **Bench correlate scaffold** — `timings correlate --bench <id>` → `bench-correlate.json`.
    - [x] **S1** Yosys synth smoke from portable.f / emit flist → `sta-handoff/.../synth/netlist.v`
      (soft-skip without yosys; OSS CAD suite preferred).
    - [x] **S2** OpenSTA when `sta`/`opensta` + liberty (`--liberty` / `CVA6_LIBERTY` / pd drop);
      `opensta/paths.rpt` + stub TCL without liberty.
    - [x] **S3a** FO4↔STA overlap score in `correlate.json` (`parseOpenStaPathReport`).
    - [x] **S3b** FO4 golden check (`timings fo4-golden check|write`, `fo4Golden.ts`,
      fixture `fo4-golden.json`); suite hard-check on sta_smoke. Lab retune of fo4-v1.toml still open.
    - [x] **S4a** OpenROAD `floorplan.tcl` scaffold when netlist exists; run if `openroad` on PATH
      (soft-fail without LEF).
    - [x] **sta_smoke fixture** — pure-Verilog `comb_adder` + analyze.json for S1 CI path;
      `materializeStaSmokePackage`; suite `timings-sta-handoff` hard-requires S0, soft S1–S4.
    - [x] **Bench metrics** — `benchMetrics.ts` / `timings parse-bench-log`; dhrystone_smoke + coremark
      tee logs + `timings correlate --file` when `CVA6_FROM_TIMING` set.
    - [ ] **S3b-lab** Retune `sv-timing/resources/fo4-v1.toml` from **real** STA (host
      `retune-propose` is done; package edit still lab-side).
    - [ ] **S4b** OpenROAD with real LEF/lib open-PDK study (lab).
13. [x] Malleability scaffold + spec traceability (additive; no RTL moved). Chose "additive scaffold"
    over a physical refactor to honor the §0 SoC prime directive (§0.3: never churn the working RTL
    hierarchy / break flists).
    - [x] `architecture/` non-compiled scaffold: blueprint `README.md` (target layout + migration plan +
      promotion path) + extension-point READMEs for `branch-prediction/`, `speculative-execution/`,
      `multi-threading/`, `multi-core/`, `l2-l3-cache/`, `spec-extensions/`. Not referenced by any flist.
    - [x] `AGENTS-specs-to-impl.md` — spec chapter ⇄ CVA6 RTL map (Parts I/II/III + microarch), status
      vocabulary, maintenance contract.
    - [x] `AGENTS-specs-to-tests.md` — spec chapter ⇄ build-platform suites + `verif/tests/testlist_*.yaml`
      (forward + reverse index + honest coverage gaps).
    - [x] `AGENTS-specs-coverage.md` — derived, status-only coverage summary (no file references).
    - [x] Registered as standing discipline in `AGENTS.md` §0.6 + substructure map; `verif/README.md`
      points to build-platform as the single test orchestrator (docs-level consolidation, no source moves).
14. [x] Linux RISC-V device-tree cross-validation (additive; no submodule). Avoided full kernel submodule
    because of size and Windows case-collision issues; instead added sparse, blobless fetch scripts and a
    cross-validation doc.
    - [x] `build-platform/scripts/fetch-linux-dts.sh` + `.ps1` — fetch `arch/riscv/boot/dts` + bindings YAML
      into git-ignored `build-platform/workspace/linux-dts/`, with manifest + ref/SHA reproducibility.
    - [x] `AGENTS-dts-validation.md` — DT node ⇄ Linux binding ⇄ spec anchor ⇄ CVA6 RTL/`config_pkg` ⇄
      CVA6 `.dts` cross-reference, generic reference DTS list, agent workflow, maintenance contract.
    - [x] Wired into `AGENTS-coding-philosophy.md` §4.9, review checklist §5, non-negotiable rules §6.2.
    - [x] Registered as standing discipline in `AGENTS.md` §0.6 + substructure map + §6 `.dts` linkage.
15. [~] Motherboard layer (`corev-mb/`) + `mb` configure flow (additive; no RTL moved, nothing in a
    flist). Board around the die: selecting one board adapts core/uncore config + fetches vendor IP +
    generates a **non-compiled** board package. Code is **LicenseRef-Proprietary / Etienne Cimon** per `.licensing-policy`.
    - [x] Config surface: `MotherboardConfig`/`PcbPartsConfig` in `build-platform/src/config/schema.ts`
      + `defaults.ts` (`activeBoard:null` default → existing configs/CI untouched) + `load.ts` validation.
    - [x] pcbparts.dev MCP client `build-platform/src/tooling/pcbparts.ts` (all 14 tools, cache-first,
      network only with `--online`) + Python mirror `corev-mb/lib/pcbparts_mcp.py` (stdlib-only).
    - [x] Board engine `build-platform/src/tooling/motherboard.ts`: `board.json` load/validate, CPU⇄board
      compat check, vendor-id resolve, `<id>_board_pkg.sv` + `board.mk` generation, overlay writer, scaffolder.
    - [x] CLI `mb` command (`list/select/check/create/design/expand/parts/test`) + registry; value flags
      added in `args.ts`. `select` = the SoC+MB "configure" step (overlay + `vendor sync` + generate).
    - [x] genesys2 reference: `corev-mb/boards/genesys2/board.json` (matches `ariane_xilinx.sv` GENESYSII),
      `AGENTS-mb-genesys2.md` contract, `corev-mb/architecture/genesys2/README.md` target.
    - [x] SKiDL flow `corev-mb/lib/` (`soc.py`, `interfaces.py`, `erc.py`) — custom boards only; skidl-optional.
    - [x] Analysis-only targets (described, NOT included): `corev-mb/architecture/{bpi-f3,milkv-jupiter,milkv-titan}/`
      (SpacemiT K1/M1 feature sets + honest CVA6 gaps: RVV, multi-core, LPDDR4 PHY, USB3).
    - [x] `AGENTS-motherboard.md` governance + `AGENTS.md` §0.5 board-counterpart note + §2 substructure rows.
    - [x] `AGENTS-mb-skidl.md` — board design-philosophy (PCB counterpart to `AGENTS-coding-philosophy.md`):
      pcbparts.dev part selection + power-rail planning + SoC-pin↔PHY mapping + physical-positioning/layout
      intent + ERC loop + per-domain playbooks + carry-over checklist (custom boards). Cross-reffed from
      `AGENTS-motherboard.md` §7/§8, `AGENTS.md` §2, `corev-mb/lib/README.md`.
    - [x] Tests `build-platform/test/motherboard.test.ts`; `bunx tsc --noEmit` clean; `bun test` green.
    - [ ] Promote a board → real `corev_apu/fpga/src` top-level importing the generated package + flist entry.
    - [ ] LPDDR4/USB3 controller gaps + RVV/multi-core deltas for SpacemiT-class boards (see architecture docs).
16. [~] Technology-optimization pass (opt-in; additive, no RTL moved, nothing in a flist). Adapts CVA6 to
    a foundry process by binding proprietary, high-level abstraction layers (memory compilers, ICG /
    retention / level-shifter cells, power kits, hard macros) at the existing PDK-swap seam, macro-protected
    behind `CVA6_TECH_OPT`, with the PDK **omitted-under-NDA**. Build-platform code is **LicenseRef-Proprietary / Etienne
    Cimon** per `.licensing-policy`; docs/READMEs are out of licensing scope.
    - [x] Config surface: `TechnologyConfig`/`TechnologyPdkMode` in `build-platform/src/config/schema.ts`
      + `defaults.ts` (`optimizationPass:false`, `pdkMode:"omitted"` → existing configs/CI untouched) +
      `load.ts` validation (mode, guard-macro identifier, spec globs, nda-needs-activeTechnology invariant).
    - [x] Engine `build-platform/src/tooling/technology.ts`: two-key ignition (`assessPass`), `*.tech-spec.md`
      detection (`detectSpecDocs`), PDK presence, read-only `planAdaptation`, SoC-readiness `readinessGates`,
      per-technology `scaffoldTechnology` (gitignored drop-in).
    - [x] CLI `tech` command (`status/specs/plan/check/init`) + registry; value flags `--tech`/`--pdk`;
      `check` exits 3 when enabled-but-not-ready. Tests `build-platform/test/technology.test.ts`.
    - [x] Protected NDA drop-in root `pd/pdk/` (git-ignored except READMEs + `manifest.example.json` + the
      per-dir `.gitignore`), per-area `pd/pdk/{core,corev_apu}/`, `technology.example/` template. Verified
      `git add -n` stages only the 9 scaffold files; NDA content (`*.lib/.lef/.gds`, drops) stays ignored.
    - [x] Governance `AGENTS-technology.md` + agentic playbook `agents/guides/AGENTS-technology-optimization.md`;
      `AGENTS.md` §0.7 standing rule (high-level workflow) + substructure map + §3 navigation rows.
    - [x] Validated: `bunx tsc --noEmit` clean; `bun test` green (49 pass / 1 skip).
    - [ ] Add a guarded RTL wrapper at the `tc_sram`/`sram_cache` seam for a concrete target library
      (worked example only in the guide; deferred until a real PDK drop is available).
17. [~] **Router-core upgrade program** — efficiency-ranked plan (OpenWRT/Linux router core + staged
    multi-issue OoO). **Priors / live progress (open these before editing checklist rows):**
    `architecture/router-core-upgrade-program.md` · `architecture/README.md` (live RTL table +
    programs of record) · `architecture/remaining-upgrade-sequence.md` (§0 done/open, §4 next +
    prior spine) · Current phase table above (landed + prior paths). Those docs supersede older
    checklist rows below when they conflict; open residual items point back to Practical next §N.
    - [x] Program document + `architecture/out-of-order/` extension point + programs-of-record table.
    - [x] **SoC envelope** — `AGENTS-configuration.md` §1.0/§1.1/§2.2 filled (1.25 GHz / 0.80 V /
      12 nm FFC-class inferred from shelf router silicon; open-PDK study path only). Build-platform
      `soc.*` defaults + `.config.ts` aligned.
    - [x] **Per-change verification gate** — `cva6-build verify [--lint|--formal|--sim|--synth]`
      (`build-platform/src/cli/commands/verify.ts` + `src/tooling/eda.ts`). OSS CAD Suite 2026-07-24
      under gitignored `build-platform/workspace/tooling/oss-cad-suite/`.
      - lint / elab / synth as before; baselines ~483 / 138 on primary targets (ratchet as warnings drop).
      - [x] `verify.formalTasks` = U5 OoO freelist + ROB + cancel (`.sby` use `read -formal`).
      - [ ] sim stage still host-dependent (needs bash + riscv-gcc + spike provisioned).
    - [x] **U1–U4, multi-issue, U7ᵃ/ᵇ/ᶜ, U6.0–U6.2, U8ᵃ, U9.x H/Sstc, U10 C-light** — see architecture
      live RTL table (TAGE_LITE, FTQ/FDIP, way-pred, slice-OoO gated, L2/L3, SMT, multi-core hub,
      PMU groups, server-math package, multi-context PLIC).
    - [x] **U5 full OoO** — production gated (`OoOEn`); packages `cv64a6_ooo` + `cv64a6_ooo_server`;
      suite `ooo-l3-tests` (optional).
    - [x] **U10ᵇ Ara** — package `_v`; `vendor sync ara` → `upstream/` + `Flist.ara` (**vendored**);
      sim/synth flist append still open for live vector.
    - [x] `vendor sync ara` + `vendor/ara/Flist.ara` (catalog status **vendored**; sim flist append open)
    - [x] L3 victim → L2 tag match-inval + TB `INCLUSIVE_L3=L3En` (L1 inclusive already present)
    - [x] p6 stream plane × multicore suite `mc-stream-tests` (artifacts + lint; cva6.py when ready)
    - [x] `ServerPrefetchEn` on `cv64a6_server_math` (2-core stream plane without L3)
    - [x] `verify.extraFlists` / `extraFlistsByTarget` + `topByTarget` + suite `ara-vector-path`
    - [x] Arm Ara for `cv64a6_server_math_v` (Flist.ara + typed top); **lint PASS**
    - [x] `ariane` EnableAccelerator path + `cva6_ara_attach` + optional wide AXI dwc/mux
    - [x] Residual gates green (lint path): ara/mc-stream/dual-hart/formal
    - [x] `CVA6_ARA_ATTACH=1` live Ara Verilator lint green (deps + cva6_shim; slang skipped)
    - [x] Spec status maps + `riscv-spec-I-9-vector.html` for RVV/Ara **partial** attach
    - [x] Formal vs **live** freelist + ROB RTL (ROB via yosys-slang; BMC depth 16 **PASS**);
      cancel remains policy model
    - [x] Live multi-port rename formal (`cva6_ooo_rename.sby`): free∩busy=∅, x0 map,
      dual-issue bypass, alloc≠0; rename package-free `NR_WB` API; **PASS** + `cv64a6_ooo` lint
    - [x] dual-hart-ci hardened (boot-path + dual-park ELF + rootfs R3-skippable + smt2 lint soft-skip when PE-only/WSL host-skew)
    - [x] smt-linux-rootfs R2a (payload+DTB when CROSS_COMPILE) + clearer R3/OpenSBI path
    - [x] mc-stream toolchain probe (riscv-gcc/spike) with clear lint fallback
    - [x] Windows managed xPack install (`toolchain.riscvGcc.prebuiltUrl.windows` + zip recipe)
    - [x] Dual-hart R3a OpenSBI `fw_payload.elf` built natively (Cygwin make + cygwrap)
    - [x] R3 suite soft-gates sim: **PASS R3a** when firmware present; R3 cosim = Linux/WSL
    - [x] `installSpike` WSL/Linux via `build-platform/scripts/install-spike.sh`
      (adopts `~/tools/spike`, cmake4/cstdint patches, managed `workspace/tooling/spike`)
    - [x] `cva6.py` pre-defined targets include `cv64a6_smt2` / ooo / server_math packages
    - [x] Windows cva6.py portability: `dv/lib.py` bash `-lc`, GCC version parse (xPack),
      `.elf` directed tests, ISS path `str.replace`, conditional Spike/Verilator checks
    - [x] R3 suite: full env setup + soft-pass R3 on native Windows (path mix); force via
      `CVA6_FORCE_WIN_CVA6PY=1` / hard-fail `CVA6_REQUIRE_R3_SIM=1`
    - [x] build-platform **install profiles**: `tools install <sim|dual-hart|opensbi|all>`
      + `setup --install --profile …` (`installProfiles.ts`; OpenSBI scripts wired)
    - [x] Managed Spike installed under `workspace/tooling/spike` (Linux ELF; run via `wsl`)
    - [x] R3 RTL cosim path on **WSL**: `smt-linux-r3-cosim.sh` + Verilator `cv64a6_smt2`
      model; `fw_payload.elf` → Variane **SUCCESS** (~6.5M cycles); suite auto-WSL on Windows
    - [x] **probe** CLI: categorical boxes (host/pkg/utils/tools/env/diag/commands/install),
      residuals, install playbook; wired into doctor/setup post-snapshot
    - [x] **diag** CLI + `config.diagnostics`: compartmentalized tests with **per-test
      Verilator configs** (`lintWithSurface`); probe `diag` tab
    - [x] Docs: `AGENTS-build.md`, `build-platform/README.md`, `build-platform/AGENTS.md`
      §4.6 probe→install→diag→verify operator workflow
    - [x] U10ᵇ software contract (non-BP): `AGENTS-vector.md`, `ariane-server-math-v.dts`,
      directed `v_memcpy_{skip,lmul}` / `v_misa_v` + `testlist_ara_vector.yaml`; ara-vector-path
      gates artifacts
    - [x] Zacas AMOCAS.W/D (`RVZacas`): decode + 3rd-op RF + `amo_req.operand_c` + `amo_alu`
      + HPDCache/WT CAS pack; packages server_math{,_v}/ooo_server + imafdc baseline; narrow
      tests in `testlist_mc_stream` (zacas_w/d, spo st-fwd, fence drain, cas lock handoff,
      CF×stream, CAS×stream, mispred×stream) + suite `mc-spo-soak`
    - [x] Multi-core spo **Spike** soak (`mc-spo-spike`) + harden narrow CAS/stream asm
    - [x] Verilator **mini** bare-metal hard gate (`mc-mini-veri`: tohost/jumps/AMOCAS.W/D);
      FTQ reseed + I$/missunit/AMO path fixes for green Variane
    - [x] Structural FO4 residual cuts on sparse_ex/frontend at **2.5 GHz** (`sv-timing`;
      screening only — not STA). Host clean/`--from-timing` track closed offline
    - [x] Full CRT RTL cosim (`mc-spo-veri`) — imafdc **9/9** + `g6lc64_server_math` L2 **9/9**
      (DeepSpec STQ). Dual-hart live CRT optional. → **§2 done**;
      priors: `mc-spo-veri.sh`, `mini_stream_plane.S`, `g6lc64_server_math_config_pkg.sv`
    - [x] Register `mc-mini-veri` + `mc-spo-veri` in `defaults.ts` → **§1 done**;
      priors: `build-platform/AGENTS.md` §4, `AGENTS-specs-to-tests.md`
    - [x] H-edge Spike + RTL Variane 3/3 (hedeleg WARL, VT*→22, MPV, dual VS ecall)
      → **§3 done** (kvm-h-spike + monorepo-soak/run-h-edge-veri.sh on server_math TB)
      priors: verif/regress/kvm-h-spike.sh, h_edge_diag.S, architecture/server-math-hypervisor.md,
      Phase B, agents/spec/riscv-spec-II-5.*, Hypervisor impl row
    - [x] `verif/regress/AGENTS-regress-scripts.md` + `stability-regress` battery → **§4 done**;
      priors: `AGENTS.md` §0.2, `AGENTS-build-platform.md` §4–§5, `AGENTS-specs-to-tests.md`
    - [x] Dual-ISS Spike+Verilator residual (`dual-iss-regress` tohost 2/2; +H 3/3) → **§5 done**;
      priors: `verif/regress/dual-iss-regress.sh`, `AGENTS-build-platform.md` §5
    - [x] R3b Linux Image **gate** (`r3b-linux-image` soft-skip without Image; LINUX_IMAGE build path) → **§6 gate done**;
      full rootfs shell still external/lab when Image available
      priors: `verif/regress/r3b-linux-image.sh`, `smt-linux-rootfs.md`, `software/smt2-linux/`
    - [x] OpenSBI VRF contract + Linux `CONFIG_RISCV_ISA_V` fragment + `ara-vector-cosim` soft path → **§7 gate done**;
      live lmul rebuild optional (`ARA_COSIM_LIVE=1`)
      priors: `software/vector/`, `verif/regress/ara-vector-cosim.sh`, `AGENTS-vector.md`
    - [x] AMOCAS.Q **functional** + odd illegal + W/D/Q hard mini (`zacas-policy`) → **§8 done**;
      priors: `software/zacas/README.md`, `mini_amocas_q_illegal.S`, `mc-mini-veri`, zacas maps


## What "done" means for a spec sub-file
A sub-file is **done** when it contains:
- Canonical deep-link `../specs/riscv-spec.html#<anchor>` and source line.
- One or two paragraphs of Logisplain summary (goal, spec grounding, mechanical dissection, conceptual linkage).
- A **Pseudo-SystemVerilog synthesis notes** block if the subchapter implies hardware structure, otherwise a note that it is pure ISA decode/execute.
- A **CVA6 status** line: `implemented` / `partial` / `absent` + concrete `file:line` locus or `locus TBD`.

A file is **deep-reviewed** when every claim is traceable to a spec quote and every CVA6 locus has been
verified against the actual source.

## Pending high-priority sub-files (domain order)
Tick as completed. Each is `agents/spec/<filename>`.

### Vol I
- [x] `riscv-spec-I-1.4-memory.html`
- [x] `riscv-spec-I-1.6-traps.html`
- [x] `riscv-spec-I-2.1-rv32i.html`
- [x] `riscv-spec-I-2.2-rv64i.html`
- [x] `riscv-spec-I-3.2-ztso.html`
- [x] `riscv-spec-I-4.1-zifencei.html`
- [x] `riscv-spec-I-4.9-ziccif.html`
- [x] `riscv-spec-I-4.10-ziccid.html`
- [x] `riscv-spec-I-4.11-ziccrse.html`
- [x] `riscv-spec-I-4.14-zicclsm.html`
- [x] `riscv-spec-I-4.15-zic64b.html`
- [x] `riscv-spec-I-4.17-cfi.html`
- [x] `riscv-spec-I-4.18-zihintntl.html`
- [x] `riscv-spec-I-4.19-zihintpause.html`
- [x] `riscv-spec-I-4.20-cmo.html`
- [x] `riscv-spec-I-5.1-a.html`
- [x] `riscv-spec-I-5.2-zalrsc.html`
- [x] `riscv-spec-I-5.3-za128rs.html`
- [x] `riscv-spec-I-5.4-za64rs.html`
- [x] `riscv-spec-I-5.5-zawrs.html`
- [x] `riscv-spec-I-5.6-zaamo.html`
- [x] `riscv-spec-I-5.7-zalasr.html`
- [x] `riscv-spec-I-5.8-zabha.html`
- [x] `riscv-spec-I-5.9-zacas.html`
- [x] `riscv-spec-I-5.10-zama16b.html`

### Vol II
- [x] `riscv-spec-II-3.4-reset.html`
- [x] `riscv-spec-II-3.5-nmi.html`
- [x] `riscv-spec-II-4.1-supervisor-csrs.html`
- [x] `riscv-spec-II-4.2-supervisor-instructions.html`
- [x] `riscv-spec-II-4.3-sv32.html`
- [x] `riscv-spec-II-4.5-sv48.html`
- [x] `riscv-spec-II-4.6-sv57.html`
- [x] `riscv-spec-II-5.1-hypervisor-modes.html`
- [x] `riscv-spec-II-5.2-hypervisor-csrs.html`
- [x] `riscv-spec-II-5.3-hypervisor-instructions.html`
- [x] `riscv-spec-II-5.4-mlevel-csrs-hypervisor.html`
- [x] `riscv-spec-II-5.5-two-stage-translation.html`
- [x] `riscv-spec-II-5.6-hypervisor-traps.html`
- [x] `riscv-spec-II-6.1-smstateen.html`
- [x] `riscv-spec-II-6.2-smcsrind.html`
- [x] `riscv-spec-II-6.3-smepmp.html`
- [x] `riscv-spec-II-6.4-smcntrpmf.html`
- [x] `riscv-spec-II-6.5-smrnmi.html`
- [x] `riscv-spec-II-6.6-smcdeleg.html`
- [x] `riscv-spec-II-6.7-smdbltrp.html`
- [x] `riscv-spec-II-6.8-smctr.html`
- [x] `riscv-spec-II-6.9-priv-cfi.html`
- [x] `riscv-spec-II-6.10-pointer-masking.html`
- [x] `riscv-spec-II-7.1-svnapot.html`
- [x] `riscv-spec-II-7.2-svpbmt.html`
- [x] `riscv-spec-II-7.3-svadu.html`
- [x] `riscv-spec-II-7.4-svinval.html`
- [x] `riscv-spec-II-7.5-svvptc.html`
- [x] `riscv-spec-II-7.6-svrsw60t59b.html`
- [x] `riscv-spec-II-8.1-ssqosid.html`

### Vol III
- [x] `riscv-spec-III-1-intro.html`
- [x] `riscv-spec-III-3-rva20.html`
- [x] `riscv-spec-III-4-rva22.html`
- [x] `riscv-spec-III-5-rva23.html`
- [x] `riscv-spec-III-6-rvb23.html`

## Low-priority / ISA-arithmetic sub-files (done as chapter-level summaries)
- Vol I chapters 1 (terminology), 6 (FP), 7 (compressed), 8 (bitmanip), 9 (vector), 10 (packed), 11 (crypto), 12 (matrix), appendices A-E.
- Vol II chapters 1 (intro), 2 (CSRs), 3.1-3.3 (M-level), 9 (Sh), 10 (listings), appendix A.
- Vol III chapter 2 (RVI20).

## Backlog of code-side unknowns to verify
- [x] Exact `file:line` for `FENCE.I` sequencing in `core/controller.sv` — verified (`:121-136`, etc.).
- [x] Exact `file:line` for `Zic64b` cache-line size assertion vs `DcacheLineWidth` — verified (`core/include/config_pkg.sv` line widths are 16/32 bytes; Zic64b not satisfied).
- [x] Exact `file:line` for PMP CSR read/write in `core/csr_regfile.sv` — verified (`:857-960` read, `:1839-1936` write).
- [x] Exact `file:line` for LR/SC reservation state in `core/load_store_unit.sv` and D$ — verified (LSU/AMO buffer/WT/HPDcache paths).
- [x] Extension presence audit (re-verified against live RTL / packages):
  - **Absent** (this tree): `Ztso`, `Zabha`, `Zama16b`, `Svvptc`, `Svrsw60t59b`, in-core RVV VRF (AMOCAS.Q **implemented**).
  - **Partial / config**: **Zacas AMOCAS.W/D** (`RVZacas`); **RVV via Ara attach**; H U9.0–U9.2;
    L2/L3/multi-core hub; SMT2.
  - **Authoritative status tables:** `AGENTS-specs-to-impl.md` · `AGENTS-specs-coverage.md` ·
    sub-files via `agents/spec/INDEX.md` · program snapshot `architecture/remaining-upgrade-sequence.md` §0.
- [x] Spike Zacas cosim remains **unavailable** (ISS); hard-gate CAS on RTL mini / `zacas-policy`.
  → **§8**; priors: `software/zacas/README.md`, `mc-mini-veri.sh`, `zacas-policy.sh`.
- [x] `g6lc64_server_math` L2 bare-metal CRT 9/9 (DeepSpecEn=1; NrHarts=1 / NrCores=2).  
  → **§2**; logs `mc-spo-veri-server-math-full.log`. Dual-hart live park greened on smt2 (`a0c410f3d`).
- [x] H-edge Spike + RTL Variane litmus 3/3 (hedeleg WARL, virt-instr 22, VS ecall/MPV,
  dual re-entry). SPV residual optional.
  → **§3 done**; priors: h_edge_diag.S, kvm-h-spike.sh, run-h-edge-veri.sh,
  architecture/server-math-hypervisor.md, agents/spec/riscv-spec-II-5.*-hypervisor*.html.

## AI-matrix open (sideband dual-poll) — **closed**
- Was misdiagnosed as a CVXIF `rs_valid` wedge. Root cause: **sideband `ai.enq` races MMIO desc updates** (`fence` does not wait AXI BRESP; kick is a core wire). Same-addr load-back can STLF and still race. Second enq reused the prior good latch → poll OK; test `fail` used even `a0=2` → HTIF syscall hang (timeout). Fix: drain via a *different* island reg after desc/region MMIO before `ai.enq`; odd HTIF fail codes. Covered by `ai_enq_sideband_smoke` phase-2 + `ai_dual_enq_poll`.
