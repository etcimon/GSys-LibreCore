// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Refcounted libwasm object table (B61).
//!
//! `struct JsHandle` in `libwasm/source/libwasm/types.d:454-490` is
//! explicitly refcounted, not garbage collected: the destructor calls
//! `libwasm_removeObject(handle)` when `handle > 2` and the copy constructor
//! calls `libwasm_copyObjectRef(rhs.handle)`. A host that ignores either one is
//! wrong in a way the guest cannot detect, so this table implements both and
//! fails closed on double-free and use-after-free.
//!
//! Handles `1` and `2` are permanently-live roots the guest never frees.
//! svelte-engine `libwasm.ts` maps them to `document` and `window`. The
//! G6LC_G6B cell's `getRoot()` still returns 1 as the Spa mount (a `#root`
//! stand-in). That is a transitional BIOS shortcut, **not** a BoardSpec
//! object and **not** a kernel type: `libwasm_global("document"|"window")`
//! intern the live browser instance on the UI-thread Host.
//! `copy` of a root is identity and `remove` of a root is an error.

/// Spa mount / document root — never allocated, never freed.
pub const OBJECT_ROOT_DOM: i32 = 1;
/// `window` root in svelte-engine. The shipped G6LC_G6B cell still uses DOM
/// handle 2 as the first `createElement`; interned `window` lives at
/// `OBJECT_BASE+` via `libwasm_global("window")` until the LDC cell's
/// `getRoot()` matches svelte-engine (`querySelector('#root')`).
pub const OBJECT_ROOT_SCOPE: i32 = 2;
/// First handle this table hands out. Above the DOM handle space so a DOM
/// handle can never be mistaken for an object handle while the two spaces
/// remain separate (they merge in B63).
pub const OBJECT_BASE: i32 = 0x0010_0000;
/// Live-object budget, matching the DOM handle budget.
pub const MAX_OBJECTS: usize = 4096;

/// True for the two roots that exist before any allocation.
pub fn is_root(handle: i32) -> bool {
    handle == OBJECT_ROOT_DOM || handle == OBJECT_ROOT_SCOPE
}

#[derive(Debug, Clone)]
struct Slot<T> {
    value: T,
    /// `JsHandle` references outstanding in the guest. Zero means free.
    refs: u32,
}

/// Bounded, refcounted handle table shared by every Rust libwasm host.
#[derive(Debug, Clone)]
pub struct ObjectTable<T> {
    slots: Vec<Option<Slot<T>>>,
    free: Vec<usize>,
    live: usize,
}

impl<T> Default for ObjectTable<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> ObjectTable<T> {
    pub fn new() -> Self {
        Self {
            slots: Vec::new(),
            free: Vec::new(),
            live: 0,
        }
    }

    /// Number of live objects (excludes the two roots, which are not stored).
    pub fn len(&self) -> usize {
        self.live
    }

    pub fn is_empty(&self) -> bool {
        self.live == 0
    }

    fn index(handle: i32) -> Result<usize, String> {
        if is_root(handle) {
            return Err(format!("libwasm handle {handle} is a protected root"));
        }
        if handle < OBJECT_BASE {
            return Err(format!("invalid libwasm object handle {handle}"));
        }
        Ok((handle - OBJECT_BASE) as usize)
    }

    /// Insert `value` with one outstanding reference.
    pub fn add(&mut self, value: T) -> Result<i32, String> {
        if self.live >= MAX_OBJECTS {
            return Err(format!(
                "libwasm object budget exceeded ({MAX_OBJECTS} live handles)"
            ));
        }
        let slot = Slot { value, refs: 1 };
        let idx = match self.free.pop() {
            Some(idx) => {
                self.slots[idx] = Some(slot);
                idx
            }
            None => {
                self.slots.push(Some(slot));
                self.slots.len() - 1
            }
        };
        self.live += 1;
        i32::try_from(idx)
            .ok()
            .and_then(|i| i.checked_add(OBJECT_BASE))
            .ok_or_else(|| "libwasm object handle space exhausted".to_string())
    }

    /// `env.libwasm_copyObjectRef` — one more outstanding `JsHandle`.
    /// Copying a root is identity: the guest never frees it.
    pub fn copy_ref(&mut self, handle: i32) -> Result<i32, String> {
        if is_root(handle) {
            return Ok(handle);
        }
        let idx = Self::index(handle)?;
        let slot = self
            .slots
            .get_mut(idx)
            .and_then(|s| s.as_mut())
            .ok_or_else(|| format!("libwasm copyObjectRef on freed handle {handle}"))?;
        slot.refs = slot
            .refs
            .checked_add(1)
            .ok_or_else(|| format!("libwasm refcount overflow on handle {handle}"))?;
        Ok(handle)
    }

