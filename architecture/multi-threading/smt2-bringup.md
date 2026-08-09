# SMT2 bring-up notes (U6.1 follow-on)

Profile: `core/include/g6lc64_smt2_config_pkg.sv` (`NrHarts=2`, `SMT_HYBRID`).

## Software view

| Item | Value |
|------|--------|
| `mhartid` thread *h* | `hart_id_base + h` (base from SoC pin) |
| ISA | Same string both threads; SBI/OpenSBI treat as two harts |
| CLINT | Two MSIP/MTIMECMP slots if `NR_CORES`/`NR_HARTS` covers SMT |
| Linux | Two `cpu@` nodes with consecutive hartids; enable only after OpenSBI knows both |

## What the RTL guarantees

1. **Per-hart arch state:** RF banks, CSR banks, PC bank, RAS banks, GHR banks  
2. **Fine-grain switch:** IF flush + unissued drop; EX/scoreboard drain; BP preserved  
3. **Commit isolation:** CSR write path keyed by `commit_instr.hart_id`  
4. **Fetch view:** Privilege/MMU CSRs muxed by active fetch hart  

## Recommended bring-up sequence

1. Lint/synth with default `NrHarts=1` (identity) — always green  
2. Select `g6lc64_smt2_config_pkg` for sim; boot bare-metal on hart 0 only  
3. Park hart 1 in WFI (`wfi` loop at reset vector +1 page or secondary entry)  
4. Exercise switch-on-miss: force D$ misses on hart 0, confirm peer fetch  
5. Dual-thread `rdcycle` / store-buffer litmus before Linux  
6. OpenSBI: set `expected_harts` / domain for two harts  
7. Linux: `maxcpus=2` smoke  

## Dual-hart Linux / CI sketch

**DTS of record:** `corev_apu/bootrom/ariane-smt2.dts`  
**Validate against Linux tree:** see `dts-linux-smt.md` (fetch + `validate-cva6-dts.ps1`).

```
# 0) .\build-platform\scripts\fetch-linux-dts.ps1
#    .\build-platform\scripts\validate-cva6-dts.ps1
# 1) dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
# 2) OpenSBI: expected_harts = NrCores × NrHarts, embed DTB
# 3) Boot Linux maxcpus=2 earlycon=… root=…
# 4) cat /proc/cpuinfo ; taskset -c 0,1 stress-ng --cpu 2
```

**RTL path (landed):** CLINT `NR_HARTS=NrCores×NrHarts`, per-bank timer/IPI/PLIC into CSR
banks, `mhartid=base+h`, decode `irq_active=irq_i[smt_active_hart]`.  
**Gates:**
- R0 DTS/RTL: `verif/regress/smt-linux-boot-path.{ps1,sh}` (`smt-linux-boot-path`)
- R1–R3 rootfs track: `verif/regress/smt-linux-rootfs.{ps1,sh}` (`smt-linux-rootfs`)
  — dual-park directed + preflight; set `CVA6_LINUX_PAYLOAD` for full image sim  
  — plan: `architecture/multi-threading/smt-linux-rootfs.md`

CI job (optional, not default verify):

| Stage | Command / note |
|-------|----------------|
| Lint | `g6lc64_smt2` or `g6lc64_ooo_server` (NrHarts=2) |
| Bare-metal | `smt_dual_park.S` (hart1 WFI; hart0 self-check) |
| SBI | OpenSBI domain with 2 harts |
| Linux | boot to prompt; `cat /proc/cpuinfo` shows 2 (`CVA6_LINUX_PAYLOAD` / cva6-sdk) |

Combine with **H** (`server_math`) only after SMT bare-metal is green — KVM-on-SMT is out of scope for bring-up.

## Known limits

- BHT/BTB tables are **shared** (only RAS + GHR banked) — mild cross-hart BP pollution  
- Dual-commit of two different harts in the same cycle is not specialized (single CSR port)  
- Full KVM-on-SMT not a bring-up target; use H package separately  

## Debug tips

- RVFI: `mhartid` differs per bank; trace `smt_active_hart` / `smt_switch`  
- If hang: check both CSRs not in permanent WFI with no peer IRQ  
- Mispredict after switch should only zero the **active** RAS/GHR bank

## Dual-hart bare-metal Variane (live residual)

Linux Verilator **5.008** builds `work-ver-smt2`
(`make verilate target=g6lc64_smt2 ver-library=work-ver-smt2`).

**Fix (core):** SMT thread select holds switches until the primary has committed
outside the boot ROM page and for a short DRAM grace (`SMT_DRAM_GRACE` in
`core/cva6.sv`). Mid-bootrom / early-DRAM switches were PC-bank restoring past
bootrom `jr s0` into zeros (`ILLEGAL_INSTR` @ 0x10020).

**Green:** bare `mini_tohost` + `smt_dual_park` on `work-ver-smt2`; Spike dual-park;
`DUAL_HART_LIVE=1 DUAL_HART_LIVE_HARD=1 bash verif/regress/dual-hart-ci.sh`.

**Peer post-grace green:** `smt_peer_tohost` (hart1 tohost PASS after primary
WFI) on `work-ver-smt2` after: delayed switch pulse, ready≠sticky-miss, miss-switch
blackout, longer `SmtFetchQuantum`, bootrom all-harts→DRAM (no mhartid WFI park).

**Scheduler holds (`cva6.sv` / `g6lc_thread_select.sv`):**
- Primary DRAM grace before first peer switch
- Sticky per-hart first DRAM exit (capped ~128 cycles) so peer finishes bootrom
- Freeze quantum/starve during hold (prevents starve-steal when hold drops)

**Hard dual-active gate:** `smt_peer_tohost` (primary WFI yield → peer tohost).

**WFI halt vector:** `g6lc_smt_csr_bank.hart_halt_o` → `smt_hart_halt` (was sticky-active-only; dual-WFI timer wake hung).

**RTL isolation landed:** commit RF writes banked by `commit_instr.hart_id` (was stuck
at hart 0); RAW hazards hart-qualified in `raw_checker` (no cross-hart forward/stall).

**Still open:** concurrent `smt_dual_active` (peer tohost while primary stays ready —
no WFI). Live still times out with primary FAIL before peer scores; Spike `-p2` OK.
Also open: dual-WFI without IPI; OpenSBI dual-hart + Linux R3 Image lab.

**Hold policy (`cva6.sv`):** primary DRAM grace + hold while active NPC is in bootrom
(unless active is WFI/halted — escape so a peer can run).

**Scheduler (landed):** quantum zeroed under hold (full window on release); starve freeze under hold; sticky per-hart first DRAM exit (capped); RF write hart banking + hart-qualified RAW.
**Hard dual-active:** `smt_peer_tohost` / `smt_dual_active` (WFI yield after dual-ready burn).
**Concurrent green:** `smt_dual_concurrent` (no-WFI peer tohost) live PASS after one-shot first-activation exclusive window (`SMT_FIRST_ACT_EXCL=512` in `core/cva6.sv`) + larger `SmtFetchQuantum=32`. Hard gates remain park / peer_tohost / dual_active.

**Pure concurrent residual:** closed on live — `smt_dual_concurrent.S` PASS (first-act exclusive + Q=32). Remaining soft: OpenSBI dual-hart + Linux R3 Image lab.

**Dual-WFI timer gate:** `verif/tests/custom/smt/smt_dual_wfi_timer.S` — both harts MTIE + CLINT mtimecmp, no MSIP; live PASS after bank-vector halt.

**OpenSBI R3a (Spike):** greened via opensbi-linux-boot / dual-hart-residual (Domain0 HARTs 0*,1* + SMT2-OSBI-OK).
**R3a RTL:** open — post thrash-fix both harts `_start_hang` ~65k cyc (no UART); Spike R3a green.
**R3b Linux Image:** external (contract gate soft-skip without Image).
**Residual suite:** erif/regress/dual-hart-residual.sh.

**HYBRID miss thrash fix:** miss-switch requires sustained stall (`stall_age >= 32`) + blackout 16; smt2 Q=128, starve=64. Stopped dual-ready thrash every ~8 cycles (OpenSBI stuck in sbi_strchr).

**SMT cold-boot exclusive:** SMT_COLD_EXCL=200000 holds switches so hart 0 alone owns early OpenSBI (shared temp stack / lottery). Concurrent burn extended past this window.

**R3a RTL status:** hart 0 still reaches _start_hang ~9k commits without ever returning from w_platform_init (dasm: call@6965 → hang@9255, no fter_plat); FDT magic@0x8001e000 OK; no RVFI exceptions; bare dual moswap lottery PASS; Spike R3a PASS. Next: stack/ra corruption or FDT path failure mode inside w_platform_init on CVA6.

## R3a RTL hang root-cause notes (2026-08-07)

Trapdump (`mtvec` early = `_start_hang`, `CVA6_TRAP_DUMP` TB dump of DRAM+0x1000):

| Build | mepc | mcause | mtval | Notes |
|-------|------|--------|-------|-------|
| dual-issue + short hang stub | `0x80012e9c` (`fdt_get_property_by_offset_` `sw a5,0(s2)`) | 6 store misalign | `0x80012b2a` (code, inside `fdt_check_node_offset_`) | `lenp` is a code address, not stack |
| single-stack extended stub | `0x80022768` (`thead_generic` **object**) | 2 illegal instr | `0x27d8` | jumped into platform_override **data** as code |
| Spike | — | — | — | Domain0 HARTs 0*,1* + `SMT2-OSBI-OK` |

Interpretation:
- Stack base itself looks healthy when GPRs are dumped (`sp≈0x80046f70`).
- Fault family matches hang-6/7 OpenSBI FDT walk on dual-issue: register/pointer corruption mid FDT or platform match.
- Cold-excl keeps one hart early, so this is **single-hart dual-issue**, not SMT RF cross-talk.
- Diagnostic: force `g6lc64_smt2` single-issue (`SuperscalarEn=0`, `NrIssuePorts→1`) and re-run `fw_payload`.
### Single-issue diagnostic (2026-08-07)

Built `work-ver-smt2-si` with `SuperscalarEn=0` / `NrIssuePorts→1` (config temporarily
flipped then restored). Result after 1.5M cycles:

- `platform.hart_count` stayed **0x80** (ELF default) — `fw_platform_init` never stored
  the real count (hang-7 family, not hang-6 dual-only).
- No exception dump (fail-WFI / mtvec hang stubs never wrote DRAM+0x1000).
- No OpenSBI / `SMT2-OSBI-OK` UART marker.

Conclusion: R3a RTL is **not** unblocked by single-issue alone on g6lc64_smt2. Dual-issue
faults earlier (store-misalign / illegal into `thead_generic` data); single-issue stalls
later without completing platform_init. Same FDT-walk residual as multi-core hang-6/7.
### Post-bp sequential drop attempt (2026-08-07) — reverted

Tried gating `instruction_valid` into `instr_queue` after predicted taken CF
until the target fetch block is presented (`frontend.sv`), including Jump-only
variant. OpenSBI still trapped at `thead_generic` (mcause=2, `hart_count=0x80`).
**Bare `smt_dual_concurrent` regressed** (timeout vs prior SUCCESS @~200k).
Reverted; do not re-land without concurrent + peer soak.

Residual R3a still needs a dual-issue FDT residual fix that does not starve
short control-flow (hang-6 Jump fallthrough class, without broad IQ drop).
### R3a force-platform_init probe (2026-08-07)

Binary-patched `fw_payload` (`tmp-dual-ci/fw_payload_r3a_h1.elf`):

1. `platform_override_modules_size = 0` (skip thead_generic match).
2. `fw_platform_init` replaced with stub: `hart_count=1`, `index2id[0]=0`,
   coldboot bitmap all-ones, heap_size=0x20000, return FDT arg.
3. Progress cookies in DRAM: `0x51b10000` enter stub, `0x51b10001` leave stub,
   `0x51b10002` enter `sbi_init` (trampoline at `0x80000420`).

**Result @800k–5M cycles (dual-issue `work-ver-smt2`):**

| Cookie / field | Value | Meaning |
|----------------|-------|---------|
| `0x1000` | `0x51b10000` | force stub entered |
| `0x1008` | `0x51b10001` | force stub returned |
| `0x1010` | `0x51b10002` | **`sbi_init` entered** |
| `plat_hc` | `1` | hart_count sticky |
| UART / OpenSBI banner | none | hang inside `sbi_init` (no trap) |

So the dual-issue FDT fault that killed stock `fw_platform_init` is **bypassable**,
and cold-boot reaches `sbi_init`. Residual hang is **later OpenSBI FDT/console/
domain init** (same dual-issue FDT family), not SMT thrash or platform_init alone.

Bare concurrent remains green with `+tohost_addr=0x80001000` (~200k SUCCESS).


### R3a phase map (force-init + norest + lab stubs, 2026-08-07 cont.)

**Authoritative tree:** `E:\cva6` (this worktree may lag).

#### Breakthroughs

1. **`fdt_reset_drivers_size=0` in `.data` (file off `DATA_OFF=0x24000`, VMA `0x80040000`)**
   advances past `fdt_reset_init` into `sbi_hart_init`. Earlier zero used text map → no effect.

2. **`sbi_hart_init` fails into `sbi_hart_hang` with `a0 = -9` (`SBI_ERR_NO_SHMEM`)**
   before `sbi_hart_reinit`. Feature-detect / `fdt_parse_isa_extensions` path (FDT + CSR
   expected-trap probing). Lab: ret0-stub `sbi_hart_init`.

3. **Phase trampolines must NOT start at `0x80000420`** — that is inside `_trap_handler`
   and corrupts expected-trap / general traps. Safe home: dead body of overwritten
   `fw_platform_init` (`0x800072ca` + stub … `+746`).

4. **UART MMIO at `0x10000000` hangs the AXI fabric** in this SMT2 Variane run (force
   `uart8250_init` never returns). `InclUART=0` + `mock_uart` is elaborated, but a full
   8250 init sequence still wedged. Lab: DRAM putc ring @ `0x80001100`, cursor @ `0x800010f0`.

5. **Ticket `spin_lock` (`amoadd.w.aqrl`) appears to wedge printf** — cookie at
   `sbi_printf` entry, no putc. Lab: `spin_lock`/`spin_unlock`/`spin_trylock` → ret/success.

6. **Unstubbed `sbi_printf` floods `R/B Response Errored`** (testharness asserts) —
   dual-issue / FDT string walk residue. Lab: printf → append `"OSBI\n"` to DRAM ring.

7. **With lab stubs, cold boot reaches the OpenSBI banner printf loop**
   (`fw_payload_r3a_banner.elf` @4M cycles):
   ```
   [dram-console] (149 bytes) HI!\nOSBI\nOSBI\n... (×~29)
   ```
   Hang after banner is consistent with **missing IPI/timer devices**
   (`sbi_ipi_get_device` / `sbi_timer_get_device` → NULL → error path). No AXI assert spam.

#### Lab stub set (banner ELF)

| Stub | Purpose |
|------|---------|
| force `fw_platform_init` | hart_count=1, coldboot, skip overrides |
| zero `fdt_reset_drivers_size` / override modules size | skip FDT reset match |
| ret0 `sbi_hart_init`, `sbi_sse_init`, `sbi_pmu_init`, `sbi_dbtr_init`, `sbi_fwft_init`, `sbi_domain_finalize`, `sbi_ecall_init` | skip FDT/CSR-heavy fails |
| force `sbi_console_init` → `sbi_console_set_device(&uart8250_console)` | bind putc without UART MMIO |
| DRAM `uart8250_putc` | banner capture without AXI |
| nop spinlocks | avoid AMO ticket hang |
| stub `sbi_printf` → DRAM `"OSBI\n"` | avoid printf bus errors |

TB: `CVA6_TRAP_DUMP` dumps cookies + `[dram-console]` (cursor VA or offset).

#### Residual real RTL work (not lab stubs)

1. **Dual-issue FDT residual** — root of platform_init, reset match, ISA parse, serial match, printf string walks.
2. **AMO / ticket spinlock** — verify `amoadd.w` + acquire barrier under SMT dual-issue.
3. **UART path** — why `uart8250_init`/`set_reg` never completes with mock_uart.
4. **`sbi_hart_init` / CSR expected-trap detect** — real return `-9` without stub.
5. **IPI/timer (ACLINT) registration** — so post-banner `get_device` is non-NULL and boot can finish / hand off payload.

Bare dual-hart concurrent remains green with `+tohost_addr=0x80001000`.

### R3a banner+trap residual (2026-08-07 cont. 2)

#### Banner path (lab stubs) — confirmed

`fw_payload_r3a_banner2/3.elf` with DRAM console + nop spinlocks + ret0
hart/sse/pmu/dbtr/fwft/domain/ecall/pmp + force `ipi_dev`/`timer_dev` + stub printf:

```
[dram-console] HI!\nOSBI\n × ~27
```

Hang is **`sbi_trap_error` → `sbi_hart_hang`** at `sbi_trap_handler+0x59e` (`0x80006372`),
not a clean post-banner `get_device` NULL path.

#### Trap diagnosis

| Field | Value | Meaning |
|-------|-------|---------|
| hang `ra` | `0x80006376` | return into trap_handler after `jal sbi_hart_hang` |
| CSR `mcause` (at hang) | `2` then `3` | illegal, later breakpoint |
| illegal log `mepc` | `0x358` | **not** an OpenSBI text address (PC corruption or bad tcntx read) |
| illegal log `mtval` | `0x7b302573` | SYSTEM/`csrrs a0, 0x7b3, x0` — **dscratch1**; **no such insn in fw ELF** |

So the banner-phase hang is an **unhandled exception** after partial cold-boot, with either:

1. **PC corruption** to low memory (`0x358`) fetching garbage that decodes as a debug CSR, or
2. **Stale/wrong trap context** while a real illegal fires elsewhere.

Skipping illegal (`mepc+=4; return 0`) still ends in `sbi_trap_error` (breakpoint path) —
not a stable recovery.

#### Lab vs real RTL (updated priority)

| Lab only (do not ship) | Real RTL residual |
|------------------------|-------------------|
| force platform_init, zero FDT reset table | dual-issue FDT residual (root) |
| ret0 hart/sse/pmu/dbtr/domain/ecall/pmp | real `sbi_hart_init` / CSR expected-trap detect |
| DRAM putc, stub printf, nop AMO ticket locks | UART MMIO + `amoadd.w` ticket spinlock under SMT |
| force `ipi_dev`/`timer_dev` pointers | ACLINT cold_init + FDT clint match |
| skip-illegal / trapdump cookies | precise trap after dual-issue FDT fix |

