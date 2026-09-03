// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-vm` — backend **B3**, the native virtual machine.
//!
//! B3 is not a luxury tier. It is what keeps a working fast path and the entire diagnosis
//! layer inside MIT, so continuous integration and the tandem oracle never depend on
//! building a GPL emulator ([`architecture/DESIGN.md`] §3).
//!
//! It also owns the machinery that is awkward to bolt onto a third-party emulator:
//! deterministic time, record and replay of memory-mapped I/O and interrupts, and
//! checkpoint export.
//!
//! # Determinism
//!
//! Nothing here may consult a host clock. Time advances on a fixed
//! retired-instructions-per-tick ratio, and every asynchronous event is delivered at a
//! `(hart, retired-instruction-count)` boundary. A non-deterministic oracle is not an
//! oracle ([`architecture/DIAG.md`] §1).
//!
//! # Stage
//!
//! Q0 defines the deterministic clock and the execution-tier vocabulary. Q3 adds the
//! interpreter, the address-translation walker and the faithful devices.
//!
//! [`architecture/DESIGN.md`]: ../../../architecture/DESIGN.md
//! [`architecture/DIAG.md`]: ../../../architecture/DIAG.md

#![forbid(unsafe_code)]

pub mod c;
pub mod csr;
pub mod device;
pub mod exec;
pub mod gemm;
pub mod insn;
pub mod mem;
pub mod mmu;
pub mod numfmt;
pub mod regs;

pub use exec::{Halt, Hart};
pub use insn::{decode, Insn};
pub use mem::{MemError, PhysMem, Region};
pub use regs::{Fregs, Regs};

/// Deterministic clock (re-exported from the Q0 scaffold).
pub type Clock = DeterministicClock;

impl Default for DeterministicClock {
    fn default() -> Self {
        Self::new(1)
    }
}

/// Execution tiers, in the order they are implemented.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Tier {
    /// Decode-cached threaded interpreter. Correctness before speed; the tandem oracle.
    #[default]
    Interpreter,
    /// Basic-block translation with chaining. Only if profiling justifies it.
    BlockJit,
    /// Region translation with register promotion. Deferred; no gate requires it.
    RegionJit,
}

impl Tier {
    /// Stable wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Interpreter => "interpreter",
            Tier::BlockJit => "block-jit",
            Tier::RegionJit => "region-jit",
        }
    }

    /// Whether this tier is implemented at the current stage.
    pub fn implemented(self) -> bool {
        matches!(self, Tier::Interpreter)
    }
}

/// A deterministic time base.
///
/// The machine's timer counter is derived from retired instructions, never from a host
/// clock, so that two runs of the same workload deliver interrupts at exactly the same
/// instruction boundaries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeterministicClock {
    instret: u64,
    instret_per_tick: u64,
}

impl DeterministicClock {
    /// Create a clock that advances one tick per `instret_per_tick` retired instructions.
    ///
    /// A ratio of zero is meaningless and is clamped to one, because a divide-by-zero
    /// here would be a panic in the middle of a long run.
    pub fn new(instret_per_tick: u64) -> Self {
        Self {
            instret: 0,
            instret_per_tick: instret_per_tick.max(1),
        }
    }

    /// Create a clock with a pre-existing retired-instruction count.
    pub fn with_instret(instret_per_tick: u64, instret: u64) -> Self {
        let mut c = Self::new(instret_per_tick);
        c.retire(instret);
        c
    }

    /// Retire `n` instructions.
    pub fn retire(&mut self, n: u64) {
        self.instret = self.instret.saturating_add(n);
    }

    /// Total retired instructions.
    pub fn instret(&self) -> u64 {
        self.instret
    }

    /// Retirement ratio: one clock tick per this many retired instructions.
    pub fn instret_per_tick(&self) -> u64 {
        self.instret_per_tick
    }

    /// The current timer value.
    pub fn ticks(&self) -> u64 {
        self.instret / self.instret_per_tick
    }

    /// The retired-instruction count at which `tick` is first observable.
    ///
    /// Used to schedule a timer interrupt at a reproducible instruction boundary rather
    /// than "whenever we next look".
    pub fn instret_for_tick(&self, tick: u64) -> u64 {
        tick.saturating_mul(self.instret_per_tick)
    }
}

