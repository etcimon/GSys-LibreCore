# CVA6 L2 cache (U6.0)

Memory-side AXI-to-AXI L2 under `corev_apu/l2_cache/`. Does **not** edit `core/cache_subsystem`.

## Contention optimisations
- **Multi-MSHR + line-merge** (`g6lc_l2_mshr.sv`): secondary miss to an in-flight line does not open a new AXI transaction.
- **Multi-waiter attach (U6.2)**: up to `MAX_WAITERS` ids per line so multi-core same-line misses share one fill.
- **Banked data array** (`g6lc_l2_data.sv`, default 4 banks via `tc_sram`): hit read and fill write proceed in parallel when banks differ.
- **Non-cacheable bypass**: `ax.cache[1]==0` skips tags (MMIO never pollutes L2).
- **Write-through + read-allocate**: matches CVA6 WT L1; writes push through to memory.
- **Parallel tag compare**: single-cycle SET_ASSOC hit path.
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
