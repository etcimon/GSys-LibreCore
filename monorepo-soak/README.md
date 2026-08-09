# monorepo-soak (trimmed)

Lab **notes + rebuild helpers** only. Applied patch generators were **deleted**
after their intent landed in `core/**` / TB — see **`APPLIED.md`**.

## Integration

- Map: `architecture/multi-threading/soft-ladder/monorepo-soak-integration.md`
- Soft-ladder: `architecture/multi-threading/soft-ladder/`
- Dual-issue SS serialize: `core/issue_read_operands.sv` (cont.6/14/15/18)

## Keep

| Path | Role |
|------|------|
| `L2-OPENSBI-HANG-PROGRESS.md` | Hang-1…7 narrative |
| `APPLIED.md` | Retired script → RTL file map |
| `analyze-hang7-*.py` | Offline log analysis (optional) |
| `rebuild-*.sh` / `run-hang*.sh` / `debug-*.sh` | Lab rebuild/run helpers |
| Result markdowns | Historical conclusions |

## Rules

1. **Do not re-introduce** applied `patch-*.py` without a new residual.
2. New durable RTL → `core/**` only; update soft-ladder inventory.
3. Soft OpenSBI peels → `tmp-dual-ci/mk_plat_skip.py` (production pair only).
