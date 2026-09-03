# AGENTS Vendor — litedram (DDR3/DDR4/LPDDR4 controller + FPGA PHYs)

```yaml
# --- provenance (self-versioning header) ---
vendor_id:     litedram
upstream_url:  https://github.com/enjoy-digital/litedram.git
authored_ref:  3cf585a60a37113f18a9f6c6f3ee774be521623e
catalog_ref:   3cf585a60a37113f18a9f6c6f3ee774be521623e
mechanism:     submodule
domain:        memory
kind:          controller+phy
license:       BSD-2-Clause
status:        vendored
scan_fingerprint: { files: 0, tops: [] }  # Migen; no .sv/.v until gen.py
authored_at:   2026-09-01
last_refresh:  2026-09-01
refresh_trigger: on-fetch
```

**Vendored, not integrated.** `vendor scan litedram` of `.sv/.v` is empty (Python/Migen).
Do not treat QEMU or this checkout as Variane cookie evidence.

## 1. Identity

LiteDRAM @ `3cf585a` (`2026.04` setup.py). Generator: `litedram/gen.py`.
Live testharness YAML uses a **native** user port (not the AXI frontend).
Sim PHY: `litedram/phy/model.py` (`LiteDRAMCoreSimPHY` when `gen.py --sim`).

## 2. Controller vs PHY split

- **On-die:** bank machines, refresher, AXI/Wishbone/native (`litedram/core`, `frontend`).
- **Testharness:** `gen.py --sim` → `SDRAMPHYModel` (no FPGA pins).
- **FPGA:** `USDDRPHY` / `K7DDRPHY` / `ECP5DDRPHY` — hard PHY, not this wrap.
- **ASIC:** licensed DDR PHY hard macro (`AGENTS-technology.md`).

## 3. Top-level interface map (from gen.py, pin 3cf585a)

- Generated top: `--name litedram_core` (default)
- Native user port `user_port_native_0_*` (YAML `native_0`):
  cmd valid/ready/we/addr[25:0]; wdata valid/ready/data[255:0]/we[31:0];
  rdata valid/ready/data[255:0]. No ID; wrap holds AXI IDs.
- Clk/rst: `clk`, `init_done`, `init_error`, `user_clk`, `user_rst`
- YAML `block_until_ready: false` so the native port is not gated on the
  init_done CSR (`cpu: None` — no core to write it). Wrap `ForceInitDone`.

## 4. Connectivity to CVA6

- AXI seam: `g6lc_ai_litedram_wrap` ← `g6lc_ai_dram_backend` class 1
- Live testharness **DramClass=0** (SRAM); do not flip to `AiIslandDdr4Bringup`
  until `G6LC_HAVE_LITEDRAM` and generated `litedram_core` exist
- Cross-links: `architecture/uncore/ddr4-controller.md` ·
  `architecture/uncore/litedram-testharness.yml` · `AGENTS-corev-apu.md` §3

## 5. Exploration map

| To find... | Open |
|---|---|
| generator | `litedram/gen.py` (`--sim`, `--name`) |
| testharness YAML | `architecture/uncore/litedram-testharness.yml` |
| Native port | `litedram/common.py` `LiteDRAMNativePort` |
| sim PHY | `litedram/phy/model.py` |
| G6LC wrap | `corev_apu/src/g6lc_ai_litedram_wrap.sv` |

## 6. Integration plan

1. ~~`vendor sync litedram`~~ **done** @ 3cf585a.
2. ~~`gen.py --sim`~~ **done** → `generated/gateware/litedram_core.v` (re-run `run-litedram-gen.sh`).
3. Opt-in elaborate: `defines=G6LC_HAVE_LITEDRAM+G6LC_AI_DRAM_CLASS1` (not default).
4. Live testharness remains DramClass=0 until that library is the HARD bar.
5. Directed `--sim` 256-beat stream **7858 milli-GB/s (98% of 8 GB/s fabric)** —
   80% gate **closed**. LiteDRAM rdata is a delayed pulse (no backpressure). Not 19 GB/s
   nameplate, not 400. **Do not start I2.**
6. Native wrap **PASS** `tb_g6lc_ai_litedram_wrap` id6 **1445 cy** (eight AR + eight AW live / 9th backpressure, mixed AW+AR, L1 16 B, WRAP **SLVERR**). Wrap **NrArSlots/NrAwSlots=8**; AXI held until `init_done` (`ForceInitDone=1` in `--sim`). 4 AXI beats pack into one 256-bit native word. Class-1 PHY N=1/2/4/8 **PASS 375/416/448/453 cy**. Island GEMM vs class-1 N=1/2/4/8 LiteDRAM **PASS** `tb_g6lc_ai_gemm_channels` **336/681/821/1162 cy** (MaxAROut=8), golden C=16, CAP match.

Preconditions: [x] generate [x] flist (Makefile `src` + `litedram_core.v` on CLASS1/CHANS_*)
[x] PHY separation (`--sim` vs FPGA) [x] native map
[x] CDC (sim is one clock) [x] DTS (one `memory@`; CAP 0x38 count+shift; live class 0 N=1)
[ ] DFT

## 7. Verification

