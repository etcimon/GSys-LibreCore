// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B65 JSON codec and `Object_VarArgCall` descriptor parsing.
//!
//! `JSON_parse_string` / `JSON_stringify` bridge `g6b_spec::json` and
//! `LibwasmValue`, so host objects can carry JSON payloads.  `Object_VarArgCall`
//! uses the same JSON parser for its serialized argument list and a small D
//! type-descriptor parser to recover `Optional!T` and `SumType!(...)` shapes.

use std::collections::BTreeMap;

use g6b_spec::{parse_json, stringify_json, Json};

use crate::values::{LibwasmValue, ObjectKind};

/// Parse a JSON document and return the corresponding `LibwasmValue`.
///
/// JSON `null` becomes `LibwasmValue::None`; objects and arrays are stored as
/// `LibwasmValue::Object` with `ObjectKind::Json` or `ObjectKind::Array`.
pub fn parse_libwasm_json(s: &str) -> Result<LibwasmValue, String> {
    json_to_libwasm(&parse_json(s)?)
}

/// Stringify a `LibwasmValue` as JSON.
///
/// Only `None`, scalars, `Object { kind: Json | Array | Empty, ... }` and
/// `String` are supported; other object kinds fail closed.
pub fn stringify_libwasm_json(v: &LibwasmValue) -> Result<String, String> {
    let j = libwasm_to_json(v)?;
    Ok(stringify_json(&j))
}

fn json_to_libwasm(v: &Json) -> Result<LibwasmValue, String> {
    Ok(match v {
        Json::Null => LibwasmValue::None,
        Json::Bool(b) => LibwasmValue::Bool(*b),
        Json::Int(i) => LibwasmValue::I64(*i),
        Json::F64(f) => LibwasmValue::F64(*f),
        Json::Str(s) => LibwasmValue::String(s.clone()),
        Json::Arr(items) => {
            let mut props = std::collections::HashMap::new();
            for (idx, item) in items.iter().enumerate() {
                props.insert(idx.to_string(), json_to_libwasm(item)?);
            }
            LibwasmValue::Object {
                kind: ObjectKind::Array,
                props,
            }
        }
        Json::Obj(map) => {
            let mut props = std::collections::HashMap::new();
            for (k, val) in map.iter() {
                props.insert(k.clone(), json_to_libwasm(val)?);
            }
            LibwasmValue::Object {
                kind: ObjectKind::Json,
                props,
            }
        }
    })
}

fn libwasm_to_json(v: &LibwasmValue) -> Result<Json, String> {
    Ok(match v {
        LibwasmValue::None => Json::Null,
        LibwasmValue::Bool(b) => Json::Bool(*b),
        LibwasmValue::String(s) | LibwasmValue::Error(s) => Json::Str(s.clone()),
        LibwasmValue::I8(n) => Json::Int(i64::from(*n)),
        LibwasmValue::U8(n) => Json::Int(i64::from(*n)),
        LibwasmValue::I16(n) => Json::Int(i64::from(*n)),
        LibwasmValue::U16(n) => Json::Int(i64::from(*n)),
        LibwasmValue::I32(n) => Json::Int(i64::from(*n)),
        LibwasmValue::U32(n) => Json::Int(i64::from(*n)),
        LibwasmValue::I64(n) => Json::Int(*n),
        LibwasmValue::U64(n) => Json::Int(*n as i64),
        LibwasmValue::F32(n) => Json::F64(f64::from(*n)),
        LibwasmValue::F64(n) => Json::F64(*n),
        LibwasmValue::I32Vec(items) => {
            Json::Arr(items.iter().map(|i| Json::Int(i64::from(*i))).collect())
        }
        LibwasmValue::U32Vec(items) => {
            Json::Arr(items.iter().map(|i| Json::Int(i64::from(*i))).collect())
        }
        LibwasmValue::Object { kind, props } => match kind {
            ObjectKind::Array => {
                let mut items = Vec::new();
                let mut keys: Vec<u32> = props
                    .keys()
                    .map(|k| {
                        k.parse::<u32>()
                            .map_err(|_| "JSON array key is not an index".to_string())
                    })
                    .collect::<Result<_, _>>()?;
                keys.sort_unstable();
                for k in keys {
                    items.push(libwasm_to_json(
                        props
                            .get(&k.to_string())
                            .ok_or("missing JSON array index")?,
                    )?);
                }
                Json::Arr(items)
            }
            ObjectKind::Json | ObjectKind::Empty => {
                let mut map = BTreeMap::new();
                for (k, val) in props.iter() {
                    map.insert(k.clone(), libwasm_to_json(val)?);
                }
                Json::Obj(map)
            }
            other => {
                return Err(format!(
                    "JSON stringify on unsupported object kind: {other:?}"
                ))
            }
        },
    })
}

/// Convert a flat JSON argument list into a list of `LibwasmValue`s using a
/// libwasm `argsdef` descriptor.
///
/// The descriptor is a `;`-separated list of D type tokens.  Supported tokens:
/// plain scalars (`bool`, `int`, `uint`, `short`, `ushort`, `long`, `ulong`,
/// `float`, `double`, `string`, `Handle`), `Optional!T` and `SumType!(T1,T2,...)`.
pub fn vararg_from_json(argsdef: &str, args_json: &str) -> Result<Vec<LibwasmValue>, String> {
    let json = parse_json(args_json)?;
    let Json::Arr(items) = json else {
        return Err("Object_VarArgCall args must be a JSON array".into());
    };
    let mut it = items.iter();
    let mut out = Vec::new();
    for token in argsdef.split(';').filter(|t| !t.is_empty()) {
        out.push(consume_arg(token, &mut it)?);
    }
    if it.next().is_some() {
        return Err("Object_VarArgCall args has trailing values".into());
    }
    Ok(out)
}

