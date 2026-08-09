# B2 — Firmware policy (OpenSBI / platform)

Binary `mk_plat_skip` stubs are **prototypes**. B2 lands the same *intent* in
source under an explicit bring-up profile, then deletes hard-coded VAs.

## Target tree

| Path | Role |
|------|------|
| `software/smt2-linux/` | SMT2 OpenSBI fetch/build/patches |
| `software/smt2-linux/opensbi/patches/` | Durable OpenSBI patches |
| Platform (upstream OpenSBI after fetch) | `platform/` hooks: early_init, console, coldboot |

Do **not** edit vendored OpenSBI trees without a patch file in
`software/smt2-linux/opensbi/patches/` (or documented rebuild step).

## Proposed bring-up profile (sketch)

Name: **`CVA6_DI_BRINGUP`** (or Kconfig equivalent).

| Soft site (inventory) | Source form when profile ON | When profile OFF |
|----------------------|----------------------------|------------------|
| `b2-soft-printf` | `sbi_printf` → count+cookie stub or UART-less no-op | Real printf |
| `b2-switch-mode-payload` | `sbi_hart_switch_mode` → harness SUCCESS + WFI until payload linked | Real M→S |
| `b2-console-platform-jalr` | NULL console/device ops | Real devices |
| `b2-early-init-skip` | Empty `early_init` | Real |
| `b2-domain-finalize-cut` | Early finalize after safe walk **or** full walk once ecall poison fixed | Full finalize |
| `b2-csr-probe-skip` | Skip hart CSR probes **only if** B1 still open | Full probes |

## Domain / ecall coupling (cont.51 pin)

- Domain multi-iter with hart_ptr soft-zero can complete under DI.
- Later `sbi_ecall_init` then faults (`mepc=0x8f5a` mcause=4) — extension table / `s1` poison.
- **Do not** soft ecall permanently to “win” multi-iter.
- B2 options: (a) keep domain cut until root cause fixed; (b) source-level limited walk; (c) fix corruption then full walk + real ecall.

## Promotion steps for a B2 site

1. Add inventory id status `in_progress`.
2. Implement source `#ifdef` / platform callback (patch file under `software/smt2-linux/`).
3. Build OpenSBI **without** that site in `mk_plat_skip.py`.
4. DI cookie gate green (or documented intentional soft).
5. Mark `source-landed`; remove binary patch.

## Explicit non-goals

- No permanent single-hart “delete all spinlocks” in production profile.
- No hard-coded VAs in source patches.
- Atomically correct locks/LR-SC remain B1; B2 must not paper over B1 forever.
