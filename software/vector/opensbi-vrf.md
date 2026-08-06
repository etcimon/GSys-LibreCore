# OpenSBI vector context (VRF) for Ara / RVV

**Status:** checklist + patch points in-tree; apply against a fetched OpenSBI tree
(same workspace style as `software/smt2-linux/`). Full production SBI vector
support is **upstream OpenSBI** feature work — this file is the CVA6V-EC
integration contract so agents do not invent a second VRF in the scalar core.

## Why this exists

When `misa.V` is set (package `g6lc64_server_math_v` + live Ara):

1. M-mode / HS must allow `mstatus.VS` transitions (Off → Initial → Clean → Dirty).
2. On hart context switch / HSM start, firmware or OS must save/restore:
   - CSRs: `vtype`, `vl`, `vstart`, `vcsr` (and `vxrm`/`vxsat` via `vcsr`)
   - The **VRF** (Ara-owned architectural vector registers)
3. Linux with `CONFIG_RISCV_ISA_V` relies on SBI / kernel assembly for that path.
   Without it, multi-task vector userspace corrupts state.

Ara owns the physical VRF; CVA6 only issues accelerator ops. Context switch still
needs a software protocol to **snapshot** Ara state (or fence vector ops + dirty
bit policy). Production path: OpenSBI + kernel, not bare-metal only.

## Probe sequence (M-mode bring-up)

```text
1. csrr t0, misa ; check bit 21 (V)
2. if clear → do not advertise v in DTS / do not enable CONFIG_RISCV_ISA_V
3. if set  → csrs mstatus, MSTATUS_VS   # enable vector state
4. first V insn may mark VS Dirty; trap if VS Off
```

Directed bare-metal: `verif/tests/custom/vector/v_misa_v.S`, `v_memcpy_lmul.S`.

## OpenSBI integration points (upstream)

When building OpenSBI for a `_v` platform (generic + `ariane-server-math-v.dtb`):

| Area | Expectation |
|------|-------------|
| Feature probe | Detect `misa.V` / FDT `riscv,isa` containing `v` |
| `sbi_hart` context | Save/restore vector CSRs on switch if V present |
| Extension | Prefer upstream vector / SSE context if available for your OpenSBI pin |
| Platform | `PLATFORM=generic`, `FW_FDT_PATH` = server-math-**v** DTB when vector is live |
| Mutex | Do not enable CVXIF-only packages with this DTB |

Suggested lab build (after Image/OpenSBI fetch — not default CI):

```bash
# Example: reuse SMT2 OpenSBI fetch tree
export OPENSBI_SRC=build-platform/workspace/smt2-linux/opensbi
# Point FW_FDT at a compiled ariane-server-math-v.dtb when available
# Apply any vendor vector patches required by your OpenSBI version
# Then rebuild fw_payload with the Linux Image that has CONFIG_RISCV_ISA_V
```

Document version pin next to the OpenSBI pin used for SMT2 (`software/smt2-linux`).

## What CVA6 will not do

- Implement an in-core VRF in `ex_stage` / scoreboard.
- Soft-pass dual-ISS or Spike as RVV golden when Ara is the execution unit
  (Spike may model V; RTL golden is live Ara).
- Advertise `v` on non-`_v` DTS trees.

## Gate

`verif/regress/ara-vector-cosim.sh` tier **SBI** checks this file + Linux fragment
exist and that DTS/package alignment still holds. It does **not** rebuild OpenSBI
by default.
