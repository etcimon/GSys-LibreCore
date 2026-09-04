// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party HTTP/1.1 + HTTP/2 for BIOS kernel endpoints.
//! Spec: libwasm fetch / Object_Call (not linked). Not SvelteKit.

#![allow(missing_docs)]

pub mod files;
pub mod h1;
pub mod h2;
pub mod router;

pub use files::StaticFile;
pub use router::{Route, Router};

/// Wire version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Version {
    Http11,
    Http2,
}

/// Parsed request (HolyC, JS fetch, WASM Object_Call).
#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub version: Version,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Kernel response.
#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    /// JSON body, `application/json`.
    pub fn json(status: u16, body: &str) -> Self {
        Self {
            status,
            headers: vec![("content-type".into(), "application/json".into())],
            body: body.as_bytes().to_vec(),
        }
    }

    /// Static file body with a content-type.
    pub fn file(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: vec![("content-type".into(), content_type.into())],
            body: body.into(),
        }
    }

    /// UTF-8 body.
    pub fn body_str(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// Detect HTTP/2 preface vs HTTP/1.1.
pub fn parse(raw: &[u8]) -> Result<Request, String> {
    if raw.starts_with(h2::PREFACE) || looks_h2_frame(raw) {
        h2::parse(raw)
    } else {
        h1::parse(raw)
    }
}

fn looks_h2_frame(raw: &[u8]) -> bool {
    raw.len() >= 9 && raw[3] <= 9 && raw[0] == 0 && raw[1] == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_spec::BoardSpec;

    #[test]
    fn roundtrip_h1_and_h2_clocks() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true,"http1":true,"http2":true},"params":{"clocks":true,"bootloader":true}}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        let h1 = b"GET /bios/clocks HTTP/1.1\r\n\r\n";
        let out = r.handle_bytes(h1).unwrap();
        let s = String::from_utf8_lossy(&out);
        assert!(s.contains("HTTP/1.1 200"), "{s}");
        assert!(s.contains("cpu_hz"), "{s}");
        let h2 = h2::client_get("/bios/bootloader");
        let out2 = r.handle_bytes(&h2).unwrap();
        assert!(out2.len() > 9);
        let got = parse(&h2).unwrap();
        assert_eq!(got.path, "/bios/bootloader");
    }
}
