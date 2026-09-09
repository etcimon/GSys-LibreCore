// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! UI-thread timer heap (B89). `setTimeout` / `setInterval` / rAF schedule
//! here; `BrowserSession::tick` fires due entries through `WasmUi::call`.
//! Id 0 is never issued (B66 used to return 0 as a silent no-op).

use std::collections::BTreeMap;

use g6b_spec::BoardSpec;

/// Hard cap so a hostile cell cannot grow an unbounded heap.
pub const MAX_TIMERS: usize = 64;
/// Due callbacks per frame (fuel / re-entry budget).
pub const MAX_FIRES_PER_TICK: usize = 8;
/// Delay clamp (one minute).
const MAX_DELAY_NS: u64 = 60_000 * 1_000_000;

/// One scheduled callback. `ptr` is an indirect-table index (libwasm
/// delegate), not a raw function index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Timer {
    pub id: i32,
    pub due_ns: u64,
    pub interval_ns: Option<u64>,
    pub ctx: i32,
    pub ptr: i32,
    pub raf: bool,
}

/// Bounded timer heap. Ids start at 1.
#[derive(Clone, Debug, Default)]
pub struct TimerHeap {
    next_id: i32,
    entries: BTreeMap<i32, Timer>,
}

impl TimerHeap {
    pub fn new() -> Self {
        Self {
            next_id: 1,
            entries: BTreeMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn set_timeout(&mut self, ctx: i32, ptr: i32, ms: i32, now_ns: u64) -> Result<i32, String> {
        self.insert(ctx, ptr, delay_ns(ms), None, false, now_ns)
    }

    pub fn set_interval(
        &mut self,
        ctx: i32,
        ptr: i32,
        ms: i32,
        now_ns: u64,
    ) -> Result<i32, String> {
        let d = delay_ns(ms).max(1_000_000);
        self.insert(ctx, ptr, d, Some(d), false, now_ns)
    }

    pub fn request_animation_frame(
        &mut self,
        ctx: i32,
        ptr: i32,
        now_ns: u64,
        frame_period_ns: u64,
    ) -> Result<i32, String> {
        let d = frame_period_ns.max(1);
        self.insert(ctx, ptr, d, None, true, now_ns)
    }

    pub fn clear(&mut self, id: i32) {
        if id > 0 {
            self.entries.remove(&id);
        }
    }

    /// Pop up to `max` timers with `due_ns <= now_ns`. Intervals are
    /// rescheduled from `now_ns`; one-shots (timeout/rAF) are removed.
    pub fn take_due(&mut self, now_ns: u64, max: usize) -> Vec<Timer> {
        let mut ids: Vec<i32> = self
            .entries
            .values()
            .filter(|t| t.due_ns <= now_ns)
            .map(|t| t.id)
            .collect();
        ids.sort_unstable();
        ids.truncate(max);
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(t) = self.entries.remove(&id) {
                if let Some(period) = t.interval_ns {
                    let mut next = t.clone();
                    next.due_ns = now_ns.saturating_add(period);
                    self.entries.insert(id, next);
                }
                out.push(t);
            }
        }
        out
    }

    fn insert(
        &mut self,
        ctx: i32,
        ptr: i32,
        delay_ns: u64,
        interval_ns: Option<u64>,
        raf: bool,
        now_ns: u64,
    ) -> Result<i32, String> {
        if self.entries.len() >= MAX_TIMERS {
            return Err("timer heap budget exceeded".into());
        }
        if self.next_id <= 0 {
            return Err("timer id space exhausted".into());
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        self.entries.insert(
            id,
            Timer {
                id,
                due_ns: now_ns.saturating_add(delay_ns),
                interval_ns,
                ctx,
                ptr,
                raf,
            },
        );
        Ok(id)
    }
}

fn delay_ns(ms: i32) -> u64 {
    let ms = u64::from(ms.max(0) as u32);
    ms.saturating_mul(1_000_000).min(MAX_DELAY_NS)
}

/// Frame period from BoardSpec `fps` (including 100/144).
pub fn frame_period_ns(spec: &BoardSpec) -> u64 {
    let hz = spec.kernel.proxy.refresh_hz().max(1);
    1_000_000_000 / u64::from(hz)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_positive_and_timeout_fires_once() {
        let mut h = TimerHeap::new();
        let id = h.set_timeout(1, 2, 10, 0).unwrap();
        assert!(id > 0);
        assert!(h.take_due(5_000_000, 8).is_empty());
        let due = h.take_due(10_000_000, 8);
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].id, id);
        assert!(h.take_due(20_000_000, 8).is_empty());
    }

    #[test]
    fn interval_reschedules() {
        let mut h = TimerHeap::new();
        let id = h.set_interval(0, 1, 5, 0).unwrap();
        let first = h.take_due(5_000_000, 8);
        assert_eq!(first.len(), 1);
        let second = h.take_due(10_000_000, 8);
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].id, id);
        h.clear(id);
        assert!(h.take_due(20_000_000, 8).is_empty());
    }

    #[test]
    fn raf_is_one_shot_at_frame_period() {
        let mut h = TimerHeap::new();
        let period = 8_333_333;
        let id = h.request_animation_frame(0, 3, 0, period).unwrap();
        assert!(id > 0);
        assert!(h.take_due(period - 1, 8).is_empty());
        assert_eq!(h.take_due(period, 8).len(), 1);
        assert!(h.take_due(period * 2, 8).is_empty());
    }

    #[test]
    fn budget_is_fail_closed() {
        let mut h = TimerHeap::new();
        for _ in 0..MAX_TIMERS {
            h.set_timeout(0, 1, 1, 0).unwrap();
        }
        assert!(h.set_timeout(0, 1, 1, 0).is_err());
    }
}
