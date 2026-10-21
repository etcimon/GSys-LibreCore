#!/usr/bin/env python3
"""Flist resolution + provider uniqueness for the hyp8 trees."""
import os, re, pathlib

_HYP = pathlib.Path(os.environ.get("HYP_ROOT") or
                    pathlib.Path(__file__).resolve().parents[2])
CORE = _HYP / "hyp_redesign_core_8fo4"
APU = _HYP / "hyp_redesign_corev_apu_8fo4"
FLISTS = [CORE/"core/Flist.g6lc_hyp8", APU/"Flist.hyp8_apu"]

for fl in FLISTS:
    root = CORE if "hyp_redesign_core_8fo4" in str(fl) and "apu" not in str(fl) else CORE
    rows, missing = [], []
    for ln in fl.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("//") or ln.startswith("#") or ln.startswith("+"):
            continue
        p = ln.replace("${HYP_CORE_DIR}", str(CORE)).replace("${HYP_APU_DIR}", str(APU))
        p = p.split("//")[0].strip()
        if not p:
            continue
        rows.append(p)
        if not pathlib.Path(p).exists():
            missing.append(p)
    print(f"{fl.name}: {len(rows)} rows, {len(missing)} unresolved")
    for m in missing:
        print("   MISSING", m)
    # provider uniqueness: module names declared per flisted file
    mods = {}
    for p in rows:
        if not pathlib.Path(p).exists():
            continue
        try:
            t = pathlib.Path(p).read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        t = re.sub(r"//[^\n]*|/\*.*?\*/", " ", t, flags=re.S)
        for mm in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)", t):
            mods.setdefault(mm.group(1), []).append(p)
    dups = {n: fs for n, fs in mods.items() if len(fs) > 1}
    print(f"   flisted modules: {len(mods)}, duplicate providers: {len(dups)}")
    for n, fs in dups.items():
        print("   DUP", n)
        for x in fs: print("       ", x)


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
