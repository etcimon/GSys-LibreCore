# Extension point: `g6lc_bios`

**Status:** B0–B52 plus later guest/web/CLI stages live in `g6lc_bios/`.
Recovery program: `g6b-bootctl` / `g6b-runtime-abi` landed; native service
callee ELF is labelled `native-service-callee-not-bootable-firmware` and
QEMU-proved for `Capabilities`, in-frame `Poll`, and boot inhibit
(`NATIVE-SERVICE-OK`, `NATIVE-POLL-OK`, `NATIVE-BOOT-HOLD`). Journal-window
`BlkWrite`/`BlkFlush`/`JrnLoad`/`JrnCommit` landed in exec model (G6BH at
LBA 8). QEMU UART `Jrn` proved (`JRN-LOAD-OK`/`JRN-COMMIT-OK`). A/B
firmware flash/slot-select and live OpenWrt VM remain open.

Profiles `embedded`/`router` → `full` (UART+SPI flash
to browser-UI HTTPS + USB settings). USB FAT32 flash always compiled; USB-key
FileMgr extra. HolyC kernel file server emits generated HTML/JS/WASM over
HTTP(S) (`http.files`). 64-bit SMT2 / multi-issue / stream / OoO / H / RVV infer
setup menus; HolyC-UI ⊥ browser-UI. JS↔HolyC HTTP router; svelte-d UI (not
SvelteKit); Botan-spec TLS; adapter :443/:2222 until `NET-DELEGATE`. OpenSBI
ELF calls `TimerInit` before park; display-proxy geom is payload words.
`MboxInit` + `trap_mbox` service `/dev/g6lc-bios` doorbell kicks (not a netdev).
UART RX is PLIC irq 1 (`trap_uart`) into a line buffer; `ViewSection("name")`
prints `VIEW name`. Guest `G6UI` blob + `FileServe` / `GetFile` (`GET /ui/ui.wasm`).
Dual-band UART1 is irq-driven WFI.
`GrInit` publishes a `GR16` header, a 4bpp 640×480 plane (boot scanline), and an
8×8 `G6LC` blit after the hart stacks.
Independent package at
[`../../g6lc_bios/`](../../g6lc_bios/).

The BIOS **platform is a rewrite** of TempleOS/ZealOS, which live under
`g6lc_bios/kernel-spec/` as **specs** (Unlicense / public domain, not compiled).
Inferences from those specs are validated against LibreCore (OpenSBI M-mode,
BoardSpec, PLIC/UART map, PMA/PMP, no Variane evidence) — see package
`architecture/PLAN.md` §0–§3.

S-mode setup firmware. Display is in-kernel HTML+JS after generated HolyC
`KMain`; the other KVM face is SSH+HolyC. `g6b elf` emits `g6lc_bios.elf`.
QEMU: `g6q gen --emit bios-spec` then `g6q run --loader bios` with UART1
`-serial tcp:127.0.0.1:2222,server,nowait`. After Linux, the OS NIC is
delegated; `/dev/g6lc-bios` (mbox+PLIC) is the loopback. Never Variane evidence.

Package plan of record: `g6lc_bios/architecture/PLAN.md`. Guider:
`g6lc_bios/AGENTS.md`. Keep `g6lc_bios/AGENTS-todo.md` current.
