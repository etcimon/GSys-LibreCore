// SPDX-License-Identifier: MIT
//! Emit `hw/riscv/g6lc-<target>-apu-bridge.c`, the QEMU side of the APU
//! RTL-in-the-loop bridge.
//!
//! The emitted device is a sysbus device with one MMIO region covering the
//! APU's virtio-mmio window and one IRQ output. It connects to the Verilator
//! `tb_g6lc_apu_bridge` server over a Unix stream socket and forwards:
//!
//!   - guest MMIO reads/writes as request/reply frames,
//!   - the device's AXI DMA bursts as DMA_RD/DMA_WR requests served from
//!     `address_space_memory` (the guest's RAM), and
//!   - the device's IRQ level as IRQ frames driving `qemu_set_irq`.
//!
//! Wire protocol (little-endian, length-prefixed; see
//! `verif/tb/apu/bridge/bridge_main.cpp` for the peer):
//!
//!   frame: u32 len (bytes after this field), u8 type, u8 flags, u16 seq
//!   QEMU->RTL  0x01 MMIO_RD {u32 off}               -> 0x81 {u32 data, u8 err}
//!              0x02 MMIO_WR {u32 off,u32 data,u8 s} -> 0x82 {u8 err}
//!   RTL->QEMU  0x11 DMA_RD  {u64 addr,u32 len}       -> 0x91 {u8 err, bytes[len]}
//!              0x12 DMA_WR  {u64 addr,u32 len,
//!                            bytes[len],strb[ceil(len/8)]} -> 0x92 {u8 err}
//!              0x13 IRQ     {u8 level}               (no reply)
//!
//! `off` is a byte offset inside the MMIO window (the server adds the window
//! base). `strb` carries one bit per payload byte. Both directions tolerate
//! interleaving: the MMIO wait loop keeps servicing DMA/IRQ frames until the
//! reply carrying its own sequence number arrives.
//!
//! The socket path is the `sock` property; unset, it falls back to the
//! `G6LC_APU_RTL_SOCK` environment variable and then the protocol default.
//! It is deliberately not model state — it describes where a particular run
//! finds the RTL server, not anything the design publishes.

use crate::machine::machine_name;
use crate::{Emission, EmittedFile};
use g6q_core::model::{ApuModel, TargetModel};

/// Whether the model wants the bridge device emitted and instantiated.
///
/// Both halves are required: `soc.apu` is the ingested geometry and
/// `soc.apu_bridge` is the machine-profile flag that selects it.
pub fn enabled(model: &TargetModel) -> bool {
    model.soc.apu_bridge && model.soc.apu.is_some()
}

/// The QOM type name the machine creates the device by.
pub fn qom_type(model: &TargetModel) -> String {
    format!("g6lc-{}-apu-bridge", machine_name(&model.target_id))
}

fn c_ident(model: &TargetModel) -> String {
    format!("g6lc_{}_apu_bridge", machine_name(&model.target_id))
}