**Do not treat banner stubs as R3a green.** They prove sbi_init can reach the
banner printf *region* if FDT/CSR/AMO/UART hazards are removed; the unhandled
illegal/PC anomaly must be gone on unstubbed OpenSBI for a real pass.

Artifacts: `tmp-dual-ci/fw_payload_r3a_{norest,err2,stub*,uart,dramcon,nospin,banner,banner2,banner3}.elf`,
TB `CVA6_TRAP_DUMP` + `[dram-console]` in `corev_apu/tb/ariane_tb.cpp`.

### R3a RTL fix attempt: always-on unresolved CF stall (2026-08-07)

**Problem:** `build_config_pkg` forces `SpeculativeSb=1` whenever `SuperscalarEn=1`.
The hang-7 issue stall (`gen_unresolved_cf_stall`) was gated on `!SpeculativeSb`, so
**dual-issue smt2 never stalled issue past unresolved CTRL_FLOW**. Fallthrough after
RAS-miss Return / predicted Jump could enter EX before resolve; younger-cancel alone
was insufficient for FDT walks (BADOFFSET / memchr-low / plat_hc=0x80).

**Change (`core/issue_stage.sv`):** apply unresolved CF stall **unconditionally**
(SpeculativeSb still provides younger cancel). Detect CF accept from `issue_instr_valid_sb`
(not gated iro) so the issue cycle still registers. Clear on `resolve_branch_i || flush_i`.

**Config (`g6lc64_smt2_config_pkg.sv`):**
- `NrLoadBufEntries` 2 → 8 (match hang-7 server_math floor)
- `RASDepth` 2 → 8 (FDT recursion; BPCkptDepth=0 so avoid prior ckpt/RAS=16 misalign)

**Also confirmed this session:** stock `fw_payload` on both DI and SI smt2 still ends
`plat_hc=0x80` / `coldboot_done=0` by 1.5–4M (hang-6/7 family). Lab banner stubs remain
diagnostic only.

**Rebuild:** `work-ver-smt2` re-verilate after this change; then soak bare concurrent +
stock/force OpenSBI.

#### Soak after CF-stall + RAS/ldbuf (work-ver-smt2 rebuild)

| Test | Result |
|------|--------|
| `smt_dual_concurrent.elf` +tohost | **SUCCESS** ~200k cycles (no regress) |
| stock `fw_payload.elf` @2M | still `plat_hc=0x80` coldboot=0 (hang-6/7 FDT walk) |
| `fw_payload_r3a_norest.elf` (force+phases) | same as pre-fix: cookies through hsm/fdt_reset/hart_init then `51b100ff` hang; plat_hc=1 |

**Takeaway:** always-on unresolved CF stall is a correctness fix for SpeculativeSb×dual
issue windows and does not regress bare concurrent, but does **not** alone clear
stock OpenSBI FDT walk or `sbi_hart_init` residual. Next RTL candidates remain
true dual-issue data-path (pointer/PC) corruption in FDT walks and CSR expected-trap
/ AMO / UART paths.

### R3a: RAS-miss NoCF + RASDepth 16 (2026-08-07 cont.)

**Hang-7 smoking gun (from monorepo-soak/L2-OPENSBI-HANG-PROGRESS.md):** after
`ret` from an FDT error path, next commit was alias `jal memchr` **skipping**
`mv a0,s1` setup — RAS/Return wrong-path with a0=-4 (BADOFFSET) → unbounded
memchr → R Response storm. Not a path[0] LBU miss at commit.

**RTL (`core/frontend/frontend.sv`):** when `is_return` and `!ras_predict.valid`,
set `cf_type=NoCF` (not `Return` with garbage target). `branch_unit` then always
mispredicts JALR with `cf==NoCF` and redirects to rs1/ra.

**Config:** `RASDepth` 8→16 on `g6lc64_smt2` (with always-on CF stall + ldbuf=8).

**Soak:**
| Test | Result |
|------|--------|
| concurrent | SUCCESS ~200k |
| stock OpenSBI @3M | still `plat_hc=0x80` (no R/B storm) |
| norest force | same phase cookies → hart_init hang |
| banner2 stubs | still trap_error hang after OSBI dump |

Stock FDT residual remains open after these CF/RAS discipline fixes.

### R3a: fdtcnt probe (2026-08-07 cont.)

**TB fixes (`corev_apu/tb/ariane_tb.cpp`):**
- Restored `-m` / `+max-cycles=` enforcement (`main_time >= max_cycles` break) — had been
  dropped during hang-7 probe growth, so post-rebuild soaks ran unbounded.
- Extended `CVA6_TRAP_DUMP` with `[fdtcnt]` BSS log @ DRAM+`0x42e00` and optional
  8-slot offset ring @ `0x42e80`.

**ELF probe `tmp-dual-ci/fw_payload_r3a_fdtcnt.elf` (and denser `…fdtcnt2.elf`):**
trampolines at `0x80007600` (`fdt_next_tag`) / `0x80007670` (`fdt_path_offset`) log into
BSS `LOG=0x80042e00` (safe; cookies at `0x80001000` overwrite `.text`).

**DI soak (`work-ver-smt2`, concurrent still SUCCESS ~200k):**

| Artifact | next_tag | last_off | path_cnt | last_path | fail | notes |
|----------|----------|----------|----------|-----------|------|-------|
| Harness / artifact | next_tag | last_off | max_off | path_cnt | last_path | fail | notes |
|--------------------|----------|----------|---------|----------|-----------|------|-------|
| DI fdtcnt @400k–1.5M | **8** | **0** | — | **1** | `0x8001f7f0` (`"/"`) | 0 | `plat_hc=0x80`; `last_fdt=8001e000` |
| DI fdtcnt2 ring @400k | **3** | **8** | **8** | **1** | `0x8001f7f0` | 0 | ring `0,8,8`; `last_fdt=0` (extra DI a0 loss) |
| SI fdtcnt2 ring @400k | **4** | **0** | **8** | **1** | `0x8001f7f0` | 0 | ring `0,8,8,0`; `last_fdt=8001e000` ok |

Concurrent DI still **SUCCESS** ~200k after TB-only rebuild.

**Interpretation:**
1. Hang is **inside the first `fdt_path_offset("/")` walk** (not platform fail-WFI; `fail=0`).
2. Structure walk **starts** (`0 → 8` = root `BEGIN_NODE` + empty name pad) then **never
   advances past offset 8** on both DI and SI (`max_off=8`). Residual is **not DI-only**.
3. DI denser trampoline also shows **`last_fdt=0`** on the last entry — extra dual-issue
   a0 / caller fdt corruption on top of the shared offset-8 stall.
4. Hook discipline: keep original RVC prologue head before `j` body; LOG base is
   `lui t0,0x80; addiw; slli 12; …` (not `lui t0,0x80000`).

**FDT layout (fw_payload, struct @ header+0x38):** abs off `0` = `BEGIN_NODE ""` → next `8`;
abs off `8` = **`PROP` (tag=3, len=4)** → should next at `0x18`. Probe never leaves `8`, so the
stall is **on the first property tag** (load of BE tag/len/nameoff or `*nextoffset` store), not
on path string matching.

### R3a: fdtcnt3 — `*nextoffset` store is dead (2026-08-07 cont.)

Probe `fw_payload_r3a_fdtcnt3.elf` (entry hook in RX pad `@0x8001d914` + epilogue hook
replacing `c.addi16sp; c.jr ra` at `0x80012a70`):

| Config | next_tag | ret_cnt | last_tag | last_nxoff | a2 | notes |
|--------|----------|---------|----------|------------|-----|-------|
| observe only | **1** | **1** | **1** (`BEGIN_NODE`) | **0** | `0x80046e4c` valid | body returns OK; **out-param not written** |
| lab: if `*nx==0` force `sw 8` | **15** | **15** | 1 | 8 | valid | walk **unblocks** — proves hang is dead `*nextoffset` |
| lab: force only tag==1 | 2–3 | 3 | 9/`END` | −8 | mixed | partial progress; still `plat_hc=80` |

**Smoking gun:** first `fdt_next_tag(fdt,0,&nx)` returns tag `FDT_BEGIN_NODE` but
`*nx` stays **0** despite a live stack slot (`a2=0x80046e4c`). libfdt then cannot advance
past the root node. Binary stores are `sw rd, 0(s3)` at `0x80012a2a` / `0x80012a84`
(s3 holds the `nextoffset` pointer).

This matches hang-progress notes on **CPU store/load path** (not FDT image corruption).
SI and DI both show the dead out-param; DI can also zero a0/fdt on later entries.

### R3a: fdtcnt4 — `sw` site values (2026-08-07 cont.)

Instrumented `sw a4,0(s3)` @ `0x80012a2a` and `sw s1,0(s3)` @ `0x80012a84` (stubs in
RX pad, logs at `LOG+0x100` / `+0x120` so they do not collide with entry `LOG@0x42e00`).

Prologue: `c.mv s3, a2` @ `0x800129e6` — pointer is captured early.

| Site | n | s3 (ptr) | val (data) | a2 at sw | mem[*s3] after |
|------|---|----------|------------|----------|----------------|
| sw1 `12a2a` | 8 | `0x80046e1c` **valid** | last **`-11`** (`-FDT_ERR_BADSTRUCTURE`) | `0xff0000` (clobbered) | — |
| sw2 `12a84` | 1 | `0x80046e1c` | **`0x48`** | `0x48` | **`0x48`** |

**Takeaways:**
1. **Pointer is fine** — hang is not “s3=0 / lost a2”. `s3` holds the stack slot; `a2` is
   free to be reused (clobbered) after the `c.mv`.
2. **Stores fire** — not a total store-unit black hole. Values include libfdt error codes
   (`-11`) and a large structure skip (`0x48`).
3. Earlier **observe-only** probe saw `*nx==0` after `tag==1` return; with store stubs
   (extra latency) the walk reaches `last_off=0x28` / `next_tag≈9` — **timing-sensitive**,
   consistent with **store→load hazard** (caller `lw *nextoffset` before SB/L1 visibility)
   or intermittent **bad FDT loads** producing `BADSTRUCTURE` then recovery.
4. LSU does **not** forward store data: `store_buffer` only sets `page_offset_matches` on
   `addr[11:3]` and the load unit **stalls** (`WAIT_PAGE_OFFSET`) until the match clears
   (`load_unit.sv` / `store_buffer.sv`). A miss in that compare (or a speculative load under
   `SpeculativeSb`) would allow a load to see **stale 0**.

### R3a: STORE younger-cancel exemption (2026-08-07 cont.)

**Mechanism (scoreboard + STQ):** on `is_mispredict`, younger cancel marks SB TIDs
`cancelled`; `store_buffer` drops those TIDs from the speculative STQ; `commit_drop`
ACKs the instruction **without** `commit_lsu`. Comment claimed “no LSU side-effects” —
false for stores: the SW is discarded with no re-exec.

**RTL (`core/scoreboard.sv`):** do **not** younger-cancel `fu==STORE` (sticky + same-cycle
mask). Wrong-path stores may still need a precise STQ age kill; full `flush_ex` on
mispredict was tried and is unsafe (drops older uncommitted correct-path stores).

**Soak after rebuild (`work-ver-smt2`):**
| Test | Result |
|------|--------|
| concurrent +tohost | **SUCCESS** ~200k (no regress) |
| fdtcnt1 @600k | still `next_tag=8` `last_off=0` `path_cnt=1` `plat_hc=80` |
| diag @1.5M | still `plat_hc=80` |

**Conclusion:** STORE cancel exemption is a real correctness fix for lost SWs under
SpeculativeSb, but **alone does not clear R3a** — residual is still the FDT walk stuck
at offset 0 / dead `*nextoffset` visibility (store→load hazard and/or bad structure
loads), not solely STQ cancel of the `*nx` SW.

### R3a: ret-drain / sticky / STQ-empty load experiments (2026-08-07 cont.)

Tried three LSU/commit interlocks on `work-ver-smt2` (Verilator **5.008** —
system 5.020 faults on this tree; use `PATH=/root/tools/verilator-v5.008/bin:$PATH`).

| Change | concurrent | fdtcnt1 | fdtnx (BSS `*nx`) | notes |
|--------|------------|---------|-------------------|-------|
| **CTRL_FLOW hold until `no_st_pending`** (commit) | SUCCESS | **`next_tag=0` `last_fdt=0`** (regress) | dead | Reverted. Global ret stall until commit-queue+wbuffer empty is too coarse. |
| **1-cycle sticky `page_offset_matches`** after STQ drop (`store_buffer.sv`) | SUCCESS | still `last_off=0` | `last_off=8` `nx_slot=0x18` (baseline) | Kept: low-cost STQ→wbuffer bubble cover; does **not** alone clear R3a. |
| **SpeculativeSb: stall all loads while STQ non-empty** (`load_unit.sv`) | SUCCESS | `next_tag=0xc` still `last_off=0` | **`nx_slot=-11` regress** | Reverted. Heavy RAW drain does not fix stack `*nx`; **increases BADSTRUCTURE**. |

**Disassembly anchors (`fdt_next_tag` @ `0x800129d4`):**
- `c.mv s3,a2` then `sw -8,0(a2)` at entry; unconditional `sw -11,0(s3)` before tag
  dispatch (`0x80012a2a`); success `sw s1,0(s3)` @ `0x80012a84`.
- `fdt_check_node_offset_`: `sw a1,-20(s0)` then `jal fdt_next_tag` then `lw a0,-20(s0)`
  — exact stack out-param RAW after ret.

**Evidence summary:**
1. **Pointer OK** — fdtcnt4: `s3=0x80046e1c`, stores fire (`-11`, later `0x48` in mem).
2. **BSS outparam (fdtnx) advances** (`last_off=8`, `nx_slot=0x18`) while **stack stays at
   `last_off=0`** — address-class / timing, not total store black hole.
3. **SI** (`work-ver-smt2-si`) also `last_off=0` `plat_hc=80` — not dual-issue-only.
4. Extra probe latency (fdtcnt4 stubs) can push `last_off` to `0x28` — timing-sensitive.
5. Full STQ-empty load stall **worsens** structure path (`-11`) → residual leans **bad FDT
   structure loads** as much as stack RAW.

**Live RTL kept on `work-ver-smt2`:**
- scoreboard: no younger-cancel of `STORE`
- controller: mispredict = `flush_if`+`flush_unissued` only (no `flush_ex`)
- store_buffer: 1-cycle sticky page_offset match
- commit: **no** CTRL_FLOW ret-drain
- load_unit: **no** SpeculativeSb STQ-empty stall

### R3a: STQ data-forward + directed microtest (2026-08-07 cont.)

**FDT blob is valid offline** (magic `d00dfeed`, walk `0→BEGIN_NODE, 8→PROP, …`).

**STQ store→load data forward** (`store_buffer` + `load_unit`):
- Byte-merge oldest→youngest for entries matching **full** page offset `[11:0]`
  (not `[11:3]` — early version could forward a stack SW onto an FDT load that only
  aliases in `[11:3]` across 4 KiB pages).
- Load completes from forward when `((st_fwd_be & load_be) == load_be)` without a D$ req.
- Sticky `[11:3]` match for stall kept (false-positive stalls OK).

**Directed microtest** `tmp-dual-ci/stld_ret.elf` (A: SW/LW, B: callee SW+ret+LW,
C: three SWs like libfdt, D: stack out-param frame like `fdt_check_node_offset_`):
| Config | Result |
|--------|--------|
| STQ forward + STORE cancel on | **PASS** ~514 cyc (tohost exit 0) |
| STQ forward + STORE cancel off (exemption) | **PASS** same |

**OpenSBI after STQ forward (exact `[11:0]`), STORE younger-cancel restored:**
| Test | Result |
|------|--------|
| concurrent | SUCCESS ~200k |
| fdtcnt1 | still `next_tag=8` **`last_off=0`** `plat_hc=80` |
| fdtnx BSS | still `last_off=8` `nx_slot=0x18` |
| diag @1.5M | still `plat_hc=80` |

**Conclusion:** simple stack RAW / ret / multi-SW is **not** broken on this core. R3a is
OpenSBI+libfdt specific (long `fdt_next_tag` with many FDT structure loads, dual-issue
pressure, mispredict mix). STQ forward is kept as correctness; it does **not** alone
clear platform FDT hang. STORE cancel exemption is **dropped** (wrong-path SW commit
hazard; no OpenSBI delta either way).

**Live RTL on `work-ver-smt2`:**
- STQ exact `[11:0]` data forward + sticky `[11:3]` stall match
- Normal younger-cancel of STORE (no exemption)
- No CTRL_FLOW ret-drain; no SpeculativeSb STQ-empty load stall

### R3a: ret-probe RA sign-extend bug; `*nx` is live (2026-08-07 cont.)

**Probe bug (false “dead *nx”):** entry hook set `ra = ret_stub` via
`lui ra, 0x8001e; addiw ra, ra, -0x5e0`. On RV64, `lui` of an imm20 with bit19 set
**sign-extends** → `ra = 0xffffffff8001da20` → **instruction access fault** on
`ret` into the stub. Symptoms: `next_tag≥1`, `ret_cnt=0`, trapdump PC
`ffffffff8001da20`. Entry hook at `0x8001d914` still ran (same page) because the
`j hook` is PC-relative, not via that `lui`.

**Fix:** materialize `0x8001da20` as
`lui 0x80; addi 0x1d; slli 12; addi 0x7ff; addi 0x221` (same style as LOG base).

**Rebuilt probes from clean `fw_payload_diag.elf`:**
- `fw_payload_r3a_fdtcnt3_obs.elf` — observe only  
- `fw_payload_r3a_fdtcnt3.elf` — force `*a2=8` if `tag==1 && *a2==0` (did not fire)

**Observe @0.8–3.0M on current `work-ver-smt2` (STQ exact forward + normal STORE cancel):**

