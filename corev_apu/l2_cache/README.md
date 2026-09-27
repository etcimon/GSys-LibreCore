# CVA6 L2 cache (U6.0)

Memory-side AXI-to-AXI L2 under `corev_apu/l2_cache/`. Does **not** edit `core/cache_subsystem`.

## Contention optimisations
- **Multi-MSHR + line-merge** (`g6lc_l2_mshr.sv`): secondary miss to an in-flight line does not open a new AXI transaction.
- **Multi-waiter attach (U6.2)**: up to `MAX_WAITERS` ids per line so multi-core same-line misses share one fill.
- **Banked data array** (`g6lc_l2_data.sv`, default 4 banks via `tc_sram`): hit read and fill write proceed in parallel when banks differ.
- **Non-cacheable bypass**: `ax.cache[1]==0` skips tags (MMIO never pollutes L2).
- **Exclusive AR bypass**: `AR.lock` is captured and forwarded on the memory-side AR. A locked read never takes the tag-hit path (that would return OKAY and leave `g6lc_axi_lrsc` unarmed). `AW.lock` / ATOP were already preserved for AMOCAS/STEX.
- **Write-through + read-allocate**: matches CVA6 WT L1; writes push through to memory.
- **Parallel tag compare**: single-cycle SET_ASSOC hit path.

## Write-update policy (`WRITE_UPDATE` / `CVA6Cfg.L2WriteUpdateEn`)

Default off; when enabled, a write-through to a **resident** line merges the W
beats into that line instead of invalidating the tag. Motivation (T8e,
measured on `mc_l2_write_read` and the four-hart OpenSBI boot): ~6,060 of
8,192 stores purged a resident L2 line and ~90k of ~100k boot L2 misses
followed a purge.

**Ordering argument.** A write is globally ordered by its B response: the
coherence hub drops the writer's L1 copy at B, so a reader served *before* B
may legally observe pre-write data, while any reader served *after* B must see
the new bytes. Merging keeps the same bound as purging — the FSM stays in the
write bypass sequence until B lands (`S_BYPASS_AW → S_BYPASS_W → S_BYPASS_B`),
so no read can be served the merged line before memory acknowledged the write;
the composed bench's `late_ar_cycle >= mem_b_cycle` admission contract holds
under both settings.

**Eligibility** (evaluated once, at AW acceptance, on registered fields —
`wu_eligible`): cacheable write, `atop == '0`, not locked, the whole burst
inside the addressed line (`len==0` of any size, or a full-width multi-beat
INCR run ending inside the line), and no in-flight fill for the same line.
Anything else — atomics, locked accesses, non-cacheable writes,
same-line-fill races, tag-miss writes — keeps the invalidate-and-kill path,
including the fill-kill (`kill_match` fires on every write either way) and the
deferred self-invalidation retry.

**Collision rules.** A back-invalidation colliding with a merge arms the
deferred match port and conservatively clears the merged line. An install
that would claim the merge's way mid-write is stalled (`wu_install_stall`)
until the write drains into `S_BYPASS_B`; a tag `write_i` landing on the
match-read edge exempts that way from the deferred inval-match compare (the
tag replacement itself retires the invalidation). `l2_wupdate_o` pulses once
per merged write (last forwarded beat).

**Timing impact:** the merge adds a byte-enable shifter plus a data-port-A
write mux in the bypass states only — no path into the `S_TAG` hit compare;
the eligibility compare is on registered request fields.
- **Pairs with** `corev_apu/coherence/` split AR‖AW hub under multi-core.

## Config (`cva6_cfg_t`)
| Knob | Meaning |
|------|---------|
| `L2En` | Wire L2 in SoC (e.g. `ariane_testharness`) |
| `L2ByteSize` | Capacity (e.g. 262144) |
| `L2SetAssoc` | Ways (e.g. 8) |
| `L2LineWidth` | Bits; must match D$ / 512 for 64 B |
| `L2MshrDepth` | Outstanding misses (power of two) |
| `L2DataBanks` | Data banking factor |
| `NrHarts` | 1 baseline; 2 reserved for U6.1/U6.2 |

## Files
- `g6lc_l2_pkg.sv` — geometry helpers
- `g6lc_l2_mshr.sv` — MSHR + merge
- `g6lc_l2_tag.sv` — tag array
- `g6lc_l2_data.sv` — banked data (`tc_sram`)
- `g6lc_l2_top.sv` — AXI slave/master controller

## U6.1 / U6.2 scaffold
`NrHarts` is config-gated (1|2). SMT thread-tag and dual-core snoop filter land in later sub-phases; L2 MSHR depth and banking are sized to absorb dual-hart MLP.
