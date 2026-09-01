# EDK2 patchworks

Compile uses **official** `github.com/tianocore/edk2` @ `edk2-stable202511`
plus first-party patches. The optional `linux-dist/edk2` checkout is the
etcimon **development** fork; `extract-patches.sh` pulls diffs. QEMU and
`g6q fw build --loader edk2` never build that fork.

```
develop on linux-dist/edk2 (etcimon fork)
        │
        ▼
extract-patches.sh     →  from-fork/  (review into patches/edk2-*.patch)
        │
        ▼
apply-patches.sh       →  official out/loader-src/edk2
        │
        ▼
generated edk2-build.sh also copies patches/edk2-*.patch next to itself
```

Seed patches (already required for E2/E3):

- `../patches/edk2-riscv-sstatus-no-stack.patch` — SIE helpers must not `sd` onto a 4-byte frame
- `../patches/edk2-riscv-trap-frame-width.patch` — `SupervisorModeTrap` frame is 35×8

```bash
bash g6lc_qemu/edk2/check-patches.sh          # no fork needed
EDK2_SRC=out/loader-src/edk2 bash g6lc_qemu/edk2/apply-patches.sh
```

E4 (RTL tandem of a full FD) is not possible on Variane (no 32 MiB pflash).
The RTL witness remains `verif/tests/custom/multicore/mini_edk2_sec.S`.
