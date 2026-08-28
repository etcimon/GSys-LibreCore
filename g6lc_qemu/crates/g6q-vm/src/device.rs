// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Memory-mapped devices for the g6lc-soc faithful profile.
//!
//! Q3 starts with CLINT (timers and MSIP) and a minimal NS16550a-like UART
//! (transmit-only for console output). PLIC is a later increment.

use std::fmt::Write;

use g6q_core::Json;

fn json_u64(v: u64) -> Json {
    Json::Int(v as i64)
}

fn json_u32(v: u32) -> Json {
    Json::Int(v as i64)
}

fn parse_u64(j: &Json) -> Option<u64> {
    match j {
        Json::Int(i) => Some(*i as u64),
        _ => None,
    }
}

fn parse_u32(j: &Json) -> Option<u32> {
    match j {
        Json::Int(i) => Some(*i as u32),
        _ => None,
    }
}

fn json_uarr(v: &[u64]) -> Json {
    Json::arr(v.iter().map(|x| json_u64(*x)))
}

fn json_u32arr(v: &[u32]) -> Json {
    Json::arr(v.iter().map(|x| json_u32(*x)))
}

fn parse_uarr(j: &Json) -> Option<Vec<u64>> {
    let Json::Arr(items) = j else {
        return None;
    };
    items.iter().map(parse_u64).collect()
}

fn parse_u32arr(j: &Json) -> Option<Vec<u32>> {
    let Json::Arr(items) = j else {
        return None;
    };
    items.iter().map(parse_u32).collect()
}

fn json_hex(v: &[u8]) -> Json {
    Json::str(
        v.iter()
            .fold(String::with_capacity(v.len() * 2), |mut s, b| {
                write!(s, "{b:02x}").unwrap();
                s
            }),
    )
}

fn parse_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    s.as_bytes()
        .chunks(2)
        .map(|c| {
            let t = std::str::from_utf8(c).ok()?;
            u8::from_str_radix(t, 16).ok()
        })
        .collect()
}

/// A memory-mapped device.
pub trait MmioDevice: std::fmt::Debug {
    /// Load a value of `width` bytes (1, 2, 4 or 8) at `offset` from the device base.
    fn load(&self, offset: u64, width: usize) -> u64;
    /// Store `value` (low `width*8` bits) at `offset`.
    fn store(&mut self, offset: u64, width: usize, value: u64);
    /// Claims the highest-priority pending interrupt for target `i` (PLIC-style), or `None`.
    fn claim(&mut self, _target: u32) -> Option<u32> {
        None
    }
    /// Completes an interrupt for target `i` (PLIC-style).
    fn complete(&mut self, _target: u32, _irq: u32) {}
    /// Capture device state as a list of `(name, value)` JSON pairs.
    fn snapshot(&self) -> Vec<(String, Json)> {
        Vec::new()
    }
    /// Restore device state from a `(name, value)` list.  Unknown names are ignored.
    fn restore(&mut self, _state: &[(String, Json)]) {}
}

/// Core-local interruptor.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Clint {
    /// Machine-mode software interrupt pending for each hart.
    pub msip: Vec<u64>,
    /// Time compare for each hart.
    pub mtimecmp: Vec<u64>,
    /// Free-running wall-clock time.
    pub mtime: u64,
    /// Number of harts.
    pub harts: usize,
}

impl Clint {
    /// Create a CLINT for `harts` harts.
    pub fn new(harts: usize) -> Self {
        Self {
            msip: vec![0; harts],
            mtimecmp: vec![u64::MAX; harts],
            mtime: 0,
            harts,
        }
    }

    /// Advance `mtime`.
    pub fn tick(&mut self) {
        self.mtime = self.mtime.wrapping_add(1);
    }

    /// True if hart `i` has a pending timer interrupt.
    pub fn timer_pending(&self, i: usize) -> bool {
        i < self.harts && self.mtime >= self.mtimecmp[i]
    }

    /// True if hart `i` has a pending software interrupt.
    pub fn sw_pending(&self, i: usize) -> bool {
        i < self.harts && self.msip[i] & 1 != 0
    }

    fn hart_addr(&self, offset: u64) -> Option<usize> {
        // MSIP: 0x0000, 4 bytes per hart
        // MTIMECMP: 0x4000, 8 bytes per hart
        // MTIME: 0xbff8
        if offset < 0x4000 {
            let i = (offset / 4) as usize;
            if i < self.harts {
                return Some(i);
            }
        } else if offset < 0xbff8 {
            let i = ((offset - 0x4000) / 8) as usize;
            if i < self.harts {
                return Some(i);
            }
        }
        None
    }
}

impl Clint {
    /// Capture the full CLINT state as JSON pairs.
    pub fn to_snapshot(&self) -> Vec<(String, Json)> {
        vec![
            ("harts".into(), json_u64(self.harts as u64)),
            ("mtime".into(), json_u64(self.mtime)),
            ("msip".into(), json_uarr(&self.msip)),
            ("mtimecmp".into(), json_uarr(&self.mtimecmp)),
        ]
    }

    /// Restore the CLINT state from JSON pairs.
    pub fn from_snapshot(&mut self, state: &[(String, Json)]) {
        for (k, v) in state {
            match k.as_str() {
                "harts" => {
                    if let Some(n) = parse_u64(v) {
                        self.harts = n as usize;
                    }
                }
                "mtime" => {
                    if let Some(n) = parse_u64(v) {
                        self.mtime = n;
                    }
                }
                "msip" => {
                    if let Some(arr) = parse_uarr(v) {
                        self.msip = arr;
                    }
                }
                "mtimecmp" => {
                    if let Some(arr) = parse_uarr(v) {
                        self.mtimecmp = arr;
                    }
                }
                _ => {}
            }
        }
    }
}