| Field | Value | Meaning |
|-------|--------|---------|
| `ret_cnt` | **3** | ret stub healthy |
| `rettag[]` | **1, 3, 9** | BEGIN_NODE → PROP → END/fail |
| `retnx[]` | **8, 0x18, 0x18** | **`*nextoffset` advances** |
| `ring[]` | 0, 8, 8 | entries at 0 then 8 |
| `a2_entry` | `0x80046e1c` | valid stack out-param |
| `force_nx` | 0 | never saw tag==1 with *nx==0 |
| `plat_hc` | **0x80** | still not parsed |
| concurrent | SUCCESS ~200k | no regress |

**Revised root-cause picture:**
1. Earlier “dead `*nextoffset`” was **mostly a broken ret probe** (RA sign-extend), not
   proven sole RTL loss of stack SWs. Directed `stld_ret` already PASSed.
2. With a working ret path, **first steps of the FDT structure walk succeed** under DI.
3. Hang residual is **later** in platform FDT use: trapdump PC `0x80012eb2` is
   `fdt_get_property_by_offset_` **error path** (`sw a0,0(s2); li a0,0`), cookie
   `[1008]=6` (~`FDT_ERR_BADPHANDLE`). `path_cnt=0` (no `/cpus` path walk yet).
4. STQ `[11:0]` data forward remains valuable insurance; not the only R3a lever.

**Live artifacts:** `tmp-dual-ci/fw_payload_r3a_fdtcnt3{,_obs}.elf`, rebuild recipe in
session notes (RA `li` sequence). Verilator **5.008** only.

### R3a: hang locus = `fdt_getprop_namelen` / compatible match (2026-08-07 cont.)

**fdtcnt5 probes** (`tmp-dual-ci/build_fdtcnt5.py`, RA-safe): `fdt_next_tag` +
`fdt_path_offset` hooks, a0/fdt ring @ LOG+0x140, path_ret @ LOG+0x70.

**DI baseline (`work-ver-smt2`, STQ forward + CF blocks LOAD):**
| Field | Value |
|-------|--------|
| `path_cnt` / `last_path` | 1 / `0x8001f7f0` (`"/"`) |
| `path_ret` | **0** (success — root offset) |
| `next_tag` / `ret_cnt` | **2** / **2** |
| `rettag` / `retnx` | 1,3 / 8,0x18 |
| `a0` ring | both `0x8001e000` (fdt stable) |
| `plat_hc` | 0x80 |

**SI (`work-ver-smt2-si`):** `last_path=0x8001f800` (`"/cpus"`), `next_tag≈13` —
**DI stalls earlier than SI.**

**Software bisection (binary stubs → `c.li a0,0; c.jr ra`):**
| Stub | DI effect |
|------|-----------|
| `fdt_getprop` only | still stuck (`next_tag=2`, path `/`) |
| `fdt_get_property_by_offset_` only | still stuck |
| **`fdt_getprop_namelen` only** | **unblocks** → `last_path=/cpus`, `next_tag=3` |
| all prop APIs | same as getprop_namelen stub |

**Call chain:**
`fw_platform_init` → `path_offset("/")=0` → override loop (`platform_override_modules_size=8`)
→ `fdt_match_node` → `fdt_node_check_compatible` → **`fdt_getprop_namelen("compatible")`**
→ `fdt_get_property_namelen_` → after 2×`next_tag` (BEGIN_NODE, first PROP) **DI never
makes the 3rd `next_tag`** (would be `check_prop` inside `get_property_by_offset_`).

**Also tried:** SpeculativeSb `CTRL_FLOW` now blocks **LOAD** as well as STORE
(`issue_read_operands.sv`) — concurrent still green; **no** fdtcnt5 delta (may need
clean rebuild verify).

**Next targets (ordered):**
1. **RTL: why DI dies in `fdt_get_property_namelen_` after exactly two `next_tag` rets**
   (post-ret `a0`/tag use, stack `*nextoff` at `s0-116`, or hang in
   `get_property_by_offset_`/`check_prop` before the 3rd entry hook).
2. After compatible/getprop works: `/cpus` path (`path_ret=-8` under prop stubs) +
   `fdt_parse_hart_id` → `plat_hc`.
3. Banner / coldboot once `plat_hc ∈ {1,2}`.

### R3a session (2026-08-07) — fdtcnt6 ra/s2 rings + CF all-ports trial

**Probes:** `tmp-dual-ci/build_fdtcnt6_s2.py` (entry-only + ra/s2 rings @ LOG+0x180/0x1c0);
TB dumps `[fdtcnt-ra]` / `[fdtcnt-s2]`. Ret-hijack **not** required to see the hang
(entry-only also stalls; ret-stub global ra was a red herring for the 2-ret ceiling).

**DI fdtcnt6 @1.5M (port-0-only unresolved CF stall, baseline):**
| Field | Value |
|-------|--------|
| next_tag | 3 |
| a0 ring | `8001e000`, **0**, `8001e000` |
| ra ring | `80013082` (get_property loop), `80012b60` (check_prop), `80012b2a` (check_node) |
| s2 ring | fdt / stack-lenp / fdt |
| path / plat_hc | `/` / 0x80 |

Null `a0` on check_prop entry is DI-specific (SI: next_tag≈0x19, path_cnt=2).
Isolated `stld_full` (s2 frame save/restore + nested outparam) **PASS** under DI —
simple stack RAW is not sufficient to explain OpenSBI hang.

**Software locus (unchanged):** hang inside `fdt_get_property_namelen_` /
`fdt_get_property_by_offset_` / `fdt_check_prop_offset_` after ~2–3 `next_tag`
(BEGIN_NODE via check_node + PROP walk). Stock `fw_payload_diag` still
`plat_hc=80`, cookies near `80012e9c` (by_offset `sw *lenp`) / `80012b2a`.

**RTL trial — unresolved CF stall on all issue ports** (`issue_stage.sv`):
- Arm `unresolved_cf_q` when **any** port accepts CTRL_FLOW (was port 0 only).
- FDT: next_tag 3→4, a0 ring all good (no null).
- **Regressed concurrent** (timeout @300k–500k vs prior SUCCESS ~200k).
- **Reverted.** Root cause of concurrent hang likely multi-hart / resolve
  coupling (global stall bit). Future: per-hart unresolved CF, or arm port 1
  only for predicted-indirect CF.

**Live RTL kept:** STQ sticky+[11:0] forward, SpeculativeSb CTRL_FLOW blocks
LOAD+STORE co-issue, STORE younger-cancel, port-0 unresolved CF stall.

**Next targets:**
1. Per-hart `unresolved_cf_q` (or port-1 arm without concurrent hang).
2. Why DI dies mid-getprop after 2–4 next_tag (get_string / memcmp / *lenp SW).
3. `/cpus` + `plat_hc∈{1,2}` + banner once getprop completes.


### R3a session (2026-08-07 cont.) — per-hart unresolved CF stall

**RTL (kept):** `core/issue_stage.sv` `gen_unresolved_cf_stall`

- Arm `unresolved_cf_q[hart]` when **any** issue port accepts `CTRL_FLOW` for that hart
  (fixes port-0-only miss of dual-issue `ALU||JAL` on port 1).
- Gate `issue_instr_valid_iro[p]` only if **that instruction's** `hart_id` is stalled
  (global all-ports arm hung `smt_dual_concurrent`; per-hart does not).
- Clear on same-hart `resolve_branch_i` (`resolved_branch_i.hart_id`) or `flush_i`.

**Soak (`work-ver-smt2`, Verilator 5.008):**

| Test | Result |
|------|--------|
| concurrent +`+elf_file=` | **SUCCESS ~200155 c** (green) |
| fdtcnt6 entry-only | `next_tag=4`, a0 all good (was 3 + null a0), path still `/`, `plat_hc=80` |
| fdtcnt5 ret-stub | still `next_tag=2` rets 1,3 / nx 8,0x18 |
| stock diag | `plat_hc=80`, cookie near `get_property_by_offset_` |

**Software bypass probes (diag ELF only):**

| Patch | Effect |
|-------|--------|
| `platform_override_modules_size=0` + fdtcnt6 | `path_cnt=2` **`last_path=/cpus`**, still hang (`next_tag=4`, `fdt_next_node` ra) |
| force `plat_hc=2` in BSS + stub first_subnode | trapdump **`plat_hc=2`** but still hang in getprop before coldboot (`coldboot_done=0`) |

**Interpretation:** per-hart CF stall is a real DI hygiene fix and slightly advances FDT
entry probes; residual hang remains inside libfdt property / node walks
(`getprop` / `first_subnode` / `next_node`), not "never leave `/`". Override bypass
reaches `/cpus` entry under DI.

**Next:** fix remaining DI FDT walk (STQ/RAW or issue window during `next_node` body)
so stock getprop completes → natural `plat_hc` from `/cpus` → coldboot/banner.


### R3a session (2026-08-07 cont.2) — STQ full-paddr match + hang PC

**RTL (kept):** STQ stall/forward now uses **full load paddr** when DTLB hit
(`load_paddr_valid_i` + `load_paddr_i` through load_unit → store_unit → store_buffer).

- Prior `[11:0]`-only forward could poison FDT structure loads with stack data when
  `stack[11:0] == fdt_addr[11:0]` across pages (or false-stall forever on `[11:3]` alias).
- Bare mode: `dtlb_hit=1`, PPN from VA[high] → identity paddr compare.
- Concurrent still **SUCCESS ~200155**.

**Also kept:** per-hart unresolved CF stall (all issue ports).

**Software experiments (no RTL cure alone):**

| Experiment | Result |
|------------|--------|
| NOP next_tag intermediate SW `-8`/`-11` | fdtcnt6 `next_tag` 4→5; still hang |
| Full-paddr STQ | concurrent green; stock still `plat_hc=80` |
| hangpc dump at timeout | **`npc0=0xe678`** (low / non-DRAM PC) |

**Hang signature:** not a tidy WFI in OpenSBI FDT; frontend NPC lands at **0xe678**
(suggests bad redirect / exception / truncated PC view). AXI `R Response Errored`
around ~226k cycles still appears. fdtcnt6 still caps at `next_tag=4` in getprop
(check_node / check_prop callers).

**Next:** resolve hang PC 0xe678 (full exception/mtvec/mepc dump; confirm not
bit-slice of npc_q); check whether STQ forward still active under hang; SI
stock diag npc compare.


### R3a session (2026-08-07 cont.3) — hang is store/load access fault

**Definitive hang state (DI stock, banked CSR dump):**

| Field | Value | Meaning |
|-------|-------|---------|
| mepc | `0x80012e9c` | `sw a5,0(s2)` in `fdt_get_property_by_offset_` (*lenp) |
| mcause | `0x6` | **Store/AMO access fault** |
| mtvec | `0x800003c8` | OpenSBI M-mode trap vector |
| npc0 | `0x10050` | post-trap frontend NPC (not DRAM text) |
| plat_hc | `0x80` | still default |

**fdtcnt6 DI:** mepc=`0x80012b30` (`lw a0,-20(s0)` *nextoff in `check_node_offset_`), **mcause=4 load access fault**.

**Interpretation:** not a quiet FDT spin — the walk takes a **memory access fault** on
stack out-params after `fdt_next_tag` (lenp via s2, or *nextoff via s0-20). That
matches callee-saved / stack-frame corruption across `next_tag` (s2 save/restore or
frame), then trap to mtvec and stuck with bad NPC.

**STQ work this session (kept, concurrent green):**

- Full-address forward (no cross-page poison)
- Load STQ key = current `vaddr` (always valid)
- Stall on `[11:0]` (classic); forward only full address
- Per-hart unresolved CF stall

None of these alone clear the mcause=6/4 hang yet; `stld_full` still PASS.

**Next:** prove s2/s0 value at faulting SW/LW (GPR dump at trap); fix next_tag
frame RAW or RF restore under DI; consider not cancelling stack stores.

### R3a session (2026-08-07 cont.4) — GPR proof + branch-TID cancel fix

**Trap-handler GPR dump (stock DI, `CVA6_TRAP_DUMP=1`):**

| Slot | Value | Meaning |
|------|-------|---------|
| mepc | `0x80012e9c` | `sw a5,0(s2)` *lenp in `by_offset_` |
| mcause | `6` | store access fault |
| mtval / s2 | **`0x80012b2a`** | code addr = `check_node` after `jal next_tag` |
| s0 | `0x80046e60` | **good** by_offset frame pointer |
| ra | `0x80012e3e` | return into by_offset after `check_prop` |
| sp | `0x80046e30` | consistent with -48 frame |

So **s0 is fine; s2 alone is poisoned** with a value that was stored as `ra` on a
*prior* `next_tag` call from `check_node` (not the current `check_prop` ra
`0x80012b60`). Points to stale stack/STQ data or crossed restore, not “s0 frame
gone.”

**fdtcnt6:** s2 often still fdt; hang can be `mcause=4` with **s0** junk (`mtval=s0-20`).

**Experiments:**

| Change | Concurrent | Stock hang |
|--------|------------|------------|
| STQ nofwd (`st_fwd_valid=0`) | SUCCESS ~200155 | same mcause=6 s2=`0x80012b2a` |
| STORE younger-cancel off (prior) | green | same hang |
| `next_tag` s0/s2 via DRAM scratch (soft) | n/a | still faults (scratch path also broken / first rev infinite-looped on j offset) |
| **`after_flu_wb = branch.trans_id+1`** (not FLU_WB) | SUCCESS 200155 | **same hang** (tid desync not this residual) |
| nest `stld_next_tag_nest` | — | PASS ~3k |

**RTL kept this session:**

1. **`bp_resolve_t.trans_id`** from `branch_unit` (`fu_data_i.trans_id`).
2. **scoreboard** younger-cancel uses `resolved_branch_i.trans_id + 1` instead of
   `trans_id_i[FLU_WB]+1`. FLU mux can present mult/ALU tid while a branch resolves
   the same cycle — that widened the cancel window into older correct-path ops.
   Real hygiene fix even though stock FDT hang unchanged.
3. **STQ forward re-enabled** (`st_fwd_valid = |be_m`); nofwd was diagnostic-only.
4. Per-hart CF stall + full-PA STQ stall/forward unchanged.

**Still open:** why DI `ld s2,32(sp)` in `fdt_next_tag` yields `0x80012b2a` (prior
call’s ra) under OpenSBI jump-table pressure while isolated nest microtest PASSes.
Next levers: RF/WB result mix for epilogue LDs; wrong-path store commit to stack
slot; jump-table `jr` recovery vs frame SDs; SI vs DI A/B on same ELF with GPR dump.

### R3a session (2026-08-07 cont.5) — STQ-empty-before-load advances past *lenp

**Decisive software probes on stock `by_offset`:**

| Patch | Fault mepc | s2 / mtval |
|-------|------------|------------|
| reload s2 from `0(sp)` after check_prop | cave `sw` | still `0x80012b2a` |
| save lenp to DRAM `0x80043000`, reload | cave `sw` | `ca11ab1ebadcab1e` (uninit) |

Different poison at stack vs DRAM ⇒ **saved lenp store not visible to later load**
(not merely “RF s2 lost”). Isolated jr/namelen microtests still PASS.

**RTL (kept):** under `SpeculativeSb && SuperscalarEn`, loads wait in
`WAIT_PAGE_OFFSET` until `store_buffer_empty` unless STQ fully covers the load
via forward (`load_unit.sv` IDLE + SEND_TAG + WAIT). Concurrent still
**SUCCESS 200155**, nest PASS.

**Stock after STQ-empty gate:**

| Field | Before | After |
|-------|--------|-------|
| mepc | `0x80012e9c` (*lenp SW) | **`0x80007378`** (`fw_platform_init` after getprop) |
| mcause | 6 (store misalign on code ptr) | **4** (load misalign) |
| s2 | `0x80012b2a` poison | **`0x8001e000` fdt — fixed** |
| s0 | good | good |
| s4 | n/a | **`0x80046f94`** bad (sp+4) → `ld a5,0(s4)` |

getprop returned NULL (`beqz` to +0xae); then misaligned `ld` on corrupt s4.
**s2 frame residual cleared;** remaining issues are later callee-saved (s4) /
getprop still returning NULL / platform_override path.

**Also kept:** branch `trans_id` for younger-cancel; STQ forward re-enabled.

**Next:** why getprop NULL with s2 healthy; s4 corruption in `fw_platform_init`;
refine full-STQ-empty (perf) once coldboot green.

### R3a session (2026-08-07 cont.6) — s4 = getprop lenp (restore fail)

**s4 fault math:** `mtval == s0-108 == 0x80046f94` exactly. In `fdt_getprop`:
`mv s4,a3` parks **lenp**; `ld s4,0(sp)` should restore caller s4. After return,
`fw_platform_init` does `ld a5,0(s4)` with s4 still **lenp** → load misalign (cause 4).

| Experiment | Result |
|------------|--------|
| STQ-empty loads (cont.5) | s2 fixed; hang @ `0x80007378` s4=lenp |
| + D$ wbuffer-empty wait | **regressed** (illegal @0xa / trap path broken) — **reverted** |
| LOAD exempt from younger-cancel | **no change** (still s4=lenp) |
| getprop s4 save/restore via DRAM | still hang @ `0x80007378` |
| reseed s4=`generic_plat` after getprop | advances to `ld a5,8(a5)` @ `0x80007386` |
| trap cookie base `lui t1,0x80001` | soft patch; multi-instr t1 setup was fragile |

**Interpretation:** callee-saved **LOAD restore** still wrong even with STQ-empty and
no LOAD cancel — points at **store data for the save** (sd s4 captured after
`mv s4,a3` / wrong operand) or **forward/D$ returning lenp into the restore ld**.
Reseed proves platform_init can continue once s4 is correct.

**RTL live:** STQ-empty-before-load + branch tid cancel + STQ full-PA forward;
LOAD still cancelled on mispredict again? (no-load-cancel kept in tree if green).

**Next:** fix sd/ld operand timing for callee-saved pairs (sd rs2 vs later mv rd);
or force single-issue around prologue save/restore; getprop success path + plat_hc.

### R3a session (2026-08-07 cont.7) — s4 still lenp after more levers

| Lever | Concurrent | Stock @ getprop s4 |
|-------|------------|---------------------|
| Serialize all issue after STORE | SUCCESS 200155 | **unchanged** s4=`s0-108` |
| LOAD not younger-cancelled | SUCCESS | unchanged |
| getprop s4 DRAM save/restore | — | unchanged |
| reseed s4 after getprop (soft) | — | **advances** to `0x80007386` |