/// An asynchronous event pinned to a reproducible point in the instruction stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ScheduledEvent {
    /// Retired-instruction count at which the event is delivered.
    pub instret: u64,
    /// Which hart observes it.
    pub hart: u32,
    /// Interrupt or event identifier.
    pub id: u32,
}

/// A replayable event schedule.
///
/// Ordering is by `(instret, hart, id)` so that a recorded schedule replays identically
/// no matter what order events were captured in.
#[derive(Debug, Clone, Default)]
pub struct Schedule {
    events: Vec<ScheduledEvent>,
}

impl Schedule {
    /// An empty schedule.
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert an event, keeping the schedule canonically ordered.
    pub fn insert(&mut self, event: ScheduledEvent) {
        let pos = self.events.partition_point(|e| e < &event);
        self.events.insert(pos, event);
    }

    /// Events due at or before `instret` for a given hart, in order.
    pub fn due(&self, hart: u32, instret: u64) -> Vec<ScheduledEvent> {
        self.events
            .iter()
            .copied()
            .filter(|e| e.hart == hart && e.instret <= instret)
            .collect()
    }

    /// All events, canonically ordered.
    pub fn events(&self) -> &[ScheduledEvent] {
        &self.events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_interpreter_tier_exists_yet() {
        assert!(Tier::Interpreter.implemented());
        assert!(!Tier::BlockJit.implemented());
        assert!(!Tier::RegionJit.implemented());
        assert_eq!(Tier::default(), Tier::Interpreter);
    }

    #[test]
    fn time_is_derived_from_retired_instructions() {
        let mut c = DeterministicClock::new(100);
        assert_eq!(c.ticks(), 0);
        c.retire(99);
        assert_eq!(c.ticks(), 0);
        c.retire(1);
        assert_eq!(c.ticks(), 1);
        c.retire(250);
        assert_eq!(c.ticks(), 3);
        assert_eq!(c.instret(), 350);
    }

    #[test]
    fn two_identical_runs_produce_identical_time() {
        let run = || {
            let mut c = DeterministicClock::new(64);
            for _ in 0..1000 {
                c.retire(7);
            }
            (c.instret(), c.ticks())
        };
        assert_eq!(run(), run());
    }

    #[test]
    fn a_zero_ratio_cannot_divide_by_zero() {
        let mut c = DeterministicClock::new(0);
        c.retire(5);
        assert_eq!(c.ticks(), 5);
    }

    #[test]
    fn tick_boundaries_are_computable_in_advance() {
        let c = DeterministicClock::new(100);
        assert_eq!(c.instret_for_tick(3), 300);
    }

    #[test]
    fn a_schedule_is_canonically_ordered_regardless_of_insertion_order() {
        let mut a = Schedule::new();
        a.insert(ScheduledEvent {
            instret: 200,
            hart: 0,
            id: 1,
        });
        a.insert(ScheduledEvent {
            instret: 100,
            hart: 1,
            id: 2,
        });
        a.insert(ScheduledEvent {
            instret: 100,
            hart: 0,
            id: 3,
        });

        let mut b = Schedule::new();
        b.insert(ScheduledEvent {
            instret: 100,
            hart: 0,
            id: 3,
        });
        b.insert(ScheduledEvent {
            instret: 200,
            hart: 0,
            id: 1,
        });
        b.insert(ScheduledEvent {
            instret: 100,
            hart: 1,
            id: 2,
        });

        assert_eq!(a.events(), b.events());
        assert_eq!(a.events()[0].instret, 100);
        assert_eq!(a.events()[0].hart, 0);
    }

    #[test]
    fn events_are_delivered_per_hart_at_instruction_boundaries() {
        let mut s = Schedule::new();
        s.insert(ScheduledEvent {
            instret: 100,
            hart: 0,
            id: 7,
        });
        s.insert(ScheduledEvent {
            instret: 150,
            hart: 1,
            id: 8,
        });
        s.insert(ScheduledEvent {
            instret: 300,
            hart: 0,
            id: 9,
        });

        assert_eq!(s.due(0, 99).len(), 0);
        assert_eq!(s.due(0, 100).len(), 1);
        assert_eq!(
            s.due(0, 299).len(),
            1,
            "hart 1's event must not leak to hart 0"
        );
        assert_eq!(s.due(0, 300).len(), 2);
        assert_eq!(s.due(1, 300).len(), 1);
    }
}
