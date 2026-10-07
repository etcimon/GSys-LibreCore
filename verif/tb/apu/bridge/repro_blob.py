#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""repro_blob.py — bisect the kernel's CREATE_BLOB -> ERR_PARAM observed
under the stock Ubuntu guest (3d-b).  Sends the exact wire shape
virtio_gpu_cmd_resource_create_blob produces and varies one field at a
time.  Run:  python3 repro_blob.py   (needs obj_venus/apu_bridge)"""
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import bridge_selftest as st


def chain(cl, mem, req_words, resp_cap=64, desc_slots=[0, 1], ring=0,
          rq=0, rnum=None):
    """One ctrl chain: desc0 = request (device-read), desc1 = response
    (device-write).  Returns the response words."""
    n = rnum or st.VN["VN_Q0_NUM"]
    base_a = st.VN["VN_Q0_DESC"]
    a_buf = 0x80000000 + 0x40000     # request buffer in guest DRAM
    r_buf = 0x80000000 + 0x41000
    bs = b"".join(struct.pack("<I", w) for w in req_words)
    mem.w(a_buf, bs)
    mem.w(r_buf, b"\xcc" * resp_cap)
    st_wait = time.time()
    # desc table
    mem.w(base_a, struct.pack("<QIHH", a_buf, len(bs), 1, 1))
    mem.w(base_a + 16, struct.pack("<QIHH", r_buf, resp_cap, 2, 0))
    # avail: flags(2) idx(2) ring[num]
    ab = st.VN["VN_Q0_AVAIL"]
    idx = mem.r16(ab + 2)
    mem.w16(ab + 4 + 2 * (idx % n), 0)
    mem.w16(ab + 2, idx + 1)
    ub = st.VN["VN_Q0_USED"]
    uidx = mem.r16(ub + 2)
    cl.mmio_wr(st.VN["VREG_QUEUE_NOTIFY"], rq)
    # wait used
    while mem.r16(ub + 2) == uidx:
        cl.pump(0.01)
        if time.time() - st_wait > 60:
            raise RuntimeError("used.idx timeout")
    uid = mem.r32(ub + 4 + 8 * (uidx % n))
    ulen = mem.r32(ub + 8 + 8 * (uidx % n))
    # irq ack
    isr = cl.mmio_rd(st.VN["VREG_INTERRUPT_STATUS"])
    if isr & 1:
        cl.mmio_wr(st.VN["VREG_INTERRUPT_ACK"], 1)
    rb = mem.r(r_buf, min(ulen, resp_cap))
    return [w for w in struct.unpack("<%dI" % (len(rb) // 4), rb)], ulen


def main():
    srv = st.run_server("/tmp/g6lc-apu-bridge/obj_venus/apu_bridge",
                        "/tmp/g6lc-apu-rtl.sock",
                        "/tmp/g6lc-apu-bridge/server-repro.log")
    try:
        mem = st.Mem()
        cl = st.Client(mem)
        cl.connect("/tmp/g6lc-apu-rtl.sock")
        st.VN = st.load_map("/tmp/g6lc-apu-bridge/bridge_map.h")
        st.probe(cl, venus=True)
        print("probe OK")

        def run(label, words):
            r, ulen = chain(cl, mem, words)
            print(f"{label}: ulen={ulen} resp={[hex(w) for w in r[:10]]}")

        # CTX_CREATE ctx=2, context_init=4 (kernel venus context)
        name = b"vn\x00" + b"\x00" * 61
        nw = [int.from_bytes(name[4 * i:4 * i + 4], "little")
              for i in range(16)]
        run("ctx_create ctx=2", [0x0200, 0, 0, 0, 2, 0, 2, 4] + nw)

        # CREATE_BLOB kernel shape: rid, blob_mem=2, flags=1, nr=0,
        # blob_id=0, size=4096
        for ctx in (2, 4, 0):
            run(f"create_blob ctx={ctx} m=2 f=1 sz=4096 id=0",
                [0x010C, 0, 0, 0, ctx, 0,
                 0x11, 2, 1, 0, 0, 0, 4096, 0])
        # flag variants incl. SHAREABLE/CROSS as venus may set them
        run("create_blob f=3", [0x010C, 0, 0, 0, 2, 0,
                                0x12, 2, 3, 0, 0, 0, 4096, 0])
        # blob_id != 0 (device-memory blob): id = some value
        run("create_blob id=1 sz=4096", [0x010C, 0, 0, 0, 2, 0,
                                       0x13, 2, 1, 0, 1, 0, 4096, 0])
        # bisect the aperture limit
        for sz in (65536, 262144, 524288, 1048576, 2097152, 4194304):
            run(f"create_blob sz={sz}", [0x010C, 0, 0, 0, 2, 0,
                                         0x14, 2, 1, 0, 0, 0, sz, 0])
    finally:
        srv.terminate()
        srv.wait(timeout=10)


if __name__ == "__main__":
    main()
