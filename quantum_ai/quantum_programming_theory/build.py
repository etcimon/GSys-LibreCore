#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Rebuild the Grok QC conversation export as a readable HTML article."""
from __future__ import annotations

import html
import re
from pathlib import Path

SRC = Path("/home/workdir/attachments/148_Quantum_Computing_Qubits,_Challenges,_Progress.html")
OUT = Path("/home/workdir/artifacts/qc-export-html/index.html")


def extract_body(text: str) -> str:
    i = text.find("<body>")
    j = text.find("</body>")
    if i < 0:
        return text
    return text[i + 6 : j if j > 0 else None]


def strip_junk(s: str) -> str:
    s = re.sub(r"<grok:render[\s\S]*?</grok:render>", "", s)
    s = re.sub(r"</?grok:render[^>]*>", "", s)
    s = re.sub(r'<argument name="citation_id">\d+</argument>', "", s)
    s = re.sub(r"\s*<hr\s*/?>\s*", "\n", s)
    return s


def split_turns(body: str) -> list[tuple[str, str]]:
    # Pattern: <p><strong>HUMAN</strong>: ... then ASSISTANT
    parts = re.split(r"<p><strong>(HUMAN|ASSISTANT)</strong>\s*:", body)
    # parts[0] is preamble before first HUMAN (title)
    turns = []
    role = None
    buf_preamble = parts[0]
    i = 1
    while i < len(parts):
        role = parts[i].strip()
        content = parts[i + 1] if i + 1 < len(parts) else ""
        turns.append((role, content))
        i += 2
    return buf_preamble, turns


def first_text(html_frag: str, n: int = 90) -> str:
    t = re.sub(r"<[^>]+>", " ", html_frag)
    t = html.unescape(t)
    t = re.sub(r"\s+", " ", t).strip()
    if len(t) > n:
        t = t[: n - 1].rsplit(" ", 1)[0] + "…"
    return t


def wrap_math(frag: str) -> str:
    """Light touch: convert common TeX leftovers into KaTeX blocks."""
    frag = frag.replace(r"\begin{pmatrix}", r"$$\begin{pmatrix}")
    frag = frag.replace(r"\end{pmatrix}", r"\end{pmatrix}$$")
    return frag


def _split_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    cells = [c.strip() for c in line.split("|")]
    return cells


def _is_sep(cells: list[str]) -> bool:
    if not cells:
        return False
    return all(re.fullmatch(r":?-{3,}:?", c.replace(" ", "")) or c == "" for c in cells)


def _cell_html(c: str) -> str:
    c = c.strip()
    # close dangling inline code
    ticks = c.count("`")
    if ticks % 2 == 1:
        c = c + "`"
    # inline code
    c = re.sub(r"`([^`]+)`", r"<code>\1</code>", c)
    c = c.replace("\n", "<br/>")
    return c


_KET_RE = re.compile(r"\|([^\s|<>]{1,24})⟩")


def _protect_kets(s: str) -> str:
    return _KET_RE.sub(lambda m: f"§KET:{m.group(1)}§", s)


def _restore_kets(s: str) -> str:
    return re.sub(r"§KET:([^§]+)§", r"|\1⟩", s)