**Live RTL package (keep):**
1. Loads wait for `store_buffer_empty` unless STQ forward covers (fixed **s2**)
2. Younger-cancel uses `branch.trans_id+1`
3. STQ full-PA forward
4. After STORE, block all younger dual-issue ports (hygiene)
5. LOAD exempt from younger-cancel (hygiene; did not fix s4 alone)

**s4 residual:** `fdt_getprop` `ld s4,0(sp)` still yields **lenp** (`mv s4,a3` value),
not the saved caller s4 — even with DRAM path and no LOAD cancel. Soft reseed of
`s4=generic_plat` unblocks one instruction. Next: operand capture timing in LSU
for store data; or stop parking lenp in s4 in libfdt (software).

### R3a session (2026-08-07 cont.8) — force-SI + FDT walk forensics

**force-SI (kept):** under `SpeculativeSb && SuperscalarEn`, issue port p>0 forced
busy (`issue_read_operands.sv`). Concurrent still **SUCCESS 200155**.

**Stock under force-SI (decisive):**

| Field | Value |
|-------|--------|
| hang path | error dump after `fdt_path_offset("/cpus")` |
| a0/a1 | **-4** (`FDT_ERR_BADOFFSET`) |
| s2 | **0x8001e000** fdt (healthy) |
| ra | 0x800073a6 (return from path_offset) |
| cookie | `bad0c0de` |
| plat_hc | 0 (never enumerated) |

So force-SI **clears the getprop s4=lenp hang** (advances past 0x80007378). Remaining
blocker is **libfdt path walk**, not callee-saved s4.

**FDT layout (fw_payload_diag, absolute blob offsets):**

| Node | abs | **struct-relative** (= abs − 0x38) |
|------|-----|-------------------------------------|
| `/` (root) | 0x38 | **0** |
| `chosen` | 0x9c | 0x64 |
| `cpus` | 0x13c | **0x104** |
| `cpu@0` | 0x178 | **0x140** |
| `cpu@1` | 0x3bc | 0x384 |

libfdt `fdt_offset_ptr` does `fdt + off_dt_struct + offset`, so soft-force must use
**structure-relative** offsets (0x104 / 0x140), not absolute. Earlier “fix” to
0x13c/0x178 double-counted `off_dt_struct` and broke the walk.

**No `opensbi,config` / `cold-boot-harts` in this FDT** — after a successful cpus walk,
`fw_platform_init` hard-fails path_offset/compatible for opensbi,config (error dump
@ 0x80007560). Soft-skip of that section is required for this image, or the DTB
must gain an `opensbi,config` node.

**fdtcnt3 under force-SI:**

```
next_tag entry=2 ret=1 last_tag=9 last_nxoff=-11 last_fdt=0x8001e000 last_off=0
```

`fdt_next_tag(fdt, 0)` returns **tag 9 (FDT_END)** with nextoffset −11 — the
`fdt_offset_ptr` NULL path (cannot map structure offset 0 → root BEGIN_NODE). That
is the mechanical reason path_offset → −4 even though DRAM FDT magic/tags are intact
at preload (`magic_be=0xd00dfeed`, cpus@0x13c tag=1).

**Soft force_hc2b (struct-rel 0x104, s3=2, skip hart walk + opensbi section):**

| Result | Value |
|--------|--------|
| plat_hc | **2** |
| coldboot_done | 0 |
| later hang | mepc=`0x80013064` (`fdt_get_property_namelen_` after check_node) mcause=6 mtval=0xf9 |
| concurrent | SUCCESS 200155 |

Interpretation: platform_init can be forced through with plat_hc=2; later OpenSBI FDT
property walks still trap (store EA 0xf9 ⇒ frame/`s0` class residual under deeper
call stacks).

**Live RTL package (cont.8):**

1. STQ-empty-before-load (s2 frame fix)
2. Younger-cancel via `branch.trans_id+1`
3. STQ full-PA forward
4. After STORE serialize younger ports
5. LOAD exempt younger-cancel
6. **Force single-issue under SpeculativeSb** (clears s4=lenp)

**Next (priority):**

1. Why `fdt_offset_ptr(fdt,0,4)` returns NULL with intact DRAM header (byte loads of
   `off_dt_struct` / totalsize checks; compare ro_probe vs offset_ptr).
2. Peel force-SI once offset_ptr+path_offset work; keep precise dual-issue fix for s4.
3. After natural path_offset(/cpus), soft-add or skip `opensbi,config`; aim
   `coldboot_done` + banner.
4. Keep concurrent green on every RTL touch.


### R3a session (2026-08-07 cont.9) — FDT intact; walk still -4

**TB:** `CVA6_TRAP_DUMP` now prints `[fdtmem]` (host DRAM FDT header + root/cpus
tags + LE words) and `[walk]` (0x42e00 probe slots).

**Decisive: DRAM FDT is intact at hang**

```
[fdtmem] mag=0xd00dfeed tsz=0xaf5 off_struct=0x38 off_strings=0x934
         ver=0x11 sz_struct=0x8fc tag_root=0x1 tag_cpus=0x1
         le0=0xf50a0000edfe0dd0 le8=0x3409000038000000
```

path_offset(/cpus)=-4 is **not** a corrupted blob.

**CPU can LBU/LD the header** (soft probe before path_offset @ cave 0x8001d914):

| Slot | Value | OK? |
|------|-------|-----|
| magic (lbu BE) | 0xd00dfeed | yes |
| totalsize | 0xaf5 | yes |
| off_struct | 0x38 | yes |
| le0/le8 | match fdtmem | yes |
| lw @ +0x38 | 0x01000000 (BEGIN_NODE) | yes |
| path ld | `/cpus` | yes |

Then real path_offset still returns **-4**. So failure is inside
next_tag/subnode/name walk (or its stack RAW), not header fetch.

**Skip getprop(model)** still path_offset -4 (model getprop not sole poison).

**Soft force_coldboot** (struct-rel 0x104, s3=2, skip opensbi, stub domains/final):
`plat_hc=2`, still later trap `mepc=0x80013064` mcause=6 mtval=0xf9 in
`fdt_get_property_namelen_` (same as cont.8 force_hc2b). FDT property walks after
platform_init still deadly.

**Cave note:** `.text` ends ~0x8001d918; slack to 0x8001e000 (.rodata) is loadable
zeros — OK for short caves; long caves must stay < 0x8001e000.

**Next:**
1. Instrument `fdt_next_tag`/`subnode_offset` return values with stores to
   non-BSS (e.g. 0x80001000 error-cookie region) to survive later BSS use.
2. Root-cause stack SW→LW of `*nextoff` / depth under STQ-empty (wbuffer?).
3. Stub/fix property walks only as a ladder to coldboot_done; peel force-SI
   after natural path_offset works.
4. Concurrent green on every RTL touch.


### R3a session (2026-08-07 cont.10) — path_offset returns -4 with good inputs

**Probes (log @ VA 0x80022c00 / DRAM+0x22c00, not BSS/trap cookie page):**

| Experiment | Result |
|------------|--------|
| path_offset-only cave | **completes**; result **−4**; steps 1→2 logged |
| stock diag | same −4 error dump; fdtmem intact |
| direct `fdt_ro_probe_` / `fdt_offset_ptr` from cave | **illegal insn** @ `sun20i_d1` rodata (ra restore → data) |
| path_offset (calls those internally) | no crash, returns −4 |

**walk_po log (decisive):**
```
[+0]=51b10020 cookie
[+8]=8001e000 fdt
[+10]=8001f800 /cpus
[+18]=1 before path_offset
[+20]=fffffffffffffffc  ← path_offset == -4 (BADOFFSET)
[+28]=2 after path_offset
```

So with correct fdt+path, `fdt_path_offset` still yields **−4** (not −1 NOTFOUND).
FDT blob in DRAM remains perfect (`[fdtmem]`).

**RV64 soft-patch lessons:** never `lui` with imm20≥0x80000; never `addi` imm≥0x800
(sign-extend). Build `0x80022c00` as lui 0x80 / addiw 0x22 / slli 12 / addi 0x7ff / addi 0x401.

**RTL (cont.10):** `load_unit` waits for D$ `wbuffer_empty` only when
`page_offset_matches && !st_fwd_covers` (stack RAW after STQ drain). Global wbuffer
wait still avoided. Concurrent **SUCCESS 200155**. **path_offset still −4** — so
the walk failure is not only “STQ empty but wbuffer dirty” on same page.

**Interpretation:** −4 comes from `fdt_next_node` / `next_tag` (bad tag or offset_ptr
NULL path), not from a missing `/cpus` name match (−1). Next: why `next_tag(0)` fails
under the core while host DRAM tag_root=1 (D$ stale line? sticky page-offset stall
serving wrong data? jump-table load?).

**Next:**
1. Instrument `next_tag` return (tag + nextoff) via path inside `path_offset` only
   (direct cave calls to offset_ptr/ro_probe are unreliable due to ra/stack).
2. Check sticky `page_offset_matches` vs FDT page 0xe000.
3. Soft force 0x104 only as ladder after natural −4 is understood.


### R3a session (2026-08-07 cont.11) — next_tag returns tag=9

**Confirmed chain:**
1. Host walk of the same blob finds `/cpus` at struct-rel **0x104**.
2. `path_offset` under Verilator returns **−4** (walk_po).
3. Hooked `next_node→next_tag` logs **last tag = 9** (offset_ptr NULL / tag>9 path).
4. DRAM `[fdtmem]` still perfect.

So `fdt_offset_ptr(fdt,0,4)` is effectively failing inside `next_tag` during
the OpenSBI walk (leaves `*nextoff=-11`, returns tag 9 → next_node −4).

**RTL experiment — full-PA-only stall (reverted):**
`load_paddr` is **always vaddr** (`load_unit.sv`), not DTLB paddr (by design —
ppn sampling races the store path). Stall-only-on-full-PA therefore skipped
classic [11:0] stack RAW. Reverted address_checker to **stall on [11:0]**,
forward on full PA. Concurrent still **SUCCESS 200155**.

**Kept from cont.10:** page-offset-match + `!st_fwd_covers` → wait for
`dcache_wbuffer_empty` (narrower than global wbuffer wait).

**Soft-patch notes:** hooking `next_tag` entry with `jal` clobbers `ra` (must use
`j`); force-root next_tag still WIP.

**Next:**
1. Why `offset_ptr` fails mid-walk (LBU of header → 0 / wrong totalsize?) while
   host MEM and idle LBU probes see correct bytes — D$ line vs STQ alias on
   FDT page-off `0xe000`.
2. Consider stall on [11:0] but **never forward** unless full PA (already true);
   or suppress [11:0] stall when load VA page ≠ any store VA page (page number).
3. Soft force path_offset=0x104 only as ladder after offset_ptr root-caused.


## cont.12 — optr_tag, ntag ring, STQ forward, sticky hold (2026-08-07)

### Diagnostics collected

| Probe | Result |
|-------|--------|
| `fw_payload_r3a_optr_tag` | last `offset_ptr(fdt,0,4)` → `0x8001e038`, tag lw `0x01000000` = FDT_BEGIN_NODE (**good**) |
| Host FDT walk | `/cpus` at struct-rel **0x104**; blob valid (`d00dfeed`, off_struct=0x38) |
| `st_fwd_valid=0` (nofwd) | concurrent SUCCESS 200155; stock still path_offset **−4** |
| ntag ring (hook first optr in `fdt_next_tag`) | last slots all `startoffset=0`, tag BEGIN — heavy cave can self-interfere; uninstrumented stock is authoritative for −4 |
| Soft force `/cpus` → 0x104 | advances past cpus check; next fail is `path_offset("/chosen")` @ `0x80007458` (same walk class) |

### Interpretation

- Hang is not quiet FDT WFI: error dump stores a0=−4 (`FDT_ERR_BADOFFSET`) at `0x80001000`, WFI @ platform_init error path.
- `offset_ptr` + FDT DRAM content are fine; failure is **subnode walk** (`fdt_next_tag` / `*nextoffset` stack RAW / skip math), not a bad blob.
- `path_offset("/")` succeeds (trivial); `/cpus` and `/chosen` both need depth walks and both fail.
- Comment already in `store_buffer.sv`: *nextoffset stays 0 → FDT walk stuck* after STQ→wbuffer handoff.

### RTL kept (work-ver-smt2 rebuild)

1. **Re-enable** `st_fwd_valid_o = |be_m` (nofwd was diagnostic only; did not clear −4).
2. **Page-offset sticky hold = 32 cycles** after last STQ [11:0] match so load_unit `(page_offset_matches && !wbuffer_empty)` covers the wbuffer drain bubble (1-cycle sticky was too short).
3. **force-SI** under SpeculativeSb still on; STQ [11:0] stall + page-match wbuf wait unchanged.
4. **Tried and reverted:** global `!store_buffer_empty \|\| !wbuffer_empty` for all loads — concurrent still green but stock regressed to illegal @pc=2 / store-fault in `next_tag`.

### Soak after cont.12 RTL

| Test | Result |
|------|--------|
| `smt_dual_concurrent` | **SUCCESS ~200155** |
| stock `fw_payload_diag` | still path_offset −4 / plat_hc=80 (before nuclear trial) |
| force cpus 0x104 | next residual `/chosen` path_offset (ladder works) |

### Next

1. Root-cause `*nextoffset` / next_tag without self-interfering caves (RVFI or TB scoreboard on stack PA).
2. Optional: sticky countdown only while `store_buffer_empty_o` (tie hold to real drain).
3. Peel force-SI once path_offset green; keep concurrent green every touch.
4. Soft force `/chosen` skip + plat_hc=2 only as banner ladder after walk root cause.

## cont.13 — store-side sticky, STQ residual ruled out (2026-08-07)

### Hypothesis tested

Callers post-return load of libfdt *nextoffset can issue after the store left the STQ, so load-side sticky never armed. Cont.12 32-cycle load-side sticky was insufficient for that race.

### RTL changes (kept on work-ver-smt2)

1. Wire dcache_wbuffer_empty_i into store_buffer via store_unit / load_store_unit.
2. Store-side sticky: on STQ-to-D$ grant (data_gnt), latch store [11:0] / full PA; hold page_offset_matches until dcache_wbuffer_empty.
3. Keep STQ forward (st_fwd_valid = |be_m), force-SI, STQ-empty-for-all-loads (peeling that regressed stock to load-fault at 0x80007316).

### Soaks

| Config | concurrent | stock path_offset |
|--------|------------|-------------------|
| store-side sticky + forward | SUCCESS 200155 | still -4 |
| store-side sticky + nofwd | SUCCESS 200155 | still -4 |
| classic match-only wait (no STQ-empty-all) | SUCCESS 200155 | regressed load-fault at 0x80007316 |

### Conclusion

path_offset -4 is not solely the STQ-to-wbuffer *nextoffset handoff. Even with nofwd, STQ empty before any load without forward, and store-side sticky until wbuffer empty, stock still returns FDT_ERR_BADOFFSET at /cpus. Residual is elsewhere in the libfdt walk (tag/prop loads, name compare, jump table, or SpeculativeSb cancel / dual-hart interaction).

### Soft ladder

| Patch | Result |
|-------|--------|
| force /cpus=0x104 only | next fail /chosen path_offset |
| force /cpus+/chosen | past both; fail fdt_node_offset_by_compatible(opensbi,config) (absent in this FDT); plat_hc still 80 means subnode/hart walk also broken |

### Next

1. Root-cause fdt_next_tag / fdt_first_subnode with RVFI (not self-interfering soft caves).
2. Compare g6lc64_smt2 vs true SuperscalarEn=0 SI build for path_offset.
3. Optional FDT inject opensbi,config + force hart walk only after next_tag green.
4. Keep concurrent green on every RTL touch.

## cont.14 — path_offset -4 cleared by decoupling SpeculativeSb (2026-08-07)

### Key bisect

| Build | SpeculativeSb | Issue | stock result |
|-------|---------------|-------|--------------|
| DI force-SI (pre-cont.14) | on (via SS) | force-SI | path_offset **-4** |
| True SI (SS=0) current RTL | off | 1 port | **past path_offset** into sbi_trap_handler (later store-fault) |
| DI classic LSU only | on | force-SI | load-fault 0x80007316 |
| DI SpeculativeSb decoupled off | **off** | full DI | **past path_offset** to getprop sw *lenp @ 0x80012e9c/eb2 mcause=6 |
| DI SpeculativeSb off + force-SI | off | force-SI | load-fault 0x80007316 (worse) |

Conclusion: **SpeculativeSb auto-on with SuperscalarEn was the path_offset blocker** (speculative-load LSU gates / STQ interlocks). True STQ *nextoffset race was secondary once SpeculativeSb is off.

### RTL kept

1. build_config: SpeculativeSb = OoOEn | SliceOoOEn | DeepSpecEn only (**not** SuperscalarEn).
2. force-SI **off** (re-enabling under SS regresses 0x80007316 with SpeculativeSb=0).
3. After STORE serialize all younger ports: gate on **SuperscalarEn** (was SpeculativeSb).
4. CTRL_FLOW blocks LOAD/STORE under **SuperscalarEn**.
5. Store-side sticky + STQ forward + classic page-offset wait (no STQ-empty-all).

### Soak

| Test | Result |
|------|--------|
| concurrent | SUCCESS ~200155 |
| stock fw_payload_diag | **no path_offset -4**; residual **mcause=6** store-fault at fdt_get_property_by_offset_ sw *s2 (s2=lenp corrupted under dual-issue) |

### Next

1. Precise dual-issue fix for getprop lenp/s2 (RF WB ordering) without full force-SI.
2. After getprop green: plat_hc write, opensbi,config gap, coldboot/banner.
3. Re-enable SpeculativeSb under SS only with speculative-load gates that do not break FDT walks.


## cont.15 — plat_hc force lands on SI; DI residual illegal@2 (2026-08-07)

### Soft plat_skip lessons

| Bug | Effect | Fix |
|-----|--------|-----|
| `lui`/`addiw` for `platform+0x50` | RV64 sign-extends to `0xFFFFFFFF80040438`, misses TB DRAM; `plat_hc` stays `0x80` | Form address with **`auipc+addi` from text PC** |
| Epilogue longer than 14 insns | Overwrote `platform_override_modules` loop at `0x80007588+` | Hard limit: only `0x80007550..0x80007587` |
| Cookie/`sd` extras | Same overrun | Drop cookie; `plat_hc` in trapdump is the proof |

