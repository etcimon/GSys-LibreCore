# Guide: RISC-V Vector (RVV) / Ara attach

Feature-addition playbook for **RVV 1.0** on CVA6V-EC. Vector is **not** an in-pipeline ALU
inside the scalar core; it is delivered by attaching **PULP Ara** at the accelerator seam
(`EnableAccelerator` / `acc_dispatcher`). Read `../../AGENTS.md` first. Spec summary:
`../spec/riscv-spec-I-9-vector.html`. Integration contract: `../../architecture/ara-vector-attach.md`.

## Table of contents
1. Spec grounding
2. Code map (`file:line` / loci)
3. Config knobs
4. Feature-addition playbook
5. Software / SBI / Linux / `.dts`
6. Verification
7. Invariants and pitfalls

## 1. Spec grounding

Normative home is Vol I **chapter 9** (Vector Extension): overview
`specs/riscv-spec.html#_vector_extension_overview`, instruction formats
`#_vector_instruction_formats`, load/store `#_vector_load_store_instructions`, integer arithmetic
`#_vector_integer_arithmetic_instructions`, and the single-letter **V** extension
`#ext:v` (depends on Zvl128b + Zve64d for application V). Subsets Zve32x / Zve64x / Zve64d
(`#ext:zve32x`, `#ext:zve64x`, `#ext:zve64d`) describe embedded profiles. Vector has **precise
traps**; `misa.V` is set when the implementation advertises V.

Memory-side behavior still obeys RVWMO `#memorymodel` and PMA `#pma`. CVA6 does **not** implement
vector crypto (`zvk*`) or a second in-core VRF.

Sub-file of record: `../spec/riscv-spec-I-9-vector.html`.

## 2. Code map