def markdown_table_to_html(block: str) -> str:
    block = _protect_kets(block)
    raw_lines = [ln.strip() for ln in block.strip().splitlines() if ln.strip()]
    lines = []
    for ln in raw_lines:
        ln = re.sub(r"<br\s*/?>", " ", ln)
        ln = re.sub(r"</?p>", "", ln)
        if "|" in ln:
            lines.append(ln)
    if len(lines) < 2:
        return block
    rows = [_split_row(ln) for ln in lines]
    if not rows:
        return block
    header = rows[0]
    body_rows = rows[1:]
    if body_rows and _is_sep(body_rows[0]):
        body_rows = body_rows[1:]
    width = max(len(header), max((len(r) for r in body_rows), default=0))
    header += [""] * (width - len(header))
    out = ['<div class="tbl-wrap"><table>']
    out.append("<thead><tr>" + "".join(f"<th>{_cell_html(c)}</th>" for c in header) + "</tr></thead>")
    out.append("<tbody>")
    for r in body_rows:
        r = r + [""] * (width - len(r))
        # skip leftover separator-like
        if _is_sep(r):
            continue
        out.append("<tr>" + "".join(f"<td>{_cell_html(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table></div>")
    return _restore_kets("\n".join(out))


def convert_pipe_tables(frag: str) -> str:
    """Turn markdown pipe tables (often wrapped in <p>) into HTML tables."""

    def repl_p(m: re.Match) -> str:
        inner = m.group(1)
        if inner.strip().startswith("|") and inner.count("|") >= 4:
            return markdown_table_to_html(inner)
        return m.group(0)

    frag = re.sub(r"<p>(\s*\|[\s\S]*?)</p>", repl_p, frag)

    # bare multi-line tables not inside <p>
    def repl_bare(m: re.Match) -> str:
        return markdown_table_to_html(m.group(0))

    frag = re.sub(
        r"(?:^|\n)((?:\|[^\n]+\|\s*\n){2,})",
        lambda m: "\n" + markdown_table_to_html(m.group(1)),
        frag,
    )
    return frag


CSS = r"""
:root {
  --ink: #1a1612;
  --paper: #f6f1e6;
  --rule: #c4a574;
  --accent: #6b2d2d;
  --muted: #6a6156;
  --card: #fffaf1;
  --qbg: #efe6d4;
  --codebg: #231f1b;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  font-family: "Palatino Linotype", Palatino, "Book Antiqua", "Times New Roman", serif;
  background: var(--paper);
  color: var(--ink);
  line-height: 1.55;
}
.mast {
  background: var(--ink);
  color: var(--paper);
  padding: 2.4rem 1.5rem 2rem;
  border-bottom: 6px solid var(--rule);
}
.mast .kicker {
  letter-spacing: .18em;
  text-transform: uppercase;
  font-size: .72rem;
  color: var(--rule);
  margin: 0 0 .6rem;
}
.mast h1 {
  font-weight: 400;
  font-size: clamp(1.6rem, 3vw, 2.4rem);
  margin: 0 0 .5rem;
  line-height: 1.2;
}
.mast p { margin: 0; color: #d9cbb3; max-width: 46rem; }
.wrap {
  display: grid;
  grid-template-columns: minmax(0, 16rem) minmax(0, 48rem);
  gap: 2rem;
  max-width: 72rem;
  margin: 0 auto;
  padding: 1.5rem 1.25rem 4rem;
}
nav.toc {
  position: sticky;
  top: 1rem;
  align-self: start;
  max-height: calc(100vh - 2rem);
  overflow: auto;
  font-size: .82rem;
  padding-right: .4rem;
}
nav.toc h2 {
  font-size: .75rem;
  letter-spacing: .14em;
  text-transform: uppercase;
  color: var(--muted);
  margin: 0 0 .6rem;
}
nav.toc ul { margin: 0; padding: 0; list-style: none; }
nav.toc li { margin: 0 0 .45rem; padding-left: 0; }
nav.toc li a { display: block; line-height: 1.3; }
figure.diagram {
  margin: 1rem 0 1.3rem;
  padding: .6rem .8rem .4rem;
  background: #fff;
  border: 1px solid #e6dcc8;
  text-align: center;
}
figure.diagram svg { max-width: 100%; height: auto; }
figure.diagram figcaption {
  font-size: .82rem;
  color: var(--muted);
  margin: .35rem 0 .15rem;
  font-style: italic;
}
.bloch-stage {
  position: relative;
  overflow: hidden;
  width: 100%;
  height: 500px;
  background: #05060a;
  border-radius: 4px;
}
figure.diagram.bloch-fig {
  background: #05060a;
  border-color: #1d3346;
  padding: .5rem .5rem .3rem;
}
figure.diagram.bloch-fig figcaption {
  color: #a8bccd;
  font-style: normal;
  text-align: left;
  padding: 0 .3rem;
  line-height: 1.45;
}
@media (max-width: 620px) {
  .bloch-stage { height: 430px; }
}
nav.toc a { color: var(--ink); text-decoration: none; }
nav.toc a:hover { color: var(--accent); }
article header.sec {
  margin: 2.2rem 0 1rem;
  padding-bottom: .35rem;
  border-bottom: 1px solid var(--rule);
}
.chapter { margin: 0 0 2.4rem; }
.chapter > h2 {
  font-size: 1.45rem;
  margin: 0 0 .85rem;
  padding-bottom: .35rem;
  border-bottom: 1px solid var(--rule);
}
.turn { margin: 0 0 1.6rem; }
.q, .a { padding: 1rem 1.15rem; border-radius: 2px; }
.q {
  background: var(--qbg);
  border-left: 4px solid var(--accent);
}
.a {
  background: var(--card);
  border: 1px solid #e6dcc8;
  border-left: 4px solid var(--rule);
}
.role {
  font-size: .68rem;
  letter-spacing: .16em;
  text-transform: uppercase;
  color: var(--muted);
  margin: 0 0 .45rem;
}
.q .role { color: var(--accent); }
h2, h3, h4 { font-weight: 600; line-height: 1.25; }
.tbl-wrap { overflow-x: auto; margin: 1rem 0; }
table {
  border-collapse: collapse;
  width: 100%;
  font-size: .84rem;
  margin: 0;
  background: #fff;
  min-width: 36rem;
}
th, td {
  border: 1px solid #d9cbb3;
  padding: .4rem .55rem;
  vertical-align: top;
}
th { background: #efe4cf; text-align: left; }
pre, .codehilite {
  background: var(--codebg);
  color: #e8dcc6;
  padding: 1rem 1.1rem;
  overflow-x: auto;
  font-size: .82rem;
  line-height: 1.45;
  border-radius: 3px;
  border: 1px solid #3a332b;
  tab-size: 4;
}
.codehilite pre { margin: 0; padding: 0; border: 0; background: transparent; }
.codehilite, .codehilite code, .codehilite span {
  font-family: "Source Code Pro", "Fira Code", Consolas, "Liberation Mono", monospace;
}
.codehilite .c, .codehilite .c1, .codehilite .cm, .codehilite .ch, .codehilite .cs {
  color: #7d8b6a; font-style: italic;
}
.codehilite .cp, .codehilite .cpf { color: #c9a227; font-weight: 600; }
.codehilite .k, .codehilite .kd, .codehilite .kn, .codehilite .kr, .codehilite .kc {
  color: #d27a54; font-weight: 700;
}
.codehilite .kt { color: #c97b9b; font-weight: 700; }
.codehilite .n { color: #e8dcc6; }
.codehilite .nf { color: #e0c36a; }
.codehilite .nc, .codehilite .nn { color: #d4b483; font-weight: 700; }
.codehilite .nv { color: #b8d4e3; }
.codehilite .nb, .codehilite .bp { color: #d27a54; }
.codehilite .s, .codehilite .s1, .codehilite .s2, .codehilite .sa, .codehilite .se, .codehilite .si {
  color: #c9866b;
}
.codehilite .ss { color: #c9a227; }
.codehilite .m, .codehilite .mi, .codehilite .mf, .codehilite .mh { color: #8fb3a3; }
.codehilite .o, .codehilite .ow { color: #c4a574; }
.codehilite .p { color: #cbbba0; }
.codehilite .err { color: #f0d5c8; background: #5a2a22; }
.codehilite .w { color: #6a6156; }
code { font-family: "Source Code Pro", Consolas, monospace; }
p code, li code {
  background: #efe6d4;
  color: #3a2a1a;
  padding: 0 .2em;
}
blockquote {
  margin: 1rem 0;
  padding: .2rem 1rem;
  border-left: 3px solid var(--rule);
  color: #3d3429;
}
.note {
  font-size: .9rem;
  color: var(--muted);
  margin-top: 3rem;
}
.corrigenda {
  background: #f3e6d4;
  border: 1px solid var(--rule);
  border-left: 4px solid var(--accent);
  padding: .9rem 1.1rem 1rem;
  margin: 0 0 1.8rem;
  font-size: .92rem;
}
.corrigenda h2 {
  margin: 0 0 .5rem;
  font-size: 1.05rem;
}
.corrigenda ol { margin: .3rem 0 0 1.2rem; padding: 0; }
.corrigenda li { margin: 0 0 .4rem; }
/* ---- gate figures: js/qtheory.js + js/gate-figure.js ---- */
button.gq-link {
  font: inherit;
  color: var(--accent);
  background: none;
  border: 0;
  border-bottom: 1px dotted var(--accent);
  padding: 0;
  margin: 0;
  cursor: pointer;
  line-height: inherit;
}
button.gq-link:hover, button.gq-link:focus-visible {
  background: #f2e2ce;
  border-bottom-style: solid;
  outline: none;
}
td button.gq-link, th button.gq-link { font-weight: 700; }
figure.diagram.gate-atlas-fig {
  background: #05060a;
  border-color: #1d3346;
  padding: .6rem .6rem .45rem;
}
figure.diagram.gate-atlas-fig figcaption {
  color: #a8bccd;
  font-style: normal;
  text-align: left;
  padding: .1rem .3rem 0;
  line-height: 1.45;
}
.gq-atlas {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(15.5rem, 1fr));
  gap: .5rem;
  align-items: start;
}
.gq-card {
  position: relative;
  margin: 0;
  padding: .45rem .5rem .4rem;
  background: linear-gradient(180deg, #0c1119, #070a11);
  border: 1px solid #1c2f42;
  border-radius: 3px;
  color: #cfdcea;
  font-size: .78rem;
}
.gq-card-head { display: flex; align-items: baseline; gap: .4rem; }
.gq-sym {
  font-family: "Source Code Pro", Consolas, monospace;
  font-weight: 700;
  font-size: .95rem;
  color: #ff8ae8;
  background: rgba(255, 90, 224, .12);
  border: 1px solid rgba(255, 90, 224, .35);
  border-radius: 2px;
  padding: 0 .3em;
  white-space: nowrap;
}
.gq-card-titles { display: flex; flex-direction: column; line-height: 1.2; min-width: 0; }
.gq-card-titles b { color: #e6eef7; font-weight: 600; }
.gq-card-titles small { color: #7f9bb5; font-size: .68rem; }
.gq-card-body { display: flex; gap: .4rem; align-items: flex-start; margin-top: .3rem; }
.gq-card-fig { flex: 0 0 auto; }
.gq-card-num { flex: 1 1 auto; min-width: 0; }
.gq-sphere { display: block; width: 10.5rem; height: auto; }
.gq-io {
  text-align: center;
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .8rem;
  margin-top: -.2rem;
}
.gq-io-in { color: #9fb6cb; }
.gq-io-arr { color: #ffd166; margin: 0 .25em; }
.gq-io-out { color: #ff8ae8; font-weight: 700; }
.gq-card-note { margin: .35rem 0 0; color: #8fa9c0; font-size: .7rem; line-height: 1.35; }
.gq-card-cap { margin: .35rem 0 0; border-top: 1px solid #16283a; padding-top: .28rem; }
.gq-card-cap code {
  background: none;
  color: #d8b26a;
  font-size: .7rem;
  padding: 0;
}
.gq-card-open {
  position: absolute;
  top: .35rem;
  right: .35rem;
  font: 600 .62rem/1 "Source Code Pro", Consolas, monospace;
  color: #7fd4ea;
  background: rgba(53, 201, 232, .1);
  border: 1px solid rgba(53, 201, 232, .35);
  border-radius: 2px;
  padding: .18rem .3rem;
  cursor: pointer;
}
.gq-card-open:hover { background: rgba(53, 201, 232, .25); color: #d6f6ff; }
.gq-bars { margin-top: .2rem; }
.gq-bar-row { display: flex; align-items: center; gap: .3rem; margin: .1rem 0; }
.gq-bar-lab {
  flex: 0 0 2.6rem;
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .65rem;
  color: #8fa9c0;
}
.gq-bar-track {
  flex: 1 1 auto;
  height: .42rem;
  background: rgba(120, 160, 200, .14);
  border-radius: 2px;
  overflow: hidden;
}
.gq-bar-fill { display: block; height: 100%; }
.gq-b-before { background: #7f9bb5; }
.gq-b-after { background: #ff35d6; }
.gq-bar-val {
  flex: 0 0 2.6rem;
  text-align: right;
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .65rem;
  color: #cfdcea;
}
table.gq-diff, table.gq-act, table.gq-basis-tbl {
  width: 100%;
  min-width: 0;
  border-collapse: collapse;
  background: none;
  font-size: .72rem;
  margin: .2rem 0;
}
table.gq-diff th, table.gq-diff td,
table.gq-act th, table.gq-act td,
table.gq-basis-tbl th, table.gq-basis-tbl td {
  border: 0;
  border-bottom: 1px solid #16283a;
  padding: .18rem .3rem;
  text-align: left;
  vertical-align: middle;
  color: #cfdcea;
  background: none;
}
table.gq-diff thead th, table.gq-basis-tbl thead th {
  color: #7f9bb5;
  font-weight: 600;
  font-size: .64rem;
  letter-spacing: .06em;
  text-transform: uppercase;
}
table.gq-diff tbody th, table.gq-act th, table.gq-basis-tbl tbody th {
  color: #9fb6cb;
  font-weight: 500;
  font-family: "Source Code Pro", Consolas, monospace;
  white-space: nowrap;
}
tr.gq-changed td, tr.gq-changed th { background: rgba(255, 53, 214, .09); }
tr.gq-changed .gq-delta { color: #ff8ae8; font-weight: 700; }
tr.gq-same td, tr.gq-same th { opacity: .62; }
.gq-delta { font-family: "Source Code Pro", Consolas, monospace; }
.gq-amp { display: flex; align-items: center; gap: .3rem; }
.gq-amp-bar {
  display: block;
  height: .4rem;
  min-width: 1px;
  background: #4ce3ff;
  border-radius: 1px;
  flex: 0 0 auto;
  max-width: 3.2rem;
}
.gq-amp-bar.gq-amp-neg { background: #ffa63a; }
.gq-amp-num {
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .66rem;
  white-space: nowrap;
}
.gq-ent {
  margin: .4rem 0 0;
  font-size: .72rem;
  line-height: 1.45;
  color: #8fa9c0;
  border-left: 2px solid #1e5d72;
  padding-left: .45rem;
}
.gq-ent.gq-ent-yes { color: #bfe6f5; border-left-color: #35c9e8; }
.gq-ent b { color: #ff8ae8; }
.gq-basis.gq-compact { width: 100%; }
.gq-matrix { display: inline-block; margin: .1rem 0 .4rem; }
.gq-matrix table {
  border-collapse: collapse;
  background: none;
  min-width: 0;
  border-left: 2px solid #35c9e8;
  border-right: 2px solid #35c9e8;
}
.gq-matrix td {
  border: 0;
  padding: .12rem .45rem;
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .72rem;
  color: #cfdcea;
  text-align: center;
  background: none;
}
/* ---- modal ---- */
body.gq-modal-lock { overflow: hidden; }
.gq-modal-back {
  position: fixed;
  inset: 0;
  z-index: 900;
  display: none;
  align-items: center;
  justify-content: center;
  padding: 1.2rem;
  background: rgba(4, 5, 10, .78);
}
.gq-modal-back.gq-open { display: flex; }
.gq-modal {
  width: min(56rem, 100%);
  max-height: 92vh;
  overflow: auto;
  background: radial-gradient(120% 90% at 78% 6%, #22102c 0%, #0b0d16 46%, #05060a 100%);
  border: 1px solid #2a4257;
  border-radius: 4px;
  color: #cfdcea;
  box-shadow: 0 1.4rem 3rem rgba(0, 0, 0, .6);
  font-size: .82rem;
}
.gq-modal:focus { outline: none; }
.gq-modal-head {
  display: flex;
  align-items: center;
  gap: .5rem;
  padding: .6rem .8rem;
  border-bottom: 1px solid #1e3346;
  position: sticky;
  top: 0;
  background: rgba(6, 8, 14, .95);
  z-index: 2;
}
.gq-modal-head h3 {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  color: #e9f1f8;
  display: flex;
  align-items: center;
  gap: .45rem;
  flex: 1 1 auto;
}
code.gq-qiskit {
  font-size: .7rem;
  color: #d8b26a;
  background: rgba(216, 178, 106, .1);
  border: 1px solid rgba(216, 178, 106, .25);
  border-radius: 2px;
  padding: .05rem .3rem;
}
.gq-close {
  flex: 0 0 auto;
  font-size: 1.3rem;
  line-height: 1;
  color: #9fb6cb;
  background: none;
  border: 1px solid #24405a;
  border-radius: 2px;
  width: 1.7rem;
  height: 1.7rem;
  cursor: pointer;
}
.gq-close:hover { color: #fff; background: #24405a; }
.gq-modal-body { padding: .7rem .8rem 1rem; }
.gq-modal-main { display: flex; gap: .9rem; align-items: flex-start; flex-wrap: wrap; }
.gq-modal-fig { flex: 0 0 20rem; max-width: 100%; }
.gq-modal-fig .gq-sphere { width: 20rem; max-width: 100%; }
.gq-modal-main-nq .gq-modal-fig { flex: 1 1 22rem; }
.gq-modal-num { flex: 1 1 16rem; min-width: 0; }
.gq-num-head { font-family: "Source Code Pro", Consolas, monospace; margin-bottom: .25rem; }
.gq-num-head b { color: #9fb6cb; font-size: .95rem; }
.gq-num-head b.gq-out { color: #ff8ae8; }
.gq-num-head small { color: #7f9bb5; font-size: .68rem; }
.gq-controls { margin-top: .4rem; }
.gq-ctrl-row { display: flex; align-items: center; gap: .4rem; margin: .3rem 0; flex-wrap: wrap; }
.gq-ctrl-lab {
  flex: 0 0 2.4rem;
  font-size: .68rem;
  color: #7f9bb5;
  text-transform: uppercase;
  letter-spacing: .08em;
}
.gq-chips { display: flex; gap: .22rem; flex-wrap: wrap; }
.gq-chip {
  font: 600 .72rem/1 "Source Code Pro", Consolas, monospace;
  color: #9fb6cb;
  background: rgba(120, 160, 200, .1);
  border: 1px solid #24405a;
  border-radius: 2px;
  padding: .22rem .34rem;
  cursor: pointer;
}
.gq-chip:hover { color: #e9f1f8; border-color: #35c9e8; }
.gq-chip.gq-on {
  color: #06121a;
  background: #7fd4ea;
  border-color: #7fd4ea;
}
.gq-range { flex: 1 1 8rem; min-width: 7rem; accent-color: #ff35d6; }
.gq-ctrl-out {
  flex: 0 0 2.6rem;
  text-align: right;
  font-family: "Source Code Pro", Consolas, monospace;
  font-size: .7rem;
  color: #cfdcea;
}
.gq-play {
  font: 600 .72rem/1 "Source Code Pro", Consolas, monospace;
  color: #06121a;
  background: #ff8ae8;
  border: 1px solid #ff8ae8;
  border-radius: 2px;
  padding: .3rem .45rem;
  cursor: pointer;
}
.gq-play:hover { background: #ffb3f1; }
.gq-extra h4 {
  margin: .6rem 0 .1rem;
  font-size: .66rem;
  font-weight: 600;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: #7f9bb5;
}
.gq-notes p {
  margin: .3rem 0 0;
  font-size: .72rem;
  line-height: 1.45;
  color: #bfe6f5;
  border-left: 2px solid #35c9e8;
  padding-left: .45rem;
}
dl.gq-prose {
  margin: .8rem 0 0;
  padding-top: .5rem;
  border-top: 1px solid #1e3346;
  display: grid;
  grid-template-columns: 8.5rem 1fr;
  gap: .18rem .6rem;
  font-size: .78rem;
}
dl.gq-prose dt {
  color: #7f9bb5;
  font-size: .68rem;
  text-transform: uppercase;
  letter-spacing: .07em;
  padding-top: .12rem;
}
dl.gq-prose dd { margin: 0; color: #cfdcea; line-height: 1.5; }
dl.gq-prose dd code { background: none; color: #d8b26a; padding: 0; font-size: .74rem; }
@media (max-width: 640px) {
  .gq-modal-fig, .gq-modal-fig .gq-sphere { flex-basis: 100%; width: 100%; }
  dl.gq-prose { grid-template-columns: 1fr; }
  dl.gq-prose dd { margin-bottom: .35rem; }
}
@media (max-width: 860px) {
  .wrap { grid-template-columns: 1fr; }
  nav.toc { position: static; max-height: none; }
}
"""

# NOTE: the SPDX tag below is inside a generator string literal, so this file
# legitimately contains two of them (AGENTS-licensing.md, "Invariants": the
# one-tag-per-file rule excludes code-generator string literals).
TEMPLATE = """<!DOCTYPE html>
<!--
Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
-->
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Quantum Computing: Hardware, Primitives, Photonics, and Hybrid Memory</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css"/>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
  onload="renderMathInElement(document.body, {
    delimiters: [
      {left: '$$', right: '$$', display: true},
      {left: '\\\\[', right: '\\\\]', display: true},
      {left: '\\\\(', right: '\\\\)', display: false},
      {left: '$', right: '$', display: false}
    ],
    throwOnError: false
  });"></script>
<style>{css}</style>
</head>
<body>
<header class="mast">
  <p class="kicker">Theoretical notes · photonic and hybrid memory</p>
  <h1>Quantum Computing: Hardware, Primitives, Photonics, and Hybrid Memory</h1>
  <p>A titled monograph assembled from a technical thread: physical and logical qubits,
  optical gate realizations, field pictures, the reversible-C interface, qRAM,
  cryogenic classical memory, and on-site readout. Standard polarization and
  computational-basis language is used throughout.</p>
</header>
<div class="wrap">
<nav class="toc">
  <h2>Contents</h2>
  <ul>
{toc}
  </ul>
</nav>
<article>
{body}
<p class="note">Mathematical fragments are typeset with KaTeX. Code is Pygments-tagged C and Python from the source export.</p>
</article>
</div>
<script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>
<script src="js/qtheory.js"></script>
<script src="js/bloch.js"></script>
<script src="js/gate-figure.js"></script>
</body>
</html>
"""


def plain_len(frag: str) -> int:
    t = re.sub(r"<[^>]+>", " ", frag)
    t = html.unescape(t)
    return len(re.sub(r"\s+", " ", t).strip())


def first_heading(frag: str) -> str | None:
    m = re.search(r"<h[2-4][^>]*>(.*?)</h[2-4]>", frag, re.I | re.S)
    if not m:
        return None
    title = re.sub(r"<[^>]+>", "", m.group(1))
    title = html.unescape(re.sub(r"\s+", " ", title)).strip()
    return title or None


def slugify(title: str, used: set[str]) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower())
    s = s.strip("-")[:56] or "section"
    base = s
    n = 2
    while s in used:
        s = f"{base}-{n}"
        n += 1
    used.add(s)
    return s


