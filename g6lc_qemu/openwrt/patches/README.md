# OpenWrt patches — applied to the **official** tree at compile time

Compile never uses `github.com/etcimon/openwrt` (or the feed forks). Those
checkouts live under `g6lc_qemu/linux-dist/openwrt-*` for development only.

```
develop on linux-dist/openwrt-* (etcimon forks)
        │
        ▼
extract-patches.sh     →  this directory (series + 000*.patch + from-fork/)
        │
        ▼
apply-patches.sh       →  official openwrt/openwrt @ pins.toml ref
        │
        ▼
build.sh / remote      →  Image  (QEMU / testharness)
```

`series` is the order. `files/diffconfig` is copied to OpenWrt `.config`
(not a git diff). `from-fork/` is filled by `extract-patches.sh` when the
fork has commits the seed patches do not already cover.
