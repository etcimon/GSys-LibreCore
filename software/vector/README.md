# Vector (RVV) firmware / Linux software contract

In-tree **software profile** for GSys LibreCore RVV via **Ara** (`g6lc64_server_math_v`).
Hardware attach: `architecture/ara-vector-attach.md`, guide `agents/guides/AGENTS-vector.md`.

| Piece | Path |
|-------|------|
| OpenSBI VRF checklist | `opensbi-vrf.md` |
| Linux defconfig fragment | `linux.config-fragment` |
| Gate (artifacts) | `verif/regress/ara-vector-path.sh` |
| Gate (cosim / soft tests) | `verif/regress/ara-vector-cosim.sh` |
| Directed asm | `verif/tests/custom/vector/` + `testlist_ara_vector.yaml` |
| DTS (advertise `v`) | `corev_apu/bootrom/ariane-server-math-v.dts` only |

## Alignment rule

```
package RVV=1  ⇔  misa.V  ⇔  DTS "v"/"zve64d"  ⇔  OpenSBI VRF context  ⇔  Linux CONFIG_RISCV_ISA_V
```

Never advertise `v` on `ariane-smt2.dts` / default `ariane-linux.dts` while Ara is stubbed
or the package has `RVV=0`.

## Quick path

```bash
# Artifact + optional lint
bash verif/regress/ara-vector-path.sh

# Soft directed cosim (skip/misa always; lmul needs live Ara TB)
bash verif/regress/ara-vector-cosim.sh

# Live Ara cosim (rebuild TB — long):
CVA6_ARA_ATTACH=1 DV_TARGET=g6lc64_server_math_v \
  ARA_COSIM_REBUILD=1 bash verif/regress/ara-vector-cosim.sh
```

OpenSBI / kernel steps: see `opensbi-vrf.md` and `linux.config-fragment`.
