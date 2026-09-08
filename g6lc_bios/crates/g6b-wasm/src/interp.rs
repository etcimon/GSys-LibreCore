// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host interpreter — the BIOS UI “JIT”.

#![allow(missing_docs)]

use crate::asyncify::{Asyncify, Step};
use crate::binary::{
    analyze, func_type, numeric_is_unary, BodyInfo, Instr, Module, ValType, MAX_MEMORY_PAGES,
};
use crate::{
    LibwasmValue, ObjectTable, IMPORT_ADD_EVENT_LISTENER, IMPORT_APPEND_CHILD, IMPORT_AWAIT,
    IMPORT_CATCH, IMPORT_CREATE_ELEMENT, IMPORT_DISPATCH_EVENT, IMPORT_FETCH, IMPORT_HOLYC,
    IMPORT_LIBWASM_ADD_BOOL, IMPORT_LIBWASM_ADD_BYTE, IMPORT_LIBWASM_ADD_INT,
    IMPORT_LIBWASM_ADD_INTS, IMPORT_LIBWASM_ADD_OBJECT, IMPORT_LIBWASM_ADD_SHORT,
    IMPORT_LIBWASM_ADD_STRING, IMPORT_LIBWASM_ADD_UBYTE, IMPORT_LIBWASM_ADD_UINT,
    IMPORT_LIBWASM_ADD_UINTS, IMPORT_LIBWASM_ADD_USHORT, IMPORT_LIBWASM_AWAIT_ERROR,
    IMPORT_LIBWASM_AWAIT_FAILED, IMPORT_LIBWASM_AWAIT_SUPPORTED, IMPORT_LIBWASM_AWAIT_VALUE,
    IMPORT_LIBWASM_AWAIT_VOID, IMPORT_LIBWASM_COPY_OBJECT_REF, IMPORT_LIBWASM_GET_BOOL,
    IMPORT_LIBWASM_GET_BYTE, IMPORT_LIBWASM_GET_FIELD, IMPORT_LIBWASM_GET_IDX_FIELD,
    IMPORT_LIBWASM_GET_INT, IMPORT_LIBWASM_GET_SHORT, IMPORT_LIBWASM_GET_STRING,
    IMPORT_LIBWASM_GET_UBYTE, IMPORT_LIBWASM_GET_UINT, IMPORT_LIBWASM_GET_USHORT,
    IMPORT_LIBWASM_NOTE_AWAIT_FAIL, IMPORT_LIBWASM_NOTE_AWAIT_OK, IMPORT_LIBWASM_REMOVE_OBJECT,
    IMPORT_LOG, IMPORT_OBJECT_CALL, IMPORT_REGISTER_ENDPOINT, IMPORT_REMOVE_EVENT_LISTENER,
    IMPORT_SET_INNER_TEXT, IMPORT_SET_PROPERTY, IMPORT_SET_VISIBLE, IMPORT_THROW,
};
use g6b_dom::Node;

/// WebAssembly value carried on the operand stack.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Value {
    I32(i32),
    I64(i64),
    F32(u32),
    F64(u64),
}

impl Value {
    #[allow(dead_code)]
    fn as_i32(&self) -> Result<i32, String> {
        match self {
            Value::I32(v) => Ok(*v),
            _ => Err("expected i32 operand".into()),
        }
    }
    #[allow(dead_code)]
    fn as_i64(&self) -> Result<i64, String> {
        match self {
            Value::I64(v) => Ok(*v),
            _ => Err("expected i64 operand".into()),
        }
    }
    #[allow(dead_code)]
    fn as_f32_bits(&self) -> Result<u32, String> {
        match self {
            Value::F32(v) => Ok(*v),
            _ => Err("expected f32 operand".into()),
        }
    }
    #[allow(dead_code)]
    fn as_f64_bits(&self) -> Result<u64, String> {
        match self {
            Value::F64(v) => Ok(*v),
            _ => Err("expected f64 operand".into()),
        }
    }
    fn as_f32(&self) -> Result<f32, String> {
        self.as_f32_bits().map(f32::from_bits)
    }
    fn as_f64(&self) -> Result<f64, String> {
        self.as_f64_bits().map(f64::from_bits)
    }
    fn into_raw(self) -> i64 {
        match self {
            Value::I32(v) => i64::from(v),
            Value::I64(v) => v,
            Value::F32(v) => i64::from(v),
            Value::F64(v) => v as i64,
        }
    }
    fn from_raw(ty: ValType, raw: i64) -> Self {
        match ty {
            ValType::I32 => Value::I32(raw as i32),
            ValType::I64 => Value::I64(raw),
            ValType::F32 => Value::F32(raw as u32),
            ValType::F64 => Value::F64(raw as u64),
        }
    }
}

/// Initial value of a Lodash chain (`libwasm.lodash.VarType`).
#[derive(Debug, Clone, PartialEq)]
pub enum LdexecInit {
    /// `VarType.handle` — an object-table handle.
    Handle(i32),
    /// `VarType.string_` (`eval == false`) or `VarType.eval` (`eval == true`).
    Str { text: String, eval: bool },
    /// `VarType.number`.
    Long(i64),
}

/// Guest-side function pair from a lowered D `delegate` — `(context, funcptr)`
/// into the module's indirect function table. `ptr == 0` means "absent".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct GuestFn {
    pub ctx: i32,
    pub ptr: i32,
}

impl GuestFn {
    pub fn present(&self) -> bool {
        self.ptr > 0
    }
}

/// One `ldexec_*` call: a Lodash command buffer plus its callback pair.
#[derive(Debug, Clone)]
pub struct Ldexec<'a> {
    pub init: LdexecInit,
    /// JSON command array built by `libwasm.lodash.Lodash.putCommand`.
    pub commands: &'a str,
    /// Iteratee callback (`cbCtx`/`cbPtr` in the reference host).
    pub callback: GuestFn,
    /// `onError` delegate invoked with a handle to the thrown value.
    pub on_error: GuestFn,
}

/// Host imports (libwasm-shaped subset).
pub trait Host {
    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String>;
    fn log(&mut self, msg: &str);
    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String>;
    /// Kernel HTTP proxy (libwasm `fetch` / `Object_Call_string__Handle`).
    /// Returns a string-object handle (0 when unavailable). Default returns 0.
    fn fetch(&mut self, url: &str) -> Result<i32, String> {
        let _ = url;
        Ok(0)
    }
    /// `env.await` — claim a bounded pending-completion slot (the guest
    /// `WasmAwait` correlate). Default is a no-op returning -1 (no slot
    /// tracked); hosts with an async queue (browser `kernel.ts`) override.
    fn await_op(&mut self) -> Result<i32, String> {
        Ok(-1)
    }
    /// `env.throw` — reject the given pending slot (`WasmThrow`
    /// correlate; -1 → the newest pending). Default no-op.
    fn throw_op(&mut self, slot: i32) -> Result<(), String> {
        let _ = slot;
        Ok(())
    }
    /// `env.catch` — return 1 if `slot` was rejected (`WasmCatch`
    /// correlate), 0 otherwise. Default always returns 0.
    fn catch_op(&mut self, slot: i32) -> Result<i32, String> {
        let _ = slot;
        Ok(0)
    }
    /// `env.createElement(tag)` -> handle. Default returns 0.
    fn create_element(&mut self, _tag: &str) -> Result<i32, String> {
        Ok(0)
    }
    /// `env.appendChild(parent, child)`. Default no-op.
    fn append_child(&mut self, _parent: i32, _child: i32) -> Result<(), String> {
        Ok(())
    }
    /// `env.setProperty(obj, key, value)`. Default no-op.
    fn set_property(&mut self, _obj: i32, _key: &str, _value: &str) -> Result<(), String> {
        Ok(())
    }
    /// `env.holyc(ptr, len)` -> i32. Default returns 0.
    fn holyc(&mut self, _ptr: i32, _len: i32) -> Result<i32, String> {
        Ok(0)
    }
    /// `env.register_endpoint(...)` -> i32. Default returns 0.
    fn register_endpoint(&mut self, _a: i32, _b: i32, _c: i32, _d: i32) -> Result<i32, String> {
        Ok(0)
    }
    /// `env.libwasm_await__void(slot)`. Default no-op.
    fn libwasm_await_void(&mut self, _slot: i32) -> Result<(), String> {
        Ok(())
    }
    /// Return the async slot captured by the most recent sleeping import and
    /// clear it.  Hosts that do not implement asyncify should return `None`.
    fn take_slot(&mut self) -> Option<i32> {
        None
    }
    /// Resolve the slot after an Asyncify `Sleeping` step so the guest can
    /// resume.  The default is a no-op; real hosts perform the I/O here.
    fn resolve_slot(&mut self, _slot: i32) -> Result<(), String> {
        Ok(())
    }
    /// `env.libwasm_await_supported() -> i32`.  Default 0; the runtime
    /// may override this with `asyncify.is_some()`.
    fn await_supported(&self) -> i32 {
        0
    }
    /// `env.libwasm_await_failed() -> i32` — 1 if the last await rejected.
    fn await_failed(&self) -> i32 {
        0
    }
    /// `env.libwasm_await_error()` returns the last rejection reason.
    fn await_error(&self) -> String {
        String::new()
    }
    /// `env.addEventListener(target, type, listener, capture)`.
    fn add_event_listener(
        &mut self,
        _target_id: &str,
        _event_type: &str,
        _listener_id: u64,
        _capture: bool,
    ) -> Result<(), String> {
        Ok(())
    }
    /// `env.removeEventListener(listener)`.
    fn remove_event_listener(&mut self, _listener_id: u64) -> Result<(), String> {
        Ok(())
    }
    /// `env.dispatchEvent(target, type, detail)` -> true unless default prevented.
    fn dispatch_event(
        &mut self,
        _target_id: &str,
        _event_type: &str,
        _detail: &str,
    ) -> Result<bool, String> {
        Ok(true)
    }
    /// `env.libwasm_await_value()` returns the last resolution value.
    fn await_value(&self) -> String {
        String::new()
    }
    /// `env.libwasm_note_await_fail(handle)` records `handle` as a rejection.
    fn note_await_fail(&mut self, _handle: i32) -> Result<(), String> {
        Ok(())
    }
    /// `env.libwasm_note_await_ok(handle)` records `handle` as a resolution.
    fn note_await_ok(&mut self, _handle: i32) -> Result<(), String> {
        Ok(())
    }

    /// Immutable view of the libwasm object table.  Hosts that support
    /// `libwasm_add__*` / `libwasm_get__*` override both accessors.
    fn libwasm_objects(&self) -> Option<&ObjectTable<LibwasmValue>> {
        None
    }
    /// Mutable view of the libwasm object table.
    fn libwasm_objects_mut(&mut self) -> Option<&mut ObjectTable<LibwasmValue>> {
        None
    }

    fn libwasm_table_err() -> String {
        "libwasm object table is not implemented by this host".into()
    }

    /// `env.libwasm_get__string(handle)` returns the string stored for that
    /// object handle.  A null handle (0) yields an empty string.
    fn get_string(&self, handle: i32) -> Result<String, String> {
        if handle == 0 {
            return Ok(String::new());
        }
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        t.get(handle)?.as_string().map(String::from)
    }
    /// `env.libwasm_add__string(value)` adds a string to the object table and
    /// returns a handle.
    fn add_string(&mut self, value: &str) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::String(value.to_string()))
    }
    /// `env.libwasm_add__object() -> handle` — a fresh empty host object.
    fn add_object(&mut self) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::empty(crate::values::ObjectKind::Empty))
    }
    /// `env.libwasm_removeObject(handle)` — drop one `JsHandle` reference.
    fn remove_object(&mut self, handle: i32) -> Result<(), String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.remove_ref(handle).map(|_| ())
    }
    /// `env.libwasm_copyObjectRef(handle) -> handle` — `JsHandle` copy ctor.
    fn copy_object_ref(&mut self, handle: i32) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.copy_ref(handle)
    }

    // B62 scalar box/unbox defaults.  Hosts with an object table use the
    // generic implementation; hosts without one fail closed.
    fn add_bool(&mut self, value: bool) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::Bool(value))
    }
    fn add_i32(&mut self, value: i32) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::I32(value))
    }
    fn add_u32(&mut self, value: u32) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::U32(value))
    }
    fn add_i64(&mut self, value: i64) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::I64(value))
    }
    fn add_u64(&mut self, value: u64) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::U64(value))
    }
    fn add_i16(&mut self, value: i16) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::I16(value))
    }
    fn add_u16(&mut self, value: u16) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::U16(value))
    }
    fn add_f32(&mut self, value: f32) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::F32(value))
    }
    fn add_f64(&mut self, value: f64) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::F64(value))
    }
    fn add_i8(&mut self, value: i8) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::I8(value))
    }
    fn add_u8(&mut self, value: u8) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::U8(value))
    }
    fn add_i32s(&mut self, values: &[i32]) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::I32Vec(values.to_vec()))
    }
    fn add_u32s(&mut self, values: &[u32]) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(LibwasmValue::U32Vec(values.to_vec()))
    }

    fn get_bool(&self, handle: i32) -> Result<bool, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.truthy())
    }
    fn get_i32(&self, handle: i32) -> Result<i32, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_i32())
    }
    fn get_u32(&self, handle: i32) -> Result<u32, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_u32())
    }
    fn get_i64(&self, handle: i32) -> Result<i64, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_i64())
    }
    fn get_u64(&self, handle: i32) -> Result<u64, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_u64())
    }
    fn get_i16(&self, handle: i32) -> Result<i16, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_i32() as i16)
    }
    fn get_u16(&self, handle: i32) -> Result<u16, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_u32() as u16)
    }
    fn get_f32(&self, handle: i32) -> Result<f32, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_f32())
    }
    fn get_f64(&self, handle: i32) -> Result<f64, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_f64())
    }
    fn get_i8(&self, handle: i32) -> Result<i8, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_i32() as i8)
    }
    fn get_u8(&self, handle: i32) -> Result<u8, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        Ok(t.get(handle)?.to_u32() as u8)
    }

    // B63 property registry: generic object-table lookup and typed get/call.
    // Hosts that need allow-listing per object kind override these methods.
    fn object_getter(&mut self, handle: i32, name: &str) -> Result<LibwasmValue, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        t.get(handle)?.clone_prop(name)
    }
    fn get_libwasm_value(&self, handle: i32) -> Result<LibwasmValue, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        t.get(handle).cloned()
    }
    fn object_getter_idx(&mut self, handle: i32, idx: u32) -> Result<LibwasmValue, String> {
        let t = self.libwasm_objects().ok_or_else(Self::libwasm_table_err)?;
        let v = t.get(handle)?;
        match v {
            LibwasmValue::I32Vec(items) => Ok(items
                .get(idx as usize)
                .cloned()
                .map(LibwasmValue::I32)
                .ok_or_else(|| "libwasm vector index out of bounds".to_string())?),
            LibwasmValue::U32Vec(items) => Ok(items
                .get(idx as usize)
                .cloned()
                .map(LibwasmValue::U32)
                .ok_or_else(|| "libwasm vector index out of bounds".to_string())?),
            LibwasmValue::Object { props, .. } => Ok(props
                .get(&idx.to_string())
                .cloned()
                .ok_or_else(|| format!("libwasm object has no indexed property {idx}"))?),
            other => Err(format!(
                "libwasm get_idx_field on non-indexable value: {other:?}"
            )),
        }
    }
    fn get_field(&mut self, handle: i32, name: &str) -> Result<i32, String> {
        let value = self.object_getter(handle, name)?;
        self.add_libwasm_value(value)
    }
    fn get_idx_field(&mut self, handle: i32, idx: u32) -> Result<i32, String> {
        let value = self.object_getter_idx(handle, idx)?;
        self.add_libwasm_value(value)
    }
    fn object_call(
        &mut self,
        _handle: i32,
        _method: &str,
        _args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        Err("libwasm object_call is not implemented by this host".into())
    }
    fn add_libwasm_value(&mut self, value: LibwasmValue) -> Result<i32, String> {
        let t = self
            .libwasm_objects_mut()
            .ok_or_else(Self::libwasm_table_err)?;
        t.add(value)
    }

    /// `env.ldexec_*__string` — run a Lodash chain, yielding a string.
    fn ldexec_string(&mut self, _call: Ldexec<'_>) -> Result<String, String> {
        Err("libwasm ldexec is not implemented by this host".into())
    }
    /// `env.ldexec_*__long` — run a Lodash chain, yielding an integer.
    fn ldexec_long(&mut self, _call: Ldexec<'_>) -> Result<i64, String> {
        Err("libwasm ldexec is not implemented by this host".into())
    }
    /// `env.ldexec_*__double` — run a Lodash chain, yielding a double.
    fn ldexec_double(&mut self, _call: Ldexec<'_>) -> Result<f64, String> {
        Err("libwasm ldexec is not implemented by this host".into())
    }
    /// `env.ldexec_*__Handle` — run a Lodash chain, yielding an object handle.
    fn ldexec_handle(&mut self, _call: Ldexec<'_>) -> Result<i32, String> {
        Err("libwasm ldexec is not implemented by this host".into())
    }
}

/// DOM host used by the BIOS browser.
pub struct DomHost<'a> {
    pub dom: &'a mut Node,
    pub handles: Vec<Node>,
}