impl MmioDevice for Clint {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if offset == 0xbff8 && (width == 4 || width == 8) {
            self.mtime
        } else if offset == 0xbff0 && (width == 4 || width == 8) {
            self.mtime >> 32
        } else if let Some(i) = self.hart_addr(offset) {
            if offset < 0x4000 && width == 4 {
                self.msip[i]
            } else {
                self.mtimecmp[i]
            }
        } else {
            0
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if offset == 0xbff8 && (width == 4 || width == 8) {
            self.mtime = (self.mtime & !0xffff_ffff) | (value & 0xffff_ffff);
        } else if offset == 0xbff0 && (width == 4 || width == 8) {
            self.mtime = (self.mtime & 0xffff_ffff) | (value << 32);
        } else if let Some(i) = self.hart_addr(offset) {
            if offset < 0x4000 && width == 4 {
                self.msip[i] = value & 1;
            } else {
                self.mtimecmp[i] = value;
            }
        }
    }

    fn snapshot(&self) -> Vec<(String, Json)> {
        self.to_snapshot()
    }

    fn restore(&mut self, state: &[(String, Json)]) {
        self.from_snapshot(state);
    }
}

/// Transmit-only NS16550a-ish UART.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Uart {
    /// Console bytes emitted by the guest.
    pub output: Vec<u8>,
    /// THR (offset 0) holds the last byte written, or 0.
    pub thr: u8,
    /// LSR: bit 5 (THRE) and bit 6 (TEMT) set.
    pub lsr: u8,
}

impl Uart {
    /// Create a fresh UART.
    pub fn new() -> Self {
        Self {
            lsr: 0x60,
            ..Self::default()
        }
    }

    /// Capture UART state as JSON pairs.
    pub fn to_snapshot(&self) -> Vec<(String, Json)> {
        vec![
            ("output".into(), json_hex(&self.output)),
            ("thr".into(), json_u64(self.thr as u64)),
            ("lsr".into(), json_u64(self.lsr as u64)),
        ]
    }

    /// Restore UART state from JSON pairs.
    pub fn from_snapshot(&mut self, state: &[(String, Json)]) {
        for (k, v) in state {
            match k.as_str() {
                "output" => {
                    if let Some(Json::Str(s)) = Some(v) {
                        if let Some(bytes) = parse_hex(s) {
                            self.output = bytes;
                        }
                    }
                }
                "thr" => {
                    if let Some(n) = parse_u64(v) {
                        self.thr = n as u8;
                    }
                }
                "lsr" => {
                    if let Some(n) = parse_u64(v) {
                        self.lsr = n as u8;
                    }
                }
                _ => {}
            }
        }
    }
}

impl MmioDevice for Uart {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if width != 1 && width != 4 {
            return 0;
        }
        match offset {
            0x0 => self.thr as u64,
            0x5 => self.lsr as u64,
            _ => 0,
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if (width == 1 || width == 4) && offset == 0x0 {
            self.thr = (value & 0xff) as u8;
            self.output.push(self.thr);
        }
    }

    fn snapshot(&self) -> Vec<(String, Json)> {
        self.to_snapshot()
    }

    fn restore(&mut self, state: &[(String, Json)]) {
        self.from_snapshot(state);
    }
}

/// Platform-level interrupt controller (simplified 30/16 geometry).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Plic {
    /// Number of interrupt sources.
    pub num_sources: u32,
    /// Number of interrupt targets (contexts).
    pub num_targets: u32,
    /// Priority per source.
    pub priority: Vec<u32>,
    /// Pending bit mask.
    pub pending: u32,
    /// Enable bit mask per target.
    pub enable: Vec<u32>,
    /// Priority threshold per target.
    pub threshold: Vec<u32>,
    /// Last claimed interrupt per target.
    pub claim: Vec<u32>,
    /// Sources currently claimed but not completed (per target).
    pub claimed: Vec<u32>,
}

impl Plic {
    /// Create a PLIC with the given number of sources and targets.
    pub fn new(num_sources: u32, num_targets: u32) -> Self {
        Self {
            num_sources,
            num_targets,
            priority: vec![0; num_sources as usize + 1],
            pending: 0,
            enable: vec![0; num_targets as usize],
            threshold: vec![0; num_targets as usize],
            claim: vec![0; num_targets as usize],
            claimed: vec![0; num_targets as usize],
        }
    }

    /// Whether `target` has any enabled, pending, unclaimed interrupt.
    pub fn any_pending(&self, target: u32) -> bool {
        if (target as usize) >= self.num_targets as usize {
            return false;
        }
        (self.enable[target as usize] & self.pending & !self.claimed[target as usize]) != 0
    }

    /// Capture PLIC state as JSON pairs.
    pub fn to_snapshot(&self) -> Vec<(String, Json)> {
        vec![
            ("num_sources".into(), json_u32(self.num_sources)),
            ("num_targets".into(), json_u32(self.num_targets)),
            ("priority".into(), json_u32arr(&self.priority)),
            ("pending".into(), json_u32(self.pending)),
            ("enable".into(), json_u32arr(&self.enable)),
            ("threshold".into(), json_u32arr(&self.threshold)),
            ("claim".into(), json_u32arr(&self.claim)),
            ("claimed".into(), json_u32arr(&self.claimed)),
        ]
    }

    /// Restore PLIC state from JSON pairs.
    pub fn from_snapshot(&mut self, state: &[(String, Json)]) {
        for (k, v) in state {
            match k.as_str() {
                "num_sources" => {
                    if let Some(n) = parse_u32(v) {
                        self.num_sources = n;
                    }
                }
                "num_targets" => {
                    if let Some(n) = parse_u32(v) {
                        self.num_targets = n;
                    }
                }
                "priority" => {
                    if let Some(arr) = parse_u32arr(v) {
                        self.priority = arr;
                    }
                }
                "pending" => {
                    if let Some(n) = parse_u32(v) {
                        self.pending = n;
                    }
                }
                "enable" => {
                    if let Some(arr) = parse_u32arr(v) {
                        self.enable = arr;
                    }
                }
                "threshold" => {
                    if let Some(arr) = parse_u32arr(v) {
                        self.threshold = arr;
                    }
                }
                "claim" => {
                    if let Some(arr) = parse_u32arr(v) {
                        self.claim = arr;
                    }
                }
                "claimed" => {
                    if let Some(arr) = parse_u32arr(v) {
                        self.claimed = arr;
                    }
                }
                _ => {}
            }
        }
    }
}

