// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Kernel endpoint table. HolyC and JS register into the same map.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_pglite::StorePort;
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

/// `/bios/display` body: the candidate outputs in priority order, the one that
/// would win, and the surface feeding it. Declared state — actual presence is a
/// boot-time fact the guest `DispSel` mux resolves.
fn display_json(spec: &BoardSpec) -> String {
    let outs: Vec<String> = spec
        .display_outputs()
        .iter()
        .map(|o| {
            format!(
                "{{\"id\":\"{}\",\"class\":\"{}\",\"priority\":{},\"w\":{},\"h\":{},\"surface\":\"{}\"}}",
                escape(&o.id),
                o.class.as_str(),
                o.class.priority(),
                o.w,
                o.h,
                o.surface.as_str()
            )
        })
        .collect();
    let active = spec.default_output();
    format!(
        "{{\"active\":\"{}\",\"class\":\"{}\",\"surface\":\"{}\",\"toggle\":{},\"outputs\":[{}]}}",
        escape(&active.id),
        active.class.as_str(),
        spec.default_surface().as_str(),
        if spec.surface_toggle() {
            "true"
        } else {
            "false"
        },
        outs.join(",")
    )
}

/// POST body: the surface the toggle switches to from the default.
fn display_toggle_json(spec: &BoardSpec) -> String {
    format!(
        "{{\"ok\":true,\"action\":\"surface\",\"surface\":\"{}\"}}",
        spec.default_surface().toggled().as_str()
    )
}

