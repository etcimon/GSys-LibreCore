# Spike multi-hart patches (GSys LibreCore)

Applied automatically by `build-platform/scripts/install-spike.sh` onto the
vendored OpenHW cosim Spike (`verif/core-v-verif/vendor/riscv/riscv-isa-sim`).

## Why

OpenSBI dual-hart (`-p2` + `ariane-smt2.dts`) needs every hart stepped. The
upstream cosim `Simulation::run` only stepped `procs[0]`, so IPI init failed
with error `-3`. Standalone mode also must tick CLINT/UART and must **not**
HTIF-yield every interleave (that spuriously completed the HTIF run mid-boot).

## Patches

| File | Change |
|------|--------|
| `0001-Simulation-standalone-multihart.patch` | RR step all harts; CLINT/UART tick; no HTIF yield |
| `0002-Proc-per-hart-isa.patch` | Per-hart ISA / privilege setup |
| `0003-spike-main-per-hart.patch` | Per-core mhartid / logging |

Paths in the diffs are relative to the **isa-sim root** (`riscv/…`, `spike_main/…`).
