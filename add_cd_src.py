from pathlib import Path
p = Path('verif/tb/ai_island/run-cluster-dispatch.sh')
s = p.read_text()
anchor = '  "$AI_RTL/g6lc_ai_gemm_seq.sv" \\\n'
ins = '  "$AI_RTL/g6lc_ai_mul_seq.sv" \\\n  "$AI_RTL/g6lc_ai_gemm_arplan.sv" \\\n'
assert anchor in s, 'gemm_seq anchor not found'
s = s.replace(anchor, ins + anchor, 1)
p.write_text(s, newline='\n')
print('mul_seq + arplan added')
