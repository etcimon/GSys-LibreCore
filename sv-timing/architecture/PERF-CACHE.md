# Analyze throughput and the pre-compiled unit cache — design delta

> Companion to [`DESIGN.md`](DESIGN.md) § Cache design (schema v1) and § Multi-Step Architecture.
> **Status:** §1 is **mostly implemented** — B1–B5 landed (see §1.1); B6–B9 remain.
> §3 (`units` tier, P17) and §4 (calibration, P18) are still design-only. Phases in
> [`../AGENTS-todo.md`](../AGENTS-todo.md).
> **Scope:** package-internal. Cache path/tier stay caller-chosen (KD2); no host coupling (KD0).

---

## 0. Summary

Two independent problems are recorded here.

1. **Wall-clock**: cold analyze is single-threaded and carries several
   superlinear terms (an O(N²) path-matching loop, an O(K·N) per-module tree rewalk,
   O(P²) id lookups per correct pass). None of them are inherent.
2. **Incrementality**: cache v1 is *IR-only*, so KD15 forces "IR miss ⇒ reparse every
   file in the module's contributing set **from disk**". Editing one line therefore
   reparses that module's whole closure. The fix is a new **pre-compiled per-file unit
   tier** — the "content-addressed blob cache" `DESIGN.md` parks as *optional later*, but
   holding **lowered units** rather than CSTs.

Two correctness defects in the current cache are fixed as part of this work (§3.1).

---

## 1. Measured-by-inspection bottleneck table (P16)

| # | Bottleneck | Locus | Complexity / cost | Fix |
|---|---|---|---|---|
| B1 | **Serial parse.** One `parse_sv_str` per file in a `for` loop; each file is read to `Vec<u8>`, copied again via `String::from_utf8_lossy(..).into_owned()`, indexed, and both the bytes **and** the CST are retained | `crates/sv-timing-core/src/parse.rs:73-107` | Dominant term. ~3 copies of every source in RAM. No `rayon` anywhere (`Cargo.toml:45-56`) | Parallel per-file parse (files are independent); drop the redundant `bytes` copy or borrow from the tree; keep results in input order for determinism |
| B2 | **`paths_match` allocates two lowercased `String`s per comparison**, called from nested loops over the digest set | `crates/sv-timing-cache/src/analyze_cache.rs:467-471`; callers `:115,141,174,236,243,439,444` | O(N²) comparisons × 2 allocs; on a ~1k-file flist that is millions of heap allocations *before* any parse | Normalize every path **once** into a canonical key at ingest; use `HashMap<CanonKey, idx>`. Drop the two-way `ends_with` fuzz — it is also a false-positive risk (`alu.sv` vs `my_alu.sv`) |
| B3 | **Per-module full-tree rewalk.** `collect_typed_parameters(tree)`, `collect_module_ports(tree)`, `collect_genvar_loops(tree)` and the region walk each traverse the **whole file** once per module found | `crates/sv-timing-core/src/lower.rs:408-493` | O(K·N) for K modules per file. Also a **correctness** bug: every module in a K-module file inherits *all* ports/params/localparams of the file | One walk per file that buckets nodes by enclosing module declaration; per-module views over that index |
| B4 | **Whole-design re-cost per correct pass**, and ranking deep-clones every path | `crates/sv-timing-transform/src/pass.rs:135-141`; `crates/sv-timing-core/src/measure.rs:215-233` | O(passes · all nodes) + O(passes · P) deep clones (paths carry node vectors, strings, `SourceLoc`s) although one module is dirty | Dirty-module set on `PassContext`; `remeasure` honors it (as `AUTO-CORRECT-CORE-API.md` §3.2 already specifies). Rank over `Vec<PathId>` / indices, never clones |
| B5 | **Linear id lookups in hot loops.** `paths.iter().find(|p| p.id == …)`, `opportunities.iter().find(...)` per path, `paths.iter().map(id).max()` per insert | `crates/sv-timing-transform/src/worklist.rs:75-85`; `crates/sv-timing-transform/src/pipeline.rs:213-265`; `crates/sv-timing-transform/src/pass.rs:178-222` | O(P²) per pass | `BTreeMap<PathId, usize>` index on the design; monotone `next_path_id` counter instead of `max()` |
| B6 | **`serde_json` blobs, uncompressed, written twice.** Every commit writes a per-module blob **and** a whole-design blob; every node's `SourceLoc.file` is a full path `String` | `crates/sv-timing-cache/src/store.rs:384-451`; `crates/sv-timing-cache/src/analyze_cache.rs:436-463` | DB grows ~O(design²) over runs; a large-design hit can deserialize slower than re-lowering a small module. `DESIGN.md` §6 says *bincode* | `bincode` (or `postcard`) + `zstd`; intern `SourceLoc.file` as the `Arc<str>` `DESIGN.md` §1 already specifies, with a per-blob file table |
| B7 | **Table-driven CRC, serial, full file read.** `crc::Crc<u32>` over `CRC_32_ISCSI` | `crates/sv-timing-cache/src/crc.rs:18-76` | ~1 GB/s vs ~20 GB/s for the SSE4.2/`crc32c` path that `DESIGN.md` §Cache actually names | Switch to the `crc32c` crate (same polynomial, identical hex output ⇒ **no** cache invalidation), digest in parallel with B1 |
| B8 | **`Expr::parse` on every op's RHS text** — a second, string-level parser over content already present in the CST | `crates/sv-timing-core/src/lower.rs:527-528` | One text parse per IR node | Lower expressions directly from CST subtrees; keep `Expr::parse` for tests/emit round-trip only |
| B9 | **`source.lines().nth(n)` per candidate line** during relocation, inside the ±radius scan | `crates/sv-timing-emit/src/rhs.rs:118-123,180-205` | O(edits · radius · L) | Build the line table once per source; better, drive relocation from `SourceLoc.byte_start/byte_end` (P19, see [`OPTIMIZATION-LEVELS.md`](OPTIMIZATION-LEVELS.md) M7) |

