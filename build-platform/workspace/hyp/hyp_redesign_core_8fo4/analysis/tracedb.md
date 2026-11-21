# hyp8 trace database (`tracedb`) — testdb methodology

The **testdb** is the hyp8 verification analytics layer: a single SQLite file
that turns every diagnostic record emitted by a Verilator run into a
categorical row, so a boot/test can be *compared, bucketed and joined* instead
of grepped. It is the tooling half of the "categorize → isolate → fix →
re-ingest → verify" loop used to drive the hyp8 redesign to a clean
multicore OpenWrt boot.

Scripts live in `verif/regress/remote/hyp8/tracedb/`:

| file        | role                                                        |
|-------------|-------------------------------------------------------------|
| `tq.sh`     | operator entry point (push scripts to remote, run reports)  |
| `ingest.py` | one pass over a run's logs → SQLite rows (run/event/census/…) |
| `query.py`  | analytics reports over the DB                               |

The database itself is **remote-resident** next to the logs it indexes:

```
/opt/testharness/tracedb/hyp8-trace.sqlite     # override with HYP8_TRACEDB
```

`tq.sh` base64-pushes the (content-addressed) scripts to the remote each call,
so an edit is always picked up; nothing is installed permanently.

---

## 1. Running it on traces — the workflow

### Ingest a run (or several)

```bash
cd /mnt/e/cva6
# ingest one or more run tags; tags may be globs
bash verif/regress/remote/hyp8/tracedb/tq.sh --ingest hyp8-osbi-mc-rfix131a-p
bash verif/regress/remote/hyp8/tracedb/tq.sh --ingest 'hyp8-osbi-scalar-r12*'
```

`tq.sh --ingest` runs `ingest.py --db $DB <tags>` remotely (default budget
`TQ_TIMEOUT=3000`s). `ingest.py` auto-detects the run **layout**:

| kind     | recognised output                                             |
|----------|---------------------------------------------------------------|
| witness  | `<run>/output/run-hyp8.log`, `uart.txt`, `witness.json`, `trace_rvfi_hart_NN.dasm` |
| smokes   | `<run>/output/<test>.log` (+ `smokes-results.json`)            |
| probe    | `<run>/output/<test>.log`, `<test>/trace_rvfi_hart_NN.dasm`    |

Useful ingest knobs (via `TQ_INGEST_ARGS`): `--window N` (RVFI context
radius), `--anchors N`, `--profile-step N` (PC-sample stride), `--force`
(re-ingest), `--runs-root`.

### Query the database

```bash
bash verif/regress/remote/hyp8/tracedb/tq.sh runs                     # one line per run
bash verif/regress/remote/hyp8/tracedb/tq.sh classes                 # etype x run matrix
bash verif/regress/remote/hyp8/tracedb/tq.sh classes -r r127m        # scoped to a run
bash verif/regress/remote/hyp8/tracedb/tq.sh origins                 # events by origin
bash verif/regress/remote/hyp8/tracedb/tq.sh hangs    -r r127m       # commit-gap dumps by head insn
bash verif/regress/remote/hyp8/tracedb/tq.sh asserts                 # every model assertion + last insns
bash verif/regress/remote/hyp8/tracedb/tq.sh threads  -r r127m       # per core/hart retired/IPC/gap
bash verif/regress/remote/hyp8/tracedb/tq.sh uart     -r r127m       # boot phases: cycle/kern-time/text
bash verif/regress/remote/hyp8/tracedb/tq.sh timeline -r r127m -b N  # events per N-cycle bucket + IPC
bash verif/regress/remote/hyp8/tracedb/tq.sh top      -r r127m -e PFX   # hottest addr/PC of an etype
bash verif/regress/remote/hyp8/tracedb/tq.sh around   -r r127m -e PFX -n K  # retired insns before K events
bash verif/regress/remote/hyp8/tracedb/tq.sh profile  -r r127m       # sampled-PC region x privilege
bash verif/regress/remote/hyp8/tracedb/tq.sh diff     A B            # etype diff over common cycles
bash verif/regress/remote/hyp8/tracedb/tq.sh sql "SELECT ..."       # raw SQL escape hatch
```

