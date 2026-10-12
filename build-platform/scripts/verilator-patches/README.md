# Verilator fork (simulation-speed work, tier T tooling around a tier-U compiler)

The simulation-speed changes to Verilator live in the fork
**github.com/etcimon/verilator**, branch **`g6lc`**, based on the pinned release
`v5.008` (the qualification compiler). The fork is pinned as the submodule
`tools/verilator`; the gitlink is the version of record. Verilator keeps its own
licence (LGPL-3.0-only OR Artistic-2.0); nothing of it is relicensed here.

Build (builder, no root):

```
bash build-platform/scripts/install-verilator-g6lc.sh
# -> /opt/testharness/toolchains/verilator-v5.008-g6lc  (version string "5.008 (mod)")
# -> .../verilator-v5.008-g6lc/runtime : the pinned runtime headers + the fork's verilator_bin,
#    for the build driver's T16_VLT_ROOT (t21s-build.sh)
```

The Yosys fork is the sibling submodule `tools/yosys` (branch `g6lc`).
`build-platform/scripts/install-yosys-g6lc.sh` installs it to
`/opt/testharness/toolchains/yosys-g6lc`. `tools install formal` builds that
same checkout. See `agents/guides/AGENTS-verilator-performance.md`.

Commits on `g6lc` (newest first), each one codegen-only and measured with callgrind
(`agents/guides/AGENTS-verilator-performance.md`):

| commit | effect |
|---|---|
| `1878fd75` V3Const: do not merge part-select assignments into a wide (>64-bit) concat | the merged wide CONCAT chain was emitted as O(n²) `VL_CONCAT_W*` copies — 22 % of the eval instructions of a `g6lc64_ooo` model |

Models built with the fork record `recipe.verilatorRoot` in their build manifest;
qualification records state which compiler built a model. The pinned `v5.008`
(unmodified) remains the compiler of the qualification runs until a fork version is
qualified on the full battery (anchors byte-identical, FP/probes Spike-exact).
