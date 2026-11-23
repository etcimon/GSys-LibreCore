# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Screen archived MC source evidence; model joint span, never substitute it for cycles/s."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from g6lc_pack_wrapped_columns import lower_wrapped
from g6lc_sentinel_index import read_rounds, scenario


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ("postpack", "tile_manifest", "class_header"):
        ap.add_argument(name, type=Path)
    ap.add_argument("captures", type=Path, nargs="+")
    args = ap.parse_args()
    attr = json.loads((args.postpack / "attrib.json").read_text())
    src = json.loads((args.postpack / "source.json").read_text())
    manifest = json.loads(args.tile_manifest.read_text())
    hdr = args.class_header.read_text()
    by_path = {}
    for symbol, (_, writes, *_) in src["fn"].items():
        path = Path(src["source"][symbol])
        if (path.with_suffix(".o").name not in manifest["words_by_object"]
                and any(field == "age_col" for field, _ in writes)):
            by_path.setdefault(path, []).append(symbol)
    matched = {}
    for path, symbols in sorted(by_path.items()):
        text = path.read_text()
        for n in symbols:
            match = re.search(r"\bvoid " + re.escape(n) + r"\([^\n]*\) \{", text)
            if not match:
                raise ValueError(f"no definition of {n} in {path}")
            # Include the brace: it is the first legal batch boundary.
            body = text[match.end()-1:text.index("\n}", match.end())+2]
            _, hits = lower_wrapped(body, hdr)
            if hits:
                matched[n] = dict(tu=path.name, words=hits)
    scales = {}
    for group, weights in attr["stats"].items():
        task = re.fullmatch(r"cycles:t(\d+)", group)
        if task:
            relevant = sum(v for n, v in weights.items() if n in matched)
            if relevant:
                scales[int(task[1])] = 1 - 0.5*relevant/sum(weights.values())
    print(json.dumps(dict(packed_baseline=manifest["control"], tiled_manifest=manifest["candidate"],
                          profile_sha256=hashlib.sha256((args.postpack/"attrib.json").read_bytes()).hexdigest(),
                          matched=matched, retained_body=scales,
                          assumption="unchanged TU; packed within-task cycle shares transfer; "
                                     "whole matched callees halve, not just matched expressions",
                          scenarios=[dict(capture=str(p), **scenario(
                              attr, read_rounds(p, attr["seq"]), scales)) for p in args.captures]
                          if scales else []), indent=2))


if __name__ == "__main__":
    main()