def canonize_terms(s: str) -> str:
    pairs = [
        ("PlaneSpace/OrthoSpace", "the two orthogonal polarization modes"),
        ("planespace/orthospace", "the two orthogonal polarization modes"),
        ("PlaneSpace and OrthoSpace", "the horizontal and vertical polarization modes"),
        ("planespace and orthospace", "the horizontal and vertical polarization modes"),
        ("PrimeSpace = |0⟩, OrthoSpace = |1⟩", "|0⟩ = horizontal, |1⟩ = vertical"),
        ("PrimeSpace", "the |0⟩ (horizontal) component"),
        ("OrthoSpace", "the |1⟩ (vertical) component"),
        ("orthospace", "vertical mode"),
        ("planespace", "horizontal mode"),
        ("Planespace", "horizontal mode"),
        ("Orthospace", "vertical mode"),
    ]
    for a, b in pairs:
        s = s.replace(a, b)
    return s


def mathify_outside_code(frag: str) -> str:
    """Turn common physics snippets into KaTeX, leaving code fences alone."""
    parts = re.split(r"(<div class=\"codehilite\">[\s\S]*?</div>|<pre[\s\S]*?</pre>)", frag)
    subs = [
        (r"sin³\(ωt\)", r"\\(\\sin^{3}(\\omega t)\\)"),
        (r"cos³\(ωt\)", r"\\(\\cos^{3}(\\omega t)\\)"),
        (r"sin³", r"\\(\\sin^{3}\\)"),
        (r"cos³", r"\\(\\cos^{3}\\)"),
        (r"√2", r"\\(\\sqrt{2}\\)"),
        (r"π/4", r"\\(\\pi/4\\)"),
        (r"π/2", r"\\(\\pi/2\\)"),
        (r"(?<![\\a-zA-Z])π(?![a-zA-Z])", r"\\(\\pi\\)"),
        (r"ωt", r"\\(\\omega t\\)"),
        (r"10\^25", r"\\(10^{25}\\)"),
        (r"2\^30", r"\\(2^{30}\\)"),
        (r"2\^40", r"\\(2^{40}\\)"),
        (r"θ/2", r"\\(\\theta/2\\)"),
        (r"(?<![\\a-zA-Z])θ(?![a-zA-Z])", r"\\(\\theta\\)"),
        (r"φ", r"\\(\\varphi\\)"),
        (r"ψ\(t\)", r"\\(\\psi(t)\\)"),
        (r"(?<![\\|\w])ψ(?![\w])", r"\\(\\psi\\)"),
    ]

    def conv(chunk: str) -> str:
        if chunk.startswith("<div class=\"codehilite\"") or chunk.startswith("<pre"):
            return chunk
        # do not rewrite inside already-delimited math
        pieces = re.split(r"(\$\$.*?\$\$|\\\(.*?\\\))", chunk, flags=re.S)
        out = []
        for piece in pieces:
            if piece.startswith("$$") or piece.startswith("\\("):
                out.append(piece)
                continue
            tmp = piece
            for pat, repl in subs:
                tmp = re.sub(pat, repl, tmp)
            out.append(tmp)
        return "".join(out)

    return "".join(conv(p) for p in parts)


