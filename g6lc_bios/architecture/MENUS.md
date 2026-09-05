# BIOS setup menus — one model, two UIs

BoardSpec is the only customisation IR. Setup screens are **inferred** from
ISA, hart topology, pipeline geometry, uncore, and boot parameters. HolyC-UI
and browser-UI are presentations of that tree. They do not each own a copy.

```
RTL / host JSON
    cores × threads × issue, H, V, OoO, stream, uncore
        │
        ▼
BoardSpec.infer_geo / infer_uncore / menus()
        │
        ├─ HolyC-UI   `g6b-ui` → HolycUi.ZC  MenuCpu / MenuSettingsPrint
        └─ browser-UI `g6b-ui` → browser-ui/*.svelte  fetch /bios/menu/*
                │
                ▼
         g6b-http::Router   (same JSON)
```

SvelteKit `+page` routing is refused. The browser does not print HolyC, and
the CLI does not paint DOM. Crate `g6b-ui` is the shared face list (menus +
USB/clocks utilities); both presenters consume it.

## Topology pulled from RTL-shaped JSON

| BoardSpec | RTL / host | Menu |
|---|---|---|
| `isa.xlen` 64 | `CVA6ConfigXlen` | Main |
| `harts.cores` × `harts.threads` | `NrCores` × `NrHarts` | CPU; SMT when threads>1 |
| `harts.count` | `cores × threads` | must match (inferred if omitted) |
| `core.issue_ports` | `NrIssuePorts` / `SuperscalarEn` | multi-issue |
| `core.ooo` | `OoOEn` / `SliceOoOEn` | out-of-order |
| `core.stream` | stream-plane SKU / `StreamEn` | stream vs SMT-shared |
| `extensions.h` | `RVH` / `CVA6ConfigHExtEn` | hypervisor (next-stage HS; BIOS stays S) |
| `extensions.v` | `RVV` | RVV ISel when live ∧ xlen=64 |

Adam runs on **hart 0**. Extra SMT/stream/multi-core harts `WFI` in `KStart`
until OpenSBI HSM / Linux starts them. The BIOS does not enter HS-mode.

## Uncore + standard interfaces

Inferred from `connectors.*`, peripherals, and display-proxy link, then shown
on the **Uncore** and **Devices** screens.

| Interface | Typical | HolyC connector |
|---|---|---|
| CLINT/ACLINT | 64-bit default | `ClintTime` |
| PLIC | 64-bit default | `PlicClaim` |
| UART ns16550 | APU | `UartPut` |
| SPI NOR | APU | `SpiRead` |
| SBI | core | `SbiPutchar` / SRST |
| PMU / OPP | core | `PmuRead` / `OppSet` |
| DDR | uncore `ddr4-controller.md` | `DramProbe` |
| PCIe RC | `pcie-root-complex.md` | `PciCfgRead` |
| Ethernet MAC | `ethernet-controller.md` | `EthStatus` (not a netdev after delegate) |
| SATA/NVMe/SD | `storage-controllers.md` | `BlkRead` |
| HDMI/DP | `hdmi-display.md` | `HdmiEdid` |
| USB FAT32 | always-on flash | `UsbFlash` |

These are **setup probes**, not Linux drivers. After `NET-DELEGATE` the same
JSON rides `/dev/g6lc-bios`.

## Endpoints (shared)

`GET /bios/menu` — index. `GET /bios/menu/{main,cpu,memory,uncore,devices,boot,settings}`.
Aliases `GET /bios/cpu` and `GET /bios/uncore`. HolyC `MenuCpu();` / `Menu("cpu");`
is `KernelGet` of the same path.

## Executable presentation contract (B51)

`g6b-ui::setup_html` supplies all seven menu panels, every BoardSpec item,
and its label, value and read-only status. It is shared by the kernel
viewport and `g6b-http::files`, not independently reconstructed in each.
Stable IDs are `menu-{id}`, `{id}-title`, `row-{menu}-{item}`,
`label-{menu}-{item}` and `access-{menu}-{item}`. Values are HTML-escaped;
menu JSON uses the shared Unicode-safe JSON quoting routine.

`BrowserSession::select_menu` hides other panels without destroying rows.
`kernel.browser.start_menu` selects the initial panel, default `main`.
A normal browser uses the same panels for click navigation and refreshes
through `/bios/menu/*`; no HolyC runtime global is required. Static HTML
still contains every row when scripting is off. The Settings menu also
reports UI backend, JS mode, initial menu, WASM/JIT configuration and the
shared task-service controls: enable, UI hart, task/worker limit and stack bytes.
`kernel.tasking` is opt-in (default disabled); it configures the host scheduler /
worker interface and ASM primitive contract, not an already-installed guest
scheduler. For example, add to the existing kernel object:

```json
"tasking": { "enable": true, "ui_hart": 0, "max_tasks": 128, "max_workers": 0, "stack_bytes": 32768 }
```

Worker limit zero selects the available non-UI harts (one on a singlehart
fallback), bounded by task capacity. Explicit worker limits reduce concurrency;
there is no oversubscription or saturation guarantee. Host tasking supports up
to 64 configured harts, 3–256 descriptors and 16-byte-aligned 4 KiB–1 MiB task
stacks. Both HolyC and browser rows derive these values from the same BoardSpec.

USB flash listings require `usb.enable && usb.flash_fat32`; FileMgr requires
`usb.enable && usb.key`; its filesystem panels follow the individual
filesystem flags. Clocks and USB-settings utilities use their own capability
gates. Generated sample Svelte fragments never override those gates.

All current `MenuItem.writable` values are false. These screens expose the
same **compiled configuration** as HolyC, not a second editable configuration
database. Flashing, persistent settings import/export and Linux hardware
ownership transfer are not made real by displaying buttons; the browser
therefore does not expose the router's historical canned mutation responses
as working operations. Host tests compare every row against HolyC output
across embedded/router/appliance/desktop/full profiles.

Fixtures: `g6lc64-smt2.json` (SMT2 dual-issue, H/V off as in `g6lc64_smt2_config_pkg`),
`g6lc64-server.json` (2×2 harts, issue 2, OoO, stream, H+V, full uncore),
`g6lc64-virt.json` (1×2 SMT, issue 2). Host: `g6q gen --emit bios-spec --target g6lc64_smt2`.