/// Minimal JSON string escaping for ids that come from BoardSpec.
fn escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            c if (c as u32) < 0x20 => vec![' '],
            c => vec![c],
        })
        .collect()
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
            files::live_features_json(spec, files::load_pglite_dist().as_ref()),
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
        // Display outputs and the VGA/GPU surface split. GET always exists so a
        // UI can report which output won; POST is only registered when both
        // surfaces are actually reachable, so toggling cannot be offered on a
        // board that has nowhere to toggle to.
        r.insert("GET", "/bios/display", "bios", display_json(spec));
        if spec.surface_toggle() {
            r.insert("POST", "/bios/display", "bios", display_toggle_json(spec));
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

    /// Dispatch a parsed request (canned routes + files). Store paths 404
    /// without a [`StorePort`].
    pub fn handle(&self, req: &Request) -> Response {
        self.handle_store(req, None)
    }

    /// Dispatch, threading a live store for `/bios/store/*` before canned routes.
    pub fn handle_store(&self, req: &Request, store: Option<&mut dyn StorePort>) -> Response {
        let path = req.path.split('?').next().unwrap_or(req.path.as_str());
        if path == "/bios/store" || path.starts_with("/bios/store/") {
            if (!self.http1 && !self.http2) || store.is_none() {
                return Response::json(404, "{\"error\":\"not found\"}");
            }
            if let Some(s) = store {
                return match s.handle(&req.method, path, &req.body) {
                    Ok((status, body)) => Response::json(status, &body),
                    Err(e) => Response::json(500, &format!("{{\"error\":\"{e}\"}}")),
                };
            }
        }
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
        self.handle_http_bytes_store(raw, None)
    }

    fn handle_http_bytes_store(
        &self,
        raw: &[u8],
        store: Option<&mut dyn StorePort>,
    ) -> Result<Vec<u8>, String> {
        let req = parse(raw)?;
        let resp = self.handle_store(&req, store);
        match req.version {
            Version::Http11 => {
                if !self.http1 {
                    return Err("http1 compiled out".into());
                }
                Ok(crate::h1::encode(&resp))
            }
            Version::Http2 => {
                if !self.http2 {
                    return Err("http2 compiled out".into());
                }
                Ok(crate::h2::encode(&resp, 1))
            }
        }
    }

    /// Parse bytes and dispatch through an optional live store.
    pub fn handle_bytes_store(
        &self,
        raw: &[u8],
        store: Option<&mut dyn StorePort>,
    ) -> Result<Vec<u8>, String> {
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
        let http = self.handle_http_bytes_store(&inner, store)?;
        if tls {
            Ok(g6b_tls::wrap_app(&http))
        } else {
            Ok(http)
        }
    }

    /// True when `path` is a mounted static UI file (`/ui/…`).
    pub fn has_file(&self, path: &str) -> bool {
        self.files.contains_key(path)
    }

    /// Convenience for JS `fetch(url)` (GET).
    pub fn fetch_get(&self, url: &str) -> Response {
        self.fetch("GET", url)
    }

    pub fn fetch(&self, method: &str, url: &str) -> Response {
        self.fetch_with_body(method, url, &[], None)
    }

    /// `fetch` with a request body and optional live store.
    pub fn fetch_with_body(
        &self,
        method: &str,
        url: &str,
        body: &[u8],
        store: Option<&mut dyn StorePort>,
    ) -> Response {
        if !url.starts_with('/')
            || url.starts_with("//")
            || url.contains('\\')
            || url.chars().any(char::is_control)
        {
            return Response::json(
                400,
                "{\"error\":\"kernel fetch requires a local absolute path\"}",
            );
        }
        let path = url.split(['?', '#']).next().unwrap_or(url);
        if path.split('/').any(|p| matches!(p, "." | "..")) {
            return Response::json(400, "{\"error\":\"path traversal refused\"}");
        }
        self.handle_store(
            &Request {
                method: method.to_ascii_uppercase(),
                path: path.into(),
                version: Version::Http11,
                headers: Vec::new(),
                body: body.to_vec(),
            },
            store,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetch_preserves_methods_and_confines_urls() {
        let mut r = Router::default();
        r.insert("POST", "/bios/custom", "js", "{\"posted\":true}");
        assert_eq!(r.fetch("POST", "/bios/custom?view=1#result").status, 200);
        assert_eq!(r.fetch_get("/bios/custom").status, 404);
        for url in [
            "https://other/bios/custom",
            "//other/bios/custom",
            "/bios/../bios/custom",
            "bios/custom",
            "/bios\\custom",
        ] {
            assert_eq!(r.fetch("POST", url).status, 400, "{url}");
        }
    }

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
    fn display_endpoint_ranks_outputs_and_gates_the_toggle() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"backend":"virtio-gpu"},
                      "proxy":{"enable":true,"link":"virtio-gpu","high_w":1920,"high_h":1080}}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        let body = r.fetch_get("/bios/display").body_str();
        assert!(body.contains("\"active\":\"vio0\""), "{body}");
        assert!(body.contains("\"class\":\"virtio-gpu\""), "{body}");
        assert!(body.contains("\"surface\":\"gpu\""), "{body}");
        assert!(body.contains("\"toggle\":true"), "{body}");
        // Priorities are carried so a client never re-derives the ladder.
        assert!(body.contains("\"priority\":1"), "{body}");
        assert!(body.contains("\"priority\":0"), "{body}");
        // The response parses as JSON, not just as a substring match.
        let v = g6b_spec::parse_json(&body).unwrap();
        assert_eq!(v.get("active").as_str(), Some("vio0"));
        let post = r.fetch("POST", "/bios/display");
        assert_eq!(post.status, 200);
        assert!(
            post.body_str().contains("\"surface\":\"vga\""),
            "{}",
            post.body_str()
        );
    }

    #[test]
    fn display_toggle_is_absent_without_an_accelerated_output() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"backend":"uart"}}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        let body = r.fetch_get("/bios/display").body_str();
        assert!(body.contains("\"class\":\"none\""), "{body}");
        assert!(body.contains("\"toggle\":false"), "{body}");
        // No POST route: the surface cannot be flipped where there is nothing
        // to flip to.
        assert_ne!(r.fetch("POST", "/bios/display").status, 200);
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

    #[test]
    fn store_routes_need_a_live_port_and_http() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true,"http1":true}}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&spec);
        assert_eq!(r.fetch_get("/bios/store").status, 404);
        let mut store = g6b_pglite::StoreRegistry::from_spec(&spec);
        let list = r.fetch_with_body("GET", "/bios/store", &[], Some(&mut store));
        assert_eq!(list.status, 200, "{}", list.body_str());
        assert!(
            list.body_str().contains("g6b-pglite"),
            "{}",
            list.body_str()
        );
        let created = r.fetch_with_body(
            "POST",
            "/bios/store",
            br#"{"purpose":"registry"}"#,
            Some(&mut store),
        );
        assert_eq!(created.status, 200, "{}", created.body_str());
        assert!(
            created.body_str().contains("uuid"),
            "{}",
            created.body_str()
        );
        let off = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true},"store":{"enable":false}}}"#,
        )
        .unwrap();
        let r = Router::from_spec(&off);
        let mut store = g6b_pglite::StoreRegistry::from_spec(&off);
        assert_eq!(
            r.fetch_with_body("GET", "/bios/store", &[], Some(&mut store))
                .status,
            404
        );
    }
}
