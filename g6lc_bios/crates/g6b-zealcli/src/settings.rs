// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Adjusting BIOS settings from the CLI.
//!
//! Setup screens are mostly a **view** of what was compiled into the RTL and
//! the payload; only the rows in `g6b_spec::menu::WRITABLE` can be written, and
//! each one names the BoardSpec path it lands on. A write goes into an overlay
//! first and is exported as a BoardSpec JSON patch — which is what firmware can
//! honestly promise: the running image is fixed, the next build/boot picks the
//! patch up. Nothing here pretends to re-parameterize live silicon.

use std::collections::BTreeMap;

use g6b_spec::menu::{SettingKind, Writable};
use g6b_spec::BoardSpec;

/// Pending writes, keyed `menu.id`.
#[derive(Debug, Default, Clone)]
pub struct Overlay {
    edits: BTreeMap<String, String>,
}

impl Overlay {
    pub fn is_empty(&self) -> bool {
        self.edits.is_empty()
    }

    pub fn len(&self) -> usize {
        self.edits.len()
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.edits.get(key).map(String::as_str)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &String)> {
        self.edits.iter()
    }

    pub fn clear(&mut self) {
        self.edits.clear();
    }

    /// Write `menu.id = value`. `key` may be `settings.cli_rows` or just
    /// `cli_rows` when the row name is unique across screens.
    pub fn set(&mut self, spec: &BoardSpec, key: &str, value: &str) -> Result<String, String> {
        let w = resolve(spec, key)?;
        let canonical = w
            .kind
            .canonical(value)
            .map_err(|e| format!("set {}.{}: {e}", w.menu, w.id))?;
        self.edits
            .insert(format!("{}.{}", w.menu, w.id), canonical.clone());
        Ok(format!(
            "SET {}.{} = {canonical} ({})",
            w.menu, w.id, w.path
        ))
    }

    /// Current value of a row: the pending write if any, else the compiled one.
    pub fn effective(&self, spec: &BoardSpec, key: &str) -> Result<String, String> {
        let w = resolve(spec, key)?;
        let id = format!("{}.{}", w.menu, w.id);
        if let Some(v) = self.edits.get(&id) {
            return Ok(format!("{id} = {v} (pending)"));
        }
        let menu = spec
            .menu(w.menu)
            .ok_or_else(|| format!("no menu {}", w.menu))?;
        let item = menu
            .items
            .iter()
            .find(|i| i.id == w.id)
            .ok_or_else(|| format!("no row {id}"))?;
        Ok(format!("{id} = {}", item.value))
    }

    /// A BoardSpec JSON patch of the pending writes, ready for
    /// `SettingsExport` / a USB key / the next build.
    pub fn patch_json(&self, spec: &BoardSpec) -> String {
        let mut tree = Node::default();
        for (key, value) in &self.edits {
            let Some((menu, id)) = key.split_once('.') else {
                continue;
            };
            let Some(w) = spec.writable(menu, id) else {
                continue;
            };
            tree.insert(w.path, &render(w, value));
        }
        let mut out = String::from("{\"schema_version\":1");
        for (k, v) in &tree.children {
            out.push(',');
            out.push('"');
            out.push_str(k);
            out.push_str("\":");
            v.write(&mut out);
        }
        out.push('}');
        out
    }

    /// Read a patch from [`Overlay::patch_json`] into this overlay. Does not
    /// rewrite the running BoardSpec; the next boot/build applies the patch.
    pub fn load_patch(&mut self, spec: &BoardSpec, patch: &str) -> Result<usize, String> {
        let json = g6b_spec::parse_json(patch).map_err(|e| format!("settings patch: {e}"))?;
        let mut n = 0;
        for w in spec.writables() {
            let value = json_path(&json, w.path);
            let text = match value {
                g6b_spec::Json::Null => continue,
                g6b_spec::Json::Str(s) => s.clone(),
                g6b_spec::Json::Bool(true) => "yes".into(),
                g6b_spec::Json::Bool(false) => "no".into(),
                g6b_spec::Json::Int(i) => i.to_string(),
                _ => return Err(format!("settings patch: {} is not a value", w.path)),
            };
            self.set(spec, &format!("{}.{}", w.menu, w.id), &text)?;
            n += 1;
        }
        Ok(n)
    }

