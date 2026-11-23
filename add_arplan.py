from pathlib import Path
import glob
for f in sorted(glob.glob('verif/tb/ai_island/*.sh')):
    t = Path(f).read_text()
    if 'g6lc_ai_gemm_arplan' in t or 'g6lc_ai_mul_seq' not in t:
        continue
    old = '"$AI_RTL/g6lc_ai_mul_seq.sv" \\\n'
    new = old + '  "$AI_RTL/g6lc_ai_gemm_arplan.sv" \\\n'
    if old in t:
        Path(f).write_text(t.replace(old, new), newline='\n')
        print('added', f)