- Island DMA page delay: `tb_g6lc_ai_dram_timing` (28/14/42) — not LiteDRAM.
- Variane class 1: wrap smoke **PASS** 1445 cy; proxy flavours `ai-dt`/`ai-d1` exist. Doctor lists them. `build ai-dt` **linked** 38 Mi (jobs=1 `-O0`); `test --ai-remote` **PASS** 2681 cy tohost=1. `ai-d1` still opt-in. Not 400.
- Linux: generic `memory@` node.

## 8. Open questions / risks

- Host image has no Migen/LiteX (`python3-venv` missing); generate not run here.
- `vendor scan` of RTL extensions is empty until generate — expected.
- Generated Verilog is sim-PHY; FPGA USDDRPHY is a different generate.

## 9. Refresh log

| date | ref | trigger | what changed |
|---|---|---|---|
| 2026-09-01 | 3cf585a | on-fetch | submodule add; AXI map from gen.py; wrap landed |
| 2026-09-01 | 3cf585a | on-integrate | `--sim` generated `litedram_core.v`; wrap ports match (no rst, 31-bit addr, wb_ctrl idle) |
| 2026-09-01 | 3cf585a | gemm n4 cap | GEMM vs class-1 N=2/N=4 LiteDRAM **500 cy** golden C=16; CAP `0x50`/`0x70` matches slave occupancy |
| 2026-09-01 | 3cf585a | gemm wide | GEMM class-0 N=2/4/8 **356/405/503 cy** + class-1 N=2/4/8 **976/1085/1323 cy**; wide `lda=64` all-NCH occupancy |
| 2026-09-01 | 3cf585a | dram-bw | `--sim` stream **2048 beats / 9179 cy = 1784 milli-GB/s (22% of fabric)**; 80% gate open |
| 2026-09-01 | 3cf585a | native-gen | Migen+LiteX generate self-host; native user port **proven** (256-bit, cmd_addr[25:0]); bursting wrap not drop-in (two-ID AXI smoke); live generate restored to AXI |
| 2026-09-01 | 3cf585a | native-wrap | AXI→native gearbox **PASS** id6 235 cy; 64-beat `--sim` **512/534 cy = 7670 milli-GB/s (95%)**; 80% gate **closed**. YAML `native_0` live. |
| 2026-09-02 | 3cf585a | rdata-ready | Native rdata is a delayed pulse (crossbar ignores ready). Wrap always accepts; issue while FIFO+inflight fit. 256-beat **2048/2085 cy = 7858 milli-GB/s (98%)**. GEMM N=2/4/8 **913/1064/1408 cy**. |
| 2026-09-02 | 3cf585a | gemm n1 | Class-1 GEMM N=1 identity **420 cy** ch0-only golden C=16; run script n1+n2+n4+n8. |
| 2026-09-02 | 3cf585a | phy n1 | Class-1 PHY `tb_g6lc_ai_dram_channels` N=1/2/4/8 **375/416/448/453 cy**; N=1 two IDs on one wrap (cluster+island). |
| 2026-09-02 | 3cf585a | backend class1 | Testharness CLASS1 slave: `dram_backend` DramClass=1 GEMM N=1/2 **420/913 cy** golden C=16. |
| 2026-09-02 | 3cf585a | verilate flags | Catalog/README native_0. `ai-matrix-veri` CHANS_2/8 → work-ver-ai-d{2,8}. Makefile already appends `litedram_core.v` + HAVE_LITEDRAM. |
| 2026-09-02 | 3cf585a | backend n4 | Testharness CHANS_4 slave: `dram_backend` DramClass=1 GEMM N=4 **1064 cy**. Vendor guide native_0 (was AXI). |
| 2026-09-02 | 3cf585a | dts-cap | CAP `0x38` matches live DTS 1 ch / shift 6; N=2 bringup packs 2/6. One `memory@`. |
| 2026-09-02 | 3cf585a | nameplate | `island_cfg_legal` refuses 400 on class 0/DDR4, NoC 8 on DDR4/LPDDR5, N=3, shift 2. |
| 2026-09-02 | 3cf585a | wrap size | AXI INCR size 0–3 + FIXED len=0 (WT byte/half/word). Wrap smoke **371 cy**. |
| 2026-09-02 | 3cf585a | wrap merge | ST.B after SD merges via native we (**A511** then **2211**). Two-ID byte stores. Wrap **504 cy**. |
| 2026-09-02 | 3cf585a | wrap slverr | Multi-beat WRAP/FIXED handshake then SLVERR (no `aw_ready` stall, no native). ST.H +2 merge **3344_2211**. Single-beat WRAP legal. Wrap **629 cy**. |
| 2026-09-02 | 3cf585a | backend n8 | Testharness CLASS1 `dram_backend` N=8 GEMM **1408 cy** golden C=16 (matches channels). |
| 2026-09-02 | 3cf585a | wrap l1 | L1 16 B INCR (aligned + sl=2), 32 B native straddle, ST.W +4, NC AR size 0/1/2, AR-while-B. Wrap **915 cy**. |
| 2026-09-02 | 3cf585a | wrap dual-ar | Two outstanding AR (single-beat + 16 B I$+D$). Wrap **1009 cy**. |
| 2026-09-02 | 3cf585a | wrap l2-mshr | Two 64 B AR, mixed AW+AR two IDs, 3rd AR backpressure. Wrap **1209 cy**. |
