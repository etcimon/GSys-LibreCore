# sv-timing

**Standalone** SystemVerilog timing IR package: parse → timing-oriented intermediate form →
path/cost reports → optional auto-correct. Structural FO4 estimates only — **not** STA sign-off.

| Doc | Purpose |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Agent guider (start here for contributors/agents) |
| [`AGENTS-todo.md`](AGENTS-todo.md) | Live implementation state |
| [`architecture/DESIGN.md`](architecture/DESIGN.md) | Full architecture |
| [`AGENTS-toolchain.md`](AGENTS-toolchain.md) | Contained rustup/cargo + venv |

## Correctness and production use

Current `ir-v1` / `delay-v2` evidence separates source recovery, structural measurement,
projected algorithm feasibility, emitted-SV validity and technology-mapped STA. A clean
parse or a high cleanliness score is not a timing/equivalence proof. Emitted packages
with incomplete re-analysis fail validation rather than inheriting the IR's closure.
See [`architecture/DESIGN.md`](architecture/DESIGN.md) and the current audit in
[`AGENTS-todo.md`](AGENTS-todo.md).

The host flag is `build-platform timings ... --from-timing <package>` (singular).
OpenSTA report parsing is checked against reference output; real setup/hold closure
still needs Liberty, reviewed clock/I/O constraints and a mapped netlist. QEMU can check
software/device contracts, not the corrected SV or a 4 GHz clock.

## Quick start (Python-first)

Host needs **Python 3.9+** and **git**. Rust is installed **into `.tools/`** automatically.

```bash
cd sv-timing
python tools/svt.py setup          # rustup+cargo+venv+vendor sv-parser
python tools/svt.py doctor
python tools/svt.py build
python tools/svt.py test
python tools/svt.py run -- status
python tools/svt.py run -- analyze --files-from fixtures/filelist.txt --modules comb_adder_cloud
# With IR cache (second run skips parse when CRCs match):
python tools/svt.py run -- analyze --files-from fixtures/filelist.txt --modules comb_adder_cloud \
  --cache .sv-timing-cache/ir.sqlite
```

Windows:

```powershell
cd sv-timing
py -3 tools/svt.py setup
py -3 tools/svt.py doctor
```

Optional thin wrappers: `./svt.sh …` / `.\svt.ps1 …` (they only call `tools/svt.py`).

## TypeScript client (`js/`)

Bun + **TypeScript** package `@sv-timing/js` for AST/debug/auto-correct connection tests:

```bash
python tools/svt.py build
python tools/svt.py js-test
# or: cd js && bun install && bun test && bun run typecheck
```

See `js/README.md`, `AGENTS-js.md`, `architecture/JS-TYPESCRIPT.md`.

## Verif regress (Python + pyslang)

Heavy-timing `.sv` fixtures → analyze (startpoint/endpoint closure) → correct emit → **pyslang** lint:

```bash
python tools/svt.py verif-regress
```

See `verif/README.md`, `architecture/FREQUENCY-CLOSURE.md`.

## Independence

This package does **not** depend on CVA6, build-platform, or monorepo flists. Hosts pass file lists
via CLI. See `AGENTS-host.md`.

## License

- First-party: MIT (Etienne Cimon) when under monorepo policy.
- Vendored `crates/sv-parser`: MIT OR Apache-2.0 (upstream).
