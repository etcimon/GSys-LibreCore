// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Kernel endpoint table. HolyC and JS register into the same map.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_spec::BoardSpec;

use crate::{files, parse, Request, Response, Version};

/// One registered endpoint.
#[derive(Debug, Clone)]
pub struct Route {
    pub method: String,
    pub path: String,
    /// Origin: `bios`, `holyc`, or `js`.
    pub origin: String,
    pub body: String,
}

/// Shared kernel router (HolyC ≡ JS ≡ WASM fetch).
#[derive(Debug, Clone)]
pub struct Router {
    pub http1: bool,
    pub http2: bool,
    /// TLS record wrap for file/HTTPS serve.
    pub https: bool,
    routes: BTreeMap<(String, String), Route>,
    files: BTreeMap<String, files::StaticFile>,
}

impl Default for Router {
    fn default() -> Self {
        Self {
            http1: true,
            http2: true,
            https: false,
            routes: BTreeMap::new(),
            files: BTreeMap::new(),
        }
    }
}

impl Router {
    /// BoardSpec-compiled BIOS parameter endpoints.
    pub fn from_spec(spec: &BoardSpec) -> Self {
        let mut r = Self {
            http1: spec.kernel.http.http1,
            http2: spec.kernel.http.http2,
            https: spec.kernel.http.files.https || spec.kernel.tls.serve,
            routes: BTreeMap::new(),
            files: BTreeMap::new(),
        };
        if !spec.kernel.http.enable {
            r.http1 = false;
            r.http2 = false;
            return r;
        }
        let p = &spec.kernel.params;
        if p.clocks {
            r.insert(
                "GET",
                "/bios/clocks",
                "bios",
                format!(
                    "{{\"cpu_hz\":{},\"uart_baud\":{},\"timer_base\":\"0x18000000\"}}",
                    p.cpu_hz, p.uart_baud
                ),
            );
        }
        if p.edk2 {
            r.insert(
                "GET",
                "/bios/edk2",
                "bios",
                format!(
                    "{{\"loader\":\"edk2\",\"enable\":{}}}",
                    if p.edk2_enable { "true" } else { "false" }
                ),
            );
        }
        if p.uboot {
            r.insert(
                "GET",
                "/bios/u-boot",
                "bios",
                format!(
                    "{{\"loader\":\"u-boot\",\"enable\":{}}}",
                    if p.uboot_enable { "true" } else { "false" }
                ),
            );
        }
        if p.bootloader {
            r.insert(
                "GET",
                "/bios/bootloader",
                "bios",
                format!(
                    "{{\"next\":\"{}\",\"payload\":\"g6lc_bios.elf\",\"s_mode\":true}}",
                    p.next
                ),
            );
        }
        r.insert(
            "GET",
            "/bios/profile",
            "bios",
            format!("{{\"profile\":\"{}\"}}", spec.kernel.profile.as_str()),
        );
        r.insert(
            "GET",
            "/bios/features",
            "bios",
            spec.compiled_features_json(),
        );
        r.insert("GET", "/bios/menu", "bios", spec.menus_index_json());
        r.insert(
            "GET",
            "/bios/cpu",
            "bios",
            spec.menu("cpu")
                .map(|m| m.json())
                .unwrap_or_else(|| "{}".into()),
        );
        r.insert(
            "GET",
            "/bios/uncore",
            "bios",
            spec.menu("uncore")
                .map(|m| m.json())
                .unwrap_or_else(|| "{}".into()),
        );
        for m in spec.menus() {
            r.insert("GET", &format!("/bios/menu/{}", m.id), "bios", m.json());
        }
        let f = &spec.kernel.flash;
        if f.enable {
            let body = format!(
                "{{\"enable\":true,\"image\":\"{}\",\"backend\":\"{}\",\"openwrt\":{},\"self_update\":{}}}",
                f.image,
                f.backend,
                if f.openwrt { "true" } else { "false" },
                if f.self_update { "true" } else { "false" }
            );
            r.insert("GET", "/bios/flash", "bios", body.clone());
            r.insert(
                "POST",
                "/bios/flash",
                "bios",
                "{\"ok\":true,\"action\":\"flash\"}",
            );
            if f.self_update {
                r.insert("GET", "/bios/update", "bios", body);
                r.insert(
                    "POST",
                    "/bios/update",
                    "bios",
                    "{\"ok\":true,\"action\":\"self-update\"}",
                );
            }
        }
        let s = &spec.kernel.settings;
        if s.enable {
            let body = format!(
                "{{\"export\":{},\"import\":{},\"uart\":{},\"mailbox\":{},\"usb_key\":{}}}",
                if s.export { "true" } else { "false" },
                if s.import { "true" } else { "false" },
                if s.uart { "true" } else { "false" },
                if s.mailbox { "true" } else { "false" },
                if s.usb_key { "true" } else { "false" }
            );
            r.insert("GET", "/bios/settings", "bios", body);
            if s.export {
                r.insert(
                    "GET",
                    "/bios/settings/export",
                    "bios",
                    "{\"format\":\"json\",\"via\":\"uart,mailbox\"}",
                );
            }
            if s.import {
                r.insert(
                    "POST",
                    "/bios/settings/import",
                    "bios",
                    "{\"ok\":true,\"via\":\"uart,mailbox\"}",
                );
                r.insert(
                    "PUT",
                    "/bios/settings",
                    "bios",
                    "{\"ok\":true,\"action\":\"import\"}",
                );
            }
            if s.usb_key {
                r.insert(
                    "GET",
                    "/bios/settings/usb",
                    "bios",
                    "{\"present\":true,\"role\":\"key\"}",
                );
                r.insert(
                    "POST",
                    "/bios/settings/usb",
                    "bios",
                    "{\"ok\":true,\"via\":\"usb-key\"}",
                );
            }
        }
        let u = &spec.kernel.usb;
        if u.enable {
            r.insert(
                "GET",
                "/bios/usb",
                "bios",
                format!(
                    "{{\"enable\":true,\"flash_fat32\":{},\"key\":{},\"fs\":{}}}",
                    if u.flash_fat32 { "true" } else { "false" },
                    if u.key { "true" } else { "false" },
                    g6b_fs::volumes_json(spec)
                ),
            );
            if u.flash_fat32 {
                r.insert(
                    "GET",
                    "/bios/usb/ls",
                    "bios",
                    g6b_fs::ents_json(&g6b_fs::flash_images(spec)),
                );
                r.insert(
                    "POST",
                    "/bios/usb/flash",
                    "bios",
                    "{\"ok\":true,\"fs\":\"fat32\",\"action\":\"flash\"}",
                );
            }
            if u.key {
                r.insert("GET", "/bios/files", "bios", g6b_fs::volumes_json(spec));
                let mut vols = Vec::new();
                if u.fs_fat32 {
                    vols.push(("/bios/files/fat32", g6b_fs::FsKind::Fat32));
                }
                if u.fs_ntfs {
                    vols.push(("/bios/files/ntfs", g6b_fs::FsKind::Ntfs));
                }
                if u.fs_ext4 {
                    vols.push(("/bios/files/ext4", g6b_fs::FsKind::Ext4));
                }
                for (path, kind) in vols {
                    r.insert(
                        "GET",
                        path,
                        "bios",
                        g6b_fs::ents_json(&g6b_fs::list_key(spec, "/", Some(kind))),
                    );
                }
            }
        }
        if spec.kernel.http.files.enable {
            r.files = files::mount(spec);
            let list: Vec<String> = r.files.keys().cloned().collect();
            r.insert(
                "GET",
                "/bios/www",
                "bios",
                format!(
                    "{{\"root\":\"{}\",\"https\":{},\"files\":{list:?}}}",
                    spec.kernel.http.files.root,
                    if spec.kernel.http.files.https {
                        "true"
                    } else {
                        "false"
                    }
                ),
            );
        }
        r
    }

