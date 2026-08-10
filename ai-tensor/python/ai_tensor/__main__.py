# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""python -m ai_tensor — smoke without torch."""

from .device import Device, pack_gemm_desc


def main() -> None:
    d = pack_gemm_desc(8, 8, 8)
    assert len(d) == 64
    print(f"desc_bytes={len(d)} header={d[:8].hex()}")

    dev = Device("sim")
    a = [1, 2, 3, 4]
    b = [5, 6, 7, 8]
    c, ticket, status = dev.gemm_s8(2, 2, 2, a, b, ticket=9)
    print(f"backend={dev.backend} ticket={ticket} status={status} c={c}")
    assert status == 0
    assert c == [19, 22, 43, 50]
    print("ok")


if __name__ == "__main__":
    main()
