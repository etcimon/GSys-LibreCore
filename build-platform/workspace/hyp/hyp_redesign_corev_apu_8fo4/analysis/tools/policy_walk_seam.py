from pathlib import Path
import re
dma = Path('verif/tb/ai_island/run-ai-island-dma.sh').read_text()
pw  = Path('verif/tb/ai_island/run-ai-island-policy-walk.sh')
s = pw.read_text()

seam = re.search(r'AI_RTL=.*?AI_CVXIF=.*?\n', dma, re.S).group(0)
anchor = 'cd "$ROOT"\n'
assert anchor in s
s = s.replace(anchor, anchor + '\n' + seam, 1)

start = s.find('  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv"')
end   = s.find('"$ROOT/verif/tb/ai_island/tb_g6lc_ai_island_dma.sv"')
assert start > 0 and end > start, (start, end)
newsrc = '''  "$AI_INC/g6lc_ai_island_cfg_pkg.sv" \\
  "$AI_RTL/include/g6lc_ai_desc_pkg.sv" \\
  "$AI_RTL/include/g6lc_ai_fp_pkg.sv" \\
  "$AI_RTL/include/g6lc_ai_policy_pkg.sv" \\
  "$AI_RTL/g6lc_ai_addr_check.sv" \\
  "$AI_RTL/g6lc_ai_cap_window.sv" \\
  "$AI_RTL/g6lc_ai_desc_engine.sv" \\
  "$AI_RTL/g6lc_ai_desc_fetch.sv" \\
  "$AI_RTL/g6lc_ai_mem_store.sv" \\
  "$AI_RTL/g6lc_ai_tile_sram.sv" \\
  "$AI_RTL/g6lc_ai_pe_dot.sv" \\
  "$AI_RTL/g6lc_ai_pe_dot_pipe.sv" \\
  "$AI_RTL/g6lc_ai_pe_dot_float.sv" \\
  "$AI_RTL/g6lc_ai_pe_dot_float_pipe.sv" \\
  "$AI_RTL/g6lc_ai_policy_codec.sv" \\
  "$AI_RTL/g6lc_ai_policy_subcode.sv" \\
  "$AI_RTL/g6lc_ai_policy_steer.sv" \\
  "$AI_RTL/g6lc_ai_gemm_seq.sv" \\
  "$AI_RTL/g6lc_ai_mul_seq.sv" \\
  "$AI_RTL/g6lc_ai_dram_timing.sv" \\
  "$AI_RTL/g6lc_ai_cpl_fifo.sv" \\
  "$AI_RTL/g6lc_ai_axi_cut.sv" \\
  "$AI_RTL/g6lc_ai_cmd_fifo.sv" \\
  "$AI_RTL/g6lc_ai_inval_queue.sv" \\
  "$AI_RTL/g6lc_ai_cluster_dispatch.sv" \\
  "$AI_RTL/g6lc_ai_island_top.sv" \\
  '''
s = s[:start] + newsrc + s[end:]

if '-I"$AI_INC"' not in s:
    s = s.replace(
        '-Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \\',
        '-Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \\\n  -I"$AI_INC" \\\n  -I"$AI_RTL/include" \\',
        1)
pw.write_text(s, newline='\n')
print('policy-walk seam applied')
