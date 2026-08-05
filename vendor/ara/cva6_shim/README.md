# CVA6 shims for PULP Ara (U10ᵇ)

Small patches so Ara elaborates against **OpenHW CVA6 / cvfpu** and current
**pulp-platform/axi**, without forking the full Ara tree.

| File | Why |
|------|-----|
| `vmfpu.sv` | CVA6 `fpnew_pkg` has 5 FP formats and 4 opgroups (no DOTP / FP8ALT); drop `hart_id_i` on `fpnew_top` |
| `lane_sequencer.sv` | Verilator `ENUMVALUE`: replace `default:'0` that zero-initializes enum fields |
| `vlsu.sv` | `axi_cut` parameters are `req_t`/`resp_t` (not `axi_req_t`/`axi_resp_t`) |

Upstream sources remain under `vendor/ara/upstream/`. `Flist.ara` points at these
shims where listed.

**License:** upstream Ara SHL-0.51 for derived RTL; shim notes are project docs.
