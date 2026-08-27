# Testharness proxy — harness of record for multi-threading

**Normative for SMT / soft-ladder / dual-hart / 8-hart evidence.**  
Implementation: `verif/regress/remote/testharness_proxy.py`  
Wrappers: `verif/regress/remote-testharness.sh` · `cva6-build remote`  
Host default: `ovh_calltorch` (`TH_REMOTE_HOST`) · remote root `/opt/testharness`

This file is the **execution plan**. Soft-ladder SUCCESS, A/B blame, and I4dp Linux-boot
greens are defined elsewhere; this document says **where those results must be produced**.

Cross-refs: [`soft-ladder/README.md`](soft-ladder/README.md) ·
[`soft-ladder/b3-sim-harness.md`](soft-ladder/b3-sim-harness.md) ·
[`linux-boot-scale.md`](linux-boot-scale.md) (OpenSBI steps × fetch_B combos × envelopes) ·
[`../firmware-boot-principles.md`](../firmware-boot-principles.md) ·
[`AGENTS.md`](../../AGENTS.md) §0.8 · [`AGENTS-build.md`](../../AGENTS-build.md) Remote testharness.

---

## 0. Rule

Every multi-threading **evidence run** goes through the proxy. That includes:

| Kind | Examples |
|------|----------|
| Spike ISS | directed minis (`soft-ladder-di` Spike leg), dual-park, H-edge when used as SMT evidence |
| Variane soaks | hold / nat / peel, `soft-ladder-osbi`, cookie classify |
| Peels | `PEEL_FDT_GETPROP`, `PEEL_FDT_NEXT_TAG`, combined walk, TRACE |
| Directed RTL minis | `mini_fdt_*`, `mini_stq_*`, frame-32 alias |
| Linux-boot cap | I4dp `g6lc64_server_math_v` (2 harts) and `g6lc64_ooo_server` (4×2 = 8 logical harts) at 200M cycles |

**Not evidence** (may compile locally, must not be cited as a pin/soak/peel result):

- WSL or Windows `work-ver-*/Variane_testharness`
- ad-hoc `p<N>_*.py` / `p<N>_*.sh` (gitignored)
- `software/smt2-linux/soft-ladder/run_mini_*.sh` against a local Mdir
- `soft-ladder-opensbi-soak.sh` / `soft-ladder-di-regress.sh` invoked on the Windows/WSL host except as the **payload** the proxy `soak` / `run` already wraps remotely

Compile-only (`SOFT_LADDER_COMPILE_ONLY=1`, `riscv-none-elf-gcc`) may stay local. The **run** that produces tohost / cookie / TRACE / hangpc does not.

---

## 1. Why (invariants this preserves)

1. **One toolchain.** Remote is pinned Verilator **5.008** + xpack gcc **14.2.0-3** + Spike (`testharness_proxy.py` `VERILATOR_VERSION` / `XPACK_GCC_VERSION`). Local WSL and the builder must not fork a second “green.”
2. **I4dp Linux boots live on the builder.** `work-ver-server-math-v-B` (2 harts) and `work-ver-ooo-server-B` (8 logical harts) already reach harness `tohost = 0` at 200M cycles. A B1 candidate that only soaks `work-ver-smt2-fw64-B` on WSL can regress those without anyone noticing.
3. **Flavour Mdirs must not mix.** Proxy `FLAVOURS`: `B` → `work-ver-smt2-fw64-B` (stock `Flist.cva6` / `G6LC_FETCH_B`); `legacy` → `work-ver-smt2-fw64-legacy`. `--verlib` for I4dp packages. Never copy objects between them.
4. **SSH rc is not the result.** A long `run` can return **rc=255** on ControlMaster/SSH drop while `runs/<tag>/run-*.log` shows success. **Classify from the log** (pulled to `remote-runs/<tag>/` with `--pull`).
5. **Harness tohost is not soft-ladder SUCCESS.** Cookie `51b1babe` is osbi green. I4dp `*** SUCCESS *** (tohost = 0)` at the cycle cap is *no-trap / no-hang*, not a peel. S4 180k: `_v` can print that SUCCESS while `coldboot_done=0` and WFI at `_start_hang` after illegal `@46f2c` — classify hangpc, not the cap string.

I4dn IPI hart-seen stays. I4cd I$ identity, I4ce G1ao-on-cancel, I4cf `keep_stack_frame` stay **reverted**.

---

## 2. Remote layout

```text
/opt/testharness/
  toolchains/     verilator, riscv-gcc, spike (setup, once)
  repo/           rsync whitelist (sync)
  work/<verlib>/  Verilator --Mdir (build)
  runs/<tag>/     ELF + run-<flavour>.log  (run / soak / py)
  cache/          downloads + optional Mdir output-cache
```