`TQ_TIMEOUT` bounds the remote call (default 300 s for queries, 3000 s for
ingest). The DB path can be relocated with `HYP8_TRACEDB`.

---

## 2. Schema (what gets categorised)

`run` — one row per ingested `(tag,test)`: rev, int_tag, model_sha, elf,
argv, budget, last_cycle, cores/harts, verdict, log size/mtime.

`etype` — the **classification dictionary**: `etype → (class, origin, rfix,
descr)`. `ingest.py`'s `ETYPES` table maps each diagnostic prefix to an
origin + the RFIX worklog entry that owns it. `origin` is the triage bucket:

- `stale-context` — execution under a stale privilege/translation context
- `wrong-path`    — speculative/wrong-path memory or fetch activity
- `liveness`      — commit gaps / fetch sequence gaps (hang candidates)
- `architectural?`— possibly-legitimate architectural faults (demand paging)
- `unknown` / `diagnostic` / `model-assert` / `idle`

`event` — the fact table: `(run_id, seq, cycle, cycle_exact, core, hart,
class, etype, addr, pc, aux, detail, raw)`. Addresses are 16-digit hex TEXT
(they exceed SQLite's signed int64); cycles are INTEGER. Indexed on
`(run_id,class,cycle)` and `(run_id,cycle)`.

`census` — periodic `[stall-census]` snapshots: per-hart retired/IPC/flush/
replay/mem_viol/ldbuf_full.

`uart` — UART lines with cycle + kernel-time.

`rvfi` — retired-instruction context **around** selected event anchors
(pulled from the large per-core `.dasm` traces by bisecting on cycle stamps —
never a full scan).

`pc_sample` — sampled PC profile `(cycle,core,hart,priv,pc,region)` for
`profile`.

`kv`, `thread`, `symbol` — run metadata, per-thread retirement summary, and
firmware symbol table (kernel-image symbols for `sym()`/`around`).

`v_event` — convenience view joining `event ⋈ run ⋈ etype` (tag/test/rev +
origin + rfix exposed directly).

---

## 3. The etype dictionary (current RFIX map)

`ingest.py:ETYPES` is the single source of truth for "what kind of bug is
this". Longest-prefix match wins. Current entries (abridged):

| etype                       | origin           | rfix              | meaning                              |
|-----------------------------|------------------|-------------------|--------------------------------------|
| `axi.r.va-alias`            | stale-context    | RFIX-131a-01/02   | bus read aliasing a live VA          |
| `axi.r.hole`                | wrong-path       | RFIX-131a-01      | bus read nothing decodes             |
| `axi.r.dev`                 | wrong-path       | RFIX-131a-01      | bus error from a device window       |
| `axi.r.untagged`            | unknown          | RFIX-131a-01      | bus read error, untagged harness     |
| `ptw.fetch.phys-alias`      | stale-context    | RFIX-131a-02      | fetch walk under stale PA context    |
| `ptw.data.phys-alias`       | stale-context    | RFIX-131a-02      | data walk under stale PA context     |
| `ptw.data.null`             | wrong-path       | RFIX-131a-03      | wrong-path load, null/garbage base   |
| `ptw.fetch.null`            | wrong-path       | RFIX-131a-04      | wrong-path fetch, null target        |
| `ptw.data.user`/`fetch.user`| architectural?   | —                 | user walk fault (paging or wrong-path)|
| `ptw.fetch.kernel`          | unknown          | RFIX-131a-04      | kernel fetch walk fault              |
| `ptw.*.noncanonical`        | wrong-path       | RFIX-131a-03/04   | non-canonical walk                   |
| `ife.priv0/1/3`             | arch?/wrong-path | RFIX-131a-04      | instruction fault in U/S/M mode      |
| `hang`                      | liveness         | RFIX-131a-05      | commit gap over `+hang_dump`         |
| `seqgap`                    | liveness         | —                 | fetch seq gap over `+seq_gap_limit`  |

When a **new** diagnostic prefix appears that isn't in `ETYPES`, `ingest.py`
files it under a best-effort class and leaves `origin`/`rfix` empty — the
`classes` report then shows it as an unclassified row to triage. Add the
prefix to `ETYPES` to give it an origin + RFIX owner.

---

## 4. Methodology — how the loop is run

1. **Produce a run.** A witness (`run_hyp8_witness.py` → `run-hyp8.log` +
   `uart.txt` + `trace_rvfi_hart_*.dasm`) for boots, or a directed/smoke/probe
   run for targeted tests. The witness plusargs that feed the DB are the
   diagnostic emitters: `+hang_dump=N`, `+stall_census`, `+equiv_report`,
   `+rvfi_cycle_stamp`, `+seq_gap_trace`, `+seq_gap_limit=N`, `+tohost_addr`,
   `+max-cycles`, `+time_out`.
2. **Ingest** the tag(s) into tracedb.
3. **Categorize** with `classes`/`origins`: which etypes dominate, which
   origin bucket, which RFIX owns them, and how the counts move vs the
   previous run (`diff A B` over common cycles).
4. **Isolate** the worst class: `top`/`around`/`timeline`/`hangs`/`threads`/
   `uart`/`profile` narrow it to a PC, a hart, a cycle window, a boot phase.
5. **Fix** the RTL at the located stage; record the hypothesis + evidence in
   `analysis/rfix131a/worklog.md` under the next `RFIX-131a-NN`.
6. **Rebuild → re-run → re-ingest** the same tag family and confirm the class
   count drops (the `classes` matrix is the scoreboard).

The DB is what makes step 3–4 cheap: instead of reading a multi-GB
`run-hyp8.log`, you query counts/histograms/joined context.

---

## 5. Reading the current boot picture (worked example)

Scalar OpenSBI boots (`hyp8-osbi-scalar-r12*`) were ingested across revisions
r127m→r131. `classes` showed the RFIX-131a-01..09 series draining:
`axi.r.untagged` (18k) → `ptw.*.phys-alias` (stale-context) → `ptw.data.null`
→ `ife.*.cause12` → `hang.fu*` liveness. r127m reached a `shell` verdict at
~2.67 G cycles; later revisions fixed the wrong-path/stale-context classes.

The **multicore** witness (`hyp8-osbi-mc-rfix131a-memfix`, 8 harts / 4
cores SMT, `fw_payload.elf` OpenWrt/Linux image) has advanced through two
distinct deadlock frontiers:

1. **LSU dual-issue drop — FIXED (cont.56–59).** `ex_stage` forwards ONE
   memory request/cycle (highest-port `fu_data` wins) while
   `lsu_valid_i=|ports`, so two same-cycle LOAD/STORE acks silently dropped
   the lower-port op after it was marked issued → never retried. The
   commit-head `ld s4,0x20(sp)`@`0x8001379a` (c≈25714) was the victim →
   circular wait on `phys203`. Fix: single-memory-issue grant at
   `issue_ack_pre` in `issue_read_operands.sv` (`lsu_mem_cand/grant`);
   losers stay in the IQ and retry. Verified: boot advanced ~7700 cycles
   past the former stall.

2. **Frontend IQ drain deadlock — FIXED (cont.60–67).** The earlier
   `cf_hold`/`bp_pend` freeze (c≈33490) was a *symptom*: the real root was
   `instr_queue` drain pointer `idx_ds_q` collapsing to `0` (an absorbing
   state — the `p >= NrFifo` generate branch zeroed `idx_ds[p]` on the
   advance-only slot, so a highest-consumed `NrIssue-1` rotated the drain
   one-hot to all-zero). `idx_ds_q=0` → `pos_present=0` → `fe_valid=0` →
   `consumed=0` → predicted-CF target FIFO never pops → `full_address=1` →
   `ready_o=0` → `demand_req=0`. Fix: `idx_ds[p] =
   rotate_left(idx_ds_q, p % NrFifo)` in `instr_queue.sv`. Categorized as
   `hang.fe.iq-drain-idxds0`.

3. **store_buffer witness false-positive — FIXED (cont.68).** The iqfix
   witness aborted at c≈170756 on `store_buffer.sv` assertion
   `ooo_no_younger_forward`. Not a younger-store bug: for
   `StoreFwdCycles==3` the `st_fwd_*_o` outputs are an F3 *held* response,
   not cycle-aligned with the live `load_paddr_i`/`load_trans_id_i`, so the
   witness compared a response for one tagged request against the live
   request of another. The real age contract is enforced inside `stb_fwd`
   F1. Fix: gate the translate_off witness to `StoreFwdCycles == 1`.

**Current frontier (cont.70).** The `stgfwd` witness
(`hyp8-osbi-mc-rfix131a-stgfwd-wt1`, model `ca6c8a96`) carries all three
fixes and has run **deep-clean**: past c170756 into c398k+ with **zero**
categorized events (`run-hyp8.log` emits `[hang]`/`[stall-census]`/verdict
only at an endpoint, so a clean mid-run ingests as 0 — that *is* the
result). ELF `nm` maps the dominant PC region (`0x80012xxx`, 85% of
retires) to **libfdt** (`fdt_offset_ptr`/`fdt_next_tag`/`fdt_next_node`/
`fdt_move`…): hart0 is walking the DTB (`fw_fdt_bin`@`0x8001e000`) during
OpenSBI `sbi_init` — normal coldboot progress, not a stall. Secondary
harts 2/4/6 sit in `_wait_for_boot_hart` (`0x800002e8`, coldboot-lottery
losers) as designed. Two detached remote watchers (`watcher.sh`
cyc/event log; `ingest_watcher.sh` auto-ingest on PID exit →
`auto_ingest.txt`) pre-stage the tracedb categorization for the endpoint.

**Lean boot witness (cont.71).** Because per-instruction tracing costs
~10× wall-rate and the goal is a kernel-length boot, a second detached
witness `hyp8-osbi-mc-rfix131a-stgfwd-lean` (same `ca6c8a96` model) was
queued via `HYP8_WAIT_PIDS=1951517` — it `exec`s once the diagnostic
witness exits. It runs `+rvfi_notrace +core_notrace` (the designed
kernel-boot flags; kills the 48 GB dasm/iti/encaps + RVFI streams) plus
`+smt_progress` and the endpoint diagnostics (`+stall_census
+hang_dump=2000 +equiv_report +seq_gap_trace`), budget
`+max-cycles=+time_out=3000000000`. Live signals reduce to `uart.txt`,
`run-hyp8.log` events, and process liveness; a lean `watcher.sh`
(120 s poll → `watcher.log`) watches for `UART`/`EVENT`/`EXITED`. If it
stalls, `hang_dump`+`stall_census` still emit the state needed for
tracedb classification; if it boots, `uart`/`smt-progress`/`equiv`
records carry the milestone.

---

## 6. Notes / gotchas

- The DB is **remote**; `tq.sh` proxies every call. Run it from WSL
  (`/mnt/e/cva6`), not Windows-native, so the proxy + base64 push work.
- `ingest.py` is read-only over run outputs; it never modifies the model or
  logs. Re-ingesting a changed log needs `--force`.
- Large witness logs (multi-GB) are indexed by **bisecting RVFI traces on
  cycle stamps**, not full scans — ingest stays bounded.
- `addresses` are TEXT hex; compare/join on the TEXT form or `CAST(addr AS …)`
  carefully (they exceed int64).
- Keep `HYP8_TRACEDB` stable across a campaign so `diff`/`classes` line up;
  a per-run DB defeats the cross-run matrix.
