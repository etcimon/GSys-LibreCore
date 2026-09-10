// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTTP `/bios/store` face. HolyC builtins call [`StoreRegistry`] directly.

use crate::catalog::StoreRegistry;
use crate::error::StoreError;
use crate::names::StoreUuid;
use crate::params_from_json;
use crate::persist::PersistMode;
use g6b_spec::{parse_json, stringify_json, Json};
use std::collections::BTreeMap;

/// Live store mutations. `Router` stays `Clone` and does not own the registry.
pub trait StorePort {
    fn handle(&mut self, method: &str, path: &str, body: &[u8]) -> Result<(u16, String), String>;
}

impl StorePort for StoreRegistry {
    fn handle(&mut self, method: &str, path: &str, body: &[u8]) -> Result<(u16, String), String> {
        Ok(dispatch(self, method, path, body))
    }
}

fn dispatch(reg: &mut StoreRegistry, method: &str, path: &str, body: &[u8]) -> (u16, String) {
    if !reg.cfg().enable {
        return not_found();
    }
    let method = method.to_ascii_uppercase();
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let path = path.trim_end_matches('/');
    match route(&method, path) {
        Route::List => list(reg),
        Route::Create => create(reg, body),
        Route::Purpose(p) => purpose(reg, &p),
        Route::Import => import(reg, body),
        Route::Open => open_dir(reg, body),
        Route::Drop(u) => drop_one(reg, u),
        Route::Op(u, op) => op_dispatch(reg, u, &op, &method, body),
        Route::Unknown => not_found(),
    }
}

enum Route {
    List,
    Create,
    Purpose(String),
    Import,
    Open,
    Drop(StoreUuid),
    Op(StoreUuid, String),
    Unknown,
}

fn route(method: &str, path: &str) -> Route {
    let rest = match path.strip_prefix("/bios/store") {
        Some("") | Some("/") => {
            return if method == "GET" {
                Route::List
            } else if method == "POST" {
                Route::Create
            } else {
                Route::Unknown
            };
        }
        Some(r) => r.trim_start_matches('/'),
        None => return Route::Unknown,
    };
    if rest == "import" {
        return if method == "POST" {
            Route::Import
        } else {
            Route::Unknown
        };
    }
    if rest == "open" {
        return if method == "POST" {
            Route::Open
        } else {
            Route::Unknown
        };
    }
    if let Some(p) = rest.strip_prefix("purpose/") {
        return if method == "GET" {
            Route::Purpose(p.to_string())
        } else {
            Route::Unknown
        };
    }
    let (id, op) = match rest.split_once('/') {
        Some((id, op)) => (id, Some(op)),
        None => (rest, None),
    };
    let Ok(uuid) = StoreUuid::parse(id) else {
        return Route::Unknown;
    };
    match (method, op) {
        ("DELETE", None) => Route::Drop(uuid),
        (_, Some(op)) => Route::Op(uuid, op.to_string()),
        _ => Route::Unknown,
    }
}

fn not_found() -> (u16, String) {
    (404, "{\"error\":\"not found\"}".into())
}

fn err(e: StoreError) -> (u16, String) {
    if matches!(e, StoreError::Disabled | StoreError::UnknownStore) {
        return not_found();
    }
    (e.http_status(), stringify_json(&e.to_json()))
}

fn ok_obj(fields: &[(&str, Json)]) -> (u16, String) {
    let mut m = BTreeMap::new();
    m.insert("ok".into(), Json::Bool(true));
    for (k, v) in fields {
        m.insert((*k).into(), v.clone());
    }
    (200, stringify_json(&Json::Obj(m)))
}

fn body_json(body: &[u8]) -> Result<Json, StoreError> {
    if body.is_empty() {
        return Ok(Json::Obj(BTreeMap::new()));
    }
    let s = std::str::from_utf8(body).map_err(|_| StoreError::syntax("body utf8"))?;
    parse_json(s).map_err(StoreError::syntax)
}

fn too_big(reg: &StoreRegistry, kind: &str, body: &[u8]) -> Option<(u16, String)> {
    let s = reg.cfg();
    let cap = match kind {
        "query" | "exec" => s.max_sql_bytes.saturating_add(s.max_param_bytes),
        "load" => s.max_result_bytes,
        _ => return None,
    };
    if body.len() as u32 > cap {
        Some(err(StoreError::Budget("body")))
    } else {
        None
    }
}