Per-test `run` uploads **only the ELF** (content-addressed). `sync` is the RTL/TB
whitelist (`core/`, `corev_apu/`, `verif/`, pin ELF, `mk_plat_skip.py`, …) — not
`work-ver*/`, not `docs/`.

---

## 3. Command map (MT work → proxy)

First time (or after a dead builder): `doctor` → `setup` → `sync` → `build B` (and
`build legacy` when A/B blame is in play). After RTL: `sync` + `build B --no-clean`
(incremental Mdir). **2026-08-25:** remote `legacy` harness is absent (`doctor`
prints `legacy : -`). Do not cite A/B until `build legacy`; do not copy B objects
into the legacy Mdir.

| MT work | Proxy invocation | Log / SUCCESS |
|---------|------------------|---------------|
| Directed mini (Variane) | `run <mini.elf> --flavour B --tag b1-<id> --pull` plus `--plusarg +tohost_addr=0x…` when the TB does not discover `tohost` | mini tohost contract in `runs/b1-<id>/run-B.log` |
| S1 / Linux-boot mini battery | `bash verif/regress/remote/s1-linux-boot-regress.sh` (optional `S1_REGRESS_SOAK=1`) | PASS/RED/HANG from pulled `remote-runs/s1reg-*/run-B.log`; cap `tohost=0` at that run's `+time_out` is hang. nackinv + addi-sp: h0/tight/nt-osbi **PASS** (nackinv-d1 hung h0 @40000 — reverted). `mini_stq_alias_jal` **PASS @986** hart1 WFI park. wrack TRACE is opt-in (`SOFT_LADDER_BUILD_CXXFLAGS=-DG6LC_TRACE_WT_WBUFFER`); default build must not poke inlined `wr_ack`. |
| Spike ISS | `shell --cmd-file` with remote `$PATH` spike against the uploaded ELF; keep the log under `runs/<tag>/`. **Gap:** no `spike` subcommand yet — do not fall back to host Spike as the recorded result. | Spike `tohost=1` / mem write in that log |
| OpenSBI hold | `soak --flavour B --hold` or `--env SOFT_LADDER_HOLD=1` | cookie `51b1babe` in soak log |
| OpenSBI nat / default mk | `soak --flavour B --skip-build` with pin/default ELF already on the builder (`sync` includes `*.pin-bc7ed11d.elf`) | cookie only |
| Peel | `soak --flavour B --env PEEL_FDT_GETPROP=1` (add `PEEL_FDT_NEXT_TAG=1` for combined) | cookie or pin mepc from log; **not** harness tohost |
| TRACE | `py software/smt2-linux/soft-ladder/trace_peel_both.py --data …/fw_payload_peel_both.elf --data …/trace-s1-nt-alias.spec --tag s1-peel-trace --pull` (S1 peel); `py …/trace_mini_nt_nl.py --data …/mini_fdt_nt_osbi_tight.elf --data …/trace-s1-nt-nl.spec --tag s1-tight-hold-trace --pull` (S1 tight + `log hold`); `py …/trace_h0_hang.py --data …/mini_fdt_nt_osbi_h0.elf --data …/trace-s1-h0-hang.spec --tag s1-h0-keep-hang-trace --pull` (h0 hang tail, `log after=`); or `--env CVA6_TRACE=1` + a named probe | `[trace]` / classify in `remote-runs/<tag>/output/` |
| A/B blame | same ELF, `soak --flavour legacy` then `soak --flavour B` | A-green/B-red ⇒ fetch_B; never silent flavour fallback |
| I4dp 2-hart Linux cap | `run <fw.elf> --verlib work-ver-server-math-v-B --time-out 200000000 --tag i4dp-smv --pull --plusarg +tohost_addr=0x80041730` | log `tohost = 0` at cap **and** hangpc `coldboot_done`/not `_start_hang`. Live ELF `linux-g6lc64_server_math_v/fw_payload.elf` md5 `834d65e0` is **R3a** OpenSBI+`smt2_sbi_dual` (`.payload` 0x178), **not** Linux Image. v4 4-cpu ELF `203f9359` is the DTS-matched artifact (do not replace `834d65e0`) |
| I4dp 8-hart Linux cap | same with `--verlib work-ver-ooo-server-B --tag i4dp-ooo`; `fw_payload_ooo_server.elf` (`7fea71c9`); `ooo_server/fw_payload.elf` is the same `834d65e0` R3a ELF as `_v`. Image still external (`r3b-linux-image`) | log `tohost = 0` at cap |