**Ordering rationale:** B2/B7 are pure wins with no behavior change and land first; B1
gives the largest cold-run factor; B3 is simultaneously a perf and a correctness fix;
B4/B5 only matter once `correct` runs many passes (which `-O3` makes normal).

### 1.1 As-built (P16)

| # | Status | Implementation |
|---|---|---|
| B1 | **done** | `parse::parse_paths` parses files on scoped `std::thread`s with **dynamic** scheduling (`AtomicUsize` work queue + `mpsc` results, reassembled in input order). No new dependency. Degree from dial 10a (`--opt-jobs`, `0`/absent = `available_parallelism`, `1` = serial); `worker_count` clamps to the file count. `sv-timing-core` needed `#![recursion_limit = "1024"]` because proving `Send` for `sv_parser::SyntaxTree` overflows the default limit. |
| B2 | **done** | New `cache::pathkey` module: `CanonPath` (normalize `\`→`/`, strip `\\?\`, case-fold, collapse `//`) + `PathIndex` (hash lookup, then unique file-name match, then unique **path-boundary** suffix match). Every `paths_match` call site in `analyze_cache` now goes through an index built once per run; the helper is deleted. |
| B3 | **done** | `lower_file` walks the file once and materializes each module's own subtree into a `ModuleScope { name, loc, nodes: Vec<RefNode> }`; `collect_typed_parameters_in`, `collect_module_ports_in`, `collect_genvar_loops_in`, `collect_module_instances_in`, the region walk and the op fallback all take that slice. Per-file walks drop from ~5xK to 2. **Also a correctness fix:** each module in a multi-module file previously inherited the *union* of every module's ports/params/regions, and all instances were attributed to the first module. |
| B4 | **done** | Two halves. *Dirty-only remeasure:* `PassContext` tracks `dirty_modules`; `insert_register` / `split_assign` call `mark_active_dirty()`, and `measure()` re-costs only those modules via `attribute_costs_modules` + `remeasure_path_slacks_modules` (first pass, or an unknown module, falls back to `measure_full`). *Clone-free ranking:* new `RankedOrder` + `rank_path_order` hold **indices**; `PassContext.ranked` and `order_worklist` use them, so no `TimingPath` is deep-cloned per pass. `rank_paths_by_slack` stays for report-time callers. |
| B5 | **done** | `order_worklist` indexes opportunities by `path_id` once per pass; the driver builds a `path_id → index` map per pass instead of scanning `design.paths` per work item. |
| B6–B9 | open | See the table above. B6/B7 need new crates (`bincode`/`zstd`/`crc32c`) — a dependency decision, not just code. |

`RefNode` is not iterable in the vendored parser (only `&ConcreteNode` is), which is why a
scope is a materialized `Vec<RefNode>` rather than a lazy cursor. Golden:
`fixtures/measure/two_modules.sv` +
`lower::tests::multi_module_file_scopes_ports_regions_and_instances` asserts that
`leaf_a` never sees `holder_b`'s ports, each module has exactly one region, and the
`i_leaf` instance belongs to `holder_b` alone.

**Measured** (debug build, 8 CPUs, the 9-file CVA6 sparse set from `sv-timing-advanced`,
38 KB–5.6 KB per file):

| `--opt-jobs` | wall clock | speedup |
|---|---|---|
| 1 | 4.21 s | 1.00x |
| 2 | 2.79 s | 1.51x |
| 4 | 2.51 s | 1.68x |
| 8 | 2.34 s | 1.80x |

The ceiling is **Amdahl on one file**: `riscv_pkg.sv` is ~25 % of the bytes, so a 9-file
list cannot exceed ~2.5x no matter the core count. Flists with many comparable files scale
further; a 200-file list of small fixtures is dominated by thread spawn instead (0.12 s
total), so the win is real only when per-file parse work is substantial.

**Scheduling matters:** the first implementation used a static stride and 8 workers were
*slower* than 4 (5.27 s vs 4.30 s) because the two largest files landed on one worker. The
dynamic queue removed that inversion.

**Determinism:** verified end-to-end — `analyze --opt-jobs 1` and `--opt-jobs 8` on the
sparse set produce byte-identical JSON (180 794 bytes compared) once the echoed `jobs`
dial itself is excluded, plus unit tests `parallel_parse_matches_serial_order_and_content`
and `parallel_parse_reports_first_failure_in_input_order`.

**Cache-key correction found by that comparison:** `--opt-jobs` was initially folded into
the design key, so changing thread count evicted a perfectly valid cache entry. The dials
now split into `OptOptions::analysis_digest()` (only `effort` + `cache_mode` — what can
change an analyze result) for the cache key and `digest()` (all ten) for reporting.

**B4 is an exact optimization, not an approximation.** Untouched modules cannot change
cost, so scoping is safe by construction — and
`pass::tests::dirty_scoped_measure_matches_full_measure` proves it: after a real
`insert_register`, a scoped `measure()` and a subsequent `measure_full()` agree on every
path total, every slack, the opportunity count and the ranking order. The `-O` sweep on
`deep_add_chain` is unchanged (`-O2` 2 edits/16.7, `-O3` 3/9.3 closes, `-Os` 3/9.3 closes).

Determinism is a hard constraint on all of it: parallelism may reorder *work*, never
*results*. Every parallel stage collects into input order before lowering, and all IR
containers stay ordered (`BTreeMap`) so goldens are unaffected.

---

## 2. Current cache tiers (as built)

| Tier | Key | Hit means | Locus |
|---|---|---|---|
| Design | `design_key = f(pp_fingerprint, module_filter, digests, param keys)` | Zero parse, zero lower; retarget + `remeasure_path_slacks` only | `analyze_cache.rs:76-95` |
| Module IR | `(module_name, crc_set, ir_version)` | Reuse `ir_blob` for that module | `analyze_cache.rs:131-168` |
| Miss | — | **Reparse from disk every file in the module's set** (KD15) | `analyze_cache.rs:230-258` |

Observed behavior on a package-heavy file list: any file lacking a `file_modules` row is
forced into the miss set on **every** run (`analyze_cache.rs:172-177`), so package-rich
flists rarely reach a cheap tier even when nothing changed.

### 2.1 Defects to fix with this delta

| # | Defect | Locus | Consequence |
|---|---|---|---|
| C1 | **`crc_set` is committed over the primary file only** (`crc_set_for_file(path, crc)`), while `DESIGN.md` step 4 defines it over the full contributing set `F(m)` | `analyze_cache.rs:436-460` | **Stale hit**: a module whose imported package changed still IR-hits if its own file is untouched. Correctness, not performance. |
| C2 | **Orphan (unmapped) paths always join the miss set** | `analyze_cache.rs:170-177` | Package files permanently defeat the cheap tiers |
| C3 | Design blob rewritten in full on every commit alongside all module blobs | `analyze_cache.rs:209-218,284-293` | Redundant write amplification; interacts with B6 |

---

## 3. New tier: `units` — pre-compiled per-file lowered IR (P17)

**Idea:** cache the *lowered unit*, not the CST. A CST blob is large, parser-version
fragile, and still needs re-lowering; a lowered unit is small, is exactly what the linker
consumes, and makes KD15's full-set reparse unnecessary.

```sql
CREATE TABLE units (
  path              TEXT NOT NULL,     -- canonical key (see B2)
  crc               TEXT NOT NULL,     -- crc32c hex, unchanged algorithm
  parser_version    TEXT NOT NULL,
  pp_fingerprint    TEXT NOT NULL,     -- defines/incdirs closure
  unit_ir_version   TEXT NOT NULL,
  unit_blob         BLOB NOT NULL,     -- bincode + zstd
  stored_at         TEXT NOT NULL,
  PRIMARY KEY (path, crc, parser_version, pp_fingerprint, unit_ir_version)
);
CREATE INDEX idx_units_crc ON units(crc);
```

`unit_blob` (`UnitIr`) holds, for **one file**: the modules it declares (ports, params,
localparams, functions, imports, regions, nodes with `lhs`/`rhs_expr`, gates, instances,
per-module `SourceLoc`s), the packages it declares, its `+incdir+`/import references, and
an interned file/string table. It contains **no** cross-file resolution and **no** costs —
widths, costs, paths, and stitching are link-time so a `--fo4-ps` or `-O` change never
invalidates a unit.

### 3.1 Analyze algorithm with the unit tier

```
0b  ingest        → canonical path keys (once), incdirs, defines
1   digest        → crc32c in parallel  (B7 + B1)
2   design tier   → design_key hit ⇒ return (unchanged)
3   unit tier     → for each file: units PK hit ⇒ decode UnitIr (NO parse)
                                   miss      ⇒ parse + lower that ONE file → UnitIr → stage for commit
4   dep closure   → resolve imports/instances across units; per module compute
                    crc_set(m) = sha256 over F(m) = {defining file} ∪ {package/include files it resolves against}   (fixes C1)
5   module tier   → (module_name, crc_set, ir_version) hit ⇒ reuse ir_blob
                    miss ⇒ LINK from units (no reparse of clean siblings)     (relaxes KD15)
6   cost/paths    → widths + costs + DAG longest path + stitch (see OPTIMIZATION-LEVELS §1.1)
7   commit        → upsert units (staged), module blobs, design blob, file_modules
```

The KD15 invariant is replaced, not broken: *"an IR miss must not use a stale CST"*
becomes *"an IR miss must re-link from units whose `(crc, parser_version, pp_fingerprint,
unit_ir_version)` all match; any mismatch reparses that file."* Record this as **KD19**
in `DESIGN.md` when the phase lands, and keep `--force` bypassing every tier.

### 3.2 Expected effect

| Scenario | Today | With units |
|---|---|---|
| Cold, N files | N serial parses | N parses across `opt_jobs` workers |
| Warm, nothing changed | design hit (already fast) | unchanged |
| Warm, one `.sv` edited | design miss ⇒ reparse the module's whole contributing set | **1** parse + link |
| Warm, one package edited | design miss; dependents may **wrongly hit** (C1) | dependents correctly miss, then link from cached units |
| `--target-mhz` / `--fo4-ps` / `-O` changed only | design-key miss ⇒ full rebuild | all units hit ⇒ link + re-cost only |

That last row matters most for the `-O` surface and for `--freq-sweep`: sweeping six
frequencies currently costs six full rebuilds; with units it costs one parse and six
cost/rank passes.

### 3.3 Migration

Schema bump + `PRAGMA user_version`; on mismatch the CLI requires `sv-timing clean`
(`DESIGN.md` § Data Model, unchanged policy). `--opt-cache-mode ir` keeps the old
behavior for A/B comparison; `off` bypasses SQLite entirely.

---

## 4. Frequency sweep and calibration (P18)

The tool cannot make silicon faster; it can make the blocking set explicit. Deliverables:

| Item | Shape |
|---|---|
| `--fo4-preset generic\|12nm\|7nm` | Named `fo4_ps` + per-class table variants; `generic`=20 ps keeps today's goldens |
| `--freq-sweep 1250,1500,2000,2500,3000,3500` | Per module: `max_freq_mhz`, `closes`, worst path, count of blocking paths at each point — one analyze, N ranking passes (cheap once §3 lands) |
| Report banner | `measurement=`, `cost_model=`, `fo4_ps=`, `calibrated=false` until a real fit exists |
| Optional cross-check | Yosys/OpenSTA on a fixture set to fit per-class constants; strictly an offline calibration input, never a runtime dependency (Alternatives 2/3 in `DESIGN.md` stay rejected as primary) |

Governance: root `AGENTS-configuration.md` §1.1 fixes the target of record at **1.25 GHz,
12 nm, SS 0.72 V/125 °C sign-off, ~250 mW/core, 4 W fanless**, stretch 1.5 GHz. Any sweep
row above the stretch target is reported as *structural head-room analysis*, tagged
`inferred`, and may not be quoted as closure — `NG1`, `KD18`,
[`STA-HANDOFF.md`](STA-HANDOFF.md), and `AGENTS-configuration.md` §1.0 all apply.

---

## 5. Testing

| Layer | Test |
|---|---|
| Unit | `canonical_path_key_dedups_windows_and_posix`; `canon_key_rejects_suffix_false_positive` (`alu.sv` vs `my_alu.sv`) |
| Unit | `crc32c_hex_matches_previous_table_impl` (byte-identical ⇒ no invalidation) |
| Unit | `unit_blob_roundtrip_bincode_zstd`; `unit_hit_does_not_parse` (parse counter instrumented in `ParseOptions` test hook) |
| Cache | `package_edit_invalidates_dependent_module` (**C1 regression**); `single_file_edit_parses_one_file` (**KD19**); `target_mhz_change_relinks_without_parse`; `unmapped_package_path_does_not_force_full_miss` (**C2**) |
| Perf smoke | `analyze_scales_with_jobs` — wall-clock ratio only, no absolute gate (KD18 spirit) |
| Determinism | `parallel_parse_matches_serial_ir` — byte-identical IR/report for `opt_jobs=1` vs `N` |
| Independence | `check_independence.py` still clean; new deps (`rayon`/`crc32c`/`bincode`/`zstd`) are third-party crates, not host coupling |

---

## 6. Non-goals

- No CST blobs in SQLite (units supersede the idea).
- No cross-run sharing of a cache directory between different `parser_version`s.
- No absolute performance gate in CI.
- No relaxation of realpath containment for `--cache` / `--out-dir`.
