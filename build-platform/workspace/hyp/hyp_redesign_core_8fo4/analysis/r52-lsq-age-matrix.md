# r52-B6 design note — g6lc_lsq_reduce: distance tournament → pairwise age matrix

Scope: `core/ooo/g6lc_lsq_reduce.sv` R1 tournament (29.9 FO4 regtoreg @:171,
3 levels of (IDW+1)-bit magnitude compare + slot mux for LEAVES=8).
Investigation only — no RTL change in r52.

## Current form

`cand = match_i & older_i` → balanced tournament over `pick_dist` (DIR=0:
largest circular dist, strict `>` = lowest-index tie; DIR=1: smallest,
strict `<`). `dist_i` is the leaf's circular distance `ooo_age_dist(IDW,
entry.id, commit_ptr_i)` — pivot-relative, so leaf-leaf order comparisons
are what the tournament actually performs. Instances: `i_q_red`
(STL_LEAF store entries, DIR=0), `i_stl_red` per update (DIR=0),
`i_vio_red` per update (DIR=1, VIO_LEAF = resident loads + NR_UPDATE
virtual `vv_*` leaves).

## Matrix form

Per queue, a maintained `age_q[r][c]` = "r is older than c", updated at
allocation exactly like `g6lc_iq_bank.older_q` (`g6lc_iq_bank.sv:1354`):
newcomer column = residents (newest allocates behind everything),
newcomer row cleared, dead rows/cols cleared. Distinct SB tids give a
strict total order, so "older than the query" and "younger than leaf i"
are complementary relations over the candidate set.

DIR=0 (youngest older store): `win_mask[i] = cand[i] & ~|(cand & ~age_col_i)`
where `age_col_i[j] = age_q[j][i]` (j older than i). Equivalently the
maximal element of `cand` under the order — one AND + one OR-reduce.
DIR=1 (oldest violating load): `win_mask[i] = cand[i] & ~|(cand & age_q[i])`.

Tie rule: a strict total order makes `win_mask` one-hot, except equal-`dist`
leaves — possible only when a `vv_*` virtual leaf carries the same SB tid
as a resident leaf (see below). On any multi-bit `win_mask`, take the
lowest concatenated index: identical to both tournaments' strict-compare
left-keep (vv sits high, resident vio sits low — resident wins a tie,
matching `strict <`/`>` today).

## Allocation sites / rows

- `g6lc_lsq_slot` owns `ld_alloc_oh`/`st_alloc_oh` (`g6lc_lsq.sv:292-334`);
  the matrix lives beside `ld_q`/`st_q` — LD_ENTRIES² for the vio/STL
  load side, ST_ENTRIES² for the store side (8² = 64 flops each, trivial;
  vs today zero added flops).
- Flush/cancel: same update as iq_bank — dead rows/cols cleared; a stale
  cell is also harmless because `cand` masks non-candidates.
- `vv_*` virtual leaves have **no queue slot** — they cannot take a
  matrix row. Options: (a) compute vv rows as compare-based vectors at
  the `vv_*_q` register boundary (`vv_age_d[u][*] = ooo_age_older(vv_id,
  ent_id_i)` per resident leaf — an N×NLEAF compare paid at the vv
  register edge, one cycle before R1 consumes it); (b) append vv leaves
  to a dedicated tail row whose column bits are formed the same way.
  Option (a) keeps the matrix strictly maintained; the compare happens
  off the R1 path either way.

## Port / consumer changes

- `g6lc_lsq` → `g6lc_lsq_reduce`: replace `dist_i` with `age_i` per leaf
  row (`[NLEAF-1:0][NLEAF-1:0]`), or pass the matrix handle; `win_dist_o`
  still needed by `vio_r_dist` — the dist gather by `win_mask` keeps
  `dist_i` as a payload input (no longer in the pick cone).
- R2's leaf id/pay gather is unchanged (one-hot `win_mask` already
  selects `ent_id_i`/`ent_pay_i`).

## Estimated R1 depth

`cand & ~|(cand & row)` ≈ AND + OR-8 + invert ≈ 3–4 FO4; one-hot id/dist/
pay gather (masked-OR tree, ≤8 leaves) ≈ 4–5 FO4 → R1 ≈ **8–10 FO4**
vs 29.9 today, at +2×64 flops and vv-row compare logic at the vv
register edge. The frontier/R2 split stays valid (the pick mask is the
registered frontier record).

## Open questions for ruling

1. Maintained matrix (registers at allocation) vs compare-matrix
   (`age[r][c] = ooo_age_older(ent_id[r], ent_id[c])` computed flat each
   cycle — NLEAF²=64 compares in parallel, no flops, no allocation
   coupling): same ~10 FO4 pick, zero state. The maintained form is the
   brief's candidate; the compare form may be simpler. Recommend
   measuring the compare form first.
2. vv-row compare placement (register-boundary vs inside R1).
3. Whether `older_i` (query-relative filter) stays an input — yes,
   unchanged.
