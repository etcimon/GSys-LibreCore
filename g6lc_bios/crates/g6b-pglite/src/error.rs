// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use g6b_spec::Json;
use std::collections::BTreeMap;
use std::fmt;

/// Fail-closed store error. JSON shape matches the PGlite-facing envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    Disabled,
    UnknownStore,
    Closed,
    Budget(&'static str),
    Syntax(String),
    Exec(String),
    PersistUnarmed(&'static str),
    CapDenied,
    NotImplemented(&'static str),
}

impl StoreError {
    pub fn syntax(msg: impl Into<String>) -> Self {
        Self::Syntax(msg.into())
    }

    pub fn exec(msg: impl Into<String>) -> Self {
        Self::Exec(msg.into())
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::UnknownStore => "unknown_store",
            Self::Closed => "closed",
            Self::Budget(_) => "budget",
            Self::Syntax(_) => "syntax",
            Self::Exec(_) => "exec",
            Self::PersistUnarmed(_) => "persist_unarmed",
            Self::CapDenied => "cap_denied",
            Self::NotImplemented(_) => "not_implemented",
        }
    }

    pub fn sqlstate(&self) -> Option<&'static str> {
        match self {
            Self::Syntax(_) => Some("42601"),
            Self::Budget(_) => Some("54000"),
            Self::CapDenied => Some("42501"),
            _ => None,
        }
    }

    pub fn http_status(&self) -> u16 {
        match self {
            Self::Disabled | Self::UnknownStore => 404,
            Self::CapDenied => 403,
            Self::Budget(_) => 413,
            Self::Syntax(_) | Self::Exec(_) => 400,
            Self::PersistUnarmed(_) | Self::Closed => 409,
            Self::NotImplemented(_) => 501,
        }
    }

    pub fn to_json(&self) -> Json {
        let mut m = BTreeMap::new();
        m.insert("ok".into(), Json::Bool(false));
        m.insert("error".into(), Json::Str(self.kind().into()));
        m.insert("message".into(), Json::Str(self.to_string()));
        if let Some(s) = self.sqlstate() {
            m.insert("sqlstate".into(), Json::Str(s.into()));
        }
        Json::Obj(m)
    }
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Disabled => write!(f, "store disabled"),
            Self::UnknownStore => write!(f, "unknown store"),
            Self::Closed => write!(f, "store closed"),
            Self::Budget(k) => write!(f, "budget:{k}"),
            Self::Syntax(s) => write!(f, "{s}"),
            Self::Exec(s) => write!(f, "{s}"),
            Self::PersistUnarmed(k) => write!(f, "persist unarmed:{k}"),
            Self::CapDenied => write!(f, "cap denied"),
            Self::NotImplemented(k) => write!(f, "NotImplemented(\"{k}\")"),
        }
    }
}

impl std::error::Error for StoreError {}
