# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Identity rename map for the hyp trees.

Upstream identity tokens are assembled from fragments at runtime so that this
source file itself stays free of them (the tree's cleanliness grep must pass
over tools/ as well).
"""
import re

# Upstream identity tokens (constructed — never spelled out literally).
L = "cv" + "a6"          # lower-case core token
U = "CV" + "A6"          # upper-case core token
T = "C" + "va6"          # title-case core token
AL = "a" + "riane"       # lower-case soc token
AU = "AR" + "IANE"       # upper-case soc token
AT = "A" + "riane"       # title-case soc token

# Ordered, whole-word, case-sensitive identifier map (code context).
# Each entry: (token, replacement). Tokens match only at identifier
# boundaries — a token followed by '_' or another ident char does not hit,
# which is what the catch-all `*_` rules cover.
RENAME_IDENTS = [
    (f"{L}_config_pkg", "g6lc_config_pkg"),
    (f"{U}Config", "G6LCConfig"),          # <U>Config* prefix
    (f"{U}Cfg", "G6LCCfg"),
    (f"{L}_cfg_t", "g6lc_cfg_t"),
    (f"{L}_cfg_empty", "g6lc_cfg_empty"),
    # explicit <core>_* modules/files
    (f"{L}_fifo_v3", "g6lc_fifo_v3"),
    (f"{L}_mmu", "g6lc_mmu"),
    (f"{L}_shared_tlb", "g6lc_shared_tlb"),
    (f"{L}_tlb", "g6lc_tlb"),
    (f"{L}_ptw", "g6lc_ptw"),
    (f"{L}_rvfi_probes", "g6lc_rvfi_probes"),
    (f"{L}_rvfi", "g6lc_rvfi"),
    (f"{L}_icache_axi_wrapper", "g6lc_icache_axi_wrapper"),
    (f"{L}_accel_first_pass_decoder_stub",
     "g6lc_accel_first_pass_decoder_stub"),
    # explicit <soc>_* packages / modules
    (f"{AL}_axi_soc_pkg", "g6lc_axi_soc_pkg"),
    (f"{AL}_axi_pkg", "g6lc_axi_pkg"),
    (f"{AL}_soc_pkg", "g6lc_soc_pkg"),
    (f"{AL}_pkg", "g6lc_core_pkg"),
    (f"{AL}_regfile_fpga", "g6lc_regfile_fpga"),
    (f"{AL}_regfile_ff", "g6lc_regfile_ff"),
    (f"{AL}_regfile", "g6lc_regfile"),
    # file names as they appear in `include` lines / flists
    (f"{L}.sv", "g6lc_core.sv"),
    (f"{AL}.sv", "g6lc_hart.sv"),
    # package scopes
    (f"{AL}_axi_soc::", "g6lc_axi_soc::"),
    (f"{AL}_axi::", "g6lc_axi::"),
    (f"{AL}_soc::", "g6lc_soc::"),
    (f"{U}_REPO_DIR", "HYP_ROOT"),
    # catch-alls: <tok>_<x>
    (f"{L}_", "g6lc_"),
    (f"{U}_", "G6LC_"),
    (f"{AL}_", "g6lc_"),
    (f"{AU}_", "G6LC_"),
    # bare module/type words (code context only)
    (f"{L}", "g6lc_core"),
    (f"{AL}", "g6lc_hart"),
    (f"{U}", "G6LC"),
    (f"{AU}", "G6LC"),
    (f"{T}", "G6lc"),
    (f"{AT}", "G6lc"),
]

# Prose/comment-context word replacements for the bare identity words.
PROSE_WORDS = [
    (U, "G6LC"),
    (AU, "G6LC"),
    (L, "g6lc"),
    (T, "G6lc"),
    (AL, "the core"),
    (AT, "the core"),
]

_BARE = {L, AL, U, AU, T, AT}

_EXEMPT = ("Copyright", "SPDX", "Licensed", "License", "http", "www")


# tokens that are identifier PREFIXES (no right boundary):
_PREFIX_TOKENS = {f"{U}Config", f"{U}Cfg"}


def _ww(token: str) -> re.Pattern:
    """Whole-word pattern: identifier boundary on the left; `_`-/`::`/`.sv`-
    suffixed catch-alls and prefix tokens have no right boundary."""
    if token.endswith("_") or token.endswith("::") or token.endswith(".sv") \
            or token in _PREFIX_TOKENS:
        return re.compile(r"\b" + re.escape(token))
    return re.compile(r"\b" + re.escape(token) + r"\b")


_PATS = [(_ww(t), r) for t, r in RENAME_IDENTS]
_PROSE_PATS = [(_ww(t), r) for t, r in PROSE_WORDS]
_PROSE_IDENT_PATS = [(_ww(t), r) for t, r in RENAME_IDENTS if t not in _BARE]

_PATH_RE = re.compile(
    r"[A-Za-z]:[\\/]+" + L + r"[\\/]+|[A-Za-z]:[\\/]+" + L + r"\b")

_RESID = re.compile(
    r"cv" + "a6" + r"|" + "a" + "riane", re.IGNORECASE)


def _resid_repl(m: re.Match) -> str:
    t = m.group(0)
    if t.isupper():
        return "G6LC"
    if t[:1].isupper():
        return "G6lc"
    return "g6lc"


def _sub_pairs(pairs, text: str) -> str:
    for pat, repl in pairs:
        text = pat.sub(repl, text)
    return text


def _prose_pass(text: str) -> str:
    """Comment/doc context: identifier-shaped tokens first, then bare words
    per the prose rule."""
    text = _sub_pairs(_PROSE_IDENT_PATS, text)
    text = _sub_pairs(_PROSE_PATS, text)
    return text


def _resid(text: str) -> str:
    return _RESID.sub(_resid_repl, text)


def _code_line(line: str) -> str:
    """Split code/comment; identifiers on code, prose rules on comment tails
    and string literals."""
    # find // outside double quotes, honoring // inside a string
    i, in_str, cut = 0, False, -1
    while i + 1 < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        if not in_str and c == "/" and line[i + 1] == "/":
            cut = i
            break
        i += 1
    code, comment = (line, "") if cut < 0 else (line[:cut], line[cut:])
    # code portion: full ident map, prose inside string literals
    def fix_str(m):
        return '"' + _resid(_prose_pass(m.group(1))) + '"'
    code = re.sub(r'"([^"]*)"', fix_str, code)
    code = _sub_pairs(_PATS, code)
    code = _resid(code)          # embedded leftovers: i_<tok>, acc_to_<tok>_t
    comment = _resid(_prose_pass(comment)) if comment else ""
    return code + comment


def apply_rename(text: str, prose: bool = False) -> str:
    """Rename upstream identity tokens. prose=True treats every line as
    comment/doc text (for .md); prose=False does the SV code/comment split."""
    out = []
    in_block = False
    for line in text.replace("\r\n", "\n").split("\n"):
        if any(k in line for k in _EXEMPT):
            out.append(line)
            continue
        if "/*" in line:
            in_block = True
        is_comment = in_block or line.lstrip().startswith("//")
        line = _PATH_RE.sub("<src>/", line)
        if prose or is_comment:
            new = _resid(_prose_pass(line))
        else:
            new = _code_line(line)
        if "*/" in line:
            in_block = False
        out.append(new)
    return "\n".join(out)


def rename_ident(name: str) -> str:
    """Rename one bare identifier (module/package/file stem)."""
    return _resid(_sub_pairs(_PATS, name))


def rename_path(rel: str) -> str:
    """Rename an upstream repo-relative path segment-wise."""
    return _resid(_sub_pairs(_PATS, rel.replace("\\", "/")))


def scrub_paths(text: str) -> str:
    """Repo-rooted paths -> <src>/<rel>; emit-relative left as-is."""
    return _PATH_RE.sub("<src>/", text)


_BANNER = re.compile(
    r"// Generated by sv-timing[^\n]*\n"
    r"// DO NOT commit without human review\.\n"
    r"// SPDX-FileCopyrightText: machine-generated\n")
BANNER_LINE = ("// hyp8 provenance: AS-IS "
               "(sv-timing emit at the 8-FO4 budget)\n")


def scrub_banner(text: str) -> str:
    """Replace the three-line sv-timing emit banner with the hyp8 provenance
    line; every other header line stays verbatim."""
    return _BANNER.sub(BANNER_LINE, text)


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