    /// Pending rows for `GET /bios/settings/pending`.
    pub fn pending_json(&self, spec: &BoardSpec) -> String {
        let mut body = String::from("{\"pending\":[");
        for (i, (key, value)) in self.edits.iter().enumerate() {
            if i > 0 {
                body.push(',');
            }
            let path = key
                .split_once('.')
                .and_then(|(m, id)| spec.writable(m, id))
                .map(|w| w.path)
                .unwrap_or("");
            body.push_str("{\"id\":");
            body.push_str(&g6b_spec::quote_json(key));
            body.push_str(",\"value\":");
            body.push_str(&g6b_spec::quote_json(value));
            body.push_str(",\"path\":");
            body.push_str(&g6b_spec::quote_json(path));
            body.push('}');
        }
        body.push_str("]}");
        body
    }

    /// Apply a patch produced by [`Overlay::patch_json`] on top of a BoardSpec
    /// JSON document, i.e. what `SettingsImport` hands the next build.
    pub fn summary(&self, spec: &BoardSpec) -> String {
        if self.edits.is_empty() {
            return "no pending settings writes\n".into();
        }
        let mut s = String::new();
        for (key, value) in &self.edits {
            let path = key
                .split_once('.')
                .and_then(|(m, i)| spec.writable(m, i))
                .map(|w| w.path)
                .unwrap_or("?");
            s.push_str(&format!("{key} = {value}  -> {path}\n"));
        }
        s
    }
}

/// Row lookup by `menu.id` or by a unique bare `id`.
pub fn resolve(spec: &BoardSpec, key: &str) -> Result<&'static Writable, String> {
    let key = key.trim();
    if let Some((menu, id)) = key.split_once('.') {
        return spec
            .writable(menu, id)
            .ok_or_else(|| format!("`{key}` is not a writable setting (try `set` for the list)"));
    }
    let hits: Vec<&'static Writable> = spec
        .writables()
        .into_iter()
        .filter(|w| w.id == key)
        .collect();
    match hits.len() {
        1 => Ok(hits[0]),
        0 => Err(format!(
            "`{key}` is not a writable setting (try `set` for the list)"
        )),
        _ => Err(format!(
            "`{key}` is ambiguous; qualify it as {}",
            hits.iter()
                .map(|w| format!("{}.{}", w.menu, w.id))
                .collect::<Vec<_>>()
                .join(" or ")
        )),
    }
}

/// The writable rows, formatted for `set` with no argument and for `man`.
pub fn writable_table(spec: &BoardSpec) -> String {
    let mut s = String::from("writable settings (set <name> <value>):\n");
    for w in spec.writables() {
        s.push_str(&format!(
            "  {:<24} {:<28} {}\n",
            format!("{}.{}", w.menu, w.id),
            w.kind.describe(),
            w.path
        ));
    }
    s
}

fn json_path<'a>(json: &'a g6b_spec::Json, path: &str) -> &'a g6b_spec::Json {
    let mut cur = json;
    for part in path.split('.') {
        cur = cur.get(part);
    }
    cur
}

fn render(w: &Writable, value: &str) -> String {
    match w.kind {
        SettingKind::Bool => {
            if value == "yes" {
                "true".into()
            } else {
                "false".into()
            }
        }
        SettingKind::U32 { .. } => value.to_string(),
        SettingKind::Enum(_) => {
            // A numeric enum (uart_baud) is still a number in BoardSpec.
            if value.chars().all(|c| c.is_ascii_digit()) {
                value.to_string()
            } else {
                format!("\"{value}\"")
            }
        }
        SettingKind::Text { .. } => format!("\"{value}\""),
    }
}

/// A tiny JSON object tree, just enough to nest dotted BoardSpec paths.
#[derive(Debug, Default)]
struct Node {
    children: BTreeMap<String, Node>,
    leaf: Option<String>,
}

impl Node {
    fn insert(&mut self, path: &str, value: &str) {
        match path.split_once('.') {
            Some((head, rest)) => self
                .children
                .entry(head.to_string())
                .or_default()
                .insert(rest, value),
            None => {
                self.children.entry(path.to_string()).or_default().leaf = Some(value.to_string());
            }
        }
    }

