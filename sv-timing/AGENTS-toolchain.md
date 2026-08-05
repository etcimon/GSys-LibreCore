# AGENTS-toolchain — Contained rustup, cargo, and Python venv

> Companion to [`AGENTS.md`](AGENTS.md). **Default automation language: Python 3.**

## Goals

1. A clean machine can build `sv-timing` after one command without polluting global toolchains.
2. **rustup** + **cargo** install into package-local `.tools/` via official installers.
3. **Python venv** at `.tools/python-venv` holds tooling deps from `requirements.txt`.
4. All orchestration is in **`tools/svt.py`**; `svt.sh` / `svt.ps1` only locate Python and exec it.

## Layout (gitignored)

```
.tools/
  rustup/          # RUSTUP_HOME
  cargo/           # CARGO_HOME  (bin/cargo, bin/rustc, bin/rustup)
  python-venv/     # package venv
```

Environment variables set by `svt.py` for child processes:

| Variable | Value |
|---|---|
| `SV_TIMING_ROOT` | Absolute path to package root |
| `RUSTUP_HOME` | `$ROOT/.tools/rustup` |
| `CARGO_HOME` | `$ROOT/.tools/cargo` |
| `PATH` | `$CARGO_HOME/bin` prepended |

## Commands (`python tools/svt.py <cmd>`)

| Command | Action |
|---|---|
| `setup` | Install rustup (if needed), install toolchain from `rust-toolchain.toml`, create venv, pip install, vendor parser if missing |
| `doctor` | Print readiness |
| `vendor-sv-parser` | Run `refresh_sv_parser.py` |
| `build` / `test` / `check` | cargo (+ independence on check) |
| `run -- …` | `cargo run -p sv-timing-cli -- …` |
| `flist --in … --out …` | Expand nested/env filelist → portable `.f` (`tools/flist_expand.py`) |
| `flist --selftest` | Smoke-test expander |
| `cargo …` / `python …` | Proxies with contained env |
| `clean` | `cargo clean` + remove `target/`, `.sv-timing-out/`, `.sv-timing-cache/` |
| `clean --all` | Same as `clean`, then remove contained `.tools/` (rustup/cargo/venv); re-run `setup` after |
| `env` | Print export / PowerShell assignments |
| `monorepo-soak …` | Sparse real-RTL FO4 soak when monorepo `core/` is present (not part of default `test`) |

### Clean crosswalk (when package is checked into CVA6 monorepo)

| Goal | Package (`cd sv-timing`) | Host (repo root) |
|------|--------------------------|------------------|
| Free Cargo / local cache bulk | `python tools/svt.py clean` | `./build.sh clean svt` |
| Free contained rustup/cargo | `python tools/svt.py clean --all` | `./build.sh clean svt-tools --yes` |
| Free host soak / timings packages | *(N/A)* | `./build.sh clean timings` |

Host inventory: `./build.sh clean status`. Never use host `clean timings` expecting to wipe
`sv-timing/target` (and vice versa). See monorepo `AGENTS-build-platform.md` §2.6.

## Bootstrap seeds (host)

| Seed | Required for |
|---|---|
| **Python 3.9+** (`python3`, `python`, or Windows `py -3`) | Running `svt.py` and creating venv |
| **curl** (Unix) or **Invoke-WebRequest** (Windows) | Downloading rustup-init |
| **git** | Vendoring sv-parser |
| **MSVC Build Tools** (Windows) or **gcc/clang** (Unix) | Linking Rust binaries |

Global Rust is **not** required. If present, it is ignored when `.tools/cargo` exists (PATH order).

## Why Python-first

- One implementation for Windows / macOS / Linux (path handling, subprocess, downloads).
- Shell/PowerShell stay thin → fewer OS-specific bugs.
- Same venv runs vendor + independence + future codegen.

## Agent rules

- **Never** add multi-step logic to `svt.sh` / `svt.ps1`; add a function in `svt.py`.
- Pin Rust via `rust-toolchain.toml` only.
- Keep `requirements.txt` minimal; prefer stdlib in `tools/*.py`.
