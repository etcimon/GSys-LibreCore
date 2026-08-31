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
**SMT2 × AI attunement:** soft-ladder DI residual + dual-hart topology **and** ai-tensor /
PyTorch staged track (branch **`smt2-ai-tensor-linux`**).  
Program spine: `architecture/remaining-upgrade-sequence.md` §0/§4 · residual matrix
`AGENTS-build-platform.md` §5–§7 · live RTL table `architecture/README.md` ·  
**soft ladder** `architecture/multi-threading/soft-ladder/` ·  
**topology** `architecture/multi-threading/fdt-topology-soft-ladder.md` ·  
**AI×SMT track** `architecture/multi-threading/smt2-ai-tensor-linux.md` ·  
**multi-threading map** `architecture/multi-threading/README.md` (AI attunement §) ·  
**MT harness of record** `architecture/multi-threading/testharness-proxy.md` (proxy-only Spike/soak/peel) ·  
**Linux-boot scale** `architecture/multi-threading/linux-boot-scale.md` (OpenSBI × fetch_B combos × envelopes).

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
| **Soft ladder (DI OpenSBI residual scaffold)** | **P0 done** + **I4dn kept**. Default and `PEEL_FDT_GETPROP=1` **SUCCESS**. Combined still `12eb2`. New `mini_fdt_namelen_walk` Spike+Variane **PASS**; `mini_fdt_opensbi_blob` Variane **PASS** — 12eb2 is stock OpenSBI `next_tag` binary, not the reconstructed nest. I4cd/I4ce reverted. Soft getprop stays. | `ITERATION` I4dn · `mini_fdt_namelen_walk.S` |
| **FDT topology plan** | `NrCores`×`NrHarts` (threads/core), stream vs SMT `cpu-map`, issue width non-DT; gates before `/proc/cpuinfo` **and before multi-thread PyTorch** | `fdt-topology-soft-ladder.md` · `ariane-smt2.dts` · `ariane-stream8.dts` |
| **SMT2 × ai-tensor / PyTorch** | Soft pytorch **PASS** (Device virt-card). Fast track live. Multi-thread host workers **blocked** on soft-ladder hold cookie + SL-C + Linux Image. AI CSR banked on SMT. | `smt2-ai-tensor-linux.md` · `multi-threading/README.md` · `ai-tensor/AGENTS.md` · HARD `ai-matrix/hard-tests.md` |
| **Ara / RVV** | Attach + DTS + directed; **VRF/cosim gate** `ara-vector-cosim` (live lmul opt) | `architecture/ara-vector-attach.md` · `agents/guides/AGENTS-vector.md` · `agents/vendor/AGENTS-vendor-ara.md` · `agents/spec/riscv-spec-I-9-vector.html` · suite `ara-vector-path` |
| **H / KVM** | U9 + **H-edge Spike+RTL 3/3** (`kvm-h-spike` / Variane server_math) | `architecture/server-math-hypervisor.md` · remaining-upgrade Phase B · `agents/spec/riscv-spec-II-5.*-hypervisor*.html` · impl Hypervisor row · `verif/tests/custom/kvm_h/` · suite `kvm-h-tests` |
| **`g6lc_qemu` emulation** | **Q2 closed** — B0 stock-QEMU emission complete: `--emit args` (full invocation + capability delta), `--emit dts`/`dtb` (in-tree DTB writer, no `dtc` needed), profile-aware disks/networking, `--fw`/`--kernel`/`--initrd`/`--rootfs` plumbing. **Boot gate not verified** — no emulator, `dtc` or RISC-V cross-toolchain on the authoring host. **Next: Q3** native Rust VM. **Never citable as evidence** (proxy discipline). | `architecture/g6lc-qemu/README.md` (thesis + GPL boundary) · `staging.md` (Q0–Q9) · `cli.md` (DTS/APU/OpenSBI/OS args) · `diagnosis.md` (D1 tandem / D2 uarch) · `ai-island.md` (Xg6lcai + ai-tensor in-guest) · package queue `g6lc_qemu/AGENTS-todo.md` · `.licensing-tiers` (`T g6lc_qemu/**`) |

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

**Resume order (review pass 2026-08-29).** The O3 residual is **not a fetch class** and the S1
table already proves it — so the next three items are ordered off that fact, not off another G1\*
letter: **SL-W** (D$ ACK-before-check) → **AI-2** (config-integrity on `g6lc64_server_math_v`, the
Linux-boot bar package itself) → **SL-R**(1) (`geo()` wiring). Both of the first two are now
**specified rather than open-ended**: SL-W has a micro-arch note
([`architecture/dcache-ack-before-check.md`](architecture/dcache-ack-before-check.md)) with the
untried design axis and six acceptance gates, and AI-2 has a diagnosed root cause plus a 2-line fix
(pin `ACCEL` to issue port 0 via the unused `fus_busy_t.accel` field). Neither was landed: SL-W needs
proxy evidence, and AI-2 touches the dual-issue throttle that `core-fetch/SPEC.md` §9.6 freezes until
R6–R11. The L1–L4 module extract likewise stays gated behind the R4 pin (`SPEC.md` §8).

Landed in that pass, inspection-verifiable only: the `core/fetch_B` duplicate drop (SL-R) and the
`VoidKeepEn` / `VoidKeepTag` naming (SL-W) — both uncompiled or bit-identical, so neither needs a
re-soak. **Nothing in that pass is claimed green:** the host had no `verilator` and no
`TH_REMOTE_HOST`, and evidence is proxy-only (`AGENTS.md` §0.8).