impl MmioDevice for Plic {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if width != 4 {
            return 0;
        }
        if offset == 0x0200_0004 {
            // claim/complete for target 0
            self.claim[0] as u64
        } else if (0x0..0x1000).contains(&offset) {
            let i = (offset / 4) as usize;
            if i < self.priority.len() {
                self.priority[i] as u64
            } else {
                0
            }
        } else {
            0
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if width != 4 {
            return;
        }
        if (0x0..0x1000).contains(&offset) {
            let i = (offset / 4) as usize;
            if i < self.priority.len() {
                self.priority[i] = (value & 0xff) as u32;
            }
        } else if offset == 0x0200_0004 {
            self.claim[0] = 0;
        }
    }

    fn claim(&mut self, target: u32) -> Option<u32> {
        if target as usize >= self.num_targets as usize {
            return None;
        }
        let mask = self.enable[target as usize] & self.pending & !self.claimed[target as usize];
        if mask == 0 {
            return None;
        }
        // Return lowest set source id as a placeholder.
        let irq = mask.trailing_zeros();
        if irq > self.num_sources {
            return None;
        }
        self.claim[target as usize] = irq;
        self.claimed[target as usize] |= 1u32 << irq;
        Some(irq)
    }

    fn complete(&mut self, target: u32, irq: u32) {
        if (target as usize) < self.num_targets as usize {
            self.pending &= !(1u32 << irq);
            self.claimed[target as usize] &= !(1u32 << irq);
            self.claim[target as usize] = 0;
        }
    }

    fn snapshot(&self) -> Vec<(String, Json)> {
        self.to_snapshot()
    }

    fn restore(&mut self, state: &[(String, Json)]) {
        self.from_snapshot(state);
    }
}

/// One entry in the AI-island descriptor queue.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AiQueueEntry {
    /// Ticket assigned at enqueue.
    pub ticket: u64,
    /// Guest descriptor address.
    pub desc_addr: u64,
    /// Completion status: 0 = OK, pending otherwise.
    pub status: u32,
    /// True once `ai.qfence` or completion has finished the entry.
    pub done: bool,
}

/// Circular descriptor queue for the AI-island.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiQueue {
    /// Queue base guest address.
    pub base: u64,
    /// Queue control word (enabled, depth log2, etc.).
    pub ctl: u64,
    /// Producer head (enqueue index).
    pub head: u64,
    /// Consumer tail (completion index).
    pub tail: u64,
    /// Maximum number of in-flight entries.
    pub depth: u64,
    /// Next ticket to hand out.
    pub next_ticket: u64,
    /// In-flight entries.
    pub entries: Vec<AiQueueEntry>,
}

impl AiQueue {
    /// Create a queue with the given depth.
    pub fn new(depth: u64) -> Self {
        Self {
            base: 0,
            ctl: 0,
            head: 0,
            tail: 0,
            depth: depth.max(1),
            next_ticket: 0,
            entries: Vec::new(),
        }
    }

    /// Number of in-flight entries.
    pub fn inflight(&self) -> usize {
        self.entries.len()
    }

    /// Enqueue a descriptor pointer under a caller-allocated ticket.
    ///
    /// The ticket is allocated by the *island*, not by the queue, because a design with
    /// more than one ring must still hand out tickets that identify an entry uniquely:
    /// two rings each counting from zero would make `ai.poll` ambiguous as soon as a
    /// second hart submitted work.
    pub fn enqueue_with_ticket(&mut self, ticket: u64, desc_addr: u64) -> Option<u64> {
        if self.inflight() >= self.depth as usize {
            return None;
        }
        self.next_ticket = ticket.wrapping_add(1);
        self.entries.push(AiQueueEntry {
            ticket,
            desc_addr,
            status: 0,
            done: false,
        });
        self.head = (self.head + 1) % self.depth;
        Some(ticket)
    }

    /// Poll the status of a ticket.
    pub fn poll(&mut self, ticket: u64) -> Option<u64> {
        if let Some(e) = self.entries.iter_mut().find(|e| e.ticket == ticket) {
            if e.done {
                Some(e.status as u64)
            } else {
                // Still pending; status not yet final.
                Some(0xffff_ffff) // conventional "not complete" sentinel
            }
        } else {
            // Unknown ticket — already completed or never enqueued.
            Some(0)
        }
    }

    /// Fence: complete all outstanding entries.
    pub fn qfence(&mut self) -> usize {
        for e in self.entries.iter_mut() {
            e.done = true;
            e.status = 0;
        }
        let n = self.entries.len();
        self.tail = (self.tail + n as u64) % self.depth;
        n
    }

    /// Drain completed entries.
    pub fn retire_completed(&mut self) {
        self.entries.retain(|e| !e.done);
    }
}

impl Default for AiQueue {
    fn default() -> Self {
        Self::new(4)
    }
}

/// Where each AI-island descriptor register sits in the MMIO window.
///
/// **These offsets are architecture-derived when a model is available.** The `Default`
/// implementation is a *bring-up fallback* used only when no descriptor layout has been
/// ingested; it is not a claim about any real design. Once
/// [`AiRegMap::from_desc_layout`] has run, the window mirrors the packed descriptor the
/// design's own package describes, which is what keeps this device, the emitted QEMU
/// device model, and a host-packed descriptor image talking about the same bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AiRegMap {
    /// Combined version (low half) and op (high half) doorbell word.
    pub version_op: u64,
    /// Flag word.
    pub flags: u64,
    /// M dimension.
    pub m: u64,
    /// N dimension.
    pub n: u64,
    /// K dimension.
    pub k: u64,
    /// A/B leading-dimension packing.
    pub ld_ab: u64,
    /// A pointer.
    pub ptr_a: u64,
    /// B pointer.
    pub ptr_b: u64,
    /// C pointer.
    pub ptr_c: u64,
    /// Scale pointer.
    pub ptr_scale: u64,
    /// Completion pointer.
    pub ptr_done: u64,
    /// Status register (device-owned, not a descriptor field).
    pub status: u64,
    /// Completion register (device-owned, not a descriptor field).
    pub completion: u64,
}

