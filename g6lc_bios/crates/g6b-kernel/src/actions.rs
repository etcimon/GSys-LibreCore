// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Setup-page controls that are not menu tabs: boot, settings, net,
//! firmware, manual, console. The kernel records the result. The page paints it.

use super::BrowserSession;

impl BrowserSession {
    /// `true` when `id` was one of those controls.
    pub(super) fn shell_click(&mut self, id: &str) -> Result<bool, String> {
        if let Some(boot) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-boot").map(str::to_string))
        {
            let line = format!("BootSelect(\"{boot}\")");
            match self.holyc_request(&line) {
                Ok(g6b_holyc::ReplResult::Output(text)) => {
                    self.diagnostics.push(format!("BOOT-PICK {text}"));
                }
                Ok(other) => {
                    self.diagnostics.push(format!("BOOT-PICK {other:?}"));
                }
                Err(error) => {
                    self.diagnostics.push(format!("BOOT-PICK-ERR {error}"));
                }
            }
            return Ok(true);
        }
        if let Some(action) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-settings").map(str::to_string))
        {
            let line = if action == "load" {
                "SettingsImport(\"uart\")".to_string()
            } else {
                "SettingsExport(\"uart\")".to_string()
            };
            if let Some(out) = self.settings_invoke(&line) {
                self.diagnostics.push(format!("SETTINGS {out}"));
            }
            return Ok(true);
        }
        if let Some(action) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-net").map(str::to_string))
        {
            let out = self.net_apply(&action);
            self.diagnostics.push(format!("NET {out}"));
            return Ok(true);
        }
        if let Some(action) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-fw").map(str::to_string))
        {
            let src = super::input_value(&self.dom, "fw-src");
            let line = if action == "commit" {
                let shown = super::find_node_by_id(&self.dom, "fw-digest")
                    .map(|n| n.inner_text())
                    .unwrap_or_default();
                let hex = shown
                    .split("sha256=")
                    .nth(1)
                    .unwrap_or("")
                    .split_whitespace()
                    .next()
                    .unwrap_or("");
                if hex.is_empty() {
                    "FwApply(\"\")".into()
                } else {
                    format!("FwApply(\"{hex}\")")
                }
            } else {
                format!("FwUpdate(\"{src}\")")
            };
            if let Some(out) = self.firmware_invoke(&line) {
                self.diagnostics.push(format!("FW {out}"));
            }
            return Ok(true);
        }
        if super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-manual").map(str::to_string))
            .as_deref()
            == Some("open")
        {
            let out = self.open_manual();
            self.diagnostics.push(format!("MANUAL {out}"));
            return Ok(true);
        }
        if let Some(action) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-console").map(str::to_string))
        {
            self.console_set(action != "close");
            self.diagnostics.push(format!(
                "CONSOLE {}",
                if self.console_open { "open" } else { "closed" }
            ));
            return Ok(true);
        }
        if let Some(key) = super::find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-setting-apply").map(str::to_string))
        {
            let out = self.apply_setting_control(&key);
            self.diagnostics.push(format!("SETTING {out}"));
            return Ok(true);
        }
        Ok(false)
    }
}