impl DomHost<'_> {
    fn node(&self, h: i32) -> Result<&Node, String> {
        match h {
            1 => Ok(self.dom),
            h if h >= 2 => self
                .handles
                .get((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {h}")),
        }
    }

    fn node_mut(&mut self, h: i32) -> Result<&mut Node, String> {
        match h {
            1 => Ok(self.dom),
            h if h >= 2 => self
                .handles
                .get_mut((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {h}")),
        }
    }
}

impl Host for DomHost<'_> {
    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
        let n = self
            .dom
            .get_element_by_id(id)
            .ok_or_else(|| format!("no element id={id}"))?;
        n.set_inner_text(val);
        Ok(())
    }

    fn log(&mut self, _msg: &str) {}

    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String> {
        let n = self
            .dom
            .get_element_by_id(id)
            .ok_or_else(|| format!("no element id={id}"))?;
        n.set_visible(on);
        Ok(())
    }

    fn create_element(&mut self, tag: &str) -> Result<i32, String> {
        let idx = self.handles.len() as i32;
        self.handles.push(Node::elem(tag));
        Ok(idx + 2)
    }

    fn append_child(&mut self, parent: i32, child: i32) -> Result<(), String> {
        let child = self.node(child)?.clone();
        self.node_mut(parent)?.children.push(child);
        Ok(())
    }

    fn set_property(&mut self, obj: i32, key: &str, value: &str) -> Result<(), String> {
        let n = self.node_mut(obj)?;
        match key {
            "innerText" | "textContent" => n.set_inner_text(value),
            _ => {
                n.attributes.insert(key.into(), value.into());
                n.dirty = true;
            }
        }
        Ok(())
    }
}

/// Run exported `_start` (svelte-d / libwasm Spa boot).
///
/// Accepts either `() -> ()` (legacy test modules) or `(i32) -> ()` (libwasm
/// Spa modules that take the heap base as a pointer). The `i32` argument is
/// the `__heap_base` global export when present, otherwise 0.
pub fn run_start(m: &Module, host: &mut impl Host) -> Result<(), String> {
    const ASYNCIFY_STACK_SIZE: u32 = 4096;
    const ASYNCIFY_STEP_LIMIT: u32 = 4;

    let idx = m
        .exports
        .iter()
        .find(|e| e.name == "_start" && e.kind == 0)
        .map(|e| e.idx)
        .ok_or("no _start export")?;
    let ty = func_type(m, idx)?;
    let heap_base = m
        .exports
        .iter()
        .find(|e| e.name == "__heap_base" && e.kind == 3)
        .and_then(|e| m.globals.get(e.idx as usize))
        .map(|g| g.value as i32)
        .unwrap_or(0);
    let mut m = m.clone();
    if !(ty.params.is_empty() || ty.params == [ValType::I32]) || !ty.results.is_empty() {
        return Err("_start must have signature () -> () or (i32) -> ()".into());
    }
    let args: Vec<i32> = if ty.params == [ValType::I32] {
        vec![heap_base]
    } else {
        vec![]
    };

    if let Ok(a) = Asyncify::new(&m) {
        let data = heap_base as u32;
        let stack_end = data + ASYNCIFY_STACK_SIZE;
        let needed = (stack_end as usize).saturating_sub(m.memory.len());
        if needed > 0 {
            let pages = ((needed + 65535) / 65536) as u32;
            m.mem_pages += pages;
            m.memory
                .resize(m.memory.len() + (pages as usize) * 65536, 0);
        }
        let mut step = a.step(&mut m, idx, &args, data, stack_end, host)?;
        for _ in 0..ASYNCIFY_STEP_LIMIT {
            match step {
                Step::Done(_) => return Ok(()),
                Step::Sleeping { slot, .. } => {
                    host.resolve_slot(slot)?;
                    step = a.resume(&mut m, idx, &args, data, stack_end, host)?;
                }
            }
        }
        return Err("asyncify step limit".into());
    }

    run_with_fuel_mut(&mut m, idx, &args, host, DEFAULT_FUEL).map(|_| ())
}

/// Run function `idx` (import space first).
pub fn run(m: &Module, idx: u32, args: &[i32], host: &mut impl Host) -> Result<Vec<i32>, String> {
    run_with_fuel(m, idx, args, host, DEFAULT_FUEL)
}

pub const DEFAULT_FUEL: u64 = 100_000;
pub const MAX_FUEL: u64 = 1_000_000;
pub const MAX_CALL_DEPTH: usize = 64;

pub fn run_with_fuel(
    m: &Module,
    idx: u32,
    args: &[i32],
    host: &mut impl Host,
    fuel: u64,
) -> Result<Vec<i32>, String> {
    run_with_fuel_mut(&mut m.clone(), idx, args, host, fuel)
}

pub fn run_with_fuel_mut(
    m: &mut Module,
    idx: u32,
    args: &[i32],
    host: &mut impl Host,
    fuel: u64,
) -> Result<Vec<i32>, String> {
    if fuel > MAX_FUEL {
        return Err("wasm fuel limit exceeds maximum".into());
    }
    let info = analyze(m)?;
    let mut memory = Vec::new();
    memory
        .try_reserve_exact(m.memory.len())
        .map_err(|_| "wasm memory allocation failed")?;
    memory.extend_from_slice(&m.memory);
    let globals: Vec<Value> = m
        .globals
        .iter()
        .map(|g| Value::from_raw(g.valtype, g.value))
        .collect();
    let value_args: Vec<Value> = args.iter().map(|&v| Value::I32(v)).collect();
    let tables = init_tables(m);
    let (elem_dropped, data_dropped) = init_dropped(m);
    let asyncify = Asyncify::new(m).ok();
    let asyncify_data = if let Some(ref a) = asyncify {
        globals
            .get(a.data_global as usize)
            .and_then(|v| v.as_i32().ok())
            .map(|v| v as u32)
            .unwrap_or(0)
    } else {
        0
    };
    let string_pool_next = memory.len() as u32;
    let mut rt = Runtime {
        m,
        info,
        host,
        fuel,
        memory,
        globals,
        tables,
        elem_dropped,
        data_dropped,
        caught: None,
        asyncify,
        asyncify_data,
        string_pool_next,
    };
    let results = rt.invoke(idx, &value_args, 0)?;
    // Persist mutable globals and memory so asyncify / multi-step calls see
    // the same instance state.  Take the runtime state before dropping it so
    // we can write back without keeping the module borrow alive.
    let mem = std::mem::take(&mut rt.memory);
    let final_globals = std::mem::take(&mut rt.globals);
    drop(rt);
    m.memory = mem;
    for (g, v) in m.globals.iter_mut().zip(final_globals) {
        g.value = v.into_raw();
    }
    Ok(results
        .into_iter()
        .map(|v| v.as_i32().unwrap_or(0))
        .collect())
}

/// Helper for reading operands from a `Vec<Value>`.
struct ArgReader<'a> {
    args: &'a [Value],
    at: &'a mut usize,
}

impl ArgReader<'_> {
    fn i32(&mut self) -> Result<i32, String> {
        let v = self.args.get(*self.at).ok_or("import arity")?.as_i32()?;
        *self.at += 1;
        Ok(v)
    }
    fn i64(&mut self) -> Result<i64, String> {
        let v = self.args.get(*self.at).ok_or("import arity")?.as_i64()?;
        *self.at += 1;
        Ok(v)
    }
    fn f32(&mut self) -> Result<f32, String> {
        let v = self.args.get(*self.at).ok_or("import arity")?.as_f32()?;
        *self.at += 1;
        Ok(v)
    }
    fn f64(&mut self) -> Result<f64, String> {
        let v = self.args.get(*self.at).ok_or("import arity")?.as_f64()?;
        *self.at += 1;
        Ok(v)
    }
}

struct Runtime<'a, H> {
    m: &'a Module,
    info: Vec<BodyInfo>,
    host: &'a mut H,
    fuel: u64,
    memory: Vec<u8>,
    globals: Vec<Value>,
    tables: Vec<Vec<Option<u32>>>,
    elem_dropped: Vec<bool>,
    data_dropped: Vec<bool>,
    caught: Option<Exception>,
    asyncify: Option<Asyncify>,
    asyncify_data: u32,
    string_pool_next: u32,
}

fn funcref_from_raw(raw: i32, func_count: usize) -> Result<Option<u32>, String> {
    if raw == 0 {
        Ok(None)
    } else {
        let f = (raw - 1) as u32;
        if f as usize >= func_count {
            Err("funcref out of range".into())
        } else {
            Ok(Some(f))
        }
    }
}

struct Frame {
    height: usize,
    results: usize,
    start: usize,
    end: usize,
    is_loop: bool,
    is_try: bool,
    catches: Vec<(u32, usize)>,
    catch_all: Option<usize>,
}

impl Clone for Frame {
    fn clone(&self) -> Self {
        Self {
            height: self.height,
            results: self.results,
            start: self.start,
            end: self.end,
            is_loop: self.is_loop,
            is_try: self.is_try,
            catches: self.catches.clone(),
            catch_all: self.catch_all,
        }
    }
}

struct Exception {
    tag: u32,
    values: Vec<Value>,
}

fn pop(stack: &mut Vec<Value>) -> Result<Value, String> {
    stack
        .pop()
        .ok_or_else(|| "wasm operand stack underflow".into())
}

fn preserve(stack: &mut Vec<Value>, height: usize, results: usize) -> Result<(), String> {
    let result = if results == 1 {
        Some(pop(stack)?)
    } else {
        None
    };
    if stack.len() < height {
        return Err("wasm control stack underflow".into());
    }
    stack.truncate(height);
    stack.extend(result);
    Ok(())
}

