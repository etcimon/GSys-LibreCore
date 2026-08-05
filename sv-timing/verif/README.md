# sv-timing verif / regress

Python-driven regression for **frequency-closure analysis** and **precompiler quality**:

1. Load heavy `.sv` fixtures under `tests/`
2. Run `sv-timing analyze` → JSON with **startpoint / endpoint / path_kind / slack / max_freq_mhz**
3. Run `sv-timing correct --emit` → optimized `*__svt.sv`
4. Lint optimized SV with **pyslang**
5. Check FO4 path cost does not worsen; emit reparse OK

## Run

```bash
cd sv-timing
python tools/svt.py setup          # rust + venv
python tools/svt.py verif-regress  # install pyslang if needed, run suite
```

Or:

```bash
.tools/python-venv/Scripts/python tools/svt.py verif-regress   # Windows
.tools/python-venv/bin/python tools/svt.py verif-regress       # Unix
```

Outputs: `.sv-timing-out/verif-regress/<case>/` + `summary.json`.

## Suite definition

`regress/suites.toml` — cases, target MHz, pyslang requirements.

## Adding a case

1. Add `verif/tests/my_heavy.sv` with intentional long combinational / reg paths  
   **or** a multi-file project under `fixtures/` + `files_from = "…/project.f"`  
2. Append `[[case]]` in `regress/suites.toml` (`module=` **or** `all_modules = true`)  
3. Re-run `python tools/svt.py verif-regress --case my_id`

Multi-file project auto-correct (out-dir, `svt_corrected.f`, per-file edits):  
see [`architecture/PROJECT-AUTOCORRECT.md`](../architecture/PROJECT-AUTOCORRECT.md).
