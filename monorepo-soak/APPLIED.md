# Applied / retired monorepo-soak patch scripts

These scripts **wrote RTL that now lives in `core/**` / TB**. They are removed
from the active tree to avoid re-applying non-idempotent edits. History remains
in git if needed.

| Script | Landed in |
|--------|-----------|
| `patch-amocas-q-rtl.py` | `ariane_pkg`, `decoder`, … |
| `patch-amocas-q-rtl2.py` | `cva6_hpdcache_if_adapter`, `miss_handler` |
| `patch-amocas-q-commit.py` | `commit_stage`, `issue_read_operands` |
| `patch-amocas-q-issue-stall.py` | `issue_read_operands` |
| `patch-amocas-q-raddr.py` | `issue_read_operands` |
| Hang-4 instr_queue PC | `frontend/instr_queue.sv` |
| Hang-7 younger cancel / CF stall | `scoreboard`, `issue_stage`, `branch_unit`, `frontend` |
| Dual-issue SS serialize (R3a cont.6/14/15/18) | `issue_read_operands.sv` (LSU/ALU/CF full younger block under `SuperscalarEn`) |
| `patch-raw-hart.py` / `patch-rf-whart.py` / `patch-dual-wfi-halt.py` | `raw_checker`, commit/issue, `g6lc_smt_csr_bank`, `cva6` |
| `patch-trap-dump-tb.py` | `corev_apu/tb/ariane_tb.cpp` |

**Do not re-run** experimental `patch-smt-*-boot*` force/kick scripts (see
`L2-OPENSBI-HANG-PROGRESS.md` reverts).

Promotion / open residuals: `architecture/multi-threading/soft-ladder/`.
