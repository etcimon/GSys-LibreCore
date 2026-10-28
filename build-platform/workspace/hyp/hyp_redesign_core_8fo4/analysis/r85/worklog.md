
## r85 — dep-chain path enumeration (delay-v48)

**Crate edits**:
- `measure.rs`: `node_read_symbols`/`with_guards` →
  `Expr::walk_read_idents(seed)` (dep-edge fold); `dep_pred` from the
  live `edges`; `longest_comb_path` walks `dep_pred` not `fans_in`;
  per-endpoint liveness — `live_out` (output sinks) vs `live_reg`
  (registered sinks) split at the `sinks`/`edges` build; each
  `design.paths` path's `nodes` filtered by `path_kind`
  (`InToOut`/`RegToOut` → `live_out`, else `live_reg`); empty paths
  dropped; `primary_loc` re-pointed.
- `lower.rs`/`ir.rs`: `keep_dead_nodes` on `LowerOptions` +
  `TimingDesign` (serde default); `lower.rs:121` compose.
- `main.rs`: `--keep-dead-nodes` flag → `LowerOptions` (Analyze +
  two other variants default `false`).
- `version.rs`: `MEASUREMENT_VERSION = delay-v48`.

**Fixtures**: `dead_arm_region.sv` (new, MIT) + `localparam_gate_fold.sv`
registered in `filelist.txt`. `dead_arm_region` under `Stages=1`:
`out0` = `line 17` (`y_o = r_q`) only — `g_a` fully pruned.

**Boards (release, delay-v48)**:
- `analyze-r85-lu.json` + `analyze-r85-lu-deep.json`: load_unit
  **54.2 FO4** `reg-to-reg load_unit.sv:1239` on BOTH — the dep-chain
  reg→reg enumeration bills a longer chain than the statement-order
  links did; the 37.2 `into L5` cone is gone (its `ex_pub` node is
  no longer on the out path) but a deeper reg→reg cone surfaced.
  Whether this is a true correction or over-chaining needs the
  `ir_hot_nodes` census of the L1239 cone (is `pend_*`/`ldbuf`
  transitively deeper than the old chain claimed?). `inst`/`into`/
  `rr`/`pres` all recomputed — measure-semantics correction expected.
- The r84 stage's `into L5` → pending-arm cut is no longer measurable
  as `37.2→<33.5`; the row is now the reg→reg floor.

**For the lead**: the dep-chain enumeration is correct for dead-arm
pruning (fixture) but changes absolute numbers broadly (+17 FO4 on
the module row). Whether `L1239` 54.2 is a true cone or dep-chain
over-chaining (edges that statement-order didn't form) needs the
hot-node census. `cargo test`/`build` clean dev; release + boards ran
with delay-v48 banner.