    fn write(&self, out: &mut String) {
        if let Some(v) = &self.leaf {
            out.push_str(v);
            return;
        }
        out.push('{');
        for (i, (k, v)) in self.children.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push('"');
            out.push_str(k);
            out.push_str("\":");
            v.write(out);
        }
        out.push('}');
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> BoardSpec {
        BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#).unwrap()
    }

    #[test]
    fn writes_are_canonical_and_only_on_writable_rows() {
        let spec = spec();
        let mut o = Overlay::default();
        assert!(o.set(&spec, "boot.next", "EDK2").unwrap().contains("edk2"));
        assert!(o.set(&spec, "cli_rows", "40").unwrap().contains("40"));
        assert!(o.set(&spec, "timeout_ms", "3000").is_ok());
        // Views are not settings.
        assert!(o
            .set(&spec, "cpu.cores", "8")
            .unwrap_err()
            .contains("not a writable"));
        assert!(o.set(&spec, "nonsense", "1").is_err());
        // Out-of-range and nonsense values never enter the overlay.
        assert!(o.set(&spec, "cli_rows", "900").is_err());
        assert!(o.set(&spec, "boot.next", "grub").is_err());
        assert_eq!(o.len(), 3);
        assert!(o.effective(&spec, "boot.next").unwrap().contains("pending"));
        assert!(o
            .effective(&spec, "cpu_hz")
            .unwrap()
            .contains("cpu.cpu_hz ="));
    }

    #[test]
    fn patch_json_is_a_boardspec_overlay() {
        let spec = spec();
        let mut o = Overlay::default();
        o.set(&spec, "boot.next", "u-boot").unwrap();
        o.set(&spec, "settings.cli_rows", "40").unwrap();
        o.set(&spec, "settings.cli_mouse", "on").unwrap();
        o.set(&spec, "entry_timeout", "1").unwrap_err();
        o.set(&spec, "boot.timeout_ms", "1500").unwrap();
        o.set(&spec, "fw_url", "https://fw.gsys.dev/g6lc_bios.elf")
            .unwrap();
        let patch = o.patch_json(&spec);
        // A patch is an overlay on the board it came from: applied to that
        // profile it must still be a legal BoardSpec.
        let merged = patch.replacen(
            "{\"schema_version\":1",
            "{\"schema_version\":1,\"profile\":\"barebone\"",
            1,
        );
        let round = BoardSpec::from_json_str(&merged)
            .unwrap_or_else(|e| panic!("patch is not a BoardSpec: {e}\n{merged}"));
        assert_eq!(round.kernel.params.next, "u-boot");
        assert_eq!(round.kernel.cli.rows, 40);
        assert!(
            round.kernel.cli.mouse,
            "the pointer opt-in survives the patch"
        );
        assert_eq!(round.entry.timeout_ms, 1500);
        assert_eq!(round.kernel.flash.url, "https://fw.gsys.dev/g6lc_bios.elf");
        assert!(o.summary(&spec).contains("kernel.params.next"));
        let empty = Overlay::default();
        assert!(empty.summary(&spec).contains("no pending"));
        assert_eq!(empty.patch_json(&spec), "{\"schema_version\":1}");
        let mut fresh = Overlay::default();
        let n = fresh.load_patch(&spec, &patch).unwrap();
        assert!(n >= 4, "{n}");
        assert!(
            fresh
                .effective(&spec, "boot.autoboot_order")
                .unwrap_or_else(|_| fresh.effective(&spec, "boot.next").unwrap())
                .contains("pending")
                || fresh
                    .effective(&spec, "boot.next")
                    .unwrap()
                    .contains("u-boot")
        );
        assert!(fresh
            .effective(&spec, "boot.next")
            .unwrap()
            .contains("u-boot"));
    }

    #[test]
    fn table_lists_every_writable_row_with_its_alphabet() {
        let spec = spec();
        let t = writable_table(&spec);
        for w in spec.writables() {
            assert!(t.contains(&format!("{}.{}", w.menu, w.id)), "{t}");
            assert!(t.contains(w.path), "{t}");
        }
        assert!(t.contains("opensbi|edk2|u-boot"), "{t}");
    }
}
