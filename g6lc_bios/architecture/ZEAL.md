# ZealOS / TempleOS — spec of record for the rewrite

Unlicense / public-domain **specs**, not a tree we compile. Checkouts:
[`../kernel-spec/`](../kernel-spec/) (`ZealOS/`, `TempleOS/`). The BIOS
platform is a **rewrite** of the services named here, in conformity with
LibreCore (`PLAN.md` §3). Prefer ZealOS paths; TempleOS is the root snapshot.

When an ancestor file implies x86, ring-0-only, VGA, or a NIC-as-OS, that is
spec of *intent*. The implementation follows BoardSpec + CVA6/OpenSBI/PLIC.

**Keep (as services):** Adam, DolDoc store, ZealC CLI shape, `#exe` compile-time
opts, Clip, AutoComplete, Gr as a BoardSpec-sized framebuffer.

Kernel-spec loci (read these, then rewrite — do not copy x86). Full map:
[`KERNEL-RV.md`](KERNEL-RV.md).

- Start / KMain: `kernel-spec/ZealOS/src/Kernel/KMain.ZC`, `KStart64.ZC`, `KTask.ZC`
  (TempleOS: `kernel-spec/TempleOS/Kernel/KMain.HC`, `KStart64.HC`)
  → generated `zeal/KStart.S` + `g6b-elf` (S-mode, `tp`/`sp`/`stvec`)
- Interrupts: `KInterrupts.ZC` → `zeal/KInts.S` (`stvec`/`scause`/`sret`, not IDT/LAPIC)
- HolyC: `kernel-spec/ZealOS/src/Compiler/{Lex,ParseStatement}.ZC`
- DolDoc: `kernel-spec/ZealOS/src/System/DolDoc/`
- Gr: `kernel-spec/ZealOS/src/System/Gr/`

**Rewrite:** x86 backend → RISC-V + SBI from BoardSpec; VGA → UART or virtio-gpu;
HolyC JIT → `g6b-holyc` (fast subset) + `g6b-asm` RISC-V ISel (not string
`.S`). Display path is the **display-proxy**: low-res ZealOS Gr plus HTML+JS
DOM painted by an OpenGL-ES2 adapter on HDMI/DP / host-GL. Specs:
`kernel-spec/goja`, `lirx-dom`, `webidl/` — never compiled. `Adam.ZC` /
`KMain.ZC` / `PostBoot.ZC` / `Browser.ZC` / `Tls.ZC` are **rust-generated**.

**Post-boot:** Adam may remain as a long-lived task (`postboot.enable=runtime|
mgmt-hart|bmc-island`). Two KVM faces share it: HTML+JS (ToHtml viewport) and
**SSH+HolyC** (ZealOS CLI / `SshHolyc` task). Immutable pages stay viewable.
After NIC delegate, both faces ride the mailbox (`/dev/g6lc-bios`), not eth/wifi.

**Refuse:** `/Apps`, oracle, Go goja runtime, Chromium, puppeteer/XTalk-to-host-browser,
compiling `kernel-spec/botan` or `libwasm`, linking OpenSSL, SvelteKit as BIOS UI,
emitting RVV when `extensions.v` is not `live`.