impl Default for AiRegMap {
    fn default() -> Self {
        // Bring-up fallback only; see the type docstring.
        Self {
            version_op: 0x00,
            flags: 0x08,
            m: 0x10,
            n: 0x14,
            k: 0x18,
            ld_ab: 0x1c,
            ptr_a: 0x20,
            ptr_b: 0x28,
            ptr_c: 0x30,
            ptr_scale: 0x38,
            ptr_done: 0x40,
            status: 0x48,
            completion: 0x50,
        }
    }
}

impl AiRegMap {
    /// Resolve the window from an ingested descriptor layout, relative to `base`.
    ///
    /// `base` is where the island places its descriptor latch window; the layout supplies
    /// the offset of each field *within* the descriptor. Both halves are needed, and they
    /// come from different places in the design, so they are separate arguments here
    /// rather than one conflated number.
    ///
    /// A field the layout does not name keeps its fallback offset rather than being
    /// dropped, so a partially-parsed package degrades instead of producing a device
    /// with holes in it. `status` and `completion` are device registers rather than
    /// descriptor fields, so they are placed immediately after the descriptor using the
    /// layout's own `desc_bytes` — derived, not chosen.
    pub fn from_desc_layout(layout: &g6q_core::model::AiDescLayout, base: u64) -> Self {
        let mut map = Self::default();
        let set = |slot: &mut u64, name: &str| {
            if let Some(off) = layout.offset(name) {
                *slot = base + off;
            }
        };
        set(&mut map.version_op, "version");
        set(&mut map.flags, "flags");
        set(&mut map.m, "m");
        set(&mut map.n, "n");
        set(&mut map.k, "k");
        set(&mut map.ld_ab, "ld_ab");
        set(&mut map.ptr_a, "ptr_a");
        set(&mut map.ptr_b, "ptr_b");
        set(&mut map.ptr_c, "ptr_c");
        set(&mut map.ptr_scale, "ptr_scale");
        set(&mut map.ptr_done, "ptr_done");
        if layout.desc_bytes > 0 {
            map.status = base + layout.desc_bytes;
            map.completion = base + layout.desc_bytes + 8;
        }
        map
    }
}

/// Status codes the island reports, by meaning rather than by value.
///
/// As with [`AiRegMap`], `Default` is a bring-up fallback; real values come from the
/// `ST_*` constants in the design's descriptor package.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AiStatusCodes {
    /// Completed without error.
    pub ok: u16,
    /// Descriptor version the island does not implement.
    pub bad_ver: u16,
    /// Island present but not enabled.
    pub disabled: u16,
}

impl Default for AiStatusCodes {
    fn default() -> Self {
        Self {
            ok: 0,
            bad_ver: 2,
            disabled: 6,
        }
    }
}

impl AiStatusCodes {
    /// Resolve the codes from an ingested descriptor layout.
    pub fn from_desc_layout(layout: &g6q_core::model::AiDescLayout) -> Self {
        let mut codes = Self::default();
        if let Some(v) = layout.status("ST_OK") {
            codes.ok = v as u16;
        }
        if let Some(v) = layout.status("ST_BAD_VER") {
            codes.bad_ver = v as u16;
        }
        if let Some(v) = layout.status("ST_DISABLED") {
            codes.disabled = v as u16;
        }
        codes
    }
}

/// AI-island / matrix-accelerator device model.
///
/// The MMIO window, the status codes, the number of descriptor rings and their depth are
/// all taken from the ingested model (see [`AiIsland::set_ai_model`]). Nothing about the
/// guest-visible surface is chosen here: a literal in this device would be a second
/// source of truth for the descriptor ABI.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiIsland {
    /// Version register.
    pub version: u16,
    /// Last submitted op.
    pub op: u16,
    /// M dimension.
    pub m: u32,
    /// N dimension.
    pub n: u32,
    /// K dimension.
    pub k: u32,
    /// A/B leading-dimension packing.
    pub ld_ab: u32,
    /// A pointer.
    pub ptr_a: u64,
    /// B pointer.
    pub ptr_b: u64,
    /// C pointer.
    pub ptr_c: u64,
    /// Scale pointer.
    pub ptr_scale: u64,
    /// Done pointer.
    pub ptr_done: u64,
    /// Pending completion interrupt.
    pub irq_pending: bool,
    /// Completion status: 0 = ST_OK.
    pub status: u16,
    /// Completion ticket.
    pub ticket: u32,
    /// Descriptor queue rings, one per ring the model declares.
    pub queues: Vec<AiQueue>,
    /// Island-wide ticket allocator, so a ticket identifies an entry across all rings.
    pub next_ticket: u64,
    /// Resolved MMIO window.
    pub regmap: AiRegMap,
    /// Resolved status codes.
    pub codes: AiStatusCodes,
    /// Base of the capability window, taken from the model when the design states it.
    ///
    /// `None` means the window is not decoded. It is deliberately never defaulted to an
    /// address: inventing a base here would put a guest-visible address in this file.
    pub cap_base: Option<u64>,
    /// Tensor events produced by this device.
    pub events: Vec<g6q_diag::ai_tensor::AiTensorEvent>,
    /// Monotonic event order counter.
    pub event_order: u64,
    /// Architecture-derived AI island model, when available.
    pub ai_model: Option<g6q_core::model::AiIslandModel>,
}

