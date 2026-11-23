from pathlib import Path
import os
out = Path(os.environ['TH_OUT_DIR'])
src = Path('/opt/testharness/runs/hyp8-h33-stq-diag-r1/run-hyp8.log')
lines = src.read_text(errors='replace').splitlines()
stq = [l for l in lines if '[stq]' in l]
ldst = [l for l in lines if '[ldst]' in l]
smt = [l for l in lines if 'smt-flow' in l]
lsq = [l for l in lines if '[lsq]' in l or '[lsq-' in l]
wt = [l for l in lines if '[wt' in l]
disp = [l for l in lines if '[disp]' in l]
(out / 'stq.txt').write_text('\n'.join(stq))
(out / 'ldst.txt').write_text('\n'.join(ldst))
(out / 'smtflow.txt').write_text('\n'.join(smt))
(out / 'lsq.txt').write_text('\n'.join(lsq))
(out / 'wt.txt').write_text('\n'.join(wt))
(out / 'disp.txt').write_text('\n'.join(disp))
(out / 'tail.txt').write_text('\n'.join(lines[-40:]))
print(f'collected stq={len(stq)} ldst={len(ldst)} smt={len(smt)} lsq={len(lsq)} wt={len(wt)} disp={len(disp)}')