    /// Register from HolyC or JS. Same table.
    pub fn insert(&mut self, method: &str, path: &str, origin: &str, body: impl Into<String>) {
        let m = method.to_ascii_uppercase();
        let p = path.to_string();
        self.routes.insert(
            (m.clone(), p.clone()),
            Route {
                method: m,
                path: p,
                origin: origin.into(),
                body: body.into(),
            },
        );
    }

    /// Lookup.
    pub fn get(&self, method: &str, path: &str) -> Option<&Route> {
        self.routes
            .get(&(method.to_ascii_uppercase(), path.to_string()))
    }

    /// Dispatch a parsed request.
    pub fn handle(&self, req: &Request) -> Response {
        let path = req.path.split('?').next().unwrap_or(req.path.as_str());
        if req.method.eq_ignore_ascii_case("GET") {
            if let Some(f) = self.files.get(path) {
                return Response::file(200, &f.content_type, f.body.clone());
            }
        }
        if let Some(rt) = self.get(&req.method, path) {
            return Response::json(200, &rt.body);
        }
        if req.method.eq_ignore_ascii_case("GET") && path == "/bios" {
            let list: Vec<String> = self
                .routes
                .values()
                .map(|r| format!("{} {}", r.method, r.path))
                .collect();
            return Response::json(200, &format!("{{\"endpoints\":{list:?}}}"));
        }
        Response::json(404, "{\"error\":\"not found\"}")
    }

    /// Parse bytes (HTTP/1.1, HTTP/2, or TLS 1.2 ClientHello / app-data).
    pub fn handle_bytes(&self, raw: &[u8]) -> Result<Vec<u8>, String> {
        if g6b_tls::is_client_hello(raw) {
            if !self.https {
                return Err("https compiled out".into());
            }
            return g6b_tls::server_handshake(raw);
        }
        let tls = g6b_tls::is_app_record(raw);
        let inner = if tls {
            if !self.https {
                return Err("https compiled out".into());
            }
            g6b_tls::unwrap_app(raw)?
        } else {
            raw.to_vec()
        };
        let http = self.handle_http_bytes(&inner)?;
        if tls {
            Ok(g6b_tls::wrap_app(&http))
        } else {
            Ok(http)
        }
    }