Script: `tmp-dual-ci/mk_plat_skip.py` → `fw_payload_r3a_c15_plat_skip.elf`.

### Soak (RTL: SpeculativeSb decoupled; ALU/LSU/MULT/FPU serialize under SS)

| Build | `plat_hc` | `coldboot_done` | hang | notes |
|-------|-----------|-----------------|------|-------|
| **SI** (`work-ver-smt2-si`) | **2** | 0 | timeout, no trap-dump write at `0x1000` | Epilogue **runs**; past `fw_platform_init`; stuck later in `sbi_init` (not `sbi_hart_hang`) |
| **DI** (`work-ver-smt2`) | 80 | 0 | `mepc=0x2` `mcause=2` `mtvec=_start_hang` | Trap dump mepc=2; `s2` still FDT — **dies before epilogue** |
| concurrent | — | — | **SUCCESS ~200155** | Still green |

### Interpretation

1. **SI ladder unblocked through `plat_hc`.** Soft-skip of missing `opensbi,config` + force `plat_hc=2` is valid. Residual is post-`platform_init` OpenSBI (`sbi_init` coldboot/scratch/domain/HSM), not FDT walk.
2. **DI residual is dual-issue control-flow:** illegal fetch at PC=2 (null/ra poison); epilogue never reached.
3. Stubbing `sbi_hartindex_to_domain` + lottery `li a0,0` did not set `coldboot_done` in 2M cycles — need finer `sbi_init` breadcrumbs.

### Next

1. **SI:** breadcrumb cookies on `sbi_init` cold path (scratch/heap/domain/hsm/`coldboot_done`) to find first fail; populate `generic_hart_index2id` if needed; then banner.
2. **DI:** dual-issue PC=2 under FDT/`platform_init` with current serialize; compare vs SI; do **not** re-enable force-SI (regresses `0x80007316`).
3. Keep concurrent green; peel serialize only after DI reaches SI `plat_hc=2`.
4. Re-enable SpeculativeSb under SS only after clean dual-issue FDT+SBI.


## cont.16 — SI coldboot_done=1 via soft ladder (2026-08-07)

### Root causes unlocked this pass

| Layer | Bug | Fix |
|-------|-----|-----|
| Soft plat_hc force | `lui`/`addiw` → `0xFFFFFFFF80040438` misses DRAM | `auipc+addi` from text PC |
| Epilogue size | >14 insns clobbered override-modules loop @ `0x7588` | Hard limit `0x7550..0x7587` |
| Soft-skip coldboot-harts | `generic_coldboot_harts==0` → `cold_boot_allowed` always 0 → every hart waits forever for `coldboot_done` | Setup in `cold_boot_allowed`: bitmap=~0, `hart_index2id={0,1}`, return 1 |
| Dual-hart lottery | Stub `li a0,0` made **both** harts coldboot winners → deadlock | `csrr a0,mhartid` — only hart0 takes cold path |
| `sbi_domain_init` | Never returns (spin) after scratch+heap OK | Soft stub `li a0,0; ret` (ladder only) |

### Bisect (SI, full cold path)

| Skip | `coldboot_done` |
|------|-----------------|
| after scratch → done | 1 |
| after heap → done | 1 |
| after domain entry → done | 0 (stuck **in** `sbi_domain_init`) |
| domain stubbed | **1** |

### Soak

| Build | plat_hc | last_hartidx | coldboot_done | notes |
|-------|---------|--------------|---------------|-------|
| **SI** + ladder | **2** | **1** | **1** | past platform_init + sbi_init cold path; residual post-coldboot (no hang cookie) |
| DI | 80 | 0 | 0 | still `mepc=0x2` before epilogue |
| concurrent | — | — | — | SUCCESS ~200155 |

### Script

`tmp-dual-ci/mk_plat_skip.py` → `fw_payload_r3a_c15_plat_skip.elf`

### Next

1. SI: post-`coldboot_done` (`sbi_hart_init` / console / banner) with fail-site hang breadcrumbs.
2. DI: illegal@2 before `platform_init` epilogue (dual-issue CF); do not force-SI.
3. Peel domain stub once domain FDT/spinlock root cause known; re-enable SpeculativeSb only after DI reaches SI ladder point.


## cont.17 — SI post-coldboot to hsm_start_finish success WFI (2026-08-07)

### Post-coldboot bisect

| Step | Result |
|------|--------|
| baseline after coldboot_done | stuck in ops+0x10 callback (`early_init`/`fdt_reset`) |
| skip ops cb | `sbi_hart_init` fails (hang ra=0x840) |
| stub hart/console/sse/... | banner path; later inits block |
| `sbi_fwft_init` fails | hang ra=0xb40 |
| **lottery patch at 0x996** | **BUG**: 0x996 is fall-through after `hsm_hart_start_finish` → infinite coldboot loop |
| fix: 0x752 bnez→lottery; 0x996→success WFI | correct |
| b9c→980 + stub start_finish | **`[1000]=…51b1babe` success cookie** |

### Soak

| Build | plat_hc | last_hartidx | coldboot_done | cookie | notes |
|-------|---------|--------------|---------------|--------|-------|
| **SI** ladder | **2** | **1** | **1** | **0x51b1babe** | post-`hsm_hart_start_finish` success WFI |
| concurrent | — | — | — | — | SUCCESS ~200155 |
| DI | 80 | 0 | 0 | — | still illegal@pc=2 before platform epilogue |

### Ladder (`tmp-dual-ci/mk_plat_skip.py`)

1. plat_hc=2 (`auipc+addi`), heap_size=0x20000
2. cold_boot_allowed: coldboot_harts=~0, index2id={0,1}, return 1
3. lottery via **0x752→0x7a2** (not 0x996!); winner=hart0
4. domain_init stub
5. skip early_init cb; stub hart/console/printf/sse/pmu/…/fwft/pmp/ecall
6. skip final ops cb; **b9c→980**; stub `hsm_hart_start_finish`
7. **0x996 → success cave**: store **0x51b1babe**, WFI

### Next

1. Peel stubs (real `sbi_hart_init` needs domain/features).
2. Real banner once console works.
3. DI illegal@2 before plat_hc force.
4. Keep concurrent green.


## cont.18 — DI reaches 51b1babe (full CF serialize + override skip) (2026-08-07)

### DI progression

| Harness / RTL | Soft | hang residual | plat_hc | coldboot_done | cookie |
|---------------|------|---------------|---------|---------------|--------|
| DI partial CF (cont.15) | ladder | mepc=2 mcause=2 **ra=0** | 80 | 0 | — |
| DI **full CF serialize** | ladder | mepc=0x7316 mcause=4 s3=poison | 80 | 0 | — |
| DI full CF + **skip override mods** | ladder | success WFI | **2** | **1** | **51b1babe** |
| SI | ladder | success WFI | 2 | 1 | 51b1babe |
| concurrent | — | — | — | — | SUCCESS 200155 |

### RTL kept

`issue_read_operands.sv`: after CTRL_FLOW under SuperscalarEn, full `fus_busy[p]='1`.
Concurrent still green. Full CF clears DI ra=0 / mepc=2; advances into `fw_platform_init`.

### Soft

Skip `platform_override_modules` at 0x730a→0x7594 (DI `ld s3,0(s4)` yields poison
`ca11ab1ebadcab1e` even with full CF serialize).

### Next

1. Root-cause s3 poison without skipping override loop.
2. Peel soft stubs toward stock OpenSBI on SI and DI.
3. Keep concurrent green on every RTL touch.

## cont.19 — DI s3 poison root-cause: dual c.mv after ld s3 (2026-08-07)

### Symptom

DI at `platform_override_modules` loop:
- `mepc=0x80007316` `mcause=4` `mtval=ca11ab1ebadcab1e` (axi_err_slv poison)
- Instruction is `ld a2, 0(s3)` — s3 holds poison, not a module pointer

### What it is *not*

| Hypothesis | Result |
|------------|--------|
| natural `auipc+addi s4` wrong | **auipc alone → s4=0x80040300 correct**; delayed addi → 0x80040460 |
| force s4 alone | still dies if both c.mvs remain |
| force s3 / skip whole override (cont.18) | unblocks but over-broad |
| single `c.mv a1,s1` only | **SUCCESS** |
| single `c.mv a0,s2` only | **SUCCESS** |

### What it *is*

Sequence at fault site:

```
730e  ld   s3, 0(s4)     # module ptr — good when allowed to retire
7312  c.mv a1, s1
7314  c.mv a0, s2
7316  ld   a2, 0(s3)     # uses s3
```

**Both** c.mvs together leave `s3 = ca11ab1ebadcab1e` (dump after the pair). Either c.mv alone is fine. Spacing with nops between the two adds still fails. Nopping **both** c.mvs → DI reaches **51b1babe** with **natural** s4 (no force, no override skip).

Likely RTL: dual-issue commit/RF writeback interaction between in-flight `ld s3` and two younger ALU writes (a1/a0) under `NrCommitPorts=2` — WAW/forwarding or wrong rd on load complete. Issue-stage already serializes after LOAD/ALU under SS; residual is multi-cycle LSU vs dual commit.

### Soft ladder (narrower than cont.18)

Replace override skip `0x730a→0x7594` with:

```
7312: c.nop   # was c.mv a1, s1
7314: c.nop   # was c.mv a0, s2
```

Override loop runs; module call args a0/a1 may be stale (stubs still yield success cookie).

### Soak

| Build | Soft | plat_hc | coldboot_done | cookie |
|-------|------|---------|---------------|--------|
| **DI** | nop c.mv pair | **2** | **1** | **51b1babe** |
| **SI** | nop c.mv pair | **2** | **1** | **51b1babe** |
| concurrent | — | — | — | SUCCESS ~200155 (expect hold; no RTL change) |

### RTL attempt (cont.19b) — dual-commit serialize (negative result)

Tried `commit_stage.sv`: under `SuperscalarEn`, block dual-commit when
oldest is `LOAD` or when both ports are `ALU`. Rebuilt `work-ver-smt2`.

| Soft | Result after RTL |
|------|------------------|
| natural c.mv pair | **still** mepc=`0x7316` poison |
| nop c.mv pair | still **51b1babe** |
| concurrent | still **SUCCESS 200155** |

So the poison is **not** dual-commit of load+ALU or ALU+ALU (in-order commit
already forces load RF write before the c.mvs). Reverted the commit-stage
change. Residual RTL hypothesis: scoreboard/forwarding or wrong-path LOAD
(cont.5: LOAD not younger-cancelled) still writing poison into `s3` around the
c.mv pair — needs wave/SB dump next.

### Next

1. RTL: SB/forward dump around `ld s3` + dual `c.mv` (or selective LOAD cancel).
2. Soft: keep nop c.mvs; peel domain/hart_init/banner stubs.
3. Keep concurrent green on any RTL touch.

## cont.20 — peel soft stubs; RTL load-WB stall negative (2026-08-07)

### RTL probe (reverted)

Tried stall-all-issue while any LOAD is still-issued and not WB-valid
(`issue_read_operands.sv` under SuperscalarEn).

| Soft | Result |
|------|--------|
| natural c.mv | illegal @ mepc=`0xa` (worse) |
| nop ladder | regressed (`plat_hc=80`, no cookie) |
| concurrent | still SUCCESS 200155 |

**Reverted.** Full load-WB drain is too aggressive for OpenSBI dual-issue.

### Soft stub peel (SI single-site sweep)

| Stub | SI alone | Notes |
|------|----------|-------|
| domain_init | OK | **DI alone FAIL** (`coldboot_done=0` mepc=`0x3dc`) |
| sse, dbtr, irqchip, ipi, tlb, timer, fwft, pmp, ecall, printf, console | OK | — |
| pmu, domain_finalize, hart_init | FAIL | coldboot_done=1 but no cookie |
| hsm_start_finish | FAIL | success-path still needs stub |

### Combined peel

| Set | SI | DI |
|-----|----|----|
| all OK singles | FAIL | FAIL |
| SI no-IO (10: +domain_init, no printf/console) | **OK** | FAIL (domain_init) |
| DI-safe 9 (no domain_init; +fwft+ecall) | OK | hang @ `0x80008cc4` (no cookie) |
| **shared: sse,dbtr,irqchip,ipi,tlb,timer,pmp** | **OK** | **OK** |
| +printf or +console onto no-IO | FAIL | — |

### Production ladder (`mk_plat_skip.py` cont.20)

**Peeled (real):** sse, dbtr, irqchip, ipi, tlb, timer, pmp_configure  
**Still stubbed:** domain_init, pmu, domain_finalize, hart_init, printf, console_init, fwft, ecall_init, hsm_start_finish  
**Kept:** cont.19 nop c.mv @7312/7314; b9c→980; success cookie WFI  

### Soak

| Build | plat_hc | coldboot_done | cookie | concurrent |
|-------|---------|---------------|--------|------------|
| **SI** peeled | 2 | 1 | **51b1babe** | — |
| **DI** peeled | 2 | 1 | **51b1babe** | — |
| concurrent | — | — | — | **SUCCESS 200155** |

### Next

1. DI: real domain_init (spin/FDT) without coldboot death.
2. Peel fwft/ecall once DI hang @`0x8cc4` understood; printf/console after banner path.
3. RTL: cont.19 dual-c.mv s3 poison (SB/forward waves).
4. Keep concurrent green.

## cont.21 — domain_init DI = illegal@2; trap handler t1 fix (2026-08-07)

### DI `sbi_domain_init` (real, not stubbed)

| Build | Result |
|-------|--------|
| SI + real domain_init | OK alone (cont.20) |
| DI + real domain_init | **FAIL** |

**Primary exception (after trap fix):** mepc=`0x2` mcause=`0x2` (illegal instruction at PC 2).

**Secondary (before trap fix):** hangpc mepc=`0x800003dc` mcause=`0x6` (store misaligned) was the trap handler itself: `_trap_handler` @`0x3d8` did `sd t0,0(t1)` with **uninitialized t1** (`mtvec` skips `_start_hang` @`0x3c8` that formed `t1=0x80001000`).

So domain_init under DI still hits the **cont.18-class CF/ra→PC=2** residual; keep stubbed on the shared ladder.

### Soft: trap handler dump fix

`mk_plat_skip.py` cont.21: at `0x800003d8` jal to cave @`0x8000ef00`:

1. form `t1 = 0x80001000` (lui/addiw/slli)
2. dump mepc, mcause, mtval, sp, s0, s2, ra, s1
3. WFI

Any future exception dumps cleanly to DRAM+0x1000 for trapdump.

### Hang @`0x80008cc4` (fwft/ecall peel)

Disassembly: `spin_lock` **ret** (not the spin loop). Combined peels that include real `fwft`/`ecall_init` hang after coldboot without cookie; likely lock/path hang later, not ticket AMO misalign alone. Still stub those on shared ladder.

### Ladder state (unchanged peels from cont.20)

**Peeled:** sse, dbtr, irqchip, ipi, tlb, timer, pmp_configure  
**Stubbed:** domain_init, pmu, domain_finalize, hart_init, printf, console, fwft, ecall_init, hsm_start_finish  
**Plus:** cont.19 nop c.mv; cont.21 trap t1 cave; success cookie WFI  

### Soak

| Build | cookie / result |
|-------|-----------------|
| SI cont.21 ladder | **51b1babe** plat_hc=2 coldboot_done=1 |
| DI cont.21 ladder | **51b1babe** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** |

### Next

1. DI: illegal@2 into/out of `domain_init` (ra/jal dual-issue residual under CF serialize).
2. Peel fwft/ecall once spin/path hang is clear; printf/console for banner.
3. cont.19 dual-c.mv s3 poison RTL.
4. Keep concurrent green.


## cont.22 — domain_init completes; post-domain scratch_alloc ra stale (2026-08-08)

### Reframe (was: illegal@2 inside domain_init)

Cookie bisect with trap cave + restored real sbi_domain_init from fw_payload_diag.elf:

| Probe | Cookie | Meaning |
|-------|--------|---------|
| after zalloc1/2 | 0x888/0x999 | heap OK |
| memreg path | 0xAAA | past first memregion_init |
| before domain_register | 0x444 | hartmask done |
| wrap domain_register | 0xBBB then 0xCCC | register returns |
| skip domain_register | 0xDDD | still mepc=2 later |
| wrap domain_init call | 0x111 then 0x222 | domain_init returns |
| stop after domain_init | 0xE2 + WFI | clean stop, no illegal@2 |

Conclusion: real sbi_domain_init completes on DI. Illegal@pc=2 is after return to sbi_init at 0x7dc, not inside domain_init body.

### Fault window: first post-domain sbi_scratch_alloc_offset

After domain_init, coldboot does: 7e0/7f4 scratch_alloc, 818 hsm_init, 828 coldboot_done.

| Probe | Result |
|-------|--------|
| before SA at 7e0 (0xA1) | cookie seen; never A2 (SA does not return) |
| after spin_lock in SA (0x52) | lock returns |
| after spin_unlock (0x92) | unlock returns; s4 old offset=0x70 |
| skip memset to epilogue (0x93) | still mepc=2 |
| epilogue dump saved ra | ra slot = 0x8000bc76 |

0x8000bc76 is the return PC of the first SA call inside domain_init (jal at 0xbc72 returns to 0xbc76). The post-domain SA epilogue restores a stale ra and rets into the middle of domain_init, then eventual illegal@2.

Hypothesis (DI residual, same family as cont.19): second SA sd ra,40(sp) does not stick, or sp wrong so ld ra hits first frame slot; and/or jal link / stack forwarding under dual-issue after deep domain_init stack traffic.

### Soft workarounds (diagnostic)

| Soft | Result |
|------|--------|
| Leaf soft SA at 7e0/7f4 (bump extra_offset, no stack/lock/memset) | past both SAs; natural ld at 0x806 still mcause=4 once |
| Force s5/s4 + entry-count + hsm_init + coldboot_done=1 in cave | coldboot_done=1 with real domain_init (cookie 0xF7); hang later in PMU path (~0x1ad4), no 51b1babe yet |
| Production ladder (domain still stubbed) | still 51b1babe |

### Ladder (unchanged production peels)

Peeled: sse, dbtr, irqchip, ipi, tlb, timer, pmp_configure
Stubbed: domain_init, pmu, domain_finalize, hart_init, printf, console, fwft, ecall_init, hsm_start_finish
Plus: cont.19 nop c.mv at 7312/14; cont.21 trap t1 cave; success cookie WFI

