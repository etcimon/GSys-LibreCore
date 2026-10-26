# r45 — MMU caller specialization and request predicates

Continuation of the retained r44 changes. This pass implements a dedicated
disabled-shared-TLB router, local TLB flush predicates and a reduced load
physical-address capture predicate. Existing cycle contracts remain the
reference. The RTL diff and paired measurements have been reviewed; targeted
verification is recorded below when complete.

## Source contracts

### Disabled shared TLB

`g6lc_mmu::i_shared_tlb` currently instantiates the shared-TLB module even
when `G6LCCfg.UseSharedTlb=0`. Its live behavior in that configuration is:

- DTLB access suppresses an ITLB request even when the DTLB access hits.
- The selected access/address/side is registered; address and side retain
  their values when no request is selected.
- A returned PTW update routes according to the registered request bits.
  Update ASID, VMID, hart and PTE come from the returned record.
- The routed update's stage-enable field uses the live stage flags selected
  by the registered side. This extraction does not retime that context.
- `shared_tlb_hit_o` follows the return valid bit even without a registered
  request owner. Both local update outputs are then zero.
- Flush busy is zero in the disabled configuration, but the existing
  READ/APPLY walker still suppresses new requests for two cycles per set.
  Requests resume on the same edge in the extracted implementation.

The new `g6lc_tlb_miss_router` has only the ports/state needed for those
outputs. A generate in the MMU chooses it or the original enabled table.
The existing `UseSharedTlb` field owns that choice; no new feature switch
or timing exception is introduced. The enabled table remains available.

This is an explicit functional specialization, not permission to delete
the whole shared-TLB module from every configuration's timing report.
The old standalone module score and the new router score are different
functions and must not be presented as a measured hardware speedup of
the disabled-table core.

### Local TLB flush

The old NAPOT flush expression constructs a VPN, masks low four bits on
both sides, then compares. For equal-width vectors the relation is:

```
(a & ~mask_low4) == (b & ~mask_low4)
    iff a[VpnLen-1:4] == b[VpnLen-1:4].
```

Compute this and the ordinary page match independently per row. The
four SFENCE cases factor into:

```
eligible_translation_stage
&& (flush_address_is_zero || row_address_match)
&& (flush_asid_is_zero || (!global && row_asid_match)).
```

Keep SFENCE before VVMA before GVMA before replacement. An all-zero
address or ASID has architectural meaning; it is not an invalid request.
The rewrite adds no lookup or update cycle and caches no live request
predicate.

The old masked-address equality and four-case expression are retained
as a local simulation reference. Directed fills and flushes must make
both matching and nonmatching rows observable.

### Load physical-address capture

The original capture condition is:

```
valid_i && translation_req_o && dtlb_hit_i
```

`translation_req_o` already has an explicit state decode. Under the
outer `valid_i && dtlb_hit_i` guard, `dtlb_hit_i` makes `tr_idle_ok`
true, and `valid_i` absorbs the repeated valid tests in admission and
cancellation. The equivalent capture condition uses:

```
pa_capture_state =
    WAIT_GNT
    || (WAIT_TRANSLATION && (MmuPresent || NonIdemPotenceEn))
    || ((IDLE || SEND_TAG) && !ldbuf_full);

capture = valid_i && dtlb_hit_i
          && (!OoOEn || !cancel_hit) && pa_capture_state;
```

The translation request output, held PA, drop/pop priority, live PA
selection, request ID and forward-request edge stay as they were.
An assertion compares the new capture bit directly with the original
expression; the existing FSM reference remains independent.

## PTW decision

The reported 37.55-FO4 PTW chain at the raw NAPOT predicate belongs
to the procedural `!PDEC` branch, whereas current Hyp8 selects
`PtwDecodeStage=1`. Another extraction solely to make that branch
disappear from a source report would not establish a hardware reduction.
No PTW latency change is part of this batch. Its next discriminator is
the actual active decode/verdict boundary, not the raw module maximum.

## Measurement identity

Before source edits, the lead ran the same command as r44 using:

- `analysis/r44-param-map.json`, SHA-256
  `75d16bc9fad4f78f2892dd34c921b8a90e5424de14b0d7d14886d643a19830e9`;
- analyzer executable SHA-256
  `d837e8798a2b34800c2ec13abda21ee69e88d5558e57b9d1085c049057f08a91`;
- the same width map, `--all-modules --stages`,
  5000 MHz target, 20 ps/FO4 and 0.2 margin.

The before artifact is
`build-platform/workspace/build/sv-timing/hyp8-src/boards/hyp8-core/analyze-r45-before.json`.
Before maxima: load input-to-register 36.15, load L5 reg-to-output
30.25, TLB reg-to-reg 36.4 and lookup reg-to-output 31.0 FO4.
The measurement file list gains the new router for the after run;
all old entries and analysis settings remain unchanged.

These are source-screen quantities. Disabled procedural branches,
generic instance parameters and port-bridge composition remain limitations.
No change of cost model, stage window or physical constraint is used to
claim improvement.

## Results

The after artifact is `boards/hyp8-core/analyze-r45-after.json` under
the same analysis workspace. The lead independently checked the before
and after path records and the changed MMU instance graph.

