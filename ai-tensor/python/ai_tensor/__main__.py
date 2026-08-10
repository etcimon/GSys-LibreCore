# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""python -m ai_tensor — smoke without torch."""

from pathlib import Path

from .device import Device, pack_gemm_desc
from .golden import run_golden_suite
from .profile import Profile


def main() -> None:
    d = pack_gemm_desc(8, 8, 8)
    assert len(d) == 64
    print(f"desc_bytes={len(d)} header={d[:8].hex()}")

    dev = Device("sim")
    a = [1, 2, 3, 4]
    b = [5, 6, 7, 8]
    c, ticket, status, meta = dev.gemm_s8(2, 2, 2, a, b, ticket=9)
    print(f"backend={dev.backend} ticket={ticket} status={status} c={c} meta_tiles={meta.get('tiles')}")
    assert status == 0
    assert c == [19, 22, 43, 50]

    n = run_golden_suite(backends=("sim",))
    print(f"golden_suite count={n}")

    root = Path(__file__).resolve().parents[2]
    prof = root / "profiles" / "island-p3-v1.toml"
    if prof.is_file():
        p = Profile.load_file(prof)
        d2 = Device.from_profile(str(prof))
        print(
            f"profile id={p.id} backend={p.backend} device={d2.backend} "
            f"tile={d2.caps().acc_tile_m}x{d2.caps().acc_tile_n}x{d2.caps().acc_tile_k}"
        )
    print("ok")


if __name__ == "__main__":
    main()
