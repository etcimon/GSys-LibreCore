// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party HTTP/1.1 + HTTP/2. When both are on, H2 is preferred
//! (ALPN `h2` then `http/1.1`; h2c Upgrade; PRI preface).
//! Spec: libwasm fetch / Object_Call (not linked). Not SvelteKit.

#![allow(missing_docs)]

pub mod files;
pub mod h1;
pub mod h2;
pub mod mgmt;
pub mod outbound;
pub mod rfb;
pub mod router;
pub mod ws;

pub use files::{live_features_json, load_pglite_dist, StaticFile, MAX_PGLITE_EMBED_BYTES};
pub use mgmt::{check_image_elf, version_newer, Capsule, Mgmt, RecoveryState};
pub use outbound::{ocsp_from_http, ocsp_http_post, ocsp_plan};
pub use rfb::{
    linux_enter_blocked, linux_enter_ready, offer_security as rfb_offer_security,
    select_security as rfb_select_security, KvmLease, RfbClient, RfbServer,
};
pub use router::{Route, Router};
pub use ws::{
    decode_frame as ws_decode_frame, encode_close as ws_encode_close,
    encode_frame as ws_encode_frame, encode_ping as ws_encode_ping, encode_pong as ws_encode_pong,
    WsInbox,
};

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

fn security_headers(content_type: &str) -> Vec<(String, String)> {
    vec![
        ("content-type".into(), content_type.into()),
        ("x-content-type-options".into(), "nosniff".into()),
        ("x-frame-options".into(), "DENY".into()),
        (
            "content-security-policy".into(),
            "default-src 'self'; frame-ancestors 'none'".into(),
        ),
        ("referrer-policy".into(), "no-referrer".into()),
        ("cache-control".into(), "no-store".into()),
        (
            "strict-transport-security".into(),
            "max-age=31536000; includeSubDomains".into(),
        ),
        ("cross-origin-opener-policy".into(), "same-origin".into()),
        ("cross-origin-resource-policy".into(), "same-origin".into()),
        ("cross-origin-embedder-policy".into(), "require-corp".into()),
        (
            "permissions-policy".into(),
            "camera=(), microphone=(), geolocation=()".into(),
        ),
        ("x-dns-prefetch-control".into(), "off".into()),
        ("x-permitted-cross-domain-policies".into(), "none".into()),
    ]
}

impl Response {
    /// JSON body, `application/json`.
    pub fn json(status: u16, body: &str) -> Self {
        Self {
            status,
            headers: security_headers("application/json"),
            body: body.as_bytes().to_vec(),
        }
    }

    /// Static file body with a content-type.
    pub fn file(status: u16, content_type: &str, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: security_headers(content_type),
            body: body.into(),
        }
    }

    /// UTF-8 body.
    pub fn body_str(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// Higher-level choice: H2 over H1 when both flags are on.
pub fn preferred_http(http2: bool, http1: bool) -> Option<&'static str> {
    if http2 {
        Some("h2")
    } else if http1 {
        Some("http/1.1")
    } else {
        None
    }
}

/// Detect HTTP/2 by PRI preface. Otherwise HTTP/1.1 (including h2c Upgrade).
pub fn parse(raw: &[u8]) -> Result<Request, String> {
    if raw.starts_with(h2::PREFACE) {
        h2::parse(raw)
    } else {
        h1::parse(raw)
    }
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
        let h1 = b"GET /bios/clocks HTTP/1.1\r\nHost: bios\r\n\r\n";
        let out = r.handle_bytes(h1).unwrap();
        let s = String::from_utf8_lossy(&out);
        assert!(s.contains("HTTP/1.1 200"), "{s}");
        assert!(s.contains("cpu_hz"), "{s}");
        let h2 = h2::client_get("/bios/bootloader");
        let out2 = r.handle_bytes(&h2).unwrap();
        assert!(out2.len() > 9);
        let got = parse(&h2).unwrap();
        assert_eq!(got.path, "/bios/bootloader");
        let mut off = Router::from_spec(&spec);
        off.http2 = false;
        assert!(off
            .handle_bytes(&h2)
            .unwrap_err()
            .contains("http2 compiled out"));
        let frame_only = &h2[h2::PREFACE.len()..];
        assert!(parse(frame_only).is_err());
        assert_eq!(preferred_http(true, true), Some("h2"));
        assert_eq!(preferred_http(false, true), Some("http/1.1"));
        let h2c = b"GET /bios/clocks HTTP/1.1\r\nHost: bios\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAAQCAAAAAAIAAAAA\r\n\r\n";
        let sw = r.handle_bytes(h2c).unwrap();
        let s = String::from_utf8_lossy(&sw);
        assert!(s.contains("101"), "{s}");
        assert!(s.contains("h2c"), "{s}");
    }

    #[test]
    fn responses_carry_security_headers() {
        let r = Response::json(200, "{}");
        let has = |k: &str, v: &str| r.headers.iter().any(|(a, b)| a == k && b.contains(v));
        assert!(has("x-content-type-options", "nosniff"));
        assert!(has("x-frame-options", "DENY"));
        assert!(has("content-security-policy", "frame-ancestors 'none'"));
        assert!(has("cache-control", "no-store"));
        assert!(has("strict-transport-security", "max-age=31536000"));
        assert!(has("cross-origin-opener-policy", "same-origin"));
        assert!(has("cross-origin-embedder-policy", "require-corp"));
        assert!(has("permissions-policy", "camera=()"));
        assert!(has("x-dns-prefetch-control", "off"));
        assert!(has("x-permitted-cross-domain-policies", "none"));
        assert!(!has("content-security-policy", "*"));
    }
}
