#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Push this OpenWrt overlay through the existing testharness SSH transport."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REMOTE_DIR = "/opt/testharness/cache/openwrt-overlay"
REMOTE_NEW = REMOTE_DIR + ".new"
REMOTE_TAR = "/tmp/g6lc-openwrt-overlay.tar"


def load_proxy():
    root = HERE
    while root != root.parent:
        cand = root / "verif" / "regress" / "remote" / "testharness_proxy.py"
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("th_proxy", cand)
            mod = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            spec.loader.exec_module(mod)
            return mod
        root = root.parent
    sys.exit("testharness_proxy.py not found walking up from " + str(HERE))


def main() -> int:
    mod = load_proxy()
    rem = mod.Remote(mod.HOST)
    rem.timeout = 180.0
    with tempfile.TemporaryDirectory(prefix="g6lc-openwrt-overlay-") as td:
        tar_path = Path(td) / "overlay.tar"
        subprocess.run(
            [
                "tar",
                "-cf",
                str(tar_path),
                "--exclude=remote-kconfig-fail.txt",
                "--exclude=__pycache__",
                "-C",
                str(HERE),
                ".",
            ],
            check=True,
        )
        try:
            rem.start_master()
            res = rem.run(
                f"rm -rf {REMOTE_NEW} && mkdir -p {REMOTE_NEW} {REMOTE_DIR}",
                check=False,
                capture=True,
            )
            if res.returncode != 0:
                sys.stderr.write(res.stderr or res.stdout or "")
                return int(res.returncode)
            scp = subprocess.run(
                ["scp", *rem.base_opts(), str(tar_path), f"{rem.host}:{REMOTE_TAR}"],
                check=False,
                capture_output=True,
                text=True,
            )
            if scp.returncode != 0:
                sys.stderr.write(scp.stderr or scp.stdout or "")
                return int(scp.returncode)
            res = rem.run(
                " && ".join(
                    [
                        f"tar -xf {REMOTE_TAR} -C {REMOTE_NEW}",
                        f"rsync -a --delete {REMOTE_NEW}/ {REMOTE_DIR}/",
                        f"rm -rf {REMOTE_NEW} {REMOTE_TAR}",
                        f"find {REMOTE_DIR} -maxdepth 2 -type f | sort",
                    ]
                ),
                check=False,
                capture=True,
            )
            sys.stdout.write(res.stdout or "")
            sys.stderr.write(res.stderr or "")
            if res.returncode == 0:
                print("PUSH_OVERLAY_OK")
            return int(res.returncode)
        finally:
            rem.close()


if __name__ == "__main__":
    raise SystemExit(main())
