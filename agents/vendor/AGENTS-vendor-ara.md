# Vendor code-agent: Ara (RVV)

| Field | Value |
|-------|--------|
| Catalog id | `ara` |
| Path | `vendor/ara/` (upstream under `vendor/ara/upstream/` after sync) |
| Domain | compute / vector accelerator |
| Seam | `core/acc_dispatcher.sv`, `EnableAccelerator`, `CvxifEn=0` |
| Package | `g6lc64_server_math_v_config_pkg.sv` |
| Architecture doc | `architecture/ara-vector-attach.md` |
| Status | **planned** — RTL not in-tree by default |

## Self-map onto CVA6

1. Decode: first-pass decoder replaces stub when `RVV`.
2. Issue: scoreboard long-latency accelerator FU.
3. Memory: Ara AXI/TCDM → SoC xbar; respect PMA / non-idempotent regions.
4. Coherence: L1 inv already ORed for accelerator in `cva6.sv`.
5. Discovery: `misa.V`; DT `riscv,isa-extensions += "v"`.

## Integration plan

`vendor sync ara` → fill `Flist.ara` → sim with `_v` package → vector memcpy directed → Linux.

## Versioning

Pin the Ara commit SHA in `.config.ts` / catalog `ref` before calling status **integrated**.