| Layer | Locus |
|-------|--------|
| Config field `RVV` | `core/include/config_pkg.sv` (`cva6_cfg_t` / user cfg) |
| Packages | `core/include/g6lc64_server_math_v_config_pkg.sv` (`VExtEn=1`, `CvxifEn=0`); non-`_v` leave `RVV=0` |
| `misa.V` (bit 21) | `core/csr_regfile.sv` (OR of `CVA6Cfg.RVV`); dirty-V path when `RVV` |
| Accelerator enable | `build_config_pkg` ← `CVA6Cfg.RVV` → `EnableAccelerator` |
| Dispatch / long-latency FU | `core/acc_dispatcher.sv`; genblock `core/cva6.sv` `gen_accelerator` |
| Mutex with CVXIF | `core/cva6.sv` assert: `CvxifEn` and accelerator mutually exclusive |
| SoC glue | `corev_apu/src/g6lc_ara_attach.sv` (live under `` `define CVA6_ARA_ATTACH ``, else stub); wide AXI merge `corev_apu/src/g6lc_axi_2to1_mux.sv` |
| Cluster / ariane path | `corev_apu/src/ariane.sv` EnableAccelerator wiring; cluster instantiates `ariane` |
| Vendor IP | `vendor/ara/upstream`, `vendor/ara/Flist.ara`, shims `vendor/ara/cva6_shim/` |
| Lint top | `verif/tb/g6lc_ara_lint_top.sv` |
| Directed tests | `verif/tests/custom/vector/`, `verif/tests/testlist_ara_vector.yaml` |
| Path suite | `verif/regress/ara-vector-path.{sh,ps1}` |

There is **no** in-core VLEN/SEW register file in the scalar pipeline. Ara owns the VRF and vector
datapath; CVA6 only issues accelerator ops and retires them via the scoreboard long-latency path.

## 3. Config knobs

| Knob | Meaning |
|------|---------|
| `CVA6Cfg.RVV` / `CVA6ConfigVExtEn` | ISA + accelerator path; sets `misa.V` |
| `CvxifEn` | Must be **0** when RVV/accelerator is on |
| `EnableAccelerator` | Derived; gates `acc_dispatcher` + SoC attach |
| `NonIdemPotenceEn` | Ara/non-idempotent region interaction (see `config_pkg` notes) |
| Ara parameters | `NrLanes`, `VLEN` on `g6lc_ara_attach` (SoC-side; not full `cva6_cfg_t` yet) |

Select package of record for live vector:

```
core/include/g6lc64_server_math_v_config_pkg.sv
```

Default server C-light (`g6lc64_server_math`) keeps `RVV=0` and may use CVXIF.

## 4. Feature-addition playbook

1. **Do not** invent a second vector datapath inside `ex_stage` / execute. Prefer Ara (or another
   accelerator) behind `acc_dispatcher`.
2. Vendor IP: `cva6-build vendor sync ara` → `vendor/ara/upstream` + keep `Flist.ara` / shims current.
3. Arm flist only for the `_v` target (`verify.extraFlistsByTarget.g6lc64_server_math_v`).
4. Elaborate with `` `define CVA6_ARA_ATTACH `` for **live** Ara; without it the attach is a stub
   (`acc_resp` idle — vector ops will **not** complete).
5. Wire wide Ara AXI into the SoC xbar (existing `g6lc_axi_2to1_mux` + dwc path when needed).
6. Keep **timing / placement** as an island (clock-gate, power region); propagate `scan_enable_i` /
   DFT; add PMU/RVFI hooks for vector busy if missing.
7. Software contract (next section): DTS `v`, SBI context, directed `v_memcpy_*`.
8. Verify: `CVA6_ARA_ATTACH=1 cva6-build verify --lint --target g6lc64_server_math_v`, then suite
   `ara-vector-path`, then optional `cva6.py` cosim with `testlist_ara_vector.yaml`.

## 5. Software / SBI / Linux / `.dts`

| Artifact | Role |
|----------|------|
| `corev_apu/bootrom/ariane-server-math-v.dts` | CPU nodes advertise RVV 1.0: `v` + `zve64d` + full server set (`imafdcv…_zacas_…`) for the `_v` package only |
| Default `ariane*.dts` / `ariane-linux.dts` / `ariane-smt2.dts` | **No** `v` / `zve*` — matches non-RVV packages; opensbi-linux-boot tier A2 enforces |
| OpenSBI | Must save/restore vector CSRs + VRF on context switch when `misa.V` is set; enable `mstatus.VS` before first V op |
| Linux | `riscv,isa` / `riscv,isa-extensions` must include `v` only if hardware+firmware support it; kernel vector context switch depends on SBI + `CONFIG_RISCV_ISA_V` |

**Alignment rule (SoC readiness):** package `RVV` ⇔ `misa.V` ⇔ DTS `v` ⇔ SBI vector context ⇔
toolchain `-march=…v…`. Never advertise `v` on a tree that still uses stub Ara or `RVV=0`.

SBI/firmware notes (bring-up checklist, not a full OpenSBI fork in this repo):

1. Probe `misa.V` before enabling vector in S-mode software.
2. Set `mstatus.VS` (and keep dirty-state coherent with the accelerator) around V use.
3. Context-switch path: save/restore `vtype`/`vl`/`vstart`/`vcsr` and the VRF (or trap-and-emulate
   policy — not recommended for production Ara).
4. Linux: enable V only after OpenSBI reports vector support; keep DTS tokens legal per
   `Documentation/devicetree/bindings/riscv/extensions.yaml` (`v` token).

## 6. Verification

| Gate | What it proves |
|------|----------------|
| `ara-vector-path` | Artifacts + `server_math_v` lint + optional live Ara lint (`CVA6_ARA_ATTACH=1`) |
| `testlist_ara_vector.yaml` | Directed asm: soft-skip without V; LMUL memcpy when V+live Ara |
| Full RVV compliance / Spike cosim | Still open — needs provisioned `riscv-gcc` + Spike + `cva6.py` target |

Directed tests under `verif/tests/custom/vector/`:

- `v_memcpy_skip.S` — always soft-pass without functional V ops (CI-safe on any package).
- `v_misa_v.S` — discovery: records whether `misa.V` is set; never fails solely for V clear.
- `v_memcpy_lmul.S` — unit-stride e64 m1 memcpy via raw encodings; **requires** `misa.V` **and** live
  Ara (stub attach hangs on accelerator response). Soft-skips when V clear.

## 7. Invariants and pitfalls

- **CVXIF ↔ RVV mutex** — never enable both; the core asserts.
- **Stub attach** — elaborates and lints, but `acc_resp=0` means vector issue never completes; do not
  run functional vector tests against the stub.
- **ISA advertising** — lying in DTS/`riscv,isa` about `v` breaks Linux bring-up harder than leaving V off.
- **Line size / PMA** — Ara memory traffic must honor non-idempotent regions and RVWMO; keep CMO and
  L1/L2 policy consistent with the server_math hierarchy.
- **Superscalar + accelerator** — scoreboard long-latency path must remain flush-safe on mispredict
  and exception (precise V traps).
- **Licensing** — new proprietary code under `.licensing-policy`; do not relicense Ara upstream.

## Related

- `architecture/ara-vector-attach.md` — operator attach status and flist steps
- `agents/vendor/AGENTS-vendor-ara.md` — vendor code-agent for the Ara tree
- `AGENTS-specs-to-impl.md` / `AGENTS-specs-to-tests.md` — living status rows for Vector / Ara
- C-light stand-in (no V): `verif/tests/custom/server_math/u10_memcpy_stream.S`