/// Emit `hw/riscv/g6lc-<target>-apu-bridge.c`.
pub fn emit_bridge_c(model: &TargetModel, version: &str, digest: &str) -> Option<EmittedFile> {
    if !enabled(model) {
        return None;
    }
    let apu: &ApuModel = model.soc.apu.as_ref()?;
    let name = machine_name(&model.target_id);
    let id = c_ident(model);
    let upper = id.to_uppercase();
    let type_name = qom_type(model);

    let body = format!(
        r###"
/*
 * Generated APU RTL bridge device for the {type_name} machine.
 *
 * This device is the QEMU half of the APU RTL-in-the-loop bridge: guest
 * accesses to the APU virtio-mmio window are forwarded to a Verilator
 * simulation of the real g6lc_apu_sys, and the device's DMA bursts are served
 * from guest RAM. The socket peer is `verif/tb/apu/bridge/bridge_main.cpp`.
 *
 * Window geometry (from the model's `soc.apu` block, which ingest reads out
 * of g6lc_apu_cfg_pkg.sv's ApuVenus literal and g6lc_apu_pkg.sv):
 *
 *   virtio-mmio window : 0x{mmio_base:x} .. +0x{mmio_len:x}
 *   PLIC source        : {irq}
 *   DMA window         : 0x{dma_base:x} .. +0x{dma_len:x}
 *   shared aperture    : 0x{shm_base:x} .. +0x{shm_len:x} (SHM id {shm_id},
 *                        kept as RAM in this machine and reserved in the FDT)
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/main-loop.h"
#include "qemu/sockets.h"
#include "qemu/thread.h"
#include "qapi/error.h"
#include "hw/qdev-properties.h"
#include "hw/sysbus.h"
#include "hw/irq.h"
#include "exec/memory.h"
#include "exec/address-spaces.h"
#include "system/dma.h"

#define TYPE_{upper} "{type_name}"
OBJECT_DECLARE_SIMPLE_TYPE({Upper}State, {upper})

/* MMIO window length published by the APU configuration. */
#define {upper}_MMIO_LEN {mmio_len}ULL

/* Maximum DMA frame payload (one AXI burst, per the bridge protocol). */
#define {upper}_DMA_MAX 4096

/* Receive queue capacity: one maximal frame plus headroom. */
#define {upper}_RX_CAP ({upper}_DMA_MAX + 512 + 12)

/* Frame types, shared with the RTL server. QEMU->RTL requests carry 0x0x,
 * their replies 0x8x; RTL->QEMU requests carry 0x1x with replies 0x9x. */
enum {{
    {upper}_T_MMIO_RD   = 0x01,
    {upper}_T_MMIO_WR   = 0x02,
    {upper}_T_MMIO_RD_R = 0x81,
    {upper}_T_MMIO_WR_R = 0x82,
    {upper}_T_DMA_RD    = 0x11,
    {upper}_T_DMA_WR    = 0x12,
    {upper}_T_DMA_RD_R  = 0x91,
    {upper}_T_DMA_WR_R  = 0x92,
    {upper}_T_IRQ       = 0x13,
}};

struct {Upper}State {{
    SysBusDevice parent_obj;

    MemoryRegion mmio;
    qemu_irq irq;
    int fd;                     /* connected socket, or -1 */
    int dead_fd;                /* fd dropped by a vCPU-side kill; fd_read reaps it */
    char *sock;                 /* "sock" property; NULL -> env/default */

    /*
     * Socket access discipline. io_lock serializes every byte in and out.
     * Two readers exist — the vCPU thread inside an MMIO wait, and the
     * main loop's fd handler — but only one holds the lock at a time and
     * inbound bytes are queued in rx_buf, so a frame can never be split
     * between readers. While a vCPU waits for an MMIO reply it keeps the
     * lock and services interleaved DMA/IRQ frames itself (the protocol
     * requires this: the device may be mid-burst); the main loop's trylock
     * then fails and fd_read returns, leaving the bytes for the waiter —
     * the fd stays readable, so the handler refires until the wait ends,
     * costing a bounded spin for each RTL round trip.
     */
    QemuMutex io_lock;
    uint8_t rx_buf[{upper}_RX_CAP + 8];
    size_t rx_len;
    uint16_t seq;               /* next MMIO request sequence number */
    uint16_t want_seq;          /* seq of the MMIO request being awaited */
    uint8_t want_type;          /* its reply type; 0 when no wait is active */
    int reply_ready;            /* dispatch found the awaited reply */
    uint8_t reply[8];
    uint32_t reply_len;

    /* Run statistics, printed from finalize. */
    uint64_t n_mmio_rd, n_mmio_wr;
    uint64_t n_dma_rd, n_dma_wr, dma_bytes, n_irq;
}};

static uint32_t {id}_le32(const uint8_t *p)
{{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}}

static uint64_t {id}_le64(const uint8_t *p)
{{
    return (uint64_t){id}_le32(p) | ((uint64_t){id}_le32(p + 4) << 32);
}}

static int {id}_send_frame({Upper}State *s, uint8_t type, uint16_t seq,
                            const void *payload, size_t plen)
{{
    uint8_t hdr[8];
    hdr[0] = (uint8_t)(plen + 4);
    hdr[1] = (uint8_t)((plen + 4) >> 8);
    hdr[2] = (uint8_t)((plen + 4) >> 16);
    hdr[3] = (uint8_t)((plen + 4) >> 24);
    hdr[4] = type;
    hdr[5] = 0;
    hdr[6] = (uint8_t)seq;
    hdr[7] = (uint8_t)(seq >> 8);
    if (qemu_send_full(s->fd, hdr, sizeof(hdr)) != sizeof(hdr)) {{
        return -1;
    }}
    if (plen && qemu_send_full(s->fd, payload, plen) != (ssize_t)plen) {{
        return -1;
    }}
    return 0;
}}

/*
 * Kill the connection from any thread, io_lock held. Handler removal and
 * close happen on the main loop (fd_read reaps dead_fd, woken by the
 * shutdown), because qemu_set_fd_handler is main-loop business. A waiting
 * MMIO roundtrip observes fd < 0 / reply_ready and returns a failure.
 */
static void {id}_kill_locked({Upper}State *s, const char *why)
{{
    if (s->fd < 0) {{
        return;
    }}
    s->dead_fd = s->fd;
    s->fd = -1;
    shutdown(s->dead_fd, SHUT_RDWR);
    s->reply_ready = 1;
    error_report("%s: RTL socket dropped (%s); APU MMIO now returns bus errors",
                 TYPE_{upper}, why);
}}

/*
 * Service one device->QEMU frame. Payloads are validated against the frame
 * length the peer announced; malformed frames drop the connection rather
 * than serve a truncated DMA. io_lock is held.
 */
static void {id}_device_frame({Upper}State *s, uint8_t type, uint16_t seq,
                               const uint8_t *pl, uint32_t len)
{{
    uint8_t reply[1 + {upper}_DMA_MAX];
    uint8_t err;

    switch (type) {{
    case {upper}_T_DMA_RD: {{
        if (len != 12) {{
            {id}_kill_locked(s, "short DMA_RD");
            return;
        }}
        uint64_t addr = {id}_le64(pl);
        uint32_t n = {id}_le32(pl + 8);
        if (n > {upper}_DMA_MAX) {{
            {id}_kill_locked(s, "oversized DMA_RD");
            return;
        }}
        err = address_space_rw(&address_space_memory, addr,
                               MEMTXATTRS_UNSPECIFIED, reply + 1, n, false)
                  ? 1 : 0;
        reply[0] = err;
        if ({id}_send_frame(s, {upper}_T_DMA_RD_R, seq, reply, 1 + n)) {{
            {id}_kill_locked(s, "DMA_RD reply send");
            return;
        }}
        s->n_dma_rd++;
        s->dma_bytes += n;
        break;
    }}
    case {upper}_T_DMA_WR: {{
        if (len < 12) {{
            {id}_kill_locked(s, "short DMA_WR");
            return;
        }}
        uint64_t addr = {id}_le64(pl);
        uint32_t n = {id}_le32(pl + 8);
        uint32_t strb_len = (n + 7) / 8;
        if (n > {upper}_DMA_MAX || len != 12 + n + strb_len) {{
            {id}_kill_locked(s, "bad DMA_WR framing");
            return;
        }}
        const uint8_t *bytes = pl + 12;
        const uint8_t *strb = bytes + n;
        err = 0;
        /* Strb is one bit per payload byte; write contiguous set runs. */
        uint32_t i = 0;
        while (i < n) {{
            while (i < n && !(strb[i >> 3] & (1u << (i & 7)))) {{
                i++;
            }}
            uint32_t run = i;
            while (i < n && (strb[i >> 3] & (1u << (i & 7)))) {{
                i++;
            }}
            if (i > run &&
                address_space_rw(&address_space_memory, addr + run,
                                 MEMTXATTRS_UNSPECIFIED,
                                 (void *)(bytes + run), i - run, true)) {{
                err = 1;
                break;
            }}
        }}
        if ({id}_send_frame(s, {upper}_T_DMA_WR_R, seq, &err, 1)) {{
            {id}_kill_locked(s, "DMA_WR reply send");
            return;
        }}
        s->n_dma_wr++;
        s->dma_bytes += n;
        break;
    }}
    case {upper}_T_IRQ:
        if (len != 1) {{
            {id}_kill_locked(s, "short IRQ");
            return;
        }}
        s->n_irq++;
        qemu_set_irq(s->irq, pl[0]);
        break;
    default:
        error_report("%s: unexpected frame type 0x%02x seq %u",
                     TYPE_{upper}, type, seq);
        break;
    }}
}}

/*
 * Drain complete frames out of rx_buf. MMIO replies land in the mailbox
 * when they match the request a vCPU is awaiting; DMA/IRQ frames are
 * serviced inline by whichever reader holds io_lock. io_lock is held.
 */
static void {id}_dispatch_locked({Upper}State *s)
{{
    for (;;) {{
        uint32_t len, pay;
        uint8_t type;
        uint16_t seq;

        if (s->rx_len < 8) {{
            return;
        }}
        len = {id}_le32(s->rx_buf);
        if (len < 4 || len > {upper}_RX_CAP) {{
            {id}_kill_locked(s, "bad frame length");
            s->rx_len = 0;
            return;
        }}
        if (s->rx_len < 4 + len) {{
            return;     /* incomplete frame; more bytes may follow */
        }}
        type = s->rx_buf[4];
        seq = (uint16_t)(s->rx_buf[6] | (s->rx_buf[7] << 8));
        pay = len - 4;

        if ((type == {upper}_T_MMIO_RD_R || type == {upper}_T_MMIO_WR_R) &&
            type == s->want_type && seq == s->want_seq) {{
            s->reply_len = pay < sizeof(s->reply) ? pay : (uint32_t)sizeof(s->reply);
            memcpy(s->reply, s->rx_buf + 8, s->reply_len);
            s->reply_ready = 1;
        }} else if (type == {upper}_T_DMA_RD || type == {upper}_T_DMA_WR ||
                    type == {upper}_T_IRQ) {{
            {id}_device_frame(s, type, seq, s->rx_buf + 8, pay);
            if (s->fd < 0) {{
                s->rx_len = 0;
                return;
            }}
        }} else {{
            /* A reply we never asked for: the peer confused the sequence. */
            error_report("%s: stray reply type 0x%02x seq %u",
                         TYPE_{upper}, type, seq);
        }}
        memmove(s->rx_buf, s->rx_buf + 4 + len, s->rx_len - (4 + len));
        s->rx_len -= 4 + len;
    }}
}}

/*
 * Append whatever the socket offers to rx_buf. blocking != 0 waits for at
 * least one byte (used by the vCPU wait loop); blocking == 0 drains until
 * EAGAIN (used by the fd handler). Returns 1 when bytes arrived, 0 when
 * nothing was pending, -1 on EOF or error. io_lock is held.
 */
static int {id}_recv_into_buf({Upper}State *s, int blocking)
{{
    for (;;) {{
        ssize_t n;
        if (s->rx_len >= sizeof(s->rx_buf)) {{
            return -1;
        }}
        n = recv(s->fd, s->rx_buf + s->rx_len,
                 sizeof(s->rx_buf) - s->rx_len, blocking ? 0 : MSG_DONTWAIT);
        if (n > 0) {{
            s->rx_len += (size_t)n;
            return 1;
        }}
        if (n == 0) {{
            return -1;
        }}
        if (errno == EINTR) {{
            continue;
        }}
        if (!blocking && (errno == EAGAIN || errno == EWOULDBLOCK)) {{
            return 0;
        }}
        return -1;
    }}
}}

/* Main-loop callback: the server pushed DMA/IRQ frames while QEMU idles. */
static void {id}_fd_read(void *opaque)
{{
    {Upper}State *s = opaque;
    int dead = 0;

    /* A vCPU MMIO wait owns the socket right now; leave the bytes for it.
     * qemu_mutex_trylock returns 0 on success, -EBUSY on contention. */
    if (qemu_mutex_trylock(&s->io_lock)) {{
        return;
    }}
    if (s->dead_fd >= 0) {{
        qemu_set_fd_handler(s->dead_fd, NULL, NULL, NULL);
        qemu_close(s->dead_fd);
        s->dead_fd = -1;
    }}
    if (s->fd >= 0) {{
        for (;;) {{
            int rc = {id}_recv_into_buf(s, 0);
            if (rc <= 0) {{
                dead = rc < 0;
                break;
            }}
            {id}_dispatch_locked(s);
            if (s->fd < 0) {{
                dead = 1;
                break;
            }}
        }}
        if (dead) {{
            qemu_set_fd_handler(s->fd, NULL, NULL, NULL);
            qemu_close(s->fd);
            s->fd = -1;
            s->reply_ready = 1;
            error_report("%s: RTL socket closed by peer; "
                         "APU MMIO now returns bus errors", TYPE_{upper});
        }}
    }}
    qemu_mutex_unlock(&s->io_lock);
}}

/*
 * Send one MMIO request and wait for its reply, servicing interleaved
 * DMA/IRQ frames so the device's in-flight bursts do not deadlock the access
 * that triggered them. Returns 0 with the reply payload in `out`.
 */
static int {id}_mmio_roundtrip({Upper}State *s, uint8_t req, uint8_t rsp,
                                const uint8_t *payload, uint32_t plen,
                                uint8_t *out, uint32_t *out_len)
{{
    uint16_t seq;
    int rc = -1;

    qemu_mutex_lock(&s->io_lock);
    if (s->fd < 0) {{
        goto out;
    }}
    seq = s->seq++;
    s->want_seq = seq;
    s->want_type = rsp;
    s->reply_ready = 0;
    if ({id}_send_frame(s, req, seq, payload, plen)) {{
        {id}_kill_locked(s, "mmio send");
        goto out;
    }}
    {id}_dispatch_locked(s);
    while (!s->reply_ready) {{
        if ({id}_recv_into_buf(s, 1) < 0) {{
            {id}_kill_locked(s, "mmio wait");
            goto out;
        }}
        {id}_dispatch_locked(s);
    }}
    if (s->fd < 0) {{
        goto out;
    }}
    if (*out_len > s->reply_len) {{
        *out_len = s->reply_len;
    }}
    memcpy(out, s->reply, *out_len);
    rc = 0;
out:
    s->want_type = 0;
    qemu_mutex_unlock(&s->io_lock);
    return rc;
}}

static uint64_t {id}_mmio_read(void *opaque, hwaddr offset, unsigned size)
{{
    {Upper}State *s = opaque;
    uint8_t req[4], reply[5];
    uint32_t reply_len = sizeof(reply);
    unsigned shift = offset & 3;

    offset &= ~3;
    req[0] = (uint8_t)offset;
    req[1] = (uint8_t)(offset >> 8);
    req[2] = (uint8_t)(offset >> 16);
    req[3] = (uint8_t)(offset >> 24);
    if ({id}_mmio_roundtrip(s, {upper}_T_MMIO_RD, {upper}_T_MMIO_RD_R,
                            req, sizeof(req), reply, &reply_len) ||
        reply_len < 5 || reply[4]) {{
        return ~0ull;
    }}
    s->n_mmio_rd++;
    return ({id}_le32(reply) >> (8 * shift)) & ((1ull << (8 * size)) - 1);
}}

static void {id}_mmio_write(void *opaque, hwaddr offset, uint64_t value,
                             unsigned size)
{{
    {Upper}State *s = opaque;
    uint8_t req[9], reply[1];
    uint32_t reply_len = sizeof(reply);
    unsigned shift = offset & 3;

    offset &= ~3;
    req[0] = (uint8_t)offset;
    req[1] = (uint8_t)(offset >> 8);
    req[2] = (uint8_t)(offset >> 16);
    req[3] = (uint8_t)(offset >> 24);
    value <<= 8 * shift;
    req[4] = (uint8_t)value;
    req[5] = (uint8_t)(value >> 8);
    req[6] = (uint8_t)(value >> 16);
    req[7] = (uint8_t)(value >> 24);
    req[8] = (uint8_t)(((1u << size) - 1) << shift);
    if ({id}_mmio_roundtrip(s, {upper}_T_MMIO_WR, {upper}_T_MMIO_WR_R,
                            req, sizeof(req), reply, &reply_len) ||
        reply_len < 1 || reply[0]) {{
        error_report("%s: MMIO_WR off 0x%" HWADDR_PRIx " failed",
                     TYPE_{upper}, offset);
        return;
    }}
    s->n_mmio_wr++;
}}

static const MemoryRegionOps {id}_mmio_ops = {{
    .read = {id}_mmio_read,
    .write = {id}_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {{
        .min_access_size = 1,
        .max_access_size = 4,
    }},
}};

static void {id}_realize(DeviceState *dev, Error **errp)
{{
    {Upper}State *s = {upper}(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);
    const char *path = s->sock;

    if (!path || !path[0]) {{
        path = getenv("G6LC_APU_RTL_SOCK");
    }}
    if (!path || !path[0]) {{
        path = "/tmp/g6lc-apu-rtl.sock";
    }}

    qemu_mutex_init(&s->io_lock);
    s->fd = -1;
    s->dead_fd = -1;

    sysbus_init_irq(sbd, &s->irq);
    memory_region_init_io(&s->mmio, OBJECT(s), &{id}_mmio_ops, s,
                          "{type_name}", {upper}_MMIO_LEN);
    sysbus_init_mmio(sbd, &s->mmio);

    s->fd = unix_connect(path, errp);
    if (s->fd < 0) {{
        return;
    }}
    qemu_socket_set_block(s->fd);
    qemu_set_fd_handler(s->fd, {id}_fd_read, NULL, s);
}}

static void {id}_finalize(Object *obj)
{{
    {Upper}State *s = {upper}(obj);

    if (s->fd >= 0) {{
        qemu_set_fd_handler(s->fd, NULL, NULL, NULL);
        qemu_close(s->fd);
        s->fd = -1;
    }}
    if (s->dead_fd >= 0) {{
        qemu_set_fd_handler(s->dead_fd, NULL, NULL, NULL);
        qemu_close(s->dead_fd);
        s->dead_fd = -1;
    }}
    fprintf(stderr,
            "%s: mmio_rd=%llu mmio_wr=%llu dma_rd=%llu dma_wr=%llu"
            " dma_bytes=%llu irq=%llu\n",
            TYPE_{upper},
            (unsigned long long)s->n_mmio_rd,
            (unsigned long long)s->n_mmio_wr,
            (unsigned long long)s->n_dma_rd,
            (unsigned long long)s->n_dma_wr,
            (unsigned long long)s->dma_bytes,
            (unsigned long long)s->n_irq);
}}

static const Property {id}_properties[] = {{
    DEFINE_PROP_STRING("sock", {Upper}State, sock),
}};

static void {id}_class_init(ObjectClass *oc, void *data)
{{
    DeviceClass *dc = DEVICE_CLASS(oc);

    device_class_set_props(dc, {id}_properties);
    dc->realize = {id}_realize;
    dc->desc = "g6lc APU RTL bridge (virtio-mmio over a Unix socket)";
}}

static const TypeInfo {id}_info = {{
    .name = TYPE_{upper},
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof({Upper}State),
    .instance_finalize = {id}_finalize,
    .class_init = {id}_class_init,
}};

static void {id}_register(void)
{{
    type_register_static(&{id}_info);
}}

type_init({id}_register)
"###,
        type_name = type_name,
        mmio_base = apu.mmio_base,
        mmio_len = apu.mmio_len,
        irq = apu.irq_source,
        dma_base = apu.dma_window_base,
        dma_len = apu.dma_window_bytes,
        shm_base = apu.shm_base,
        shm_len = apu.shm_bytes,
        shm_id = apu.shm_id,
        upper = upper,
        Upper = to_upper_camel(&id),
        id = id,
    );

    Some(EmittedFile::new(
        format!("hw/riscv/g6lc-{name}-apu-bridge.c"),
        version,
        digest,
        &body,
    ))
}

