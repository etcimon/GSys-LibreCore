# g6b-zealcli — VGA mouse-less ZealOS CLI

**Status:** landed. Green: `python tools/g6b.py check`. Crate
`g6b-zealcli` depends only on `g6b-holyc` + `g6b-spec` — **not**
`g6b-hw`, not browser-ui.

VGA, keyboard-only prompt (`>` from ZealOS `CmdLinePrompt`). Bash-shaped
commands (`ls`/`cd`/`cat`/`edit`) with ZealOS names (`Dir`/`Cd`/`Type`/`Ed`).
Help lists **every** HolyC builtin from `HOLYC_BUILTIN_NAMES` so the CLI
stays current when HolyC grows.

## Boot

`kernel.cli.enable` (default on). `kernel.cli.boot`:

| value | Face |
|---|---|
| `cli` | always VGA zealcli (embedded) |
| `ui` | skip CLI; browser-ui if compiled |
| `auto` | CLI until GPU probe+announce, then browser-ui (`LoadUI`) |

`BoardSpec::wants_zealcli(gpu_ready)` / `g6b_kernel::wants_zealcli`.
`LoadUI()` returns `Action::LoadUi` so the kernel can start browser-ui
and **disable** VGA+CLI.

## Not in this crate

Mouse / tablet / USB HID / USB-key listings live in **`g6b-hw`**
(`virtio-tablet`, `usb-hid`, `usb-key`, `HwPointer` / `HwUsbLs`).
The CLI never takes a pointer device.
