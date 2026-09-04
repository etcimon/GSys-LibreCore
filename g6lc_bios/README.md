# g6lc_bios

Independent GSys LibreCore BIOS: a **rewrite** of TempleOS/ZealOS (those trees
are specs under `kernel-spec/`) as an S-mode setup kernel whose **display is
HTML+JS**, plus an SSH+HolyC KVM face, all from a BoardSpec. Inferences from
the spec forks must match LibreCore architecture (`architecture/PLAN.md`).

```
python tools/g6b.py check
python tools/g6b.py boot --spec fixtures/g6lc64-virt.json
python tools/g6b.py regress
```

QEMU (via the optional host; never Variane evidence):

```
g6q gen --emit bios-spec --target g6lc64_smt2 --machine g6lc-virt
g6q run --loader bios --dry-run --loader-image out/g6lc_bios.elf
# UART1 is the SSH-like HolyC port (default 2222); --holyc-port off disables it
```

The BIOS package does not depend on `g6lc_qemu`. See `AGENTS.md`.
