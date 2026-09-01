# linux-dist — OpenWrt and Ubuntu fitted to LibreCore RTL

First-party **MIT** layout. Distro sources are **separate works** (OpenWrt GPL,
Ubuntu Canonical). Nothing here is linked into `g6lc_qemu/crates/**`
(`E-GPLLINK`).

## Two paths (do not mix)

| Path | What | Used at compile? |
|---|---|---|
| `linux-dist/openwrt/` and `linux-dist/openwrt-*` | **Development** checkouts of [etcimon forks](https://github.com/etcimon/openwrt) | **No** |
| official `github.com/openwrt/openwrt` @ `pins.toml` + [`../openwrt/patches/`](../openwrt/patches/) | **Compile** for QEMU / testharness | **Yes** |

Develop on the forks → `bash ../openwrt/extract-patches.sh` → patches land in
`g6lc_qemu/openwrt/patches/` → `build.sh` / remote apply those patches onto a
fresh **official** clone. QEMU never builds the fork.

Feed folders use the `openwrt-` prefix so they stay distinct from Ubuntu (or
any later distro) sitting alongside:

| Slot | Role | Dev submodule (etcimon) | Official compile pin |
|---|---|---|---|
| `openwrt/` | OpenWrt core | [etcimon/openwrt](https://github.com/etcimon/openwrt) `37fc534` (`openwrt-24.10`) | [openwrt/openwrt](https://github.com/openwrt/openwrt) `v24.10.2` |
| `openwrt-packages/` | packages feed | [etcimon/openwrt-packages](https://github.com/etcimon/openwrt-packages) | [openwrt/packages](https://github.com/openwrt/packages) |
| `openwrt-luci/` | LuCI feed | [etcimon/openwrt-luci](https://github.com/etcimon/openwrt-luci) | [openwrt/luci](https://github.com/openwrt/luci) |
| `openwrt-routing/` | routing feed | [etcimon/openwrt-routing](https://github.com/etcimon/openwrt-routing) | [openwrt/routing](https://github.com/openwrt/routing) |
| `openwrt-telephony/` | telephony feed | [etcimon/openwrt-telephony](https://github.com/etcimon/openwrt-telephony) | [openwrt/telephony](https://github.com/openwrt/telephony) |
| `ubuntu/` | Ubuntu RISC-V scaffold | (none yet) | `ubuntu/pins.toml` |
| `edk2/` | EDK2 development fork | [etcimon/edk2](https://github.com/etcimon/edk2) | [tianocore/edk2](https://github.com/tianocore/edk2) `edk2-stable202511` + `g6lc_qemu/patches/edk2-*.patch` |

OpenWrt itself has no git submodules; the four `src-git` feeds are those
`openwrt-*` siblings.

## RTL ISA

See [`isa/`](isa/). Tokens come from `g6lc64_smt2_config_pkg` +
`ariane-smt2.dts`, not from QEMU. Shared by OpenWrt patches and the Ubuntu
scaffold.

## Commands

```bash
# optional: get etcimon forks for development
bash g6lc_qemu/linux-dist/init-submodules.sh

# after committing customizations on a fork:
bash g6lc_qemu/openwrt/extract-patches.sh

# compile (official tree + patches; no fork):
OPENWRT_SRC=/path/to/official/openwrt bash g6lc_qemu/openwrt/build.sh
```