fn list(reg: &StoreRegistry) -> (u16, String) {
    let s = reg.cfg();
    let mut m = BTreeMap::new();
    m.insert("ok".into(), Json::Bool(true));
    m.insert("enable".into(), Json::Bool(s.enable));
    m.insert("engine".into(), Json::Str("g6b-pglite".into()));
    m.insert(
        "purposes".into(),
        Json::Arr(s.purposes.iter().map(|p| Json::Str(p.clone())).collect()),
    );
    let mut persist = BTreeMap::new();
    persist.insert("memory".into(), Json::Bool(s.persist_memory));
    persist.insert("elf".into(), Json::Bool(s.persist_elf));
    persist.insert("usb".into(), Json::Bool(s.persist_usb));
    m.insert("persist".into(), Json::Obj(persist));
    let mut budgets = BTreeMap::new();
    budgets.insert("max_stores".into(), Json::Int(s.max_stores as i64));
    budgets.insert("max_sql_bytes".into(), Json::Int(s.max_sql_bytes as i64));
    budgets.insert(
        "max_param_bytes".into(),
        Json::Int(s.max_param_bytes as i64),
    );
    budgets.insert(
        "max_result_bytes".into(),
        Json::Int(s.max_result_bytes as i64),
    );
    m.insert("budgets".into(), Json::Obj(budgets));
    let instances = reg
        .list()
        .into_iter()
        .map(|(u, p, persist, rows)| {
            let mut o = BTreeMap::new();
            o.insert("uuid".into(), Json::Str(u.hyphenated()));
            o.insert("purpose".into(), Json::Str(p.as_str().into()));
            o.insert(
                "persist".into(),
                Json::Str(
                    match persist {
                        PersistMode::Memory => "memory",
                        PersistMode::ElfSeed => "elf",
                        PersistMode::UsbLive => "usb",
                    }
                    .into(),
                ),
            );
            o.insert("rows".into(), Json::Int(rows as i64));
            Json::Obj(o)
        })
        .collect();
    m.insert("instances".into(), Json::Arr(instances));
    (200, stringify_json(&Json::Obj(m)))
}

fn create(reg: &mut StoreRegistry, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let purpose = json.get("purpose").as_str().unwrap_or("registry");
    match reg.create(purpose) {
        Ok(u) => ok_obj(&[
            ("uuid", Json::Str(u.hyphenated())),
            ("purpose", Json::Str(purpose.into())),
        ]),
        Err(e) => err(e),
    }
}

fn purpose(reg: &mut StoreRegistry, purpose: &str) -> (u16, String) {
    match reg.current(purpose) {
        Some(u) => ok_obj(&[
            ("uuid", Json::Str(u.hyphenated())),
            ("purpose", Json::Str(purpose.into())),
        ]),
        None => not_found(),
    }
}

fn import(reg: &mut StoreRegistry, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let volume = json.get("volume").as_str().unwrap_or("");
    let rel = json.get("rel").as_str().unwrap_or("");
    match reg.import(volume, rel) {
        Ok(u) => ok_obj(&[("uuid", Json::Str(u.hyphenated()))]),
        Err(e) => err(e),
    }
}

fn drop_one(reg: &mut StoreRegistry, uuid: StoreUuid) -> (u16, String) {
    match reg.drop(uuid) {
        Ok(()) => ok_obj(&[("uuid", Json::Str(uuid.hyphenated()))]),
        Err(e) => err(e),
    }
}

