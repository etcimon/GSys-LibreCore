# AGENTS Vendor — hdmi (HDMI 1.4b TMDS transmitter)

```yaml
# --- provenance (self-versioning header) ---
vendor_id:        hdmi
upstream_url:     https://github.com/hdl-util/hdmi.git
authored_ref:     <from vendor scan or catalog ref when fetched>
catalog_ref:      <from config.vendor.controllers[]>
mechanism:        submodule
domain:           display
kind:             controller
license:          MIT
status:           planned
scan_fingerprint: { files: <from vendor scan hdmi>, tops: [<from vendor scan>] }
authored_at:      <ISO date; update on creation>
last_refresh:     <ISO date; update on refresh>
refresh_trigger:  on-fetch
```

> **Scope:** per-vendor code-agent guide for `hdl-util/hdmi` (catalog id `hdmi`).
> This is the `AGENTS.md`-equivalent for the checked-out `vendor/hdl-util/hdmi` tree.
> It is a **planned skeleton** built only from catalog-known facts; scan-derived
> fields are explicitly marked `<from vendor scan>` and should be filled by
> `vendor scan hdmi` after the first `vendor sync hdmi`.

---

## 1. Identity

- **Controller:** hdl-util/hdmi — pure-SystemVerilog HDMI 1.4b TMDS transmitter.
- **Upstream:** `https://github.com/hdl-util/hdmi.git` (MIT).
- **Catalog entry:** `config.vendor.controllers` (`id: hdmi`), `path: vendor/hdl-util/hdmi`.
- **Status:** `planned` (catalogued, not fetched).
- **Domain outline:** `architecture/uncore/hdmi-display.md`.
- **One-line role:** Drive a local display by scanning a framebuffer out over TMDS.

---

## 2. Controller vs PHY split

- **On-die controller:** the TMDS encoder, serializer, and video-timing generator.
- **Board / analog PHY:** the HDMI connector plus ESD / level-shift / re-driver
  (e.g. TPD12S016, SN65DP159) and, for high pixel clocks, FPGA OSERDES / GT primitives.
- **PHY note from catalog:** TMDS encoder is on-die; board carries the HDMI connector and
  (often) an ESD/level-shift or re-driver.

This is the decisive boundary: the catalog entry vendors the digital controller only;
PHY and connector choices are target/board decisions.

---

## 3. Top-level interface map (from `vendor scan hdmi`)

- **Top module(s):** `<from vendor scan>`
- **Bus:** `<from vendor scan>` (expected: pixel/AXI-Stream style data + AXI-Lite config; update after scan)
- **Parameters:** `<from vendor scan>` (expected: video-mode / pixel-clock / color-depth knobs)
- **Clocks / resets:** `<from vendor scan>` (pixel-clock domain vs AXI domain; async-active-low reset)
- **Interrupts:** `<from vendor scan>` (if any; likely VBlank/line interrupt → PLIC)

---

## 4. Connectivity to CVA6

- **AXI seam:** a framebuffer in DRAM is read by a display DMA (AXI master, e.g. AXI-VDMA-style)
  and fed to the TMDS encoder; configuration via AXI-Lite. The encoder attaches into the
  `corev_apu` AXI fabric the same way existing low-speed peripherals do.
- **Wrapper plan:** `corev_apu/fpga/src/<board>_hdmi_wrapper.sv` (board-specific)
  plus constraints in `corev_apu/fpga/constraints/` (the `NEXYS_VIDEO` board already targets
  this class of output).
- **Cross-links:**
  - Domain outline: `architecture/uncore/hdmi-display.md`
  - Actives row: `AGENTS-core-platform-vendor-actives.md` §2.5 (`hdmi`)
  - SystemVerilog preconditions: `AGENTS-corev-apu.md` §3
  - Fetch/scan mechanism: `AGENTS-vendor.md`

---

## 5. Exploration map (navigate by intent)

| To find...                    | Open (within the checkout, after `vendor sync hdmi`) |
|-------------------------------|------------------------------------------------------|
| TMDS encoder / top module     | `<from vendor scan; root: src>`                      |
| Config / parameters           | `<from vendor scan>`                                 |
| Serializer / PHY boundary     | `<from vendor scan>`                                 |
| Video timing                  | `<from vendor scan>`                                 |
| Audio path (if used)          | `<from vendor scan>`                                 |
| Sim / tests                   | `<from vendor scan>`                                 |

---

## 6. Integration plan (promotion path)

Follow `AGENTS-vendor.md` §6 / `architecture/uncore/README.md`:

1. **Config-gate** — add a per-board config bit in `config_pkg` / board package.
2. **Fetch** — `vendor sync hdmi` (pin to a SHA before `vendored`).
3. **Scan** — `vendor scan hdmi`; fill this doc's §3 and §5.
4. **AXI wrapper** — write `corev_apu/fpga/src/<board>_hdmi_wrapper.sv`
   (framebuffer/AXI-VDMA ↔ TMDS, CDC between pixel-clock and AXI domains).
5. **Flist** — register relevant `vendor/hdl-util/hdmi/src/*` files.
6. **Verify** — video-timing checker + small pattern generator in `corev_apu/tb`.
7. **Observe** — optional VBlank PMU event; no ISA-visible RVFI impact unless a DMA
   error path is exposed.
8. **Document** — device-tree framebuffer node per `AGENTS-dts-validation.md`.

Preconditions checklist (`AGENTS-corev-apu.md` §3):
- [ ] async-active-low reset
- [ ] CDC between pixel-clock and AXI domain
- [ ] `tc_sram` for line buffers
- [ ] `tc_clk_gating` / DFT threading
- [ ] AXI types match `ariane_axi_pkg`
- [ ] PHY separation (board wrapper, not in the vendored source)
- [ ] flist registration
- [ ] DTS cross-validation

---

## 7. Verification & software hooks

- **TB entry:** video-timing checker + small pattern generator in `corev_apu/tb`
  (exact filename `<from vendor scan>`).
- **Device tree:** display / framebuffer node if exposed to Linux; cross-validate per
  `AGENTS-dts-validation.md`.
- **Software:** simple framebuffer console first; DRM/KMS is a larger effort and not
  required for initial bring-up.

---

## 8. Open questions / risks

- Pixel-clock source and exact video-mode parameters are board-dependent.
- High pixel clocks may require FPGA OSERDES primitives; ASIC needs a hardened SerDes.
- Audio path support is optional; if unused, document which modules to exclude.
- Framebuffer bandwidth depends on `litedram` / DDR4 integration.
- No claim about on-die PHY: HDMI connector and ESD/re-driver live on the board.

---

## 9. Refresh log (self-versioning history)

| date | ref | trigger | what changed |
|------|-----|---------|--------------|
| `<authored_at>` | `<authored_ref>` | on-fetch | Skeleton created from catalog facts; scan-derived sections left as `<from vendor scan>`. |