def escape_text_underscores(frag: str) -> str:
    r"""Escape `_` inside \text{...}.

    KaTeX rejects a bare underscore in text mode ("Can't use function '_' in
    text mode"), and with throwOnError:false that renders as red error text in
    the article rather than failing loudly. The thread's Grover section writes
    \text{target_cipher} twice, which is where this bites.
    """

    def fix(m: re.Match) -> str:
        return r"\text{" + m.group(1).replace("_", r"\_") + "}"

    # only well-formed, non-nested \text{...} groups
    return re.sub(r"\\text\{([^{}]*)\}", fix, frag)


def repair_math(frag: str) -> str:
    """Undo markdown-italic damage to TeX subscripts inside $$ blocks."""
    frag = re.sub(r"<em>\{([^}]*)\}</em>", r"_{\1}", frag)
    frag = re.sub(r"<em>\{([^}]*)\}", r"_{\1}", frag)
    frag = frag.replace(r"\bigotimes</em>{", r"\bigotimes_{")
    # user's explicit identity, if a mangled cousin remains
    frag = frag.replace(
        r"\text{mCZ}_{40}\;|\psi_3\rangle",
        r"\mathrm{mCZ}_{40}\,|\psi_3\rangle",
    )
    # NOTE: this rewrite must run *before* \text{mCZ} is renamed to \mathrm{mCZ}
    # below, or it can never match — which is exactly why its `target\_cipher`
    # escape never reached the output and the formula rendered as a KaTeX error.
    frag = re.sub(
        r"\$\$\s*\\(?:text|mathrm)\{mCZ\}[\s\S]*?\$\$",
        lambda _m: "$$\\mathrm{mCZ}_{40}\\,|\\psi_3\\rangle = (-1)^{\\delta\\bigl(h(\\mathrm{guess}),\\,\\mathrm{target\\_cipher}\\bigr)}\\,|\\psi_3\\rangle$$",
        frag,
        count=1,
    )
    frag = frag.replace(r"\text{mCZ}_{40}", r"\mathrm{mCZ}_{40}")
    return escape_text_underscores(frag)


