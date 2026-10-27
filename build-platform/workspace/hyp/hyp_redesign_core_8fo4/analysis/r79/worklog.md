# r79 worklog

## Item 1 — E6 fixture (tier T, landed)

sv-timing/fixtures/fn_zero_len_range.sv (MIT): package
range_check/is_inside_regions over a 2-rule array with all-zero
lengths — reproduces load_unit's stall_ni billing on a dead
predicate. Registered in fixtures/filelist.txt. AGENTS-todo.md line
added: "constant-fold range_check/is_inside_* with zero-length or
constant rules". No crate changes.

## Item 2 — NI gate + pow2: NULL, REVERTED

Implemented: config_pkg nonidempotent_any + pow2/aligned masked
form in is_inside_nonidempotent_regions + ref_ generic body under
ifndef SYNTHESIS; NI_ANY gate at all 5 is_inside call sites
(load_unit paddr_ni, g6lc_icache addr_ni, wt_dcache_wbuffer is_ni,
g6lc_fdip, g6lc_lsq) + lu_ni_eq assertion + counter +
G6LC_MUT_LU_NI_ANY.
Board analyze-r79-lu.json (combined with item 3): module row
unchanged 37.2 (into-L5 window 0 stays the limiter); rr actually
moved 33.5 -> 33.9 — the analyzer re-billed the state_d cone
slightly upward with the localparam ternary present. NULL ->
all 6 files reverted byte-exact from analysis/r79/pre/*.zip.

## Item 3 — last_tid_q: NULL, REVERTED

Implemented: last_tid_q registered at the ldbuf_w edge beside
ldbuf_last_id_q (+ reset + G6LC_MUT_LU_LAST_TID stale-mutant +
lu_last_tid_eq + [equiv] counter); live reads at :966/~:2335
switched to cancelled_mask_i[last_tid_q]. Same combined board —
into-L5 37.2 unchanged; NULL -> reverted byte-exact with item 2.

## r79 verdict

load_unit's 37.2 into-L5 limiter is a presentation cone (the L5
one-hot block's window-0 makespan) — neither the dead-predicate
removal nor the index shortening moves it; both are
correct-by-hygiene but ruled NULL and reverted. The only landed
deliverable is the E6 fixture + analyzer to-do (the real fix for
the over-read is constant-folding in the analyzer, not the RTL).
No batch end — nothing kept.