| Boundary | Before FO4 | After FO4 | Interpretation |
|---|---:|---:|---|
| TLB reg-to-reg maximum | 36.40 | 31.00 | Flush no longer sets the module maximum; lookup now does. |
| TLB reg-to-output lookup | 31.00 | 31.00 | Lookup latency and this cone are unchanged. |
| TLB input-to-output | 15.25 | 22.85 | Displaced work is reported, although below the 31.0 maximum. |
| Load maximum across path kinds | 36.15 | 35.05 | Small reduction; the analyzer also reclassifies the capture dependency. |
| Load input-to-register | 36.15 | 5.00 | Do not report this alone as the load improvement. |
| Load reg-to-reg | 19.35 | 35.05 | The capture path now appears here; no register was added. |
| Load input-to-output | 36.15 | 23.95 | Read with the 35.05 reg-to-output maximum. |
| Dedicated miss router reg-to-reg / reg-to-output | — | 9.70 / 10.70 | New specialization, not an old-to-new table speedup. |

The new router's limiting source anchor is its walk-state/request-admission
decode. The active MMU instance graph contains `i_miss_router` and no
`i_shared_tlb` under the pinned `UseSharedTlb=0`; the enabled shared table
remains in the source list and retains its standalone score. MMU, PTW,
dispatch, cache memory and LSQ reducer maxima are unchanged in this pair.

The measurements also contain simulation-reference paths. The new TLB
miter's reported input-to-output path is 7.5 FO4, below the selected
functional maxima; it is not used as timing evidence. This reinforces
the need to inspect source origin rather than ranking every reported
path indiscriminately.

Pre-edit copies and hashes are under
`C:/Users/etcim/cva6-artifacts/r45/pre/`. The new router is present in all
three hyp8 manifests. Its exact hypothetical path has a dedicated
licensing/REUSE entry; existing upstream MMU/TLB/load notices remain
unchanged.

The retained changes add no instruction pipeline cycles and change no
ISA, DTS cache geometry, firmware or architectural discovery fields.
Existing table-off flush quiet time is intentionally preserved.

## Verification outcome

Final refined-source leaves on the sha-pinned closure (`hyp8-r45-closure`,
394 files) and the integration lint closure (`hyp8-r45-int-closure`, 818
files):

| Surface | Result | Scope |
|---|---|---|
| MMU leaf `tb_g6lc_hyp8_mmu` | `HYP8_MMU_PASS checked=716 miter=771` (`hyp8-r45-mmu-r6`) | Router vs. the real disabled-table module, every output every edge, depths {2,3,64} x HYP_EXT {0,1}; directed I/D/simultaneous/no-owner/flag-switch/flush/quiet-window/reset-midwalk cases plus a 300-cycle varying soak. TLB row-predicate rewrite over entries {4,16} x stages {1,3} x HYP_EXT {0,1} with an independent fill/lookup/flush oracle. |
| MMU negative control | `FAIL MMU0_IRET_VALID` (`hyp8-r45-mmu-mut`) | Bench copy with the I-return arm suppressed fails by name. |
| Depth-1 reference probe | reference does not elaborate (`hyp8-r45-mmu-refd1`) | The old module's `$clog2(1)`-wide selects are an unsupported geometry; the new router is checked at depth 1 against the explicit two-cycle quiet-window expectation. |
| Memory leaf | `HYP8_MEMORY_PASS checked=129` (`hyp8-r45-memory-r3`) | r44 cases plus the PA-capture qualification (no capture without hit, capture on hit while held, no capture under cancel, clear on release); the capture invariant ran throughout. |
| Full-top lint scalar/SMT2/L3 | rc=0, zero `%Error` (`hyp8-r45-lint`) | Only the three pre-existing vendor latch warnings. |

Dispatch, D-cache and LSQ were not touched in r45; their r44 evidence stands.

### Findings outside the planned batch

1. **Latent PLRU defect fixed in `g6lc_tlb.sv`.** The T1 flat-mask PLRU
   used `lvl = $clog2(n+1)`, which is the BFS level only when `n+1` is a
   power of two; other tree nodes got an empty update mask and never
   changed (for four entries, entry 3 was never selected for replacement).
   Discriminating evidence: a hit on entry 2 produced a live next tree
   `001010` against the priority-loop reference `001110`. The fix is
   `lvl = $clog2(n+2)-1`; the equivalence check now compares only the real
   node prefix (the register is wider than the real tree and the extra
   bits are unread by `replace_en`). It was never caught earlier because
   no leaf instantiated `g6lc_tlb` and the old self-check used the same
   formula. This is a replacement-policy repair, not an ISA-visible
   translation change; it is retained because the leaf shows the old form
   failing and the new form passing.
2. **Dormant latch in the enabled shared-table arm.** With `UseSharedTlb=1`
   the shared-TLB module elaborates but `patched_pte` is assigned only
   under the way-hit condition (`-Werror-LATCH`). The arm is unreachable in
   every hyp8 build and was left unchanged; it is recorded as a follow-up
   for any configuration that enables the table.

No firmware, Linux, synthesis or physical timing qualification is claimed.
