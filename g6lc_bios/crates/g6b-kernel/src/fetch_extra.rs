// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Dynamic setup GETs that depend on the live session.
//! Static `/bios/menu/…` stays on the router.

use super::BrowserSession;

impl BrowserSession {
    pub(super) fn extra_fetch(&mut self, url: &str) -> Option<g6b_http::Response> {
        let path = url.split(['?', '#']).next().unwrap_or(url);
        let resp = match path {
            "/bios/fw/status" => {
                g6b_http::Response::file(200, "text/plain", self.shell.eval("fw status").1)
            }
            "/bios/hw/stat" => {
                g6b_http::Response::file(200, "application/json", self.hw.stat_json())
            }
            "/bios/disk" => g6b_http::Response::file(
                200,
                "application/json",
                g6b_zealcli::fsview::disk_json(self.shell.ports()),
            ),
            "/bios/cli/screen" => {
                if !self.spec.kernel.cli.enable {
                    g6b_http::Response::file(404, "text/plain", "cli disabled")
                } else {
                    g6b_http::Response::file(200, "text/plain", self.console_text())
                }
            }
            "/bios/settings/pending" => {
                g6b_http::Response::file(200, "application/json", self.shell.pending_json())
            }
            _ => return None,
        };
        Some(resp)
    }

    /// Live setup routes for a host that holds this session. Static files
    /// stay on the router: this returns `None` for every other path.
    pub fn serve_setup(
        &mut self,
        method: &str,
        path: &str,
        body: &str,
    ) -> Option<g6b_http::Response> {
        let path = path.split(['?', '#']).next().unwrap_or(path);
        if method.eq_ignore_ascii_case("POST") {
            if let Some(resp) = self.setup_post(path, body) {
                return Some(resp);
            }
            return self.cli_post(path, body);
        }
        if method.eq_ignore_ascii_case("GET") {
            return self.extra_fetch(path);
        }
        None
    }

    /// `POST /bios/holyc` runs the line on this session. The native page
    /// posts the same text `holyc_request` already accepts.
    pub(super) fn setup_post(&mut self, path: &str, body: &str) -> Option<g6b_http::Response> {
        if path != "/bios/holyc" {
            return None;
        }
        let line = body.trim();
        if line.is_empty() || line.len() > 480 || line.contains('\n') || line.contains('\r') {
            return Some(g6b_http::Response::file(
                400,
                "text/plain",
                "setup line refused\n",
            ));
        }
        match self.submit_setup_line(line) {
            Ok(text) => Some(g6b_http::Response::file(200, "text/plain", text)),
            Err(error) => Some(g6b_http::Response::file(400, "text/plain", error)),
        }
    }

    /// `POST /bios/cli` with `open`, `close`, or `key <name>`. The body of a
    /// successful key is the console text. The page paints `#cli-screen`.
    pub(super) fn cli_post(&mut self, path: &str, body: &str) -> Option<g6b_http::Response> {
        if path != "/bios/cli" {
            return None;
        }
        if !self.spec.kernel.cli.enable {
            return Some(g6b_http::Response::file(404, "text/plain", "cli disabled"));
        }
        let body = body.trim();
        let text = if body == "open" {
            self.console_set(true);
            self.console_text()
        } else if body == "close" {
            self.console_set(false);
            String::new()
        } else if let Some(key) = body.strip_prefix("key ") {
            if !console_key_name(key) {
                return Some(g6b_http::Response::file(
                    400,
                    "text/plain",
                    "cli key refused\n",
                ));
            }
            if !self.console_open {
                return Some(g6b_http::Response::file(
                    409,
                    "text/plain",
                    "console closed\n",
                ));
            }
            if let Err(error) = self.handle_key(key) {
                return Some(g6b_http::Response::file(400, "text/plain", error));
            }
            self.console_text()
        } else {
            return Some(g6b_http::Response::file(
                400,
                "text/plain",
                "cli command refused\n",
            ));
        };
        Some(g6b_http::Response::file(200, "text/plain", text))
    }
}

fn console_key_name(key: &str) -> bool {
    matches!(
        key,
        "ArrowUp"
            | "ArrowDown"
            | "ArrowLeft"
            | "ArrowRight"
            | "Enter"
            | "Backspace"
            | "Escape"
            | "Tab"
            | "Home"
            | "End"
            | "F10"
    ) || key.chars().count() == 1 && key.chars().next().is_some_and(|ch| !ch.is_control())
}
