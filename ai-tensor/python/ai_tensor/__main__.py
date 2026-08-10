# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""python -m ai_tensor — smoke without torch."""

from pathlib import Path

from .c_abi import PLIC_SOURCE_ISLAND_P3, pack_desc64, verify_header_present
from .device import Device, pack_gemm_desc
from .golden import run_golden_suite
from .probe import probe_dict
from .profile import Profile


def main() -> None:
    d = pack_gemm_desc(8, 8, 8)
    assert len(d) == 64
    print(f"desc_bytes={len(d)} header={d[:8].hex()}")
    d2 = pack_desc64(8, 8, 8, 0x1000, 0x2000, 0x3000, 0x4000)
    assert len(d2) == 64
    assert verify_header_present()
    print(f"c_abi_header=ok plic={PLIC_SOURCE_ISLAND_P3}")

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
        ddev = Device.from_profile(str(prof))
        print(
            f"profile id={p.id} backend={p.backend} device={ddev.backend} "
            f"tile={ddev.caps().acc_tile_m}x{ddev.caps().acc_tile_n}x{ddev.caps().acc_tile_k} "
            f"wait={p.wait_policy} submit={p.submit_mode}"
        )
        pr = probe_dict(device=ddev, profile=p)
        print(f"probe package={pr['package']} plic={pr['plic_source']} backend={pr['backend']}")
    print("ok")


if __name__ == "__main__":
    main()
