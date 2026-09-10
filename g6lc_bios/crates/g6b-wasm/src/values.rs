// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! libwasm object-table payloads (B62 + B63 scaffold).
//!
//! `libwasm_add__*` boxes a scalar or small array into a refcounted handle;
//! `libwasm_get__*` unboxes it.  `Object` adds an allow-listed property map,
//! the foundation of the B63 registry.  This value model is intentionally
//! narrow: no prototypes, no functions, no cycles.  The JS-facing
//! `g6b_js::JsValue` lives in `g6b-js` and is converted to/from this type only
//! in the kernel.

use std::collections::HashMap;

use crate::objects::ObjectTable;

/// Discriminator for the allow-listed host object kind.  B63 uses this to
/// choose the property/method table and to keep object-table payloads typed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ObjectKind {
    /// `libwasm_add__object()` — an empty host object with no kind yet.
    Empty,
    /// A DOM/Node/Element produced by `createElement` or the libwasm SPA.
    Element,
    /// Retired G6LC_G6B name for handle 2 (it was never BoardSpec). Prefer
    /// [`ObjectKind::Window`].
    Scope,
    /// The browser `window` (JS export registry, location, fetch).
    Window,
    /// The browser `document`.
    Document,
    /// A kernel router or fetch result.
    Router,
    /// B65: a parsed JSON object (`JSON_parse_string`).
    Json,
    /// B65: a JSON array, stored with numeric string keys.
    Array,
    /// A DOM `Event` interned for listener re-entry (`clientX`/`preventDefault`).
    Event,
    /// Interned `window.pglite` factory (`PgLite()` / `attempt(dataDir)`).
    StoreFactory,
    /// Open store instance (`query` / `exec` / tx / close).
    Store,
}

/// Payload stored in an [`ObjectTable`] for libwasm object handles.
#[derive(Debug, Clone, PartialEq)]
pub enum LibwasmValue {
    /// `libwasm_add__object()` — a host object with an allow-listed property map.
    Object {
        kind: ObjectKind,
        props: HashMap<String, LibwasmValue>,
    },
    /// `libwasm_add__string(value)` / `libwasm_get__string(handle)`.
    String(String),
    /// A host error or rejection reason stored as an object.
    Error(String),
    /// `libwasm_add__bool`.
    Bool(bool),
    /// `libwasm_add__byte` / `libwasm_get__byte`.
    I8(i8),
    /// `libwasm_add__ubyte` / `libwasm_get__ubyte`.
    U8(u8),
    /// `libwasm_add__short` / `libwasm_get__short`.
    I16(i16),
    /// `libwasm_add__ushort` / `libwasm_get__ushort`.
    U16(u16),
    /// `libwasm_add__int` / `libwasm_get__int`.
    I32(i32),
    /// `libwasm_add__uint` / `libwasm_get__uint`.
    U32(u32),
    /// `libwasm_add__long` / `libwasm_get__long`.
    I64(i64),
    /// `libwasm_add__ulong` / `libwasm_get__ulong`.
    U64(u64),
    /// `libwasm_add__float` / `libwasm_get__float`.
    F32(f32),
    /// `libwasm_add__double` / `libwasm_get__double`.
    F64(f64),
    /// `libwasm_add__ints`.
    I32Vec(Vec<i32>),
    /// `libwasm_add__uints`.
    U32Vec(Vec<u32>),
    /// Missing/empty optional value (B64 `Optional!T` None).
    None,
}

