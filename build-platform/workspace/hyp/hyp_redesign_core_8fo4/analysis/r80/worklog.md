
## r80 — lead implementation of variant b and its boards (INCONCLUSIVE on the model; reverted)
- Implemented the cut-after-gather record (`pr_q = {v,tid,word,off,op}` captured on the data arm's pop, `a_rec` presents at the data arm's rank, drops on flush, holds while outranked; record invariants `lu_rec_origin/capture/present`, `[equiv] load_unit pubrec` counter; `lu_pop_is_presented`/`lu_l5_onehot_eq` made stage-aware). Lint: baseline 16 under both profiles. Leaf plain: `HYP8_MEMORY_PASS checked=160`, F15 n=1, L5 onehot 155 (==1 bit-identical). Leaf deep: the bench's same-cycle publish checks (`G1_PUB_A` …) need the +1 retime — not done.
- Boards (same-map protocol): pre 37.2 → with the record present in the file **45.2/46.2 for BOTH the ==1 and the forced-on form** (ternary form 46.2; generate form 45.2; `analyze-r80-lu1/lu2/lu2-deep.json`). Identical numbers across the gated arms show the analyzer does not evaluate the `LoadPubStages`-derived localparam (`LU_PUBREC`) — it bills both arms of the ternary/generate and the `a_rec` term added to `pub_fire`. The comparison therefore cannot discriminate the stage, and the ==1 profile would carry a false +8 on the board.
- Verdict: inconclusive on the instrument (E6/RT-P1) → load_unit restored byte-exact from `analysis/r80/pre/load_unit.sv.zip`. Owed: an sv-timing fixture for "generate/ternary on a localparam derived from a param-map struct field" (same class as `fn_zero_len_range.sv`); until the analyzer folds it, config-gated stage arms in one file cannot be measured same-map — the alternative is a separate module per arm selected by the caller (caller-purpose segmentation), which the analyzer measures per module.

## r81 — L4 extraction batch end (lead-landed g6lc_lu_result split)

New module core/g6lc_lu_result.sv (L4 result formation, verbatim;
registered in Flist.g6lc_hyp8 + inputs/hyp8-core.f +
Flist.hyp8_sim + local leaf script). Closure picked it up: 732
files (+1). hyp8-integration-r81: rc=0 347.5s, sha
05e9dc3b7a31ea3fa1fc2934c84d87aa967c0181a817f8a2cead9f626c280dc9,
lint scalar/smt2 rc=0 0 %Error, g6lc_lu_result present in the built
model. hyp8-r81-smokes: 7/7 PASS — 685/1011/492/2364/2199/1231/671,
cycle-identical.
analyze-r81-all.json (+.cmd): structural clock 1.08 GHz (37.2 FO4,
load_unit, into L5 window 0 — now identified as the ex_pub
same-cycle exception publish at L1415, 6-node reg->out);
g6lc_lu_result 18.2 pres. Diff vs r78-all: no module-row changes
(the extraction is representation-only).
Witness hyp8-osbi-scalar-r47b: 29 census prints, ~30M cycles,
ret ~6.9M, IPC 0.23, no [hang]; running detached pid 1952306.
