// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use crate::codec;
use crate::engine::Engine;
use crate::error::StoreError;
use crate::names::{DataDir, Purpose, StoreUuid};
use crate::persist::{self, PersistMode};
use crate::results::QueryResult;
use crate::sql::{parse_exec, parse_query, Stmt};
use g6b_spec::{parse_json, store_purpose_ok, stringify_json, BoardSpec, Json, StoreCfg};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct Store {
    pub uuid: StoreUuid,
    pub purpose: Purpose,
    pub label: Option<String>,
    pub persist: PersistMode,
    pub usb_volume: Option<String>,
    pub usb_rel: Option<String>,
    pub engine: Engine,
    pub handles: u32,
}

#[derive(Debug, Clone)]
pub struct StoreRegistry {
    spec: StoreCfg,
    instances: BTreeMap<StoreUuid, Store>,
    current: BTreeMap<Purpose, StoreUuid>,
    seq: u64,
    usb: BTreeMap<(String, String), Vec<u8>>,
    listening: BTreeMap<(StoreUuid, String), Vec<Json>>,
}

impl StoreRegistry {
    pub fn new(cfg: StoreCfg) -> Self {
        Self {
            spec: cfg,
            instances: BTreeMap::new(),
            current: BTreeMap::new(),
            seq: 0,
            usb: BTreeMap::new(),
            listening: BTreeMap::new(),
        }
    }

    pub fn from_spec(spec: &BoardSpec) -> Self {
        Self::new(spec.kernel.store.clone())
    }

    pub fn cfg(&self) -> &StoreCfg {
        &self.spec
    }

    fn enabled(&self) -> Result<(), StoreError> {
        if self.spec.enable {
            Ok(())
        } else {
            Err(StoreError::Disabled)
        }
    }

    fn mint_uuid(&mut self) -> StoreUuid {
        self.seq = self.seq.saturating_add(1);
        let mut b = [0u8; 16];
        b[0..8].copy_from_slice(&self.seq.to_be_bytes());
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        StoreUuid(b)
    }