    /// `env.libwasm_removeObject` — drop one reference, freeing at zero.
    /// Returns `true` when the object was actually released.
    pub fn remove_ref(&mut self, handle: i32) -> Result<bool, String> {
        let idx = Self::index(handle)?;
        let slot = self
            .slots
            .get_mut(idx)
            .and_then(|s| s.as_mut())
            .ok_or_else(|| format!("libwasm removeObject on freed handle {handle}"))?;
        slot.refs -= 1;
        if slot.refs > 0 {
            return Ok(false);
        }
        self.slots[idx] = None;
        self.free.push(idx);
        self.live -= 1;
        Ok(true)
    }

    pub fn get(&self, handle: i32) -> Result<&T, String> {
        let idx = Self::index(handle)?;
        self.slots
            .get(idx)
            .and_then(|s| s.as_ref())
            .map(|s| &s.value)
            .ok_or_else(|| format!("libwasm use of freed object handle {handle}"))
    }

    pub fn get_mut(&mut self, handle: i32) -> Result<&mut T, String> {
        let idx = Self::index(handle)?;
        self.slots
            .get_mut(idx)
            .and_then(|s| s.as_mut())
            .map(|s| &mut s.value)
            .ok_or_else(|| format!("libwasm use of freed object handle {handle}"))
    }

    /// Outstanding reference count, for tests and diagnostics.
    pub fn refs(&self, handle: i32) -> Result<u32, String> {
        let idx = Self::index(handle)?;
        self.slots
            .get(idx)
            .and_then(|s| s.as_ref())
            .map(|s| s.refs)
            .ok_or_else(|| format!("libwasm refcount of freed handle {handle}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refcount_copy_and_remove_release_exactly_once() {
        let mut t: ObjectTable<String> = ObjectTable::new();
        let h = t.add("menu".into()).unwrap();
        assert_eq!(h, OBJECT_BASE);
        assert_eq!(t.refs(h).unwrap(), 1);
        assert_eq!(t.copy_ref(h).unwrap(), h, "copy returns the same handle");
        assert_eq!(t.refs(h).unwrap(), 2);
        assert_eq!(t.len(), 1, "a copy is not a second object");

        assert!(!t.remove_ref(h).unwrap(), "still referenced");
        assert_eq!(t.get(h).unwrap(), "menu");
        assert!(t.remove_ref(h).unwrap(), "last reference releases");
        assert_eq!(t.len(), 0);
    }

    #[test]
    fn double_free_and_use_after_free_fail_closed() {
        let mut t: ObjectTable<String> = ObjectTable::new();
        let h = t.add("gone".into()).unwrap();
        assert!(t.remove_ref(h).unwrap());
        let err = t.remove_ref(h).unwrap_err();
        assert!(err.contains("freed"), "{err}");
        let err = t.get(h).unwrap_err();
        assert!(err.contains("freed"), "{err}");
        let err = t.copy_ref(h).unwrap_err();
        assert!(err.contains("freed"), "{err}");
    }

    #[test]
    fn roots_are_copyable_but_never_freed_or_allocated_over() {
        let mut t: ObjectTable<String> = ObjectTable::new();
        for root in [OBJECT_ROOT_DOM, OBJECT_ROOT_SCOPE] {
            assert_eq!(t.copy_ref(root).unwrap(), root);
            let err = t.remove_ref(root).unwrap_err();
            assert!(err.contains("protected root"), "{err}");
            assert!(t.get(root).unwrap_err().contains("protected root"));
        }
        // Roots occupy no slot, so the first allocation is still OBJECT_BASE.
        assert_eq!(t.add("first".into()).unwrap(), OBJECT_BASE);
    }

    #[test]
    fn freed_slots_are_reused_and_the_budget_is_enforced() {
        let mut t: ObjectTable<u32> = ObjectTable::new();
        let a = t.add(1).unwrap();
        let b = t.add(2).unwrap();
        assert_ne!(a, b);
        assert!(t.remove_ref(a).unwrap());
        assert_eq!(t.add(3).unwrap(), a, "freed slot is reused");

        let mut full: ObjectTable<u32> = ObjectTable::new();
        for i in 0..MAX_OBJECTS {
            full.add(i as u32).unwrap();
        }
        let err = full.add(0).unwrap_err();
        assert!(err.contains("budget exceeded"), "{err}");
        // The budget is on live objects, not on handles ever issued.
        assert!(full.remove_ref(OBJECT_BASE).unwrap());
        full.add(0).expect("a release makes room");
    }

    #[test]
    fn handles_below_the_base_are_rejected_without_panicking() {
        let mut t: ObjectTable<u32> = ObjectTable::new();
        for h in [i32::MIN, -1, 0, 3, OBJECT_BASE - 1] {
            assert!(t.get(h).is_err());
            assert!(t.remove_ref(h).is_err());
            assert!(t.copy_ref(h).is_err());
        }
        assert!(
            t.get(i32::MAX).is_err(),
            "far handle is absent, not a panic"
        );
    }
}