fn consume_arg(token: &str, it: &mut std::slice::Iter<'_, Json>) -> Result<LibwasmValue, String> {
    if let Some(inner) = token.strip_prefix("Optional!") {
        let defined = it.next().ok_or("Optional missing defined flag")?;
        if defined.truthy() {
            consume_arg(inner, it)
        } else {
            // The optional value is still present in the flat tuple; consume it
            // so the index stays aligned with D's serialized layout.
            let _ = consume_arg(inner, it)?;
            Ok(LibwasmValue::None)
        }
    } else if let Some(inner) = token.strip_prefix("SumType!") {
        let inner = inner
            .strip_prefix('(')
            .and_then(|s| s.strip_suffix(')'))
            .ok_or("SumType missing parentheses")?;
        let disc = it.next().ok_or("SumType missing discriminator")?;
        let idx = disc
            .as_u32()
            .ok_or("SumType discriminator is not an integer")? as usize;
        let mut types = Vec::new();
        let mut depth = 0;
        let mut start = 0;
        for (i, c) in inner.char_indices() {
            match c {
                '(' | '!' => depth += 1,
                ')' => depth -= 1,
                ',' if depth == 0 => {
                    types.push(&inner[start..i]);
                    start = i + 1;
                }
                _ => {}
            }
        }
        types.push(&inner[start..]);
        let mut values = Vec::new();
        for t in types.iter() {
            values.push(consume_arg(t.trim(), it)?);
        }
        values
            .into_iter()
            .nth(idx)
            .ok_or_else(|| format!("SumType discriminator {idx} out of range"))
    } else {
        let v = it
            .next()
            .ok_or_else(|| format!("missing value for {token}"))?;
        convert_json_to_type(v, token)
    }
}

fn convert_json_to_type(v: &Json, ty: &str) -> Result<LibwasmValue, String> {
    Ok(match ty {
        "bool" => LibwasmValue::Bool(v.truthy()),
        "int" => LibwasmValue::I32(
            v.as_i64()
                .ok_or_else(|| format!("int expected integer, got {v:?}"))? as i32,
        ),
        "uint" => LibwasmValue::U32(
            v.as_i64()
                .ok_or_else(|| format!("uint expected integer, got {v:?}"))? as u32,
        ),
        "short" => LibwasmValue::I16(
            v.as_i64()
                .ok_or_else(|| format!("short expected integer, got {v:?}"))? as i16,
        ),
        "ushort" => LibwasmValue::U16(
            v.as_i64()
                .ok_or_else(|| format!("ushort expected integer, got {v:?}"))? as u16,
        ),
        "long" => LibwasmValue::I64(
            v.as_i64()
                .ok_or_else(|| format!("long expected integer, got {v:?}"))?,
        ),
        "ulong" => LibwasmValue::U64(
            v.as_i64()
                .ok_or_else(|| format!("ulong expected integer, got {v:?}"))? as u64,
        ),
        "float" => LibwasmValue::F32(
            v.as_f64()
                .ok_or_else(|| format!("float expected number, got {v:?}"))? as f32,
        ),
        "double" => LibwasmValue::F64(
            v.as_f64()
                .ok_or_else(|| format!("double expected number, got {v:?}"))?,
        ),
        "string" => LibwasmValue::String(
            v.as_str()
                .ok_or_else(|| format!("string expected string, got {v:?}"))?
                .to_string(),
        ),
        "Handle" => LibwasmValue::U32(
            v.as_i64()
                .ok_or_else(|| format!("Handle expected integer, got {v:?}"))? as u32,
        ),
        other => return Err(format!("unsupported vararg type {other}")),
    })
}

/// Convert a `LibwasmValue` result back to JSON for `Object_VarArgCall__string`.
pub fn libwasm_to_json_string(v: &LibwasmValue) -> Result<String, String> {
    let j = libwasm_to_json(v)?;
    Ok(stringify_json(&j))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_parse_stringifies_round_trip() {
        let s = r#"{"a":[1,2.5,true,null,"x"],"b":{"c":false}}"#;
        let v = parse_libwasm_json(s).unwrap();
        assert_eq!(stringify_libwasm_json(&v).unwrap(), s);
    }

    #[test]
    fn vararg_parses_optional_and_sumtype() {
        let argsdef = "Optional!Handle;SumType!(string,Handle);int";
        let args_json = r#"[1,12345,0,"hello",0,42]"#; // defined=1, handle=12345; disc=0, "hello", handle=0; int=42
        let args = vararg_from_json(argsdef, args_json).unwrap();
        assert_eq!(args[0], LibwasmValue::U32(12345));
        assert_eq!(args[1], LibwasmValue::String("hello".into()));
        assert_eq!(args[2], LibwasmValue::I32(42));
    }

    #[test]
    fn vararg_optional_empty_is_none() {
        let argsdef = "Optional!string;int";
        let args_json = r#"[0,"",7]"#;
        let args = vararg_from_json(argsdef, args_json).unwrap();
        assert_eq!(args[0], LibwasmValue::None);
        assert_eq!(args[1], LibwasmValue::I32(7));
    }

    #[test]
    fn vararg_sumtype_handle_is_chosen() {
        let argsdef = "SumType!(string,Handle);int";
        let args_json = r#"[1,"",54321,7]"#;
        let args = vararg_from_json(argsdef, args_json).unwrap();
        assert_eq!(args[0], LibwasmValue::U32(54321));
        assert_eq!(args[1], LibwasmValue::I32(7));
    }
}