impl AiIsland {
    /// Create a fresh AI island, disabled, with one ring and fallback geometry.
    pub fn new() -> Self {
        let codes = AiStatusCodes::default();
        Self {
            status: codes.disabled,
            codes,
            regmap: AiRegMap::default(),
            queues: vec![AiQueue::new(4)],
            ..Default::default()
        }
    }

    fn submit(&mut self, version: u64, op: u64) {
        self.version = (version & 0xffff) as u16;
        self.op = (op & 0xffff) as u16;
        // Compare against the version the package declares. When the package does not
        // publish one, `FALLBACK_DESC_VERSION` is used -- and it is named here, as a
        // single visible constant, rather than buried in a lookup that always misses.
        // Removing it needs a published constant in the design, not a change here.
        const FALLBACK_DESC_VERSION: u16 = 1;
        let supported = self
            .ai_model
            .as_ref()
            .and_then(|m| m.desc_layout.version)
            .map_or(FALLBACK_DESC_VERSION, |v| v as u16);
        self.status = if self.version == supported {
            self.codes.ok
        } else {
            self.codes.bad_ver
        };
    }

    /// Adopt an architecture-derived model: placement, window, codes and rings.
    ///
    /// When the model does not resolve the island's MMIO placement, the descriptor window
    /// falls back to offset zero and the capability window stays undecoded. That is a
    /// deliberately visible degradation: `AiIslandConfig::placement_resolved` reports it,
    /// so a caller can say "the guest cannot address this island" instead of silently
    /// running against an invented address map.
    pub fn set_ai_model(&mut self, model: &g6q_core::model::AiIslandModel) {
        let desc_base = model.config.desc_base.unwrap_or(0);
        self.regmap = AiRegMap::from_desc_layout(&model.desc_layout, desc_base);
        self.cap_base = model.config.cap_base;
        self.codes = AiStatusCodes::from_desc_layout(&model.desc_layout);
        if self.status != self.codes.ok {
            self.status = self.codes.disabled;
        }
        let depth = (model.config.queue_depth as u64).max(1);
        let rings = (model.config.queues as usize).max(1);
        self.queues = (0..rings).map(|_| AiQueue::new(depth)).collect();
        self.ai_model = Some(model.clone());
    }

    /// Set the depth of every ring explicitly (tests and bring-up).
    pub fn set_queue_depth(&mut self, depth: u64) {
        if self.queues.is_empty() {
            self.queues.push(AiQueue::new(depth));
        }
        for q in self.queues.iter_mut() {
            q.depth = depth.max(1);
        }
    }

    /// The first ring. Present so single-ring callers stay readable.
    pub fn queue(&self) -> &AiQueue {
        &self.queues[0]
    }

    /// Total in-flight entries across every ring.
    pub fn inflight_total(&self) -> usize {
        self.queues.iter().map(AiQueue::inflight).sum()
    }

    /// Which ring a hart submits to.
    ///
    /// One ring per hart while rings are plentiful, wrapping when a design has fewer
    /// rings than harts. This is the behaviour a threaded or multi-core guest depends on:
    /// concurrent submission must not serialise onto one ring by accident.
    pub fn ring_for_hart(&self, hart: u32) -> usize {
        (hart as usize) % self.queues.len().max(1)
    }

    /// Enqueue a descriptor, emit a tensor event, and return the assigned ticket.
    pub fn queue_enq(&mut self, desc_addr: u64, hart: u32) -> Option<u64> {
        let ring = self.ring_for_hart(hart);
        let ticket = self.next_ticket;
        let issued = self.queues[ring].enqueue_with_ticket(ticket, desc_addr)?;
        self.next_ticket = self.next_ticket.wrapping_add(1);
        let mut ev = g6q_diag::ai_tensor::AiTensorEvent {
            order: self.event_order,
            hart,
            descriptor_addr: desc_addr,
            ticket: issued as u32,
            done: false,
            ..Default::default()
        };
        ev.version = self.version;
        ev.op = self.op;
        self.events.push(ev);
        self.event_order += 1;
        Some(issued)
    }

    /// Poll a ticket on whichever ring holds it.
    pub fn queue_poll(&mut self, ticket: u64) -> Option<u64> {
        for q in self.queues.iter_mut() {
            if q.entries.iter().any(|e| e.ticket == ticket) {
                return q.poll(ticket);
            }
        }
        // Unknown ticket: already retired, or never issued.
        Some(self.codes.ok as u64)
    }

    /// Fence every ring, completing all in-flight entries.
    pub fn queue_qfence(&mut self) -> usize {
        let n: usize = self.queues.iter_mut().map(AiQueue::qfence).sum();
        let ok = self.codes.ok;
        for ev in self.events.iter_mut().rev().take(n) {
            ev.done = true;
            ev.status = ok;
        }
        n
    }

    /// Capability words the guest may read, as offset -> value.
    ///
    /// Derived wholly from the ingested configuration. This is the mechanism that lets a
    /// single guest binary run against parts of different sizes, so answering from
    /// anything other than the model would defeat its purpose.
    pub fn cap_words(&self) -> Vec<(u64, u64)> {
        let Some(model) = self.ai_model.as_ref() else {
            return Vec::new();
        };
        let cfg = &model.config;
        let mut out = Vec::new();
        for (name, off) in &cfg.cap_offsets {
            if let Some(value) = Self::cap_value(cfg, name) {
                out.push((*off, value));
            }
        }
        out.sort_unstable();
        out
    }