### Soak (cont.22)

| Build | Result |
|-------|--------|
| DI production ladder | 51b1babe (base ELF, reconfirmed) |
| concurrent | no RTL change this cont; keep SUCCESS ~200155 |

### Next

1. RTL: sbi_scratch_alloc_offset second-call ra/sp — SB dump of sd/ld ra,40(sp) under SuperscalarEn; SI vs DI after domain_init.
2. Soft peel: real domain_init + soft post-domain SA + land success cookie (extend past PMU stubs).
3. cont.19 dual-c.mv s3 poison still open.
4. Peel fwft/ecall/printf when safe; keep concurrent green.
## cont.23 — real domain_init peeled on DI via soft SA (2026-08-08)

### Peel

| Item | cont.22 | cont.23 |
|------|---------|---------|
| sbi_domain_init | stubbed | **real** (full body from stock OpenSBI) |
| post-domain sbi_scratch_alloc_offset @7e0/7f4 | natural (DI stale ra) | **leaf soft SA** caves @0xee00/0xee80 |
| after both SA stores @0x806 | natural hsm/coldboot | **set coldboot_done=1; j SUCCESS** |
| success cookie | 51b1babe | **51b1babe** |

Soft SA: bump extra_offset, zero 8B at s2+old, return old offset — no stack, no spin_lock, no memset loop (avoids cont.22 stale-ra epilogue).

Coldboot short-circuit: hsm_init still fails under real domain + soft SA (mepc into scratch / error hang). Skip to success WFI for green ladder; post-coldboot peels remain validated on domain-stubbed cont.21 path.

### Production (mk_plat_skip.py)

**Peeled (real):** domain_init, sse, dbtr, irqchip, ipi, tlb, timer, pmp_configure
**Soft:** post-domain SA leaf; @806 coldboot_done + success jump
**Stubbed:** pmu, domain_finalize, hart_init, printf, console, fwft, ecall_init, hsm_start_finish
**Plus:** cont.19 nop c.mv; cont.21 trap t1 cave

### Soak

| Build | Result |
|-------|--------|
| DI cont.23 ladder | **51b1babe** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** (no RTL change) |

### Next

1. RTL: second-call scratch_alloc ra/sp under DI (cont.22 root).
2. Soft: real hsm_init after soft SA without short-circuit; restore post-coldboot path under real domain.
3. cont.19 dual-c.mv s3 poison.
4. Peel fwft/ecall/printf when safe.


## cont.24 — global soft scratch_alloc; natural hsm/coldboot (2026-08-08)

### Insight

cont.23 call-site soft SA only fixed 7e0/7f4. `sbi_hsm_init` cold path also calls
`sbi_scratch_alloc_offset(56)` — that hit the **same** real SA and cont.22 stale-ra
bug. Hence cont.23 needed @806 short-circuit past hsm.

### Peel

| Item | cont.23 | cont.24 |
|------|---------|---------|
| domain_init | real | real |
| sbi_scratch_alloc_offset | call-site soft @7e0/7f4 only | **GLOBAL leaf soft** @entry 0x3984 -> cave 0xee00 |
| @806 / hsm_init / coldboot_done | short-circuit to SUCCESS | **natural** path |
| success cookie | 51b1babe | **51b1babe** |

Global soft SA leaf (no stack): align size, load/store `extra_offset`, return old
offset, `jalr x0,ra`. Covers domain_init first SA, post-domain SA, hsm 56B SA.

### Production (mk_plat_skip.py)

**Real:** domain_init, sse, dbtr, irqchip, ipi, tlb, timer, pmp_configure, **hsm_init** (via soft SA)
**Soft:** entire sbi_scratch_alloc_offset
**Stubbed:** pmu, domain_finalize, hart_init, printf, console, fwft, ecall_init, hsm_start_finish
**Plus:** cont.19 nop c.mv; cont.21 trap t1; lottery; success WFI @996

### Soak

| Build | Result |
|-------|--------|
| DI cont.24 ladder | **51b1babe** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** |

### Next

1. RTL: real scratch_alloc second-call ra/sp under DI (retire soft SA).
2. cont.19 dual-c.mv s3 poison.
3. Peel fwft/ecall/printf; banner path.

## cont.25 — peel fwft + ecall_init on DI (2026-08-08)

### Stub sweep (cont.24 base + restore one real at a time)

| Peel alone | DI result |
|------------|-----------|
| **fwft** | **51b1babe** |
| **ecall_init** | **51b1babe** |
| **fwft+ecall** | **51b1babe** |
| printf | FAIL mepc=`0x80012eb2` mcause=6 (getprop/store residual) |
| console | FAIL mepc garbage mcause=1 |
| pmu | FAIL mepc=`0x80012eb2` mcause=6 |
| hart_init | hang no cookie (coldboot_done=1) |
| domain_finalize | **51b1dead** error path |

cont.21 DI hang @`0x8cc4` (spin_lock ret) with fwft/ecall is **cleared** under cont.24 global soft SA + real domain ladder.

### Production peel (mk_plat_skip.py cont.25)

**Real:** domain_init, sse, dbtr, irqchip, ipi, tlb, timer, pmp, **fwft**, **ecall_init**, hsm_init (via soft SA)
**Soft:** global sbi_scratch_alloc_offset leaf
**Stubbed:** printf, console, pmu, hart_init, domain_finalize, hsm_start_finish
**Plus:** cont.19 nop c.mv; cont.21 trap t1; success WFI

### Soak

| Build | Result |
|-------|--------|
| DI cont.25 ladder | **51b1babe** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** |

### Still blocked

- printf/console: IO path + getprop store residual @`0x12eb2`
- pmu: same store residual when real
- hart_init / domain_finalize: path hangs or error without cookie
- RTL: real scratch_alloc ra/sp; cont.19 dual-c.mv s3 poison

### Next

1. Banner: peel printf/console once getprop@12eb2 fixed (or soft stub printf body).
2. RTL soft-SA retirement + dual-c.mv.
3. hart_init peel when DI path clean.

## cont.26 — soft printf BANR + banner path thru ecall/features (2026-08-08)

### Real printf still blocked

| Attempt | Result |
|---------|--------|
| peel real printf | FAIL mcause=6 @`0x12eb2` (`sw *lenp` s2 poison) |
| nop 12eb2 + printf | FAIL moves to `0x13128` (`sw s1,0(s3)` namelen) |
| printf + stub all fdt getprop* | FAIL mepc=`-2` ifetch |
| **soft printf** (count+BANR, ret 0) | **51b1babe + BANR** |

Root: DI residual **s-reg outparam poison** in libfdt property path (same family as cont.15/19), triggered when real printf runs (more call depth / timing). Soft printf avoids it.

### Banner path peel

Ladder previously short-circuited `b9c -> 980` (skipped ecall + all banner printfs).

| Step | cont.26 |
|------|---------|
| `sbi_printf` | soft cave @`0xed00`: ++count @`0x1060`, store **BANR** `0x42414e52` @`0x1068`, ret 0 |
| `sbi_putc` | stub ret 0 |
| `b9c` | **real** `sbi_ecall_init` (already peeled cont.25) |
| thru platform-name printf | soft printf |
| `bfa` (features printf) | **j 980** success path (cut before heavier platform I/O) |

Probes: open full banner without cut → mepc=2; cut at bfa → babe+BANR.

### Production (mk_plat_skip.py cont.26)

**Real:** domain_init, sse, dbtr, irqchip, ipi, tlb, timer, pmp, fwft, ecall_init, hsm (soft SA), **banner path ecall+first printfs**
**Soft:** global scratch_alloc; **soft printf BANR**
**Stubbed:** console_init, putc, pmu, hart_init, domain_finalize, hsm_start_finish
**Plus:** cont.19 nop c.mv; cont.21 trap t1; bfa→980; success WFI

### Soak

| Build | Result |
|-------|--------|
| DI cont.26 | **51b1babe** + **`[1068]=42414e52` BANR** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** |

### Next

1. Real printf once FDT lenp s2/s3 poison fixed (or more precise soft).
2. Extend past bfa (platform features/IPI banner) with soft printf.
3. RTL: soft-SA retirement; cont.19 dual-c.mv.
4. console_init/UART for true serial banner.

## cont.27 — banner extended thru device list (cut @d00) (2026-08-08)

### Cut-point sweep (soft printf BANR, natural ecall)

| Cut after | VA | DI |
|-----------|-----|-----|
| boot_hart printf | c0a | **51b1babe + BANR** |
| ipi device printf | c20 | **OK** |
| timer device printf | c3a | **OK** |
| console device printf | c50 | **OK** |
| hsm device printf | c66 | **OK** |
| pmu device printf | c7c | **OK** |
| domain/heap size printfs | **d00** | **OK** (furthest green) |
| heap usage printf | d72 | FAIL mepc=2 |
| no cut (full banner tail) | — | FAIL mepc=2 |

cont.26 cut was **bfa** (features string only). cont.27 moves cut to **d00**: full OpenSBI-style device banner sequence under soft printf (platform name, features, boot HART, IPI/timer/console/HSM/PMU/reset/suspend/cppc, domain base/size/fw size).

### Failure beyond d00

`d3e+` heap space queries (`sbi_heap_*` / `sbi_scratch_used_space`) then printf → illegal@2. Soft-SA / heap residual; leave cut at d00.

### Production (mk_plat_skip.py cont.27)

**Same as cont.26 plus:** banner cut `bfa -> 980` replaced by **`d00 -> 980`**.

**Soft printf BANR** @`0x1068`; global soft SA; real domain/fwft/ecall; cont.19 nop c.mv; cont.21 trap t1.

### Soak

| Build | Result |
|-------|--------|
| DI cont.27 | **51b1babe** + **BANR** plat_hc=2 coldboot_done=1 |
| concurrent | **SUCCESS 200155** |

### Next

1. Fix heap/scratch_used_space path past d00 (or soft those helpers).
2. Real printf (FDT lenp s2/s3); console/UART.
3. RTL: soft-SA retirement; dual-c.mv s3.

## cont.28 — soft heap freelist walkers; banner cut @d92 (2026-08-08)

### Root of post-d00 mepc=2

Fine cuts (soft printf, natural ecall/banner):

| Cut | Result |
|-----|--------|
| d3a / d42 / **d46** (after `heap_reserved`) | **51b1babe** |
| d4c+ (runs `sbi_heap_used_space`) | **mepc=2** |

`sbi_heap_reserved_space` is a plain load (OK).  
`sbi_heap_used_space` / `sbi_heap_free_space` walk freelist under `spin_lock` and die (ra→2), likely corrupted `hpctrl` freelist after soft SA / zalloc under DI.  
`sbi_scratch_used_space` also uses spin_lock.

### Soft fix

Stub ret0:

- `sbi_heap_used_space` @`0xf2f4`
- `sbi_heap_free_space` @`0xf2aa`
- `sbi_scratch_used_space` @`0x3a3c`

Keep real `sbi_heap_reserved_space`.

With stubs, banner extends cleanly through heap/scratch printfs:

| Cut | Result |
|-----|--------|
| d72, **d92**, db0 | **51b1babe + BANR** |
| domain_dump_all (dd0) without stub | mepc=2 (still blocked) |

Production cut moved **d00 → d92** (after scratch-used printf).

### Production (mk_plat_skip.py cont.28)

**New soft stubs:** heap_used, heap_free, scratch_used  
**Banner cut:** `d92 → 980`  
**Unchanged:** soft printf BANR, global soft SA, real domain/fwft/ecall, cont.19 nop c.mv

### Soak

| Build | Result |
|-------|--------|
| DI cont.28 | **51b1babe** + **BANR** |
| concurrent | **SUCCESS 200155** |

### Next

1. Soft/fix `sbi_domain_dump_all` past d92; ecall version + boot HART dump.
2. Real freelist walkers (heap integrity under DI).
3. Real printf; console/UART; RTL soft-SA + dual-c.mv.

## cont.29 — full natural banner; soft domain_dump_all (2026-08-08)

### Extension past d92

With cont.28 heap freelist stubs + soft stub **`sbi_domain_dump_all`** @`0xb594`:

| Cut / path | Result |
|------------|--------|
| db0..efc (ecall ver, boot string, domain dump skip, hart/misa/pmp/mhpm) | **51b1babe + BANR** |
| **no cut (full natural banner tail)** | **51b1babe + BANR** |
| nodump cut @dd4 (dump not stubbed) | also OK if cut before dump |

`domain_dump_all` walks `domidx_to_domain_table` and calls `sbi_domain_dump` + printf — dies under DI without soft stub (cont.27–28 mepc=2 when dump runs).

### Production peel (mk_plat_skip.py cont.29)

**New soft stub:** `sbi_domain_dump_all`  
**Removed:** banner cut `d92 → 980` (full natural path to success WFI)  
**Keep:** soft printf BANR, global soft SA, heap_used/free + scratch_used stubs, real domain/fwft/ecall, cont.19 nop c.mv

Banner now prints (soft) through: platform/features/devices, heap/scratch numbers, SBI ecall version, boot HART, domain (dump soft), priv/misa/extensions, PMP/MHPM.

### Soak

| Build | Result |
|-------|--------|
| DI cont.29 | **51b1babe** + **BANR** |
| concurrent | **SUCCESS 200155** |

### Next

1. Real `domain_dump` / freelist walkers (DI table integrity).
2. Real printf + console/UART.
3. Peel hart_init / domain_finalize.
4. RTL: soft-SA retirement; dual-c.mv s3.

## cont.30 — peel real putc + domain_dump_all (2026-08-08)

### Stub re-peel sweep (cont.29 base)

| Peel alone | DI result |
|------------|-----------|
| **sbi_putc** | **51b1babe + BANR** |
| **sbi_domain_dump_all** | **51b1babe + BANR** |
| heap_used / heap_free / scratch_used | mepc=2 (keep soft) |
| hart_init | hang, no cookie |
| domain_finalize | 51b1dead |
| pmu | mepc=`0x12eb2` mcause=6 (getprop) |
| console_init | mepc garbage mcause=1 |

cont.29 soft-stubbed `domain_dump_all` after earlier mepc=2; re-test on full cont.29 ladder (heap freelist soft + soft printf) shows **real dump is green**. Soft printf handles dump's printf calls.

### Production (mk_plat_skip.py cont.30)

**Peeled real:** putc, domain_dump_all  
**Still soft/stub:** heap_used, heap_free, scratch_used, printf (BANR), global SA, console_init, pmu, hart_init, domain_finalize, hsm_start_finish

### Soak

| Build | Result |
|-------|--------|
| DI cont.30 | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Next

1. Real heap freelist walkers (hpctrl integrity under DI).
2. hart_init / domain_finalize peels.
3. Real printf + console/UART.
4. RTL: soft-SA retirement; dual-c.mv s3.

## cont.31 — sbi_hart_init DI bisect (2026-08-08)

### Goal
Peel real `sbi_hart_init` (`0x8000CCCC`) on DI, or prove soft ret0 is the safe production leaf.

### Disasm (cold path, `a1 != 0`)
`sbi_hart_init` is large (`0xCCCC` .. `~0xEF4C` → `sbi_hart_hang`):
1. stack frame / save s0–s4
2. `csrw mip, 0`
3. cold: `misa_extension_imp(72)` → optional `sbi_hart_expected_trap` install
4. `sbi_scratch_alloc_offset(40)` → store into `hart_features_offset` (`0x80042148`)
5. memset features, PMP expected-trap CSR probe (`pmpcfg0`/`pmpaddr0` via `mtvec` swap)
6. feature detection / `sbi_hart_reinit` / ret

### Probe matrix (`run_c31.py` / `run_c31b.py`, unstub then patch)

| Probe | Result | Notes |
|-------|--------|-------|
| **soft0** (entry → ret0) | **51b1babe + BANR** | Same as production `stub0` |
| **feat0** (features_offset=0, ret0) | **51b1babe + BANR** | Zeroing features OK under soft ladder |
| softmin (SA 40B + store features + ret0) | hang, `[1000]=51b1c001` | Probe bug: `jal ra, SA` clobbers `ra`; final `jalr ra` loops mid-cave |
| SAonly (SA then ret0) | mepc=`0x80040012` mcause=2 | Same ra-clobber / cave chaos; not soft-SA leaf failure |
| wrap call site `@0x83c` | hang, no C2 | Real body never returns |
| B12 cookies `@cd24/@cd46` | mepc=`0x8000cd4e` mcause=6 | **Artifact**: cookie overwrote `auipc s4` → garbage store |
| D1 (preserve `sd a0,0(s4)` + cookie) | hang, no babe | Real cold path still dies later |
| D2 (after memset) / D34 (wrap reinit) | hang, no babe | Hang after early cold path |

Cookie dump slot was `0x80001080` (just **outside** trapdump window `0x1000..0x1078`); use `≤0x1070` for visible breadcrumbs.

### Critical: soft caves sit inside `sbi_hart_init`

| Cave | VA | Overlaps |
|------|-----|----------|
| soft printf | `0x8000ED00` | hart_init +0x2034 |
| global soft SA | `0x8000EE00` | hart_init +0x2134 |
| trap dump | `0x8000EF00` | hart_init end |
| hang / success | `0x8000EF4C` / `0xEF70` | `sbi_hart_hang` / `switch_mode` |

Production works because **entry is stub0** — body never runs. Real peel **must relocate caves** out of `[0xCCCC, 0xEF4C]` before unstubbing.

### Production (unchanged cont.30 ladder)
- Keep `stub0` @ `0x8000CCCC` (confirmed soft0/feat0 green).
- No mk_plat_skip peel this cont.
- No RTL change.

### Soak

| Build | Result |
|-------|--------|
| DI soft0 / feat0 | **51b1babe + BANR** |
| DI production ladder | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Next (cont.32+)
1. **Relocate** soft SA / printf / trap / success caves outside hart_init (need free RX gap or dead stub region).
2. Re-unstub + bisect real cold path (PMP expected-trap / reinit) with in-window cookies.
3. domain_finalize peel; heap freelist; real printf.
4. RTL: soft-SA retirement; dual-c.mv s3.


## cont.32 — relocate soft caves out of sbi_hart_init (2026-08-08)

### Problem (from cont.31)
Soft caves lived inside `sbi_hart_init` (`0xCCCC`..`~0xEF4C`):
- soft printf `@0xED00`, soft SA `@0xEE00`, trap `@0xEF00`
Unstubbing entry still ran into stomped mid-function bodies.