| # | Item | Phase | Status / next action |
|---|------|-------|----------------------|
| **SL-0** | **Register residual suites in build-platform** | P0 | **Done.** Optional `soft-ladder-di` + `soft-ladder-osbi` in `defaults.ts` (not `defaultSuites`); diag `diag-soft-ladder-paths`; maps in `AGENTS-specs-to-tests.md` / `AGENTS-build-platform.md` / `AGENTS-regress-scripts.md`. |
| **SL-P** | **Proxy-only MT evidence** | B3 | **Normative.** Spike ISS, Variane soaks, peels, TRACE, I4dp 200M-cap: `verif/regress/remote/testharness_proxy.py` only. S1 battery: `verif/regress/remote/s1-linux-boot-regress.sh`. SYNC includes pin / default-mk / peel_both (not refused held). Classify from `runs/<tag>/run-*.log` (rc=255 ≠ fail). Added `di` subcommand to `testharness_proxy.py` for parallel remote directed-mini regression (compile locally, run remote harness with thread pool). Plan: `architecture/multi-threading/testharness-proxy.md`. I4dn kept; I4cd/I4ce/I4cf stay reverted. |
| **SL-N** | **Linux-boot scale (named envelopes)** | P6 | **Plan landed.** [`linux-boot-scale.md`](architecture/multi-threading/linux-boot-scale.md): OpenSBI O0–O8, `smt_legacy` oracle only, fetch_B **four combos** (no fifth, no `core/frontend` churn). Live bar: `_v` N=2 T=2 V=1 and `ooo_server` N=4 T=2 I=4 (I4dp). smt2 still lacks natural FDT, `RVH`, RVV, `NrCores>1`. `NrHarts>2` blocked on `CVA6_MAX_SMT_HARTS=2` + PLIC `S≤8`. Do not merge packages. |
| **SL-A** | **iter-013 / S4 fetch_B/IQ leftover — CLOSED as IAF/test-address** | P1–P2 | **Closed (2026-08-30).** The `mini_fdt_nt_ptr0` failure was an instruction-access fault, not a fetch_B/IQ leftover bug. The FDT stub at `0x8001e030` is outside the `g6lc64_smt2` execute region (`0x80000000` length `0x1e000`). Fixed by moving `.text.fdt` to `0x8001d000` in `verif/tests/custom/multicore/mini_fdt_nt_ptr0.{S,ld}`; `mini_fdt_nt_ptr0` now passes on `work-ver-smt2-fw64-B` and in the remote `di` suite. No RTL change. The historic OpenSBI `mepc=0` `sbi_hart_hang` path remains a separate residual if `fdt_next_tag` jumps to a non-execute address. |
| | **Linux boot greens to preserve (I4dp)** | P3 | `g6lc64_server_math_v` (NrHarts=2) and `g6lc64_ooo_server` (4×2 = **8 logical harts**) both reach harness `tohost = 0` at the 200M-cycle cap via the proxy on `ovh_calltorch`. 8-hart payload path: `corev_apu/bootrom/ariane-ooo-server.dts` + `G6LC_DTS`/`G6LC_DTB`/`G6LC_SMT2`/`OPENSBI_SRC` in `build-opensbi-smt2.sh`; `tohost` `0x80041730`. Harness tohost is **not** soft-ladder SUCCESS — classify from `runs/<tag>/run-*.log`, since a long `run` can return rc=255 on SSH drop. Any B1 candidate must keep both. |
| | Bisects **all negative** | P2 | Dual-commit; STQ-nofwd; force SI; ALU cancel-exempt — same pin; **reverted**. |
| | Directed (P1) | P1 | **5/5 green** FDT shape + `mini_fdt_next_tag_lbu` on fw64/slfix. |
| | **P2 RTL + TB** | P2 | **Landed through I4ay:** I4au cookie green; I4ax/y keep `lui t0`/`auipc t1` (did not fire). I4av/w rewind **reverted**. TB hangpc; **`work-ver-smt2-slfix`**. |
| | **Oracle discipline** | P2 | Pin md5 **`bc7ed11dab17454fd147e4927ba07fef`** (backup `*.pin-bc7ed11d.elf`). Held: rebuild with `rebuild_held_from_pin.sh` only — **do not** `mk_plat_skip` from current diag (`8169b747…` → cold-regress `plat_hc=80`). |
| | **Cookie chase I4f–g** | P2 | Cave OK. Stock: **`sbi_hart_init` CSR probes**. Soft-skip → platform **`c.jalr a5`** (irqchip@`17e0`→FDT). **Hold green:** `SOFT_HART_INIT`+plat peels → **`51b1babe`**. |
| | **Track hold** | P2 | **`hold` dual-confirm green** held `8b6b310e…` on slfix (`plat_hc=2` BANR). `mini_csr_expected_trap` + **`mini_csr_pmp_probe` PASS**. |
| **Next** | P1 | OpenSBI 7ba still Branch (hangj 766 is leftover jal **bp_valid**; TRACE n7b8@20431 then n7c0@20438 then n7ba@20440; later_br_01 MINI-FAIL FDT 23 @1184 G1iz class — do not re-land; sib8_fetch MINI-FAIL FDT hang @400000 G1jd class — do not re-land; hi8_npc_fetch MINI-FAIL lottery 4 @362 G1ja / FDT 57 @445 G1jd — do not re-land; lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 — do not re-land (jalr-target `[2:1]==11`); lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2 — do not re-land; ljx0_off / ljx0_pc / ljx0_bp hygiene; sib_lo_s2 MINI-FAIL lottery 2 @420 / FDT 50 @545 (G1jp) — do not re-land; lo_ld_stay HOLD-FAIL 51b1c001 — do not re-land; lo_ld_lo11 hygiene; hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd) — do not re-land; load_flush_next16 hygiene; ld_until_01 MINI-FAIL FDT 106 @409 (G1lm) — do not re-land; leftover_off_npc00 hygiene; leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — do not re-land; load00_vs_off16 hygiene; leftover_nx8_npc00 hygiene; leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — do not re-land; load00_vs_lj hygiene; leftover_lo8_s2 hygiene; load00_lo8_s2 hygiene; slfix `2db4dea7`/`f5f908e4`); idle_sib16 / idle_load_sib HOLD-FAIL 51b1c001 G1jw class — IDLE user[33] into G1hj closed; leftover_blocks_01 + G1hj consume-PC-match + is_mispredict spare + stash_keep16 + stash_keep_pc + load_flush_keep + plus2_stay + line_hi8_stay hygiene — G1hj never captures 7ba; slfix `55aa90c6`/`dad4695c` cookie t=83968). P3 @518 P4 @597. skip-range HOLD-FAIL. c.jalr skip-arm HOLD-FAIL. skip_next MINI-FAIL. Not G1mg. Not G1gn. Not G1iz/G1jh/later_br_01. Not G1jb. Not idle_sib16. Not idle_load_sib. Not sib8_fetch. Not hi8_npc_fetch. Not lo11_npc00. Not lo_pc_npc00. Capture 7ba bits from valid 7b0 16B sibling without IDLE user[33] and without rewriting leftover fetch. G1mf kept (SB result-valid 00 LOAD into g1lo; cookie t=83968; 7ba unchanged — last SB 00 LOAD is not 7b0, or 7b0 is not yet sbe.valid; slfix `64f6c38e` / `850ebd78`). G1mf kept. G1me kept. G1md kept. G1mc kept. G1mb kept. G1ma kept. G1lz kept. G1ly kept. G1lx kept. G1lw kept. G1lv kept. G1lu kept. G1lt kept. G1ls kept. G1lr kept. G1lq kept. G1lp kept. G1lo kept. G1ln kept. G1lm MINI-FAIL. G1ll kept. G1lk reverted. G1lj kept. G1li kept. G1lh kept. G1lg kept. G1lf kept. G1le kept. G1ld kept. G1lc kept. G1lb kept. G1la kept. G1kz kept. G1ky kept. G1kx kept. G1kw kept. G1kv kept. G1ku kept. G1kt kept. G1ks kept. G1kr kept. G1kq kept. G1kp kept. G1ko kept. G1kn kept. G1km kept. G1kl kept. G1kk kept. G1kj kept. G1ki HOLD-FAIL restored G1kh. G1jo keep (replay !kill_s1 at npc 00 fired; cookie t=83968). Fetch-steal at npc 01 closed (G1iz/G1jc/G1jg/G1jh). Sibling [31:16] any-stash closed (G1jj). IDLE sibling-pair into G1hj closed (G1jw). All-npc-00 kill_s2 closed (G1jp). npc-00 flush_i kill_s1 closed (G1jr/G1js). G1fx npc +2 all-compressed closed. G1lx/G1lw/G1lv/G1lu/G1lt/G1ls/G1lr/G1lq/G1lp/G1lo/G1ln/G1ll/G1lj/G1li/G1lh/G1lg/G1lf/G1le/G1ld/G1lc/G1lb/G1la/G1kz/G1ky/G1kx/G1kw/G1kv/G1ku/G1kt/G1ks/G1kr/G1kq/G1kp/G1ko/G1kn/G1km/G1kl/G1kk/G1kj/G1kh/G1kg/G1kf/G1ke/G1kd/G1kc/G1kb/G1ka/G1jz/G1jy/G1jx/G1jv/G1ju/G1jt/G1jq/G1jo/G1jn/G1jm/G1jl/G1jk/G1ji/G1jg/G1jc/G1jb/G1ix/G1iw/G1iu/G1it/G1ir/G1iq/G1ip/G1io/G1il/G1ik/G1ij/G1ii/G1ih/G1ie/G1id/G1ic/G1ib/G1ia/G1hz/G1hy/G1hx/G1hw/G1hv/G1ht/G1hs/G1hr/G1hq/G1hp/G1ho/G1hn/G1hm/G1hl/G1hk/G1hj/G1hi/G1hh/G1hg/G1hf/G1hd/G1hc/G1hb/G1ha/G1gy/G1gx/G1gw/G1gu/G1gs/G1gq/G1gp/G1gm/G1gl/G1gk/G1gj/G1gi/G1gh/G1gg/G1ge/G1gd kept. Do not re-land G1ew/G1es/G1eo/G1eh/G1ec/G1eb/G1dr/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/G1lk/G1lm/lo11_npc00/+8 hold. Do not lower `SMT_COLD_EXCL`. Soft getprop stays. Not G0/W1/G6/G1i/G1z/G1aa/G1ab/G1ac/G1af/G1aj/G1ak/G1ap/G1as/G1at/G1ax/G1bb/G1bd/G1bi/G1bk/G1bn/G1bo/G1bq/G1br/G1bs/G1bt/G1bu/G1bw/G1by/G1bz/G1cd/G1ce/G1cf/G1cg/G1ch/G1cj/G1ck/G1cl/G1cn/G1co/G1cu/G1db/G1dg/G1dr/G1dw/G1dy/G1eb/G1ec/G1eh/G1eo/G1es/G1ew/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/G1lk/G1lm. **Do not start I4cg.** Do not land D$ fill. |
| | Priors | | g1gi–gm peel `7e280d82` / `a0d82504` · jal-x0 squash `cb3802ff` / `72829707` · leftover slfix `7af3e3c8` / `2707526e` · E9 `e396f136` / `47c636b1` · E4 FE `9aa3360c` / `8fe2d083` · E4 `8d0ee26d` / `27221419` · E8 `e87ba20c` / `e673a237` · E7 `c162608c` / `b7faf8e8` · E6 `6f90de0f` / `4412d136` · G1mf slfix `64f6c38e` / `850ebd78` · G1me `dce70345` / `b810edbb` · G1md `5f743837` / `656c7884` · G1mc `9b9e0aa0` / `1af85acb` · G1mb `ff2c6aaf` / `049e7041` · G1ma `99feee68` / `6cb66364` · G1lz `24bca058` / `d9bb33dd` · G1ly `672f5c89` / `2e9c569b` · G1lx `76330b85` / `0ed5c1eb` · G1lw `e16fd998` / `8b0e7f35` · G1lv `9de0cf5c` / `2c5b0389` · G1lu `ba656512` / `7e270547` · G1lt `0c7273bb` / `720bd125` · G1ls `28430b85` / `c6ecb315` · G1lr `e8df2ac5` / `aac00289` · G1lq `64cd8bd2` / `edde23b1` · G1lp `6f9629d0` / `8417ade6` · G1lo `7aa89110` / `80c2a735` · G1ln `f7f9b8b0` / `e15f1291` · G1ll `93a79414` / `cb4dc600` (G1lm reverted) · G1lj `673cd1d8` / `cf66549f` (G1lk reverted) · pin `bc7ed11d` |
| **SL-W** | **D$ ACK-before-check — general fix for the L1-stale class** | P2 / S1 | **Queue RTL landed; default disabled (`WtDcacheFixupDepth=0`), PMU wired, full-queue wbuffer hold in place.** Post-ACK fixup queue lives in `wt_dcache_wbuffer.sv` (parameterized by `CVA6Cfg.WtDcacheFixupDepth`), explicit `inv_req_o`/`inv_ack_i` port through `wt_dcache`→`wt_dcache_mem`, shared tag-read and word-write port priority `check_wr > fixup retire > ACK writeback`, refill ordering via `wr_cl_vld_d/q`, full-queue bypass/invalidate fallback, and `VoidKeepEn`/`VoidKeepTag` containment preserved for depth=0. PMU events `DCACHE_WBUF_VOID_ACK/FIXUP_WRITE/FIXUP_INVAL/FIXUP_FULL` wired to `perf_counters.sv` group 5 (`MHPMGrpSLW`). Core lint PASS (imafdc 265 / cv32a65x 58 warnings); smt2 lint (optional) clean with `WtDcacheFixupDepth=2` and `WtDcacheFixupVoidKeepEn=0` except the two pre-existing Verilator internal `Different default drivers` on `we_gpr_commit_id`. Still open: proxy evidence that the full-queue hold does not re-enter the FDT forward-progress hang; gate-6 is the first proxy build with `WtDcacheFixupDepth>0` and `WtDcacheFixupVoidKeepEn=0`. Local WSL Verilator build (5.020) hits an internal fault after duplicate-module warnings, not an RTL error — this is the Debian 5.020 behavior the Makefile already warns about; a pinned 5.008 build or the remote proxy is needed. The S1 pin class is `wt_dcache_wbuffer` freeing a TX on a write ACK that races its own tag check: the clean bytes never reach the L1 data array, a stale way survives, and a later load reads pre-store data (`s1-tight-hold-trace`: `g1ao_hold` dead, DRAM=`lenp`, 2nd `ld s3` retires `0x12b2a`). Kept containment is `nackinv` + a **workload-scoped** VOID-keep window, now named `VoidKeepEn` / `VoidKeepTag` in `wt_dcache_wbuffer.sv` (header note 3 + declaration; bit-identical rename, `VoidKeepEn=0` restores stock upstream ACK handling — **no re-soak needed**). Every address-agnostic variant is logged **reverted**: `ackinv`, `voidchk2`, `keep`/`keepv`/`keep1..7`/`keepnz`/`keepcoal`/`keeppend`, `snoopd*`, `wr1`, `nackhit*`, `nack2*`. **Micro-arch note landed:** [`architecture/dcache-ack-before-check.md`](architecture/dcache-ack-before-check.md) — it classifies every logged tag by *which* mode it broke, names the one untried design axis (a **post-ACK L1 fixup queue** owning no write-buffer state, ordered against refill, falling back to *invalidate* when full so correctness stops depending on queue capacity), records why capacity/TTL sweeps cannot work, and adds **gate 6: pin + hold still green with `VoidKeepEn = 0`** as the test that a fix is general. The split it turns on — **(a) staleness**, an ACK'd-but-unchecked word must either land in L1 or invalidate that line; **(b) forward progress**, holding words keeps `txblock`/`valid` set and starves `wr_ack` / `empty_o`, which is what hangs h0 in the FDT_PROP walk (`s1-h0-keep-hang-trace`: not an LSU stall, `nextoff=0` walk never ends). A fix must close (a) without re-entering (b); note also that (a) is a **write-through coherence** defect that outlives this firmware. **Gates (proxy-only):** pin `bc7ed11d` cookie `51b1babe`, hold `8b6b310e` cookie + BANR, `mini_fdt_*` battery, and I4dp `_v` + `ooo_server` 200M `tohost=0`. Do **not** widen the window as a substitute (0x80040–0x80045 already reverted). Priors: `linux-boot-scale.md` S1 · `wt_dcache_wbuffer.sv` note 3. |
| **SL-R** | **Fetch-plane compartmentalization** | P6 / cleanup | **Duplicate drop landed.** `core/fetch_B/` carried 16 uncompiled predictor copies (`bht`, `bht2lvl`, `btb`, `ras`, `g6lc_bp_*`, `g6lc_ftq`, `g6lc_fdip`, `g6lc_loop_buffer`; 2043 L) on no flist, no script and no `REUSE.toml` entry — byte-identical to the compiled `core/frontend` copies apart from CRLF and mojibake in 6 of them, i.e. a silent "edited the wrong copy" trap. Removed; the directory is now exactly the six `Flist.fetch_B` files (**2364 L**). Mirrors the earlier `core/smt/` drop; all five flists re-checked to resolve. **Landed (1):** `fetch_geo_t` / `geo()` now drives the synthesized supply (`frontend.sv`, `instr_realign.sv`, `instr_queue.sv`) and `g6lc_fetch_dbg.sv` as a bit-identical localparam substitution. Added `log2_slots` and `hart_idx_w` to `fetch_geo_t` so `IdxW` and `HidW` share the same source. `VALUES.md` §3 updated. Build-platform `diag run {core,smt2,residual,ooo,apu}` PASS path/cap checks; Verilator lint skipped (`verilator` not installed locally). Ungated until `tools install sim` or proxy. **Open (2):** the L1–L4 extract into `g6lc_fetch_{align,window,order,redirect}` stays **gated behind the R4 pin** (`SPEC.md` §8, `core-fetch/README.md` status) — do not start it while S1 is open. Priors: `core-fetch/{README,SPEC,VALUES}.md` · `Flist.fetch_B`. |
| **SL-B** | Peel soft getprop + real printf | P3–P4 | **Pin printf dual-confirm.** Getprop natural. Pin peel-printf `39b9dcc2` + plat-ops `7d670268` cookie **`51b1babe`+`51b1d000` t=131072**. Hart-only leftover-RVI `@12ad8` (FDT_PROP `addi@12ad6` straddle; `a0=0x82200638`). BANR + `SOFT_HART_INIT` stay on held `8b6b310e`. Do not replace pin/held. |
| **SL-C** | Topology truth (smt2) | P6 / topology |
|| **SL-X** | **SMT2 product closeout / FDT compensation** | P6 | **Open.** Cookie green (SL-A/B/C) is a gate, not product completeness. Track and retire: `SMT_COLD_EXCL`/`SMT_FIRST_ACT_EXCL`, dual-commit same cycle, banked BHT/BTB, FP/vector register banking, idle-thread clock gate, `Zawrs`/wait-for-peer, `SMT2` default SKU, and FDT `smt,*` compensation properties. Central checklist: `architecture/multi-threading/smt2-product-closeout.md`. **FDT compensation retired (landed).** The `smt,*` node is now documentation only; enforcement moved from firmware run time to DTB build time in `software/smt2-linux/scripts/dts_to_dtb.py` (`CLOSEOUT_ISA_TOKENS`; fails the DTB build if a `cpu@` advertises a closed-out token, `--strip-closeout` to mutate a temp DTS instead, `--no-closeout-check` to skip). Deleted `scripts/patch_opensbi_smt_compensation.py`, dropped its call from `build-opensbi-smt2.{sh,ps1}`, and restored vendored `platform/generic/platform.c` to stock (147 inserted lines removed; only the `patch_opensbi_g6lc_clint.py` CLINT/PLIC edits remain). Three reasons: (1) **dead** — `ariane-smt2.dts` never advertised `zawrs`; (2) **actively broken** — the rewriter called `sbi_malloc()` from `fw_platform_init()` (`fw_base.S:115`), ~250 instructions before `sbi_init`→`sbi_heap_init` (`fw_base.S:367`), so `hpctrl` was zeroed BSS and `sbi_list_for_each_entry` dereferenced `NULL+0x18` → `fault_load mtval=0x18` → `_start_hang`; this was the OpenSBI-on-QEMU hang; (3) **cost a source-anchor fork** of upstream. Also corrected the `smt,zawrs` semantics: `core/decoder.sv:315-334` **does** decode `WRS.NTO`/`WRS.STO` under `ZawrsEn` and retires them as `WFI` (conforming — Zawrs lets `WRS` terminate for any reason); what is open is only the SMT wait-for-peer wake plus the "no `sbi_send_ipi_and_wait`" firmware policy. **Residual conform item:** the B1 generated DTB derives `zawrs` from `ZawrsEn=1` and so advertises it, while the handwritten `ariane-smt2.dts` conservatively omits it — reconcile via `g6q conform` capability `wait-on-reservation`, do not paper over it. | **Side `ipi-tab` dual-confirm** `3314827d`: cookie **`51b1babe`+`51b1d000`** and **`sp1=0x80045f10`** (`s3-ipi-tab6`/`6b`). In-line MSIP after cookie `sw`. Pin/hold still babe `sp1=0` (no MSIP). Not VOID-keep widen. Not G1dg. Do not replace pin/held. |
| **S4** | `_v` Image / I4dp hygiene | P6 | **R3b SKIP**. Execute-uncached + BHT + **FtqDepth=0** + **RAS=16** + **`bp_fire&&cf_consumed`** + **same_win `bp_pend` misp-retarget** (ttl=7). L2 **`live[]`** + **`slot_keep_link`**. fetch_B IQ **DEPTH=8**. **`leftover_retake`**. **leftover-complete slot0 push** (I7 exception; hygiene PASS including osbi). **`replay_addr = icache_vaddr_q`** (rest PC on slot0 push). **Leftover jal Jump (G1do B)**. **`leftover_update` kill_s1**. fetch_dbg **contiguous-run** SVA. **12c56 IAF closed.** **12958 illegal closed.** 8M: **`plat_hc=4` `coldboot_done=1`**. WFI `@eef4` is **`sbi_hart_hang` after `sbi_trap_redirect` failed (-2)**; mtvec t=2456818 ra=`12994` **mepc=0** (fetch/jump to 0, cause>11). Bare TB has a bootrom at 0, so the exact `mepc=0` class is reproduced via `soft-ladder-opensbi-soak.sh` with `PEEL_FDT_NEXT_TAG=1` (natural `fdt_next_tag` hangs without `0x51b1babe`). Directed mini `verif/tests/custom/multicore/mini_fdt_nt_ptr0` reproduces the same fetch_B/IQ leftover with `tohost=122928` (`mepc` lower 32 = `0x1E030`, `ra=0x80012994`) on the stale `work-ver-smt2-fw64-B` binary (2026-08-25). A fresh rebuild (`work-ver-smt2-fw64`, Verilator 5.008) from current source with the stock `common/link_verilator.ld` appeared to pass `mini_fdt_nt_ptr0` (`tohost=0`), but that ELF does not place `offset_ptr`, the `c.jr a0` and the FDT at the S4 fixed VAs and therefore does not exercise the residual. Re-linking with `verif/tests/custom/multicore/mini_fdt_nt_ptr0.ld` (the intended S4 layout) on the same fresh binary (`work-ver-smt2-fw64-B`, byte-identical to `work-ver-smt2-fw64`) still fails with `tohost=122928`. The S4 `c.jr a0`/`fdt_offset_ptr` residual is therefore **reproducible on current source**, and the stale-binary caveat is removed. OpenSBI `PEEL_FDT_NEXT_TAG=1` on the fresh build still `CLASSIFY=FAIL`, hanging at `npc0=0x80004a50` (`plat_hc=80`, `coldboot_done=0`, ~1M cy) rather than the historical `mepc=0`; the jump-to-0 class may have shifted or the mini catches a narrower form of the same FDT-walk/redirect issue. leftover_drop hold **MINI-FAIL**. leftover_drop replay_addr **SIGSEGV**. pipe_keep **MINI-FAIL**. leftover_replay_hold **MINI-FAIL**. stale_ret_ok **SIGSEGV**. redirect_pend take **MINI-FAIL**. Not G1aa. Not I4v. Pin `bc7ed11d` kept. Landed `d05660170`. |
| **SL-D** | Stream plane vs SMT | P6 | Orthogonal stream8 (`N=2,T=1,I=1`); recover layer 2 off. Do not merge with smt2 DI until FDT trusted. Stream I=2 / RVV / H: `CONTRACT.md` §6 (Phase 4b; AI-2; §6.5 `RVH` on smt2 is package+DTS+H-edge, not G1\*). |
| **SL-E** | Optional DTS generator | later | Third topology / N>2 stream forces generator (`CONTRACT.md` §8.3). All-feature + `NrCores` scale: union soak per named envelope, not G1\* re-read. |
| **SL-F** | **Fetch_B unaligned I$ data alignment** | P2 | **Proxy build done; fix does not fully resolve residual.** The pre-shift removal was reverted to the original `frontend.sv` pre-shift contract; the fetch `leftover_branch_bp_fire` is the landed fetch_B change. Remote B-harness (`work-ver-smt2-fw64-B`, 12-thread, Verilator 5.008) builds clean and DI is 12/16 best pass but flaky; the remaining failures are not a fetch pre-shift issue. Trace of `mini_fdt_next_tag_lbu` points to a **scoreboard/issue/branch ordering** problem around `c.addi16sp` + `c.sdsp`/`c.ldsp`/`c.jr` at 2-byte aligned function boundaries. OpenSBI `PEEL_FDT_GETPROP=1 PEEL_FDT_NEXT_TAG=1` still fails at `npc0≈0x800138a8`. See `architecture/multi-threading/soft-ladder/b1-rtl-residuals.md` §Fetch_B unaligned I$ data alignment. |
| **SL-T** | **SMT2 × ai-tensor / PyTorch** | parallel + after SL-C | **Active on `smt2-ai-tensor-linux`.** Driver: `smt2-ai-tensor-track.sh` (`fast`→`di`→`hold`→`peel`→`dual`→`tensor`→`mt-soft`→`hard`). T4 soft pytorch **green**. T5 dual workers need SL-C + Image. AI CSR banked. Map: `smt2-ai-tensor-linux.md`. |

