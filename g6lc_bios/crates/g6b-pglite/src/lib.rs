// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party BIOS registry. PostgreSQL-*shaped* subset, not Electric wasm.
//!
//! BoardSpec `kernel.store` (default enable) is the compile gate. Guest
//! `start_ops` never instantiates this crate.

#![allow(missing_docs)]

mod catalog;
mod codec;
mod engine;
mod error;
mod http;
mod names;
mod persist;
mod results;
mod sql;

pub use catalog::{Store, StoreRegistry};
pub use error::StoreError;
pub use http::StorePort;
pub use names::{DataDir, Purpose, StoreUuid};
pub use persist::{
    dump_path, dump_path_explicit, read_host_dump_bytes, Dump, PersistMode, StoreVolume,
};
pub use results::{Field, QueryResult};
pub use sql::{parse_exec, parse_query, Stmt};

use g6b_spec::Json;

/// Bind-array helper: `Json::Arr` or empty.
pub fn params_from_json(v: &Json) -> Result<Vec<Json>, StoreError> {
    match v {
        Json::Null => Ok(Vec::new()),
        Json::Arr(a) => Ok(a.clone()),
        _ => Err(StoreError::exec("bind")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_spec::{parse_json, BoardSpec, Json};

    fn armed() -> StoreRegistry {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"kernel":{"store":{"enable":true}}}"#)
                .unwrap();
        StoreRegistry::from_spec(&spec)
    }

    #[test]
    fn default_board_spec_enables_store() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        assert!(spec.kernel.store.enable);
        let mut r = StoreRegistry::from_spec(&spec);
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
            .unwrap();
        r.query(
            u,
            "INSERT INTO kv VALUES ($1, $2)",
            &[Json::Str("a".into()), Json::Str("b".into())],
        )
        .unwrap();
        let out = r
            .query(u, "SELECT * FROM kv WHERE k = $1", &[Json::Str("a".into())])
            .unwrap();
        assert_eq!(out.rows.len(), 1);
        assert_eq!(out.rows[0].get("v"), Some(&Json::Str("b".into())));
    }

    #[test]
    fn disabled_is_store_error() {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"kernel":{"store":{"enable":false}}}"#)
                .unwrap();
        let mut r = StoreRegistry::from_spec(&spec);
        assert!(matches!(
            r.open_purpose("registry"),
            Err(StoreError::Disabled)
        ));
    }

    #[test]
    fn dml_update_delete_and_aggregates() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(
            u,
            "CREATE TABLE t (id SERIAL PRIMARY KEY, n INTEGER); INSERT INTO t (n) VALUES (1); INSERT INTO t (n) VALUES (2); INSERT INTO t (n) VALUES (3)",
        )
        .unwrap();
        r.exec(u, "UPDATE t SET n = n WHERE id = 2").unwrap();
        r.query(
            u,
            "UPDATE t SET n = $1 WHERE id = $2",
            &[Json::Int(20), Json::Int(2)],
        )
        .unwrap();
        r.exec(u, "DELETE FROM t WHERE n = 1").unwrap();
        let c = r.query(u, "SELECT COUNT(*) FROM t", &[]).unwrap();
        assert_eq!(c.rows[0].get("count"), Some(&Json::Int(2)));
        let s = r.query(u, "SELECT SUM(n) FROM t", &[]).unwrap();
        assert_eq!(s.rows[0].get("sum"), Some(&Json::Int(23)));
        let star = r.query(u, "SELECT * FROM t ORDER BY id ASC", &[]).unwrap();
        assert_eq!(star.rows.len(), 2);
    }

    #[test]
    fn tx_commit_and_rollback() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            .unwrap();
        r.exec(u, "BEGIN; INSERT INTO t VALUES (1); COMMIT")
            .unwrap();
        r.exec(u, "BEGIN; INSERT INTO t VALUES (2); ROLLBACK")
            .unwrap();
        let out = r.query(u, "SELECT COUNT(*) FROM t", &[]).unwrap();
        assert_eq!(out.rows[0].get("count"), Some(&Json::Int(1)));
        let err = r.exec(u, "BEGIN; INSERT INTO t VALUES (1)").unwrap_err();
        assert!(matches!(err, StoreError::Exec(_)));
        let out = r.query(u, "SELECT COUNT(*) FROM t", &[]).unwrap();
        assert_eq!(out.rows[0].get("count"), Some(&Json::Int(1)));
    }

    #[test]
    fn syntax_fail_closed() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE t (id INTEGER PRIMARY KEY, x INTEGER)")
            .unwrap();
        assert!(matches!(
            r.query(u, "INSERT INTO t VALUES (other_col)", &[]),
            Err(StoreError::Syntax(_))
        ));
        assert!(matches!(
            r.query(u, "SELECT COUNT(x), y FROM t", &[]),
            Err(StoreError::Syntax(_))
        ));
        assert!(matches!(
            r.query(u, "SELECT * FROM t JOIN t", &[]),
            Err(StoreError::Syntax(_))
        ));
        assert!(matches!(
            r.query(u, "SELECT * FROM t WHERE id = ?", &[]),
            Err(StoreError::Syntax(_))
        ));
        assert!(matches!(
            r.query(u, "UPDATE t SET x = x + 1", &[]),
            Err(StoreError::Syntax(_))
        ));
        assert!(matches!(
            r.exec(u, "BEGIN; BEGIN"),
            Err(StoreError::Budget("tx"))
        ));
    }

    #[test]
    fn drop_removes_close_does_not() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.close(u).unwrap();
        assert_eq!(r.list().len(), 1);
        r.drop(u).unwrap();
        assert!(r.list().is_empty());
        assert!(matches!(r.open_uuid(u), Err(StoreError::UnknownStore)));
    }

    #[test]
    fn persist_unarmed_and_dump_roundtrip() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE kv (k TEXT PRIMARY KEY)").unwrap();
        r.exec(u, "INSERT INTO kv VALUES ('a')").unwrap();
        assert!(matches!(
            r.open("elf://registry"),
            Err(StoreError::PersistUnarmed("elf"))
        ));
        assert!(matches!(
            r.export(u, "KEY-FAT", None),
            Err(StoreError::PersistUnarmed("usb"))
        ));
        assert!(matches!(
            r.export(u, "flash", None),
            Err(StoreError::PersistUnarmed("usb"))
        ));
        let dump = r.dump(u).unwrap();
        let u2 = r.create("registry").unwrap();
        r.load(u2, &dump).unwrap();
        let out = r.query(u2, "SELECT * FROM kv", &[]).unwrap();
        assert_eq!(out.rows.len(), 1);
    }

    #[test]
    fn elf_hydrate_seeds_a_deletable_memory_copy() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"persist":{"elf":true}}}}"#,
        )
        .unwrap();
        let mut r = StoreRegistry::from_spec(&spec);
        let blob = parse_json(include_str!("../../../fixtures/store-dump.json")).unwrap();
        let u = r.hydrate_elf(&blob).unwrap();
        let out = r
            .query(
                u,
                "SELECT * FROM kv WHERE k = $1",
                &[Json::Str("boot.next".into())],
            )
            .unwrap();
        assert_eq!(out.rows.len(), 1);
        assert_eq!(out.rows[0].get("v"), Some(&Json::Str("opensbi".into())));
        r.drop(u).unwrap();
        assert!(r.list().is_empty());
        let mut off = armed();
        assert!(matches!(
            off.hydrate_elf(&blob),
            Err(StoreError::PersistUnarmed("elf"))
        ));
        if persist::read_host_dump_bytes().is_none() {
            assert!(matches!(
                r.open("elf://registry"),
                Err(StoreError::PersistUnarmed("elf"))
            ));
        }
    }

    #[test]
    fn max_rows_budget() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"max_rows":2}}}"#,
        )
        .unwrap();
        let mut r = StoreRegistry::from_spec(&spec);
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
            .unwrap();
        r.exec(u, "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)")
            .unwrap();
        let err = r.exec(u, "INSERT INTO t VALUES (3)").unwrap_err();
        assert!(matches!(err, StoreError::Budget("rows")));
    }

    #[test]
    fn oversize_sql_is_budget() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"max_sql_bytes":8}}}"#,
        )
        .unwrap();
        let mut r = StoreRegistry::from_spec(&spec);
        let u = r.open_purpose("registry").unwrap();
        let err = r.query(u, "SELECT * FROM nowhere", &[]).unwrap_err();
        assert!(matches!(err, StoreError::Budget("sql")));
    }

    fn usb_armed() -> StoreRegistry {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"usb":{"key":true},"store":{"persist":{"usb":true}}}}"#,
        )
        .unwrap();
        StoreRegistry::from_spec(&spec)
    }

    #[test]
    fn usb_live_stat_is_pollable_for_a_dialog() {
        let mut r = usb_armed();
        let mem = r.open_purpose("registry").unwrap();
        let s = r.stat(mem).unwrap();
        assert_eq!(s.get("live").as_bool(), Some(false));
        assert_eq!(s.get("ready").as_bool(), Some(true));
        assert_eq!(s.get("persist").as_str(), Some("memory"));

        let u = r.open("usb://fat32").unwrap();
        let s = r.stat(u).unwrap();
        assert_eq!(s.get("ok").as_bool(), Some(true));
        assert_eq!(s.get("live").as_bool(), Some(true));
        assert_eq!(s.get("ready").as_bool(), Some(true));
        assert_eq!(s.get("persist").as_str(), Some("usb"));
        assert_eq!(s.get("volume").as_str(), Some("fat32"));
        assert!(s.get("path").as_str().unwrap().contains(".g6bstore"));

        r.exec(u, "CREATE TABLE kv (k TEXT PRIMARY KEY)").unwrap();
        r.exec(u, "INSERT INTO kv VALUES ('boot')").unwrap();
        let s = r.stat(u).unwrap();
        assert!(s.get("bytes").as_i64().unwrap() > 0);
        assert_eq!(s.get("format").as_str(), Some("g6bs"));

        let sql = r.query(u, "STAT", &[]).unwrap();
        assert_eq!(sql.rows[0].get("ready"), Some(&Json::Bool(true)));
        assert_eq!(sql.rows[0].get("live"), Some(&Json::Bool(true)));

        let (code, body) =
            StorePort::handle(&mut r, "GET", &format!("/bios/store/{u}/stat"), b"").unwrap();
        assert_eq!(code, 200, "{body}");
        assert!(body.contains("\"ready\":true"), "{body}");
        assert!(body.contains("\"live\":true"), "{body}");

        let (code, body) = StorePort::handle(
            &mut r,
            "POST",
            "/bios/store/open",
            br#"{"dataDir":"usb://ntfs"}"#,
        )
        .unwrap();
        assert_eq!(code, 200, "{body}");
        assert!(body.contains("\"live\":true"), "{body}");
    }

    #[test]
    fn open_names_the_store_in_the_data_dir_path() {
        let mut r = armed();
        let u = r.open("memory://registry").unwrap();
        let s = r.stat(u).unwrap();
        assert_eq!(s.get("purpose").as_str(), Some("registry"));
        assert_eq!(s.get("persist").as_str(), Some("memory"));
        let again = r.open(&format!("memory://{u}")).unwrap();
        assert_eq!(u, again);

        let mut r = usb_armed();
        let u = r.open("usb://fat32/registry").unwrap();
        let s = r.stat(u).unwrap();
        assert_eq!(s.get("purpose").as_str(), Some("registry"));
        assert_eq!(s.get("volume").as_str(), Some("fat32"));
        assert_eq!(s.get("live").as_bool(), Some(true));
        assert!(s.get("path").as_str().unwrap().contains("stores/registry/"));
        let again = r.open(&format!("usb://fat32/{u}")).unwrap();
        assert_eq!(u, again);

        let (code, body) = StorePort::handle(
            &mut r,
            "POST",
            "/bios/store/open",
            br#"{"dataDir":"usb://ntfs/registry"}"#,
        )
        .unwrap();
        assert_eq!(code, 200, "{body}");
        assert!(body.contains("\"live\":true"), "{body}");
    }

    #[test]
    fn inner_join_and_listen() {
        let mut r = armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(
            u,
            "CREATE TABLE a (id INTEGER PRIMARY KEY, n TEXT); CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER, m TEXT)",
        )
        .unwrap();
        r.exec(
            u,
            "INSERT INTO a VALUES (1, 'x'); INSERT INTO b VALUES (10, 1, 'y')",
        )
        .unwrap();
        let out = r
            .query(u, "SELECT * FROM a INNER JOIN b ON a.id = b.a_id", &[])
            .unwrap();
        assert_eq!(out.rows.len(), 1);
        assert_eq!(out.rows[0].get("n"), Some(&Json::Str("x".into())));
        assert_eq!(out.rows[0].get("m"), Some(&Json::Str("y".into())));
        r.exec(u, "LISTEN ticks").unwrap();
        r.exec(u, "NOTIFY ticks, 'go'").unwrap();
        let n = r.notifies(u).unwrap();
        let Json::Arr(items) = n.get("notifies") else {
            panic!("{n:?}");
        };
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].get("channel").as_str(), Some("ticks"));
    }

    #[test]
    fn g6bs_export_import_roundtrip() {
        let mut r = usb_armed();
        let u = r.open_purpose("registry").unwrap();
        r.exec(u, "CREATE TABLE kv (k TEXT PRIMARY KEY)").unwrap();
        r.exec(u, "INSERT INTO kv VALUES ('a')").unwrap();
        r.export(u, "fat32", None).unwrap();
        r.drop(u).unwrap();
        let rel = format!("stores/registry/{}.g6bstore", u);
        let u2 = r.import("fat32", &rel).unwrap();
        assert_eq!(u2, u);
        let out = r.query(u2, "SELECT * FROM kv", &[]).unwrap();
        assert_eq!(out.rows.len(), 1);
    }
}