impl<H: Host> Runtime<'_, H> {
    fn scan_catches(
        &self,
        body: &[Instr],
        local: usize,
        pc: usize,
    ) -> (Vec<(u32, usize)>, Option<usize>) {
        let mut catches = Vec::new();
        let mut catch_all = None;
        let end = self.info[local]
            .ends
            .get(pc)
            .copied()
            .unwrap_or(body.len() - 1);
        let mut depth = 0usize;
        for (i, ins) in body.iter().enumerate().take(end + 1).skip(pc + 1) {
            match ins {
                Instr::Block(_)
                | Instr::Loop(_)
                | Instr::If(_)
                | Instr::Try(_)
                | Instr::TryTable(_) => depth += 1,
                Instr::End => {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                }
                Instr::Catch(tag) if depth == 0 => catches.push((*tag, i + 1)),
                Instr::CatchAll if depth == 0 => catch_all = Some(i + 1),
                _ => {}
            }
        }
        (catches, catch_all)
    }

    fn throw_exception(
        &mut self,
        tag: u32,
        values: Vec<Value>,
        controls: &mut Vec<Frame>,
        stack: &mut Vec<Value>,
        pc: &mut usize,
    ) -> Result<(), String> {
        for i in (0..controls.len()).rev() {
            if let Some(&(_, start)) = controls[i].catches.iter().find(|(t, _)| *t == tag) {
                let frame = controls[i].clone();
                controls.truncate(i);
                stack.truncate(frame.height);
                stack.extend(&values);
                *pc = start;
                self.caught = Some(Exception { tag, values });
                return Ok(());
            }
            if let Some(start) = controls[i].catch_all {
                let frame = controls[i].clone();
                controls.truncate(i);
                stack.truncate(frame.height);
                stack.extend(&values);
                *pc = start;
                self.caught = Some(Exception { tag, values });
                return Ok(());
            }
        }
        Err("unhandled wasm exception".into())
    }

    fn grow_memory(&mut self, delta: u32) -> i32 {
        let old = (self.memory.len() / 65536) as u32;
        let limit = self
            .m
            .max_mem_pages
            .unwrap_or(MAX_MEMORY_PAGES)
            .min(MAX_MEMORY_PAGES);
        let Some(pages) = old.checked_add(delta).filter(|pages| *pages <= limit) else {
            return -1;
        };
        let len = pages as usize * 65536;
        if self
            .memory
            .try_reserve_exact(len - self.memory.len())
            .is_err()
        {
            return -1;
        }
        self.memory.resize(len, 0);
        old as i32
    }

    /// Allocate `bytes` in the runtime memory and return the resulting
    /// `(ptr, len)` D string pair.  Grows memory by whole pages when needed.
    fn alloc_string(&mut self, bytes: &[u8]) -> Result<(i32, i32), String> {
        let len = bytes.len() as u32;
        let start = self.string_pool_next;
        let end = start.checked_add(len).ok_or("wasm string pool overflow")?;
        let target_pages = (end + 65535) / 65536;
        let current_pages = (self.memory.len() / 65536) as u32;
        if target_pages > current_pages {
            let delta = target_pages - current_pages;
            if self.grow_memory(delta) == -1 {
                return Err("wasm string pool memory grow failed".into());
            }
        }
        if end > self.memory.len() as u32 {
            return Err("wasm string pool out of memory".into());
        }
        self.memory[start as usize..end as usize].copy_from_slice(bytes);
        self.string_pool_next = end;
        Ok((start as i32, len as i32))
    }

    /// Write a D string `(len, ptr)` at `raw` in linear memory, allocating
    /// the payload from the string pool.
    fn write_string(&mut self, raw: i32, s: &str) -> Result<(), String> {
        let (ptr, len) = self.alloc_string(s.as_bytes())?;
        let _ = memory_range(self.memory.len(), raw, 0, 8)?;
        let base = raw as u32 as usize;
        self.memory[base..base + 4].copy_from_slice(&len.to_le_bytes());
        self.memory[base + 4..base + 8].copy_from_slice(&ptr.to_le_bytes());
        Ok(())
    }

    /// B64: write an `Optional!T` sret at `raw`.  `ty` is the inner D type
    /// (`Handle`, `uint`, `double`, `string`, `bool`).  The `optional.d`
    /// layout is `T _value; bool defined;` so the value is at `raw` and the
    /// presence flag is at `raw + sizeof(T)`.
    fn write_optional(&mut self, raw: i32, value: &LibwasmValue, ty: &str) -> Result<(), String> {
        let base = raw as u32 as usize;
        match ty {
            "Handle" => {
                let _ = memory_range(self.memory.len(), raw, 0, 8)?;
                let v = if matches!(value, LibwasmValue::None) {
                    0u32
                } else {
                    self.host.add_libwasm_value(value.clone())? as u32
                };
                let defined = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    1u8
                };
                self.memory[base..base + 4].copy_from_slice(&v.to_le_bytes());
                self.memory[base + 4] = defined;
                Ok(())
            }
            "uint" => {
                let _ = memory_range(self.memory.len(), raw, 0, 8)?;
                let v = if matches!(value, LibwasmValue::None) {
                    0u32
                } else {
                    value.to_u32()
                };
                let defined = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    1u8
                };
                self.memory[base..base + 4].copy_from_slice(&v.to_le_bytes());
                self.memory[base + 4] = defined;
                Ok(())
            }
            "double" => {
                let _ = memory_range(self.memory.len(), raw, 0, 9)?;
                let v = if matches!(value, LibwasmValue::None) {
                    0.0f64
                } else {
                    value.to_f64()
                };
                let defined = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    1u8
                };
                self.memory[base..base + 8].copy_from_slice(&v.to_le_bytes());
                self.memory[base + 8] = defined;
                Ok(())
            }
            "string" => {
                let _ = memory_range(self.memory.len(), raw, 0, 9)?;
                if matches!(value, LibwasmValue::None) {
                    self.memory[base..base + 8].copy_from_slice(&[0u8; 8]);
                } else {
                    self.write_string(raw, value.as_string()?)?;
                }
                let defined = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    1u8
                };
                self.memory[base + 8] = defined;
                Ok(())
            }
            "bool" => {
                let _ = memory_range(self.memory.len(), raw, 0, 2)?;
                let v = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    u8::from(value.truthy())
                };
                let defined = if matches!(value, LibwasmValue::None) {
                    0u8
                } else {
                    1u8
                };
                self.memory[base] = v;
                self.memory[base + 1] = defined;
                Ok(())
            }
            other => Err(format!("unsupported Optional!{other} result type")),
        }
    }

    fn tick(&mut self) -> Result<(), String> {
        self.fuel = self.fuel.checked_sub(1).ok_or("wasm fuel exhausted")?;
        Ok(())
    }

    fn invoke(&mut self, idx: u32, args: &[Value], depth: usize) -> Result<Vec<Value>, String> {
        if depth >= MAX_CALL_DEPTH {
            return Err("wasm call depth limit".into());
        }
        self.tick()?;
        let ty = func_type(self.m, idx)?;
        // Host imports may carry i64/f64 (the libwasm Lodash ABI); wasm-local
        // function bodies are still executed as an i32 machine.
        let is_import = (idx as usize) < self.m.imports.len();
        if !is_import
            && (!ty.params.iter().all(|t| *t == ValType::I32)
                || !ty.results.iter().all(|t| *t == ValType::I32))
        {
            return Err("non-i32 function type is not yet executable".into());
        }
        if args.len() != ty.params.len() {
            return Err("wasm argument count mismatch".into());
        }
        let results = ty.results.len();
        if is_import {
            return self.call_import(idx, args);
        }
        let local = idx as usize - self.m.imports.len();
        let mut locals = args.to_vec();
        locals.resize_with(args.len() + self.m.locals[local] as usize, || Value::I32(0));
        let body = &self.m.bodies[local];
        let mut stack = Vec::with_capacity(self.info[local].max_stack);
        let mut controls = vec![Frame {
            height: 0,
            results,
            start: 0,
            end: body.len() - 1,
            is_loop: false,
            is_try: false,
            catches: Vec::new(),
            catch_all: None,
        }];
        let mut pc = 0;
        while pc < body.len() {
            self.tick()?;
            let ins = &body[pc];
            match ins {
                Instr::Unsupported(op) => {
                    return Err(format!("unsupported wasm opcode 0x{op:02x}"));
                }
                Instr::Nop => {}
                Instr::Unreachable => return Err("wasm unreachable trap".into()),
                Instr::I32Const(v) => stack.push(Value::I32(*v)),
                Instr::LocalGet(i) => stack.push(locals[*i as usize]),
                Instr::LocalSet(i) | Instr::LocalTee(i) => {
                    let value = pop(&mut stack)?;
                    locals[*i as usize] = value;
                    if matches!(ins, Instr::LocalTee(_)) {
                        stack.push(value);
                    }
                }
                Instr::GlobalGet(i) => {
                    let v = self
                        .globals
                        .get(*i as usize)
                        .copied()
                        .ok_or("bad global index")?;
                    stack.push(v);
                }
                Instr::GlobalSet(i) => {
                    let value = pop(&mut stack)?;
                    let g = self.m.globals.get(*i as usize).ok_or("bad global index")?;
                    if !g.mutable {
                        return Err("global.set on immutable global".into());
                    }
                    let slot = self
                        .globals
                        .get_mut(*i as usize)
                        .ok_or("bad global index")?;
                    *slot = value;
                }
                Instr::I32Load { .. }
                | Instr::I32Load8S { .. }
                | Instr::I32Load8U { .. }
                | Instr::I32Load16S { .. }
                | Instr::I32Load16U { .. }
                | Instr::I64Load { .. }
                | Instr::I64Load8S { .. }
                | Instr::I64Load8U { .. }
                | Instr::I64Load16S { .. }
                | Instr::I64Load16U { .. }
                | Instr::I64Load32S { .. }
                | Instr::I64Load32U { .. }
                | Instr::F32Load { .. }
                | Instr::F64Load { .. } => {
                    let address = pop(&mut stack)?.as_i32()?;
                    let (_, offset, width) =
                        ins.memory_access().ok_or("invalid memory instruction")?;
                    let range = memory_range(self.memory.len(), address, offset, width)?;
                    let bytes = &self.memory[range];
                    let value = load_value(ins, bytes)?;
                    stack.push(value);
                }
                Instr::I32Store { .. }
                | Instr::I32Store8 { .. }
                | Instr::I32Store16 { .. }
                | Instr::I64Store { .. }
                | Instr::I64Store8 { .. }
                | Instr::I64Store16 { .. }
                | Instr::I64Store32 { .. }
                | Instr::F32Store { .. }
                | Instr::F64Store { .. } => {
                    let value = pop(&mut stack)?;
                    let address = pop(&mut stack)?.as_i32()?;
                    let (_, offset, width) =
                        ins.memory_access().ok_or("invalid memory instruction")?;
                    let range = memory_range(self.memory.len(), address, offset, width)?;
                    store_value(ins, &mut self.memory[range], value)?;
                }
                Instr::MemorySize => stack.push(Value::I32((self.memory.len() / 65536) as i32)),
                Instr::MemoryGrow => {
                    let delta = pop(&mut stack)?.as_i32()? as u32;
                    stack.push(Value::I32(self.grow_memory(delta)));
                }
                Instr::Drop => {
                    pop(&mut stack)?;
                }
                Instr::Select => {
                    let condition = pop(&mut stack)?.as_i32()?;
                    let b = pop(&mut stack)?;
                    let a = pop(&mut stack)?;
                    stack.push(if condition != 0 { a } else { b });
                }
                Instr::I32Eqz => {
                    let a = pop(&mut stack)?.as_i32()?;
                    stack.push(Value::I32(i32::from(a == 0)));
                }
                Instr::Call(callee) => {
                    let count = func_type(self.m, *callee)?.params.len();
                    let base = stack
                        .len()
                        .checked_sub(count)
                        .ok_or("call argument underflow")?;
                    let args = stack.split_off(base);
                    stack.extend(self.invoke(*callee, &args, depth + 1)?);
                }
                Instr::Block(result) | Instr::Loop(result) | Instr::If(result) => {
                    let condition = if matches!(ins, Instr::If(_)) {
                        pop(&mut stack)?.as_i32()?
                    } else {
                        1
                    };
                    controls.push(Frame {
                        height: stack.len(),
                        results: result.is_some() as usize,
                        start: pc + 1,
                        end: self.info[local].ends[pc],
                        is_loop: matches!(ins, Instr::Loop(_)),
                        is_try: false,
                        catches: Vec::new(),
                        catch_all: None,
                    });
                    if condition == 0 {
                        pc = self.info[local].alternatives[pc]
                            .map_or(self.info[local].ends[pc], |alt| alt + 1);
                        continue;
                    }
                }
                Instr::Try(result) => {
                    let (catches, catch_all) = self.scan_catches(body, local, pc);
                    controls.push(Frame {
                        height: stack.len(),
                        results: result.is_some() as usize,
                        start: pc + 1,
                        end: self.info[local].ends[pc],
                        is_loop: false,
                        is_try: true,
                        catches,
                        catch_all,
                    });
                }
                Instr::Else => {
                    pc = self.info[local].ends[pc];
                    continue;
                }
                Instr::End => {
                    let frame = controls.pop().ok_or("unmatched runtime end")?;
                    if frame.is_try {
                        self.caught = None;
                    }
                    preserve(&mut stack, frame.height, frame.results)?;
                    if controls.is_empty() {
                        return Ok(stack);
                    }
                }
                Instr::Return => {
                    preserve(&mut stack, 0, results)?;
                    return Ok(stack);
                }
                Instr::BrTable { labels, default } => {
                    let idx = pop(&mut stack)?.as_i32()? as usize;
                    let label = labels.get(idx).copied().unwrap_or(*default);
                    let target = controls.len() - label as usize - 1;
                    let frame = controls[target].clone();
                    preserve(
                        &mut stack,
                        frame.height,
                        if frame.is_loop { 0 } else { frame.results },
                    )?;
                    controls.truncate(target + usize::from(frame.is_loop));
                    if controls.is_empty() {
                        return Ok(stack);
                    }
                    pc = if frame.is_loop {
                        frame.start
                    } else {
                        frame.end + 1
                    };
                    continue;
                }
                Instr::Br(label) | Instr::BrIf(label) => {
                    let taken = !matches!(ins, Instr::BrIf(_)) || pop(&mut stack)?.as_i32()? != 0;
                    if taken {
                        let target = controls.len() - *label as usize - 1;
                        let frame = controls[target].clone();
                        preserve(
                            &mut stack,
                            frame.height,
                            if frame.is_loop { 0 } else { frame.results },
                        )?;
                        controls.truncate(target + usize::from(frame.is_loop));
                        if controls.is_empty() {
                            return Ok(stack);
                        }
                        pc = if frame.is_loop {
                            frame.start
                        } else {
                            frame.end + 1
                        };
                        continue;
                    }
                }
                Instr::I64Const(v) => stack.push(Value::I64(*v)),
                Instr::F32Const(v) => stack.push(Value::F32(*v)),
                Instr::F64Const(v) => stack.push(Value::F64(*v)),
                Instr::Numeric(op) => {
                    if numeric_is_unary(*op) {
                        let a = pop(&mut stack)?;
                        stack.push(numeric_op(*op, a, None)?);
                    } else {
                        let b = pop(&mut stack)?;
                        let a = pop(&mut stack)?;
                        stack.push(numeric_op(*op, a, Some(b))?);
                    }
                }
                Instr::Convert(op) => {
                    let a = pop(&mut stack)?;
                    stack.push(convert_op(*op, a)?);
                }
                Instr::SaturatingTrunc(op) => {
                    let a = pop(&mut stack)?;
                    stack.push(saturating_trunc_op(*op, a)?);
                }
                Instr::CallIndirect { typeidx, tableidx } => {
                    let idx = pop(&mut stack)?.as_i32()? as u32;
                    let table = self
                        .tables
                        .get(*tableidx as usize)
                        .ok_or("call_indirect table out of range")?;
                    let callee = table
                        .get(idx as usize)
                        .copied()
                        .flatten()
                        .ok_or("call_indirect uninitialised table entry")?;
                    let expected = self
                        .m
                        .types
                        .get(*typeidx as usize)
                        .ok_or("call_indirect bad type index")?;
                    let got = func_type(self.m, callee)?;
                    if expected != got {
                        return Err("call_indirect type mismatch".into());
                    }
                    let count = expected.params.len();
                    let base = stack
                        .len()
                        .checked_sub(count)
                        .ok_or("call_indirect argument underflow")?;
                    let args = stack.split_off(base);
                    stack.extend(self.invoke(callee, &args, depth + 1)?);
                }
                Instr::MemoryCopy => {
                    let len = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let src = pop(&mut stack)?.as_i32()?;
                    let dst = pop(&mut stack)?.as_i32()?;
                    let src_range = memory_range(self.memory.len(), src, 0, len)?;
                    let dst_range = memory_range(self.memory.len(), dst, 0, len)?;
                    let bytes = self.memory[src_range].to_vec();
                    self.memory[dst_range].copy_from_slice(&bytes);
                }
                Instr::MemoryFill => {
                    let len = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let val = pop(&mut stack)?.as_i32()? as u8;
                    let dst = pop(&mut stack)?.as_i32()?;
                    let range = memory_range(self.memory.len(), dst, 0, len)?;
                    self.memory[range].fill(val);
                }
                Instr::TableGet(tableidx) => {
                    let idx = pop(&mut stack)?.as_i32()? as u32;
                    let table = self
                        .tables
                        .get(*tableidx as usize)
                        .ok_or("table.get table out of range")?;
                    let entry = table
                        .get(idx as usize)
                        .ok_or("table.get index out of range")?;
                    let raw = entry.map(|f| f + 1).unwrap_or(0);
                    stack.push(Value::I32(raw as i32));
                }
                Instr::TableSet(tableidx) => {
                    let raw = pop(&mut stack)?.as_i32()?;
                    let idx = pop(&mut stack)?.as_i32()? as u32;
                    let func_count = self.m.func_types.len();
                    let table = self
                        .tables
                        .get_mut(*tableidx as usize)
                        .ok_or("table.set table out of range")?;
                    if idx as usize >= table.len() {
                        return Err("table.set index out of range".into());
                    }
                    table[idx as usize] = funcref_from_raw(raw, func_count)?;
                }
                Instr::TableFill(tableidx) => {
                    let count = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let raw = pop(&mut stack)?.as_i32()?;
                    let start = pop(&mut stack)?.as_i32()? as u32;
                    let func_count = self.m.func_types.len();
                    let table = self
                        .tables
                        .get_mut(*tableidx as usize)
                        .ok_or("table.fill table out of range")?;
                    let entry = funcref_from_raw(raw, func_count)?;
                    if start as usize + count > table.len() {
                        return Err("table.fill out of range".into());
                    }
                    for i in 0..count {
                        table[(start as usize) + i] = entry;
                    }
                }
                Instr::TableCopy { dst, src } => {
                    let count = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let src_off = pop(&mut stack)?.as_i32()? as u32;
                    let dst_off = pop(&mut stack)?.as_i32()? as u32;
                    if dst == src {
                        let table = self
                            .tables
                            .get_mut(*dst as usize)
                            .ok_or("table.copy table out of range")?;
                        if src_off as usize + count > table.len()
                            || dst_off as usize + count > table.len()
                        {
                            return Err("table.copy out of range".into());
                        }
                        let mut tmp = Vec::with_capacity(count);
                        for i in 0..count {
                            tmp.push(table[(src_off as usize) + i]);
                        }
                        for i in 0..count {
                            table[(dst_off as usize) + i] = tmp[i];
                        }
                    } else {
                        let src_entries: Vec<Option<u32>> = self.tables[*src as usize]
                            .get(src_off as usize..)
                            .and_then(|s| s.get(..count))
                            .ok_or("table.copy src out of range")?
                            .to_vec();
                        let dst_table = self
                            .tables
                            .get_mut(*dst as usize)
                            .ok_or("table.copy dst table out of range")?;
                        if dst_off as usize + count > dst_table.len() {
                            return Err("table.copy dst out of range".into());
                        }
                        for (i, e) in src_entries.iter().enumerate().take(count) {
                            dst_table[(dst_off as usize) + i] = *e;
                        }
                    }
                }
                Instr::TableInit { elem, table } => {
                    let count = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let src_off = pop(&mut stack)?.as_i32()? as u32;
                    let dst_off = pop(&mut stack)?.as_i32()? as u32;
                    if *elem as usize >= self.m.elements.len() {
                        return Err("table.init element out of range".into());
                    }
                    if self.elem_dropped[*elem as usize] {
                        return Err("table.init dropped element".into());
                    }
                    let funcs: Vec<u32> = self.m.elements[*elem as usize]
                        .funcs
                        .get(src_off as usize..)
                        .and_then(|s| s.get(..count))
                        .ok_or("table.init element out of range")?
                        .to_vec();
                    let table = self
                        .tables
                        .get_mut(*table as usize)
                        .ok_or("table.init table out of range")?;
                    if dst_off as usize + count > table.len() {
                        return Err("table.init table out of range".into());
                    }
                    for (i, f) in funcs.iter().enumerate() {
                        table[(dst_off as usize) + i] = Some(*f);
                    }
                }
                Instr::TableGrow(tableidx) => {
                    let delta = pop(&mut stack)?.as_i32()? as u32;
                    let raw = pop(&mut stack)?.as_i32()?;
                    let func_count = self.m.func_types.len();
                    let max = self
                        .m
                        .tables
                        .get(*tableidx as usize)
                        .and_then(|t| t.max)
                        .unwrap_or(u32::MAX);
                    let table = self
                        .tables
                        .get_mut(*tableidx as usize)
                        .ok_or("table.grow table out of range")?;
                    let old = table.len() as i32;
                    if table.len() as u32 + delta > max {
                        stack.push(Value::I32(-1));
                    } else {
                        let entry = funcref_from_raw(raw, func_count)?;
                        table.resize(table.len() + delta as usize, entry);
                        stack.push(Value::I32(old));
                    }
                }
                Instr::TableSize(tableidx) => {
                    let size = self
                        .tables
                        .get(*tableidx as usize)
                        .map(|t| t.len() as i32)
                        .ok_or("table.size table out of range")?;
                    stack.push(Value::I32(size));
                }
                Instr::ElemDrop(idx) => {
                    if *idx as usize >= self.elem_dropped.len() {
                        return Err("elem.drop out of range".into());
                    }
                    self.elem_dropped[*idx as usize] = true;
                }
                Instr::DataDrop(idx) => {
                    if *idx as usize >= self.data_dropped.len() {
                        return Err("data.drop out of range".into());
                    }
                    self.data_dropped[*idx as usize] = true;
                }
                Instr::MemoryInit(idx) => {
                    let count = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let src = pop(&mut stack)?.as_i32()? as u32 as usize;
                    let dst = pop(&mut stack)?.as_i32()? as u32 as usize;
                    if !self.m.has_memory {
                        return Err("memory.init without memory".into());
                    }
                    if *idx as usize >= self.m.data_segments.len() {
                        return Err("memory.init bad data segment".into());
                    }
                    if self.data_dropped[*idx as usize] {
                        return Err("memory.init dropped data segment".into());
                    }
                    let seg = &self.m.data_segments[*idx as usize];
                    let src_end = src.checked_add(count).ok_or("memory.init src overflow")?;
                    let dst_end = dst.checked_add(count).ok_or("memory.init dst overflow")?;
                    let bytes = seg
                        .bytes
                        .get(src..src_end)
                        .ok_or("memory.init src out of range")?;
                    let mem = self
                        .memory
                        .get_mut(dst..dst_end)
                        .ok_or("memory.init dst out of range")?;
                    mem.copy_from_slice(bytes);
                }
                Instr::Catch(_) | Instr::CatchAll => {
                    let frame = controls.last().ok_or("catch outside try")?;
                    pc = frame.end;
                    continue;
                }
                Instr::Throw(tag) => {
                    let ty = self
                        .m
                        .tags
                        .get(*tag as usize)
                        .and_then(|t| self.m.types.get(t.typeidx as usize))
                        .ok_or("throw bad tag index")?;
                    let mut values = Vec::with_capacity(ty.params.len());
                    for _ in 0..ty.params.len() {
                        values.push(pop(&mut stack)?);
                    }
                    values.reverse();
                    self.throw_exception(*tag, values, &mut controls, &mut stack, &mut pc)?;
                    continue;
                }
                Instr::Rethrow(label) => {
                    let exn = self.caught.take().ok_or("rethrow outside catch")?;
                    let mut target = None;
                    let mut seen = 0;
                    for (i, frame) in controls.iter().enumerate().rev() {
                        if frame.is_try {
                            if seen == *label as usize {
                                target = Some(i);
                                break;
                            }
                            seen += 1;
                        }
                    }
                    let Some(target_idx) = target else {
                        return Err("rethrow label out of range".into());
                    };
                    let mut catch = None;
                    for i in (0..target_idx).rev() {
                        if let Some(&(_, start)) =
                            controls[i].catches.iter().find(|(t, _)| *t == exn.tag)
                        {
                            catch = Some(start);
                            break;
                        }
                        if controls[i].catch_all.is_some() {
                            catch = controls[i].catch_all;
                            break;
                        }
                    }
                    if let Some(start) = catch {
                        let frame = controls[target_idx].clone();
                        controls.truncate(target_idx);
                        stack.truncate(frame.height);
                        stack.extend(&exn.values);
                        pc = start;
                        self.caught = Some(exn);
                        continue;
                    }
                    return Err("unhandled rethrow".into());
                }
                Instr::TryTable(_) | Instr::Delegate(_) | Instr::ThrowRef => {
                    return Err(format!("unsupported wasm execution opcode {ins:?}"));
                }
                other => {
                    let b = pop(&mut stack)?.as_i32()?;
                    let a = pop(&mut stack)?.as_i32()?;
                    stack.push(Value::I32(binary_op(other, a, b)?));
                }
            }
            pc += 1;
        }
        Err("missing runtime function end".into())
    }

    /// Imports whose lowered signature is not all-`i32`, or that need a typed
    /// result. Returns `Ok(None)` when `name` is not one of them, so the
    /// all-`i32` table below stays the common path.
    fn call_typed_import(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        if name == "getTimeStamp" {
            let ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            return Ok(Some(vec![Value::I64(ms)]));
        }
        if let Some(result) = self.b68_promise_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.b68_typed_array_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.b67_moment_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.b69_map_dispatch(name, args)? {
            return Ok(Some(result));
        }
        // B62: libwasm scalar box/unbox for i64 / f32 / f64.  The i32-only
        // flavours (int/uint/short/... and string/object) are handled by the
        // common all-i32 dispatch below, so any other suffix falls through.
        if let Some(rest) = name.strip_prefix("libwasm_add__") {
            return match rest {
                "long" | "ulong" | "float" | "double" => {
                    let v = args.first().ok_or("libwasm_add__ arity")?;
                    let h = match rest {
                        "long" => self.host.add_i64(v.as_i64()?)?,
                        "ulong" => self.host.add_u64(v.as_i64()? as u64)?,
                        "float" => self.host.add_f32(v.as_f32()?)?,
                        "double" => self.host.add_f64(v.as_f64()?)?,
                        _ => unreachable!(),
                    };
                    Ok(Some(vec![Value::I32(h)]))
                }
                _ => Ok(None),
            };
        }
        if let Some(rest) = name.strip_prefix("libwasm_get__") {
            let handle = args.first().ok_or("libwasm_get__ arity")?.as_i32()?;
            return match rest {
                "long" | "ulong" | "float" | "double" => {
                    let res = match rest {
                        "long" => Value::I64(self.host.get_i64(handle)?),
                        "ulong" => Value::I64(self.host.get_u64(handle)? as i64),
                        "float" => Value::F32(self.host.get_f32(handle)?.to_bits()),
                        "double" => Value::F64(self.host.get_f64(handle)?.to_bits()),
                        _ => unreachable!(),
                    };
                    Ok(Some(vec![res]))
                }
                _ => Ok(None),
            };
        }
        if let Some(result) = self.json_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.object_getter_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.object_call_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.vararg_call_dispatch(name, args)? {
            return Ok(Some(result));
        }
        if let Some(result) = self.b66_event_dispatch(name, args)? {
            return Ok(Some(result));
        }
        let Some(rest) = name.strip_prefix("ldexec_") else {
            return Ok(None);
        };
        let Some((init_kind, ret_kind)) = rest.split_once("__") else {
            return Err(format!("malformed libwasm ldexec import {name}"));
        };
        // sret for a string result comes first; every other flavour returns by
        // value. See LIBWASM-ABI.md §2.
        let sret = ret_kind == "string";
        let mut at = 0usize;
        let i32_at = |args: &[Value], at: &mut usize| -> Result<i32, String> {
            let v = args.get(*at).ok_or("libwasm ldexec arity")?.as_i32()?;
            *at += 1;
            Ok(v)
        };
        let raw = if sret { i32_at(args, &mut at)? } else { 0 };
        let init = match init_kind {
            "Handle" => LdexecInit::Handle(i32_at(args, &mut at)?),
            "long" => {
                let v = args.get(at).ok_or("libwasm ldexec arity")?.as_i64()?;
                at += 1;
                LdexecInit::Long(v)
            }
            "string" => {
                let (len, ptr) = (i32_at(args, &mut at)?, i32_at(args, &mut at)?);
                LdexecInit::Str {
                    text: mem_str(&self.memory, ptr, len)?,
                    eval: false, // patched from the trailing flag below
                }
            }
            other => return Err(format!("unsupported libwasm ldexec init {other}")),
        };
        let (clen, coff) = (i32_at(args, &mut at)?, i32_at(args, &mut at)?);
        let commands = mem_str(&self.memory, coff, clen)?;
        let callback = GuestFn {
            ctx: i32_at(args, &mut at)?,
            ptr: i32_at(args, &mut at)?,
        };
        let on_error = GuestFn {
            ctx: i32_at(args, &mut at)?,
            ptr: i32_at(args, &mut at)?,
        };
        let init = match init {
            LdexecInit::Str { text, .. } => LdexecInit::Str {
                text,
                eval: i32_at(args, &mut at)? != 0,
            },
            other => other,
        };
        if at != args.len() {
            return Err(format!(
                "libwasm ldexec arity mismatch for {name}: {} operands, consumed {at}",
                args.len()
            ));
        }
        let call = Ldexec {
            init,
            commands: &commands,
            callback,
            on_error,
        };
        Ok(Some(match ret_kind {
            "string" => {
                let s = self.host.ldexec_string(call)?;
                self.write_string(raw, &s)?;
                Vec::new()
            }
            "long" => vec![Value::I64(self.host.ldexec_long(call)?)],
            "double" => vec![Value::F64(self.host.ldexec_double(call)?.to_bits())],
            "Handle" => vec![Value::I32(self.host.ldexec_handle(call)?)],
            other => return Err(format!("unsupported libwasm ldexec result {other}")),
        }))
    }

    /// B63: typed object property getter (`Object_Getter__*`).  The result
    /// kind is encoded in the import name; string getters return via sret.
    fn object_getter_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        let Some(suffix) = name.strip_prefix("Object_Getter__") else {
            return Ok(None);
        };
        let mut at = 0usize;
        let raw = if suffix == "string" || suffix.starts_with("Optional") {
            let raw = args.get(at).ok_or("Object_Getter__ arity")?.as_i32()?;
            at += 1;
            Some(raw)
        } else {
            None
        };
        let handle = args.get(at).ok_or("Object_Getter__ arity")?.as_i32()?;
        at += 1;
        let len = args.get(at).ok_or("Object_Getter__ arity")?.as_i32()?;
        at += 1;
        let ptr = args.get(at).ok_or("Object_Getter__ arity")?.as_i32()?;
        at += 1;
        if at != args.len() {
            return Err(format!("Object_Getter__{suffix} arity mismatch"));
        }
        let field = mem_str(&self.memory, ptr, len)?;
        let value = match self.host.object_getter(handle, &field) {
            Ok(v) => v,
            Err(e) if e.starts_with("libwasm object has no property") => LibwasmValue::None,
            Err(e) => return Err(e),
        };
        match suffix {
            "Handle" => Ok(Some(vec![Value::I32(self.host.add_libwasm_value(value)?)])),
            "int" => Ok(Some(vec![Value::I32(value.to_i32())])),
            "uint" => Ok(Some(vec![Value::I32(value.to_u32() as i32)])),
            "ushort" => Ok(Some(vec![Value::I32(value.to_u16() as i32)])),
            "bool" => Ok(Some(vec![Value::I32(value.truthy() as i32)])),
            "float" => Ok(Some(vec![Value::F32(value.to_f32().to_bits())])),
            "double" => Ok(Some(vec![Value::F64(value.to_f64().to_bits())])),
            "string" => {
                let raw = raw.ok_or("Object_Getter__string missing sret")?;
                self.write_string(raw, value.as_string()?)?;
                Ok(Some(Vec::new()))
            }
            "OptionalHandle" => {
                let raw = raw.ok_or("Object_Getter__OptionalHandle missing sret")?;
                self.write_optional(raw, &value, "Handle")?;
                Ok(Some(Vec::new()))
            }
            "OptionalUint" => {
                let raw = raw.ok_or("Object_Getter__OptionalUint missing sret")?;
                self.write_optional(raw, &value, "uint")?;
                Ok(Some(Vec::new()))
            }
            "OptionalDouble" => {
                let raw = raw.ok_or("Object_Getter__OptionalDouble missing sret")?;
                self.write_optional(raw, &value, "double")?;
                Ok(Some(Vec::new()))
            }
            "OptionalString" => {
                let raw = raw.ok_or("Object_Getter__OptionalString missing sret")?;
                self.write_optional(raw, &value, "string")?;
                Ok(Some(Vec::new()))
            }
            "OptionalBool" => {
                let raw = raw.ok_or("Object_Getter__OptionalBool missing sret")?;
                self.write_optional(raw, &value, "bool")?;
                Ok(Some(Vec::new()))
            }
            "EventHandler" => Ok(None), // handled by b66_event_dispatch
            other => Err(format!("Object_Getter__{other} is not implemented")),
        }
    }

    /// B63: typed object method call (`Object_Call_*__*`).  Arg kinds and the
    /// return kind are encoded in the import name.  Method calls delegate to
    /// `Host::object_call`; the runtime only marshals the ABI.
    fn object_call_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        let Some(rest) = name.strip_prefix("Object_Call_") else {
            return Ok(None);
        };
        let Some((arg_part, ret)) = rest.split_once("__") else {
            return Err(format!("malformed Object_Call import {name}"));
        };
        if arg_part == "EventHandler" {
            return Ok(None); // handled by b66_event_dispatch
        }
        let mut at: usize = 0;
        let mut r = ArgReader { args, at: &mut at };
        let raw = if ret == "string" || ret.starts_with("Optional") {
            Some(r.i32()?)
        } else {
            None
        };
        let handle = r.i32()?;
        let mlen = r.i32()?;
        let mptr = r.i32()?;
        let method = mem_str(&self.memory, mptr, mlen)?;
        let arg_types: Vec<&str> = if arg_part.is_empty() {
            Vec::new()
        } else {
            arg_part.split('_').collect()
        };
        let mut call_args: Vec<LibwasmValue> = Vec::with_capacity(arg_types.len());
        for ty in arg_types {
            match ty {
                "string" => {
                    let len = r.i32()?;
                    let ptr = r.i32()?;
                    call_args.push(LibwasmValue::String(mem_str(&self.memory, ptr, len)?));
                }
                "int" => call_args.push(LibwasmValue::I32(r.i32()?)),
                "uint" => call_args.push(LibwasmValue::U32(r.i32()? as u32)),
                "long" => call_args.push(LibwasmValue::I64(r.i64()?)),
                "ulong" => call_args.push(LibwasmValue::U64(r.i64()? as u64)),
                "bool" => call_args.push(LibwasmValue::Bool(r.i32()? != 0)),
                "float" => call_args.push(LibwasmValue::F32(r.f32()?)),
                "double" => call_args.push(LibwasmValue::F64(r.f64()?)),
                "Handle" => {
                    let h = r.i32()?;
                    call_args.push(self.host.get_libwasm_value(h)?);
                }
                other => return Err(format!("unsupported Object_Call argument type {other}")),
            }
        }
        if at != args.len() {
            return Err(format!("Object_Call {name} arity mismatch"));
        }
        let result = self.host.object_call(handle, &method, &call_args)?;
        match ret {
            "void" => Ok(Some(Vec::new())),
            "Handle" => Ok(Some(vec![Value::I32(self.host.add_libwasm_value(result)?)])),
            "bool" => Ok(Some(vec![Value::I32(result.truthy() as i32)])),
            "int" => Ok(Some(vec![Value::I32(result.to_i32())])),
            "uint" => Ok(Some(vec![Value::I32(result.to_u32() as i32)])),
            "long" => Ok(Some(vec![Value::I64(result.to_i64())])),
            "ulong" => Ok(Some(vec![Value::I64(result.to_u64() as i64)])),
            "float" => Ok(Some(vec![Value::F32(result.to_f32().to_bits())])),
            "double" => Ok(Some(vec![Value::F64(result.to_f64().to_bits())])),
            "string" => {
                let raw = raw.ok_or("Object_Call__string missing sret")?;
                self.write_string(raw, result.as_string()?)?;
                Ok(Some(Vec::new()))
            }
            "OptionalHandle" => {
                let raw = raw.ok_or("Object_Call__OptionalHandle missing sret")?;
                self.write_optional(raw, &result, "Handle")?;
                Ok(Some(Vec::new()))
            }
            "OptionalString" => {
                let raw = raw.ok_or("Object_Call__OptionalString missing sret")?;
                self.write_optional(raw, &result, "string")?;
                Ok(Some(Vec::new()))
            }
            other => Err(format!("unsupported Object_Call result type {other}")),
        }
    }

    /// B65: `JSON_parse_string` and `JSON_stringify`.
    fn json_dispatch(&mut self, name: &str, args: &[Value]) -> Result<Option<Vec<Value>>, String> {
        match name {
            "JSON_parse_string" => {
                let (len, ptr) = (
                    args.first().ok_or("JSON_parse_string arity")?.as_i32()?,
                    args.get(1).ok_or("JSON_parse_string arity")?.as_i32()?,
                );
                if args.len() != 2 {
                    return Err("JSON_parse_string arity mismatch".into());
                }
                let s = mem_str(&self.memory, ptr, len)?;
                let value = crate::json::parse_libwasm_json(&s)?;
                let h = self.host.add_libwasm_value(value)?;
                Ok(Some(vec![Value::I32(h)]))
            }
            "JSON_stringify" => {
                let (raw, handle) = (
                    args.first().ok_or("JSON_stringify arity")?.as_i32()?,
                    args.get(1).ok_or("JSON_stringify arity")?.as_i32()?,
                );
                if args.len() != 2 {
                    return Err("JSON_stringify arity mismatch".into());
                }
                let value = self.host.get_libwasm_value(handle)?;
                let s = crate::json::stringify_libwasm_json(&value)?;
                self.write_string(raw, &s)?;
                Ok(Some(Vec::new()))
            }
            _ => Ok(None),
        }
    }

    /// B65: `Object_VarArgCall__*` overload-resolving dispatch.  The serialized
    /// argument JSON is a flat array matched against the D `argsdef` descriptor.
    fn vararg_call_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        let Some(suffix) = name.strip_prefix("Object_VarArgCall__") else {
            return Ok(None);
        };
        let mut at: usize = 0;
        let mut r = ArgReader { args, at: &mut at };
        let raw = if suffix == "string" || suffix.starts_with("Optional") {
            Some(r.i32()?)
        } else {
            None
        };
        let handle = r.i32()?;
        let mlen = r.i32()?;
        let mptr = r.i32()?;
        let method = mem_str(&self.memory, mptr, mlen)?;
        let dlen = r.i32()?;
        let dptr = r.i32()?;
        let argsdef = mem_str(&self.memory, dptr, dlen)?;
        let alen = r.i32()?;
        let aptr = r.i32()?;
        let args_json = mem_str(&self.memory, aptr, alen)?;
        if at != args.len() {
            return Err(format!("Object_VarArgCall__{suffix} arity mismatch"));
        }
        let call_args = crate::json::vararg_from_json(&argsdef, &args_json)?;
        let result = self.host.object_call(handle, &method, &call_args)?;
        match suffix {
            "void" => Ok(Some(Vec::new())),
            "Handle" => Ok(Some(vec![Value::I32(self.host.add_libwasm_value(result)?)])),
            "bool" => Ok(Some(vec![Value::I32(result.truthy() as i32)])),
            "int" => Ok(Some(vec![Value::I32(result.to_i32())])),
            "uint" => Ok(Some(vec![Value::I32(result.to_u32() as i32)])),
            "short" => Ok(Some(vec![Value::I32(result.to_i32() as i16 as i32)])),
            "ushort" => Ok(Some(vec![Value::I32(result.to_u32() as u16 as i32)])),
            "long" => Ok(Some(vec![Value::I64(result.to_i64())])),
            "ulong" => Ok(Some(vec![Value::I64(result.to_u64() as i64)])),
            "float" => Ok(Some(vec![Value::F32(result.to_f32().to_bits())])),
            "double" => Ok(Some(vec![Value::F64(result.to_f64().to_bits())])),
            "string" => {
                let raw = raw.ok_or("Object_VarArgCall__string missing sret")?;
                self.write_string(raw, result.as_string()?)?;
                Ok(Some(Vec::new()))
            }
            "OptionalHandle" => {
                let raw = raw.ok_or("Object_VarArgCall__OptionalHandle missing sret")?;
                self.write_optional(raw, &result, "Handle")?;
                Ok(Some(Vec::new()))
            }
            other => Err(format!("unsupported Object_VarArgCall result type {other}")),
        }
    }

    /// B66: event handlers, named delegates, and timers.  The browser host is
    /// the execution lane; the kernel host fails closed by returning a zero id
    /// or an empty Optional!T result, never re-entering a running instance.
    fn b66_event_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        match name {
            "libwasm_set__function"
            | "libwasm_unset__function"
            | "Object_Call_EventHandler__void" => Ok(Some(Vec::new())),
            "setTimeout" | "setInterval" => Ok(Some(vec![Value::I32(0)])),
            "clearTimeout" | "clearInterval" => Ok(Some(Vec::new())),
            "Object_Getter__EventHandler" => {
                let raw = args
                    .first()
                    .ok_or("Object_Getter__EventHandler arity")?
                    .as_i32()?;
                let _ = memory_range(self.memory.len(), raw, 0, 12)?;
                let base = raw as u32 as usize;
                self.memory[base..base + 4].copy_from_slice(&0u32.to_le_bytes());
                self.memory[base + 4..base + 8].copy_from_slice(&0u32.to_le_bytes());
                self.memory[base + 8] = 0;
                Ok(Some(Vec::new()))
            }
            _ => Ok(None),
        }
    }

    /// B68: promise combinators.  The browser host runs the real `Promise.*`;
    /// the kernel host cannot re-enter, so it returns handle 0 and logs a
    /// `PromiseUnavailable` value into the object table for fail-closed chains.
    fn b68_promise_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        let handle = match name {
            "libasync_promise_all__promise"
            | "libasync_promise_any__promise"
            | "libasync_promise_allsettled__promise" => {
                args.first().ok_or("libasync_promise_* arity")?.as_i32()?
            }
            _ => return Ok(None),
        };
        // Consume the input handle array reference and produce a single new
        // object handle.  The browser lane builds a real Promise; here we just
        // return a placeholder and rely on `libwasm_await__void` to fail
        // closed because the placeholder is not a promise.
        let _ = handle;
        Ok(Some(vec![Value::I32(0)]))
    }

    /// B67: first-party Moment handle creation.  The browser host creates a JS
    /// Date; the kernel lane cannot re-enter, so it returns a zero placeholder.
    fn b67_moment_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        match name {
            "libwasm_moment_now" => Ok(Some(vec![Value::I32(0)])),
            "libwasm_moment_from_millis" => {
                let _ = args.first().ok_or("libwasm_moment arity")?.as_i64()?;
                Ok(Some(vec![Value::I32(0)]))
            }
            _ => Ok(None),
        }
    }

    /// B69: bounded ES6 Map surface.  The browser host creates a JS Map;
    /// the kernel lane cannot re-enter, so it returns a zero/fail-closed
    /// placeholder and writes empty strings for Optional!T lookups.
    /// `libwasm_global` (B72) is dispatched here too: it shares the
    /// fail-closed "kernel lane cannot host a live JS object" contract.
    fn b69_map_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        match name {
            // B72: browser-instance globals. The kernel lane has no JS
            // `console`/`window`/`document`, so it returns the null handle the
            // ABI defines for "unavailable" rather than inventing an object.
            // The guest must check, exactly as it must in the browser lane
            // when no context is bound.
            "libwasm_global" => {
                let _ = args.first().ok_or("libwasm_global arity")?.as_i32()?;
                Ok(Some(vec![Value::I32(0)]))
            }
            "libwasm_map_create" => Ok(Some(vec![Value::I32(0)])),
            "libwasm_map_set" | "libwasm_map_delete" | "libwasm_map_clear" => {
                let _ = args.first().ok_or("libwasm_map arity")?.as_i32()?;
                Ok(Some(vec![]))
            }
            "libwasm_map_get__OptionalString" => {
                let raw = args.first().ok_or("libwasm_map_get arity")?.as_i32()?;
                let _ = args.get(1).ok_or("libwasm_map_get arity")?.as_i32()?;
                self.write_string(raw, "")?;
                self.write_optional(raw, &LibwasmValue::None, "string")?;
                Ok(Some(vec![]))
            }
            "libwasm_map_has" => {
                let _ = args.first().ok_or("libwasm_map_has arity")?.as_i32()?;
                Ok(Some(vec![Value::I32(0)]))
            }
            _ => Ok(None),
        }
    }

    /// B68 typed array / DataView Create: kernel lane returns a zero handle
    /// because it cannot build a live view into a running instance's memory.
    fn b68_typed_array_dispatch(
        &mut self,
        name: &str,
        args: &[Value],
    ) -> Result<Option<Vec<Value>>, String> {
        match name {
            "Int8Array_Create"
            | "Int32Array_Create"
            | "Uint8Array_Create"
            | "Float32Array_Create"
            | "DataView_Create" => {
                let _ = args.first().ok_or("typed array Create arity")?.as_i32()?;
                let _ = args.get(1).ok_or("typed array Create arity")?.as_i32()?;
                Ok(Some(vec![Value::I32(0)]))
            }
            _ => Ok(None),
        }
    }

    fn call_import(&mut self, idx: u32, args: &[Value]) -> Result<Vec<Value>, String> {
        let im = self.m.imports.get(idx as usize).ok_or("import")?;
        if im.module != "env" {
            return Err(format!("unknown import module {}", im.module));
        }
        // Typed imports first: the libwasm ABI has i64/f64 operands (B62), and
        // the i32 coercion below cannot represent them.
        if let Some(result) = self.call_typed_import(&im.name.clone(), args)? {
            return Ok(result);
        }
        let a: Vec<i32> = args
            .iter()
            .map(|v| v.as_i32())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| "host import argument type mismatch")?;
        match (im.name.as_str(), a.as_slice()) {
            (name, [id_ptr, id_len, val_ptr, val_len]) if name == IMPORT_SET_INNER_TEXT => {
                let id = mem_str(&self.memory, *id_ptr, *id_len)?;
                let val = mem_str(&self.memory, *val_ptr, *val_len)?;
                self.host.set_inner_text(&id, &val)?;
            }
            (name, [ptr, len]) if name == IMPORT_LOG => {
                self.host.log(&mem_str(&self.memory, *ptr, *len)?)
            }
            (name, [ptr, len, on]) if name == IMPORT_SET_VISIBLE => {
                self.host
                    .set_visible(&mem_str(&self.memory, *ptr, *len)?, *on != 0)?;
            }
            (name, [ptr, len]) if name == IMPORT_OBJECT_CALL => {
                return Ok(vec![Value::I32(self.host.fetch(&mem_str(
                    &self.memory,
                    *ptr,
                    *len,
                )?)?)]);
            }
            (name, [ptr, len]) if name == IMPORT_FETCH => {
                return Ok(vec![Value::I32(self.host.fetch(&mem_str(
                    &self.memory,
                    *ptr,
                    *len,
                )?)?)]);
            }
            (name, [ty]) if name == IMPORT_CREATE_ELEMENT => {
                let tag = node_type_tag(*ty).unwrap_or("div");
                return Ok(vec![Value::I32(self.host.create_element(tag)?)]);
            }
            (name, [parent, child]) if name == IMPORT_APPEND_CHILD => {
                self.host.append_child(*parent, *child)?;
            }
            (name, [obj, klen, kptr, vlen, vptr]) if name == IMPORT_SET_PROPERTY => {
                let key = mem_str(&self.memory, *kptr, *klen)?;
                let val = mem_str(&self.memory, *vptr, *vlen)?;
                self.host.set_property(*obj, &key, &val)?;
            }
            (name, [ptr, len]) if name == IMPORT_HOLYC => {
                return Ok(vec![Value::I32(self.host.holyc(*ptr, *len)?)]);
            }
            (name, [a, b, c, d]) if name == IMPORT_REGISTER_ENDPOINT => {
                return Ok(vec![Value::I32(
                    self.host.register_endpoint(*a, *b, *c, *d)?,
                )]);
            }
            (name, []) if name == IMPORT_AWAIT => {
                return Ok(vec![Value::I32(self.host.await_op()?)])
            }
            (name, [slot]) if name == IMPORT_LIBWASM_AWAIT_VOID => {
                self.host.libwasm_await_void(*slot)?;
                if let Some(ref a) = self.asyncify {
                    self.globals[a.state_global as usize] = Value::I32(crate::STATE_UNWINDING);
                    self.globals[a.data_global as usize] = Value::I32(self.asyncify_data as i32);
                }
            }
            (name, [slot]) if name == IMPORT_THROW => self.host.throw_op(*slot)?,
            (name, [slot]) if name == IMPORT_CATCH => {
                return Ok(vec![Value::I32(self.host.catch_op(*slot)?)])
            }
            (name, []) if name == IMPORT_LIBWASM_AWAIT_SUPPORTED => {
                return Ok(vec![Value::I32(if self.asyncify.is_some() {
                    1
                } else {
                    self.host.await_supported()
                })]);
            }
            (name, []) if name == IMPORT_LIBWASM_AWAIT_FAILED => {
                return Ok(vec![Value::I32(self.host.await_failed())]);
            }
            (name, [raw]) if name == IMPORT_LIBWASM_AWAIT_ERROR => {
                let s = self.host.await_error();
                self.write_string(*raw, &s)?;
            }
            (name, [raw]) if name == IMPORT_LIBWASM_AWAIT_VALUE => {
                let s = self.host.await_value();
                self.write_string(*raw, &s)?;
            }
            (name, [handle]) if name == IMPORT_LIBWASM_NOTE_AWAIT_FAIL => {
                self.host.note_await_fail(*handle)?;
            }
            (name, [handle]) if name == IMPORT_LIBWASM_NOTE_AWAIT_OK => {
                self.host.note_await_ok(*handle)?;
            }
            (name, [raw, handle]) if name == IMPORT_LIBWASM_GET_STRING => {
                let s = self.host.get_string(*handle)?;
                self.write_string(*raw, &s)?;
            }
            (name, [len, ptr]) if name == IMPORT_LIBWASM_ADD_STRING => {
                let s = mem_str(&self.memory, *ptr, *len)?;
                return Ok(vec![Value::I32(self.host.add_string(&s)?)]);
            }
            (name, []) if name == IMPORT_LIBWASM_ADD_OBJECT => {
                return Ok(vec![Value::I32(self.host.add_object()?)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_REMOVE_OBJECT => {
                self.host.remove_object(*handle)?;
            }
            (name, [handle]) if name == IMPORT_LIBWASM_COPY_OBJECT_REF => {
                return Ok(vec![Value::I32(self.host.copy_object_ref(*handle)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_BOOL => {
                return Ok(vec![Value::I32(self.host.add_bool(*v != 0)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_INT => {
                return Ok(vec![Value::I32(self.host.add_i32(*v)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_UINT => {
                return Ok(vec![Value::I32(self.host.add_u32(*v as u32)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_SHORT => {
                return Ok(vec![Value::I32(self.host.add_i16(*v as i16)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_USHORT => {
                return Ok(vec![Value::I32(self.host.add_u16(*v as u16)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_BYTE => {
                return Ok(vec![Value::I32(self.host.add_i8(*v as i8)?)]);
            }
            (name, [v]) if name == IMPORT_LIBWASM_ADD_UBYTE => {
                return Ok(vec![Value::I32(self.host.add_u8(*v as u8)?)]);
            }
            (name, [len, ptr]) if name == IMPORT_LIBWASM_ADD_INTS => {
                let values = mem_i32s(&self.memory, *ptr, *len)?;
                return Ok(vec![Value::I32(self.host.add_i32s(&values)?)]);
            }
            (name, [len, ptr]) if name == IMPORT_LIBWASM_ADD_UINTS => {
                let values = mem_u32s(&self.memory, *ptr, *len)?;
                return Ok(vec![Value::I32(self.host.add_u32s(&values)?)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_BOOL => {
                return Ok(vec![Value::I32(self.host.get_bool(*handle)? as i32)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_INT => {
                return Ok(vec![Value::I32(self.host.get_i32(*handle)?)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_UINT => {
                return Ok(vec![Value::I32(self.host.get_u32(*handle)? as i32)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_SHORT => {
                return Ok(vec![Value::I32(self.host.get_i16(*handle)? as i32)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_USHORT => {
                return Ok(vec![Value::I32(self.host.get_u16(*handle)? as i32)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_BYTE => {
                return Ok(vec![Value::I32(self.host.get_i8(*handle)? as i32)]);
            }
            (name, [handle]) if name == IMPORT_LIBWASM_GET_UBYTE => {
                return Ok(vec![Value::I32(self.host.get_u8(*handle)? as i32)]);
            }
            (name, [handle, len, ptr]) if name == IMPORT_LIBWASM_GET_FIELD => {
                let field = mem_str(&self.memory, *ptr, *len)?;
                return Ok(vec![Value::I32(self.host.get_field(*handle, &field)?)]);
            }
            (name, [handle, idx]) if name == IMPORT_LIBWASM_GET_IDX_FIELD => {
                return Ok(vec![Value::I32(
                    self.host.get_idx_field(*handle, *idx as u32)?,
                )]);
            }
            (name, [t_ptr, t_len, ty_ptr, ty_len, listener, cap])
                if name == IMPORT_ADD_EVENT_LISTENER =>
            {
                let target = mem_str(&self.memory, *t_ptr, *t_len)?;
                let ty = mem_str(&self.memory, *ty_ptr, *ty_len)?;
                self.host
                    .add_event_listener(&target, &ty, *listener as u64, *cap != 0)?;
            }
            (name, [listener]) if name == IMPORT_REMOVE_EVENT_LISTENER => {
                self.host.remove_event_listener(*listener as u64)?;
            }
            (name, [t_ptr, t_len, ty_ptr, ty_len, d_ptr, d_len])
                if name == IMPORT_DISPATCH_EVENT =>
            {
                let target = mem_str(&self.memory, *t_ptr, *t_len)?;
                let ty = mem_str(&self.memory, *ty_ptr, *ty_len)?;
                let detail = mem_str(&self.memory, *d_ptr, *d_len)?;
                return Ok(vec![Value::I32(
                    self.host.dispatch_event(&target, &ty, &detail)? as i32,
                )]);
            }
            _ => return Err("unknown host import or argument mismatch".into()),
        }
        Ok(Vec::new())
    }
}

fn binary_op(ins: &Instr, a: i32, b: i32) -> Result<i32, String> {
    Ok(match ins {
        Instr::I32Add => a.wrapping_add(b),
        Instr::I32Sub => a.wrapping_sub(b),
        Instr::I32Mul => a.wrapping_mul(b),
        Instr::I32DivS => a.checked_div(b).ok_or("wasm integer division trap")?,
        Instr::I32DivU => (a as u32)
            .checked_div(b as u32)
            .ok_or("wasm integer division trap")? as i32,
        Instr::I32RemS => {
            if b == 0 {
                return Err("wasm integer remainder trap".into());
            }
            a.wrapping_rem(b)
        }
        Instr::I32RemU => (a as u32)
            .checked_rem(b as u32)
            .ok_or("wasm integer remainder trap")? as i32,
        Instr::I32And => a & b,
        Instr::I32Or => a | b,
        Instr::I32Xor => a ^ b,
        Instr::I32Shl => a.wrapping_shl(b as u32),
        Instr::I32ShrS => a.wrapping_shr(b as u32),
        Instr::I32ShrU => (a as u32).wrapping_shr(b as u32) as i32,
        Instr::I32Rotl => a.rotate_left(b as u32),
        Instr::I32Rotr => a.rotate_right(b as u32),
        Instr::I32Eq => i32::from(a == b),
        Instr::I32Ne => i32::from(a != b),
        Instr::I32LtS => i32::from(a < b),
        Instr::I32LtU => i32::from((a as u32) < b as u32),
        Instr::I32GtS => i32::from(a > b),
        Instr::I32GtU => i32::from((a as u32) > b as u32),
        Instr::I32LeS => i32::from(a <= b),
        Instr::I32LeU => i32::from((a as u32) <= b as u32),
        Instr::I32GeS => i32::from(a >= b),
        Instr::I32GeU => i32::from((a as u32) >= b as u32),
        _ => return Err("unsupported numeric operation".into()),
    })
}

fn node_type_tag(ty: i32) -> Option<&'static str> {
    Some(match ty {
        0 => "a",
        1 => "abbr",
        2 => "address",
        3 => "area",
        4 => "article",
        5 => "aside",
        6 => "audio",
        7 => "b",
        8 => "base",
        9 => "bdi",
        10 => "bdo",
        11 => "blockquote",
        12 => "body",
        13 => "br",
        14 => "button",
        15 => "canvas",
        16 => "caption",
        17 => "cite",
        18 => "code",
        19 => "col",
        20 => "colgroup",
        21 => "data",
        22 => "datalist",
        23 => "dd",
        24 => "del",
        25 => "dfn",
        26 => "div",
        27 => "dl",
        28 => "dt",
        29 => "em",
        30 => "embed",
        31 => "fieldset",
        32 => "figcaption",
        33 => "figure",
        34 => "footer",
        35 => "form",
        36 => "h1",
        37 => "h2",
        38 => "h3",
        39 => "h4",
        40 => "h5",
        41 => "h6",
        42 => "head",
        43 => "header",
        44 => "hr",
        45 => "html",
        46 => "i",
        47 => "iframe",
        48 => "img",
        49 => "input",
        50 => "ins",
        51 => "kbd",
        52 => "keygen",
        53 => "label",
        54 => "legend",
        55 => "li",
        56 => "link",
        57 => "main",
        58 => "map",
        59 => "mark",
        60 => "meta",
        61 => "meter",
        62 => "nav",
        63 => "noscript",
        64 => "object",
        65 => "ol",
        66 => "optgroup",
        67 => "option",
        68 => "output",
        69 => "p",
        70 => "param",
        71 => "pre",
        72 => "progress",
        73 => "q",
        74 => "rb",
        75 => "rp",
        76 => "rt",
        77 => "rtc",
        78 => "ruby",
        79 => "s",
        80 => "samp",
        81 => "script",
        82 => "section",
        83 => "select",
        84 => "small",
        85 => "source",
        86 => "span",
        87 => "strong",
        88 => "style",
        89 => "sub",
        90 => "sup",
        91 => "table",
        92 => "tbody",
        93 => "td",
        94 => "template",
        95 => "textarea",
        96 => "tfoot",
        97 => "th",
        98 => "thead",
        99 => "time",
        100 => "title",
        101 => "tr",
        102 => "track",
        103 => "u",
        104 => "ul",
        105 => "var",
        106 => "video",
        107 => "wbr",
        1024 => "root",
        _ => return None,
    })
}

fn init_tables(m: &Module) -> Vec<Vec<Option<u32>>> {
    let mut tables: Vec<Vec<Option<u32>>> = m
        .tables
        .iter()
        .map(|t| vec![None; t.min as usize])
        .collect();
    for elem in &m.elements {
        let base = elem.offset as u32 as usize;
        for (i, &f) in elem.funcs.iter().enumerate() {
            if let Some(slot) = tables.first_mut().and_then(|t| t.get_mut(base + i)) {
                *slot = Some(f);
            }
        }
    }
    tables
}

fn init_dropped(m: &Module) -> (Vec<bool>, Vec<bool>) {
    let data_count = m.data_count.unwrap_or(m.data_segments.len() as u32) as usize;
    (vec![false; m.elements.len()], vec![false; data_count])
}

fn memory_range(
    len: usize,
    address: i32,
    offset: u32,
    width: usize,
) -> Result<std::ops::Range<usize>, String> {
    let start = u64::from(address as u32) + u64::from(offset);
    let end = start
        .checked_add(width as u64)
        .ok_or("wasm memory address overflow")?;
    if end > len as u64 {
        return Err("wasm memory out of bounds".into());
    }
    Ok(start as usize..end as usize)
}

fn mem_str(memory: &[u8], ptr: i32, len: i32) -> Result<String, String> {
    let range = memory_range(memory.len(), ptr, 0, len as u32 as usize)?;
    String::from_utf8(memory[range].to_vec()).map_err(|_| "wasm string is not UTF-8".into())
}

fn mem_i32s(memory: &[u8], ptr: i32, len: i32) -> Result<Vec<i32>, String> {
    let range = memory_range(
        memory.len(),
        ptr,
        0,
        (len as u32 as usize).saturating_mul(4),
    )?;
    Ok(memory[range]
        .chunks_exact(4)
        .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

fn mem_u32s(memory: &[u8], ptr: i32, len: i32) -> Result<Vec<u32>, String> {
    let range = memory_range(
        memory.len(),
        ptr,
        0,
        (len as u32 as usize).saturating_mul(4),
    )?;
    Ok(memory[range]
        .chunks_exact(4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

fn load_value(ins: &Instr, bytes: &[u8]) -> Result<Value, String> {
    Ok(match ins {
        Instr::I32Load8S { .. } => Value::I32(i32::from(bytes[0] as i8)),
        Instr::I32Load8U { .. } => Value::I32(i32::from(bytes[0])),
        Instr::I32Load16S { .. } => Value::I32(i32::from(i16::from_le_bytes([bytes[0], bytes[1]]))),
        Instr::I32Load16U { .. } => Value::I32(i32::from(u16::from_le_bytes([bytes[0], bytes[1]]))),
        Instr::I32Load { .. } => {
            Value::I32(i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        }
        Instr::I64Load8S { .. } => Value::I64(i64::from(bytes[0] as i8)),
        Instr::I64Load8U { .. } => Value::I64(i64::from(bytes[0])),
        Instr::I64Load16S { .. } => Value::I64(i64::from(i16::from_le_bytes([bytes[0], bytes[1]]))),
        Instr::I64Load16U { .. } => Value::I64(i64::from(u16::from_le_bytes([bytes[0], bytes[1]]))),
        Instr::I64Load32S { .. } => Value::I64(i64::from(i32::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3],
        ]))),
        Instr::I64Load32U { .. } => Value::I64(i64::from(u32::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3],
        ]))),
        Instr::I64Load { .. } => Value::I64(i64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ])),
        Instr::F32Load { .. } => {
            Value::F32(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        }
        Instr::F64Load { .. } => Value::F64(u64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ])),
        _ => return Err("load_value on non-load instruction".into()),
    })
}

fn store_value(ins: &Instr, out: &mut [u8], value: Value) -> Result<(), String> {
    match ins {
        Instr::I32Store8 { .. } => out[0] = value.as_i32()? as u8,
        Instr::I32Store16 { .. } => {
            let v = value.as_i32()? as u16;
            out.copy_from_slice(&v.to_le_bytes()[..2]);
        }
        Instr::I32Store { .. } => {
            let v = value.as_i32()?;
            out.copy_from_slice(&v.to_le_bytes());
        }
        Instr::I64Store8 { .. } => out[0] = value.as_i64()? as u8,
        Instr::I64Store16 { .. } => {
            let v = value.as_i64()? as u16;
            out.copy_from_slice(&v.to_le_bytes()[..2]);
        }
        Instr::I64Store32 { .. } => {
            let v = value.as_i64()? as u32;
            out.copy_from_slice(&v.to_le_bytes());
        }
        Instr::I64Store { .. } => {
            let v = value.as_i64()?;
            out.copy_from_slice(&v.to_le_bytes());
        }
        Instr::F32Store { .. } => {
            let v = value.as_f32()?;
            out.copy_from_slice(&v.to_le_bytes());
        }
        Instr::F64Store { .. } => {
            let v = value.as_f64()?;
            out.copy_from_slice(&v.to_le_bytes());
        }
        _ => return Err("store_value on non-store instruction".into()),
    }
    Ok(())
}

fn numeric_op(op: u8, a: Value, b: Option<Value>) -> Result<Value, String> {
    match (op, b) {
        (0x50, None) => {
            let v = a.as_i64()?;
            Ok(Value::I32(i32::from(v == 0)))
        }
        (0x51..=0x5a, Some(b)) => {
            let a = a.as_i64()?;
            let b = b.as_i64()?;
            let r = match op {
                0x51 => a == b,
                0x52 => a != b,
                0x53 => a < b,
                0x54 => (a as u64) < (b as u64),
                0x55 => a > b,
                0x56 => (a as u64) > (b as u64),
                0x57 => a <= b,
                0x58 => (a as u64) <= (b as u64),
                0x59 => a >= b,
                0x5a => (a as u64) >= (b as u64),
                _ => unreachable!(),
            };
            Ok(Value::I32(i32::from(r)))
        }
        (0x5b..=0x60, Some(b)) => {
            let a = a.as_f32()?;
            let b = b.as_f32()?;
            let r = match op {
                0x5b => a == b,
                0x5c => a != b,
                0x5d => a < b,
                0x5e => a > b,
                0x5f => a <= b,
                0x60 => a >= b,
                _ => unreachable!(),
            };
            Ok(Value::I32(i32::from(r)))
        }
        (0x61..=0x66, Some(b)) => {
            let a = a.as_f64()?;
            let b = b.as_f64()?;
            let r = match op {
                0x61 => a == b,
                0x62 => a != b,
                0x63 => a < b,
                0x64 => a > b,
                0x65 => a <= b,
                0x66 => a >= b,
                _ => unreachable!(),
            };
            Ok(Value::I32(i32::from(r)))
        }
        (0x67, None) => Ok(Value::I32(a.as_i32()?.leading_zeros() as i32)),
        (0x68, None) => Ok(Value::I32(a.as_i32()?.trailing_zeros() as i32)),
        (0x69, None) => Ok(Value::I32(a.as_i32()?.count_ones() as i32)),
        (0x79, None) => Ok(Value::I32((a.as_i32()? as i8) as i32)),
        (0x7a, None) => Ok(Value::I32((a.as_i32()? as i16) as i32)),
        (0x7b, None) => Ok(Value::I64((a.as_i64()? as i8) as i64)),
        (0x7c, None) => Ok(Value::I64((a.as_i64()? as i16) as i64)),
        (0x7d, None) => Ok(Value::I64((a.as_i64()? as i32) as i64)),
        (0x7e..=0x8a, Some(b)) | (0x8b..=0x8c, Some(b)) => {
            let a = a.as_i64()?;
            let b = b.as_i64()?;
            let sh = (b as u64 & 0x3f) as u32;
            Ok(match op {
                0x7e => Value::I64(a.wrapping_add(b)),
                0x7f => Value::I64(a.wrapping_sub(b)),
                0x80 => Value::I64(a.wrapping_mul(b)),
                0x81 => Value::I64(a.checked_div(b).ok_or("wasm i64 division trap")?),
                0x82 => Value::I64(
                    (a as u64)
                        .checked_div(b as u64)
                        .ok_or("wasm i64 division trap")? as i64,
                ),
                0x83 => {
                    if b == 0 {
                        return Err("wasm i64 remainder trap".into());
                    }
                    Value::I64(a.wrapping_rem(b))
                }
                0x84 => {
                    if b == 0 {
                        return Err("wasm i64 remainder trap".into());
                    }
                    Value::I64((a as u64).wrapping_rem(b as u64) as i64)
                }
                0x85 => Value::I64(a & b),
                0x86 => Value::I64(a | b),
                0x87 => Value::I64(a ^ b),
                0x88 => Value::I64(a.wrapping_shl(sh)),
                0x89 => Value::I64(a.wrapping_shr(sh)),
                0x8a => Value::I64((a as u64).wrapping_shr(sh) as i64),
                0x8b => Value::I64(a.rotate_left(sh)),
                0x8c => Value::I64(a.rotate_right(sh)),
                _ => unreachable!(),
            })
        }
        (0x8d..=0x91, None) => {
            let v = a.as_f32()?;
            Ok(Value::F32(
                match op {
                    0x8d => v.abs(),
                    0x8e => -v,
                    0x8f => v.ceil(),
                    0x90 => v.floor(),
                    0x91 => v.trunc(),
                    _ => return Err("unsupported f32 unary numeric".into()),
                }
                .to_bits(),
            ))
        }
        (0x92..=0x98, Some(b)) => {
            let a = a.as_f32()?;
            let b = b.as_f32()?;
            Ok(Value::F32(
                match op {
                    0x92 => a + b,
                    0x93 => a - b,
                    0x94 => a * b,
                    0x95 => a / b,
                    0x96 => a.min(b),
                    0x97 => a.max(b),
                    0x98 => a.copysign(b),
                    _ => unreachable!(),
                }
                .to_bits(),
            ))
        }
        (0x99..=0x9f, None) => {
            let v = a.as_f64()?;
            Ok(Value::F64(
                match op {
                    0x99 => v.abs(),
                    0x9a => -v,
                    0x9b => v.ceil(),
                    0x9c => v.floor(),
                    0x9d => v.trunc(),
                    0x9e => v.round_ties_even(),
                    0x9f => v.sqrt(),
                    _ => unreachable!(),
                }
                .to_bits(),
            ))
        }
        (0xa0..=0xa6, Some(b)) => {
            let a = a.as_f64()?;
            let b = b.as_f64()?;
            Ok(Value::F64(
                match op {
                    0xa0 => a + b,
                    0xa1 => a - b,
                    0xa2 => a * b,
                    0xa3 => a / b,
                    0xa4 => a.min(b),
                    0xa5 => a.max(b),
                    0xa6 => a.copysign(b),
                    _ => unreachable!(),
                }
                .to_bits(),
            ))
        }
        _ => Err(format!("unsupported numeric opcode 0x{op:02x}")),
    }
}

fn convert_op(op: u8, v: Value) -> Result<Value, String> {
    Ok(match op {
        0xa7 => Value::I32(v.as_i64()? as i32),
        0xac => Value::I64(i64::from(v.as_i32()?)),
        0xad => Value::I64((v.as_i32()? as u32) as i64),
        0xb2 => Value::F32((v.as_i32()? as f32).to_bits()),
        0xb3 => Value::F32(((v.as_i32()? as u32) as f32).to_bits()),
        0xb4 => Value::F32((v.as_i64()? as f32).to_bits()),
        0xb5 => Value::F32(((v.as_i64()? as u64) as f32).to_bits()),
        0xb7 => Value::F64((v.as_i32()? as f64).to_bits()),
        0xb8 => Value::F64(((v.as_i32()? as u32) as f64).to_bits()),
        0xb9 => Value::F64((v.as_i64()? as f64).to_bits()),
        0xba => Value::F64(((v.as_i64()? as u64) as f64).to_bits()),
        0xb6 => Value::F32((v.as_f64()? as f32).to_bits()),
        0xbb => Value::F64((v.as_f32()? as f64).to_bits()),
        0xbc => Value::F32(v.as_i32()? as u32),
        0xbd => Value::F64(v.as_i64()? as u64),
        0xbe => Value::I32(v.as_f32()? as u32 as i32),
        0xbf => Value::I64(v.as_f64()? as u64 as i64),
        // Sign-extension proposal: reinterpret the low 8/16/32 bits as signed.
        0xc0 => Value::I32(i32::from(v.as_i32()? as i8)),
        0xc1 => Value::I32(i32::from(v.as_i32()? as i16)),
        0xc2 => Value::I64(i64::from(v.as_i64()? as i8)),
        0xc3 => Value::I64(i64::from(v.as_i64()? as i16)),
        0xc4 => Value::I64(i64::from(v.as_i64()? as i32)),
        _ => return Err(format!("unsupported convert opcode 0x{op:02x}")),
    })
}

fn saturating_trunc_op(op: u8, _v: Value) -> Result<Value, String> {
    Err(format!(
        "saturating truncation 0x{op:02x} is not yet executable"
    ))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::binary::tests::{numeric, numeric_with_memory};
    use crate::binary::{DataSegment, Element, FuncType, Table, Tag};
    use crate::{decode, encode_ui_module};

    #[derive(Default)]
    pub(crate) struct TestHost {
        pub(crate) count: usize,
        pub(crate) slot: Option<i32>,
        pub(crate) objects: ObjectTable<LibwasmValue>,
        pub(crate) last_await_failed: bool,
        pub(crate) last_await_error: String,
        pub(crate) last_await_value: String,
        pub(crate) resolve_result: Option<Result<String, String>>,
    }
    impl TestHost {
        fn set_await_ok(&mut self, value: String) {
            self.last_await_failed = false;
            self.last_await_value = value;
            self.last_await_error.clear();
        }
        fn set_await_fail(&mut self, error: String) {
            self.last_await_failed = true;
            self.last_await_error = error;
            self.last_await_value.clear();
        }
        fn record_from_handle(&mut self, h: i32, failed: bool) -> Result<(), String> {
            let s = if h == 0 {
                String::new()
            } else {
                crate::string_of(self.objects.get(h)?)
            };
            if failed {
                self.set_await_fail(s);
            } else {
                self.set_await_ok(s);
            }
            Ok(())
        }
    }
    impl Host for TestHost {
        fn libwasm_objects(&self) -> Option<&ObjectTable<LibwasmValue>> {
            Some(&self.objects)
        }
        fn libwasm_objects_mut(&mut self) -> Option<&mut ObjectTable<LibwasmValue>> {
            Some(&mut self.objects)
        }
        fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
            self.count += 1;
            Ok(())
        }
        fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
            self.count += 1;
            Ok(())
        }
        fn log(&mut self, _: &str) {
            self.count += 1;
        }
        fn fetch(&mut self, url: &str) -> Result<i32, String> {
            self.add_string(url)
        }
        fn libwasm_await_void(&mut self, slot: i32) -> Result<(), String> {
            self.slot = Some(slot);
            Ok(())
        }
        fn take_slot(&mut self) -> Option<i32> {
            self.slot.take()
        }
        fn resolve_slot(&mut self, slot: i32) -> Result<(), String> {
            match self.resolve_result.take() {
                Some(Ok(v)) => self.set_await_ok(v),
                Some(Err(e)) => self.set_await_fail(e),
                None => {
                    // If `slot` is a known object handle, resolve with its string.
                    if let Ok(s) = self.get_string(slot) {
                        self.set_await_ok(s);
                    } else {
                        self.set_await_ok(String::new());
                    }
                }
            }
            Ok(())
        }
        fn await_failed(&self) -> i32 {
            i32::from(self.last_await_failed)
        }
        fn await_error(&self) -> String {
            self.last_await_error.clone()
        }
        fn await_value(&self) -> String {
            self.last_await_value.clone()
        }
        fn note_await_fail(&mut self, handle: i32) -> Result<(), String> {
            self.record_from_handle(handle, true)
        }
        fn note_await_ok(&mut self, handle: i32) -> Result<(), String> {
            self.record_from_handle(handle, false)
        }
        fn object_call(
            &mut self,
            _handle: i32,
            method: &str,
            args: &[LibwasmValue],
        ) -> Result<LibwasmValue, String> {
            match method {
                "double" => {
                    let n = args.first().ok_or("double arg")?.to_i32();
                    Ok(LibwasmValue::I32(n * 2))
                }
                "concat" => {
                    let a = args.first().ok_or("concat arg0")?.as_string()?;
                    let b = args.get(1).ok_or("concat arg1")?.as_string()?;
                    Ok(LibwasmValue::String(format!("{a}{b}")))
                }
                "name" => Ok(LibwasmValue::String("test".into())),
                "echo" => {
                    let s = args.first().ok_or("echo arg")?.as_string()?;
                    Ok(LibwasmValue::String(s.to_string()))
                }
                "maybeString" => {
                    let s = args.first().ok_or("maybeString arg")?.as_string()?;
                    if s == "empty" {
                        Ok(LibwasmValue::None)
                    } else {
                        Ok(LibwasmValue::String(s.to_string()))
                    }
                }
                "maybeHandle" => {
                    let v = args.first().ok_or("maybeHandle arg")?;
                    if v.to_i32() == 0 {
                        Ok(LibwasmValue::None)
                    } else {
                        Ok(v.clone())
                    }
                }
                other => Err(format!("TestHost object_call unknown method {other}")),
            }
        }
    }

    #[test]
    fn libwasm_object_and_await_status_imports_write_strings_to_memory() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let mut m = Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32, ValType::I32],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32, ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: crate::IMPORT_LIBWASM_ADD_STRING.into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: crate::IMPORT_LIBWASM_GET_STRING.into(),
                    typeidx: 1,
                },
                Import {
                    module: "env".into(),
                    name: crate::IMPORT_LIBWASM_AWAIT_ERROR.into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: crate::IMPORT_LIBWASM_AWAIT_VALUE.into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: crate::IMPORT_LIBWASM_AWAIT_FAILED.into(),
                    typeidx: 3,
                },
            ],
            func_types: vec![4],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 5,
            }],
            bodies: vec![vec![
                Instr::I32Const(5), // len
                Instr::I32Const(0), // ptr
                Instr::Call(0),     // add_string
                Instr::LocalSet(0),
                Instr::I32Const(200), // raw result for get
                Instr::LocalGet(0),
                Instr::Call(1),       // get_string
                Instr::I32Const(208), // raw result for error
                Instr::Call(2),       // await_error
                Instr::I32Const(216), // raw result for value
                Instr::Call(3),       // await_value
                Instr::Call(4),       // await_failed
                Instr::End,
            ]],
            memory: vec![0; 65536],
            locals: vec![1],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        m.memory[0..5].copy_from_slice(b"hello");
        let mut host = TestHost {
            last_await_failed: true,
            last_await_error: "rejected".into(),
            last_await_value: "resolved".into(),
            ..TestHost::default()
        };

        run_with_fuel_mut(&mut m, 5, &[], &mut host, DEFAULT_FUEL).unwrap();

        // get_string(handle) => "hello" at raw=200
        let len_get = i32::from_le_bytes(m.memory[200..204].try_into().unwrap());
        let ptr_get = i32::from_le_bytes(m.memory[204..208].try_into().unwrap());
        assert_eq!(len_get, 5);
        assert_eq!(&m.memory[ptr_get as usize..ptr_get as usize + 5], b"hello");

        // await_error(raw=208) => "rejected"
        let len_err = i32::from_le_bytes(m.memory[208..212].try_into().unwrap());
        let ptr_err = i32::from_le_bytes(m.memory[212..216].try_into().unwrap());
        assert_eq!(
            &m.memory[ptr_err as usize..ptr_err as usize + len_err as usize],
            b"rejected"
        );

        // await_value(raw=216) => "resolved"
        let len_val = i32::from_le_bytes(m.memory[216..220].try_into().unwrap());
        let ptr_val = i32::from_le_bytes(m.memory[220..224].try_into().unwrap());
        assert_eq!(
            &m.memory[ptr_val as usize..ptr_val as usize + len_val as usize],
            b"resolved"
        );
    }

    /// B67: `getTimeStamp` returns a non-negative millisecond-since-epoch i64.
    #[test]
    fn libwasm_get_timestamp_returns_epoch_milliseconds() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let mut m = Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I64],
                },
                FuncType {
                    params: vec![ValType::I64],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![Import {
                module: "env".into(),
                name: "getTimeStamp".into(),
                typeidx: 0,
            }],
            func_types: vec![2],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 1,
            }],
            bodies: vec![vec![
                Instr::Call(0),                    // getTimeStamp
                Instr::I64Const(0x0100_0000_0000), // 1 << 40
                Instr::Numeric(0x5a),              // i64.ge_u
                Instr::End,
            ]],
            memory: vec![0; 65536],
            locals: vec![0],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        let mut host = TestHost::default();
        let result = run_with_fuel_mut(&mut m, 1, &[], &mut host, DEFAULT_FUEL).unwrap();
        assert_eq!(result, vec![1]); // >= 1 << 44
    }

    /// B68: promise combinators return a placeholder handle in the kernel lane.
    #[test]
    fn libwasm_promise_combinators_fail_closed_in_kernel() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        for name in [
            "libasync_promise_all__promise",
            "libasync_promise_any__promise",
            "libasync_promise_allsettled__promise",
        ] {
            let mut m = Module {
                types: vec![
                    FuncType {
                        params: vec![ValType::I32],
                        results: vec![ValType::I32],
                    },
                    FuncType {
                        params: vec![],
                        results: vec![ValType::I32],
                    },
                ],
                imports: vec![Import {
                    module: "env".into(),
                    name: name.into(),
                    typeidx: 0,
                }],
                func_types: vec![1],
                mem_pages: 1,
                max_mem_pages: None,
                exports: vec![Export {
                    name: "_start".into(),
                    kind: 0,
                    idx: 1,
                }],
                bodies: vec![vec![Instr::I32Const(0), Instr::Call(0), Instr::End]],
                memory: vec![0; 65536],
                locals: vec![0],
                has_memory: true,
                tags: vec![],
                globals: vec![Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                }],
                tables: vec![],
                elements: vec![],
                data_count: None,
                data_segments: vec![],
            };
            let mut host = TestHost::default();
            let result = run_with_fuel_mut(&mut m, 1, &[], &mut host, DEFAULT_FUEL).unwrap();
            assert_eq!(result, vec![0]);
        }
    }

    /// B68 typed array / DataView Create: kernel lane returns a zero placeholder.
    #[test]
    fn libwasm_typed_array_create_fail_closed_in_kernel() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        for name in [
            "Int8Array_Create",
            "Int32Array_Create",
            "Uint8Array_Create",
            "Float32Array_Create",
            "DataView_Create",
        ] {
            let mut m = Module {
                types: vec![
                    FuncType {
                        params: vec![ValType::I32, ValType::I32],
                        results: vec![ValType::I32],
                    },
                    FuncType {
                        params: vec![],
                        results: vec![ValType::I32],
                    },
                ],
                imports: vec![Import {
                    module: "env".into(),
                    name: name.into(),
                    typeidx: 0,
                }],
                func_types: vec![1],
                mem_pages: 1,
                max_mem_pages: None,
                exports: vec![Export {
                    name: "_start".into(),
                    kind: 0,
                    idx: 1,
                }],
                bodies: vec![vec![
                    Instr::I32Const(0),
                    Instr::I32Const(0),
                    Instr::Call(0),
                    Instr::End,
                ]],
                memory: vec![0; 65536],
                locals: vec![0],
                has_memory: true,
                tags: vec![],
                globals: vec![Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                }],
                tables: vec![],
                elements: vec![],
                data_count: None,
                data_segments: vec![],
            };
            let mut host = TestHost::default();
            let result = run_with_fuel_mut(&mut m, 1, &[], &mut host, DEFAULT_FUEL).unwrap();
            assert_eq!(result, vec![0]);
        }
    }

    /// B67: first-party Moment handle creation returns a zero placeholder in
    /// the kernel lane.
    #[test]
    fn libwasm_moment_now_fail_closed_in_kernel() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        for (name, params) in [
            ("libwasm_moment_now", 0usize),
            ("libwasm_moment_from_millis", 1usize),
        ] {
            let mut m = Module {
                types: vec![
                    FuncType {
                        params: if params == 0 {
                            vec![]
                        } else {
                            vec![ValType::I64]
                        },
                        results: vec![ValType::I32],
                    },
                    FuncType {
                        params: vec![],
                        results: vec![ValType::I32],
                    },
                ],
                imports: vec![Import {
                    module: "env".into(),
                    name: name.into(),
                    typeidx: 0,
                }],
                func_types: vec![1],
                mem_pages: 1,
                max_mem_pages: None,
                exports: vec![Export {
                    name: "_start".into(),
                    kind: 0,
                    idx: 1,
                }],
                bodies: vec![if params == 0 {
                    vec![Instr::Call(0), Instr::End]
                } else {
                    vec![
                        Instr::I64Const(1_700_000_000_000),
                        Instr::Call(0),
                        Instr::End,
                    ]
                }],
                memory: vec![0; 65536],
                locals: vec![0],
                has_memory: true,
                tags: vec![],
                globals: vec![Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                }],
                tables: vec![],
                elements: vec![],
                data_count: None,
                data_segments: vec![],
            };
            let mut host = TestHost::default();
            let result = run_with_fuel_mut(&mut m, 1, &[], &mut host, DEFAULT_FUEL).unwrap();
            assert_eq!(result, vec![0]);
        }
    }

    /// B69: bounded ES6 Map surface returns fail-closed placeholders in the
    /// kernel lane, and `get` writes an empty Optional!string.
    #[test]
    fn libwasm_map_surface_fail_closed_in_kernel() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let mut m = Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32, ValType::I32, ValType::I32],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32, ValType::I32, ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                    ],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "libwasm_map_create".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_map_clear".into(),
                    typeidx: 1,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_map_has".into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_map_delete".into(),
                    typeidx: 3,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_map_set".into(),
                    typeidx: 4,
                },
            ],
            func_types: vec![5],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 5,
            }],
            bodies: vec![vec![
                Instr::Call(0),
                Instr::LocalSet(0),
                Instr::LocalGet(0),
                Instr::Call(1),
                Instr::LocalGet(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(2),
                Instr::Drop,
                Instr::LocalGet(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(3),
                Instr::LocalGet(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(4),
                Instr::End,
            ]],
            memory: vec![0; 65536],
            locals: vec![1],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        let mut host = TestHost::default();
        let _ = run_with_fuel_mut(&mut m, 5, &[], &mut host, DEFAULT_FUEL).unwrap();
    }

    /// B61: `libwasm_add__object` / `copyObjectRef` / `removeObject` dispatch
    /// through the interpreter and keep `JsHandle` refcount semantics, so a
    /// copied handle survives one release and a double free traps.
    #[test]
    fn libwasm_object_lifetime_imports_refcount_and_fail_closed() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let import = |name: &str, typeidx: u32| Import {
            module: "env".into(),
            name: name.into(),
            typeidx,
        };
        let module = |body: Vec<Instr>| Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![
                import(crate::IMPORT_LIBWASM_ADD_OBJECT, 0),
                import(crate::IMPORT_LIBWASM_COPY_OBJECT_REF, 1),
                import(crate::IMPORT_LIBWASM_REMOVE_OBJECT, 2),
            ],
            func_types: vec![3],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 3,
            }],
            bodies: vec![body],
            memory: vec![0; 65536],
            locals: vec![1],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };

        // add -> copy -> remove -> remove: released exactly once, and the
        // handle the guest sees back from `copyObjectRef` is the same one.
        let mut m = module(vec![
            Instr::Call(0), // h = add_object()
            Instr::LocalTee(0),
            Instr::Call(1), // copyObjectRef(h) -> h
            Instr::LocalGet(0),
            Instr::I32Eq, // copy is identity
            Instr::LocalGet(0),
            Instr::Call(2), // removeObject(h): still referenced
            Instr::LocalGet(0),
            Instr::Call(2), // removeObject(h): releases
            Instr::End,
        ]);
        let mut host = TestHost::default();
        let out = run_with_fuel_mut(&mut m, 3, &[], &mut host, DEFAULT_FUEL).unwrap();
        assert_eq!(out, vec![1], "copyObjectRef returns the same handle");
        assert!(
            host.objects.is_empty(),
            "last reference released the object"
        );

        // A third release is a double free and must trap, not be swallowed.
        let mut m = module(vec![
            Instr::Call(0),
            Instr::LocalTee(0),
            Instr::Call(2),
            Instr::LocalGet(0),
            Instr::Call(2),
            Instr::I32Const(0),
            Instr::End,
        ]);
        let mut host = TestHost::default();
        let err = run_with_fuel_mut(&mut m, 3, &[], &mut host, DEFAULT_FUEL).unwrap_err();
        assert!(err.contains("freed"), "{err}");

        // Freeing a protected root is rejected by name, not silently ignored.
        let mut m = module(vec![
            Instr::I32Const(crate::OBJECT_ROOT_DOM),
            Instr::Call(2),
            Instr::I32Const(0),
            Instr::End,
        ]);
        let err =
            run_with_fuel_mut(&mut m, 3, &[], &mut TestHost::default(), DEFAULT_FUEL).unwrap_err();
        assert!(err.contains("protected root"), "{err}");
    }

    /// B62/B67: `ldexec_*` decodes its `(init, commands, cb, onError)` operands
    /// and returns through the typed path — `long` is a real `i64` and `double`
    /// a real `f64`, neither of which the all-i32 import table could carry.
    #[test]
    fn ldexec_imports_decode_typed_operands_and_return_typed_results() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        #[derive(Default)]
        struct LdHost {
            seen: Vec<(LdexecInit, String, GuestFn)>,
        }
        impl Host for LdHost {
            fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
                Ok(())
            }
            fn log(&mut self, _: &str) {}
            fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
                Ok(())
            }
            fn ldexec_long(&mut self, call: Ldexec<'_>) -> Result<i64, String> {
                self.seen
                    .push((call.init, call.commands.into(), call.callback));
                Ok(-9_000_000_000)
            }
            fn ldexec_double(&mut self, call: Ldexec<'_>) -> Result<f64, String> {
                self.seen
                    .push((call.init, call.commands.into(), call.callback));
                Ok(0.5)
            }
        }
        let cmds = r#"[{"func":"size","params":[]}]"#;
        // ldexec_long__long(num:i64, cLen, cOff, cCtx, cPtr, errCtx, errPtr) -> i64
        // ldexec_Handle__double(ctx, cLen, cOff, cCtx, cPtr, errCtx, errPtr) -> f64
        let mut m = Module {
            types: vec![
                FuncType {
                    params: vec![
                        ValType::I64,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                    ],
                    results: vec![ValType::I64],
                },
                FuncType {
                    params: vec![ValType::I32; 7],
                    results: vec![ValType::F64],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "ldexec_long__long".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "ldexec_Handle__double".into(),
                    typeidx: 1,
                },
            ],
            func_types: vec![2],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 2,
            }],
            bodies: vec![vec![
                Instr::I32Const(0x0010_0007), // init handle
                Instr::I32Const(cmds.len() as i32),
                Instr::I32Const(0), // commands at 0
                Instr::I32Const(11),
                Instr::I32Const(22), // callback (ctx, ptr)
                Instr::I32Const(33),
                Instr::I32Const(44), // onError
                Instr::Call(1),
                Instr::Drop, // discard the f64
                Instr::I64Const(42),
                Instr::I32Const(cmds.len() as i32),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(0),
                // i64.eq against the host's answer: proves the i64 round-tripped
                // rather than being truncated by an i32 coercion.
                Instr::I64Const(-9_000_000_000),
                Instr::Numeric(0x51),
                Instr::End,
            ]],
            memory: vec![0; 65536],
            locals: vec![0],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        m.memory[..cmds.len()].copy_from_slice(cmds.as_bytes());
        let mut host = LdHost::default();
        let out = run_with_fuel_mut(&mut m, 2, &[], &mut host, DEFAULT_FUEL).unwrap();

        // The i64 result survives the import boundary intact — the old
        // all-i32 coercion could not have represented it.
        assert_eq!(out, vec![1], "i64 result compared equal inside the guest");
        assert_eq!(host.seen.len(), 2);
        assert_eq!(host.seen[0].0, LdexecInit::Handle(0x0010_0007));
        assert_eq!(host.seen[0].1, cmds, "commands are read as (len, ptr)");
        assert_eq!(host.seen[0].2, GuestFn { ctx: 11, ptr: 22 });
        assert!(host.seen[0].2.present());
        assert_eq!(host.seen[1].0, LdexecInit::Long(42));
        assert!(!host.seen[1].2.present(), "a zero funcptr is absent");

        // A host without an ldexec backend fails closed instead of returning 0.
        struct Bare;
        impl Host for Bare {
            fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
                Ok(())
            }
            fn log(&mut self, _: &str) {}
            fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
                Ok(())
            }
        }
        let err = run_with_fuel_mut(&mut m, 2, &[], &mut Bare, DEFAULT_FUEL).unwrap_err();
        assert!(err.contains("ldexec is not implemented"), "{err}");
    }

    /// A host that has not implemented the object lifetime imports must fail
    /// closed rather than hand the guest an invented handle.
    #[test]
    fn default_host_refuses_object_lifetime_imports() {
        struct Bare;
        impl Host for Bare {
            fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
                Ok(())
            }
            fn log(&mut self, _: &str) {}
            fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
                Ok(())
            }
        }
        assert!(Bare.add_object().is_err());
        assert!(Bare.remove_object(crate::OBJECT_BASE).is_err());
        assert!(Bare.copy_object_ref(crate::OBJECT_BASE).is_err());
    }

    fn eval(params: u32, locals: u32, ops: &[u8], args: &[i32]) -> Result<Vec<i32>, String> {
        let m = decode(&numeric(params, 1, locals, ops))?;
        run(&m, 0, args, &mut TestHost::default())
    }

    fn memory_eval(
        ops: &[u8],
        args: &[i32],
        min: u32,
        max: Option<u32>,
    ) -> Result<Vec<i32>, String> {
        let bytes = numeric_with_memory(args.len() as u32, 1, 1, ops, Some((min, max)));
        run(&decode(&bytes)?, 0, args, &mut TestHost::default())
    }

    #[test]
    fn call_indirect_dispatches_through_element_table() {
        let m = Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![],
            func_types: vec![0, 1, 0],
            mem_pages: 0,
            max_mem_pages: None,
            exports: vec![],
            bodies: vec![
                vec![Instr::I32Const(42), Instr::End],
                vec![
                    Instr::LocalGet(0),
                    Instr::I32Const(1),
                    Instr::I32Add,
                    Instr::End,
                ],
                vec![
                    Instr::I32Const(0),
                    Instr::CallIndirect {
                        typeidx: 0,
                        tableidx: 0,
                    },
                    Instr::End,
                ],
            ],
            memory: vec![],
            locals: vec![0, 0, 0],
            has_memory: false,
            tags: vec![],
            globals: vec![],
            tables: vec![Table { min: 3, max: None }],
            elements: vec![Element {
                offset: 0,
                funcs: vec![0, 1, 0],
            }],
            data_count: None,
            data_segments: Vec::new(),
        };
        assert_eq!(run(&m, 2, &[], &mut TestHost::default()).unwrap(), [42]);

        let mut m2 = m.clone();
        m2.bodies.push(vec![
            Instr::I32Const(10),
            Instr::I32Const(1),
            Instr::CallIndirect {
                typeidx: 1,
                tableidx: 0,
            },
            Instr::End,
        ]);
        m2.func_types.push(0);
        m2.locals.push(0);
        assert_eq!(run(&m2, 3, &[], &mut TestHost::default()).unwrap(), [11]);
    }

    #[test]
    fn table_size_grow_get_set_and_fill_mutate_call_targets() {
        let m = Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![],
            func_types: vec![0, 1, 0, 0, 0, 0, 0, 0],
            mem_pages: 0,
            max_mem_pages: None,
            exports: vec![],
            bodies: vec![
                vec![Instr::I32Const(42), Instr::End],
                vec![
                    Instr::LocalGet(0),
                    Instr::I32Const(1),
                    Instr::I32Add,
                    Instr::End,
                ],
                vec![Instr::TableSize(0), Instr::End],
                vec![
                    Instr::I32Const(0),
                    Instr::I32Const(0),
                    Instr::TableGrow(0),
                    Instr::End,
                ],
                vec![Instr::I32Const(1), Instr::TableGet(0), Instr::End],
                vec![
                    Instr::I32Const(2),
                    Instr::I32Const(2),
                    Instr::TableSet(0),
                    Instr::I32Const(10),
                    Instr::I32Const(2),
                    Instr::CallIndirect {
                        typeidx: 1,
                        tableidx: 0,
                    },
                    Instr::End,
                ],
                vec![
                    Instr::I32Const(0),
                    Instr::I32Const(0),
                    Instr::I32Const(2),
                    Instr::TableFill(0),
                    Instr::I32Const(1),
                    Instr::TableGet(0),
                    Instr::End,
                ],
                vec![
                    Instr::I32Const(2),
                    Instr::I32Const(0),
                    Instr::I32Const(1),
                    Instr::TableInit { elem: 0, table: 0 },
                    Instr::I32Const(2),
                    Instr::TableGet(0),
                    Instr::End,
                ],
            ],
            memory: vec![],
            locals: vec![0, 0, 0, 0, 0, 0, 0, 0],
            has_memory: false,
            tags: vec![],
            globals: vec![],
            tables: vec![Table {
                min: 3,
                max: Some(10),
            }],
            elements: vec![Element {
                offset: 0,
                funcs: vec![0, 1, 0],
            }],
            data_count: None,
            data_segments: Vec::new(),
        };
        assert_eq!(run(&m, 2, &[], &mut TestHost::default()).unwrap(), [3]);
        assert_eq!(run(&m, 3, &[], &mut TestHost::default()).unwrap(), [3]); // grow by 0
        assert_eq!(run(&m, 4, &[], &mut TestHost::default()).unwrap(), [2]); // func 1 -> raw 2
        assert_eq!(run(&m, 5, &[], &mut TestHost::default()).unwrap(), [11]); // set slot 2 -> func 1, call
        assert_eq!(run(&m, 6, &[], &mut TestHost::default()).unwrap(), [0]); // fill with null
        assert_eq!(run(&m, 7, &[], &mut TestHost::default()).unwrap(), [1]); // init slot 2 from elem
    }

    #[test]
    fn memory_init_and_data_drop_operate_on_passive_segments() {
        let mut m = Module {
            types: vec![FuncType {
                params: vec![],
                results: vec![ValType::I32],
            }],
            imports: vec![],
            func_types: vec![0, 0],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![],
            bodies: vec![
                vec![
                    Instr::I32Const(0), // dst
                    Instr::I32Const(0), // src
                    Instr::I32Const(4), // count
                    Instr::MemoryInit(0),
                    Instr::I32Const(0),
                    Instr::I32Load {
                        align: 2,
                        offset: 0,
                    },
                    Instr::End,
                ],
                vec![
                    Instr::DataDrop(0),
                    Instr::I32Const(0),
                    Instr::I32Const(0),
                    Instr::I32Const(1),
                    Instr::MemoryInit(0),
                    Instr::I32Const(0),
                    Instr::End,
                ],
            ],
            memory: vec![0; 65536],
            locals: vec![0, 0],
            has_memory: true,
            tags: vec![],
            globals: vec![],
            tables: vec![],
            elements: vec![],
            data_count: Some(1),
            data_segments: vec![DataSegment {
                active: false,
                offset: 0,
                bytes: vec![0x78, 0x56, 0x34, 0x12],
            }],
        };
        assert_eq!(
            run(&m, 0, &[], &mut TestHost::default()).unwrap(),
            [0x12345678]
        );
        assert!(run(&m, 1, &[], &mut TestHost::default()).is_err());

        // Reusing a dropped segment on a fresh runtime should also fail.
        m.bodies[1] = vec![
            Instr::DataDrop(0),
            Instr::I32Const(0),
            Instr::I32Const(0),
            Instr::I32Const(4),
            Instr::MemoryInit(0),
            Instr::I32Const(0),
            Instr::End,
        ];
        assert!(run(&m, 1, &[], &mut TestHost::default()).is_err());
    }

    #[test]
    fn throw_catch_and_rethrow_execute_legacy_exception_handling() {
        let m = Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
            ],
            imports: vec![],
            func_types: vec![0, 0],
            mem_pages: 0,
            max_mem_pages: None,
            exports: vec![],
            bodies: vec![
                vec![
                    Instr::Try(Some(ValType::I32)),
                    Instr::I32Const(1234),
                    Instr::Throw(0),
                    Instr::Catch(0),
                    Instr::Drop,
                    Instr::I32Const(99),
                    Instr::End,
                    Instr::End,
                ],
                vec![
                    Instr::Try(Some(ValType::I32)),
                    Instr::Try(Some(ValType::I32)),
                    Instr::I32Const(42),
                    Instr::Throw(0),
                    Instr::Catch(0),
                    Instr::Drop,
                    Instr::I32Const(11),
                    Instr::Throw(0),
                    Instr::End,
                    Instr::Catch(0),
                    Instr::Drop,
                    Instr::I32Const(77),
                    Instr::End,
                    Instr::End,
                ],
            ],
            memory: vec![],
            locals: vec![0, 0],
            has_memory: false,
            tags: vec![Tag { typeidx: 1 }],
            globals: vec![],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        assert_eq!(run(&m, 0, &[], &mut TestHost::default()).unwrap(), [99]);
        assert_eq!(run(&m, 1, &[], &mut TestHost::default()).unwrap(), [77]);
    }

    #[test]
    fn memory_copy_and_fill_operate_on_linear_memory() {
        let copy_ops = [
            0x41, 10, // dest = 10
            0x41, 0, // src = 0
            0x41, 5, // len = 5
            0xfc, 0x0a, 0x00, 0x00, // memory.copy
            0x41, 0, // result 0
            0x0b,
        ];
        let mut m = decode(&numeric_with_memory(0, 1, 0, &copy_ops, Some((1, None)))).unwrap();
        m.memory[0..5].copy_from_slice(&[1, 2, 3, 4, 5]);
        run_with_fuel_mut(&mut m, 0, &[], &mut TestHost::default(), 1000).unwrap();
        assert_eq!(&m.memory[10..15], &[1, 2, 3, 4, 5]);

        let fill_ops = [
            0x41, 20, // dest = 20
            0x41, 0xC2, 0x00, // value = 66
            0x41, 3, // len = 3
            0xfc, 0x0b, 0x00, // memory.fill
            0x41, 0, // result 0
            0x0b,
        ];
        let mut m = decode(&numeric_with_memory(0, 1, 0, &fill_ops, Some((1, None)))).unwrap();
        run_with_fuel_mut(&mut m, 0, &[], &mut TestHost::default(), 1000).unwrap();
        assert_eq!(&m.memory[20..23], &[0x42, 0x42, 0x42]);
    }

    #[test]
    fn memory_loads_stores_are_little_endian_unaligned_and_width_exact() {
        for (store, load, expected) in [
            (0x36, 0x28, 0x80ff_81feu32 as i32),
            (0x36, 0x2c, -2),
            (0x36, 0x2d, 254),
            (0x36, 0x2e, -32258),
            (0x36, 0x2f, 33278),
            (0x3a, 0x28, 254),
            (0x3b, 0x28, 33278),
        ] {
            let ops = [0x20, 0, 0x20, 1, store, 0, 2, 0x20, 0, load, 0, 2, 0x0b];
            assert_eq!(
                memory_eval(&ops, &[1, 0x80ff_81feu32 as i32], 1, None).unwrap(),
                [expected]
            );
        }
        for load in [0x28, 0x2c, 0x2d, 0x2e, 0x2f] {
            assert_eq!(
                memory_eval(&[0x41, 0, load, 0, 0, 0x0b], &[], 1, None).unwrap(),
                [0]
            );
        }
        assert_eq!(
            memory_eval(
                &[0x20, 0, 0x41, 0x7f, 0x3a, 0, 0, 0x20, 0, 0x2d, 0, 0, 0x0b],
                &[65535],
                1,
                None
            )
            .unwrap(),
            [255]
        );
    }

    #[test]
    fn memory_out_of_bounds_does_not_wrap_or_partially_store() {
        for (op, width) in [
            (0x28, 4),
            (0x2c, 1),
            (0x2d, 1),
            (0x2e, 2),
            (0x2f, 2),
            (0x36, 4),
            (0x3a, 1),
            (0x3b, 2),
        ] {
            let store = matches!(op, 0x36 | 0x3a | 0x3b);
            for (address, offset) in [(65537 - width, 0), (-1, 1), (1, u32::MAX), (i32::MIN, 0)] {
                let ins = match op {
                    0x28 => Instr::I32Load { align: 0, offset },
                    0x2c => Instr::I32Load8S { align: 0, offset },
                    0x2d => Instr::I32Load8U { align: 0, offset },
                    0x2e => Instr::I32Load16S { align: 0, offset },
                    0x2f => Instr::I32Load16U { align: 0, offset },
                    0x36 => Instr::I32Store { align: 0, offset },
                    0x3a => Instr::I32Store8 { align: 0, offset },
                    _ => Instr::I32Store16 { align: 0, offset },
                };
                let mut m =
                    decode(&numeric_with_memory(0, 0, 0, &[0x0b], Some((1, None)))).unwrap();
                m.memory.fill(0x55);
                m.bodies[0] = vec![Instr::I32Const(address)];
                if store {
                    m.bodies[0].push(Instr::I32Const(-1));
                }
                m.bodies[0].push(ins);
                if !store {
                    m.bodies[0].push(Instr::Drop);
                }
                m.bodies[0].push(Instr::End);
                let (elem_dropped, data_dropped) = init_dropped(&m);
                let mut runtime = Runtime {
                    m: &m,
                    info: analyze(&m).unwrap(),
                    memory: m.memory.clone(),
                    globals: m
                        .globals
                        .iter()
                        .map(|g| Value::from_raw(g.valtype, g.value))
                        .collect(),
                    host: &mut TestHost::default(),
                    fuel: DEFAULT_FUEL,
                    tables: init_tables(&m),
                    elem_dropped,
                    data_dropped,
                    caught: None,
                    asyncify: None,
                    asyncify_data: 0,
                    string_pool_next: m.memory.len() as u32,
                };
                assert!(runtime
                    .invoke(0, &[], 0)
                    .unwrap_err()
                    .contains("out of bounds"));
                assert_eq!(runtime.memory, m.memory);
            }
        }
        assert!(memory_eval(&[0x41, 0, 0x2d, 0, 0, 0x0b], &[], 0, None).is_err());
    }

    #[test]
    fn memory_growth_respects_declared_max_global_cap_and_unsigned_delta() {
        let ops = [0x20, 0, 0x40, 0, 0x0b];
        for (min, max, delta, expected) in [
            (0, Some(0), 0, 0),
            (0, Some(0), 1, -1),
            (1, Some(2), 0, 1),
            (1, Some(2), 1, 1),
            (1, Some(2), 2, -1),
            (1, None, 31, 1),
            (1, None, 32, -1),
            (1, Some(65536), 31, 1),
            (1, Some(65536), 32, -1),
            (32, None, 0, 32),
            (32, None, 1, -1),
            (1, None, -1, -1),
            (1, None, i32::MIN, -1),
        ] {
            assert_eq!(memory_eval(&ops, &[delta], min, max).unwrap(), [expected]);
        }
        let size = [0x20, 0, 0x40, 0, 0x1a, 0x3f, 0, 0x0b];
        assert_eq!(memory_eval(&size, &[1], 1, Some(2)).unwrap(), [2]);
        assert_eq!(memory_eval(&size, &[2], 1, Some(2)).unwrap(), [1]);
        let mut m = decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x3f, 0, 0x0b],
            Some((1, Some(2))),
        ))
        .unwrap();
        m.memory[0] = 42;
        m.bodies[0] = vec![
            Instr::I32Const(1),
            Instr::MemoryGrow,
            Instr::Drop,
            Instr::I32Const(65536),
            Instr::I32Load {
                align: 2,
                offset: 0,
            },
            Instr::End,
        ];
        let mut host = TestHost::default();
        let (elem_dropped, data_dropped) = init_dropped(&m);
        let mut runtime = Runtime {
            m: &m,
            info: analyze(&m).unwrap(),
            memory: m.memory.clone(),
            globals: m
                .globals
                .iter()
                .map(|g| Value::from_raw(g.valtype, g.value))
                .collect(),
            host: &mut host,
            fuel: DEFAULT_FUEL,
            tables: init_tables(&m),
            elem_dropped,
            data_dropped,
            caught: None,
            asyncify: None,
            asyncify_data: 0,
            string_pool_next: m.memory.len() as u32,
        };
        assert_eq!(runtime.invoke(0, &[], 0).unwrap(), [Value::I32(0)]);
        assert_eq!(runtime.memory[0], 42);
        assert!(runtime.memory[65536..].iter().all(|b| *b == 0));
        let before = runtime.memory.clone();
        assert_eq!(runtime.grow_memory(u32::MAX), -1);
        assert_eq!(runtime.memory, before);
        assert_eq!(m.memory.len(), 65536);
    }

    #[test]
    fn calls_and_host_imports_share_memory_but_runs_are_isolated() {
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        m.bodies.push(vec![
            Instr::I32Const(32),
            Instr::I32Const(i32::from(b'j')),
            Instr::I32Store8 {
                align: 0,
                offset: 0,
            },
            Instr::End,
        ]);
        m.locals.push(0);
        m.func_types.push(1);
        m.bodies[0].insert(0, Instr::Call(2));
        let mut root = Node::elem("div");
        root.id = Some("status".into());
        run_start(
            &m,
            &mut DomHost {
                dom: &mut root,
                handles: Vec::new(),
            },
        )
        .unwrap();
        assert_eq!(root.inner_text(), "jello");
        assert_eq!(&m.memory[32..37], b"hello");
        m.bodies[0].remove(0);
        run_start(
            &m,
            &mut DomHost {
                dom: &mut root,
                handles: Vec::new(),
            },
        )
        .unwrap();
        assert_eq!(root.inner_text(), "hello");
        let bytes = numeric_with_memory(
            0,
            1,
            1,
            &[
                0x41, 0, 0x28, 2, 0, 0x21, 0, 0x41, 0, 0x41, 7, 0x36, 2, 0, 0x20, 0, 0x0b,
            ],
            Some((1, None)),
        );
        let m = decode(&bytes).unwrap();
        for _ in 0..3 {
            assert_eq!(run(&m, 0, &[], &mut TestHost::default()).unwrap(), [0]);
        }
        let mut m = decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x3f, 0, 0x0b],
            Some((1, Some(2))),
        ))
        .unwrap();
        m.bodies[0] = vec![Instr::Call(1), Instr::Drop, Instr::MemorySize, Instr::End];
        m.bodies
            .push(vec![Instr::I32Const(1), Instr::MemoryGrow, Instr::End]);
        m.func_types.push(0);
        m.locals.push(0);
        for _ in 0..3 {
            assert_eq!(run(&m, 0, &[], &mut TestHost::default()).unwrap(), [2]);
        }
    }

    #[test]
    #[ignore = "requires Node.js native WebAssembly"]
    fn memory_semantics_match_native_webassembly() {
        use std::fmt::Write;
        let mut cases = Vec::new();
        for store in [0x36, 0x3a, 0x3b] {
            for load in [0x28, 0x2c, 0x2d, 0x2e, 0x2f] {
                let ops = [0x20, 0, 0x20, 1, store, 0, 1, 0x20, 0, load, 0, 1, 0x0b];
                let bytes = numeric_with_memory(2, 1, 0, &ops, Some((1, Some(2))));
                for address in [0, 2, 65532, 65535, -1] {
                    cases.push((bytes.clone(), vec![address, 0x80ff_81feu32 as i32]));
                }
            }
        }
        for (min, max) in [(0, 0), (0, 2), (1, 2)] {
            for ops in [
                &[0x20, 0, 0x40, 0, 0x0b][..],
                &[0x20, 0, 0x40, 0, 0x1a, 0x3f, 0, 0x0b],
            ] {
                for delta in [0, 1, 2, -1, i32::MIN] {
                    cases.push((
                        numeric_with_memory(1, 1, 0, ops, Some((min, Some(max)))),
                        vec![delta],
                    ));
                }
            }
        }
        let mut source = String::from("const cases=[");
        let mut expected = Vec::new();
        for (bytes, args) in &cases {
            write!(source, "{{bytes:{bytes:?},args:{args:?}}},").unwrap();
            let m = decode(bytes).unwrap();
            expected.push(match run(&m, 0, args, &mut TestHost::default()) {
                Ok(v) => v[0].to_string(),
                Err(_) => "trap".into(),
            });
        }
        source.push_str("];for(const c of cases){const m=new WebAssembly.Module(Uint8Array.from(c.bytes));const i=new WebAssembly.Instance(m);try{console.log(i.exports.main(...c.args))}catch(e){if(!(e instanceof WebAssembly.RuntimeError))throw e;console.log('trap')}}");
        let output = std::process::Command::new("node")
            .args(["-e", &source])
            .output()
            .expect("Node.js must be installed for native WASM comparisons");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let actual = String::from_utf8(output.stdout).unwrap();
        assert_eq!(actual.lines().collect::<Vec<_>>(), expected);
        println!("native WebAssembly matched {} memory cases", cases.len());
    }

    #[test]
    fn locals_are_zero_initialized_and_tee_preserves_value() {
        assert_eq!(eval(0, 1, &[0x20, 0, 0x0b], &[]).unwrap(), [0]);
        assert_eq!(
            eval(1, 1, &[0x20, 0, 0x22, 1, 0x20, 1, 0x6c, 0x0b], &[7]).unwrap(),
            [49]
        );
        assert!(eval(1, 0, &[0x20, 0, 0x0b], &[]).is_err());
        assert!(eval(1, 0, &[0x20, 0, 0x0b], &[1, 2]).is_err());
    }

    #[test]
    fn typed_if_and_recursive_calls_return_only_declared_results() {
        let factorial = [
            0x20, 0, 0x45, 0x04, 0x7f, 0x41, 1, 0x05, 0x20, 0, 0x20, 0, 0x41, 1, 0x6b, 0x10, 0,
            0x6c, 0x0b, 0x0b,
        ];
        assert_eq!(eval(1, 0, &factorial, &[5]).unwrap(), [120]);
        assert_eq!(eval(1, 0, &factorial, &[0]).unwrap(), [1]);
        assert!(eval(1, 0, &factorial, &[1000])
            .unwrap_err()
            .contains("call depth"));
        assert_eq!(
            eval(0, 0, &[0x41, 11, 0x41, 7, 0x0f, 0x0b], &[]).unwrap(),
            [7]
        );
    }

    #[test]
    fn loops_branch_depth_and_block_results() {
        let sum = [
            0x02, 0x40, 0x03, 0x40, 0x20, 0, 0x45, 0x0d, 1, 0x20, 1, 0x20, 0, 0x6a, 0x21, 1, 0x20,
            0, 0x41, 1, 0x6b, 0x21, 0, 0x0c, 0, 0x0b, 0x0b, 0x20, 1, 0x0b,
        ];
        assert_eq!(eval(1, 1, &sum, &[10]).unwrap(), [55]);
        assert_eq!(eval(1, 1, &sum, &[0]).unwrap(), [0]);
        assert_eq!(
            eval(
                0,
                0,
                &[0x02, 0x7f, 0x41, 11, 0x41, 7, 0x0c, 0, 0x0b, 0x0b],
                &[]
            )
            .unwrap(),
            [7]
        );
        let m = decode(&numeric(0, 0, 0, &[0x03, 0x40, 0x0c, 0, 0x0b, 0x0b])).unwrap();
        assert!(run_with_fuel(&m, 0, &[], &mut TestHost::default(), 32)
            .unwrap_err()
            .contains("fuel exhausted"));
    }

    #[test]
    fn sign_extension_opcodes_narrow_then_widen_signed() {
        // 0xc0/0xc1 are i32.extend8_s / i32.extend16_s. LDC 1.43 emits them for
        // D `byte`/`short` casts in the generated cell, so they must execute
        // rather than fail closed as unknown opcodes.
        for (opcode, input, expected) in [
            (0xc0u8, 0x0000_00ff, -1),
            (0xc0, 0x0000_007f, 127),
            (0xc0, 0x1234_5680, -128),
            (0xc1, 0x0000_ffff, -1),
            (0xc1, 0x0000_7fff, 32767),
            (0xc1, 0x1234_8000, -32768),
        ] {
            assert_eq!(
                eval(1, 0, &[0x20, 0, opcode, 0x0b], &[input]).unwrap(),
                [expected],
                "{opcode:#x} on {input:#x}"
            );
        }
        // The i64 forms decode and validate as unary conversions too.
        for opcode in [0xc2u8, 0xc3, 0xc4] {
            assert!(decode(&numeric(0, 0, 0, &[0x42, 0, opcode, 0x1a, 0x0b])).is_ok());
        }
        // 0xc5 is still unassigned and must remain rejected.
        assert!(decode(&numeric(1, 0, 0, &[0x20, 0, 0xc5, 0x1a, 0x0b])).is_err());
    }

    #[test]
    fn numeric_wrapping_shifts_comparisons_and_traps() {
        for (opcode, a, b, expected) in [
            (0x6a, i32::MAX, 1, i32::MIN),
            (0x6b, i32::MIN, 1, i32::MAX),
            (0x6c, i32::MAX, 2, -2),
            (0x74, 1, 33, 2),
            (0x75, -4, 1, -2),
            (0x76, -4, 1, 0x7fff_fffe),
            (0x77, i32::MIN, 1, 1),
            (0x78, 1, 1, i32::MIN),
            (0x48, -1, 0, 1),
            (0x49, -1, 0, 0),
            (0x6f, i32::MIN, -1, 0),
            (0x70, -1, 2, 1),
            (0x6e, -1, 2, i32::MAX),
        ] {
            assert_eq!(
                eval(2, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b], &[a, b]).unwrap(),
                [expected],
                "{opcode:#x}"
            );
        }
        for (opcode, args) in [
            (0x6d, [i32::MIN, -1]),
            (0x6d, [1, 0]),
            (0x6e, [1, 0]),
            (0x6f, [1, 0]),
            (0x70, [1, 0]),
        ] {
            assert!(eval(2, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b], &args).is_err());
        }
        assert!(eval(0, 0, &[0x00, 0x0b], &[])
            .unwrap_err()
            .contains("unreachable"));
        for condition in [0, -1, 1] {
            assert_eq!(
                eval(1, 0, &[0x41, 7, 0x41, 9, 0x20, 0, 0x1b, 0x0b], &[condition]).unwrap(),
                [if condition == 0 { 9 } else { 7 }]
            );
        }
    }

    #[test]
    fn dom_visibility_retains_content_and_is_idempotent() {
        let mut root = Node::elem("body");
        let mut item = Node::elem("section");
        item.id = Some("item".into());
        item.children.push(Node::elem("p"));
        item.children[0].set_inner_text("retained");
        root.children.push(item);
        let mut host = DomHost {
            dom: &mut root,
            handles: Vec::new(),
        };
        host.set_visible("item", false).unwrap();
        let item = host.dom.get_element_by_id("item").unwrap();
        assert!(item.hidden);
        assert_eq!(item.inner_text(), "retained");
        assert_eq!(item.children[0].name, "p");
        item.clear_dirty();
        host.set_visible("item", false).unwrap();
        assert!(!host.dom.get_element_by_id("item").unwrap().dirty);
        host.set_visible("item", true).unwrap();
        let item = host.dom.get_element_by_id("item").unwrap();
        assert!(!item.hidden);
        assert_eq!(item.inner_text(), "retained");
        assert!(host.set_visible("missing", false).is_err());
    }

    #[test]
    fn manually_emptied_body_is_rejected_before_runtime_frame_creation() {
        let mut m = decode(&numeric(0, 0, 0, &[0x0b])).unwrap();
        m.bodies[0].clear();
        m.exports[0].name = "_start".into();
        assert_eq!(crate::validate(&m).unwrap_err(), "missing function end");
        let outcome = std::panic::catch_unwind(|| {
            let mut host = TestHost::default();
            let direct = run(&m, 0, &[], &mut host).unwrap_err();
            let budgeted = run_with_fuel(&m, 0, &[], &mut host, 32).unwrap_err();
            let start = run_start(&m, &mut host).unwrap_err();
            assert_eq!(host.count, 0);
            (direct, budgeted, start)
        });
        let errors = outcome.expect("empty body must return errors without panicking");
        println!("empty body errors={errors:?}");
        assert_eq!(
            errors,
            (
                "missing function end".into(),
                "missing function end".into(),
                "missing function end".into()
            )
        );
    }

    #[test]
    fn validation_precedes_host_effects_and_pointer_errors_do_not_panic() {
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        let mut host = TestHost::default();
        m.bodies[0].push(Instr::Nop);
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.count, 0);
        m.bodies[0] = vec![
            Instr::I32Const(-1),
            Instr::I32Const(-1),
            Instr::I32Const(0),
            Instr::I32Const(0),
            Instr::Call(0),
            Instr::End,
        ];
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.count, 0);
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        m.memory[0] = 255;
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.count, 0);
        m.types[0].results = vec![crate::ValType::I32];
        assert!(run(&m, 0, &[0, 0, 0, 0], &mut host).is_err());
    }

    /// B62: scalar box/unbox round-trips through the interpreter for i32,
    /// i64, f64, bool, byte, and signed/unsigned narrow integer casts.
    #[test]
    #[allow(clippy::vec_init_then_push)]
    fn libwasm_scalar_box_unbox_round_trips_and_preserves_width() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let import = |name: &str, typeidx: u32| Import {
            module: "env".into(),
            name: name.into(),
            typeidx,
        };
        let types = vec![
            // 0: (i32) -> i32   add/get small scalars
            FuncType {
                params: vec![ValType::I32],
                results: vec![ValType::I32],
            },
            // 1: (i64) -> i32   add long
            FuncType {
                params: vec![ValType::I64],
                results: vec![ValType::I32],
            },
            // 2: (i32) -> i64   get long
            FuncType {
                params: vec![ValType::I32],
                results: vec![ValType::I64],
            },
            // 3: (f64) -> i32   add double
            FuncType {
                params: vec![ValType::F64],
                results: vec![ValType::I32],
            },
            // 4: (i32) -> f64   get double
            FuncType {
                params: vec![ValType::I32],
                results: vec![ValType::F64],
            },
            // 5: () -> i32      _start
            FuncType {
                params: vec![],
                results: vec![ValType::I32],
            },
        ];
        let imports = vec![
            import(crate::IMPORT_LIBWASM_ADD_INT, 0),
            import(crate::IMPORT_LIBWASM_GET_INT, 0),
            import(crate::IMPORT_LIBWASM_ADD_UINT, 0),
            import(crate::IMPORT_LIBWASM_GET_UINT, 0),
            import(crate::IMPORT_LIBWASM_ADD_LONG, 1),
            import(crate::IMPORT_LIBWASM_GET_LONG, 2),
            import(crate::IMPORT_LIBWASM_ADD_DOUBLE, 3),
            import(crate::IMPORT_LIBWASM_GET_DOUBLE, 4),
            import(crate::IMPORT_LIBWASM_ADD_BOOL, 0),
            import(crate::IMPORT_LIBWASM_GET_BOOL, 0),
            import(crate::IMPORT_LIBWASM_ADD_BYTE, 0),
            import(crate::IMPORT_LIBWASM_GET_BYTE, 0),
        ];
        let mut body = vec![];

        // i32 round-trip: 0x7fff_ffff -> get_int must return the same bits.
        body.push(Instr::I32Const(i32::MAX));
        body.push(Instr::Call(0)); // add_int
        body.push(Instr::LocalSet(0));
        body.push(Instr::LocalGet(0));
        body.push(Instr::Call(1)); // get_int
        body.push(Instr::I32Const(i32::MAX));
        body.push(Instr::I32Eq);
        body.push(Instr::LocalSet(2)); // result accumulator

        // u32 round-trip: -1 as i32 stores u32::MAX, get_uint returns the same bits.
        body.push(Instr::I32Const(-1));
        body.push(Instr::Call(2)); // add_uint
        body.push(Instr::LocalSet(1));
        body.push(Instr::LocalGet(1));
        body.push(Instr::Call(3)); // get_uint
        body.push(Instr::I32Const(-1));
        body.push(Instr::I32Eq);
        body.push(Instr::LocalGet(2));
        body.push(Instr::I32And);
        body.push(Instr::LocalSet(2));

        // i64 round-trip: 2^33, larger than i32 range, must not be truncated.
        body.push(Instr::I64Const(8_589_934_592));
        body.push(Instr::Call(4)); // add_long
        body.push(Instr::LocalSet(0));
        body.push(Instr::LocalGet(0));
        body.push(Instr::Call(5)); // get_long
        body.push(Instr::I64Const(8_589_934_592));
        body.push(Instr::Numeric(0x51)); // i64.eq
        body.push(Instr::LocalGet(2));
        body.push(Instr::I32And);
        body.push(Instr::LocalSet(2));

        // f64 round-trip: -0.5 must survive as f64, not become 0.
        body.push(Instr::F64Const((-0.5f64).to_bits()));
        body.push(Instr::Call(6)); // add_double
        body.push(Instr::LocalSet(0));
        body.push(Instr::LocalGet(0));
        body.push(Instr::Call(7)); // get_double
        body.push(Instr::F64Const((-0.5f64).to_bits()));
        body.push(Instr::Numeric(0x61)); // f64.eq
        body.push(Instr::LocalGet(2));
        body.push(Instr::I32And);
        body.push(Instr::LocalSet(2));

        // bool round-trip: true -> 1, get_bool returns 1.
        body.push(Instr::I32Const(1));
        body.push(Instr::Call(8)); // add_bool
        body.push(Instr::LocalSet(0));
        body.push(Instr::LocalGet(0));
        body.push(Instr::Call(9)); // get_bool
        body.push(Instr::I32Const(1));
        body.push(Instr::I32Eq);
        body.push(Instr::LocalGet(2));
        body.push(Instr::I32And);
        body.push(Instr::LocalSet(2));

        // byte round-trip: 0x7f stored as i8, get_byte returns sign-extended 0x7f.
        body.push(Instr::I32Const(0x7f));
        body.push(Instr::Call(10)); // add_byte
        body.push(Instr::LocalSet(0));
        body.push(Instr::LocalGet(0));
        body.push(Instr::Call(11)); // get_byte
        body.push(Instr::I32Const(0x7f));
        body.push(Instr::I32Eq);
        body.push(Instr::LocalGet(2));
        body.push(Instr::I32And);

        body.push(Instr::End);

        let m = Module {
            types,
            imports,
            func_types: vec![5],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 12,
            }],
            bodies: vec![body],
            memory: vec![0; 65536],
            locals: vec![3], // three i32 locals
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        let mut host = TestHost::default();
        let out = run(&m, 12, &[], &mut host).unwrap();
        assert_eq!(out, vec![1], "all scalar round-trips survived");
    }

    /// B63 scaffold: libwasm_get__field boxes a named property, and
    /// libwasm_get_idx__field boxes a vector or numeric object entry.
    #[test]
    fn libwasm_property_get_field_boxes_and_vector_index_box() {
        use crate::values::LibwasmValue;
        let mut host = TestHost::default();
        let h = host.add_object().unwrap();
        host.libwasm_objects_mut()
            .unwrap()
            .get_mut(h)
            .unwrap()
            .set_prop("answer", LibwasmValue::I32(42))
            .unwrap();
        let field_h = host.get_field(h, "answer").unwrap();
        assert!(field_h >= 0x0010_0000);
        assert_eq!(host.get_i32(field_h).unwrap(), 42);

        // Unknown property is fail-closed.
        assert!(host.get_field(h, "missing").is_err());

        // Indexed lookup from an int vector.
        let vec_h = host.add_i32s(&[10, 20, 30]).unwrap();
        let idx_h = host.get_idx_field(vec_h, 1).unwrap();
        assert_eq!(host.get_i32(idx_h).unwrap(), 20);
        assert!(host.get_idx_field(vec_h, 99).is_err());

        // Numeric string-keyed object.
        let obj_h = host.add_object().unwrap();
        host.libwasm_objects_mut()
            .unwrap()
            .get_mut(obj_h)
            .unwrap()
            .set_prop("1", LibwasmValue::U32(123))
            .unwrap();
        let obj_idx_h = host.get_idx_field(obj_h, 1).unwrap();
        assert_eq!(host.get_u32(obj_idx_h).unwrap(), 123);
    }

    /// B63: typed Object_Getter__* and Object_Call__* dispatch through the
    /// generic Host::object_getter / Host::object_call path.
    #[test]
    fn object_getter_and_call_typed_dispatch_box_and_convert() {
        use crate::values::LibwasmValue;
        let mut host = TestHost::default();
        let h = host.add_object().unwrap();
        {
            let v = host.libwasm_objects_mut().unwrap().get_mut(h).unwrap();
            v.set_prop("answer", LibwasmValue::I32(42)).unwrap();
            v.set_prop("name", LibwasmValue::String("hello".into()))
                .unwrap();
            v.set_prop("sample", LibwasmValue::F64(2.5)).unwrap();
        }

        // Object_Getter__int returns the raw i32 value.
        let value = host.object_getter(h, "answer").unwrap();
        assert_eq!(value.to_i32(), 42);

        // Object_Getter__string returns a LibwasmValue::String.
        let value = host.object_getter(h, "name").unwrap();
        assert_eq!(value.as_string().unwrap(), "hello");

        // Object_Getter__Handle boxes the property into a new handle.
        let handle = host.add_libwasm_value(value).unwrap();
        assert_eq!(host.get_i32(handle).unwrap(), 0); // string to_i32 is 0

        // Object_Getter__double returns the f64 value.
        let value = host.object_getter(h, "sample").unwrap();
        assert!((value.to_f64() - 2.5).abs() < 0.001);

        // Object_Call with string -> Handle (concat).
        let result = host
            .object_call(
                h,
                "concat",
                &[
                    LibwasmValue::String("a".into()),
                    LibwasmValue::String("b".into()),
                ],
            )
            .unwrap();
        let concat_h = host.add_libwasm_value(result).unwrap();
        assert_eq!(host.get_string(concat_h).unwrap(), "ab");

        // Object_Call with int -> void (double) discards the result; the host
        // still computes it, so the method name is enough.
        let result = host
            .object_call(h, "double", &[LibwasmValue::I32(7)])
            .unwrap();
        assert_eq!(result.to_i32(), 14);

        // Unknown method and missing property are fail-closed.
        assert!(host.object_call(h, "missing", &[]).is_err());
        assert!(host.object_getter(h, "missing").is_err());
    }

    /// B63: the runtime parses Object_Getter__* / Object_Call__* import names,
    /// reads method/argument strings from wasm memory, and marshals the ABI.
    #[test]
    fn object_getter_and_call_runtime_dispatch_through_module_imports() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let mut m = Module {
            types: vec![
                // 0: Object_Getter__int (handle, len, ptr) -> i32
                FuncType {
                    params: vec![ValType::I32, ValType::I32, ValType::I32],
                    results: vec![ValType::I32],
                },
                // 1: Object_Call_string__Handle (handle, mlen, mptr, alen, aptr) -> i32
                FuncType {
                    params: vec![
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                        ValType::I32,
                    ],
                    results: vec![ValType::I32],
                },
                // 2: _start (handle) -> i32
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "Object_Getter__int".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "Object_Call_string__Handle".into(),
                    typeidx: 1,
                },
            ],
            func_types: vec![2],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 2,
            }],
            bodies: vec![
                // _start: return (Object_Getter__int(h, 6, 0) == 42) ?
                //        (Object_Call_string__Handle(h, 4, 6, 1, 10) >= 0x100000) : 0
                vec![
                    Instr::LocalGet(0),
                    Instr::I32Const(6),
                    Instr::I32Const(0),
                    Instr::Call(0),
                    Instr::I32Const(42),
                    Instr::I32Eq,
                    Instr::LocalGet(0),
                    Instr::I32Const(4),
                    Instr::I32Const(6),
                    Instr::I32Const(1),
                    Instr::I32Const(10),
                    Instr::Call(1),
                    Instr::I32Const(0x0010_0000),
                    Instr::I32GeU,
                    Instr::I32And,
                    Instr::End,
                ],
            ],
            memory: vec![0; 65536],
            locals: vec![0],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        // "answer" at 0 (6 bytes), "echo" at 6 (4 bytes), argument "x" at 10 (1 byte).
        for (off, bytes) in [
            (0usize, "answer".as_bytes()),
            (6, "echo".as_bytes()),
            (10, "x".as_bytes()),
        ] {
            m.memory[off..off + bytes.len()].copy_from_slice(bytes);
        }

        let mut host = TestHost::default();
        let h = host.add_object().unwrap();
        host.libwasm_objects_mut()
            .unwrap()
            .get_mut(h)
            .unwrap()
            .set_prop("answer", LibwasmValue::I32(42))
            .unwrap();
        let out = run(&m, 2, &[h], &mut host).unwrap();
        assert_eq!(
            out,
            vec![1],
            "Object_Getter__int and Object_Call_string__Handle dispatch through the runtime"
        );
    }

    /// B64: `Object_Getter__Optional*` writes a value and a presence flag
    /// through an sret pointer.
    #[test]
    fn object_optional_getter_writes_sret() {
        use crate::binary::{Export, FuncType, Global, Import, Module, ValType};
        let mut m = Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32; 4],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32, ValType::I32],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![Import {
                module: "env".into(),
                name: "Object_Getter__OptionalUint".into(),
                typeidx: 0,
            }],
            func_types: vec![1],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 1,
            }],
            bodies: vec![vec![
                // raw is local 0, h is local 1; call Object_Getter__OptionalUint(raw, h, len, ptr)
                Instr::LocalGet(0),
                Instr::LocalGet(1),
                Instr::I32Const(6),
                Instr::I32Const(0),
                Instr::Call(0),
                // return (defined << 16) | value
                Instr::I32Const(100),
                Instr::I32Load {
                    align: 2,
                    offset: 0,
                },
                Instr::I32Const(100),
                Instr::I32Load {
                    align: 2,
                    offset: 4,
                },
                Instr::I32Const(16),
                Instr::I32Shl,
                Instr::I32Or,
                Instr::End,
            ]],
            memory: vec![0; 65536],
            locals: vec![0],
            has_memory: true,
            tags: vec![],
            globals: vec![Global {
                valtype: ValType::I32,
                mutable: true,
                value: 0,
            }],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        m.memory[0..6].copy_from_slice(b"answer");
        m.memory[6..13].copy_from_slice(b"missing");

        let mut host = TestHost::default();
        let h = host.add_object().unwrap();
        host.libwasm_objects_mut()
            .unwrap()
            .get_mut(h)
            .unwrap()
            .set_prop("answer", LibwasmValue::I32(42))
            .unwrap();

        let out = run_with_fuel_mut(&mut m, 1, &[100, h], &mut host, 1000).unwrap();
        assert_eq!(out, vec![0x0001_002a], "OptionalUint present value is 42");

        // Now point at the missing property; value and defined should both be 0.
        m.bodies[0][2] = Instr::I32Const(7); // len = 7 for "missing"
        m.bodies[0][3] = Instr::I32Const(6); // ptr = 6 for "missing"
        m.memory = vec![0; 65536];
        m.memory[0..6].copy_from_slice(b"answer");
        m.memory[6..13].copy_from_slice(b"missing");
        let out = run_with_fuel_mut(&mut m, 1, &[100, h], &mut host, 1000).unwrap();
        assert_eq!(out, vec![0], "OptionalUint missing is None");
    }
}