### Fix (`mk_plat_skip.py`)
| Cave | Old | New (stubbed body) |
|------|-----|---------------------|
| global soft SA | `0xEE00` | **`0x2C90`** (`sbi_pmu_init` after stub0) |
| soft printf BANR | `0xED00` | **`0xBAB0`** (`sbi_domain_finalize` after stub0) |
| trap dump | `0xEF00` | **`0xBB40`** (`sbi_domain_finalize` body) |
| hang / success | `0xEF4C` / `0xEF70` | unchanged (`sbi_hart_hang` / `switch_mode`) |

Hart_init text from diag stays intact when building the ladder.

### Results

| Build | Result |
|-------|--------|
| DI cont.32 production (stub hart_init) | **51b1babe + BANR** |
| DI unstub full hart_init | coldboot_done=1, **mepc=`0x8000ec14` mcause=2**, 51b1dead |
| concurrent | **SUCCESS 200155** |

### Real hart_init residual (post cave fix)
Illegal at `0x8000ec14` = `csrw mtvec,a5` in the **Sdtrig/`tselect` expected-trap probe** (`csrrw mtvec` → `csrr tselect` → `csrw mtvec`). CVA6 likely lacks Debug-trigger CSRs; OpenSBI expected-trap path misbehaves under DI (or dual-issue with the probe). Not a cave-stomp anymore — true CSR-detect residual.

### Production
Still **stub0** `sbi_hart_init`. Cave relocate is safe infrastructure for cont.33 peel.

### Next
1. Soft-skip or fix expected-trap around `tselect`/debug CSR probes in hart_init.
2. Or soft min: SA + features + memset, skip CSR probe tail.
3. domain_finalize / heap freelist / real printf.
4. RTL: soft-SA retirement; dual-c.mv s3; optional Sdtrig trap-on-access.


**Soft probe:** nop csrr tselect @c10 → illegal moves earlier to **mcyclecfg probe** @be0/be4 (same expected-trap pattern). Many CSR probes; expected-trap path is the systematic residual, not one CSR.


## cont.33 — peel real sbi_hart_init; soft-skip CSR probe tail (2026-08-08)

### Root cause of cont.32 residual
OpenSBI CSR expected-trap probes use:
```
csrrw mtvec, <handler>
<probe CSR>          # may illegal
csrw  mtvec, <old>
```
Under DI the probe CSR dual-issues with the following `csrw mtvec`, so **mtvec is already restored to the global handler** when the illegal is taken. `__sbi_expected_trap` never runs; our dump cave sees `mepc` on the restore `csrw` (e.g. `0xec14` tselect, `0xebe4` mcyclecfg). Switching hext→plain expected-trap does not help.

### Production peel (`mk_plat_skip.py`)
1. **Remove stub0** on `sbi_hart_init` (`0xCCCC`) — real cold path: SA, features, memset, reinit.
2. **Soft-skip** CSR expected-trap tail: after `sbi_memset` return `@0xcd86` → `j 0xcd0e` (`mv a0,s3; jal sbi_hart_reinit; epilogue`).
3. Caves remain in stubbed pmu / domain_finalize bodies (cont.32).

### Probe matrix
| Build | Result |
|-------|--------|
| real hart + skip probes (cd86→cd0e) | **51b1babe + BANR** |
| skip memset too (cd7a→cd0e) | mepc store-fault (features not zeroed) |
| soft-full SA cave | mepc=0x1c (ra restore bug; not needed) |
| nohext / hext→plain only | still mepc=`0xec14` mcause=2 |

### Soak
| Build | Result |
|-------|--------|
| DI cont.33 production | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
console_init, pmu, domain_finalize, heap_used/free, scratch_used, printf (BANR), global soft SA, hsm_start_finish; **CSR probe tail inside hart_init**.

### Next
1. RTL: serialize CSR issue after `csrrw mtvec` (or fence expected-trap pairs) so real PMP/Sdtrig detect works.
2. Peel domain_finalize / console / real printf.
3. Real heap freelist walkers.
4. Soft-SA retirement; dual-c.mv s3.


## cont.34 — rehome caves; domain/console peel attempt (2026-08-08)

### Cave rehome (so domain_finalize text is free)
| Cave | cont.32/33 | cont.34 |
|------|------------|---------|
| soft SA | pmu `@2C90` | unchanged (pmu still stub) |
| soft printf BANR | domain_finalize `@BAB0` | **heap_used `@F300`** |
| trap dump | domain_finalize `@BB40` | **hsm_start_finish `@F660`** |

### Peel bisect (on rehomed ladder)
| Config | Result |
|--------|--------|
| both stubbed (production) | **51b1babe + BANR** |
| real **domain_finalize** only | **51b1dead** + BANR (error hang; platform/domain table path) |
| real **console_init** only | mepc=`0x80042870` mcause=2 (jalr device_init → .bss garbage) |
| both real | same as console illegal |

`sbi_console_init`: `ld a5,72(a0)` platform → double-deref ops → `jalr a5`. Under DI scratch/platform console ops not wired → jump into `.bss`.

`sbi_domain_finalize`: platform finalize callback or `domidx_to_domain_table` walk → returns error → coldboot hang (`51b1dead`).

### Production
- Keep **stub0** console_init + domain_finalize.
- Cave rehome retained (domain_finalize body clean for a future peel once platform ops exist).
- hart_init real + CSR-probe skip (cont.33) unchanged.

### Soak
| Build | Result |
|-------|--------|
| DI cont.34 final | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
console_init, domain_finalize, pmu, heap freelist walkers, soft printf, global soft SA, hsm_start_finish; CSR probe tail in hart_init.

### Next
1. Soft/platform console ops or skip console device_init jalr.
2. Soft domain_finalize that marks domains ready without full table walk.
3. RTL: serialize CSR after `csrrw mtvec` for real hart CSR probes.
4. Real printf / freelist; soft-SA retirement; dual-c.mv s3.


## cont.35 — soft domain_finalize + real console_init (2026-08-08)

### Probe matrix
| Config | Result |
|--------|--------|
| real domain + skip hsm_hart_start only | **51b1dead** |
| real domain + skip plat jalr + skip hsm | mepc=`0x8f5a` mcause=4 |
| **soft domain_finalized=1, ret0** | **51b1babe + BANR** |
| **real console + c.li a0,0 @ab6a** (skip device jalr) | **51b1babe + BANR** |
| combo soft domain + real console | **51b1babe + BANR** |

### Production (`mk_plat_skip.py`)
1. **soft `sbi_domain_finalize`** @`0xBAA8`: `domain_finalized=1` via auipc/addi to `0x80042134`, `a0=0`, ret. (Full domain table walk still needs working `sbi_hsm_hart_start` / platform finalize.)
2. **real `sbi_console_init`**: keep body; **`c.li a0,0` @`0xab6a`** instead of `c.jalr a5` (device init fn-ptr was garbage → `.bss` illegal).

### Soak
| Build | Result |
|-------|--------|
| DI cont.35 production | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist walkers, soft printf, global soft SA, hsm_start_finish, domain_finalize (soft leaf), console device jalr, hart_init CSR probe tail.

### Next
1. Real domain table walk once hsm_hart_start is soft-safe / multi-hart ready.
2. Real console device (UART) ops wiring.
3. RTL: serialize CSR after `csrrw mtvec` for hart_init probes.
4. Real printf / freelist; soft-SA retirement; dual-c.mv s3.


## cont.36 — soft sbi_hsm_hart_start (2026-08-08)

### Probe matrix
| Config | Result |
|--------|--------|
| soft `hsm_hart_start` only (domain stays soft leaf) | **51b1babe + BANR** |
| soft hsm + **real domain_finalize** | **51b1dead** (platform finalize error path) |
| soft hsm + real domain + skip plat (`j baf0` / `c.li a0,0`) | mepc=`0x80008f5a` mcause=4 (`sbi_ecall_init` bad `s1` after domain walk) |
| soft hsm + real domain prologue → `j bbd4` flag epilogue | **51b1babe** (≈ soft leaf; stack-restore hazard if used long-term) |

**Conclusion:** `sbi_hsm_hart_start` soft ret0 is safe infrastructure. **Real domain table walk** still poisons later `sbi_ecall_init` under DI even with soft hsm + forced platform success. Keep **soft domain_finalize** leaf (cont.35).

### Production
- **stub0** `sbi_hsm_hart_start` @`0xF824` (ret0).
- Soft domain_finalize + real console (device jalr skip) unchanged.
- `hsm_hart_start_finish` still stub0 (trap cave @F660 in body).

### Soak
| Build | Result |
|-------|--------|
| DI cont.36 production | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_start_finish, hsm_hart_start, domain_finalize (soft leaf), console device jalr, hart_init CSR probe tail.

### Next
1. Bisect domain table walk corruption of ecall list / `s1`.
2. Move trap cave out of `hsm_start_finish` to peel finish.
3. RTL: CSR issue serialization until mtvec write commits (hart_init probes).
4. Real printf / freelist; soft-SA retirement; dual-c.mv s3.


## cont.37 — trap rehome + domain-walk / printf / finish probes (2026-08-08)

### Trap cave rehome
| Cave | cont.36 | cont.37 |
|------|---------|---------|
| trap dump | hsm_start_finish `@F660` | **pmu body `@2D00`** (after soft SA `@2C90`) |

`sbi_hsm_hart_start_finish` text is free; entry stays **stub0** (see below).

### Probe matrix
| Config | Result |
|--------|--------|
| real `sbi_printf` | mepc=`0x80012eb2` mcause=6 (FDT getprop `lenp` residual; keep soft BANR) |
| domain: plat ok + walk until spin_lock → flag | mepc=`0x8f5a` mcause=4 (ecall_init bad `s1`) |
| domain: plat ok + **load tables only** → flag | **51b1babe + BANR** |
| trap@2D00 + **real start_finish** | BANR, no babe (HSM state ≠ START_PENDING → hang path) |

**Domain residual pin:** corruption starts in walk body **`@0xbb20+`** (assigned-hart mask / spin_lock / hsm path). Loading `domidx_to_domain_table` alone is safe under DI.

**start_finish:** needs hart HSM data in START_PENDING (2) before peel; soft `hsm_hart_start` ret0 does not arm that.

### Production
- Trap cave `@0x2D00`; start_finish stub0; soft domain leaf; rest unchanged (cont.33–36).

### Soak
| Build | Result |
|-------|--------|
| DI cont.37 | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_start_finish, hsm_hart_start, domain_finalize (soft leaf), console device jalr, hart_init CSR probe tail.

### Next
1. Soft-arm HSM START_PENDING then peel start_finish.
2. Domain walk body bisect `@bb20..bb80` (mask/spin/hsm).
3. RTL: getprop lenp dual-issue; CSR probe expected-trap.
4. Real freelist; soft-SA retirement; dual-c.mv s3.


## cont.38 — real domain_finalize cut before scratch-table ld (2026-08-08)

### Domain walk bisect
| Cut site | Meaning | Result |
|----------|---------|--------|
| bb2c / bb3c / bb44 / **bb5c** | through assigned-bit check | **SUCCESS** |
| bb70 / bb78 | after hartindex→scratch `ld` | FAIL mepc=`0x8f5a` mcause=4 |

**Fault window:** `0xbb5c..0xbb70` — forms index into `hartindex_to_scratch_table` and **`ld a5,0(a5)`**. That load (or its address) poisons later `sbi_ecall_init` (`s1`).

### Production
1. **Real** `sbi_domain_finalize` body (no soft leaf).
2. **Soft-skip platform** finalize: `c.li a0,0` @`0xbac4`.
3. **Cut** @`0xbb5c` → `j 0xbbca` (restore s1–s7, set `domain_finalized`, ret 0).

### Soak
| Build | Result |
|-------|--------|
| DI cont.38 | **51b1babe + BANR** (WFI success) |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_start_finish, hsm_hart_start, domain scratch-table walk + platform ops, console device jalr, hart_init CSR probe tail.

### Next
1. Fix DI residual on hartindex→scratch load in domain walk.
2. Soft-arm HSM START_PENDING; peel start_finish without switch_mode (or payload path).
3. RTL: FDT lenp dual-issue; CSR expected-trap pairs.
4. Real freelist; soft-SA retirement; dual-c.mv s3.


## cont.39 — domain walk past scratch ld; pin residual at domain_hart_ptr (2026-08-08)

### Fine bisect (cut = j bbca *before* site executes remaining)
| Cut site | Ran through | Result |
|----------|-------------|--------|
| bb60 (after slli) | index form start | SUCCESS |
| bb64 (after srli) | index form | SUCCESS |
| **bb68** (after `c.add a5,s6; c.ld a5,0(a5)`) | **scratch-table load** | **SUCCESS** |
| bb70 (after `ld a4,0(s7)`) | domain_hart_ptr_offset load | FAIL `@0x8f5a` mcause=4 |

**Scratch-table ld is green.** Poison starts at **`ld a4,0(s7)`** (`domain_hart_ptr_offset`) or later walk (spin/hsm/stores). Full walk with soft `a5=s4` still FAIL → residual is past scratch, not only the table index.

### Production
- Real domain through **scratch ld** (`bb64/66`).
- **Cut `@bb68` → `j bbca`** (set `domain_finalized` + restore).
- Platform still `c.li a0,0` @bac4.

### Soak
| Build | Result |
|-------|--------|
| DI cont.39 | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_start_finish, hsm_hart_start, domain walk from `domain_hart_ptr_offset` ld onward, console device jalr, hart_init CSR probe tail.

### Next
1. Soft-skip / fix `domain_hart_ptr_offset` path + remainder of walk.
2. Soft start_finish (no switch_mode) for HSM state peel.
3. RTL: FDT lenp; CSR expected-trap.
4. Freelist; soft-SA; dual-c.mv s3.


## cont.40 — full domain walk with soft-zero domain_hart_ptr (2026-08-08)

### Finding
With `*domain_hart_ptr_offset == 0`, the assigned-hart body (spin_lock / hsm / domain↔scratch link) never runs, and the **full domain list iteration is green** under DI.

| Config | Result |
|--------|--------|
| cont.39 cut @bb68 (after scratch ld) | SUCCESS |
| full walk + **sd zero,0(s7)** @bb20 | **SUCCESS** |
| full walk + real non-zero hart_ptr body | FAIL ecall `@0x8f5a` |
| misaligned 4B patches @bb6a | FAIL (artifact) |

### Production
1. Real `sbi_domain_finalize` (no mid-walk cut).
2. Platform jalr → `c.li a0,0` @bac4.
3. **`sd x0, 0(s7)` @bb20** after `s7 = &domain_hart_ptr_offset` — soft-zero so assigned body is skipped; domains still walked; `domain_finalized` set naturally.

### Soak
| Build | Result |
|-------|--------|
| DI cont.40 | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_start_finish, hsm_hart_start, domain assigned-hart body (`domain_hart_ptr` non-zero path), console device jalr, hart_init CSR probe tail.

### Next
1. DI fix for assigned-hart domain↔scratch link (when hart_ptr non-zero).
2. Soft start_finish without switch_mode.
3. RTL: FDT lenp; CSR expected-trap.
4. Freelist; soft-SA; dual-c.mv s3.


## cont.41 — soft start_finish (no switch_mode) (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| soft finish: fake cmpxchg old=2, skip switch_mode, restore+ret | **SUCCESS** |
| real domain_hart_ptr + cut assigned body @bb70/74/78 | FAIL ecall (poison from non-zero hart_ptr path) |
| domain soft-zero + **j bb2c** (CF-correct) | FAIL ecall even with s9 save |
| domain soft-zero **fall-through bb24** (cont.40) | **SUCCESS** |
| cont.40 domain + soft finish | **SUCCESS** |

**Domain note:** `sd zero,0(s7)` @bb20 overwrites `(c.sd s9; c.j bb2c)` and falls into next-domain load — skips first domain's `bb2c` entry. Restoring `j bb2c` after zero still FAILS under DI; keep fall-through.

### Production
1. Domain: cont.40 soft-zero + fall-through (unchanged CF trade-off).
2. **`sbi_hsm_hart_start_finish`**: real prologue; `li a0,2` instead of cmpxchg; at success path **j ret-cave** (restore frame, `a0=0`, ret) — **no `sbi_hart_switch_mode`** so coldboot can hit success cookie @996.

### Soak
| Build | Result |
|-------|--------|
| DI cont.41 | **51b1babe + BANR** |
| concurrent | **SUCCESS 200155** |

### Still soft/stub
pmu, heap freelist, soft printf, soft SA, hsm_hart_start, start_finish cmpxchg/switch_mode, domain assigned-hart body, console device jalr, hart_init CSR probe tail.

### Next
1. DI fix for domain↔scratch assigned path / j-bb2c + zero.
2. Real start_finish → payload/switch_mode path (separate success criteria).
3. RTL: FDT lenp; CSR expected-trap.
4. Freelist; soft-SA; dual-c.mv s3.

## cont.42 — domain cut@bb68 + soft heap freelist (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| base (cont.41 production) | **SUCCESS** `51b1babe` |
| natural bb20 + **cut@bb68→bbca** (drop soft-zero) | **SUCCESS** |
| soft heap free=2047 used=0 scratch_used=0 | **SUCCESS** |
| bb68 + soft heap | **SUCCESS** |

### Production
1. **Domain:** restore natural `bb20` (`c.sd s9; j bb2c` from diag — no soft-zero). Real walk through assigned-bit + scratch-table ld; **cut `@bb68 → j bbca`** before `ld domain_hart_ptr_offset` (cont.39 residual). Platform jalr still soft `c.li a0,0 @bac4`.
2. **Heap freelist soft returns** (not plain stub0): `sbi_heap_free_space` → `a0=2047`; `sbi_heap_used_space` / `sbi_scratch_used_space` → `a0=0` (`addi; c.jr ra`). Soft printf BANR cave remains in used body `@F300`.
3. Soft `start_finish` (cont.41), soft `hsm_hart_start`, soft SA/pmu caves, soft printf, CSR probe cut — unchanged.

### Why
Drops cont.40 soft-zero fall-through CF trade-off (overwrote `j bb2c`, skipped first-domain entry). Cont.39-style cut keeps domain table walk green under DI while still skipping the assigned-hart poison path. Richer freelist returns prepare for later freelist peel without changing success cookie.

