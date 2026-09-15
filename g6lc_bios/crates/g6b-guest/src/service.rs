// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded native service core in the BIOS-owned ABI frame.
//!
//! State lives at [`CORE_OFFSET`] so RX/R callee images stay file-backed.
//! IRQ operations only enqueue. `Poll` runs a quota of work in normal
//! context and always considers watchdog before slow I/O.

use g6b_runtime_abi::{
    CORE_BYTES, CORE_OFFSET, IRQ_INPUT, IRQ_SLOW, IRQ_WATCHDOG, NATIVE_FRAME_BYTES,
    POLL_FLAG_QUOTA, POLL_FLAG_WATCHDOG, POLL_REPORT_BYTES,
};

const MAGIC: u32 = 0x4353_3647; // G6SC
const IRQ_CAP: usize = 8;
const JOB_CAP: usize = 4;
const CTX_CAP: usize = 2;
const DEFAULT_QUOTA: u32 = 4;

const OFF_MAGIC: usize = 0;
const OFF_NOW: usize = 4;
const OFF_IRQ_R: usize = 8;
const OFF_IRQ_W: usize = 9;
const OFF_IRQ_N: usize = 10;
const OFF_HITS: usize = 11;
const OFF_IRQS: usize = 12;
const OFF_CTX: usize = 28;
const OFF_JOBS: usize = 44;
const IRQ_STRIDE: usize = 2;
const CTX_STRIDE: usize = 8;
const JOB_STRIDE: usize = 16;

pub fn implemented_mask() -> u32 {
    use g6b_runtime_abi::Operation::{BootStatus, BootTrial, Cancel, Capabilities, Input, Poll};
    (1u32 << Capabilities as u16)
        | (1 << BootStatus as u16)
        | (1 << BootTrial as u16)
        | (1 << Poll as u16)
        | (1 << Cancel as u16)
        | (1 << Input as u16)
}

pub fn init(frame: &mut [u8; NATIVE_FRAME_BYTES]) {
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    core.fill(0);
    put_u32(core, OFF_MAGIC, MAGIC);
    put_u32(core, OFF_CTX, 1);
    core[OFF_CTX + 4] = 1;
    put_u32(core, OFF_CTX + CTX_STRIDE, 1);
    core[OFF_CTX + CTX_STRIDE + 4] = 1;
}

pub fn ready(frame: &[u8; NATIVE_FRAME_BYTES]) -> bool {
    get_u32(&frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES], OFF_MAGIC) == MAGIC
}

pub fn enqueue(frame: &mut [u8; NATIVE_FRAME_BYTES], kind: u32, token: u32) -> bool {
    if !ready(frame) {
        return false;
    }
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    let n = core[OFF_IRQ_N] as usize;
    if n == IRQ_CAP {
        if kind == IRQ_WATCHDOG {
            return drop_slow_then_push(core, kind, token);
        }
        return false;
    }
    push_irq(core, kind as u8, token as u8);
    true
}

pub fn poll(frame: &mut [u8; NATIVE_FRAME_BYTES], quota: u32, now: u32) -> [u8; POLL_REPORT_BYTES] {
    let mut report = [0u8; POLL_REPORT_BYTES];
    if !ready(frame) {
        return report;
    }
    let quota = if quota == 0 {
        DEFAULT_QUOTA
    } else {
        quota.min(32)
    };
    {
        let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
        if now != 0 {
            put_u32(core, OFF_NOW, now);
        } else {
            let tick = get_u32(core, OFF_NOW).saturating_add(1);
            put_u32(core, OFF_NOW, tick);
        }
    }
    let mut units = 0u32;
    let mut watchdog = 0u32;
    while units < quota {
        match take_irq_priority(frame) {
            Some((IRQ_WATCHDOG, token)) => {
                run_watchdog(frame, token);
                units += 1;
                watchdog = 1;
            }
            Some((IRQ_INPUT, token)) => {
                admit_job(frame, 0, IRQ_INPUT, 1, token);
                units += 1;
            }
            Some((IRQ_SLOW, token)) => {
                admit_job(frame, 0, IRQ_SLOW, token.max(1).min(32), token);
                units += 1;
            }
            Some(_) => units += 1,
            None => break,
        }
    }
    while units < quota {
        if !step_slow(frame) {
            break;
        }
        units += 1;
    }
    let remaining = remaining_slow(frame);
    let hits = frame[CORE_OFFSET + OFF_HITS] as u32;
    let mut flags = 0u32;
    if watchdog != 0 {
        flags |= POLL_FLAG_WATCHDOG;
    }
    if units >= quota {
        flags |= POLL_FLAG_QUOTA;
    }
    report[..4].copy_from_slice(&units.to_le_bytes());
    report[4..8].copy_from_slice(&remaining.to_le_bytes());
    report[8..12].copy_from_slice(&hits.to_le_bytes());
    report[12..16].copy_from_slice(&flags.to_le_bytes());
    report
}

pub fn cancel(frame: &mut [u8; NATIVE_FRAME_BYTES], slot: u32, generation: u32) -> bool {
    if !ready(frame) || slot as usize >= CTX_CAP {
        return false;
    }
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    let at = OFF_CTX + slot as usize * CTX_STRIDE;
    if get_u32(core, at) != generation || generation == 0 || core[at + 4] == 0 {
        return false;
    }
    for job in 0..JOB_CAP {
        let j = OFF_JOBS + job * JOB_STRIDE;
        if core[j + 4] == slot as u8 && core[j + 6] & 1 == 0 && get_u32(core, j) != 0 {
            core[j + 6] |= 1;
            core[j + 7] = 0;
        }
    }
    let next = generation.saturating_add(1);
    if next == 0 {
        return false;
    }
    put_u32(core, at, next);
    core[at + 4] = 0;
    true
}

