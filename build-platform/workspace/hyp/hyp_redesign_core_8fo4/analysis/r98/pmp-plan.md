# PMP implementation decision

This is the archived implementation plan. The completed implementation,
raw-address-domain refinement, evidence and open qualification limits are
recorded in `design.md` and `worklog.md`; those records supersede pending
actions and intermediate figures below.

Target is the Hyp `core/csr_regfile.sv`, not production RTL. Before source
is `pmp-scalar-v50.before.sv`; matched before maximum is59.467970 FO4,
using the explicitly bound eight-entry RV64 caller. The only synthesized
change is the bank between `csr_wr_pmp` and `csr_wr_acc`. Keep all64
intermediate rows because the existing assertions compare pre-WARL state.

Replace that bank with the following exact shape. The odd-config case
preserves four-state case matching; a prefix-bit shortcut would not.

```systemverilog
  always_comb begin : csr_wr_pmp
    bk_wr_pmp_uae = 1'b0;
    bk_wr_pmp_vuae = 1'b0;
    bk_wr_pmp_flush = 1'b0;
    bk_wr_pmp_dfsc = 1'b0;
    if (csr_we && G6LCCfg.IS_XLEN64) begin
      case (conv_csr_addr.address)
        riscv::CSR_PMPCFG1, riscv::CSR_PMPCFG3,
        riscv::CSR_PMPCFG5, riscv::CSR_PMPCFG7,
        riscv::CSR_PMPCFG9, riscv::CSR_PMPCFG11,
        riscv::CSR_PMPCFG13, riscv::CSR_PMPCFG15:
          bk_wr_pmp_uae = 1'b1;
        default: ;
      endcase
    end
  end
  for (genvar p = 0; p < 64; p++) begin : gen_pmp_write
    localparam logic [11:0] CFG_ADDR = 12'(riscv::CSR_PMPCFG0) +
        12'((p / (G6LCCfg.XLEN / 8)) * (G6LCCfg.XLEN / 32));
    localparam logic [11:0] ADDR_ADDR = 12'(riscv::CSR_PMPADDR0) + 12'(p);
    localparam int unsigned BYTE = p % (G6LCCfg.XLEN / 8);
    logic next_tor_locked;
    if (p < 63) begin : gen_neighbor
      assign next_tor_locked = pmpcfg_q[p+1].locked &&
                              pmpcfg_q[p+1].addr_mode == riscv::TOR;
    end else begin : gen_last
      assign next_tor_locked = 1'b0;
    end
    always_comb begin
      pmpcfg_w[p] = pmpcfg_q[p];
      pmpaddr_w[p] = pmpaddr_q[p];
      if (csr_we) begin
        if (conv_csr_addr.address == CFG_ADDR && !pmpcfg_q[p].locked)
          pmpcfg_w[p] = csr_wdata[BYTE*8+:8];
        if (conv_csr_addr.address == ADDR_ADDR &&
            !pmpcfg_q[p].locked && !next_tor_locked)
          pmpaddr_w[p] = csr_wdata[G6LCCfg.PLEN-3:0];
      end
    end
  end
```

Architectural boundary repair: entry63 has no TOR neighbor. The old dynamic
index reads64, which is undefined in four-state simulation. In the retained
`csr_update_ref` block, prepend `pmp_index < 12'd63 &&` INSIDE the existing
parenthesized neighbor-lock term. This is a bounded architectural correction,
not evidence of a current boot symptom. The same one-line correction goes
into the old-bank comparison fixture; preserve raw before source separately.
Do not change CSR apply/request ownership, reset, readonly/WARL or other banks.
Prove bytes outside the bank and this single reference predicate unchanged.

Focused verification uses the actual bank source, extracted verbatim into
private wrappers; it does not claim full CSR-seam or boot qualification.
Use RV32/PLEN34 and RV64/PLEN56, all64 intermediate rows. Wrapper has:

```systemverilog
// ports: csr_we, addr[11:0], csr_wdata[XLEN-1:0],
// pmpcfg_q[63:0] (riscv::pmpcfg_t), pmpaddr_q[63:0][PLEN-3:0],
// pmpcfg_w, pmpaddr_w, and all four bk_wr_pmp_* flags.
typedef struct packed {
  int unsigned XLEN;
  int unsigned PLEN;
  bit IS_XLEN64;
} cfg_t;
localparam cfg_t G6LCCfg =
    '{XLEN: XLEN, PLEN: PLEN, IS_XLEN64: (XLEN == 64)};
typedef struct packed {logic [11:0] address;} addr_t;
addr_t csr_addr, conv_csr_addr;
assign csr_addr.address = addr;
assign conv_csr_addr.address = addr;
// verbatim extracted bank follows
```

Use real `riscv_pkg.sv` enums/types. Extraction asserts unique start/end
markers and records input hashes and exact extracted byte ranges/hashes.
Baseline wrapper gets only the explicit last-neighbor guard correction.
Candidate and reference wrappers otherwise carry source verbatim; no helper
replacement or handwritten reimplementation of the candidate.

Append test top/cases to existing `tb_g6lc_hyp8_control.sv`. Compare both
complete output arrays and flags. Sweep all4096 CSR addresses at csr_we0/1
under three q-state patterns: unlocked; alternating locks with TOR/NAPOT;
varying byte/control patterns and locked TOR neighbors. Explicit checks:
no-write holds; odd PMPCFG traps only RV64; each config byte reaches correct
row; own lock blocks; locked TOR neighbor blocks; locked non-TOR neighbor
does not; index62 sees63; unlocked63 writes; non-PMP addresses hold. Data
must differ per byte, and address data must exercise top and low PLEN bits.
One separate negative reference mutation must fail, proving array comparison
is live. Keep width/latch/multidriver diagnostics enabled.

Readonly/unimplemented-entry clamping, WARL, RMW computation and owner/apply
rules are outside this pure combinational bank; inspect their unchanged
source and use the final isolated full-top elaboration as an integration
check. Do not claim the slice test exercises those complete protocols.
The existing complete CSR bench has unrelated geometry/stimulus issues;
do not silently disable its checks or call it passing.
