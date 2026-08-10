#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6
COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness

python3 - <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  beqz t0, fail_ip0

  # Claim ? ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
new = """  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  beqz t0, fail_ip0

  # Sample mip.MEIP (bit 11) and claim
  csrr s1, mip
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
fail_old = """fail_cl:
  # encode claimed id: a0 = ((id+20)<<1)|1
  addi a0, t0, 20
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
"""
fail_new = """fail_cl:
  # a0>>1 report: claim in [7:0], meip in bit8
  andi a0, t0, 0xff
  srli t1, s1, 11
  andi t1, t1, 1
  slli t1, t1, 8
  or   a0, a0, t1
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
"""
Path("/tmp/ai_irq_mip.S").write_text(src.replace(old,new).replace(fail_old,fail_new))
print("ok")
PY
$CC -o work-ver-ai/ai_elfs/ai_irq_mip.elf /tmp/ai_irq_mip.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_mip.elf | awk '$3=="tohost"{print $1; exit}')
echo tohost=$th
$H +time_out=200000 +debug_disable +tohost_addr=0x$th work-ver-ai/ai_elfs/ai_irq_mip.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Also: skip completion write by engine change: if ptr_done==0 skip WR_DONE
# First test with IRQ using ptr_done=0 AFTER fixing engine to allow null ptr_done
python3 - <<'PY'
from pathlib import Path
# engine: skip check/write when ptr_done==0
p = Path("corev_apu/ai_island/g6lc_ai_desc_engine.sv")
t = p.read_text()
old = """      ST_CHK_DONE: begin
        // Completion word must be writable
        check_req_o    = 1'b1;
        check_addr_o   = desc_q.ptr_done;
        check_need_w_o = 1'b1;
        if (!check_ok_i) begin
          status_d = ST_BAD_PTR;
          state_d  = ST_COMPLETE;
        end else begin
          // P3 spine: accept without executing GEMM; write completion word
          status_d = ST_OK;
          irq_d    = desc_irq(desc_q);
          if (WriteCompletion) state_d = ST_WR_DONE;
          else state_d = ST_COMPLETE;
        end
      end
"""
new = """      ST_CHK_DONE: begin
        // Null ptr_done: no completion word (still OK + optional IRQ)
        if (desc_q.ptr_done == '0) begin
          status_d = ST_OK;
          irq_d    = desc_irq(desc_q);
          state_d  = ST_COMPLETE;
        end else begin
          // Completion word must be writable
          check_req_o    = 1'b1;
          check_addr_o   = desc_q.ptr_done;
          check_need_w_o = 1'b1;
          if (!check_ok_i) begin
            status_d = ST_BAD_PTR;
            state_d  = ST_COMPLETE;
          end else begin
            // P3 spine: accept without executing GEMM; write completion word
            status_d = ST_OK;
            irq_d    = desc_irq(desc_q);
            if (WriteCompletion) state_d = ST_WR_DONE;
            else state_d = ST_COMPLETE;
          end
        end
      end
"""
if old not in t:
    raise SystemExit("engine pattern missing")
p.write_text(t.replace(old,new))
print("engine patched for null ptr_done")
PY