_BLOCH_USED = 0

# Bloch-sphere figures. Each key is a gate programme animated by js/bloch.js;
# the state is always the Prime/Ortho split of the chapters "Crucial geometric
# fact", "Ten beautiful special cases" and "Universal Cycle-Exclusive Wave
# Function": Prime = |0⟩ = horizontal = √P sin³(ωt) on +Z, Ortho = |1⟩ =
# vertical = √Q cos³(ωt+φ) on −Z, glued into one Euclidean ball by
# r = (2√(PQ) cos φ, 2√(PQ) sin φ, P − Q).
_RVEC = r"\(\mathbf{r}=(2\sqrt{PQ}\cos\varphi,\;2\sqrt{PQ}\sin\varphi,\;P-Q)\)"

# The panel legend. Ortho is carried as sin³(ωt+φ) — identically the thread's
# cos³ term with its built-in quarter-cycle stagger absorbed into φ, which is
# what makes φ = 0 the +45° linear state on +X and φ = π/2 the circular state
# on +Y, as the "Crucial geometric fact" table requires. The two modes are
# orthogonal directions in the lab, so they are shown as the components of the
# transverse field rather than summed as scalars.
_PSI = (
    r"the two cycle terms \(\sqrt{P}\sin^{3}(\omega t)\) (Prime, horizontal) and "
    r"\(\sqrt{Q}\sin^{3}(\omega t+\varphi)\equiv\sqrt{Q}\cos^{3}(\omega t+\varphi-\pi/2)\) "
    r"(Ortho, vertical), their envelope "
    r"\(|E|=\sqrt{\mathrm{Prime}^{2}+\mathrm{Ortho}^{2}}\), which space owns each slice of the "
    r"cycle, and the polarisation figure the pair sweeps in the transverse plane"
)

