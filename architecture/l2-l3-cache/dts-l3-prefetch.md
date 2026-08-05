# Device-tree + observability for L3 and server prefetch

## Linux DT sketch (cpu / soc)

```dts
cpus {
  #address-cells = <1>;
  #size-cells = <0>;
  timebase-frequency = <10000000>;

  cpu@0 {
    device_type = "cpu";
    compatible = "riscv";
    reg = <0>;
    riscv,isa = "rv64imafdch_zba_zbb_zbs_zicboz_sstc";
    riscv,isa-base = "rv64i";
    riscv,isa-extensions = "i", "m", "a", "f", "d", "c", "h",
                           "zba", "zbb", "zbs", "zicboz", "sstc";
    mmu-type = "riscv,sv39";
    next-level-cache = <&l2>;
    /* optional when Zicbo*: */
    riscv,cboz-block-size = <64>;
    riscv,cbom-block-size = <64>;
  };
  /* cpu@1 … for NrCores; for SMT: consecutive hartids per core×NrHarts */
};

l2: l2-cache {
  compatible = "cache";
  cache-level = <2>;
  cache-unified;
  /* sizes must match build_config inference or explicit CVA6Cfg fields */
  cache-size = <0x40000>;      /* 256 KiB example — L2ByteSize */
  cache-sets = <512>;          /* BYTE_SIZE / (SET_ASSOC * 64) */
  cache-block-size = <64>;     /* Zic64b-class; L2LineWidth/8 */
  next-level-cache = <&l3>;
};

l3: l3-cache {
  compatible = "cache";
  cache-level = <3>;
  cache-unified;
  cache-size = <0x200000>;     /* 2 MiB example — L3ByteSize */
  cache-sets = <2048>;
  cache-block-size = <64>;
};
```

### Size recipes (match `build_config_pkg` auto-infer)

| Profile | NrCores | L2ByteSize (auto) | L3ByteSize (auto) |
|---------|---------|-------------------|-------------------|
| server_math | 2 | max(256 KiB, 2×128) = **256 KiB** | L3En=0 |
| ooo_server | 4 | max(256 KiB, 4×128) = **512 KiB** | max(2 MiB, 4×1 MiB) = **4 MiB** |

`cache-sets = BYTE_SIZE / (SET_ASSOC × block_bytes)`. Default set_assoc L2=8, L3=16, block=64.

Align `AGENTS-dts-validation.md` when a board enables `L2En`/`L3En`.

## PMU (Sscofpmf)

| Group | Index | Meaning | Source |
|-------|-------|---------|--------|
| 0 | legacy | existing CVA6 events | `perf_counters.sv` |
| 1 | 0–7 | OoO rename/IQ/ROB/LSQ/STL | core `ooo_*` probes |
| 2 | 0 | L3 miss | cluster → each core `l3_miss_i` → `perf_counters` |
| 2 | 1 | L3 hit | `l3_hit_i` |
| 2 | 2 | Prefetch issue | `pf_issue_i` |
| 2 | 3 | Prefetch train | `pf_train_i` |
| 2 | 4 | L2 miss | `l2_miss_i` |

Select: group1 `mhpmeventN = {3'b001,5'b…}`, group2 `{3'b010,5'b…}`.

## Multi-core L3

L3 is **shared** on the cluster memory master (after coherence hub + L2). Prefetcher
sits after L3 so multi-core demand always wins AR over PF.

### Inclusive L3 (scaffold landed)

**Goal:** when LLC (L3, or L2 if L3 off) **replaces a valid victim**, back-invalidate L1s
so inclusion is not violated by stale private copies.

| Piece | Location |
|-------|----------|
| Victim report | `g6lc_l2_top` `l2_evict_valid/addr` (also via `g6lc_l3_top`) |
| Fan-out inv | `g6lc_l3_inclusive_inv.sv` → `coh_inval_t` per core |
| Enable | cluster param **`INCLUSIVE_L3=1`** (default **0**) |
| Merge | hub inv wins over inclusive if both valid |

Still open: invalidate **L2** tags on L3 victim (today only L1 via inv bus); SF keyed on L3.

**Software:** DT does not need an “inclusive” property; Linux treats LLC as unified cache level 3.

## Board bring-up

1. Enable `L2En` (+ optional `L3En`) in the active config package.  
2. Update board `.dts` cache nodes to match inferred sizes.  
3. Run `l3_stride_stream` (optional `ooo-l3-tests` suite).  
4. Measure PMU group 2 once SoC wiring lands.  