impl LibwasmValue {
    /// Best-effort conversion to a JavaScript/Lodash string, matching the
    /// g6b-js `JsValue::to_js_string` contract for the scalar subset.
    pub fn to_js_string(&self) -> String {
        match self {
            LibwasmValue::Object { .. } => "[object Object]".into(),
            LibwasmValue::String(s) | LibwasmValue::Error(s) => s.clone(),
            LibwasmValue::Bool(b) => b.to_string(),
            LibwasmValue::I8(v) => v.to_string(),
            LibwasmValue::U8(v) => v.to_string(),
            LibwasmValue::I16(v) => v.to_string(),
            LibwasmValue::U16(v) => v.to_string(),
            LibwasmValue::I32(v) => v.to_string(),
            LibwasmValue::U32(v) => v.to_string(),
            LibwasmValue::I64(v) => v.to_string(),
            LibwasmValue::U64(v) => v.to_string(),
            LibwasmValue::F32(v) => format_number(f64::from(*v)),
            LibwasmValue::F64(v) => format_number(*v),
            LibwasmValue::I32Vec(items) => items
                .iter()
                .map(|v| v.to_string())
                .collect::<Vec<_>>()
                .join(","),
            LibwasmValue::U32Vec(items) => items
                .iter()
                .map(|v| v.to_string())
                .collect::<Vec<_>>()
                .join(","),
            LibwasmValue::None => "null".into(),
        }
    }

    fn as_i64(&self) -> i64 {
        match self {
            LibwasmValue::Bool(b) => i64::from(*b),
            LibwasmValue::I8(v) => i64::from(*v),
            LibwasmValue::U8(v) => i64::from(*v),
            LibwasmValue::I16(v) => i64::from(*v),
            LibwasmValue::U16(v) => i64::from(*v),
            LibwasmValue::I32(v) => i64::from(*v),
            LibwasmValue::U32(v) => i64::from(*v),
            LibwasmValue::I64(v) => *v,
            LibwasmValue::U64(v) => *v as i64,
            LibwasmValue::F32(v) => f64::from(*v) as i64,
            LibwasmValue::F64(v) => *v as i64,
            _ => 0,
        }
    }

    fn as_u64(&self) -> u64 {
        match self {
            LibwasmValue::Bool(b) => u64::from(*b),
            LibwasmValue::I8(v) => (*v as u8) as u64,
            LibwasmValue::U8(v) => u64::from(*v),
            LibwasmValue::I16(v) => (*v as u16) as u64,
            LibwasmValue::U16(v) => u64::from(*v),
            LibwasmValue::I32(v) => (*v as u32) as u64,
            LibwasmValue::U32(v) => u64::from(*v),
            LibwasmValue::I64(v) => *v as u64,
            LibwasmValue::U64(v) => *v,
            LibwasmValue::F32(v) => f64::from(*v) as u64,
            LibwasmValue::F64(v) => *v as u64,
            _ => 0,
        }
    }

    fn as_f64(&self) -> f64 {
        match self {
            LibwasmValue::Bool(b) => f64::from(u8::from(*b)),
            LibwasmValue::I8(v) => f64::from(*v),
            LibwasmValue::U8(v) => f64::from(*v),
            LibwasmValue::I16(v) => f64::from(*v),
            LibwasmValue::U16(v) => f64::from(*v),
            LibwasmValue::I32(v) => f64::from(*v),
            LibwasmValue::U32(v) => f64::from(*v),
            LibwasmValue::I64(v) => *v as f64,
            LibwasmValue::U64(v) => *v as f64,
            LibwasmValue::F32(v) => f64::from(*v),
            LibwasmValue::F64(v) => *v,
            _ => f64::NAN,
        }
    }

    /// Returns the truthiness of the value, for `libwasm_get__bool`.
    pub fn truthy(&self) -> bool {
        match self {
            LibwasmValue::Object { .. } => true,
            LibwasmValue::String(s) if s.is_empty() => false,
            LibwasmValue::Error(s) => !s.is_empty(),
            LibwasmValue::Bool(b) => *b,
            LibwasmValue::I8(v) => *v != 0,
            LibwasmValue::U8(v) => *v != 0,
            LibwasmValue::I16(v) => *v != 0,
            LibwasmValue::U16(v) => *v != 0,
            LibwasmValue::I32(v) => *v != 0,
            LibwasmValue::U32(v) => *v != 0,
            LibwasmValue::I64(v) => *v != 0,
            LibwasmValue::U64(v) => *v != 0,
            LibwasmValue::F32(v) => *v != 0.0 && !v.is_nan(),
            LibwasmValue::F64(v) => *v != 0.0 && !v.is_nan(),
            LibwasmValue::I32Vec(v) => !v.is_empty(),
            LibwasmValue::U32Vec(v) => !v.is_empty(),
            LibwasmValue::String(_) => true,
            LibwasmValue::None => false,
        }
    }

