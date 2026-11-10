# r99 — MC configuration assertion and checkpoint-slot truncation repair

## Scope

The r98 aggregate gate was deliberately unqualified: MC emitted one RTL
`$error` for an LSQ store-credit/speculative-store-depth contract mismatch and
two `SELRANGE` diagnostics for a six-bit rename checkpoint record read as eight
bits. This pass repaired the contracts; it did not waive or suppress
diagnostics.

## Store-reservation contract

`LsqStoreEntries=0` now follows the derived speculative-store queue depth
(`ooo_spec_store_depth` geometry: 4 without `DeepSpecEn`, otherwise the next
4/8/16 power of the derived `MaxOutstandingStores`). The derivation uses the
post-floor `cfg.MaxOutstandingStores`, not the raw package field: MC raises
its raw `8` to `16` under `DeepSpecEn`, so `LsqStoreEntries` now derives to 16.
Scalar remains 8. Explicit nonzero `LsqStoreEntries` values are preserved and
still fail `gen_err_ooo_st_credits` when they exceed the physical queue.

## Checkpoint identity contract

The retained rename lane, publish seam and recovery seam now carry an eight-bit
checkpoint slot for the 128-entry MC domain. Producer/reference casts are
width-matched; recovery indexes arrays with `SLOT_W = $clog2(CKPT_DEPTH)` after
its existing range guard; publication still emits `LVL_W` including the all-ones
sentinel. A two-hart depth-128 leaf allocated slots 64..127 and printed
`CKPT128_PASS last=127`; the old six-bit record truncated 127 to 63.

## Validation

- Focused full-flist caller leaf `hyp8-r99-dispatch-c1`:
  `HYP8_DISPATCH_PASS checked=125 pop_take_same=0 opasm_int=1 opasm_fp=1`.
- Depth-128 focused rename leaf `hyp8-r99-ckpt128-c9`:
  `CKPT128_PASS last=127`.
- Isolated 731-file closure `hyp8-r99-mcfix3`, manifest SHA
  `d2a9440f4d428c4bfa69e6689811bb9a15ce18e924310f23466421f98578fb2e`.
- Final lint `hyp8-r99-mc-lint-c3` and aggregate `hyp8-r99-aggregate-c2`:
  scalar/SMT2/MC lint rc=0, `%Error=0`, `%Warning-USERERROR=0`,
  `%Warning-SELRANGE=0`; scalar build rc=0, model SHA
  `d4b061a07a609b98a9a8c3733abc352f6d0318ea86578b698a873f96f755ebc4`.
- Dedicated smokes `hyp8-r99-smokes-c1`: 7/7 pass with r90 cycle counts:
  685, 1011, 492, 2364, 2199, 1231, 671.

## Warning census

Baseline r98 aggregate -> final r99:

| Profile | Before | After | Fixed delta |
|---|---:|---:|---|
| scalar lint | 607 | 602 | 3 WIDTHEXPAND + 2 WIDTHTRUNC |
| SMT2 lint | 628 | 623 | 3 WIDTHEXPAND + 2 WIDTHTRUNC |
| MC lint | 695 | 688 | 1 USERERROR + 2 SELRANGE + 1 WIDTHEXPAND + 1 WIDTHTRUNC + 2 WIDTHCONCAT |
| scalar build | 115 | 110 | 3 WIDTHEXPAND + 2 WIDTHTRUNC |

Remaining diagnostics are unchanged ordinary width/endian/latch/case/constant
classes; they are classified, not waived. This is not a Linux/OpenSBI boot,
physical STA, complete repository-wide verification, or 8-FO4 closure claim.