BLOCH_DEMOS = {
    "precess": (
        r"<strong>Free propagation, \(R_z(\omega t)\).</strong> The Prime/Ortho split is held "
        r"fixed (\(P=0.75\), \(Q=0.25\)) while the relative phase \(\varphi\) advances, so "
        + _RVEC
        + r" precesses on a latitude ring — the arrow turns because circular light has a "
        r"rotating E-field. Panel: " + _PSI + r"."
    ),
    "hadamard": (
        r"<strong>H as a \(\pi\) rotation about \((\hat x+\hat z)/\sqrt2\).</strong> "
        r"\(|0\rangle\) Prime (\(P=1\), pure \(\sin^{3}\), horizontal linear) is carried to "
        r"\(|+\rangle\) with \(P=Q=\tfrac12\) on the \(+x\) equator, where both modes run in "
        r"phase and the light is \(+45^\circ\) linear. Panel: " + _PSI + r"."
    ),
    "rx": (
        r"<strong>\(R_x(\theta)\) — quarter- plus half-wave plates.</strong> Rotation about "
        r"\(\hat x\) walks \(|0\rangle\) Prime down the \(y\)–\(z\) meridian, trading \(P\) for "
        r"\(Q\) while \(\varphi\) swings to \(\pm\pi/2\) — the phase kick that opens the "
        r"polarisation figure into a circle. Panel: " + _PSI + r"."
    ),
    "xflip": (
        r"<strong>Pauli-X as a \(\pi\) rotation about \(\hat x\).</strong> North ↔ south, i.e. "
        r"\(\sin^{3}(\omega t)\leftrightarrow\cos^{3}(\omega t)\): the Prime and Ortho amplitudes "
        r"swap, which is exactly what a half-wave plate does. Panel: " + _PSI + r"."
    ),
    "sphase": (
        r"<strong>S — the quarter-cycle delay about \(\hat z\).</strong> "
        r"\(|+\rangle\to|R\rangle\to|-\rangle\): \(P\) and \(Q\) are untouched and only the "
        r"Prime/Ortho stagger \(\varphi\) moves, so the populations never change while the "
        r"polarisation figure opens from a \(+45^\circ\) line into a circle and closes again "
        r"onto the \(-45^\circ\) line. Panel: " + _PSI + r"."
    ),
}