    /// `libwasm_get__int` / `libwasm_get__uint` / `libwasm_get__byte` / ...
    pub fn to_i32(&self) -> i32 {
        self.as_i64() as i32
    }

    pub fn to_u32(&self) -> u32 {
        self.as_u64() as u32
    }

    pub fn to_i64(&self) -> i64 {
        self.as_i64()
    }

    pub fn to_u64(&self) -> u64 {
        self.as_u64()
    }

    pub fn to_f32(&self) -> f32 {
        self.as_f64() as f32
    }

    pub fn to_f64(&self) -> f64 {
        self.as_f64()
    }

    pub fn to_i16(&self) -> i16 {
        self.as_i64() as i16
    }

    pub fn to_u16(&self) -> u16 {
        self.as_u64() as u16
    }

    pub fn to_i8(&self) -> i8 {
        self.as_i64() as i8
    }

    pub fn to_u8(&self) -> u8 {
        self.as_u64() as u8
    }

    /// String or error content; used by the await/fetch and Lodash paths.
    pub fn as_string(&self) -> Result<&str, String> {
        match self {
            LibwasmValue::String(s) | LibwasmValue::Error(s) => Ok(s.as_str()),
            LibwasmValue::Object { .. } => Err(format!("libwasm object is not a string: {self:?}")),
            other => Err(format!("libwasm object is not a string: {other:?}")),
        }
    }

    /// Create an empty object of the given kind (B63 foundation).
    pub fn empty(kind: ObjectKind) -> Self {
        LibwasmValue::Object {
            kind,
            props: HashMap::new(),
        }
    }

    /// Look up a property by name.  Returns `Ok(value)` if the key exists.
    pub fn get_prop(&self, name: &str) -> Result<&LibwasmValue, String> {
        match self {
            LibwasmValue::Object { props, .. } => props
                .get(name)
                .ok_or_else(|| format!("libwasm object has no property {name:?}")),
            other => Err(format!("libwasm value is not an object: {other:?}")),
        }
    }

    /// Look up a property by name and clone it.
    pub fn clone_prop(&self, name: &str) -> Result<LibwasmValue, String> {
        self.get_prop(name).cloned()
    }

    /// Set a property on an object value, returning the updated value.
    pub fn with_prop(mut self, name: impl Into<String>, value: LibwasmValue) -> Self {
        if let LibwasmValue::Object { props, .. } = &mut self {
            props.insert(name.into(), value);
        }
        self
    }

    /// Set a property on a mutable object value.
    pub fn set_prop(&mut self, name: impl Into<String>, value: LibwasmValue) -> Result<(), String> {
        match self {
            LibwasmValue::Object { props, .. } => {
                props.insert(name.into(), value);
                Ok(())
            }
            other => Err(format!("libwasm value is not an object: {other:?}")),
        }
    }
}

fn format_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".into();
    }
    if n.is_infinite() {
        return if n > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    if n == n.trunc() && n.abs() < 1e21 {
        return format!("{}", n as i64);
    }
    format!("{n}")
}

/// Helper used by `TestHost` and `KernelHost` to store a scalar/array.
pub fn add_value(
    table: &mut ObjectTable<LibwasmValue>,
    value: LibwasmValue,
) -> Result<i32, String> {
    table.add(value)
}

/// Helper used by `TestHost` and `KernelHost` to read a string or error.
pub fn string_of(value: &LibwasmValue) -> String {
    value.to_js_string()
}
