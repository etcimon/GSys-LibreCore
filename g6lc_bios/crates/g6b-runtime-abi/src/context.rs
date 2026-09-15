// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Per-instance wasm/DOM/Asyncify ownership.
//!
//! P1 leftover after the poll loop: image-global `P_ASUSP` is one suspend
//! slot. This table is the portable owner — generation-checked handles,
//! independent continuation records, teardown that cannot alias a neighbour.
//! Not a guest `__prom` rewrite, not an `alloc` heap, not QEMU.

use crate::{Context, Error, Span};

/// Bounded independent applications (iframes / cells).
pub const RUNTIME_CTX_MAX: usize = 4;

/// Bounded tagged-throw payload cells (matches guest `MAX_EXCPAY`).
pub const EXC_PAY_CELLS: usize = 4;

/// One Asyncify/promise continuation owned by a [`RuntimeContext`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Continuation {
    pub pc: u32,
    pub asyncify_off: u32,
    pub asyncify_len: u32,
    /// Guest `__prom` handle (`P_ASUSP` equivalent), 0 = none.
    pub prom_handle: u32,
    /// In-flight wasm exception flag (`OFF_EXC`); 0 = none.
    pub exc: u32,
    /// In-flight exception tag (`OFF_EXCTAG`).
    pub exc_tag: u32,
    /// In-flight payload cells (`OFF_EXCPAY`, deepest first).
    pub exc_pay: [u64; EXC_PAY_CELLS],
}

#[derive(Clone, Copy, Debug)]
struct Slot {
    generation: u32,
    live: bool,
    wasm_mem: Span,
    dom_stamp: u64,
    suspend: Option<Continuation>,
}

impl Slot {
    const fn empty() -> Self {
        Self {
            generation: 1,
            live: false,
            wasm_mem: Span {
                address: 0,
                length: 0,
            },
            dom_stamp: 0,
            suspend: None,
        }
    }
}

/// Bounded table of wasm/DOM/Asyncify instances.
pub struct ContextTable {
    slots: [Slot; RUNTIME_CTX_MAX],
}

impl Default for ContextTable {
    fn default() -> Self {
        Self::new()
    }
}

impl ContextTable {
    pub const fn new() -> Self {
        Self {
            slots: [Slot::empty(); RUNTIME_CTX_MAX],
        }
    }

    /// Allocate a live slot. Rejects overlapping wasm windows so two
    /// instances cannot alias memory.
    pub fn open(&mut self, wasm_mem: Span, dom_stamp: u64) -> Result<Context, Error> {
        if wasm_mem.length != 0 {
            let _ = wasm_mem.end()?;
        }
        for slot in &self.slots {
            if slot.live && wasm_mem.overlaps(slot.wasm_mem)? {
                return Err(Error::Overlap);
            }
        }
        for (i, slot) in self.slots.iter_mut().enumerate() {
            if slot.live {
                continue;
            }
            if slot.generation == 0 {
                slot.generation = 1;
            }
            slot.live = true;
            slot.wasm_mem = wasm_mem;
            slot.dom_stamp = dom_stamp;
            slot.suspend = None;
            return Ok(Context {
                slot: i as u32,
                generation: slot.generation,
            });
        }
        Err(Error::Overflow)
    }

    /// Bump generation, drop the continuation, free the slot.
    pub fn teardown(&mut self, handle: Context) -> Result<(), Error> {
        let slot = self.slot_mut(handle)?;
        let next = slot.generation.saturating_add(1);
        if next == 0 {
            return Err(Error::Overflow);
        }
        slot.generation = next;
        slot.live = false;
        slot.suspend = None;
        slot.wasm_mem = Span {
            address: 0,
            length: 0,
        };
        slot.dom_stamp = 0;
        Ok(())
    }

    pub fn wasm_mem(&self, handle: Context) -> Result<Span, Error> {
        Ok(self.slot(handle)?.wasm_mem)
    }

    pub fn dom_stamp(&self, handle: Context) -> Result<u64, Error> {
        Ok(self.slot(handle)?.dom_stamp)
    }

    pub fn suspend(&mut self, handle: Context, cont: Continuation) -> Result<(), Error> {
        let slot = self.slot_mut(handle)?;
        slot.suspend = Some(cont);
        Ok(())
    }

    /// Take the continuation. Missing/stale is `Error::Context`.
    pub fn take_resume(&mut self, handle: Context) -> Result<Continuation, Error> {
        let slot = self.slot_mut(handle)?;
        slot.suspend.take().ok_or(Error::Context)
    }

    fn slot(&self, handle: Context) -> Result<&Slot, Error> {
        let i = handle.slot as usize;
        if i >= RUNTIME_CTX_MAX || handle.generation == 0 {
            return Err(Error::Context);
        }
        let slot = &self.slots[i];
        if !slot.live || slot.generation != handle.generation {
            return Err(Error::Context);
        }
        Ok(slot)
    }

