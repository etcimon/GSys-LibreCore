// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use g6b_spec::{stringify_json, Json};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub name: String,
    pub data_type_id: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueryResult {
    pub rows: Vec<BTreeMap<String, Json>>,
    pub fields: Vec<Field>,
    pub affected_rows: u64,
}

impl QueryResult {
    pub fn empty() -> Self {
        Self {
            rows: Vec::new(),
            fields: Vec::new(),
            affected_rows: 0,
        }
    }

    pub fn to_json(&self) -> Json {
        let mut m = BTreeMap::new();
        m.insert("ok".into(), Json::Bool(true));
        m.insert(
            "rows".into(),
            Json::Arr(self.rows.iter().map(|r| Json::Obj(r.clone())).collect()),
        );
        m.insert(
            "fields".into(),
            Json::Arr(
                self.fields
                    .iter()
                    .map(|f| {
                        let mut o = BTreeMap::new();
                        o.insert("name".into(), Json::Str(f.name.clone()));
                        o.insert("dataTypeID".into(), Json::Int(f.data_type_id as i64));
                        Json::Obj(o)
                    })
                    .collect(),
            ),
        );
        m.insert("affectedRows".into(), Json::Int(self.affected_rows as i64));
        m.insert("ready".into(), Json::Bool(true));
        Json::Obj(m)
    }

    pub fn encoded_len(&self) -> usize {
        stringify_json(&self.to_json()).len()
    }
}