    /// Source one capability word from the configuration, by the package's own name.
    ///
    /// Returning `None` means *this device cannot source that word*, which is reported
    /// through [`AiIsland::cap_unsourced`] rather than answered as zero: zero is a legal
    /// capability value, so a zero here would be indistinguishable from a real answer.
    fn cap_value(cfg: &g6q_core::model::AiIslandConfig, name: &str) -> Option<u64> {
        // Names are the package's `CAP_OFF_*` suffixes, lowercased by the reader.
        match name {
            "version" => Some(cfg.cap_version as u64),
            "clusters" => Some(cfg.clusters as u64),
            "macs_cycle" | "macs_per_cycle" => Some(cfg.macs_per_cycle as u64),
            "clock_khz" => Some(cfg.clock_khz as u64),
            "sram_bytes" => Some(cfg.sram_bytes),
            "dram_gbps" => Some(cfg.dram_gbps as u64),
            "queues" => Some(cfg.queues as u64),
            "qos" | "qos_classes" => Some(cfg.qos_classes as u64),
            "quantum" | "work_quantum_k" => Some(cfg.work_quantum_k as u64),
            "queue_depth" => Some(cfg.queue_depth as u64),
            "acc_tile_m" => Some(cfg.acc_tile_m as u64),
            "acc_tile_n" => Some(cfg.acc_tile_n as u64),
            "acc_tile_k" => Some(cfg.acc_tile_k as u64),
            "noc_width" => Some(cfg.noc_width as u64),
            "dram_channels" => Some(cfg.dram_channels as u64),
            // Words whose value is a *packed encoding* rather than a single field.
            // Packing them here would transcribe a bit-layout contract that the design
            // owns, so they stay unsourced until the model carries the layout.
            //   block_mnk  - packed tile dimensions
            //   dtype_mask - grant bits per data type
            _ => None,
        }
    }

    /// Capability words the model names but this device cannot source, with their offsets.
    ///
    /// This exists so a capability added to the design shows up as a tracked gap instead
    /// of silently disappearing from the guest-visible window.
    pub fn cap_unsourced(&self) -> Vec<(String, u64)> {
        let Some(model) = self.ai_model.as_ref() else {
            return Vec::new();
        };
        let cfg = &model.config;
        let mut out: Vec<(String, u64)> = cfg
            .cap_offsets
            .iter()
            .filter(|(name, _)| Self::cap_value(cfg, name).is_none())
            .map(|(name, off)| (name.clone(), *off))
            .collect();
        out.sort();
        out
    }

    /// Read a capability word by window offset, if the window is placed and decoded.
    pub fn cap_read(&self, offset: u64) -> Option<u64> {
        let base = self.cap_base?;
        let rel = offset.checked_sub(base)?;
        self.cap_words()
            .into_iter()
            .find(|(off, _)| *off == rel)
            .map(|(_, v)| v)
    }

    /// Drain and return the accumulated tensor events.
    pub fn drain_events(&mut self) -> Vec<g6q_diag::ai_tensor::AiTensorEvent> {
        std::mem::take(&mut self.events)
    }
}

impl MmioDevice for AiIsland {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if width > 8 {
            return 0;
        }
        // The capability window is read-only and takes precedence, so a design that
        // overlaps it with the descriptor window still reports geometry correctly.
        if let Some(v) = self.cap_read(offset) {
            return v;
        }
        let r = self.regmap;
        match offset {
            o if o == r.version_op => ((self.op as u64) << 16) | (self.version as u64),
            o if o == r.flags => 0,
            o if o == r.m => self.m as u64,
            o if o == r.n => self.n as u64,
            o if o == r.k => self.k as u64,
            o if o == r.ld_ab => self.ld_ab as u64,
            o if o == r.ptr_a => self.ptr_a,
            o if o == r.ptr_b => self.ptr_b,
            o if o == r.ptr_c => self.ptr_c,
            o if o == r.ptr_scale => self.ptr_scale,
            o if o == r.ptr_done => self.ptr_done,
            o if o == r.status => self.status as u64,
            o if o == r.completion => ((self.status as u64) << 32) | (self.ticket as u64),
            _ => 0,
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if width > 8 {
            return;
        }
        let r = self.regmap;
        match offset {
            o if o == r.version_op => self.submit(value, value >> 16),
            o if o == r.m => self.m = value as u32,
            o if o == r.n => self.n = value as u32,
            o if o == r.k => self.k = value as u32,
            o if o == r.ld_ab => self.ld_ab = value as u32,
            o if o == r.ptr_a => self.ptr_a = value,
            o if o == r.ptr_b => self.ptr_b = value,
            o if o == r.ptr_c => self.ptr_c = value,
            o if o == r.ptr_scale => self.ptr_scale = value,
            o if o == r.ptr_done => {
                self.ptr_done = value;
                self.ticket = self.ticket.wrapping_add(1);
                self.irq_pending = true;
            }
            o if o == r.status => self.irq_pending = false,
            _ => {}
        }
    }

    fn snapshot(&self) -> Vec<(String, Json)> {
        vec![
            ("version".into(), json_u64(self.version as u64)),
            ("op".into(), json_u64(self.op as u64)),
            ("status".into(), json_u64(self.status as u64)),
            ("ticket".into(), json_u64(self.ticket as u64)),
            ("irq_pending".into(), Json::Bool(self.irq_pending)),
        ]
    }