### Soak
| Build | Result |
|-------|--------|
| DI cont.42 | **51b1babe + BANR** (prod rebuild) |
| concurrent | hold **SUCCESS 200155** (no concurrent regress this cont) |

### Still soft/stub
pmu, soft printf, soft SA, hsm_hart_start, start_finish cmpxchg/switch_mode, domain assigned-hart body (`domain_hart_ptr`+), heap freelist (soft ret, not real), console device jalr, hart_init CSR probe tail.

### Next
1. DI fix for `domain_hart_ptr_offset` assigned path (peel cut@bb68).
2. Real start_finish → payload/switch_mode (separate success criteria).
3. RTL: FDT lenp; CSR expected-trap dual-issue.
4. Real freelist / soft-SA / dual-c.mv s3.

## cont.43 — domain past bb68 residual pin (2026-08-08)

### Probes (all on cont.42 prod base)
| Config | Result |
|--------|--------|
| natural bb68 + `li a4,0` @bb6a (beqz→**bb24** continue) | FAIL `mepc=0x8f5a` mcause=4 |
| natural through ld; cut@bb70/78 → **bb24** | FAIL same |
| soft-zero cave @2D40 + natural bb68 | FAIL same |
| real `ld a4` + **j bbca** @bb6e | FAIL same |
| `li a4,0` + **j bbca** @bb6e | FAIL same |
| real ld+beqz; non-zero → j bbca | FAIL same |
| BSS `domain_hart_ptr_offset` zero (not in PT_LOAD) | n/a → fallback cut@bb68 **SUCCESS** |

### Pin
Production **cut `@bb68 → j bbca`** is still the correct soft boundary. Under soft-SA the hartindex→scratch load often yields **null `a5`**, so natural `beqz a5, bb24` **continues** the multi-hart/domain loop. That multi-iteration poisons `ecall_init` (`mepc=0x8f5a` mcause=4). Forced exit at bb68 avoids the loop. Paths that only skip the assigned body but still **bb24-continue** fail the same way; even `j bbca` *after* natural `beqz a5` fails when `a5==0` takes bb24 first.

cont.40 soft-zero fall-through "worked" by **skipping domain0 entry** (`bb20` overwrite → fall `bb24`), not by completing a real assigned walk.

### Production
**Unchanged cont.42** (cut@bb68 + soft heap + soft finish).

### Next
1. Full domain walk needs real scratch table (peel soft-SA) **or** DI fix for multi-iter / assigned body.
2. Real start_finish / printf (FDT lenp) / freelist / CSR probe — other soft fronts.

## cont.44 — real printf / FDT lenp residual map (2026-08-08)

### Probes (cont.42 base; restore natural `sbi_printf` @A980)
| Config | Result |
|--------|--------|
| real printf only | FAIL `mepc=0x80012eb2` mcause=6 (`sw a0,0(s2)` lenp) |
| nop lenp sw @12e9c+12eb2 | FAIL `mepc=0x80013128` mcause=6 (`sw s1,0(s3)`) |
| nop only 12eb2 | FAIL same 13128 |
| align-safe cave @12e9c/12eb2 | FAIL 13128 |
| nop 4 known lenp sw | FAIL `mepc=0x2` mcause=2 (illegal @ null) |
| nop all imm0 `sw` in FDT prop range (10 sites) | FAIL `mepc=0x2` mcause=2 |

### Pin
DI leaves **lenp out-pointers misaligned/corrupt** across multiple FDT helpers (`fdt_get_property_by_offset_`, `fdt_get_property_namelen_`, …). Nopping the stores unblocks the first faults then dies on a bad control transfer (`mepc=0x2`). Soft BANR printf remains the correct ladder boundary until an RTL dual-issue fix for the lenp/stack pointer path (or a fuller FDT soft-shim).

### Production
**Unchanged cont.42.**

### Next
1. RTL: dual-issue lenp / stack-pointer corruption on FDT `sw *,0(lenp)`.
2. Domain multi-iter / soft-SA / assigned body.
3. Real start_finish; freelist; CSR expected-trap.

## cont.45 — real sbi_hsm_hart_start (2026-08-08)

### Probes (cont.42 base)
| Config | Result |
|--------|--------|
| real `sbi_scratch_alloc_offset` | FAIL early `mepc=0x2` mcause=2 `coldboot_done=0` |
| real SA + natural domain / cut@bb78 | FAIL same |
| real SA nop-memset | FAIL same |
| real `sbi_heap_free_space` | FAIL `coldboot_done=1` BANR but no `51b1babe`, `mepc=0x2` |
| real platform jalr `@bac4` | FAIL `51b1dead` |
| real console device jalr `@ab6a` | FAIL `mepc=0x80042870` mcause=2 |
| real `sbi_hsm_hart_start` (unstub `@F824`) | **SUCCESS** |
| real start_finish cmpxchg (keep ret cave) | FAIL no cookie (HSM state / cmpxchg) |

### Production
1. **Peel** soft stub0 on `sbi_hsm_hart_start` — natural body from diag.
2. Domain cut@bb68, soft heap, soft SA, soft printf, soft start_finish, CSR probe cut — unchanged.

### Notes
Domain assigned-body still cut before HSM start; real `hsm_hart_start` is exercised by other coldboot callers and is DI-clean. Soft-SA remains required (real SA dies early under DI). Platform finalize callback and console device ops still soft-skipped.

### Soak
| Build | Result |
|-------|--------|
| DI cont.45 | **51b1babe + BANR** (prod rebuild) |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf, soft SA, start_finish cmpxchg/switch_mode, domain assigned-hart body + multi-iter, heap freelist soft ret, console device jalr, platform finalize jalr, hart_init CSR probe tail.

### Next
1. Soft-SA retirement (DI residual early `mepc=0x2`).
2. Domain multi-iter / assigned body; real start_finish.
3. RTL: FDT lenp; CSR expected-trap; SA path.

## cont.46 — real `ld domain_hart_ptr_offset` then exit (2026-08-08)

### Probes (cont.45 base)
| Config | Result |
|--------|--------|
| force `a5=1`; real `ld a4`; cut@bb78 (after poison `ld@bb72`) | FAIL `mepc=0xbb72` mcause=4 |
| force `a5=1 a4=0`; **j bbca** | **SUCCESS** |
| force `a5=1`; real `ld a4`; **j bbca** (before bb70) | **SUCCESS** |
| force `a5=1 a4=0`; continue multi-iter | **SUCCESS** |
| real `a5`; real `ld a4`; **j bbca** | **SUCCESS** |
| natural bb68 + `li a4,0` multi-iter | FAIL `mepc=0x8f5a` mcause=4 |
| natural full domain walk | FAIL same ecall poison |

### Pin
- **`ld a4,0(s7)`** (`domain_hart_ptr_offset`) is DI-clean when followed by finalize exit.
- Assigned body (`add a5,a5,a4` / `ld a5,0(a5)` @bb70+) still poison if `a5` is a fake non-pointer.
- **Natural multi-iter** (null-scratch `beqz a5,bb24` loops) still poisons ecall — even with real `hsm_hart_start`. Forced non-null scratch + zero hart_ptr multi-iter can succeed, but is less correct than exit-after-ld.

### Production
Replace cont.42 `jal bbca` @bb68 with cave `@0x2D40`:
1. `ld a4, 0(s7)` — real domain_hart_ptr_offset load
2. `j bbca` — set `domain_finalized`, restore, ret

Keeps cont.45 real `hsm_hart_start`, soft SA/printf/heap/start_finish.

### Soak
| Build | Result |
|-------|--------|
| DI cont.46 | **51b1babe + BANR** (prod rebuild) |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf, soft SA, start_finish cmpxchg/switch_mode, domain assigned body + natural multi-iter, heap freelist soft ret, console device jalr, platform finalize jalr, hart_init CSR probe tail.

### Next
1. Domain assigned body with **real** scratch pointer (needs soft-SA retirement).
2. Natural multi-iter DI fix (`mepc=0x8f5a`).
3. Real start_finish; RTL FDT lenp / CSR / SA.

## cont.47 — real `sbi_scratch_alloc_offset` (nop spin locks) (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| real SA full (locks + memset) | FAIL early `mepc=0x2` `coldboot_done=0` |
| real SA; **nop** `spin_lock`/`spin_unlock` (3 sites) | **SUCCESS** |
| real SA; nop locks + nop memset | **SUCCESS** |
| SA force size0 only | FAIL `51b1dead` |
| ld a4; if0 bbca else bb70 (soft SA) | **SUCCESS** (a4 still 0 → bbca) |
| real early_init callback | FAIL `mepc=0x80011470` mcause=4 |
| **cont.47 prod** | **SUCCESS** |
| natural multi-iter / full domain + real SA | FAIL `mepc=0x8f5a` mcause=4 |
| real SA **with** locks restored | FAIL `mepc=0x2` (confirms pin) |

### Pin
DI residual on **`spin_lock` / `amoadd.w.aqrl`** path inside SA (not memset, not extra_offset math). Single-hart coldboot can skip the lock; real memset + table walk + `extra_offset` update are DI-clean.

### Production
1. **Retire** soft SA cave `@2C90` — natural `sbi_scratch_alloc_offset` from diag.
2. **Nop** `jal spin_lock` `@39ac`, `jal spin_unlock` `@39d2` / `@3a1c`.
3. Keep cont.46 domain ld-hart_ptr→bbca, cont.45 real hsm_start, soft printf/heap/start_finish, pmu stub (trap caves).

### Soak
| Build | Result |
|-------|--------|
| DI cont.47 | **51b1babe + BANR** |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf, start_finish cmpxchg/switch_mode, domain assigned body + natural multi-iter, heap freelist soft ret, console device jalr, platform finalize jalr, SA spin locks, hart_init CSR probe tail, early_init callback.

### Next
1. RTL: `spin_lock` / AMO dual-issue (`mepc=0x2`); FDT lenp; CSR expected-trap.
2. Domain natural multi-iter (`0x8f5a`); assigned body with non-zero hart_ptr.
3. Real start_finish; early_init; freelist.

## cont.48 — deeper `start_finish` (thru atomic_write) (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| leaf soft `spin_lock`/`unlock` (global) | FAIL `mepc=0x80004850` mcause=2 |
| real `heap_free_space` | FAIL `mepc=0x2` |
| soft global `atomic_cmpxchg` ret2 + real finish jal | **SUCCESS** |
| + natural success path; cut `@F6BC` before `switch_mode` | **SUCCESS** |
| + soft `atomic_write` | **SUCCESS** (prefer real write) |
| real `atomic_cmpxchg` body; finish still `li a0,2` | **SUCCESS** |
| finish-local cmpx cave; global cmpx natural | **SUCCESS** |

### Production
1. **`F66E`:** `jal CMPX_CAVE@2C90` — cave `li a0,2; j F672` (fake expected-old without stubbing global `atomic_cmpxchg`).
2. **Natural** success path `F696`–`atomic_write` (`F6AA`).
3. **`F6BC`:** `j FINISH_RET@EC00` instead of `sbi_hart_switch_mode` — restore frame, ret to coldboot success cookie.
4. Keep cont.47 real SA (nop locks), cont.46 domain ld-hart_ptr, cont.45 real hsm_start.

### Soak
| Build | Result |
|-------|--------|
| DI cont.48 | **51b1babe + BANR** |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf, start_finish cmpx result + no switch_mode, domain assigned/multi-iter, heap freelist soft ret, console/platform jalrs, SA spin locks, CSR probe tail, early_init.

### Next
1. Real `atomic_cmpxchg` / HSM state for finish; then `switch_mode` (payload).
2. Domain multi-iter / assigned body; freelist.
3. RTL: AMO/spin_lock; FDT lenp; CSR expected-trap.

## cont.49 — real heap_free + soft switch_mode handoff (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| force `*state=2` + **real** `atomic_cmpxchg` (LR/SC) | FAIL hang `npc≈0x84c`, no `51b1babe` (`[1000]=51b1c001`) |
| real cmpxchg no force | FAIL same (LR/SC DI residual) |
| domain multi-iter `a4=0` | FAIL `mepc=0x8f5a` mcause=4 |
| real `jal switch_mode` (natural body) | FAIL `mepc=0xef5e` mcause=2 |
| real `jal switch_mode`; **soft entry → success cookie** | **SUCCESS** |
| real `heap_free` + nop its spin lock/unlock | **SUCCESS** |

### Production
1. **`sbi_heap_free_space`:** natural body; nop `jal spin_lock` `@F2BE` / `spin_unlock` `@F2E4`. Used/scratch still soft0 (printf cave).
2. **Finish `@F6BC`:** natural `jal sbi_hart_switch_mode` (no FINISH_RET cut).
3. **`switch_mode` `@EF5E`:** `j SUCCESS@EF70` — success cookie + WFI (payload/S-mode still soft).
4. Soft finish cmpx cave unchanged (real LR/SC still stuck under DI).

### Soak
| Build | Result |
|-------|--------|
| DI cont.49 | **51b1babe + BANR**, `wfi=1` |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf, finish cmpx result (not LR/SC), switch_mode body/payload, domain assigned/multi-iter, heap used/scratch soft, console/platform jalrs, SA+heap spin locks, CSR probe tail, early_init.

### Next
1. RTL: LR/SC `atomic_cmpxchg`; AMO `spin_lock`; FDT lenp; CSR probes.
2. Domain multi-iter / assigned body.
3. Real switch_mode / S-mode payload; freelist used path.

## cont.50 — soft cmpx ld/sd + real heap_used (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| soft `atomic_cmpxchg` = ld/bne/sd (no LR/SC); real finish `jal cmpxchg` | **SUCCESS** `wfi=1` |
| domain multi-iter / full / cut@bb78 | FAIL `mepc=0x8f5a` mcause=4 |
| relocate soft printf `@2C98`; real `heap_used` nop locks | **SUCCESS** |

### Production
1. **`atomic_cmpxchg`:** non-LR/SC body (`ld; bne; sd; ret old`) — real compare-exchange semantics for single-hart; finish uses **natural** `jal atomic_cmpxchg` (drops local `li a0,2` cave).
2. **Soft printf** cave moved to `@0x2C98` (pmu free body); frees `heap_used` text.
3. **Real `sbi_heap_used_space`** + nop spin lock/unlock (`@F314`/`@F33E`); free already real (cont.49).
4. Domain cut/ld-hart_ptr, soft switch_mode entry, real SA-nolock — unchanged.

### Soak
| Build | Result |
|-------|--------|
| DI cont.50 | **51b1babe + BANR**, `coldboot_done=1` |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf (FDT lenp), switch_mode body/payload, domain assigned/multi-iter, scratch_used soft, console/platform jalrs, SA+heap spin locks, CSR probe tail, early_init; atomic_cmpxchg non-LR/SC shim.

### Next
1. Domain multi-iter (`0x8f5a`); assigned body.
2. RTL: LR/SC; AMO spin; FDT lenp; CSR.
3. Real switch_mode / S-mode payload; scratch_used.

## cont.51 — real scratch_used + switch_mode prologue (2026-08-08)

### Probes
| Config | Result |
|--------|--------|
| real `sbi_scratch_used_space` + nop spin | **SUCCESS** |
| domain multi-iter `a4=0` + **soft ecall_init** | **SUCCESS** |
| multi-iter `a4=0` + ecall skip body `@8f5a→8f72` | **SUCCESS** |
| multi-iter `a4=0` + `bb24→bbca` (no soft ecall) | FAIL `mepc=0x8f5a` |
| natural bb68 + `bb24→bbca` | FAIL same |
| switch_mode natural prologue → fall into success cave | **SUCCESS** |

### Pin
Domain multi-iter with `a4=0` (skip assigned body) is itself DI-clean. Residual is **later `sbi_ecall_init`**: multi-iter / `bb24` path leaves `sbi_ecall_exts` / `s1` poisoned so `ld a5,0(s1)` @`8f5a` faults (mcause=4). Soft ecall unblocks multi-iter but regresses real ecall — keep production domain cut + real ecall.

Hang cave `@EF4C` overran into switch_mode `@EF5E`; cont.51 restores natural prologue after hang emission.

### Production
1. **Real `sbi_scratch_used_space`**; nop spin `@3A4E`/`@3A62` (with heap free/used).
2. **Restore switch_mode prologue** `EF5E..EF6E` after hang cave; success cookie still `@EF70`.
3. Domain ld-hart_ptr→bbca, soft cmpx ld/sd, soft printf, real SA-nolock — unchanged. **No** soft ecall.

### Soak
| Build | Result |
|-------|--------|
| DI cont.51 | **51b1babe + BANR**, `coldboot_done=1` |
| concurrent | hold **SUCCESS 200155** |

### Still soft/stub
pmu, soft printf (FDT lenp), switch_mode body/payload, domain assigned/multi-iter (keeps cut; ecall coupling), freelist spins, SA spins, CSR probe tail, early_init; atomic_cmpxchg non-LR/SC shim.

### Next
1. Fix ecall poison from domain multi-iter (keep real ecall).
2. Domain assigned body; real switch_mode / payload.
3. RTL: LR/SC; AMO spin; FDT lenp; CSR.


## Soft-ladder promotion (codebase)

Binary cont.33–51 peels are inventoried for **promotion out of ELF patching**:

- **Full cont.2–51 map:** `soft-ladder/CONT-FULL-MAP.md` (disposition of every cont pin)
- Map / iteration: `soft-ladder/README.md`, `soft-ladder/inventory.yaml`, `soft-ladder/ITERATION.md`
- Buckets: **B1** RTL DI residuals, **B2** OpenSBI/platform policy, **B3** sim harness only
- Order: B1 first → B3 SUCCESS definition → B2 source profile → retire `tmp-dual-ci/mk_plat_skip.py`
- **Gates:** `verif/regress/soft-ladder-di-regress.sh` (step1); `soft-ladder-opensbi-soak.sh` (cookie)
- **Default soft ELF (2026-08-08 cookie green on work-ver-smt2):** natural spins + natural
  LR/SC cmpx + natural CSR probes; **soft malloc**; **c.mv nops** (PEEL_CMV still red);
  soft printf / domain cut / switch_mode success cave remain
- Bisect: `SOFT_SPIN` / `SOFT_CMPX` / `SOFT_CSR` / `PEEL_MALLOC` / `PEEL_CMV`

Do not add new hard-coded VAs without an inventory id.