    fn handle_http_bytes(&self, raw: &[u8]) -> Result<Vec<u8>, String> {
        let req = parse(raw)?;
        match req.version {
            Version::Http11 => {
                if !self.http1 {
                    return Err("http1 compiled out".into());
                }
                Ok(crate::h1::encode(&self.handle(&req)))
            }
            Version::Http2 => {
                if !self.http2 {
                    return Err("http2 compiled out".into());
                }
                Ok(crate::h2::encode(&self.handle(&req), 1))
            }
        }
    }

    /// Convenience for JS `fetch(url)` (GET).
    pub fn fetch_get(&self, url: &str) -> Response {
        let path = url
            .split("://")
            .last()
            .and_then(|s| s.find('/').map(|i| &s[i..]))
            .unwrap_or(url);
        let path = path.split('?').next().unwrap_or(path);
        self.handle(&Request {
            method: "GET".into(),
            path: path.into(),
            version: Version::Http11,
            headers: Vec::new(),
            body: Vec::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_clocks_and_js_register() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true},"params":{"clocks":true,"cpu_hz":1000000000}}}"#,
        )
        .unwrap();
        let mut r = Router::from_spec(&spec);
        let resp = r.fetch_get("/bios/clocks");
        assert_eq!(resp.status, 200);
        assert!(resp.body_str().contains("cpu_hz"), "{}", resp.body_str());
        r.insert("GET", "/bios/custom", "js", "{\"ok\":1}");
        assert_eq!(r.fetch_get("/bios/custom").status, 200);
        r.insert("GET", "/bios/holyc-ep", "holyc", "HOLYC-EP");
        assert!(r
            .fetch_get("/bios/holyc-ep")
            .body_str()
            .contains("HOLYC-EP"));
    }

    #[test]
    fn router_profile_flash_openwrt() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"router","isa":{"xlen":32}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        let f = r.fetch_get("/bios/flash");
        assert_eq!(f.status, 200);
        assert!(f.body_str().contains("openwrt"), "{}", f.body_str());
        let s = r.fetch_get("/bios/settings");
        assert_eq!(s.status, 200);
        assert!(
            !s.body_str().contains("\"usb_key\":true"),
            "{}",
            s.body_str()
        );
        let u = r.fetch_get("/bios/usb/ls");
        assert_eq!(u.status, 200);
        assert!(u.body_str().contains("openwrt.bin"), "{}", u.body_str());
        assert_eq!(r.fetch_get("/bios/files").status, 404);
    }

    #[test]
    fn full_profile_file_manager() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let r = Router::from_spec(&spec);
        let nt = r.fetch_get("/bios/files/ntfs");
        assert_eq!(nt.status, 200);
        assert!(nt.body_str().contains("ntfs"), "{}", nt.body_str());
        let ext = r.fetch_get("/bios/files/ext4");
        assert!(ext.body_str().contains("ext4"), "{}", ext.body_str());
    }

    #[test]
    fn full_profile_serves_html_js_wasm_and_https() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let r = Router::from_spec(&spec);
        let html = r.fetch_get("/ui/index.html");
        assert_eq!(html.status, 200);
        assert!(html.body_str().contains("G6LC-BIOS"), "{}", html.body_str());
        assert!(html
            .headers
            .iter()
            .any(|(k, v)| k == "content-type" && v.contains("text/html")));
        let js = r.fetch_get("/ui/app.js");
        assert!(js.body_str().contains("UI-BOOT"), "{}", js.body_str());
        let wasm = r.fetch_get("/ui/ui.wasm");
        assert_eq!(&wasm.body[..4], b"\0asm");
        let ch = g6b_tls::client_hello("localhost");
        let sh = r.handle_bytes(&ch).unwrap();
        assert_eq!(sh[0], g6b_tls::REC_HANDSHAKE);
        let http = b"GET /ui/index.html HTTP/1.1\r\nHost: bios\r\n\r\n";
        let wrapped = g6b_tls::wrap_app(http);
        let resp = r.handle_bytes(&wrapped).unwrap();
        assert_eq!(resp[0], g6b_tls::REC_APP);
        let inner = g6b_tls::unwrap_app(&resp).unwrap();
        assert!(String::from_utf8_lossy(&inner).contains("G6LC-BIOS"));
    }

    #[test]
    fn menu_cpu_and_uncore_from_smt2() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64},"harts":{"count":2},"core":{"issue_ports":2}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        let cpu = r.fetch_get("/bios/menu/cpu");
        assert_eq!(cpu.status, 200);
        assert!(cpu.body_str().contains("smt"), "{}", cpu.body_str());
        let un = r.fetch_get("/bios/menu/uncore");
        assert!(un.body_str().contains("plic"), "{}", un.body_str());
        assert_eq!(r.fetch_get("/bios/cpu").status, 200);
    }
}