/// `g6lc_x_apu_bridge` -> `G6lcXApuBridge`.
fn to_upper_camel(snake: &str) -> String {
    let mut out = String::new();
    let mut cap = true;
    for c in snake.chars() {
        if c == '_' {
            cap = true;
            continue;
        }
        if cap {
            out.extend(c.to_uppercase());
            cap = false;
        } else {
            out.push(c);
        }
    }
    out
}

/// Add the bridge device files to an emission.
pub fn emit(model: &TargetModel, version: &str, digest: &str, emission: &mut Emission) {
    if let Some(f) = emit_bridge_c(model, version, digest) {
        emission.push(f);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model_with_apu(bridge: bool) -> TargetModel {
        let mut m = TargetModel::new("g6lc64_test");
        m.soc.apu = Some(ApuModel {
            mmio_base: 0x4000_1000,
            mmio_len: 0x1000,
            control_base: 0x4000_2000,
            control_len: 0x1000,
            irq_source: 9,
            dma_window_base: 0x8000_0000,
            dma_window_bytes: 0x1000_0000,
            shm_base: 0x8200_0000,
            shm_bytes: 0x0010_0000,
            shm_id: 1,
            num_capsets: 1,
            num_scanouts: 0,
            num_queues: 2,
            queue_depth: 64,
        });
        m.soc.apu_bridge = bridge;
        m
    }

    #[test]
    fn nothing_is_emitted_without_the_flag() {
        let m = model_with_apu(false);
        assert!(emit_bridge_c(&m, "0.1.0", "sha256:x").is_none());
    }

    #[test]
    fn nothing_is_emitted_without_the_block() {
        let mut m = TargetModel::new("g6lc64_test");
        m.soc.apu_bridge = true;
        assert!(emit_bridge_c(&m, "0.1.0", "sha256:x").is_none());
    }

    #[test]
    fn the_device_carries_the_model_geometry_and_protocol() {
        let m = model_with_apu(true);
        let f = emit_bridge_c(&m, "0.1.0", "sha256:x").expect("emits");
        assert!(f.header_is_valid());
        assert!(f.path.ends_with("apu-bridge.c"));
        for needle in [
            "g6lc-g6lc64_test-apu-bridge",
            "_MMIO_LEN 4096",
            "unix_connect",
            "qemu_set_fd_handler",
            "qemu_set_irq",
            "address_space_rw",
            "G6LC_APU_RTL_SOCK",
            "DEFINE_PROP_STRING(\"sock\"",
            "0x82000000",
            "qemu_mutex_trylock",
            "MSG_DONTWAIT",
        ] {
            assert!(f.contents.contains(needle), "missing {needle}");
        }
    }
}
