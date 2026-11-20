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

2. **Frontend branch-pend/hold deadlock — CURRENT FRONTIER (cont.60).**
   hart0 now runs a spin-wait poll loop (`ld x15,9(x10)`@`0x80012880`,
   x10=`0x8001e000` MMIO/status), exits ~c33490 into `0x800129xx`, then the
   whole pipeline drains and freezes: `commit_ptr=issue_ptr=27`,
   `sb_empty=1`, IQ offered-empty, yet `cf_hold=1` + `bp_pend=1`
   `bp_tgt=0x80012a06` + `red_pc=0x80012a94`. No mispredict after @33055 —
   the pend is armed via the `hyp_fe_override2_o` (ov2) path which sets
   `bp_misp_ttl_q<=0` (NO timeout escape). This is the documented
   r41b/r44b/r45b hold class in `fetch_B/frontend.sv`: `bp_pend` filters a
   return stream to `bp_tgt` that never gets an `icache_dreq`, while
   `cf_hold` blocks fetch → circular. Categorized as
   `hang.fe.bp-pend-cf-hold`. See `analysis/rfix131a/worklog.md`
   cont.59–60.

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