fn op_dispatch(
    reg: &mut StoreRegistry,
    uuid: StoreUuid,
    op: &str,
    method: &str,
    body: &[u8],
) -> (u16, String) {
    match (method, op) {
        ("POST", "query") => {
            if let Some(e) = too_big(reg, "query", body) {
                return e;
            }
            query(reg, uuid, body)
        }
        ("POST", "exec") => {
            if let Some(e) = too_big(reg, "exec", body) {
                return e;
            }
            exec(reg, uuid, body)
        }
        ("POST", "begin") => map_res(reg.begin(uuid)),
        ("POST", "commit") => map_res(reg.commit(uuid)),
        ("POST", "rollback") => map_res(reg.rollback(uuid)),
        ("POST", "close") => match reg.close(uuid) {
            Ok(()) => ok_obj(&[("uuid", Json::Str(uuid.hyphenated()))]),
            Err(e) => err(e),
        },
        ("POST", "open") => open(reg, uuid, body),
        ("POST", "export") => export(reg, uuid, body),
        ("GET", "stat") => match reg.stat(uuid) {
            Ok(j) => (200, stringify_json(&j)),
            Err(e) => err(e),
        },
        ("GET", "notifies") => match reg.notifies(uuid) {
            Ok(j) => (200, stringify_json(&j)),
            Err(e) => err(e),
        },
        ("POST", "listen") => {
            let json = match body_json(body) {
                Ok(j) => j,
                Err(e) => return err(e),
            };
            let ch = json.get("channel").as_str().unwrap_or("");
            map_res(reg.listen(uuid, ch))
        }
        ("POST", "unlisten") => {
            let json = match body_json(body) {
                Ok(j) => j,
                Err(e) => return err(e),
            };
            map_res(reg.unlisten(uuid, json.get("channel").as_str()))
        }
        ("GET", "dump") => match reg.dump(uuid) {
            Ok(j) => (200, stringify_json(&j)),
            Err(e) => err(e),
        },
        ("PUT", "load") => {
            if let Some(e) = too_big(reg, "load", body) {
                return e;
            }
            load(reg, uuid, body)
        }
        _ => not_found(),
    }
}

fn map_res(r: Result<crate::QueryResult, StoreError>) -> (u16, String) {
    match r {
        Ok(out) => (200, stringify_json(&out.to_json())),
        Err(e) => err(e),
    }
}

fn query(reg: &mut StoreRegistry, uuid: StoreUuid, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let sql = json.get("sql").as_str().unwrap_or("");
    let params = match params_from_json(json.get("params")) {
        Ok(p) => p,
        Err(e) => return err(e),
    };
    map_res(reg.query(uuid, sql, &params))
}

fn exec(reg: &mut StoreRegistry, uuid: StoreUuid, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let sql = json.get("sql").as_str().unwrap_or("");
    match reg.exec(uuid, sql) {
        Ok(out) => {
            let mut m = BTreeMap::new();
            m.insert("ok".into(), Json::Bool(true));
            m.insert("results".into(), Json::Arr(vec![out.to_json()]));
            (200, stringify_json(&Json::Obj(m)))
        }
        Err(e) => err(e),
    }
}

fn open_dir(reg: &mut StoreRegistry, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let data_dir = json.get("dataDir").as_str().unwrap_or("registry");
    match reg.open(data_dir) {
        Ok(u) => match reg.stat(u) {
            Ok(s) => ok_obj(&[
                ("uuid", Json::Str(u.hyphenated())),
                (
                    "ready",
                    Json::Bool(s.get("ready").as_bool().unwrap_or(true)),
                ),
                ("live", Json::Bool(s.get("live").as_bool().unwrap_or(false))),
            ]),
            Err(_) => ok_obj(&[
                ("uuid", Json::Str(u.hyphenated())),
                ("ready", Json::Bool(true)),
            ]),
        },
        Err(e) => err(e),
    }
}

fn open(reg: &mut StoreRegistry, uuid: StoreUuid, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let data_dir = json.get("dataDir").as_str();
    let opened = if let Some(d) = data_dir {
        reg.open(d)
    } else {
        reg.open_uuid(uuid)
    };
    match opened {
        Ok(u) => ok_obj(&[
            ("uuid", Json::Str(u.hyphenated())),
            ("ready", Json::Bool(true)),
        ]),
        Err(e) => err(e),
    }
}

fn export(reg: &mut StoreRegistry, uuid: StoreUuid, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    let volume = json.get("volume").as_str().unwrap_or("");
    let rel = json.get("rel").as_str();
    match reg.export(uuid, volume, rel) {
        Ok(()) => ok_obj(&[("uuid", Json::Str(uuid.hyphenated()))]),
        Err(e) => err(e),
    }
}

fn load(reg: &mut StoreRegistry, uuid: StoreUuid, body: &[u8]) -> (u16, String) {
    let json = match body_json(body) {
        Ok(j) => j,
        Err(e) => return err(e),
    };
    match reg.load(uuid, &json) {
        Ok(()) => ok_obj(&[("uuid", Json::Str(uuid.hyphenated()))]),
        Err(e) => err(e),
    }
}
