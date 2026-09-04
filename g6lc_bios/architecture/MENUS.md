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

Fixtures: `g6lc64-smt2.json` (SMT2 dual-issue, H/V off as in `g6lc64_smt2_config_pkg`),
`g6lc64-server.json` (2×2 harts, issue 2, OoO, stream, H+V, full uncore),
`g6lc64-virt.json` (1×2 SMT, issue 2). Host: `g6q gen --emit bios-spec --target g6lc64_smt2`.