Soft-ladder SUCCESS = trapdump **`51b1babe` only** (not harness tohost SUCCESS) — suite metadata.  
Harness preference: **`work-ver-smt2-slfix`** (iter-013 / S4) for hold/cookie; `fw64` is PEEL-pin reference only.  
Oracle: `SOFT_LADDER_SKIP_BUILD=1`; pin md5 **`bc7ed11dab17454fd147e4927ba07fef`**. Holding cookie: `SOFT_LADDER_ELF=software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf` or rebuild with `SOFT_HART_INIT=1`.

### 2026-08-31 bootrom / DI validation residual

- Fixed `core/cache_subsystem/g6lc_icache.sv` active-region non-convergence: use registered `vaddr_q` for cache index, MMU/PMP request, and I$ response address; remove same-cycle `dreq_o.ready` from the `READ` hit path; gate hit/refill output with `kill_s1` instead of `kill_s2` to break the `vaddr_d → cl_index → cl_hit → dreq_o.ready → vaddr_d` combinational loop through `frontend.fetch_address`/`kill_s2`/`spec_req`. Added `boot_addr_i` input and reset `vaddr_q` to it. B flavour builds on `ovh_calltorch` with **0 warnings / 0 errors**.
- Fixed `corev_apu/bootrom/gen_rom.py` packed-array word order and regenerated `bootrom.S` with extra nops and a `fence` before `jr s0` to separate dependent `slli`/`jr` and drain the pipeline. `soft-ladder-build-harness.sh` regenerates the bootrom before Verilation.
- Rebuilt `work-ver-smt2-fw64-B` (B flavour) clean on `ovh_calltorch`.
- Implemented a `commit_stage.sv` FDT-compensation filter for `x8`/`x1`/`x10` unaligned/page-0 ALU writes (`G1lc/I4as/I4cc`) so the bootrom `li s0,1; slli s0,1,31` now produces the `0x80000000` jump target; bootrom `jr s0` now reaches DRAM `_start` (`npc0=0x80000000`) for both DI and OpenSBI images.
- OpenSBI soak (`fw_payload_r3a_c15_plat_skip.elf`) still **CLASSIFY=FAIL**, but the failure signature has moved: the bootrom completes and OpenSBI runs until `mepc0=0x8000a9a8`, `mcause0=0x2`, `mtval0=0x693af0f`, `wfi0=1`, not the earlier `npc0=0x1004c` `_hang` at `wfi`. This points to a residual in the SMT2 issue/RF/forwarding or commit path after the bootrom, not a pure bootrom stall. Same symptom reproduced on `work-ver-smt2-slfix` and `work-ver-smt2-fw64-legacy`.
- Remote DI suite now runs through `verif/regress/remote/testharness_proxy.py di` in **consecutive single-worker mode** with a pre-flight `_no_overlap_guard`: it refuses to start if any `Variane_testharness` or `soft-ladder` process is already running on the remote host. Overlapping DI runs are the root cause of flakiness seen earlier (e.g. `mini_fdt_lenp_sw` failing only when two harnesses ran concurrently).
- **Methodology turn (2026-08-31, second pass).** The three reasoning documents —
  [`AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md) (foundation),
  [`AGENTS-g6lc-opensbi-dev-heuristics.md`](architecture/AGENTS-g6lc-opensbi-dev-heuristics.md) (method) and
  [`AGENTS-smt2-opensbi-dev-logics.md`](architecture/multi-threading/AGENTS-smt2-opensbi-dev-logics.md) (instance) —
  name the previous pass's own changes as the live failure instance (workflow §9.2, heuristics H6 retrospective).
  Acted on rather than argued with. Work moved **left** on the feedback-latency ladder (L6/L7 → L0/L1/L2/L3)
  and the two red lines were reverted:
  - **Reverted `core/commit_stage.sv` commit value filter** (§E "drop `x8` unless 8-byte aligned; drop `x1` if
    result < 4 KiB"). It took a control decision from a data value (visibility **channel 5**) and was not
    expressible over any closed tuple — the tell that it was a filter, not a contract. The `SuperscalarEn &&
    NrHarts>1` gate did not launder it (P5: identity is necessary, not sufficient).
  - **Reverted the cancelled-writeback forces** on both commit ports (§E "force GPR write for cancelled
    CTRL_FLOW/LOAD", `G1s`/`G1an`) — a squashed operation performing an architectural write is **channel 1**.
  - **Kept** one Zacas port-ownership guard, re-anchored from `SuperscalarEn && NrHarts>1` onto `RVZacas`,
    the parameter that actually explains it (I28), and restated without a register number.
  - **Reverted `corev_apu/bootrom/bootrom.S`** to the stock sequence (`li s0,1; slli; csrr; la; jr s0`).
    Both the `addi s0, x0, 1` rewrite and the `nop`×5 + `fence` pipeline-drain padding were firmware edited to
    accommodate RTL (P1 inverted). The bootrom is our own code, which is what made the edit feel free.
  - **New L1 check:** `CVA6_MAX_SW_HARTS=8` + `assert (NrCores * NrHarts <= CVA6_MAX_SW_HARTS)` in
    `config_pkg`. The factors were bounded separately while the PLIC context budget scales with the *product*,
    so `NrCores=8, NrHarts=2` elaborated cleanly and would only fail when the wrong CPU took an interrupt under
    Linux. All in-tree packages pass (`ooo_server` is exactly 8).
  - **New L2 rung:** `core/fetch_B/formal/` (`align` I3/I5, `order` I2/I7, `redirect` I8) over the pure functions
    already in `g6lc_fetch_pkg`, mirroring `core/ooo/formal/`; wired into `verify.formalTasks` +
    `diag-fetch-formal-paths`.
  - **Red lines mechanized:** new `source-scan` diagnostic kind + `diag-isa-red-lines` / `diag-fw-accommodation`,
    both in the default `core` compartment. Self-tested against a five-violation fixture (5/5 fired, then clean).
    Pre-existing debt is **waived with a note and counted**, not hidden — 20 recorded entries today.
  - **Oracle controls:** `mini_must_pass` / `mini_must_fail` preflight the DI suite in both the shell runner and
    the proxy; a wrong answer in either direction aborts the run before any test.
  - **Hatch ledger:** `soft-ladder/inventory.yaml` gains the H7 `hatches:` schema, a repayment schedule, and the
    seven artifacts that repaid this pass.
- **Third pass — L3 layer contracts (M4) and the R11 hart-count contract.**
  - **M4 landed.** `core/fetch_B/g6lc_fetch_dbg.sv` is bound into `frontend` and already asserted I1/I2/I7-partial,
    but the bind omitted the realigner's carry state, so I3/I5 could not be checked at all. Added
    `leftover_valid_i` / `leftover_pc_i` / `leftover_lo_i` (the halfword observed hierarchically as
    `i_instr_realign.carry_instr_q`, so the synthesizable port list is unchanged for a `translate_off` check) and
    five assertions on the **emission**: slot0's PC is the carried PC, slot0's low half is un-rewritten (I2), and
    the completed slot0 is RVI with `ilen==4` (I5). The *enable* conditions are deliberately not re-checked here —
    the realigner builds them from the same `g6lc_fetch_pkg` functions the new L2 formal proves, so asserting them
    at this tap would be a tautology. **OpenSBI anchor:** `include/sbi/sbi_csr_detect.h:17` arms mtvec and executes
    a possibly-illegal `csrr`, and `lib/sbi/sbi_expected_trap.S:23` advances `mepc` by a **fixed 4** — sound only
    because `csrr` is always 4-byte RVI. A completion that emits a 16-bit fragment at the probe address turns a
    legal probe into an illegal instruction *and* mis-advances `mepc` (the R3(c) obligation), and would otherwise
    surface ~10M cycles later as an unrelated hang.
  - **I23 bound observed, not enforced.** `hold_age_q` was computed and only printed; it now `$warning`s once per
    run when it exceeds `geo.hold_max`. Deliberately a warning and deliberately latched: silently releasing a hold
    is itself a recorded negative (`NEGATIVE.md` §1, unbounded vs early lift), and an assertion that fires every
    cycle is noise rather than blame locality.
  - **R11 / I25 pushed to build time.** `software/smt2-linux/scripts/dts_to_dtb.py` now enforces that the number of
    `cpu@` nodes **OpenSBI would actually count** equals `NrCores × NrHarts` of the owning config package. The three
    counting conditions mirror `platform/generic/platform.c:172-184` exactly (parseable `reg`; `hartid <
    SBI_HARTMASK_MAX_BITS` = 128 per `include/sbi/sbi_hartmask.h:23`; enabled per `lib/utils/fdt/fdt_helper.c:245`,
    i.e. `status` absent or beginning `okay`/`ok`). `platform.hart_count` is the FDT walk's only durable output, so
    a mismatch is never diagnosed by firmware — it appears as a hart that never leaves the HSM wait or an interrupt
    delivered to a context that does not exist. New `DTS_CONFIG_PKG` pairing table, `--expect-harts`,
    `--config-pkg`, `--no-hart-count-check`, and a standalone `--check-all-harts` sweep.
  - **Defect found by that check, reported not changed:** `corev_apu/bootrom/ariane-ai.dts` advertises **one**
    countable `cpu@` (and its CLINT `interrupts-extended` references only `CPU0_intc`) while
    `core/include/g6lc64_ai_config_pkg.sv` sets `NrCores=2`, i.e. **S=2**. OpenSBI would set `plat_hc=1` and core 1
    would never be started. Resolution is an owner decision — either add the second `cpu@`/intc and its CLINT+PLIC
    contexts, or drop the AI package to `NrCores=1` — so it is recorded rather than unilaterally patched. The other
    five mapped DTS/package pairs agree (`ariane.dts` 1, `smt2` 2, `stream8` 2, `server_math_v` 4, `ooo_server` 8).
- Corrected the proxy and the local `soft-ladder-di-regress.sh` pass detection: a DI test only passes when the harness log shows `tohost = 1` (or `tohost = 0x1`). The previous logic treated the harness `*** SUCCESS *** (tohost = 0)` timeout as a pass, which inflated the 15/16 and 16/16 reports. **T9 (invalidate backwards) applies:** every DI count recorded before this fix came from the old classifier and is not comparable — re-measure or annotate before citing, especially where one was used to *eliminate* a hypothesis. With the corrected detection, the full consecutive DI suite is currently **0/16 PASS**:
  - `mini_amoadd_w_spin`, `mini_csr_expected_trap`, `mini_csr_pmp_probe`, `mini_dual_cmv_s3`, `mini_fdt_s2_nest`, `mini_fdt_check_prop_nest`, `mini_fdt_next_tag_lbu`, `mini_fdt_a0_is_fdt`, `mini_stq_flush_fwd`, `mini_fdt_namelen_walk`, `mini_fdt_nt_frame32`, `mini_fdt_nt_stock`, `mini_fdt_nt_cpus`, `mini_stq_alias_jal`, `mini_fdt_nt_osbi` all time out with `tohost = 0` (or hang at the bootrom `_hang`/`0x0` fetch loop).
  - `mini_fdt_lenp_sw` reaches its `fail:` path and the `rvfi_tracer` terminates the simulation (`rc=1`, `tohost=0`).
- The bootrom `s0` symptom that motivated the filter is **unexplained, not fixed**: with the accommodation in place the B harness still stalled with `npc=0x10000` and `s0=0x0` for 64+ cycles, and legacy/slfix showed the same. That is H4 territory — the symptom was never made deterministic, so the three successive attributions to it are unfalsifiable and none is recorded as a conclusion.
- Next (ordered by ladder position, not by symptom):
  0. **Grow the battery along the axis the firmware supplies (T4).** M5 shows the residual's defining co-factor — a
     live peer hart — is present in 5 of 113 minis. Before any further attribution, add live-peer variants for the
     W1 minis that already pin the class single-hart, and one `W5 × thread-select` mini
     (`lib/sbi/sbi_init.c:196` `wait_for_coldboot`: peer spins on `__smp_load_acquire` until the boot hart
     releases). A mini that passes eliminates a shape, never a class.
  1. **H4 determinism before attribution.** Establish whether the bootrom `npc=0x10000` / `s0=0` stall is stable across three runs at `verilator --threads=1` with the observer binds off. If the outcome depends on simulator scheduling, the race/X *is* the bug and it outranks any functional hypothesis. Do not attribute until it is stable.
  2. **T2 promise location, not component.** With a stable symptom, name the first false promise on `I$ → realign → IQ → issue → EX → commit`, and instrument *that* boundary. `g6lc_fetch_dbg` already asserts I1 (bytes==memory); I3/I5/I7 have no boundary SVA yet (M4).
  3. **Run the new formal first.** `verify --formal` now covers I2/I3/I5/I7/I8. A counterexample there is seconds and names the tuple; it is strictly cheaper than any harness run and must be exhausted before a soak.
  4. Only then the OpenSBI residual (`mepc0=0x8000a9a8`, `mcause0=0x2`) — as a **gate**, not a search signal.
- Deliberately **not** doing: another peel, another hold-ELF cycle, or another TRACE hunt for this class. H7 blocks a second unrepaid use, and the repayments for this class landed above.
- **M5 landed, and its result reframes the residual.** `verif/tests/custom/multicore/ARCHETYPES.yaml` classifies all
  113 minis (+2 controls) by archetype W1–W7, owning layer, invariants, and the co-factors each actually supplies;
  the matrix and a real/structural verdict for all 64 empty cells are in
  [`soft-ladder/README.md`](architecture/multi-threading/soft-ladder/README.md) §"Archetype x layer coverage (M5)".
  Counts are of **existence, not passing** (H3/T9). Three findings that matter more than the counts:
  1. **Cross-hart is essentially untested.** Only **5 of 113** minis run a live peer hart
     (`mini_fetch_straddle`, `mini_fdt_ro_probe`, `mini_fdt_nt_osbi`, `mini_stq_press_smt`, `mini_ipi_hart1_sp`);
     the other 60 hart-aware minis merely *park* `mhartid!=0`. W5 (release/acquire) has one mini total and it is
     single-hart, so `W5 × thread-select` — R2′'s own stated Home — is **empty**. This is P2/T4 exactly: the SMT2
     residual is a `T=2` property, and the battery samples the `T=1` face of the cube. It also explains why a
     green DI suite has never predicted the firmware outcome.
  2. **`W3 × L4-redirect` is empty** although `R3 ≡ R5` makes redirect one of the *two* real capability gaps.
     Nothing pins I11/I19 for a function-pointer table (`include/sbi/sbi_platform.h:265` is `if (ops->f) return
     ops->f(...)` for every service).
  3. **`W2 × L1-align` and `W2 × issue` are empty**, and both are named verbatim in R3: no mini places a CSR probe
     at a straddling address (clause c — the blind `mepc += 4`), and no mini owns "`csrrw mtvec` must not
     dual-issue with the CSR it is arming" (clause d, `stall_csr_older`). The whole `csr` layer column is zero.
  Distribution is also lopsided: `W1 × LSU` (68) and `W6 × amo` (16) hold 84 of the 106 classified minis.
  Lower-confidence classifications are flagged per-entry in the YAML (`mini_hpd_*` W1-vs-W3 ~70%; the 68 `W1 × LSU`
  homes ~75%, resolved via the blame router's data signature since R4's Home is explicitly ambiguous).
- Migration items from the heuristics §5 table: **M1–M6 are now landed.** M7 ("capability work resumes on proven ground") is the state this reaches, not a task. Open follow-ups it exposes, in ladder order:
  1. `ariane-ai.dts` vs `g6lc64_ai_config_pkg.sv` hart-count mismatch (above) — an owner decision, and the first real defect the new L1 checks caught.
  2. `core/scoreboard.sv` still consults the A-path `g6lc_sb_keep` list; waived-with-note in `diag-isa-red-lines`. Owed artifact is a squash-window contract at the EX→commit boundary.
  3. ~~The `.sby` files are unrun on this host~~ **Discharged.** All three fetch proofs **PASS by k-induction**, and `verify --formal` is **7/7** including the four `core/ooo` tasks. What it took, and what is now landed in the build platform:
     - **Distro Yosys is unusable for this repo.** Ubuntu 24.04 ships 0.33, whose classic frontend rejects `ai_cfg_t'(0)` in `config_pkg.sv` (`TOK_USER_TYPE`) and also rejects package-to-package `import`. The fix is not to edit `config_pkg` to suit a tool — it is a real SystemVerilog frontend. sv-elab/slang is **integrated into Yosys from v0.67**, so no plugin is needed; `core/ooo/formal/g6lc_ooo_rob.sby` had a stale `plugin -i slang` line that is now a hard error, and it was removed.
     - **Engine choice dominates.** `g6lc_fetch_order` is **0.27s** under `abc pdr` and **does not converge in 240s** under `smtbmc z3`. All three `.sby` now race both engines. Separately, a 32-bit free `n` in the order props made the solver reason over 2^32 loop bounds; narrowing it to 4 bits is the real fix (the tuple is the port list).
     - **The props were stateless**, so `initial assume (!rst_ni)` was both dead weight and rejected by slang. Removed.
     - **Build platform now provisions this**: `tools install formal` source-builds Yosys+SymbiYosys (`build-platform/scripts/install-formal.sh`, CMake/Ninja, `-j` cores) into `workspace/tooling/formal`, adopting an existing install when it already has `read_slang`. Windows delegates to WSL via the new `platform/wsl.ts`, matching the Spike pattern. `eda.ts` resolves oss-cad → managed → PATH, decides integrated-vs-plugin slang from the artifact rather than the suite name, and runs tasks concurrently (`--formal-jobs`, `--formal-tasks`).
     - **Do not run solvers with their workdir on `/mnt`.** DrvFs is slow for the many small files sby writes, and an 8-core build plus a solver crashed the WSL VM repeatedly. `verify.formal.workdirRoot` exists for this, and the WSL path uses a `$HOME` workdir.
     - Oracle checked in both directions (H3 applied to the gate itself): injecting one false property makes the gate report 1/7 failed; removing it returns 7/7.
  4. `core/ooo/formal/g6lc_ooo_{rename,cancel}` pass on the Windows OSS CAD suite but were never observed to complete under the WSL build — same z3-slowness class as the order proof. If they ever stall in CI, add `abc bmc3` to their engine list before touching the props.
  5. **SMT fetch contracts proven (gate now 8/8).** `core/fetch_B/formal/g6lc_fetch_smt.sby` proves the three multi-threading contracts that SPEC §4/§5 state in prose and that each have a recorded failure behind them: **R1/I4** `packet_hart` (a switch must not retag an in-flight packet as the incoming hart — a parked hart legitimately runs with `sp==0`, so mislabelled provenance is indistinguishable from "not ready yet"); **I8** `commit_for_hart` (TRACE t=200082 had `src=4` reseeding fetch with hart0's target while `h=1`, stealing hart1's bootrom `jr s0`); **I10** `snap_pc` (bank the address the I$ accepted, not the fetch-ahead `npc`). `en_restore`/`en_smt` are **free inputs**, so one run proves the T=1 and T>1 envelopes together.
  6. **Envelope collapse landed.** The order proof now runs at the geometry ceiling `N=8` instead of a package's `N=4`. A narrower `INSTR_PER_FETCH` is the same proof with upper slot inputs tied off, and tying an input off can only remove counterexamples — so `FW=32/64/128` are covered by one run. This is the `C` factor of the width ledger going to 1: raising `geo.issue`, `geo.harts` or `FETCH_WIDTH` becomes a re-run in seconds, not a re-soak in hours. Do not specialise a proof down to a package geometry; that weakens it.
  7a. **Two existing ooo proofs were silently VACUOUS.** `g6lc_ooo_{freelist,rename}.sby` used the classic
     `read -formal` frontend while their properties reference DUT state hierarchically (`dut.free_q`,
     `dut.busy_q`, `dut.ckpt_ptr_q`, `dut.map_q`). The classic frontend cannot resolve a cross-module
     reference: it silently declared wires *literally named* `dut.free_q`, warned "implicitly declared" and
     "used but has no driver", and left five assertions checking dangling nets instead of the design — while
     reporting PASS. This is the H3 class applied to formal: **a pass that is not evidence.** Both are now on
     `read_slang`, which resolves the references or errors, and both pass with **zero** dangling-wire warnings,
     so the assertions are real for the first time. `g6lc_ooo_cancel` has no hierarchical refs and was
     unaffected; `g6lc_ooo_rob` already used `read_slang`. Lesson worth keeping: **any proof that reaches into
     a DUT must use `read_slang`**, never `read -formal`.
  7b. **Remote formal landed, and it is the fast path.** `verify --formal --formal-remote` runs the whole
     suite in one remote shell on the builder — **10 tasks in ~11 s** on 12 cores. Engine choice mattered more
     than the host: adding `abc` alongside z3 took the suite from 128 s (with two z3-bound tasks dying on
     `BrokenPipeError`) to 11 s. Details and the four traps in `build-platform/AGENTS.md` §4.6.2b.
  7c. **Two proof shapes worth reusing.** (a) *Live module over pure function* — when a rule quantifies over
     module state or over the I$ line, instantiate the real module (as `core/ooo/formal` already did) instead of
     concluding the rule is not L2-expressible. That closed I1/I2/I4, which SPEC §10 had wrongly recorded as
     "L3 is leftmost feasible". (b) **Self-composition for non-interference** — a rule of the form "X must not
     depend on Y" cannot be witnessed by any single execution. Run two copies, vary only Y, assert the
     observable agrees. That is how I6 is proven, and it is the right shape for **every** ISA red line in
     `firmware-boot-principles.md` §E, which are all "must not decide from a value" claims. Today those are
     policed by a `source-scan` tripwire (`diag-isa-red-lines`); a self-composition proof would make them
     properties instead of greps.
  7. **Ladder map is now explicit.** [`core-fetch/SPEC.md`](architecture/core-fetch/SPEC.md) §10 records, for every fetch invariant, which rung checks it today, with what artifact, at what envelope, and whether it is worth moving left. That table is the work queue for this plane, and it replaces guessing about coverage.

### O1c / O2 attempt (2026-08-31) — both produced hard information, neither landed as planned

**O1c (I9 at L2): blocked by a real combinational loop, not by tooling.** The live-frontend harness was
built and *elaborates cleanly* — `read_slang --allow-use-before-declare` over 27 files (all four
`parameter type` structs reconstructed; every predictor, the realigner and the queue resolve). It then
fails at SMT model construction with **"Found logic loop in module g6lc_fetch_hold_props"**, so no
proof can be built over `frontend.sv` today. Files are kept at
`core/fetch_B/formal/g6lc_fetch_hold.{sby,props.sv}` (not in `formalTasks`) because the harness is
correct and only the design blocks it.

Chasing that produced the finding that matters: **`verify.lintArgs` carries `-Wno-UNOPTFLAT`
project-wide, which hides the entire circular-combinational-logic class.** Re-enabling it (Verilator
honours the last `-W` flag) gives **11 reports, 8 of them in the active fetch plane**:

| Locus | Signal |
|---|---|
| `core/fetch_B/frontend.sv:153` | **`fetch_address`** |
| `core/fetch_B/frontend.sv:197` (×3) | regularized nodes on that cone |
| `core/fetch_B/g6lc_fetch_pkg.sv:167` | **`kill_s2`** |
| `core/fetch_B/instr_queue.sv:117` | `address_overflow` |
| `core/fetch_B/instr_queue.sv:126,173` | rotate/regularize nodes |
| `core/decoder.sv:118`, `core/csr_regfile.sv:257`, `core/load_unit.sv:439` | outside fetch |

`fetch_address` ↔ `kill_s2` is **the same loop class the 2026-08-31 icache fix broke** — that fix cut
the path through the cache (`vaddr_d → cl_hit → dreq_o.ready → vaddr_d`), but the frontend-internal
cycle remains. New optional diagnostic **`diag-smt2-comb-loops`** keeps the class visible without
touching the main gate's baseline. Not ratcheted yet: treat it as a report and do not add a loop on
top of it. UNOPTFLAT can be a false positive for bit-sliced signals, but yosys refusing to build an
SMT model is independent corroboration that at least one is real.

**O2 (live-peer battery): blocked upstream, and the M1 oracle controls proved it in one run.** Before
writing minis, the cheapest discriminator (P6) was to ask whether the DI path can produce a PASS at
all. It cannot. The **first ever execution** of the oracle controls, remotely on the B harness:

```
mini_must_pass -> fail (expected pass)
mini_must_fail -> fail (expected fail)
ORACLE INVALID -- H3 'Oracle Validity First' precondition is not met
Suite NOT run: per-test results would be meaningless.
```

`mini_must_pass` is **three instructions** that unconditionally write `tohost=1`, so the failure is
upstream of every test's logic. The trace is unambiguous and **deterministic** (not flaky): the core
spins at `pc=0x10044 instr=ffdff06f` — `jal zero,0x10040`, the **bootrom `_hang` loop** — until the
cycle cap, on every test.

Three consequences:
1. **Adding minis is pointless until this is fixed.** The `W5 × thread-select` gap is real, but no new
   directed test can be validated while every test dies in the bootrom. O2 is *gated on O3*, not
   merely ordered after it.
2. **The controls earned their keep immediately.** They converted "16 mysterious failures" into one
   sentence about the bootrom, and they aborted the suite instead of reporting 16 meaningless verdicts.
3. **This is the H4 determinism O3 wanted.** The symptom is now stable and reproducible, which is the
   precondition for attributing it. Note it also confirms the reverted commit filter was *masking*
   this defect by forcing `s0`'s write rather than fixing it — exactly what H6 predicted.

### Workflow to O4, inferred (2026-08-31) — and one instrument defect fixed on the way

O4 is not workable directly; it sits behind O3. The dependency chain, cheapest step first:

```
O4  OpenSBI residual, as a gate
 └── O3  bootrom must reach DRAM (jr s0 -> 0x80000000)
      └── which layer loses the jump?
           └── cheapest discriminator (P6): A/B pair on mini_must_pass
                ├── legacy green + B red -> fetch_B; one fix also unblocks O1c and O2
                └── both red             -> generic core (issue/commit/link), different owner
```

**Instrument defect found and fixed first — the committed generated bootrom was a commit behind its
source.** `corev_apu/bootrom/bootrom.{sv,h}` are *generated* from `bootrom.S` by `gen_rom.py`, and they
are **checked in**. When `bootrom.S` was reverted to stock in `f2bbcad63`, the artifacts were left at
`7e6c19c54` (the accommodation image with interleaved `nop`s). Verilator compiles the `.sv`, not the
`.S`, so the in-tree image silently disagreed with its own source. Both are now regenerated and in
sync (diff is exactly the accommodation→stock image). **Standing hazard worth remembering: a generated
artifact that is checked in can disagree with its source, and here the artifact is what ships into the
simulation.** `soft-ladder-build-harness.sh` does regenerate it during a remote build (with the right
`RISCV_GCC`), which is why remote runs were not as stale as the tree — but anything that Verilates the
tree directly would have used the wrong ROM.

**A retraction.** On the first pass I read `fetch_addr=0x10044 instr=ffdff06f` as the core fetching a
*different 8-byte window* than the PC claimed — i.e. an I$/I1 violation. **That was wrong**, and it was
wrong because it was measured against the mismatched image above: `ffdff06f` sits at `0x10050` in the
accommodation build. After a clean rebuild the spin site moves to `0x1004c`, which *is* `wfi` in the
correct image. There is no evidence of an I$ window mismatch. (T9: when the instrument changes, the
record moves — including my own reading of it from 40 minutes earlier.)

**O3 stands, now on a trustworthy instrument.** Freshly built B harness, bootrom regenerated from stock
`bootrom.S` (verified by disassembly: `li s0,1; slli s0,s0,0x1f; csrr; auipc; addi; jr s0` at
`0x10000`-`0x10014`, `_hang` at `0x10040`):

```
mini_must_pass -> fail (expected pass)      # three instructions, tohost=1
mini_must_fail -> fail (expected fail)
ORACLE INVALID -- suite NOT run
spin: fetch_addr=0x1004c   (wfi, inside _hang)
```

So `jr s0` at `0x10014` does not reach `0x80000000`, and the hart ends parked in `_hang`. That is a
real bootrom→DRAM hand-off defect on current source, measured with a matched ROM for the first time.

**A/B pair run — result: NOT fetch_B.** `mini_must_pass` fails on **both** `--flavour B` and
`--flavour legacy`. By the blame router's step 0 (`logics.md` §3, `ab.legacy_red && ab.B_red`) that is
*"generic core (issue / STQ / CSR / commit) or B2 firmware policy"*. So the `fetch_address`/`kill_s2`
combinational cone from O1c, while a real hygiene defect that still blocks the I9 proof, is **not** the
cause of O3. That hypothesis is retired rather than left hanging.

**The M1 control is itself valid** — checked before trusting its verdict, since a failing positive
control can equally mean a broken control (H3 applied to the control). `mini_must_pass` links and
assembles exactly as intended: `_start` at `0x80000000`, `tohost` at `0x80001000`, body =
`csrr t0,mhartid; bnez t0,park; li t0,1; auipc/addi t1,tohost; sw t0,0(t1); j .`, with hart!=0 parked in
`wfi`. Nothing about the test is wrong; the machine does not write `tohost`.

**O3's framing was too narrow: the behaviour is test-dependent, and some tests DO reach DRAM.** On the
same freshly built B harness:

| Test | Where it ends |
|---|---|
| `mini_must_pass` | `fetch_addr=0x1004c` — `wfi` inside the **bootrom** `_hang`; never leaves ROM |
| `mini_amoadd_w_spin` | fail (timeout) |
| `mini_csr_expected_trap` | `dec_pc=0x800000cc`, `fetch_addr=0x800000ce instr=00000000 is_illegal=1` — **in DRAM**, fetching zeros past its code |

So "the bootrom never reaches DRAM" is wrong as a general statement: `mini_csr_expected_trap` executes
at `0x800000cc`. Two distinct signatures are in play, and they must not be merged into one story:
(a) a hart that stays parked in the bootrom, and (b) a hart in DRAM fetching `00000000` and taking an
illegal-instruction trap. Whether (a) is hart-1-parked-legitimately versus hart-0-stuck is **not yet
established** and is the next thing to determine — the `id-dbg` line does not identify the hart, so the
first step is per-hart attribution, not another hypothesis.

### ROOT CAUSE FOUND: the retire stream executes bytes that do not match the PC (2026-08-31)

Following the ordering (read the counterexample before theorising) led to the actual defect, and it
**reverses two of my own earlier conclusions**. Both retractions are recorded because the reasoning that
produced them was wrong in an instructive way.

**Retraction 1 — "exception delivery is broken" is FALSE.** The RVFI trace shows instructions retiring
normally and an `ILLEGAL_INSTR exception` being *reported and taken*. Exceptions work. The earlier
`mcause=0` readings came from an `id-dbg` probe that does not observe committed CSR state; I treated a
silent probe as evidence of absence.

**Retraction 2 — the "wrong fetch window" reading I retracted on 2026-08-31 was RIGHT.** I withdrew it
because it had been measured against a mismatched bootrom image. The observation was sound; only its
instrument was bad. Re-measured against a *verified* ELF, it holds.

**The evidence.** `~/trapdisc/t_ecall.elf`, `.text` 0x44 bytes, one clean LOAD segment at 0x80000000
(readelf-confirmed, so nothing is missing from memory):

| Addr | ELF contains | RVFI actually retired |
|---|---|---|
| `0x80000008` | `auipc t0,0x0` | `auipc` — matches |
| `0x8000000c` | `addi t0,t0,36` | `addi` — matches |
| `0x80000010` | **`csrw mtvec,t0`** (`30529073`) | **`f14022f3` = `csrr t0,mhartid`** — the bytes from `0x80000000` |
| `0x80000014` | **`li s0,0`** (`4401`) | **`02029c63` = `bnez`** — the bytes from `0x80000004` |

So the machine is fed bytes from address `A` while reporting PC `A + 0x10`.

**This is not a tracer artifact — the architectural effect follows the BYTES, not the PC.** Two
independent confirmations: (a) `csrr` wrote `x5 = 0`, i.e. a CSR *read* really executed where the ELF
has a CSR *write*; and (b) the subsequent trap vectored to `0x00010048` (bootrom `_hang`) instead of
`handler` at `0x8000002c`, which is only possible if **`csrw mtvec` never executed**. The wrong
instruction was not merely mis-reported, it was *committed*.

**That is an I1/I2 violation** — "decode is a function of bytes and address alone" — at the
instruction-supply boundary, and it explains every symptom of the last two days at once: the bootrom
never completing `jr s0`, `mini_must_pass` failing, `mini_csr_expected_trap` running off the end of its
`.text` into zeros, and all 16 DI minis failing. One defect, many faces.

**Why none of the 11 proven contracts could catch it — and this is the important structural lesson.**
Every fetch proof takes `data_i` as a *free* input and proves the realigner/queue are faithful to
whatever they are handed. That is exactly the right contract for those modules, and it is exactly why it
is blind here: **no contract ties `data_i` to the memory content at `vaddr`.** The promise "the bytes
returned for a fetch of address A are the bytes at A" has no owner. A green 11/11 gate and a core that
executes the wrong instructions are therefore perfectly consistent — the gate never claimed otherwise.
That missing promise is now the highest-value contract in the repository, ahead of I9.

**The missing promise now has an owner, and it is validated in both directions.** `+fetch_i1_check`
(`core/id_stage.sv`, sim-only, + `g6lc_dram_peek64` DPI in `corev_apu/tb/g6lc_tb.cpp`) checks at the
*delivery* point — the `(address, instruction)` pair decode actually consumes — so one sentence covers
the I$, the realigner and the queue. Positive control: it fires on `~/trapdisc/t_ecall.elf`. Negative
control: silent without the flag. Its output **quantifies** the defect:

| addr | delivered | should be | bytes actually come from |
|---|---|---|---|
| `0x80000010` | `f14022f3` | `30529073` | `0x80000000` |
| `0x80000014` | `02029c63` | `00734401` | `0x80000004` |
| `0x80000020` | `30529073` | `fe430313` | `0x80000010` |

**The data stream lags the address stream by exactly `0x10` — two 8-byte fetch windows at
`FETCH_WIDTH=64`.** Not a random corruption, not an off-by-one: a constant two-window lag, which is a
pipeline-depth signature (a response register pair sampled one stage too late, or an FDIP/FTQ entry
retired against the wrong window) rather than an addressing or decode fault.

Three instrument traps were hit building this, all worth remembering because each looks exactly like
"the check found nothing":
- `g6lc_fetch_dbg.sv` is **commented out of `Flist.cva6`** (line 252) while present in `Flist.fetch_B`;
  the B build uses `Flist.cva6`, so a checker placed there is never compiled. Hence the move to
  `id_stage.sv`, which is in the build and already hosts the `[id-dbg]` probe.
- A plusarg absent from the C++ **allowlist** (`g6lc_tb.cpp:84`) is handed to HTIF, which rejects it and
  kills the run *before* the checker arms. A rejected plusarg and a clean check are indistinguishable
  from the outside.
- A comment line beginning with the linter's own name is parsed as a directive and fails elaboration.

**Next, in order:**
1. ~~Write the I1-at-supply contract~~ **Done** (above), and it did what the ordering predicted: it
   localised the defect to a constant two-window lag in one 9-second run, having cost less than any of
   the hypotheses it replaced.
2. Only then localise: the `0x10` shift is a whole number of fetch windows, so suspect the I$
   response/`vaddr` pairing (the registered-`vaddr_q` path touched by the earlier convergence fix) or
   FDIP/FTQ replay serving a stale window. `id-dbg` already prints `fetch_addr`, so pair it with the
   returned data and diff against the ELF.
3. Re-run the A/B pair afterwards: both flavours failing is consistent with a shared I$/supply defect
   rather than a fetch_B-specific one, which fits this root cause better than it fits the earlier
   decode-plane hypotheses.

### Roadmap analysis: O4 → soft-ladder → SMT2 → multi-threading → g6lc_qemu (2026-08-31)

Asked for a large architectural pass toward *Linux + hypervisor boot and stable runtime* on the maximal
envelope (8-wide OoO, 8 cores, stream plane, L1–L3, RVV). The honest answer is that **the feature
parameterization is not the bottleneck and new feature RTL is not the right next code**:

- `check_cfg` already carries a dense legality envelope for U1–U6 — `OoOEn`/`SliceOoOEn` exclusivity,
  `NrIssuePorts` 1..8, `NrCores` 1..8 with the `NrCores × NrHarts` product bound, `L2En`/`L3En`
  dependency and power-of-two shape checks, prediction-fabric legality, `RVH → RVS`, prefetch/D$ type
  gating. Adding more asserts there would be duplication, not progress.
- What is missing is **contracts on the planes those features run through**. Every one of the 11 proven
  contracts is in the fetch plane. Decode, issue, commit, the exception path, the LSU and the coherence
  fabric have **zero**. That is not a documentation gap; it is why a green formal gate coexists with a
  core that cannot deliver an illegal-instruction trap.

So the ordering is forced, and it is *narrower* than the feature list:

| Stage | Gate | Why it must come first |
|---|---|---|
| **now** | exception delivery works at all | RVH/Linux/RVV all assume precise traps. A hypervisor is *built* out of traps (`sret`/`mret`, two-stage faults, `hideleg`). Building RVV or L3 on a core that drops exceptions is building on sand. |
| then | **O4** OpenSBI residual | Reachable only once `sbi_hart_detect_features`' CSR probes can trap. Its recorded signature must be **re-derived**, not reused (T9). |
| then | soft-ladder / SMT2 live-peer battery (**O2**) | Needs a valid oracle, which needs a machine that can report PASS. |
| then | multi-threading beyond T=2 | I18/I20/I22/I23 per-hart isolation contracts, none of which exist yet outside fetch. |
| last | `g6lc_qemu` B0–B3 | It *consumes* the model (DTS/PMU/device contracts). A generator fed by an unverified core propagates the error into the tooling. |

**Concrete pass made toward this, rather than feature scaffolding:**

1. **A real latent bug, found by trying to elaborate the decoder formally** (`core/decoder.sv:1758`).
   `riscv_pkg` declares instruction fields at their bit positions — `atype_t.rd` is `[11:7]`, `rs2` is
   `[24:20]` — so the AMOCAS.Q odd-pair guard `instr.atype.rd[0] || instr.atype.rs2[0]` indexed **bits
   that do not exist**. Verilator resolves an out-of-range index to X/0 and says nothing, so *the check
   never fired* and an odd-pair AMOCAS.Q was accepted instead of reported illegal. slang rejects it
   outright. Fixed to `rd[7]`/`rs2[20]`. This is the push-left thesis in miniature: the proof paid for
   itself before it ran.

2. **`core/include/g6lc_core_types.svh`** — the modularity seam. SV packages cannot be parameterized, so
   every pipeline struct lives as a `localparam type` in `core/cva6.sv`, unreachable from any harness not
   instantiated under `cva6`. Consequence: each props file **hand-copies** the layouts
   (`g6lc_fetch_hold_props.sv` reconstructs four, "layout-identical … by hand and by hope"). A props file
   whose `scoreboard_entry_t` has drifted still elaborates, still passes, and is checking a different
   machine. The header follows the convention the codebase already uses for exactly this
   (`rvfi_types.svh`, `cvxif_types.svh`: cfg-as-macro-argument). `cva6.sv` adoption is deliberately
   deferred — it must be shown netlist-identical first (I27 applied to a refactor) — and until then the
   header is documented as a copy that must track `cva6.sv`. One tracked copy beats N untracked ones.

3. **`core/formal/g6lc_trap_deliver.{sby,props.sv}`** — the first exception-plane contract, live-DUT
   (not a policy model: the `ooo` proofs are self-contained models and would have reproduced the
   *intent* rather than the code, which is how the CVXIF hole survived). Two tasks by design, so the
   proof has its own oracle: `ok` (CvxifEn=0) must pass, `bug` (CvxifEn=1) carries `expect fail` and is
   the machine-checked statement that the withheld `ex.valid` is real and the new `check_cfg` guard is
   load-bearing.

   **Status: elaborates clean (0 errors, 0 warnings) but `ok` FAILS, so it is NOT wired into
   `verify.formalTasks`.** All three assertions fail together, which points at the structure rather than
   at any one property — and the structure is the find: **`instruction_o` is driven by four separate
   processes** (`always_comb : decoder` :192, `always_comb : sign_extend` :1879, the continuous
   `assign instruction_o.valid` :1961, and `always_comb : exception_handling` :1963), i.e. one packed
   struct variable with four drivers. That is exactly why `decoder.sv:118 instruction_o` appears in the
   `UNOPTFLAT` circular-combinational report, and it is strong corroboration for **O3e**. Not yet proven
   to be *the* cause of the missing trap — the counterexample trace has not been read — so it is logged
   as corroboration, not as a verdict.

### Fastest path to O4, inferred from OpenSBI source (2026-08-31)

Rather than treat O4 as "run the soak again", the path was derived by lifting the failing directed mini
to its archetype and reading the OpenSBI witness for it (H1 → §2 archetypes → logics §2 R-table).

**`mini_csr_expected_trap` is a verbatim transcription of OpenSBI's R3 probe.** Disassembly of the
built ELF against the firmware source leaves no ambiguity:

| Mini | OpenSBI witness |
|---|---|
| `csrrw t1, mtvec, t0` (arm, saving old mtvec) | `include/sbi/sbi_csr_detect.h:17` `csr_read_allowed` |
| `.word 0xfff022f3` = `csrr t0,0xfff` (illegal CSR) | the maybe-illegal probe itself |
| `csrw mtvec, t1` (restore), inline, repeated twice | same, and `lib/sbi/sbi_hart.c:771` repeats it dozens of times |
| `expected_handler`: `csrr mepc; addi +4; csrw mepc; mret` | `lib/sbi/sbi_expected_trap.S:23` — the **blind fixed +4** |

**Its failure, measured on the freshly built B harness with a matched ROM:** `mcause=0` and `mepc=0`
for the full 200k cycles, i.e. **no trap ever fires**. The illegal CSR access at `0x80000020` does not
except; execution then continues past the restore, and does not even take the
`bne s0,t3,fail` at `0x8000002e` (which must be taken, since `s0` cannot hold the `0xe601` cookie a
handler never wrote). `tohost` is never written by either the pass path or the `fail` path, and the core
ends fetching zeros at `0x800000cc` — `0x38` bytes, i.e. **14 × 4**, past the `0x94`-byte `.text`.

**So the gate on O4 is the W2 archetype — precise trap — and it is not in the fetch plane.**

```
O4  OpenSBI fw_payload reaches the cookie
 └── requires sbi_hart_detect_features() to complete            lib/sbi/sbi_hart.c:771
      └── which repeats csr_read_allowed() dozens of times      include/sbi/sbi_csr_detect.h:17
           └── which REQUIRES a precise illegal-instruction trap
               plus a handler whose blind mepc+=4 is sound      lib/sbi/sbi_expected_trap.S:23
                └── mini_csr_expected_trap is exactly that, and no trap fires at all
                     └── Home (logics §2, R3): "precise trap", `stall_csr_older` (**issue**, not fetch)
                          └── corroborated independently by the A/B pair: fails on BOTH flavours
```

Three things line up, which is why this is worth acting on rather than another hypothesis:
1. **A/B said "not fetch_B"** — and R3's Home is issue/commit, not fetch. Independent agreement.
2. **All 11 proven contracts are fetch.** None touches trap delivery, so none of them could have caught
   this — which is exactly why the pin survived a green formal gate.
3. **M5 already flagged this cell as empty**: `W2 × issue` and `W2 × commit` have **zero** minis, and
   R3's clauses (c) and (d) were recorded as having no owner. The coverage matrix predicted the gap
   before the failure was understood.

**Discriminator run (T3), and it picks the file: exception delivery, not CSR legality.** Two minis were
built differing in *one word* — an illegal **instruction** (`.word 0x00000000`) versus an illegal **CSR
access** (`.word 0xfff022f3`), everything else identical:

| Probe | `mcause` / `mepc` | Reached DRAM? |
|---|---|---|
| illegal **instruction** | `0` / `0x0` | **yes** — executing `0x80000018`…`0x80000026` |
| illegal **CSR access** | `0` / `0x0` | **yes** — executing `0x80000024`…`0x80000034` |

**Neither raises a trap.** The confound was checked before drawing the conclusion (both minis share
`mini_must_pass`'s shape, which never leaves the ROM, so "no trap" could have meant "no execution"):
they *do* execute in DRAM, so `mcause=0` is a real absence of trap delivery and not an absence of
instructions.

Because the failure is **identical for both**, it is *not* the CSR-legality path. The suspect is the
generic **exception delivery / trap-entry path** — `core/commit_stage.sv` and `core/controller.sv` —
and **not** `core/csr_regfile.sv`. One 20-second experiment eliminated a file that would otherwise have
been the obvious place to start reading.

This also reframes O1c: I9 is "trap entry to `mtvec` is held until decode consumes it", and on this
evidence a trap entry is never *generated* in the first place. The I9 hold contract is downstream of a
defect in raising the exception at all, so proving I9 would not have caught this either.

#### A real static defect found by reading that path — and an honest negative on the fix

Reading `is_illegal → ex.valid → trap` end to end found a genuine ISA violation, independent of whether
it causes the symptom above:

| Step | Locus | Behaviour when `CvxifEn` |
|---|---|---|
| 1 | `core/decoder.sv:1838-1844` | illegal instr → `fu = CVXIF`, `op = OFFLOAD` |
| 2 | `core/decoder.sv:1976` | **`ex.valid` is withheld** — `if (!CVA6Cfg.CvxifEn)` — so the coprocessor may claim the encoding first |
| 3 | `core/issue_read_operands.sv:288` | `cvxif_req_allowed = (issue_instr_i[0].fu == CVXIF)` — **port 0 only**, with its own `TODO check only for 1st instruction ??` |
| 4 | `core/cvxif_fu.sv:61,69` | `x_valid_o` and `x_exception_o.valid` are both just `x_illegal_i` |

So on a **multi-issue** core an illegal instruction landing on any port `!= 0` gets `fu=CVXIF`, no
`ex.valid`, no CVXIF transaction, and `cvxif_fu` never returns valid: **it neither traps nor retires**,
and the machine wedges. Three G6LC configs shipped that combination — `g6lc64_smt2` (2-wide),
`g6lc64_ooo` (2), `g6lc64_ooo_server` (4) — while *every* upstream config has `NrIssuePorts: 0`. The
unsound pairing is therefore ours: the superscalar targets inherited `CvxifEn=1` from the upstream
default without the offload path ever being extended past port 0.

Fixed as a parameter red line rather than a waiver (I28: a parameter gate must not legitimize an ISA
violation): `check_cfg` now `$fatal`s on `CvxifEn && NrIssuePorts > 1`, and the three targets take the
knob to baseline (`CvxifEn = 0`) since none has a coprocessor to offload to.

**But it did not fix the symptom, and that is recorded as a negative result, not quietly dropped.**
Rebuilt and re-ran both probes: still `mcause=0`, still no trap. The rebuild is *confirmed* to have
taken effect — the harness shrank `3736872 → 3718216` bytes as the CVXIF FU and example coprocessor
dropped out of the model — so this is a real negative, not a stale instrument (which had already caught
me twice today, see below).

**Therefore a second, independent defect blocks exception delivery.** The leading suspect now converges
with O1c: `core/decoder.sv:118 instruction_o` appears in the `UNOPTFLAT` circular-combinational report,
and `instruction_o.ex.valid` is *precisely* the field that fails to work. `core/csr_regfile.sv:257
update_access_exception` is in the same report, which would equally explain the illegal-CSR arm. A
non-convergent `instruction_o` cone is a mechanism that produces "decode says illegal, nothing traps"
for both probes at once. That is the next hypothesis, and it makes the comb-loop cleanup a correctness
prerequisite rather than hygiene.

**Do not** re-measure the recorded O4 signature (`mepc0=0x8000a9a8`, `mcause0=0x2`) as evidence yet: it
was taken on RTL that still carried the commit value filter, so per T9 it is not comparable to anything
current. Re-derive it only after the W2 gate passes.

### Objectives (ordered by ladder position, not by symptom)

The cheap rungs are now real, so the ordering rule from
[`AGENTS-coding-philosophy.md`](AGENTS-coding-philosophy.md) §2.9 applies literally: spend the next
increment at the **leftmost stage that can express the rule**, and treat firmware as a gate.

| # | Objective | Rung | Why now |
|---|---|---|---|
| ~~**O1a**~~ | ~~I12 explicit sequential step + the window algebra~~ | L2 | **Done.** `g6lc_fetch_geo.sby` proves `nxt == base + W`, `nxt > pc`, `!same_win(pc, nxt)`, and that `win_base`/`win_tag`/`same_win`/`hw_off`/`ilen_of`/`rvi_prefix` all agree — **swept over 6 envelope points** (FW 32/64/128/256 × RVC, plus 64/128 without RVC). Gate is now **9/9**. |
| ~~**O1b**~~ | ~~I4 per-hart leftover, I6 head-selection independence~~ | L2 | **Done.** Both closed by proving against **live modules** instead of pure functions. `g6lc_fetch_realign.sby` instantiates the real realigner and proves **I1/I2** no-fabricate (emitted halfword == `data_i` at that slot's own address) and **I4** per-hart carry isolation. `g6lc_fetch_iq.sby` proves **I6** by **self-composition**: two live `instr_queue` copies, identical control, different raw `instr_i`, identical `ready_o`/`consumed_o`/`replay_*`/`fetch_entry_valid_o`/`.address`. Gate is now **11/11** (~18 s remote). |
| **O1c** | **I9** bounded trap hold | L2 | **Blocked, and the blocker is the finding.** The harness elaborates; `frontend.sv` has a circular combinational cone (`fetch_address` / `kill_s2`) that stops yosys building an SMT model. Fix the loop first -- then this proof is a re-run, not new work. |
| **O2** | Grow the battery along the **live-peer** axis | L4 | **Gated on O3, not merely after it.** `mini_must_pass` (3 instructions) fails: every test spins in the bootrom `_hang` loop at `0x10044`. No directed test can be validated until that is fixed. |
| **O3** | Bootrom `_hang` spin - why `jr s0` never reaches DRAM | L6 prep | **Now the critical path, and now deterministic.** Every DI test, including a 3-instruction one, ends spinning at `pc=0x10044 instr=ffdff06f` (`jal zero,0x10040`). H4 is satisfied, so attribution is finally admissible. Prime suspect is the `fetch_address`/`kill_s2` combinational cone from O1c: a non-convergent frontend and a bootrom that never completes its jump are consistent. |
| **O4** | OpenSBI residual (`mepc0=0x8000a9a8`, `mcause0=0x2`) | L6 | Only as a **gate**, and it is unreachable until O3 lands: the machine never leaves the bootrom, so the OpenSBI signature recorded earlier was itself measured on a different (filtered) RTL. Re-measure it after O3 before citing it. Never a search signal. |
| ~~**O3a**~~ | ~~A/B pair on `mini_must_pass`~~ | L4 | **Done. Result: not fetch_B** — fails on both flavours, so the blame router points at the generic core or firmware policy. Retires the comb-loop-causes-O3 hypothesis. |
| **O3b** | Per-hart attribution of the `mini_must_pass` signature | L4 | `id-dbg` does not print the hart, so "hart 1 parked correctly" cannot be told from "hart 0 stuck". Still open, but **no longer the critical path** — O3c is cheaper and sits directly on the O4 chain. |
| ~~**O3c**~~ | ~~illegal instruction vs illegal CSR discriminator~~ | L4 | **Done. Both fail identically with `mcause=0`, and both execute in DRAM** (confound checked). So it is **not** CSR legality: the suspect is generic exception delivery — `commit_stage.sv` / `controller.sv`, not `csr_regfile.sv`. |
| ~~**O3d'**~~ | ~~read the illegal→`ex.valid`→trap path~~ | L4→RTL | **Done, with a real find and an honest negative.** Found and fixed a genuine ISA violation (CVXIF offload is port-0 only while the decoder withholds `ex.valid`; unsound on all three multi-issue G6LC targets, now a `check_cfg` `$fatal` + knob to baseline). It did **not** fix the symptom: still `mcause=0` after a confirmed rebuild. |
| ~~**O3e**~~ | ~~is the `instruction_o` cone why `ex.valid` never asserts?~~ | L2/RTL | **Wrong question — retracted.** `ex.valid` *does* assert and exceptions *are* taken; the RVFI trace shows `ILLEGAL_INSTR` reported and vectored. The four-driver `instruction_o` struct is real and still blocks the L2 decode proof, but it is a **proof-model** obstacle, not the boot defect. |
| **O5** | **THE defect: retire stream executes bytes offset `0x10` from the reported PC** | L3→RTL | I1/I2 violation at instruction supply, confirmed architecturally (`csrw mtvec` never executed, so the trap vectored to the bootrom instead of the handler). Explains the bootrom stall, `mini_must_pass`, the run-off-the-end, and all 16 DI failures as one defect. Repro: `~/trapdisc/t_ecall.elf`, 9 s. |
| ~~**O5a**~~ | ~~the missing promise: delivered bytes == memory at the delivered address~~ | L3 | **Done and validated both ways.** `+fetch_i1_check` in `core/id_stage.sv` + `g6lc_dram_peek64` DPI. Fires on the repro, silent without the flag. Quantified the defect to a **constant `0x10` (two-window) lag of data behind address**. |
| ~~**O5b**~~ | ~~find the one-line skew~~ | RTL | **FIXED** in `core/cache_subsystem/g6lc_icache.sv` (I4xk): `cl_index` must use `vaddr_d`, not `vaddr_q`. The array read is launched in IDLE in the same cycle the request arrives, so indexing with the *previous* address read the previous line. `ICACHE_OFFSET_WIDTH=4`, hence a skew of exactly one 16-byte line = the observed `0x10`. Verified: `+fetch_i1_check` reports **0 violations** on all four reproducers, with the oracle already proven able to fire. |
| ~~**O5d**~~ | ~~a second, downstream defect~~ | L4 | **It was the classifier, not the core.** The harness prints `dtm->exit_code()`, not the raw tohost word: HTIF uses bit0 as "done" with bits[31:1] as the code, so writing `tohost=1` prints `(tohost = 0)` and writing `3` prints `(tohost = 1)`. The "tohost = 1 is pass" rule matched the FAILING run. Fixed in both `soft-ladder-di-regress.sh` and the proxy. |
| ~~**O6**~~ | ~~re-measure the battery with a valid oracle~~ | L4 | **Done. First trustworthy baseline: 3/16.** Every DI number recorded before 2026-08-31 went through a broken classifier and/or a line-skewed fetch and is **void** — the 15/16, the 16/16 and the 0/16 were all measuring the instrument. |
| ~~**O7**~~ | ~~triage the 8 exit-code failures~~ | L4 | **Done.** All 8 reach their own `fail*` label, so all 8 are real rejections: codes 1,1,1,3,1,16,1,2 at `fail`/`fail_exit`/`fail_pop`/`fail_phase`. `mini_csr_expected_trap` (the direct OpenSBI `csr_read_allowed` witness) was traced to root cause — see O7a. |
| **O7a** | **PARTIALLY FIXED (net +1, one regression — read O7b before building on it).** `present_exp_q` is now cleared on redirect in `core/fetch_B/frontend.sv`. **Gained:** `mini_csr_expected_trap` (the direct OpenSBI `csr_read_allowed` witness) and `mini_amoadd_w_spin` now PASS. **Lost:** `mini_fdt_lenp_sw` PASS → timeout. Baseline 3/16 → **4/16**. Both seed variants were measured — `npc_d` and `'0` — and both show the same trade, so the regression is caused by re-basing the filter at all, not by the seed value. Kept because the OpenSBI witness is on the coldboot critical path, but it is a **trade with an open regression, not a clean fix.** | RTL |
| **O7m** | **IN PROGRESS: `gen_ordered_issue` in `instr_queue` uses global PC comparison, which reorders across fetch windows. A window-aware fix hung the queue.** | RTL | Initial fix (round-robin group + same-window PC order) was committed and reverted in the same session. It eliminated the out-of-order return issue in the probe but caused the queue to deadlock: `rdy=0`, `full=0101`, `fire=00` for hundreds of cycles, with heads `[0x40 0x54 0x48 0x4c]` (F1 contains a younger `0x54` while F2 still holds older `0x48`). This means the local round-robin + PC-order hybrid was not sufficient; either the window-boundary detection is wrong, the tail pointer `idx_ds_d` advanced past unconsumed entries, or a different invariant is violated. Next: reproduce the hang with a minimal `iq_trace` window, then either (a) fix the group logic, or (b) pursue a redirect-time queue flush instead of ordering. The `iq_trace` and `fetch_win_trace` probes stay as fixtures. |
| **O7l** | **CONFIRMED by direct observation: `instr_queue` emits the YOUNGEST entry of a group first. Nothing is dropped — order is inverted.** | RTL | New `+iq_trace` probe (`core/fetch_B/instr_queue.sv`, the old `[iq-dbg]` was gated to `$time()<100`). Around the return: `t=421 isq=00 dsq=0001 push=0011 cons=0011 full=0000 rdy=1` accepts `0x40`,`0x44`; `t=423 isq=10 dsq=0001 push=1100 cons=0011` accepts `0x48`,`0x4c`. The output pointer `dsq` sits at `0001` with `fire=00` from t=409 to t=427 while `a0=0x8000003e` (decode stalled). On the first fire, **`t=428 a0=0x8000004c`** — the youngest of the four — and only at `t=430` does `a0=0x80000040` appear, by which time `t=431 fl=1 mp=1` flushes it because the mis-ordered branch already resolved. **All four entries were accepted with `full=0000` and `rdy=1`, so nothing is dropped at the input; the selection order at the output is inverted.** This is I6 clause 1, the clause `g6lc_fetch_iq.sby` does not prove. Next: `idx_is_q`/`idx_ds_q` are independent rotating pointers and the push mapping is `rotate_left(valid, idx_is_q)` (line 175) — the bug is in how a *multi-slot push while the output pointer is parked* maps slots onto FIFOs relative to `idx_ds_q`. Fix candidates must preserve I7 (all-or-nothing push) and the leftover slot0 escape. |
| **O7k** | **REFINED by reading: not the input side. `instr_queue` OUTPUT ORDER is the violation — and it is I6 clause 1, which no proof covers.** | RTL | `instr_queue.sv:158` `ready_o = ~(\|instr_queue_full) & ~full_address` **is** occupancy-derived, and there is a correct I7 overflow path (`instr_overflow` → push none → replay, lines 176-186). With `iqr=1` at both pushes no FIFO was full, so `0x40`/`0x44`/`0x48` **did enter** the queue. Yet retire goes `0x3e → 0x4c`: since this core retires in order, `0x4c` was *issued before* three older entries. **That is a program-order violation at the queue output — the one-hot output select `idx_ds` advancing further than the number of entries actually consumed** (`[iq-dbg]` already exposes `idx_ds_q`/`idx_ds_d`). Entries then die in the flush when the mis-ordered `bne` at `0x4c` branches to `fail_pop`. **Proof gap worth recording:** I6 is stated as "IQ order is program order AND must not depend on opcode/rd/FU", but `g6lc_fetch_iq.sby` proves only the *second* clause, by self-composition on value-independence. **Clause 1 — program order itself — has never been proven**, which is exactly the clause being violated. Next: probe `idx_ds_q`/`idx_ds_d` against `consumed_o` and `fetch_entry_fire` per cycle, and give clause 1 its own contract. |
| ~~**O7j**~~ | ~~input-side overwrite: ready asserted while head stalled~~ | RTL | **Superseded by O7k** — the mechanism was wrong (`ready_o` is occupancy-derived and I7 backpressure is correct); the *localisation to `instr_queue`* stands. | The two existing probes together pin it, no new instrumentation needed. `[id-dbg]` (queue output to decode) shows `fetch_addr=0x8000003e` **stuck at the head from t=409 through t=426+** — the same entry `00004285` (`li t0,1`) for 17+ cycles, so decode is stalled and not consuming. `[win]` shows that during exactly those cycles the frontend pushed the windows for `0x40` (t=421) and `0x48` (t=423), both `take=1 vmask=0011`, **with `iqr=1` (`instr_queue_ready`) asserted**. Retire then goes `0x3e → 0x4c`, skipping `0x40`, `0x44`, `0x48`. **Hypothesis with a mechanism: `instr_queue` asserts ready while it cannot actually accept, so pushes during a decode stall overwrite entries that were never consumed — a silent drop instead of backpressure.** This is an I6/I7 violation (program order and "a dropped window drops all slots") and it is where the ~9 `fdt_*`/`stq_*` failures should be re-tested, since every one of them stalls decode behind a call/return. Next: probe `instr_queue` push/pop indices and `ready_o` vs occupancy — the existing `[iq-dbg]` is gated to reset cycles only (`t=1..9`) and prints no addresses, so it needs widening. |
| **O7h** | **RELOCATED: the post-`ret` drop is DOWNSTREAM of fetch. The frontend presents the instructions; they never retire.** | RTL | The `+fetch_win_trace` window-lifecycle probe (new, `core/fetch_B/frontend.sv`) settles it. Around the return in `mini_fdt_next_tag_lbu`: `t=407 vaddr=0x80000138 bpf=1 k2=1 npc=0x8000003e` (the `ret` redirect); `t=409 vaddr=0x8000003e vmask=0001` (target slot, retires); **`t=421 vaddr=0x80000040 vmask=0011`** and **`t=423 vaddr=0x80000048 vmask=0011`** — both windows *taken* with two valid slots each, i.e. `0x40 bne`, `0x44 auipc`, `0x48 addi`, `0x4c bne` were all **presented to the queue**, with `iqr=1` (no backpressure) throughout. The retire trace shows only `0x3e` and `0x4c`. **So fetch delivers them and the instruction queue / decode / issue / commit path loses them.** Three prior attributions (O7a filter, O7f return path, O7g) were all in the fetch plane and all wrong about the location. Next: instrument `instr_queue` push/pop and the `id_stage` → issue handshake, not fetch. |
| **O7i** | Probe hazard worth remembering: a concatenated `$display` format string silently produced a NO-OP probe | L0 | `$display({"...", "..."}, ...)` compiled cleanly — `fwt_en` appears in the generated model — but the format string never reached the binary and the probe printed nothing. Indistinguishable from "nothing to report". Use a single string literal. Sixth instrument obstacle this session; the ledger of instrument-vs-machine defects is now 6:4 against the machine. |
| **O7g** | **RETRACTION: the prefix filter is NOT the mechanism behind the post-`ret` drop** | RTL | Tested the assumption instead of re-seeding it a third time. Making `slot_ge_expected` fully permissive (`G6LC_NO_PREFIX_FILTER`, now a kept switch) changes the battery **not at all** — 4/16, same tests, same modes. So (a) the filter is not load-bearing for this suite, and (b) it is **not** what drops `0x40`/`0x44`/`0x48` after a predicted `ret`. **The O7f observation stands; the O7f attribution is withdrawn.** Note this does not undo O7a: clearing the filter on architectural redirects was independently worth +2 tests, so the filter *was* the mechanism on the `mret`/flush path while something else is the mechanism on the predicted-return path. Two distinct slot-drop mechanisms, not one. Left ACTIVE: "not load-bearing for 16 minis" is weak grounds for deleting a mechanism whose comment cites OpenSBI walk scenarios absent from this suite. **Next suspects for the post-`ret` drop, in order:** `bp_fire` clearing `icache_valid_q` (frontend.sv:~871) and so discarding the return target's own registered window; `icache_take` never registering it; or `kill_s1`/`kill_s2` killing it in flight. All three are observable by extending the existing `id-dbg` probe with `icache_take`/`kill_*`/`bp_fire` rather than by another guess. |
| **O7f** | ~~shared cause is the call/return path~~ — **observation stands, attribution withdrawn (see O7g)** | RTL | Tracing `mini_fdt_next_tag_lbu` (the shallowest failure) found instructions being dropped after `ret`, exactly the O7a class but on a *predicted return* rather than an architectural redirect. Evidence: the callee epilogue retires (`ld s0/s3/s4` at `0x8000012e`-`0x132`), the return lands on `0x8000003e` (`li t0,1`) which retires, and the **next retired instruction is `0x8000004c`** — so `0x40` (`bne a0,t0`), `0x44` (`auipc t0`) and `0x48` (`addi t0,t0,188`) never retire. `t0` therefore keeps `1` from the `li`, and `bne s2,t0` compares `0x80001100` against `1`, branches to `fail_pop`, and the mini reports code 1. **The mini's logic is correct; three instructions disappeared.** Note `0x8000003e` is at offset 6 — the last halfword of its window — so the return target is maximally unaligned, the same shape as the `mret` case. This **overturns O7e**: the nine `fdt_*` minis do share a cause after all, because they all use `jal`/`ret` call-return pairs ("callee saves s2/s3 like OpenSBI"), and the differing fail depths are just where each mini's first post-return check happens to sit. My O7a fix does not cover this because it only re-bases `present_exp_q` on `flush_i \|\| is_mispredict \|\| bp_fire`, and a correctly-predicted RAS return is none of those. |
| ~~**O7e**~~ | ~~grouped-cause hypothesis is weak~~ | L4 | **Overturned by O7f** — the shared cause is control flow, not data. The three primitive eliminations still stand and were what made the O7f trace unambiguous. | Three eliminations, each one probe: (1) supply — 0 I1 violations across all 18 minis; (2) sub-word memory — `lbu`×8 offsets, `lhu`×4, `lwu`×2, byte/halfword store→load forwarding, 18/18 pass; (3) integer/BE primitives — signed `lb`/`lh`/`lw` sign-extension, `slli`/`srli`/`srai`, `addiw`/`addw`/`sllw`/`srlw`/`sraw`, and a manual 32-bit byte swap, 14/14 pass. Both probes kept on the builder as reusable primitive checks. **Two further facts argue against one shared cause:** the `fdt_*` minis each carry their OWN blob in `.rodata` (`fdt_struct`, `fdt_blob`), so there is no shared external data dependency; and they fail at very different depths (codes 1, 3, 16 — `mini_fdt_a0_is_fdt` reaching phase 16 means most of its walk works). Nine tests sharing a *name* is not nine tests sharing a *defect*. Next: trace the shallowest failure (`mini_fdt_next_tag_lbu`, code 1 at `fail_pop`, 6 s) rather than probing for more common primitives. |
| **O7c** | **Grouped sweep result: the remaining 12 failures are NOT fetch and NOT sub-word memory** | L3 | One instrumented sweep of all 18 minis with `+fetch_i1_check`: **0 I1 violations everywhere**, so instruction supply is clean for every test and no remaining failure is a fetch-supply defect. Then one 7-second directed probe killed the leading shared-primitive hypothesis: `lbu` at all 8 offsets, `lhu` at 0/2/4/6, `lwu` at 0/4, and store→load forwarding at byte and halfword granularity **all pass**. Nine of the twelve are `fdt_*` walkers, so a shared cause remains likely, but it is not sub-word load/forward and it is not supply. Next candidates by shared shape: big-endian reassembly via shifts/ORs, and the `fdt_next_tag` pointer-walk control flow. |
| **O7d** | **Honest cost of O7a that the pass-count hid: it moved 2 tests from exit-code to timeout** | RTL | Full ledger vs the 3/16 baseline — gained `mini_amoadd_w_spin` and `mini_csr_expected_trap` (exit-code → PASS); lost `mini_fdt_lenp_sw` (PASS → timeout); **`mini_fdt_s2_nest` and `mini_fdt_namelen_walk` went exit-code → timeout**, and `mini_fdt_nt_stock` went timeout → exit-code. A timeout carries **less** information than a rejection (no failing check identified, 400k cycles instead of 6k), so mode regressions are a real cost even when the pass count improves. Net: +2 pass, −1 pass, 2 modes worse, 1 mode better. Kept for the OpenSBI witness, still not done. |
| **O7b** | **Resolve the O7a regression properly: bound the valid slot count instead of filtering by pc** | RTL | Clearing the filter for one window admits the *tail* slots of the shifted window — `icache_data` is shifted left by `shamt`, so the top `shamt` halfword slots hold data from beyond the window end. Previously the `pc >= present_exp_q` filter removed them as a side effect; that is why both an over-high seed and a cleared seed break something. The principled fix is I2 itself: after an unaligned entry the realigner must present exactly `slots - shamt` valid slots and fabricate nothing past the window end, at which point the prefix filter is no longer load-bearing for redirects. That deserves a formal contract (the existing realign proof takes `data_i` free and so cannot see slot-count fabrication). |
| **O7a-detail** | evidence for the above | RTL | Traced in `mini_csr_expected_trap`. The bootrom and the whole R3 sequence now work — trap at `0x80000020` with correct cause and `mepc`, handler runs, cookie set, `mret` — but execution resumes at the **next 8-byte (FETCH_WIDTH) boundary** instead of at `mepc`: `mepc=0x80000024` → resumed `0x80000028`; `mepc=0x80000042` → resumed `0x80000048`. The skipped `csrw mtvec,t1` and `lui t3,0xe` are why `t3` becomes `0xe601+0x601=0xec02` and the cookie `bne` is taken. **Aligned redirects work** (`jr s0` → `0x80000000`, trap → handler at `0x80000060`), so the rule is: an unaligned redirect loses the partial window. I3/I7 class. **OpenSBI impact is direct**: `lib/sbi/sbi_expected_trap.S` returns to `mepc+4`, which is rarely window-aligned, so every `csr_read_allowed` probe in `sbi_hart.c` would silently skip the instruction after it. |
| **O8** | The 5 timeouts (hang, no verdict) | L4 | `mini_fdt_nt_frame32`, `mini_fdt_nt_stock`, `mini_fdt_nt_cpus`, `mini_stq_alias_jal`, `mini_fdt_nt_osbi`. All four `fdt_nt_*` hang together, so treat them as one shape, not four bugs. Lower information per run (400k cycles each) — work O7 first. |
| **O5c** | Wire `+fetch_i1_check` into the DI suite once O5b lands | L3 | It is the strongest oracle in the repo and belongs in every regression, but only after the known violation is fixed — otherwise every run drowns in expected violations and the check gets switched off. |
| **O3f** | Harden the build against stale-model builds | L0 | Three stale-instrument traps hit in one session (committed `bootrom.sv` behind `bootrom.S`; the output-cache key in `testharness_proxy.py:823` omits `core/include/*config_pkg.sv`; `grep Verilating` is not a valid "did it elaborate" probe because Verilator is silent on success). Each cost more than the analysis it interrupted. |
| **O3d** | Pin the precise-trap contract at L2 — the first proof outside the fetch plane | L2 | `W2 × issue` and `W2 × commit` are empty cells (M5). All 11 proven contracts are fetch, which is precisely why a green formal gate could not catch this. |

Deliberately **not** queued: another peel, hold-ELF cycle, or TRACE hunt for this class (H7 blocks a
second unrepaid use), and any specialisation of a proof to a package geometry (weakens it).

**AI matrix card (`Xg6lcai`) + licensing — live track (not scaffold-only):**

Phases **P0** scaffold → **P1** CVXIF T0/T1 → **P2** observability/DFT → **P3** T2 descriptor engine →
**P4** decouple `EnableAccelerator` → **P5** PCIe endpoint + virtio → **P6** torch backend.
Parallel **island track I0–I4** (throughput silicon, does not renumber P0–P6):
`architecture/ai-matrix/scaling-100tops.md` §11.
**Progress table + HARD map:** `architecture/ai-matrix/README.md` §0 · `architecture/ai-matrix/hard-tests.md`.
Transport: `architecture/uncore/pcie-endpoint.md`.

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
| **AI-2** | **`g6lc64_server_math_v` violates the superscalar/accelerator assert** | — | **Open, pre-existing, independent of AI work.** Package sets `SuperscalarEn: bit'(1)` / `NrIssuePorts: unsigned'(2)` (`core/include/g6lc64_server_math_v_config_pkg.sv:103-104`) **and** `RVV: bit'(CVA6ConfigVExtEn)` with `CVA6ConfigVExtEn = 1` (`:122`, `:44`); `EnableAccelerator` is *derived* from `RVV` (`core/include/build_config_pkg.sv:37`), so the mutex assert at **`core/cva6.sv:2414`** (`!(SuperscalarEn && EnableAccelerator)`, "Accelerator is not supported by superscalar pipeline") is violated by construction. Survives only because the assert is `translate_off initial` (so it needs Verilator `--assert` to fire) and Ara is normally a stub — a real sim should `$fatal` at t=0. Blocks option D; **shared** with the vector track. **Queued 2nd in the SL resume order** (above), because the offending package is `g6lc64_server_math_v` — the *full-stack Linux-boot bar* that `linux-boot-scale.md` §1 says smt2 work must not regress. That makes the three obvious moves all unacceptable as-is and the decision, not the edit, is the open work: dropping `SuperscalarEn`/`NrIssuePorts=2` changes the I4dp-green package; dropping `RVV` defeats it; promoting the assert into `check_cfg` makes it fail elaboration and takes the golden boot with it. **Investigated 2026-08-29 — the mutex is REAL and structural, and the fix is 2 lines.** The accelerator issue seam is single-port *by construction*: `issue_stage.sv:229-230` hands `acc_dispatcher` only port 0 (`issue_instr_o = issue_instr_iro[0]`, `issue_instr_hs_o = issue_instr_valid_iro[0] & issue_ack_iro[0]`) and `cva6.sv:2139` hands it only `fu_data_id_ex[0]`. Meanwhile **nothing stops an `ACCEL` op from being acked on port 1**: the `fu_busy` case (`issue_read_operands.sv:459-485`) has no `ACCEL` arm, so `fu_busy` is always `0` for it; the per-port force-busy block (`:389-394`) forces only `.csr`/`.cvxif` for `p>=1`; and the FU-valid case (`:1023-1061`) sets no FU valid for `ACCEL` at all. An accelerator instruction acked on port 1 is therefore never dispatched to Ara and never written back, so its scoreboard entry never completes and **commit deadlocks**. This has nothing to do with Ara being a stub, so "narrow the assert for the stub path" is dead. **Cheap correct fix that none of the earlier framings saw:** make the already-declared-but-never-used `fus_busy_t.accel` field (`:157`) live — add `fus_busy[p].accel = 1'b1;` beside the existing `.csr`/`.cvxif` lines at `:392-394`, and `ACCEL: fu_busy[i] = fus_busy[i].accel;` to the case at `:459-485`. That pins every accelerator op to port 0, where `issue_instr_o` and `fu_data_id_ex[0]` are correct, making `SuperscalarEn && EnableAccelerator` legal **by construction** — no `_v` config change, no `I=1` re-soak, no loss of RVV — after which `cva6.sv:2414` is narrowed with a recorded reason instead of being violated. **Deliberately NOT landed here:** that block *is* the dual-issue throttle, `core-fetch/SPEC.md` §9.6 says "do not touch the issue throttle (RC1/RC4) until R6–R11", and it would touch both I4dp-green Linux boots. Land after S1 behind gates: I4dp `_v` + `ooo_server` 200M `tohost=0`, `ara-vector-cosim`, `ara-vector-path`, `mc-spo-veri`. |
| **AI-3** | T2 descriptor engine address-checking | P3 | **Landed in spine.** `g6lc_ai_addr_check` per-queue `[base,limit)` + R/W; engine checks ptr_a/b/c/scale/done before accept. Standalone smoke rejects OOR and W-only. Still open: scrub/bank-partition between queues; bind checker in front of real DMA master. |
| **AI-S0** | ~~Size the 100-TOPS class~~ | I0 | **Done — `architecture/ai-matrix/scaling-100tops.md`.** Froze the definition (100 TOPS ≙ dense INT8, peak, 2 ops/MAC, no sparsity/INT4 multiplier); derived DRAM BW = (2/T)×MAC-rate ⇒ 391 GB/s at blocking T=256; machine balance ≈125 MAC/byte. Reversed three draft positions: chiplets **deferred** behind a die-size gate, island knobs **out of** `cva6_cfg_t`, on-die SRAM **8–32 MB** not 32–128 MB. |
| **AI-S1** | ~~SKU decision: latency/decode vs throughput/serving~~ | I0 | **Closed — BOTH, STAGED: latency SKU first, throughput SKU by cluster replication** (`scaling-100tops.md` §5.1). Rationale: at `T=512` the throughput SKU needs only 195 GB/s of GEMM bandwidth, while the latency SKU must buy ~400 GB/s anyway for batch-1 weight streaming — **so the expensive subsystem is built and measured first and covers both**, and adding compute later is pure cluster replication. Track order changes to I1 → I3 → (latency tape-out) → I2. Five binding conditions in §5.1: `T`/accumulator/DRAM frozen at I1; cluster is the only replication unit and the NoC cut line is set at I1; capability window ships at I1; cluster-**cooperative** blocking from the first cluster (independent per-cluster blocking collapses effective `T` to 64 and demands ~1.6 TB/s); both SKUs quoted with §12 metrics. |
| **AI-S2** | Seam decoupled from throughput target | I0 | **Recorded.** ~99.7% of island arithmetic never crosses a core seam, so the card SKU may ship on **seam B**; option D is now a small-SKU/latency feature. **Consequence: AI-2 is off the card's critical path** (still blocks the vector track). `README.md` §2 amendment. |
| **AI-S3** | Island RTL: cluster → memory → (latency SKU) → NoC/N clusters → PD | I1, I3, I2, I4 | **I1 partial + I3-lite live; HARD + host green.** AccTile/PeLanes 256; CPL FIFO multi-claim; peak 256³ **83.7k cy**. HARD suites: **narrow** / **ci 27/27** / **peak** — `hard-tests.md`. **`tensor virt-impl --impl hard --suite narrow --require-hard` PASS**. virt-ai-pcie + pytorch soft. **SMT attunement:** dual-hart multi-thread host workers tracked under **SL-T** (`smt2-ai-tensor-linux.md`) — do not claim multi-CPU AI green until soft-ladder SL-C. **Next (scaling):** I3 measured BW → I2 cluster replication; kernel UIO; NoC. Do **not** grow AccTile with TOPS. |
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
    **Open:** `b1-fdt-lenp-store` / `PEEL_FDT_GETPROP` (iter-014). Soft getprop default. S4 residual closed as IAF/test-address (iter-013). Current 12-thread B pin is `fdt_ro_probe_` at `0x800125d8`/`0x80012638` with `a5=0x8001e000` (pre-load value, `lbu` not retired); `--threads=1` build (`work-ver-smt2-fw64-B-vt1`) gives a clean `npc0=0x800138d8` (second half of 32-bit `beqz s4` at `fdt_getprop_by_offset+0x24`, `0x800138d6`, `addr[1:0]=10`), proving the residual is a `core/fetch_B/instr_realign` 32-bit fetch-word straddle. With `CVA6_TRACE=1` the 1-thread 2M pin moves to `npc0=0x800137b0` (`bltu s1,s2` in `fdt_path_offset_namelen`), showing the failure is highly sensitive to observer / Verilator evaluation order. `mini_fdt_rdxrs1` (rd==rs1 FDT header load) and new `mini_fdt_ro_probe` (direct `fdt_ro_probe_` blob call) both PASS, so the failure is contextual and timing-sensitive. `+fetch_snap` (sim-only `translate_off` observer) masks the `fdt_ro_probe_` hang and moves it to a later `fdt_path_offset_namelen` loop, suggesting an uninitialized-signal / Verilator evaluation-order race in `core/fetch_B` or a load-unit handshake sensitive to it. `work-ver-smt2-fw64-legacy` build fixed and `mini_fdt_nt_osbi` passes on it, but `PEEL_FDT_NEXT_TAG=1` on legacy fails later in `sbi_heap_init` (`npc0=0x8000f3f8`, partial cookie `0x51b1c001`).
    Bisects all negative (reverted): dual-commit, STQ-nofwd, force SI issue — same pin.
    **I4au soaked** — natural `fdt_next_tag` cookie `51b1babe` dual-confirm.

**2026-08-30 pass (b1-fdt-lenp-store residual):** Targeted `core/fetch_B/frontend.sv`
`leftover_branch_bp_fire` (bp_fire && serving_unaligned && slot0 is Branch) preserves
the carry on a predicted-taken split conditional branch so a mispredict-fallthrough can
rebuild the RVI. Rebuild `work-ver-smt2-fw64-B-vt1-trace`; DI improves from 11/16 to
13/16 (new passes: `mini_fdt_check_prop_nest`, `mini_fdt_namelen_walk`); the same two
pre-existing fails (`mini_csr_expected_trap`, `mini_stq_flush_fwd`) remain. The
`PEEL_FDT_GETPROP=1 PEEL_FDT_NEXT_TAG=1` OpenSBI soak on 12-thread B-trace moves from
`npc0=0x80012640` to `npc0=0x80013792` (`fdt_path_offset_namelen` loop) with
`a0=0xaf5`. A 1-thread B build (`SOFT_LADDER_VERILATOR_THREADS=1`) reproduces the
original `npc0=0x80012640` / `a0=0xaf5` / `ra=0x80013792` pin. `CVA6_TRACE_FILE` with
`log gpr` shows `a0` being assembled as `0xaf5` (FDT totalsize) from bytes while `a5`
flips from `0x2f` to `0x8001e000`, indicating the `fdt_ro_probe_` split-jal entry is
not completing `c.mv a5,a0` before the first `lbu` uses `a5`. The residual is therefore
a **split-jal / split-branch realignment race in `instr_realign.sv`** rather than a
simple branch-predict kill. Next: inspect `instr_realign.sv` `carry_ok`/`leftover_next`
against the `fdt_ro_probe_` entry (`0x80012544`, 8-byte block offset 4) and the jal to
it (`0x8001378e`/`0x80012ece`, 6 mod 8 split). Local `./build.sh verify` attempted but
unavailable (missing Verilator); remote build + DI + soak is the current evidence.
**Update:** A pre-shift removal + `instr_realign` `hw[cur + hw_first]` offset trial was
reverted. The original pre-shift contract is restored; remote DI is 11/16 with the
targeted `mini_fdt_lenp_sw`, `mini_fdt_nt_frame32`, `mini_fdt_nt_stock` now passing.
Residual failures: `mini_csr_expected_trap`, `mini_fdt_check_prop_nest`,
`mini_fdt_next_tag_lbu`, `mini_stq_flush_fwd`, `mini_fdt_namelen_walk`.
    **PEEL `129f8`/mcause=4** (a0=9). **I4cf last keep** (s5↔a0; peel unchanged). **I4ca reverted.** **I4x / fdt `c.mv` families exhausted.** **Next:** `architecture/multi-threading/soft-ladder/COMPLETION.md` stage 0 (`mini_fdt_a0_is_fdt` then G0). Do not start I4cg.
    Suites: `soft-ladder-opensbi-soak.sh`, `soft-ladder-di-regress.sh`.
    **Priors:** `architecture/multi-threading/soft-ladder/*` · `smt2-bringup.md` ·
    `fdt-topology-soft-ladder.md` · `core/{issue_stage,frontend/frontend,scoreboard,commit_stage}.sv`.

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

**Open upkeep finding (review pass 2026-08-29, discipline 3).** `.licensing-tiers` carries no rule
for `core/Flist.*`, so the LibreCore-authored flists resolve to the default `U **` ("someone else's
property") while their own headers declare `MIT` (`Flist.fetch_B`, `Flist.fetch`, `Flist.smt_legacy`)
or `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` (`Flist.g6lc`). Nothing is mislicensed today —
`DEFAULT_TO_FILE_LICENSE` means the declared header governs — but the tier map does not *classify*
them, which is precisely the case the `U **` default exists to surface, and `Flist.g6lc` asserting
tier-R terms from a tier-U path is `E-TIERCONFLICT`-adjacent. Resolution is to add the rule
(`T core/Flist.*` beside the existing `T vendor/ara/Flist.ara`, plus `R core/Flist.g6lc` if that one
is genuinely tier R), **not** to rewrite the headers down to the default. `.licensing-tiers` is
policy, so this is a rights-holder decision and was deliberately left unedited.

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

## Soft-ladder cleanup / retirement (2026-08-22)

Retired incomplete/unrelated artifacts outside the `smt_legacy` / `fetch_B` tracks. Moved to `.aside-untracked-20260812-115339/soft-ladder-retired-20260822/` before deletion where safe:

- **Moved aside:** `architecture/g6lc_fetch_dbg.sv` (stray copy), `architecture/multi-threading/soft-ladder/firmware-boot-principles.md` (duplicate of tracked `architecture/firmware-boot-principles.md`), `software/smt2-linux/soft-ladder/cf1_e1_di1_vs_smt2.sh`, `software/smt2-linux/soft-ladder/cf1_e1_raw.sh`, `software/smt2-linux/soft-ladder/_mini_out/` (old mini/fetchb debug logs and scripts), `core/smt/g6lc_ex_id.sv` (untracked duplicate; `core/smt` still holds tracked `g6lc_fetch_{pkg,dbg}.sv`).
- **Removed old Verilator build dirs:** `work-ver-smt2-fetchb`, `work-ver-smt2-fw64b/c/d/e/f`, `work-ver-smt2-new`, `work-ver-smt2-si`, `work-ver-smt2-si-c14`, `work-ver-smt2-slstd`, `work-ver-smt2-slfix.bak-i4bb`.
- **Removed old build products/logs:** `software/smt2-linux/soft-ladder/build/*.log`, `*.nohup`, empty `di-*/soak-*` dirs, and stale `fw_payload_r3a_c15_plat_skip.*.elf` variants (`held-nobyoff`, `peel-getprop`, `pmp8cut`, `cold-regress-20260811`). Kept current `pin-bc7ed11d.elf`, `held.elf`, `fw_payload_r3a_c15_plat_skip.elf`, and `fw_payload_diag.elf`.

**Kept in place:**
- Current harness dirs: `work-ver-smt2`, `work-ver-smt2-fw64`, `work-ver-smt2-fw64-B`, `work-ver-smt2-fw64-legacy`, `work-ver-smt2-slfix`.
- `core/fetch/` — untracked future handoff-B frontend per `architecture/firmware-boot-principles.md`. Not part of `smt_legacy`/`fetch_B`; left for Phase 2/capability work (do not delete without explicit go-ahead).

**Next:** continue `b1-fdt-lenp-store` as a `core/fetch_B/instr_realign` 32-bit RVI straddle residual; build a directed mini that reproduces the `npc0=0x800138d8` misalignment. Legacy harness build is now fixed.

## Build-platform / SMT2 × ai-tensor / g6lc_qemu continuation (2026-08-30)

- Fixed `core/smt/` → `core/smt_legacy/` path drift in the SMT2 track scripts:
  - `verif/regress/smt2-ai-tensor-track.sh` (regfile, CSR bank, issue barrier)
  - `verif/regress/dual-hart-ci.sh` and `dual-hart-ci.ps1`
  - `verif/regress/smt-linux-boot-path.ps1`
- `smt2-ai-tensor-track.sh fast` green except `g6lc64_smt2 lint` (no local verilator).
- `smt2-ai-tensor-track.sh hold` and `peel` both reach the `51b1babe` cookie on `work-ver-smt2-slfix` (with the held / pin ELF).
- `smt2-ai-tensor-track.sh tensor` and `mt-soft` pass (PyTorch Device virt-card + sequential dual invoke).
- `smt2-ai-tensor-track.sh di` runs 6/7 FDT minis; the one `mini_fdt_next_tag_lbu` false `tohost=1` FAIL is the known Verilator/HTIF `exit_code` convention in `corev_apu/tb/g6lc_tb.cpp` (DTM branch prints `*** FAILED *** (tohost = 1)` even though `tohost=1` is the pass value), not an RTL failure.
- g6lc_qemu:
  - `g6q run --backend qemu --target g6lc64_smt2 --expect SMT2-OSBI-OK` boots the generated B1 machine.
  - `--tcg-tuning tuned` and `--icount 1` both reach the same boot gate (Q8).
  - `g6q diag --uarch-out out/uarch.json` writes model-derived D2 counters (Q7).
  - `g6q run --record out/smt2-trace.json --timeout 45 --expect SMT2-OSBI-OK`
    reaches the OpenSBI boot gate and writes a valid 1.5 GB RecordFile (Q5/D1).
    The B2 trace plugin now batches records per hart (64 Ki records) and uses a
    `GMutex` for thread-safe MTTCG flushes; fixed the earlier
    `g_ptr_array_add: assertion 'rarray' failed` crash by lazy-initialising the
    instruction array in `g6lc_tb_trans`.
  - `g6q run --backend qemu --plugin ...-pmu.so,out=smt2-pmu.json` reaches the
    boot gate and writes a 6.8 KB PMU counter artifact (Q7 D2).
  - `g6q run --backend native --image smoke.bin` runs a bare-metal UART payload
    and prints `OK`; `--record` + `--replay` round-trip with no divergence (Q3/Q5).
- SMT2 soft-ladder:
  - `smt2-ai-tensor-track.sh fast` passes 21/22; only `g6lc64_smt2 lint` fails
    (no local Verilator).
  - `soft-ladder-opensbi-soak.sh` with `work-ver-smt2-slfix` + pinned ELF reaches
    `CLASSIFY=SUCCESS cookie 51b1babe` at t=83968 cycles.
  - The `work-ver-smt2-fw64-B` harness does not reach the cookie within 12 M
    cycles / 1800 s; `work-ver-smt2-slfix` completes in <60 s. Frontend/harness
    divergence to be investigated on the RTL SMT2 track.
  - `smt2-ai-tensor-track.sh peel` (PEEL_FDT_GETPROP=1) and `hold` (held
    oracle) both pass 21/0 and reach the cookie at t=83968 on
    `work-ver-smt2-slfix`.
- SMT2 dual-hart:
  - `smt2-ai-tensor-track.sh dual` passes all artifact/preflight gates; only
    `g6lc64_smt2 lint` fails (no Verilator).
  - `dual-hart-ci.sh` with `DUAL_HART_LIVE=1` on `work-ver-smt2-slfix` passes
    live `smt_dual_park`, `smt_peer_tohost`, `smt_dual_active`,
    `smt_dual_concurrent`, and `smt_dual_wfi_timer`.
- AI tensor / mt-soft:
  - `smt2-ai-tensor-track.sh tensor` passes 21/0 (Device virt-card cases only
    because PyTorch is not installed).
  - `smt2-ai-tensor-track.sh mt-soft` passes 21/0 (sequential dual invoke).
- SMT2 soft-ladder DI:
  - `smt2-ai-tensor-track.sh di` passes 6/7 mini FDT tests on
    `work-ver-smt2-slfix`; `mini_fdt_next_tag_lbu` prints
    `*** FAILED *** (tohost = 1)` due to the known Verilator/HTIF `exit_code`
    convention in `corev_apu/tb/g6lc_tb.cpp`, not an RTL failure.
- AI tensor hard (RTL):
  - `smt2-ai-tensor-track.sh hard` passes 21/0: `tensor virt-impl --impl hard`
    on `g6lc64_ai` with `work-ver-ai` passes both soft (Device/PyTorch) and hard
    (Verilator RTL) phases; `ai_island_mmio_smoke` and `ai_gemm_s8_smoke` both
    SUCCESS.
- SMT2 fetch divergence:
  - The passing `work-ver-smt2-slfix` harness is built with `core/Flist.cva6`
    (A/legacy fetch); the failing `work-ver-smt2-fw64-B` harness is built with
    `core/Flist.fetch_B` (B fetch). Same ELF, same timeout: cookie on `slfix`,
    no cookie on `fw64-B`. Old `work-ver-smt2` is stale and prints plusarg help.
- DTS / boot path:
  - Fixed `corev_apu/bootrom/ariane-smt2.dts` `smt-product-closeout` node: added
    `reg = <0x0 0x0 0x0 0x0>;` and `@0` unit address to silence `dtc` warnings.
    `smt-linux-boot-path.sh` passes with no warnings.
- SMT2 fetch_B S4 residual:
  - Reproduced the fetch_B/IQ leftover pointer-liveness bug with
    `verif/tests/custom/multicore/mini_fdt_nt_ptr0.S` on `work-ver-smt2-fw64-B`:
    `tohost = 122928` (`0x1E030`) after 514 cycles, matching
    `architecture/multi-threading/soft-ladder/ITERATION.md` iter-013.
  - Real OpenSBI context with `PEEL_FDT_NEXT_TAG=1` on `work-ver-smt2-fw64-B` also
    fails to reach the `51b1babe` cookie within 2 M cycles / 300 s; trapdump shows
    `0x51b1c001` cave value and `plat_hc=2`/`coldboot_done=0`.
  - `work-ver-smt2-slfix` (2026-08-21 build) does not reproduce the same S4 mini
    signature (`tohost = 76180`/`ra`), confirming the local harness is stale
    relative to the ITERATION.md baseline.
  - `g6lc_fetch_dbg` (`+fetch_snap`) trace: `c.jr a0` at `0x80012994` is
    resolved with `a0=0x8001e030` but the frontend issues `fetch_addr=0x80000000`
    (boot address) immediately after; the eventual `0x8001e030` demand returns
    all-zero data. Root cause narrowed to `JumpR` prediction / BTB-pend state in
    `core/fetch_B/frontend.sv` or the I-Cache refill for the redirected target.
    Caveat: the `work-ver-smt2-fw64-B` binary is dated 2026-08-25 and may predate
    the `core/fetch_B` duplicate drop / current `btb` source; the `btb` prediction
    of `0x80000000` for an unexecuted `c.jr a0` is unexpected for a cold BTB and
    must be reproduced on a fresh build.
- `python tools/g6q.py check` remains green.