    fn slot_mut(&mut self, handle: Context) -> Result<&mut Slot, Error> {
        let i = handle.slot as usize;
        if i >= RUNTIME_CTX_MAX || handle.generation == 0 {
            return Err(Error::Context);
        }
        let slot = &mut self.slots[i];
        if !slot.live || slot.generation != handle.generation {
            return Err(Error::Context);
        }
        Ok(slot)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem(address: u64, length: u64) -> Span {
        Span { address, length }
    }

    #[test]
    fn two_contexts_keep_independent_continuations() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x1000), 1).unwrap();
        let b = t.open(mem(0x3000, 0x1000), 2).unwrap();
        assert_ne!(a.slot, b.slot);
        t.suspend(
            a,
            Continuation {
                pc: 11,
                asyncify_off: 1,
                asyncify_len: 8,
                prom_handle: 3,
                ..Continuation::default()
            },
        )
        .unwrap();
        t.suspend(
            b,
            Continuation {
                pc: 22,
                asyncify_off: 2,
                asyncify_len: 8,
                prom_handle: 4,
                ..Continuation::default()
            },
        )
        .unwrap();
        let ra = t.take_resume(a).unwrap();
        let rb = t.take_resume(b).unwrap();
        assert_eq!(ra.pc, 11);
        assert_eq!(ra.prom_handle, 3);
        assert_eq!(rb.pc, 22);
        assert_eq!(rb.prom_handle, 4);
        assert_eq!(t.dom_stamp(a).unwrap(), 1);
        assert_eq!(t.dom_stamp(b).unwrap(), 2);
    }

    #[test]
    fn two_contexts_keep_independent_exceptions() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x1000), 1).unwrap();
        let b = t.open(mem(0x3000, 0x1000), 2).unwrap();
        t.suspend(
            a,
            Continuation {
                exc: 1,
                exc_tag: 7,
                exc_pay: [99, 0, 0, 0],
                ..Continuation::default()
            },
        )
        .unwrap();
        t.suspend(
            b,
            Continuation {
                exc: 1,
                exc_tag: 3,
                exc_pay: [4, 0, 0, 0],
                ..Continuation::default()
            },
        )
        .unwrap();
        let ra = t.take_resume(a).unwrap();
        let rb = t.take_resume(b).unwrap();
        assert_eq!(ra.exc, 1);
        assert_eq!(ra.exc_tag, 7);
        assert_eq!(ra.exc_pay[0], 99);
        assert_eq!(rb.exc_tag, 3);
        assert_eq!(rb.exc_pay[0], 4);
        assert_ne!(ra.exc_tag, rb.exc_tag);
    }

    #[test]
    fn teardown_drops_exception() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x100), 1).unwrap();
        let b = t.open(mem(0x2000, 0x100), 2).unwrap();
        t.suspend(
            a,
            Continuation {
                exc: 1,
                exc_tag: 7,
                exc_pay: [99, 0, 0, 0],
                ..Continuation::default()
            },
        )
        .unwrap();
        t.suspend(
            b,
            Continuation {
                exc: 1,
                exc_tag: 3,
                ..Continuation::default()
            },
        )
        .unwrap();
        t.teardown(a).unwrap();
        assert!(t.take_resume(a).is_err());
        let rb = t.take_resume(b).unwrap();
        assert_eq!(rb.exc_tag, 3);
    }

    #[test]
    fn teardown_does_not_cancel_neighbour() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x100), 1).unwrap();
        let b = t.open(mem(0x2000, 0x100), 2).unwrap();
        t.suspend(
            b,
            Continuation {
                pc: 99,
                asyncify_off: 0,
                asyncify_len: 0,
                prom_handle: 1,
                ..Continuation::default()
            },
        )
        .unwrap();
        t.teardown(a).unwrap();
        assert!(t.take_resume(a).is_err());
        assert_eq!(t.take_resume(b).unwrap().pc, 99);
    }

    #[test]
    fn stale_generation_after_teardown_is_rejected() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x100), 1).unwrap();
        t.teardown(a).unwrap();
        assert_eq!(t.wasm_mem(a), Err(Error::Context));
        let a2 = t.open(mem(0x1000, 0x100), 9).unwrap();
        assert_eq!(a2.slot, a.slot);
        assert_ne!(a2.generation, a.generation);
        assert_eq!(t.dom_stamp(a), Err(Error::Context));
        assert_eq!(t.dom_stamp(a2).unwrap(), 9);
    }

    #[test]
    fn overlapping_wasm_windows_are_rejected() {
        let mut t = ContextTable::new();
        let _ = t.open(mem(0x1000, 0x200), 1).unwrap();
        assert_eq!(t.open(mem(0x1100, 0x100), 2), Err(Error::Overlap));
    }

    #[test]
    fn table_full_is_overflow() {
        let mut t = ContextTable::new();
        for i in 0..RUNTIME_CTX_MAX {
            t.open(mem(0x1000 * (i as u64 + 1), 0x100), i as u64)
                .unwrap();
        }
        assert_eq!(t.open(mem(0x9000, 0x100), 9), Err(Error::Overflow));
    }

    #[test]
    fn foreign_handle_cannot_resume_this_slot() {
        let mut t = ContextTable::new();
        let a = t.open(mem(0x1000, 0x100), 1).unwrap();
        t.suspend(
            a,
            Continuation {
                pc: 7,
                asyncify_off: 0,
                asyncify_len: 0,
                prom_handle: 0,
                ..Continuation::default()
            },
        )
        .unwrap();
        let fake = Context {
            slot: a.slot,
            generation: a.generation.wrapping_add(1),
        };
        assert_eq!(t.take_resume(fake), Err(Error::Context));
        assert_eq!(t.take_resume(a).unwrap().pc, 7);
    }
}