def pick_bloch_demo(low: str) -> str:
    if "hadamard" in low or "superposition" in low:
        return "hadamard"
    if "pauli-x" in low or "pauli x" in low:
        return "xflip"
    if "rotation" in low or "rx" in low or "wave plate" in low:
        return "rx"
    if "cheat sheet" in low:
        return "sphase"
    if "universal quantum operation" in low:
        return "hadamard"
    return "precess"


def figure_for(title: str) -> str:
    global _BLOCH_USED
    low = title.lower()
    want = bool(
        re.search(
            r"quantum bit|hadamard|rotation gate|cheat sheet|universal quantum operation|pauli-x|bloch",
            low,
        )
    )
    if not want or _BLOCH_USED >= 5:
        return ""
    _BLOCH_USED += 1
    demo = pick_bloch_demo(low)
    cap = BLOCH_DEMOS[demo]
    return (
        f'<figure class="diagram bloch-fig">\n'
        f'<div class="bloch-stage" data-demo="{demo}"></div>\n'
        f"<figcaption>{cap}</figcaption>\n"
        f"</figure>"
    )


# Static gate atlases. These are the "figure of understanding" half of the gate
# visuals: no animation, just before -> after -> what changed, laid out as a grid
# of cards by js/gate-figure.js. The modal behind each card is opened from here
# or from any dotted-underlined gate name in the prose.
GATE_ATLASES = [
    (
        r"universal quantum operation|quick reference guide",
        "<figure class=\"diagram gate-atlas-fig\">\n<div class=\"gate-atlas\" data-gates=\"I X Y Z H S T Rx Ry Rz\"></div>\n<figcaption>Every single-qubit operation drawn as a <strong>difference</strong>. The dim dashed arrow is the input state, the bright arrow the output, the amber arc the rotation that carries one to the other, and the cyan dashed line the axis it turns about. The bars compare the Prime population \\(P\\) before and after, so a gate that writes only phase is visibly a gate that leaves \\(P\\) alone. Nothing moves: these are figures, not animations. Click any card — or any dotted gate name in the text — for the full panel, where the input state is selectable, \\(\\theta\\) is a slider for the rotation families, and the change can be replayed or scrubbed.</figcaption>\n</figure>",
    ),
    (
        r"classical reversible ope",
        "<figure class=\"diagram gate-atlas-fig\">\n<div class=\"gate-atlas\" data-gates=\"CZ CNOT SWAP Toffoli\"></div>\n<figcaption>The reversible multi-qubit gates have <strong>no single-qubit Bloch arrow at all</strong>, so the honest figure is the basis-amplitude table: the rows that move are highlighted, the rows that stay are dimmed, and the C line underneath is the same operation as a reversible assignment. For the two-qubit gates the single-qubit purity \\(|\\mathbf r|\\) is reported before and after — when it falls below 1 the gate has entangled the pair, both arrows have collapsed toward the centre of the ball, and neither qubit has a state of its own any more. That collapse is why the arrow picture has to be abandoned here rather than stretched.</figcaption>\n</figure>",
    ),
]


