# AI-matrix Variane helpers

Scratch and debug scripts for the Xg6lcai directed suite
(`verif/regress/ai-matrix-veri.sh`). Not part of CI; keep experiment
drivers here instead of the repo root.

| Script | Purpose |
|--------|---------|
| `run-smoke.sh` | Rebuild (optional) + run a named subset of AI ELFs |
| `run-irq-claim-bisect.sh` | Bisect PLIC claim-0 vs completion DMA write |
| `experiments/_tmp_*.sh` | Frozen claim-dig transcripts (not for CI) |

Normative suite entry point remains:

```bash
bash verif/regress/ai-matrix-veri.sh
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" \
  bash verif/regress/ai-matrix-veri.sh
```