    fn restore(&mut self, state: &[(String, Json)]) {
        for (k, v) in state {
            match k.as_str() {
                "version" => self.version = parse_u64(v).unwrap_or(0) as u16,
                "op" => self.op = parse_u64(v).unwrap_or(0) as u16,
                "status" => self.status = parse_u64(v).unwrap_or(0) as u16,
                "ticket" => self.ticket = parse_u64(v).unwrap_or(0) as u32,
                "irq_pending" => {
                    if let Json::Bool(b) = v {
                        self.irq_pending = *b;
                    }
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clint_mtimecmp_and_msip() {
        let mut c = Clint::new(2);
        c.store(0x0, 4, 1);
        c.store(0x4000, 8, 0x1234);
        assert_eq!(c.load(0x0, 4), 1);
        assert_eq!(c.load(0x4000, 8), 0x1234);
        assert_eq!(c.load(0x4008, 8), u64::MAX);
    }

    #[test]
    fn uart_transmits_bytes() {
        let mut u = Uart::new();
        u.store(0x0, 1, b'X' as u64);
        assert_eq!(u.output, vec![b'X']);
        assert_eq!(u.load(0x5, 1), 0x60);
    }

    #[test]
    fn plic_claims_highest_enabled_pending() {
        let mut p = Plic::new(30, 16);
        p.priority[5] = 1;
        p.enable[0] = 1 << 5;
        p.pending = 1 << 5;
        assert_eq!(p.claim(0), Some(5));
        assert_eq!(p.claim(0), None);
        p.complete(0, 5);
        assert_eq!(p.pending & (1 << 5), 0);
    }

    #[test]
    fn ai_island_submits_and_completes() {
        let mut a = AiIsland::new();
        // Initial status is ST_DISABLED.
        assert_eq!(a.load(0x48, 4), 6);
        // Submit a version=1, op=GEMM (1) descriptor.
        a.store(0x00, 4, 0x0001_0001);
        assert_eq!(a.version, 1);
        assert_eq!(a.op, 1);
        assert_eq!(a.status, 0); // ST_OK
                                 // Write completion pointer and read back completion word.
        a.store(0x40, 8, 0x9000_0000);
        assert!(a.irq_pending);
        let completion = a.load(0x50, 8);
        assert_eq!(completion, 1);
    }

    #[test]
    fn ai_island_queue_enq_poll_and_qfence() {
        let mut a = AiIsland::new();
        a.set_queue_depth(2);

        let t0 = a.queue_enq(0x8000_0000, 0).unwrap();
        assert_eq!(t0, 0);
        let t1 = a.queue_enq(0x8000_1000, 0).unwrap();
        assert_eq!(t1, 1);
        assert!(a.queue_enq(0x8000_2000, 0).is_none());

        assert_eq!(a.queue_poll(t0).unwrap(), 0xffff_ffff);
        a.queue_qfence();
        assert_eq!(a.queue_poll(t0).unwrap(), 0);

        let events = a.drain_events();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].descriptor_addr, 0x8000_0000);
        assert!(events[1].done);
    }

    /// A layout whose offsets deliberately differ from the bring-up fallback, so a test
    /// that passes can only be reading the model.
    fn model_with_layout() -> g6q_core::model::AiIslandModel {
        use g6q_core::model::{AiDescLayout, AiIslandConfig, AiIslandModel, DescField};
        let mut fields = std::collections::BTreeMap::new();
        let mut put = |name: &str, offset: u64, size: u64| {
            fields.insert(
                name.to_string(),
                DescField {
                    offset,
                    size,
                    bit_low: offset * 8,
                    bit_high: (offset + size) * 8 - 1,
                },
            );
        };
        // The packed descriptor from the reference package: ptr_done at 56, not 0x40.
        put("version", 0, 2);
        put("op", 2, 2);
        put("flags", 4, 4);
        put("m", 8, 4);
        put("n", 12, 4);
        put("k", 16, 4);
        put("ld_ab", 20, 4);
        put("ptr_a", 24, 8);
        put("ptr_b", 32, 8);
        put("ptr_c", 40, 8);
        put("ptr_scale", 48, 8);
        put("ptr_done", 56, 8);
        let mut statuses = std::collections::BTreeMap::new();
        statuses.insert("ST_OK".to_string(), 0u64);
        statuses.insert("ST_BAD_VER".to_string(), 3u64);
        statuses.insert("ST_DISABLED".to_string(), 7u64);
        let mut cap_offsets = std::collections::BTreeMap::new();
        cap_offsets.insert("clusters".to_string(), 0x04u64);
        cap_offsets.insert("macs_cycle".to_string(), 0x08u64);
        cap_offsets.insert("queue_depth".to_string(), 0x0cu64);
        AiIslandModel {
            config: AiIslandConfig {
                clusters: 8,
                macs_per_cycle: 4096,
                queues: 2,
                queue_depth: 3,
                cap_offsets,
                // Placement as the island decode states it: capability window at the
                // bottom of the region, descriptor latch window higher up.
                cap_base: Some(0x000),
                desc_base: Some(0x140),
                ..Default::default()
            },
            desc_layout: AiDescLayout {
                desc_bytes: 64,
                version: None,
                fields,
                ops: Default::default(),
                statuses,
            },
            ..Default::default()
        }
    }

    #[test]
    fn the_mmio_window_follows_the_ingested_layout_at_the_stated_base() {
        let mut a = AiIsland::new();
        a.set_ai_model(&model_with_layout());

        // ptr_done is at base + the layout's offset (0x140 + 56), not the fallback 0x40.
        assert_eq!(a.regmap.ptr_done, 0x140 + 56);
        a.store(0x140 + 56, 8, 0x9000_0000);
        assert_eq!(a.ptr_done, 0x9000_0000);
        assert!(a.irq_pending);
        // Neither the fallback offset nor the un-based offset may still decode.
        a.ptr_done = 0;
        a.store(0x40, 8, 0xdead_beef);
        a.store(56, 8, 0xdead_beef);
        assert_eq!(a.ptr_done, 0, "only base + field offset may decode");

        // status/completion sit after the descriptor, derived from base + desc_bytes.
        assert_eq!(a.regmap.status, 0x140 + 64);
        assert_eq!(a.regmap.completion, 0x140 + 72);
    }

    #[test]
    fn an_unresolved_placement_is_visible_rather_than_invented() {
        let mut model = model_with_layout();
        model.config.cap_base = None;
        model.config.desc_base = None;
        assert!(!model.config.placement_resolved());

        let mut a = AiIsland::new();
        a.set_ai_model(&model);
        // The capability window is not decoded at all without a base...
        assert!(a.cap_base.is_none());
        assert!(a.cap_read(0x04).is_none());
        // ...but the values are still derivable, so the finding is "unplaced", not "absent".
        assert!(!a.cap_words().is_empty());
        // The descriptor window collapses to offset zero, which is a degradation the
        // caller can detect through `placement_resolved` rather than a silent guess.
        assert_eq!(a.regmap.ptr_done, 56);
    }

    #[test]
    fn status_codes_come_from_the_package_not_from_literals() {
        let mut a = AiIsland::new();
        a.set_ai_model(&model_with_layout());
        // ST_DISABLED is 7 in this package, not the fallback 6.
        assert_eq!(a.codes.disabled, 7);
        assert_eq!(a.load(a.regmap.status, 4), 7);
        // A bad version reports this package's ST_BAD_VER (3), not the fallback 2.
        a.store(a.regmap.version_op, 4, 0x0001_0009);
        assert_eq!(a.status, 3);
        // The supported version reports ST_OK.
        a.store(a.regmap.version_op, 4, 0x0001_0001);
        assert_eq!(a.status, 0);
    }

    #[test]
    fn rings_come_from_the_model_and_harts_do_not_serialise_onto_one() {
        let mut a = AiIsland::new();
        a.set_ai_model(&model_with_layout());
        assert_eq!(a.queues.len(), 2, "two rings declared");
        assert_eq!(a.queue().depth, 3, "depth from the model");

        // Two harts land on different rings.
        assert_ne!(a.ring_for_hart(0), a.ring_for_hart(1));

        // Fill hart 0's ring; hart 1 must still be able to submit.
        for i in 0..3 {
            assert!(a.queue_enq(0x8000_0000 + i * 0x1000, 0).is_some());
        }
        assert!(
            a.queue_enq(0x8000_9000, 0).is_none(),
            "hart 0's ring is full"
        );
        let t = a
            .queue_enq(0x8001_0000, 1)
            .expect("hart 1 has its own ring");

        // Tickets are island-wide, so hart 1's ticket is distinct from hart 0's.
        assert_eq!(t, 3);
        assert_eq!(a.inflight_total(), 4);

        // Polling finds the ticket on whichever ring holds it.
        assert_eq!(a.queue_poll(t).unwrap(), 0xffff_ffff);
        a.queue_qfence();
        assert_eq!(a.queue_poll(t).unwrap(), 0);
    }

    #[test]
    fn the_capability_window_answers_from_the_model_once_placed() {
        let mut a = AiIsland::new();
        a.set_ai_model(&model_with_layout());

        // The base came from the model, not from this test.
        assert_eq!(a.cap_base, Some(0x000));
        assert_eq!(a.cap_read(0x04), Some(8), "clusters");
        assert_eq!(a.cap_read(0x08), Some(4096), "macs/cycle");
        assert_eq!(a.cap_read(0x0c), Some(3), "queue depth");
        assert_eq!(a.load(0x04, 8), 8, "readable through the MMIO surface");
        // An offset the model never named is not invented.
        assert!(a.cap_read(0x10).is_none());

        // The window follows the base wherever the design puts it.
        a.cap_base = Some(0x200);
        assert!(a.cap_read(0x04).is_none());
        assert_eq!(a.cap_read(0x204), Some(8));
    }

    #[test]
    fn an_island_without_a_model_reports_no_capabilities() {
        let a = AiIsland::new();
        assert!(a.cap_words().is_empty());
        assert!(a.cap_read(0).is_none());
    }

    /// Every capability name the reference package publishes must be either sourced or
    /// explicitly unsourced. Silently dropping one would remove a word from the
    /// guest-visible window, and the guest would read zero -- which is a legal value, so
    /// nothing would look wrong.
    #[test]
    fn every_published_capability_name_is_accounted_for() {
        use g6q_core::model::{AiIslandConfig, AiIslandModel};
        // The `CAP_OFF_*` suffixes of the reference package, lowercased by the reader.
        let published = [
            "version",
            "clusters",
            "macs_cycle",
            "clock_khz",
            "sram_bytes",
            "block_mnk",
            "dram_gbps",
            "queues",
            "qos",
            "quantum",
            "dtype_mask",
        ];
        let mut cap_offsets = std::collections::BTreeMap::new();
        for (i, name) in published.iter().enumerate() {
            cap_offsets.insert(name.to_string(), (i as u64) * 4);
        }
        let model = AiIslandModel {
            config: AiIslandConfig {
                cap_version: 1,
                clusters: 8,
                macs_per_cycle: 4096,
                clock_khz: 1_500_000,
                sram_bytes: 1 << 21,
                dram_gbps: 400,
                queues: 2,
                qos_classes: 4,
                work_quantum_k: 64,
                cap_offsets,
                cap_base: Some(0),
                desc_base: Some(0x140),
                ..Default::default()
            },
            ..Default::default()
        };
        let mut a = AiIsland::new();
        a.set_ai_model(&model);

        let sourced = a.cap_words().len();
        let unsourced: Vec<String> = a.cap_unsourced().into_iter().map(|(n, _)| n).collect();
        assert_eq!(
            sourced + unsourced.len(),
            published.len(),
            "a published capability name was silently dropped"
        );

        // Only the packed encodings may be unsourced; anything else is a mapping bug.
        assert_eq!(
            unsourced,
            vec!["block_mnk".to_string(), "dtype_mask".to_string()],
            "unexpected unsourced capabilities"
        );

        // The names that previously did not map must now answer.
        assert_eq!(a.cap_read(8 * 4), Some(4), "qos");
        assert_eq!(a.cap_read(9 * 4), Some(64), "quantum");
        assert_eq!(a.cap_read(6 * 4), Some(400), "dram_gbps");
    }

    #[test]
    fn the_descriptor_version_comes_from_the_package_when_published() {
        let mut model = model_with_layout();
        model.desc_layout.version = Some(2);
        let mut a = AiIsland::new();
        a.set_ai_model(&model);
        // Version 2 is accepted, version 1 is not, purely from the package.
        a.store(a.regmap.version_op, 4, 0x0001_0002);
        assert_eq!(a.status, a.codes.ok);
        a.store(a.regmap.version_op, 4, 0x0001_0001);
        assert_eq!(a.status, a.codes.bad_ver);
    }
}
