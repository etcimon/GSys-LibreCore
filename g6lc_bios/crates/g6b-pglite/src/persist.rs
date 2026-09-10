// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use crate::engine::Table;
use crate::error::StoreError;
use crate::names::{Purpose, StoreUuid};
use crate::sql::{ColDef, ColType};
use g6b_spec::{parse_json, Json};
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

pub const DUMP_VERSION: i64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersistMode {
    Memory,
    ElfSeed,
    UsbLive,
}

impl PersistMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::ElfSeed => "elf",
            Self::UsbLive => "usb",
        }
    }
}

impl fmt::Display for PersistMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

pub struct Dump {
    pub uuid: StoreUuid,
    pub purpose: Purpose,
    pub label: Option<String>,
    pub tables: BTreeMap<String, Table>,
}

pub fn dump_json(
    uuid: StoreUuid,
    purpose: &Purpose,
    label: Option<&str>,
    tables: &BTreeMap<String, Table>,
) -> Json {
    let mut root = BTreeMap::new();
    root.insert("g6b_store".into(), Json::Int(DUMP_VERSION));
    root.insert("uuid".into(), Json::Str(uuid.hyphenated()));
    root.insert("purpose".into(), Json::Str(purpose.as_str().into()));
    root.insert(
        "label".into(),
        match label {
            Some(s) => Json::Str(s.into()),
            None => Json::Null,
        },
    );
    let mut tmap = BTreeMap::new();
    for (name, t) in tables {
        let mut o = BTreeMap::new();
        o.insert(
            "cols".into(),
            Json::Arr(
                t.cols
                    .iter()
                    .map(|c| {
                        let mut col = BTreeMap::new();
                        col.insert("name".into(), Json::Str(c.name.clone()));
                        col.insert("type".into(), Json::Str(c.ty.as_str().into()));
                        col.insert("pk".into(), Json::Bool(c.primary_key));
                        Json::Obj(col)
                    })
                    .collect(),
            ),
        );
        o.insert(
            "rows".into(),
            Json::Arr(t.rows.iter().map(|r| Json::Arr(r.clone())).collect()),
        );
        o.insert("serial".into(), Json::Int(t.serial));
        tmap.insert(name.clone(), Json::Obj(o));
    }
    root.insert("tables".into(), Json::Obj(tmap));
    Json::Obj(root)
}

pub fn load_dump(blob: &Json) -> Result<Dump, StoreError> {
    let Json::Obj(root) = blob else {
        return Err(StoreError::exec("dump"));
    };
    if root.get("g6b_store") != Some(&Json::Int(DUMP_VERSION)) {
        return Err(StoreError::exec("dump version"));
    }
    let uuid = StoreUuid::parse(
        root.get("uuid")
            .and_then(Json::as_str)
            .ok_or_else(|| StoreError::exec("dump uuid"))?,
    )?;
    let purpose = Purpose::parse(
        root.get("purpose")
            .and_then(Json::as_str)
            .ok_or_else(|| StoreError::exec("dump purpose"))?,
    )?;
    let label = root.get("label").and_then(Json::as_str).map(str::to_string);
    let mut tables = BTreeMap::new();
    if let Some(Json::Obj(tmap)) = root.get("tables") {
        for (name, spec) in tmap {
            let Json::Obj(o) = spec else {
                return Err(StoreError::exec("dump table"));
            };
            let cols = match o.get("cols") {
                Some(Json::Arr(a)) => a
                    .iter()
                    .map(|c| {
                        let Json::Obj(m) = c else {
                            return Err(StoreError::exec("dump col"));
                        };
                        Ok(ColDef {
                            name: m
                                .get("name")
                                .and_then(Json::as_str)
                                .ok_or_else(|| StoreError::exec("dump col"))?
                                .into(),
                            ty: ColType::parse(
                                m.get("type").and_then(Json::as_str).unwrap_or("TEXT"),
                            )?,
                            primary_key: m.get("pk").and_then(Json::as_bool).unwrap_or(false),
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                _ => Vec::new(),
            };
            let rows = match o.get("rows") {
                Some(Json::Arr(a)) => a
                    .iter()
                    .map(|r| match r {
                        Json::Arr(cells) => Ok(cells.clone()),
                        _ => Err(StoreError::exec("dump row")),
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                _ => Vec::new(),
            };
            let serial = o.get("serial").and_then(Json::as_i64).unwrap_or(1);
            tables.insert(name.clone(), Table { cols, rows, serial });
        }
    }
    Ok(Dump {
        uuid,
        purpose,
        label,
        tables,
    })
}

pub fn refuse_unarmed(kind: &'static str) -> StoreError {
    StoreError::PersistUnarmed(kind)
}

/// `G6B_STORE_DUMP` overrides; otherwise `out/g6b_store_dump.json`.
pub fn dump_path() -> PathBuf {
    if let Ok(p) = std::env::var("G6B_STORE_DUMP") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../out/g6b_store_dump.json")
}

/// Set when the operator asked for a specific dump file (`g6b.py store-embed --out`).
pub fn dump_path_explicit() -> Option<PathBuf> {
    std::env::var("G6B_STORE_DUMP")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

/// Host-side dump bytes. Missing file is `None` (open `elf://` → PersistUnarmed).
pub fn read_host_dump_bytes() -> Option<Vec<u8>> {
    let b = std::fs::read(dump_path()).ok()?;
    if b.is_empty() {
        None
    } else {
        Some(b)
    }
}

pub fn read_dump_file(path: &Path) -> Result<Json, StoreError> {
    let s = std::fs::read_to_string(path).map_err(|_| refuse_unarmed("elf"))?;
    parse_json(&s).map_err(StoreError::syntax)
}