    pub fn create(&mut self, purpose: &str) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        let purpose = Purpose::parse(purpose)?;
        if !self.spec.purposes.iter().any(|p| p == purpose.as_str()) {
            return Err(StoreError::CapDenied);
        }
        if self.instances.len() as u32 >= self.spec.max_stores {
            return Err(StoreError::Budget("instances"));
        }
        let n = self
            .instances
            .values()
            .filter(|s| s.purpose == purpose)
            .count() as u32;
        if n >= self.spec.max_per_purpose {
            return Err(StoreError::Budget("per_purpose"));
        }
        let uuid = self.mint_uuid();
        self.instances.insert(
            uuid,
            Store {
                uuid,
                purpose: purpose.clone(),
                label: None,
                persist: PersistMode::Memory,
                usb_volume: None,
                usb_rel: None,
                engine: Engine::new(self.spec.clone()),
                handles: 1,
            },
        );
        self.current.entry(purpose.clone()).or_insert(uuid);
        if !self.spec.usb_volume.is_empty() {
            let _ = self.attach_usb(uuid, &self.spec.usb_volume.clone(), None);
        }
        Ok(uuid)
    }

    pub fn open_purpose(&mut self, purpose: &str) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        let purpose = Purpose::parse(purpose)?;
        if let Some(u) = self
            .current
            .get(&purpose)
            .copied()
            .filter(|u| self.instances.contains_key(u))
        {
            if let Some(s) = self.instances.get_mut(&u) {
                s.handles = s.handles.saturating_add(1);
            }
            let vol = self.spec.usb_volume.clone();
            if !vol.is_empty() {
                let _ = self.attach_usb(u, &vol, None);
            }
            return Ok(u);
        }
        self.create(purpose.as_str())
    }

    pub fn open_uuid(&mut self, uuid: StoreUuid) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        let s = self
            .instances
            .get_mut(&uuid)
            .ok_or(StoreError::UnknownStore)?;
        s.handles = s.handles.saturating_add(1);
        Ok(uuid)
    }

    pub fn open(&mut self, data_dir: &str) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        match DataDir::parse(data_dir)? {
            DataDir::Purpose(p) => self.open_purpose(p.as_str()),
            DataDir::Uuid(u) => self.open_uuid(u),
            DataDir::Elf(p) => self.open_elf(p.as_str()),
            DataDir::Usb { volume, rel } => self.open_usb(&volume, &rel),
        }
    }

    /// Hydrate a Memory instance from a first-party dump JSON (`elf://` seed).
    pub fn hydrate_elf(&mut self, blob: &Json) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        if !self.spec.persist_elf {
            return Err(persist::refuse_unarmed("elf"));
        }
        self.insert_dump(blob)
    }

    fn insert_dump(&mut self, blob: &Json) -> Result<StoreUuid, StoreError> {
        let encoded = stringify_json(blob);
        if encoded.len() as u32 > self.spec.max_result_bytes {
            return Err(StoreError::Budget("result"));
        }
        let dump = persist::load_dump(blob)?;
        if !self
            .spec
            .purposes
            .iter()
            .any(|p| p == dump.purpose.as_str())
        {
            return Err(StoreError::CapDenied);
        }
        if let Some(s) = self.instances.get_mut(&dump.uuid) {
            s.handles = s.handles.saturating_add(1);
            return Ok(dump.uuid);
        }
        if self.instances.len() as u32 >= self.spec.max_stores {
            return Err(StoreError::Budget("instances"));
        }
        let n = self
            .instances
            .values()
            .filter(|s| s.purpose == dump.purpose)
            .count() as u32;
        if n >= self.spec.max_per_purpose {
            return Err(StoreError::Budget("per_purpose"));
        }
        let mut engine = Engine::new(self.spec.clone());
        engine.tables = dump.tables;
        let uuid = dump.uuid;
        let purpose = dump.purpose.clone();
        self.instances.insert(
            uuid,
            Store {
                uuid,
                purpose: purpose.clone(),
                label: dump.label,
                persist: PersistMode::Memory,
                usb_volume: None,
                usb_rel: None,
                engine,
                handles: 1,
            },
        );
        self.current.entry(purpose).or_insert(uuid);
        Ok(uuid)
    }

    fn open_elf(&mut self, purpose: &str) -> Result<StoreUuid, StoreError> {
        if !self.spec.persist_elf {
            return Err(persist::refuse_unarmed("elf"));
        }
        let purpose = Purpose::parse(purpose)?;
        let path = persist::dump_path();
        let blob = match persist::read_dump_file(&path) {
            Ok(j) => j,
            Err(_) => return Err(persist::refuse_unarmed("elf")),
        };
        let dump = persist::load_dump(&blob)?;
        if dump.purpose != purpose {
            return Err(StoreError::exec("purpose mismatch"));
        }
        self.hydrate_elf(&blob)
    }

    pub fn close(&mut self, uuid: StoreUuid) -> Result<(), StoreError> {
        self.enabled()?;
        let s = self
            .instances
            .get_mut(&uuid)
            .ok_or(StoreError::UnknownStore)?;
        if s.handles > 0 {
            s.handles -= 1;
        }
        Ok(())
    }

    pub fn drop(&mut self, uuid: StoreUuid) -> Result<(), StoreError> {
        self.enabled()?;
        let s = self
            .instances
            .remove(&uuid)
            .ok_or(StoreError::UnknownStore)?;
        if self.current.get(&s.purpose) == Some(&uuid) {
            self.current.remove(&s.purpose);
        }
        Ok(())
    }

    fn store_mut(&mut self, uuid: StoreUuid) -> Result<&mut Store, StoreError> {
        self.enabled()?;
        self.instances
            .get_mut(&uuid)
            .ok_or(StoreError::UnknownStore)
    }

    fn bind_params(&self, params: &[Json]) -> Result<(), StoreError> {
        let bytes: usize = params.iter().map(|p| stringify_json(p).len()).sum();
        if bytes as u32 > self.spec.max_param_bytes {
            return Err(StoreError::Budget("params"));
        }
        if params.len() as u32 > self.spec.max_columns {
            return Err(StoreError::Budget("params"));
        }
        Ok(())
    }

    fn finish(&self, out: QueryResult) -> Result<QueryResult, StoreError> {
        if out.encoded_len() as u32 > self.spec.max_result_bytes {
            return Err(StoreError::Budget("result"));
        }
        Ok(out)
    }

    pub fn query(
        &mut self,
        uuid: StoreUuid,
        sql: &str,
        params: &[Json],
    ) -> Result<QueryResult, StoreError> {
        self.enabled()?;
        if sql.len() as u32 > self.spec.max_sql_bytes {
            return Err(StoreError::Budget("sql"));
        }
        self.bind_params(params)?;
        let stmt = parse_query(sql)?;
        let out = match &stmt {
            Stmt::Listen { channel } => self.listen(uuid, channel)?,
            Stmt::Unlisten { channel } => self.unlisten(uuid, channel.as_deref())?,
            Stmt::Notify { channel, payload } => self.notify(
                uuid,
                channel,
                payload.as_ref().map(|s| Json::Str(s.clone())),
            )?,
            Stmt::Stat => self.stat_result(uuid)?,
            other => self.store_mut(uuid)?.engine.exec_stmt(other, params)?,
        };
        if stmt_writes(&stmt) {
            self.flush_usb(uuid)?;
        }
        self.finish(out)
    }

    pub fn exec(&mut self, uuid: StoreUuid, sql: &str) -> Result<QueryResult, StoreError> {
        self.enabled()?;
        if sql.len() as u32 > self.spec.max_sql_bytes {
            return Err(StoreError::Budget("sql"));
        }
        let stmts = parse_exec(sql)?;
        let snap = self.store_mut(uuid)?.engine.tables.clone();
        let in_tx = self.store_mut(uuid)?.engine.tx.is_some();
        let mut last = QueryResult::empty();
        for stmt in &stmts {
            let r = match stmt {
                Stmt::Listen { channel } => self.listen(uuid, channel),
                Stmt::Unlisten { channel } => self.unlisten(uuid, channel.as_deref()),
                Stmt::Notify { channel, payload } => self.notify(
                    uuid,
                    channel,
                    payload.as_ref().map(|s| Json::Str(s.clone())),
                ),
                Stmt::Stat => self.stat_result(uuid),
                other => self.store_mut(uuid)?.engine.exec_stmt(other, &[]),
            };
            match r {
                Ok(v) => last = v,
                Err(e) => {
                    let store = self.store_mut(uuid)?;
                    store.engine.tables = snap;
                    if !in_tx {
                        store.engine.tx = None;
                    }
                    return Err(e);
                }
            }
        }
        let out = self.finish(last)?;
        if !in_tx && stmts.iter().any(stmt_writes) {
            self.flush_usb(uuid)?;
        }
        Ok(out)
    }

    pub fn begin(&mut self, uuid: StoreUuid) -> Result<QueryResult, StoreError> {
        self.query(uuid, "BEGIN", &[])
    }

    pub fn commit(&mut self, uuid: StoreUuid) -> Result<QueryResult, StoreError> {
        self.query(uuid, "COMMIT", &[])
    }

    pub fn rollback(&mut self, uuid: StoreUuid) -> Result<QueryResult, StoreError> {
        self.query(uuid, "ROLLBACK", &[])
    }

    pub fn dump(&mut self, uuid: StoreUuid) -> Result<Json, StoreError> {
        let s = self.store_mut(uuid)?;
        Ok(persist::dump_json(
            s.uuid,
            &s.purpose,
            s.label.as_deref(),
            &s.engine.tables,
        ))
    }

    pub fn load(&mut self, uuid: StoreUuid, blob: &Json) -> Result<(), StoreError> {
        let dump = persist::load_dump(blob)?;
        let _dump_uuid = dump.uuid;
        {
            let s = self.store_mut(uuid)?;
            if s.purpose != dump.purpose {
                return Err(StoreError::exec("purpose mismatch"));
            }
            if !s.engine.tables.is_empty() {
                return Err(StoreError::exec("replace"));
            }
            s.label = dump.label;
            s.engine.tables = dump.tables;
        }
        self.flush_usb(uuid)?;
        Ok(())
    }

    pub fn export(
        &mut self,
        uuid: StoreUuid,
        volume: &str,
        rel: Option<&str>,
    ) -> Result<(), StoreError> {
        self.enabled()?;
        if !self.spec.persist_usb {
            return Err(persist::refuse_unarmed("usb"));
        }
        let volume = normalize_volume(volume)?;
        let (rel, json) = {
            let s = self.store_mut(uuid)?;
            let rel = rel
                .map(str::to_string)
                .filter(|r| !r.is_empty())
                .unwrap_or_else(|| default_usb_rel(&s.purpose, s.uuid));
            let json = persist::dump_json(s.uuid, &s.purpose, s.label.as_deref(), &s.engine.tables);
            (rel, json)
        };
        let raw = stringify_json(&json);
        if raw.len() as u32 > self.spec.max_result_bytes {
            return Err(StoreError::Budget("result"));
        }
        let packed = codec::pack(raw.as_bytes());
        if let Some(prev) = self.usb.get(&(volume.clone(), rel.clone())) {
            if let Ok(old) = codec::unpack(prev) {
                if let Ok(j) = parse_json(std::str::from_utf8(&old).unwrap_or("")) {
                    if let Ok(d) = persist::load_dump(&j) {
                        if d.uuid != uuid {
                            return Err(StoreError::exec("uuid live"));
                        }
                    }
                }
            }
        }
        self.usb.insert((volume, rel), packed);
        Ok(())
    }

    pub fn import(&mut self, volume: &str, rel: &str) -> Result<StoreUuid, StoreError> {
        self.import_at(volume, rel, false)
    }

    pub fn import_at(
        &mut self,
        volume: &str,
        rel: &str,
        replace: bool,
    ) -> Result<StoreUuid, StoreError> {
        self.enabled()?;
        if !self.spec.persist_usb {
            return Err(persist::refuse_unarmed("usb"));
        }
        let volume = normalize_volume(volume)?;
        let blob = self
            .usb
            .get(&(volume, rel.to_string()))
            .ok_or_else(|| persist::refuse_unarmed("usb"))?
            .clone();
        let raw = codec::unpack(&blob)?;
        let json = parse_json(std::str::from_utf8(&raw).map_err(|_| StoreError::exec("utf8"))?)
            .map_err(StoreError::syntax)?;
        let dump = persist::load_dump(&json)?;
        if self.instances.contains_key(&dump.uuid) {
            if !replace {
                return Err(StoreError::exec("uuid live"));
            }
            self.drop(dump.uuid)?;
        }
        self.insert_dump(&json)
    }

    fn open_usb(&mut self, volume: &str, rel: &str) -> Result<StoreUuid, StoreError> {
        if !self.spec.persist_usb {
            return Err(persist::refuse_unarmed("usb"));
        }
        let volume = normalize_volume(volume)?;
        if rel.is_empty() || store_purpose_ok(rel) {
            let purpose = if rel.is_empty() { "registry" } else { rel };
            let uuid = self.open_purpose(purpose)?;
            self.attach_usb(uuid, &volume, None)?;
            return Ok(uuid);
        }
        if let Ok(uuid) = StoreUuid::parse(rel) {
            self.open_uuid(uuid)?;
            self.attach_usb(uuid, &volume, None)?;
            return Ok(uuid);
        }
        self.import_at(&volume, rel, false)
    }

    pub fn attach_usb(
        &mut self,
        uuid: StoreUuid,
        volume: &str,
        rel: Option<&str>,
    ) -> Result<(), StoreError> {
        self.enabled()?;
        if !self.spec.persist_usb {
            return Err(persist::refuse_unarmed("usb"));
        }
        let volume = normalize_volume(volume)?;
        let rel = {
            let s = self.store_mut(uuid)?;
            rel.map(str::to_string)
                .filter(|r| !r.is_empty())
                .unwrap_or_else(|| default_usb_rel(&s.purpose, s.uuid))
        };
        if let Some(blob) = self.usb.get(&(volume.clone(), rel.clone())).cloned() {
            if let Ok(raw) = codec::unpack(&blob) {
                if let Ok(json) = parse_json(std::str::from_utf8(&raw).unwrap_or("")) {
                    let dump = persist::load_dump(&json)?;
                    if dump.uuid == uuid {
                        let s = self.store_mut(uuid)?;
                        s.engine.tables = dump.tables;
                        s.label = dump.label;
                    }
                }
            }
        }
        {
            let s = self.store_mut(uuid)?;
            s.persist = PersistMode::UsbLive;
            s.usb_volume = Some(volume);
            s.usb_rel = Some(rel);
        }
        self.flush_usb(uuid)
    }

    fn flush_usb(&mut self, uuid: StoreUuid) -> Result<(), StoreError> {
        let (volume, rel, json) = {
            let s = match self.instances.get(&uuid) {
                Some(s) => s,
                None => return Ok(()),
            };
            if s.persist != PersistMode::UsbLive || s.engine.tx.is_some() {
                return Ok(());
            }
            let volume = s
                .usb_volume
                .clone()
                .ok_or_else(|| persist::refuse_unarmed("usb"))?;
            let rel = s
                .usb_rel
                .clone()
                .unwrap_or_else(|| default_usb_rel(&s.purpose, s.uuid));
            (
                volume,
                rel,
                persist::dump_json(s.uuid, &s.purpose, s.label.as_deref(), &s.engine.tables),
            )
        };
        let raw = stringify_json(&json);
        if raw.len() as u32 > self.spec.max_result_bytes {
            return Err(StoreError::Budget("result"));
        }
        self.usb.insert((volume, rel), codec::pack(raw.as_bytes()));
        Ok(())
    }

    pub fn stat(&self, uuid: StoreUuid) -> Result<Json, StoreError> {
        self.enabled()?;
        let s = self.instances.get(&uuid).ok_or(StoreError::UnknownStore)?;
        let mut m = BTreeMap::new();
        m.insert("ok".into(), Json::Bool(true));
        m.insert("uuid".into(), Json::Str(uuid.hyphenated()));
        m.insert("purpose".into(), Json::Str(s.purpose.as_str().into()));
        m.insert("persist".into(), Json::Str(s.persist.as_str().into()));
        let live = s.persist == PersistMode::UsbLive;
        m.insert("live".into(), Json::Bool(live));
        let volume = s.usb_volume.clone().unwrap_or_default();
        let rel = s.usb_rel.clone().unwrap_or_default();
        if !volume.is_empty() {
            m.insert("volume".into(), Json::Str(volume.clone()));
        }
        if !rel.is_empty() {
            m.insert("path".into(), Json::Str(rel.clone()));
        }
        let bytes = self
            .usb
            .get(&(volume.clone(), rel.clone()))
            .map(|b| b.len() as i64)
            .unwrap_or(0);
        m.insert("bytes".into(), Json::Int(bytes));
        if bytes > 0 {
            m.insert("format".into(), Json::Str("g6bs".into()));
        }
        // Memory is always usable. UsbLive is ready once persist.usb is armed
        // (canned key volume is present). A dialog that *requires* USB polls
        // until `live && ready`.
        let ready = match s.persist {
            PersistMode::UsbLive => self.spec.persist_usb,
            PersistMode::ElfSeed => self.spec.persist_elf,
            PersistMode::Memory => true,
        };
        m.insert("ready".into(), Json::Bool(ready));
        Ok(Json::Obj(m))
    }

    fn stat_result(&self, uuid: StoreUuid) -> Result<QueryResult, StoreError> {
        let j = self.stat(uuid)?;
        let Json::Obj(m) = &j else {
            return Ok(QueryResult::empty());
        };
        Ok(QueryResult {
            rows: vec![m.clone()],
            fields: m
                .keys()
                .map(|k| crate::results::Field {
                    name: k.clone(),
                    data_type_id: 25,
                })
                .collect(),
            affected_rows: 0,
        })
    }

    pub fn listen(&mut self, uuid: StoreUuid, channel: &str) -> Result<QueryResult, StoreError> {
        self.store_mut(uuid)?;
        self.listening
            .entry((uuid, channel.to_string()))
            .or_default();
        let mut row = BTreeMap::new();
        row.insert("ok".into(), Json::Bool(true));
        row.insert("listening".into(), Json::Str(channel.into()));
        row.insert("ready".into(), Json::Bool(true));
        Ok(QueryResult {
            rows: vec![row],
            fields: vec![],
            affected_rows: 0,
        })
    }

    pub fn unlisten(
        &mut self,
        uuid: StoreUuid,
        channel: Option<&str>,
    ) -> Result<QueryResult, StoreError> {
        self.store_mut(uuid)?;
        match channel {
            None | Some("*") => {
                self.listening.retain(|(u, _), _| *u != uuid);
            }
            Some(ch) => {
                self.listening.remove(&(uuid, ch.to_string()));
            }
        }
        Ok(QueryResult::empty())
    }

    pub fn notify(
        &mut self,
        uuid: StoreUuid,
        channel: &str,
        payload: Option<Json>,
    ) -> Result<QueryResult, StoreError> {
        self.store_mut(uuid)?;
        if let Some(q) = self.listening.get_mut(&(uuid, channel.to_string())) {
            if q.len() >= 64 {
                return Err(StoreError::Budget("notify"));
            }
            q.push(payload.unwrap_or(Json::Null));
        }
        Ok(QueryResult::empty())
    }

    pub fn notifies(&mut self, uuid: StoreUuid) -> Result<Json, StoreError> {
        self.store_mut(uuid)?;
        let mut all = Vec::new();
        for ((u, ch), q) in self.listening.iter_mut() {
            if *u != uuid {
                continue;
            }
            for p in q.drain(..) {
                let mut o = BTreeMap::new();
                o.insert("channel".into(), Json::Str(ch.clone()));
                o.insert("payload".into(), p);
                all.push(Json::Obj(o));
            }
        }
        let mut m = BTreeMap::new();
        m.insert("ok".into(), Json::Bool(true));
        m.insert("notifies".into(), Json::Arr(all));
        Ok(Json::Obj(m))
    }

    pub fn usb_list(&self, volume: &str) -> Vec<(String, usize)> {
        let Ok(v) = normalize_volume(volume) else {
            return Vec::new();
        };
        self.usb
            .iter()
            .filter(|((vol, _), _)| *vol == v)
            .map(|((_, rel), b)| (rel.clone(), b.len()))
            .collect()
    }

    pub fn list(&self) -> Vec<(StoreUuid, Purpose, PersistMode, u64)> {
        self.instances
            .values()
            .map(|s| (s.uuid, s.purpose.clone(), s.persist, s.engine.row_count()))
            .collect()
    }

    pub fn current(&self, purpose: &str) -> Option<StoreUuid> {
        let p = Purpose::parse(purpose).ok()?;
        self.current.get(&p).copied()
    }

    pub fn select(&mut self, purpose: &str, uuid: StoreUuid) -> Result<(), StoreError> {
        self.enabled()?;
        let purpose = Purpose::parse(purpose)?;
        let s = self.instances.get(&uuid).ok_or(StoreError::UnknownStore)?;
        if s.purpose != purpose {
            return Err(StoreError::CapDenied);
        }
        self.current.insert(purpose, uuid);
        Ok(())
    }

    /// Resolve a path id that is either a UUID or a purpose name.
    pub fn resolve(&mut self, id: &str) -> Result<StoreUuid, StoreError> {
        if id.contains("://") {
            return self.open(id);
        }
        if let Ok(u) = StoreUuid::parse(id) {
            self.open_uuid(u)?;
            return Ok(u);
        }
        self.open_purpose(id)
    }
}

fn stmt_writes(stmt: &Stmt) -> bool {
    !matches!(
        stmt,
        Stmt::Select { .. }
            | Stmt::Begin
            | Stmt::Rollback
            | Stmt::Listen { .. }
            | Stmt::Unlisten { .. }
            | Stmt::Notify { .. }
            | Stmt::Stat
    )
}

fn default_usb_rel(purpose: &Purpose, uuid: StoreUuid) -> String {
    format!("stores/{}/{}.g6bstore", purpose.as_str(), uuid.hyphenated())
}

fn normalize_volume(v: &str) -> Result<String, StoreError> {
    let l = v.trim().to_ascii_lowercase();
    if l == "flash" {
        return Err(StoreError::CapDenied);
    }
    Ok(match l.as_str() {
        "fat32" | "fat" | "vfat" | "key-fat" => "fat32".into(),
        "ntfs" | "key-ntfs" => "ntfs".into(),
        "ext4" | "ext3" | "ext2" | "key-ext4" => "ext4".into(),
        _ => return Err(StoreError::syntax("usb volume")),
    })
}