`cva6-build remote …` is the same proxy with passphrase cache in
`build-platform/.remote-ssh-creds` (gitignored).

Credentials: `$TH_SSH_PASSPHRASE` or `~/.config/librecore/th-remote.pass` — never in-repo.

---

## 4. Classification (log, not process rc)

| Result class | Authoritative signal | Not sufficient |
|--------------|----------------------|----------------|
| Soft-ladder / osbi SUCCESS | `[cookie-exit]` or `[1000]=…51b1babe` in the soak/`run` log | harness `SUCCESS (tohost=0)`, proxy rc=0, BANR alone |
| Soft-ladder FAIL / pin | `[pin-exit]` / trapdump mepc+mcause in the log | proxy rc≠0 without reading the log |
| Mini PASS | that mini’s tohost contract in `run-B.log` | local WSL tohost |
| I4dp boot green | `*** SUCCESS *** (tohost = 0)` at 200M cap in `runs/<tag>/run-*.log` | treating that as cookie green |
| Transport failure | proxy rc=255 **and** log missing or truncated | treating 255 as RTL FAIL |

Pull with `--pull` (or `pull`) before citing a result. Quote the log path in ITERATION.

---

## 5. Firmware path (8-hart)

Do not invent a second OpenSBI tree. `software/smt2-linux/scripts/build-opensbi-smt2.sh`
already honours:

| Env | Default | 8-hart override |
|-----|---------|-----------------|
| `G6LC_SMT2` | `software/smt2-linux` | same |
| `OPENSBI_SRC` | `$OUT/opensbi` | existing checkout |
| `G6LC_DTS` | `corev_apu/bootrom/ariane-smt2.dts` | `corev_apu/bootrom/ariane-ooo-server.dts` |
| `G6LC_DTB` | `$OUT/ariane-smt2.dtb` | matching ooo-server dtb |
| `tohost` | `0x80041730` | same symbol on both payloads |

`NrCores×NrHarts` in that DTS is the 8-logical-hart CLINT map. Soft-ladder smt2
soaks stay on `ariane-smt2.dts` unless the experiment is I4dp.

---

## 6. Known proxy gaps (close in-proxy, not with `p<N>`)

These are B3 harness items. Until they land, use `shell --cmd-file` / extra
`--plusarg` / `--env` — still through the proxy.

| Gap | Effect | Interim |
|-----|--------|---------|
| No `spike` subcommand | ISS has no first-class `run` twin | `shell --cmd-file` + remote spike; log under `runs/<tag>/` |
| `run` omits `+tohost_addr` and `CVA6_*` | minis/osbi may not cookie-exit or detect tohost | `--plusarg` and `py --env` |
| `soak` has no `--tag` / `--pull` | logs stay only on the builder | `pull` the soak rundir, or `shell` to tail then `pull` |
| `FLAVOURS` is only `B`/`legacy` | I4dp Mdirs are opt-in | `--verlib work-ver-server-math-v-B` / `work-ver-ooo-server-B` |
| Classify-from-log is not in the Python rc | callers must read the log | ITERATION quotes the log; do not trust `command completed rc=` |

Do **not** reopen these as local WSL workarounds.

---

## 7. B1 candidate checklist (binds every MT RTL edit)

Before calling a class landed:

- [ ] Mini or peel that moved the pin was a **proxy** `run` / `soak` / `py`, log pulled.
- [ ] Default / hold cookie still `51b1babe` via `soak --flavour B` (hygiene).
- [ ] I4dp 2-hart and 8-hart 200M-cap logs still `tohost = 0` (or explicitly deferred with a reason — not “WSL looked fine”).
- [ ] I4dn still in `core/cva6.sv`; I4cd / I4ce / I4cf not re-landed.
- [ ] A/B pair used the proxy flavours, not a mixed local Mdir.

---

## 8. How to start the next MT unit of work

```text
0. testharness_proxy.py doctor          # fail closed if SSH/builder down
   (scale order: linux-boot-scale.md S0–S9; OpenSBI O0–O8)
1. sync && build B                      # after RTL; --verlib for I4dp packages
2. Directed mini: gcc locally OK → run ELF --flavour B --tag b1-… --pull
3. Spike: remote spike via shell --cmd-file; same tag dir
4. soak --flavour B [--env PEEL_…=1]    # cookie from log
5. I4dp hygiene if the class touches SMT ready / IPI / fetch / STQ
6. Quote runs/<tag>/run-*.log in ITERATION — not proxy rc
```

If `doctor` cannot reach `ovh_calltorch`, **stop and report**. Do not substitute a
local Variane soak as the recorded result.