fn drop_slow_then_push(core: &mut [u8], kind: u32, token: u32) -> bool {
    for i in 0..IRQ_CAP {
        let at = OFF_IRQS + i * IRQ_STRIDE;
        if core[at] == IRQ_SLOW as u8 {
            core[at] = kind as u8;
            core[at + 1] = token as u8;
            return true;
        }
    }
    false
}

fn push_irq(core: &mut [u8], kind: u8, token: u8) {
    let w = core[OFF_IRQ_W] as usize;
    let at = OFF_IRQS + (w % IRQ_CAP) * IRQ_STRIDE;
    core[at] = kind;
    core[at + 1] = token;
    core[OFF_IRQ_W] = ((w + 1) % IRQ_CAP) as u8;
    core[OFF_IRQ_N] += 1;
}

fn take_irq_priority(frame: &mut [u8; NATIVE_FRAME_BYTES]) -> Option<(u32, u32)> {
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    if core[OFF_IRQ_N] == 0 {
        return None;
    }
    let n = core[OFF_IRQ_N] as usize;
    let r = core[OFF_IRQ_R] as usize;
    let mut found = None;
    for i in 0..n {
        let idx = (r + i) % IRQ_CAP;
        let at = OFF_IRQS + idx * IRQ_STRIDE;
        if core[at] == IRQ_WATCHDOG as u8 {
            found = Some(idx);
            break;
        }
        if found.is_none() {
            found = Some(idx);
        }
    }
    let idx = found?;
    let at = OFF_IRQS + idx * IRQ_STRIDE;
    let kind = core[at] as u32;
    let token = core[at + 1] as u32;
    core[at] = 0;
    core[at + 1] = 0;
    compact_irqs(core, idx);
    Some((kind, token))
}

fn compact_irqs(core: &mut [u8], hole: usize) {
    let n = core[OFF_IRQ_N] as usize;
    let r = core[OFF_IRQ_R] as usize;
    let mut live = [0u8; IRQ_CAP * IRQ_STRIDE];
    let mut m = 0usize;
    for i in 0..n {
        let idx = (r + i) % IRQ_CAP;
        if idx == hole {
            continue;
        }
        let at = OFF_IRQS + idx * IRQ_STRIDE;
        live[m * 2] = core[at];
        live[m * 2 + 1] = core[at + 1];
        m += 1;
    }
    core[OFF_IRQS..OFF_IRQS + IRQ_CAP * IRQ_STRIDE].fill(0);
    core[OFF_IRQS..OFF_IRQS + m * IRQ_STRIDE].copy_from_slice(&live[..m * IRQ_STRIDE]);
    core[OFF_IRQ_R] = 0;
    core[OFF_IRQ_W] = (m % IRQ_CAP) as u8;
    core[OFF_IRQ_N] = m as u8;
}

fn run_watchdog(frame: &mut [u8; NATIVE_FRAME_BYTES], _token: u32) {
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    core[OFF_HITS] = core[OFF_HITS].saturating_add(1);
}

fn admit_job(frame: &mut [u8; NATIVE_FRAME_BYTES], ctx: u8, kind: u32, remaining: u32, token: u32) {
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    if kind != IRQ_SLOW {
        return;
    }
    for job in 0..JOB_CAP {
        let j = OFF_JOBS + job * JOB_STRIDE;
        if get_u32(core, j) == 0 {
            let gen = get_u32(core, OFF_CTX + ctx as usize * CTX_STRIDE);
            put_u32(core, j, gen);
            core[j + 4] = ctx;
            core[j + 5] = kind as u8;
            core[j + 6] = 0;
            core[j + 7] = remaining as u8;
            put_u32(core, j + 8, get_u32(core, OFF_NOW).saturating_add(32));
            put_u32(core, j + 12, token);
            return;
        }
    }
}

fn step_slow(frame: &mut [u8; NATIVE_FRAME_BYTES]) -> bool {
    let core = &mut frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    for job in 0..JOB_CAP {
        let j = OFF_JOBS + job * JOB_STRIDE;
        if get_u32(core, j) == 0 || core[j + 6] & 1 != 0 || core[j + 5] != IRQ_SLOW as u8 {
            continue;
        }
        if core[j + 7] == 0 {
            put_u32(core, j, 0);
            continue;
        }
        core[j + 7] -= 1;
        if core[j + 7] == 0 {
            put_u32(core, j, 0);
        }
        return true;
    }
    false
}

fn remaining_slow(frame: &[u8; NATIVE_FRAME_BYTES]) -> u32 {
    let core = &frame[CORE_OFFSET..CORE_OFFSET + CORE_BYTES];
    let mut total = 0u32;
    for job in 0..JOB_CAP {
        let j = OFF_JOBS + job * JOB_STRIDE;
        if get_u32(core, j) != 0 && core[j + 6] & 1 == 0 && core[j + 5] == IRQ_SLOW as u8 {
            total += core[j + 7] as u32;
        }
    }
    total
}

fn get_u32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

fn put_u32(bytes: &mut [u8], at: usize, value: u32) {
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
}