def atlas_for(title: str) -> str:
    low = title.lower()
    for pat, block in GATE_ATLASES:
        if re.search(pat, low):
            return block
    return ""


def strip_question_chrome(s: str) -> str:
    s = re.sub(r"<p class=\"role\">.*?</p>", "", s)
    s = re.sub(r"^</p>\s*", "", s)
    s = re.sub(r"<p>\s*</p>", "", s)
    return s


def main() -> None:
    raw = SRC.read_text(encoding="utf-8", errors="replace")
    body = strip_junk(extract_body(raw))
    _, turns = split_turns(body)
    toc_items = []
    blocks = []
    used_slugs: set[str] = set()
    used_titles: set[str] = set()
    chap = 0
    global _BLOCH_USED
    _BLOCH_USED = 0

    for role, content in turns:
        if role != "ASSISTANT":
            continue
        raw_ans = content.strip()
        if plain_len(raw_ans) < 480:
            continue
        ans = canonize_terms(convert_pipe_tables(wrap_math(raw_ans)))
        ans = strip_question_chrome(ans)
        title = first_heading(ans)
        if not title:
            title = first_text(ans, 72)
        title = re.sub(r"^\d+\.\s*", "", title)
        title = re.sub(r"\s+", " ", title).strip(" .")
        low = title.lower()
        if re.search(
            r"my personal|favorite three|favorite three from|top-3|top 3 |top 4 |top 5 |"
            r"rename history|roll off the tongue|i would actually|"
            r"why the names|new batch|dominance in ai|short answer first|"
            r"^is |^would |^could |^can you",
            low,
        ):
            continue
        key = re.sub(r"[^a-z0-9]+", "", title.lower())[:48]
        if key in used_titles:
            continue
        used_titles.add(key)
        chap += 1
        sid = slugify(title, used_slugs)
        # promote first heading to the chapter title if present
        ans, nsub = re.subn(
            r"<h[2-4][^>]*>.*?</h[2-4]>",
            "",
            ans,
            count=1,
            flags=re.I | re.S,
        )
        toc_items.append(f'    <li><a href="#{sid}">{html.escape(title)}</a></li>')
        ans = repair_math(mathify_outside_code(ans))
        fig = figure_for(title) + atlas_for(title)
        blocks.append(
            f'<section class="chapter" id="{sid}">'
            f"<h2>{html.escape(title)}</h2>{fig}{ans}</section>"
        )

    body_html = "\n".join(blocks)
    replacements = [
        (
            "Microsoft (Majorana 1 prototype for topological qubits).",
            "Microsoft topological work ongoing (Majorana 1 chip announced Feb 2025, not 2023).",
        ),
        (
            "e.g., IBM's 4,000-qubit goal by 2025 end",
            "e.g., IBM's Nighthawk (120 qubits) and Starling ~2029 logical-qubit target—not a 4,000-qubit 2025 chip",
        ),
        (
            "reaching 12 entangled logical qubits (Microsoft/Quantinuum).",
            "reaching a 2024 Microsoft/Quantinuum demonstration of 12 logical qubits (not a 2025-only event).",
        ),
        (
            "Quantinuum's Helios: 56+ qubits supporting 10+ logical qubits.",
            "Quantinuum Helios (late-2025 H-series successor; vendor qubit/logical counts should be read from the paper, not the headline).",
        ),
        (
            "10–100× faster drug candidate screening",
            "research-scale electronic-structure demos (not a proven 10–100× production screen)",
        ),
        (
            "5–20 % better solutions on hard problems",
            "possible heuristic gains on selected instances; not a general proven margin",
        ),
        (
            "Willow benchmark (5 min vs. 10^25 years classical)",
            "Willow RCS benchmark (Google claim: &lt;5 min vs. 10^25 yr classical; contested hardness, not a useful-app advantage)",
        ),
        (
            "These are the literal equations running inside every photonic quantum computer in 2025.",
            "These Maxwell / Jones sketches are the standard optical-table picture; the sin³/cos³ labels used elsewhere in this thread are a pedagogical overlay, not the chip compiler’s native basis.",
        ),
        (
            "When you write <code>qc.h(0); qc.cx(0,1)</code> in Qiskit or Pennylane, the compiler turns it into a sequence of beam-splitter ratios, wave-plate angles, and path lengths that make Euclidean space do exactly the transformations above.",
            "On a photonic backend the compiler maps gates to interferometer settings; on superconducting or ion backends the same Qiskit line becomes microwave pulses or laser Raman drives—not wave plates.",
        ),
    ]
    for old, new in replacements:
        body_html = body_html.replace(old, new)
    html_out = (
        TEMPLATE.replace("{css}", CSS)
        .replace("{toc}", "\n".join(toc_items))
        .replace("{body}", body_html)
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html_out, encoding="utf-8")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes), chapters={chap}")


if __name__ == "__main__":
    main()
