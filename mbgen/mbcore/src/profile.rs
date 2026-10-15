// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! LibreCore configuration profiles, **generated from the config packages,
//! never typed**. The processor window used to carry a literal table whose
//! core/thread counts had drifted from `core/include/*_config_pkg.sv`
//! (`g6lc64_ooo_server` advertised 4 harts; the RTL has 8). A board that
//! tells firmware the wrong hart count is discovered at Linux boot, the most
//! expensive place to learn a compile-time constant.
//!
//! The reader is deliberately narrow. A survey of the real packages found five
//! expression forms and no arithmetic: `unsigned'(X)`, `bit'(X)`, a
//! `config_pkg::ENUM`, a plain identifier (another localparam, possibly a
//! nested `'{...}` struct literal), and decimal literals. Anything else is
//! carried as [`SvValue::Unresolved`] with its source text, and a profile
//! that needs an unresolved field is `status: unresolved` — never silently
//! defaulted. A reader that guesses produces a plausible wrong board.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

/// One evaluated SystemVerilog value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SvValue {
    Int(i64),
    Flag(bool),
    Enum(String),
    Nested(BTreeMap<String, SvValue>),
    Unresolved(String),
}

/// Facts read from one `*_config_pkg.sv`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ConfigFacts {
    pub package: String,
    pub localparams: BTreeMap<String, SvValue>,
    /// The `cva6_user_cfg_t` struct literal (the one that carries `XLEN`).
    pub cfg: BTreeMap<String, SvValue>,
}

/// Where a profile's numbers came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileSource {
    /// Repo-relative path of the config package.
    pub path: String,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoreProfile {
    pub id: String,
    /// UI grouping only, derived from the id.
    pub group: String,
    pub isa: String,
    pub xlen: u32,
    pub cores: u32,
    pub threads: u32,
    /// `cores * threads` — what `mhartid` space the SoC really has.
    pub harts: u32,
    pub ooo: bool,
    pub l2: bool,
    pub l3: bool,
    pub ai: bool,
    pub axi_bits: u32,
    /// `qualified` when every field above resolved; `unresolved` otherwise.
    pub status: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unresolved: Vec<String>,
    pub source: ProfileSource,
}

impl CoreProfile {
    pub fn is_qualified(&self) -> bool {
        self.status == "qualified"
    }
}

#[derive(Serialize, Deserialize)]
struct ProfileFile {
    schema_version: u32,
    generated_by: String,
    profiles: Vec<CoreProfile>,
}

pub const PROFILES_SCHEMA_VERSION: u32 = 1;
const PROFILES_JSON: &str = include_str!("../data/profiles.json");

/// Every profile the generator found, qualified or not, in id order.
pub fn profiles() -> &'static [CoreProfile] {
    static CACHE: OnceLock<Vec<CoreProfile>> = OnceLock::new();
    CACHE.get_or_init(|| {
        let file: ProfileFile = serde_json::from_str(PROFILES_JSON).expect("mbcore/data/profiles.json is valid");
        assert_eq!(file.schema_version, PROFILES_SCHEMA_VERSION, "profiles.json schema");
        file.profiles
    })
}

pub fn profile(id: &str) -> Option<&'static CoreProfile> {
    profiles().iter().find(|p| p.id == id)
}

/// Serialize a generated set in the committed file layout.
pub fn profiles_json(profiles: &[CoreProfile]) -> String {
    let file = ProfileFile {
        schema_version: PROFILES_SCHEMA_VERSION,
        generated_by: "mbgen profiles (mbcore::profile)".into(),
        profiles: profiles.to_vec(),
    };
    let mut text = serde_json::to_string_pretty(&file).expect("profiles serialize");
    text.push('\n');
    text
}

// ---- Reader -----------------------------------------------------------------

fn strip_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'/' {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
        } else if bytes[i] == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'*' {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i += 2;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

/// Index of the delimiter closing the one at `open`, honouring (), {}, [].
fn matching_close(s: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    for (i, &b) in s.iter().enumerate().skip(open) {
        match b {
            b'(' | b'{' | b'[' => depth += 1,
            b')' | b'}' | b']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

/// Split on top-level commas.
fn split_top(s: &str) -> Vec<&str> {
    let bytes = s.as_bytes();
    let mut depth = 0i32;
    let mut start = 0;
    let mut out = Vec::new();
    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'(' | b'{' | b'[' => depth += 1,
            b')' | b'}' | b']' => depth -= 1,
            b',' if depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    let tail = &s[start..];
    if !tail.trim().is_empty() {
        out.push(tail);
    }
    out
}

fn is_ident(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => chars.all(|c| c.is_ascii_alphanumeric() || c == '_'),
        _ => false,
    }
}

/// `N'b…`, `N'd…`, `N'h…` sized literals that fit in i64; anything wider or
/// with x/z stays unresolved.
fn sized_literal(e: &str) -> Option<i64> {
    let (width, rest) = e.split_once('\'')?;
    if !width.chars().all(|c| c.is_ascii_digit()) || width.is_empty() {
        return None;
    }
    let mut chars = rest.chars();
    let radix = match chars.next()? {
        'b' | 'B' => 2,
        'd' | 'D' => 10,
        'h' | 'H' => 16,
        'o' | 'O' => 8,
        _ => return None,
    };
    let digits: String = chars.filter(|c| *c != '_').collect();
    i64::from_str_radix(&digits, radix).ok()
}

fn eval(expr: &str, params: &BTreeMap<String, SvValue>) -> SvValue {
    let e = expr.trim();
    if e.is_empty() {
        return SvValue::Unresolved(String::new());
    }
    if let Ok(n) = e.replace('_', "").parse::<i64>() {
        return SvValue::Int(n);
    }
    if let Some(n) = sized_literal(e) {
        return SvValue::Int(n);
    }
    if let Some(inner) = e.strip_prefix("'{") {
        if e.ends_with('}') {
            return SvValue::Nested(parse_struct(&inner[..inner.len() - 1], params));
        }
    }
    // `TYPE'(expr)` casts: bit' yields a flag; every other type keeps the inner
    // value (unsigned', int', ai_cfg_t', …). An identifier type is a cast.
    if let Some((ty, rest)) = e.split_once("'(") {
        let ty = ty.trim();
        if rest.ends_with(')') && (is_ident(ty) || ty.starts_with("config_pkg::")) {
            let inner = eval(&rest[..rest.len() - 1], params);
            return match (ty, inner) {
                ("bit", SvValue::Int(n)) => SvValue::Flag(n != 0),
                (t, SvValue::Flag(b)) if t != "bit" => SvValue::Int(b as i64),
                (_, v) => v,
            };
        }
    }
    if let Some(name) = e.strip_prefix("config_pkg::") {
        if is_ident(name) {
            // A shared constant published by config_pkg.sv resolves to its
            // value when the generator seeded it; otherwise it is an enum.
            return match params.get(e) {
                Some(v) => v.clone(),
                None => SvValue::Enum(name.to_string()),
            };
        }
    }
    if is_ident(e) {
        return match params.get(e) {
            Some(v) => v.clone(),
            None => SvValue::Unresolved(e.to_string()),
        };
    }
    SvValue::Unresolved(e.to_string())
}

fn parse_struct(body: &str, params: &BTreeMap<String, SvValue>) -> BTreeMap<String, SvValue> {
    let mut out = BTreeMap::new();
    for item in split_top(body) {
        let Some((name, value)) = item.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if !is_ident(name) {
            continue;
        }
        out.insert(name.to_string(), eval(value, params));
    }
    out
}

/// Read one package. Never fails: unknown shapes become `Unresolved`.
pub fn read_config_pkg(text: &str) -> ConfigFacts {
    read_config_pkg_with(text, &BTreeMap::new())
}

/// Constants a target package may reference from the shared `config_pkg.sv`
/// (e.g. `config_pkg::AiCfgIsland`), keyed as `config_pkg::NAME`.
pub fn shared_constants(config_pkg_text: &str) -> BTreeMap<String, SvValue> {
    read_config_pkg(config_pkg_text)
        .localparams
        .into_iter()
        .map(|(k, v)| (format!("config_pkg::{k}"), v))
        .collect()
}

/// Read one package with shared constants pre-seeded.
pub fn read_config_pkg_with(text: &str, shared: &BTreeMap<String, SvValue>) -> ConfigFacts {
    let clean = strip_comments(text);
    let mut facts = ConfigFacts::default();
    facts.localparams = shared.clone();
    if let Some(p) = clean.find("package ") {
        let rest = &clean[p + 8..];
        facts.package = rest.split(|c: char| c == ';' || c.is_whitespace()).next().unwrap_or("").to_string();
    }
    let bytes = clean.as_bytes();
    let mut search = 0;
    while let Some(rel) = clean[search..].find("localparam") {
        let start = search + rel;
        let after = start + "localparam".len();
        // Statement ends at the first ';' at nesting depth 0.
        let mut depth = 0i32;
        let mut end = None;
        for (i, &b) in bytes.iter().enumerate().skip(after) {
            match b {
                b'(' | b'{' | b'[' => depth += 1,
                b')' | b'}' | b']' => depth -= 1,
                b';' if depth == 0 => {
                    end = Some(i);
                    break;
                }
                _ => {}
            }
        }
        let Some(end) = end else { break };
        let stmt = &clean[after..end];
        search = end + 1;
        let Some(eq) = stmt.find('=') else { continue };
        let lhs = stmt[..eq].trim();
        let name = lhs.split_whitespace().last().unwrap_or("");
        if !is_ident(name) {
            continue;
        }
        let value = eval(&stmt[eq + 1..], &facts.localparams);
        if let SvValue::Nested(fields) = &value {
            if fields.contains_key("XLEN") {
                facts.cfg = fields.clone();
            }
        }
        facts.localparams.insert(name.to_string(), value);
    }
    // Shared constants were only an evaluation context; do not report them
    // as this package's own localparams.
    for key in shared.keys() {
        facts.localparams.remove(key);
    }
    let _ = matching_close; // kept for struct-literal callers that need it
    facts
}

// ---- Profile derivation ---------------------------------------------------

fn group_for(id: &str) -> &'static str {
    if id == "g6lc64_ai" || id.ends_with("_ai") {
        "ai"
    } else if id.contains("ooo") {
        "ooo"
    } else if id.contains("smt2") {
        "smt"
    } else if id.contains("stream") {
        "stream"
    } else if id.contains("server") {
        "server"
    } else {
        "baseline"
    }
}

/// ISA letters in canonical order, from the extension flags.
const ISA_LETTERS: &[(&str, &str)] = &[
    ("RVA", "a"),
    ("RVF", "f"),
    ("RVD", "d"),
    ("RVC", "c"),
    ("RVB", "b"),
    ("RVV", "v"),
    ("RVH", "h"),
];

/// Build a profile. Every field is read from the facts; a missing or
/// unresolved field is recorded and marks the profile unresolved.
pub fn profile_from_facts(id: &str, facts: &ConfigFacts, source: ProfileSource) -> CoreProfile {
    let mut unresolved = Vec::new();
    let int = |name: &str, unresolved: &mut Vec<String>| -> Option<u32> {
        match facts.cfg.get(name) {
            Some(SvValue::Int(n)) if *n >= 0 => Some(*n as u32),
            Some(SvValue::Flag(b)) => Some(*b as u32),
            other => {
                unresolved.push(format!("{name}={}", describe(other)));
                None
            }
        }
    };
    let flag = |name: &str, unresolved: &mut Vec<String>| -> Option<bool> {
        match facts.cfg.get(name) {
            Some(SvValue::Flag(b)) => Some(*b),
            Some(SvValue::Int(n)) => Some(*n != 0),
            other => {
                unresolved.push(format!("{name}={}", describe(other)));
                None
            }
        }
    };
    let xlen = int("XLEN", &mut unresolved);
    let cores = int("NrCores", &mut unresolved);
    let threads = int("NrHarts", &mut unresolved);
    let axi = int("AxiDataWidth", &mut unresolved);
    let ooo = flag("OoOEn", &mut unresolved);
    let l2 = flag("L2En", &mut unresolved);
    let l3 = flag("L3En", &mut unresolved);
    // AI plane present ⇔ AiCfg.MatrixEn. `ai_cfg_t'(0)` (AiCfgOff) is the
    // all-zero struct. A shared constant unresolved because config_pkg.sv was
    // not read stays unresolved — never guessed from its name.
    let ai = match facts.cfg.get("AiCfg") {
        Some(SvValue::Nested(f)) => match f.get("MatrixEn") {
            Some(SvValue::Flag(b)) => Some(*b),
            Some(SvValue::Int(n)) => Some(*n != 0),
            other => {
                unresolved.push(format!("AiCfg.MatrixEn={}", describe(other)));
                None
            }
        },
        Some(SvValue::Int(0)) => Some(false),
        other => {
            unresolved.push(format!("AiCfg={}", describe(other)));
            None
        }
    };
    let mut isa = format!("rv{}i", xlen.unwrap_or(0));
    // M is not a config bit in CVA6; the multiplier is always present.
    isa.push('m');
    for (field, letter) in ISA_LETTERS {
        match flag(field, &mut unresolved) {
            Some(true) => isa.push_str(letter),
            Some(false) => {}
            None => isa.push('?'),
        }
    }
    let status = if unresolved.is_empty() { "qualified" } else { "unresolved" };
    let (cores, threads) = (cores.unwrap_or(0), threads.unwrap_or(0));
    CoreProfile {
        id: id.to_string(),
        group: group_for(id).to_string(),
        isa,
        xlen: xlen.unwrap_or(0),
        cores,
        threads,
        harts: cores * threads,
        ooo: ooo.unwrap_or(false),
        l2: l2.unwrap_or(false),
        l3: l3.unwrap_or(false),
        ai: ai.unwrap_or(false),
        axi_bits: axi.unwrap_or(0),
        status: status.to_string(),
        unresolved,
        source,
    }
}

fn describe(v: Option<&SvValue>) -> String {
    match v {
        None => "missing".into(),
        Some(SvValue::Unresolved(s)) => format!("unresolved({s})"),
        Some(SvValue::Enum(e)) => format!("enum({e})"),
        Some(SvValue::Nested(_)) => "struct".into(),
        Some(SvValue::Int(n)) => n.to_string(),
        Some(SvValue::Flag(b)) => b.to_string(),
    }
}

/// `<id>` for `<id>_config_pkg.sv`, or None for files that are not targets.
pub fn target_id_from_filename(name: &str) -> Option<&str> {
    let id = name.strip_suffix("_config_pkg.sv")?;
    if id.starts_with("cv32") || id.starts_with("cv64") || id.starts_with("g6lc") {
        Some(id)
    } else {
        None
    }
}

/// Generate the profile set from a `core/include`-shaped directory.
pub fn generate_from_dir(dir: &std::path::Path, repo_relative_prefix: &str) -> std::io::Result<Vec<CoreProfile>> {
    let mut out = Vec::new();
    let shared = match std::fs::read_to_string(dir.join("config_pkg.sv")) {
        Ok(text) => shared_constants(&text),
        Err(_) => BTreeMap::new(),
    };
    let mut entries: Vec<_> = std::fs::read_dir(dir)?.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let name = entry.file_name();
        let Some(id) = target_id_from_filename(&name.to_string_lossy()).map(str::to_string) else {
            continue;
        };
        let text = std::fs::read_to_string(entry.path())?;
        let facts = read_config_pkg_with(&text, &shared);
        let source = ProfileSource {
            path: format!("{repo_relative_prefix}{}", name.to_string_lossy()),
            sha256: sha256_hex(text.as_bytes()),
        };
        out.push(profile_from_facts(&id, &facts, source));
    }
    Ok(out)
}

// ---- SHA-256 (FIPS 180-4), dependency-free -----------------------------------

pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
        0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bit_len = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
// a leading comment
package g6lc64_demo_config_pkg;
  localparam CVA6ConfigXlen = 64;
  localparam CVA6ConfigRVF = 1;
  localparam CVA6ConfigRVD = 1;
  localparam CVA6ConfigVExtEn = 0;  // must stay 0
  localparam int unsigned CVA6ConfigAxiDataWidth = 128;
  localparam config_pkg::ai_cfg_t ai_cfg = '{
      MatrixEn: bit'(1),
      AccelEn: bit'(0),
      TileM: unsigned'(8)
  };
  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      RVA: bit'(1),
      RVF: bit'(CVA6ConfigRVF),
      RVD: bit'(CVA6ConfigRVD),
      RVC: bit'(1),
      RVB: bit'(0),
      RVV: bit'(CVA6ConfigVExtEn),
      RVH: bit'(1),
      AxiDataWidth: unsigned'(CVA6ConfigAxiDataWidth),
      AiCfg: ai_cfg,
      HaltAddress: 64'h800,
      PMPCfgRstVal: {64{64'h0}},
      L2En: bit'(1),
      NrHarts: unsigned'(2),
      NrCores: unsigned'(4),
      OoOEn: bit'(1),
      L3En: bit'(0),
      SmtPolicy: config_pkg::SMT_HYBRID
  };
endpackage
"#;

    fn src() -> ProfileSource {
        ProfileSource { path: "core/include/demo_config_pkg.sv".into(), sha256: sha256_hex(SAMPLE.as_bytes()) }
    }

    #[test]
    fn the_five_forms_read_and_odd_shapes_stay_unresolved() {
        let facts = read_config_pkg(SAMPLE);
        assert_eq!(facts.package, "g6lc64_demo_config_pkg");
        assert_eq!(facts.cfg.get("XLEN"), Some(&SvValue::Int(64)));
        assert_eq!(facts.cfg.get("RVF"), Some(&SvValue::Flag(true)));
        assert_eq!(facts.cfg.get("RVV"), Some(&SvValue::Flag(false)));
        assert_eq!(facts.cfg.get("AxiDataWidth"), Some(&SvValue::Int(128)));
        assert_eq!(facts.cfg.get("SmtPolicy"), Some(&SvValue::Enum("SMT_HYBRID".into())));
        assert_eq!(facts.cfg.get("HaltAddress"), Some(&SvValue::Int(0x800)));
        assert!(matches!(facts.cfg.get("PMPCfgRstVal"), Some(SvValue::Unresolved(_))));
        match facts.cfg.get("AiCfg") {
            Some(SvValue::Nested(f)) => assert_eq!(f.get("MatrixEn"), Some(&SvValue::Flag(true))),
            other => panic!("AiCfg {other:?}"),
        }
    }

    #[test]
    fn a_profile_carries_the_real_topology_and_its_source() {
        let p = profile_from_facts("g6lc64_demo_ooo", &read_config_pkg(SAMPLE), src());
        assert_eq!(p.status, "qualified", "{:?}", p.unresolved);
        assert_eq!((p.cores, p.threads, p.harts), (4, 2, 8));
        assert_eq!(p.isa, "rv64imafdch");
        assert!(p.ooo && p.l2 && !p.l3 && p.ai);
        assert_eq!(p.axi_bits, 128);
        assert_eq!(p.group, "ooo");
        assert_eq!(p.source.sha256.len(), 64);
    }

    #[test]
    fn a_missing_or_odd_field_blocks_qualification_instead_of_defaulting() {
        let text = SAMPLE.replace("NrCores: unsigned'(4)", "NrCores: unsigned'(CVA6ConfigNrCores)");
        let p = profile_from_facts("g6lc64_demo", &read_config_pkg(&text), src());
        assert_eq!(p.status, "unresolved");
        assert!(p.unresolved.iter().any(|u| u.starts_with("NrCores=unresolved(")), "{:?}", p.unresolved);
        assert_eq!(p.harts, 0, "an unresolved count must not look like a real one");
    }

    const SHARED: &str = r#"
package config_pkg;
  localparam ai_cfg_t AiCfgOff = ai_cfg_t'(0);
  localparam ai_cfg_t AiCfgIsland = '{
    MatrixEn: 1'b1,
    AccelEn: 1'b0,
    QosClasses: 32'd2
  };
endpackage
"#;

    #[test]
    fn shared_config_pkg_constants_resolve_instead_of_being_guessed_from_their_name() {
        let shared = shared_constants(SHARED);
        let off = SAMPLE.replace("AiCfg: ai_cfg", "AiCfg: config_pkg::AiCfgOff");
        let p = profile_from_facts("cv64a6_demo", &read_config_pkg_with(&off, &shared), src());
        assert!(p.is_qualified(), "{:?}", p.unresolved);
        assert!(!p.ai);
        assert_eq!(p.group, "baseline");
        let island = SAMPLE.replace("AiCfg: ai_cfg", "AiCfg: config_pkg::AiCfgIsland");
        let p = profile_from_facts("g6lc64_demo_l3_ai", &read_config_pkg_with(&island, &shared), src());
        assert!(p.is_qualified(), "{:?}", p.unresolved);
        assert!(p.ai);
        assert_eq!(p.group, "ai");
        // Without the shared file the same package must stay unresolved.
        let p = profile_from_facts("g6lc64_demo_l3_ai", &read_config_pkg(&island), src());
        assert_eq!(p.status, "unresolved");
        assert!(p.unresolved.iter().any(|u| u == "AiCfg=enum(AiCfgIsland)"), "{:?}", p.unresolved);
        // Shared constants are context, not the target's own localparams.
        assert!(!read_config_pkg_with(&island, &shared).localparams.contains_key("config_pkg::AiCfgIsland"));
    }

    #[test]
    fn sized_literals_read() {
        assert_eq!(sized_literal("1'b1"), Some(1));
        assert_eq!(sized_literal("32'd2"), Some(2));
        assert_eq!(sized_literal("64'h800"), Some(0x800));
        assert_eq!(sized_literal("8'b1010_1010"), Some(0xAA));
        assert_eq!(sized_literal("1'bx"), None);
        assert_eq!(sized_literal("abc"), None);
    }

    #[test]
    fn sha256_matches_the_known_vectors() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn target_ids_come_only_from_real_target_packages() {
        assert_eq!(target_id_from_filename("g6lc64_smt2_config_pkg.sv"), Some("g6lc64_smt2"));
        assert_eq!(target_id_from_filename("cv32a60x_config_pkg.sv"), Some("cv32a60x"));
        assert_eq!(target_id_from_filename("build_config_pkg.sv"), None);
        assert_eq!(target_id_from_filename("cva6_config_pkg.sv"), None);
        assert_eq!(target_id_from_filename("work-ver-smt2-fw64-B_config_pkg.sv"), None);
        assert_eq!(target_id_from_filename("config_pkg.sv"), None);
    }

    #[test]
    fn committed_profiles_load_and_known_topologies_are_right() {
        let all = profiles();
        assert!(all.len() >= 15);
        let server = profile("g6lc64_ooo_server").expect("ooo_server");
        assert_eq!((server.cores, server.threads, server.harts), (4, 2, 8));
        let smt2 = profile("g6lc64_smt2").expect("smt2");
        assert_eq!((smt2.cores, smt2.threads), (1, 2));
        let v = profile("g6lc64_server_math_v").expect("server_math_v");
        assert_eq!((v.cores, v.threads), (2, 2));
        assert!(v.isa.contains('v'));
        assert!(all.iter().all(|p| p.source.sha256.len() == 64));
    }

    /// The committed data file must equal a fresh read of `core/include`
    /// whenever the monorepo is present. On drift this fails with the command
    /// that regenerates the file; in a standalone checkout it is skipped.
    #[test]
    fn committed_profiles_agree_with_core_include() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../core/include");
        if !dir.is_dir() {
            eprintln!("skipped: {} not present (standalone checkout)", dir.display());
            return;
        }
        let fresh = generate_from_dir(&dir, "core/include/").unwrap();
        let committed = profiles();
        let fresh_ids: Vec<_> = fresh.iter().map(|p| p.id.as_str()).collect();
        let committed_ids: Vec<_> = committed.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(
            fresh_ids, committed_ids,
            "profile set drifted; run: mbgen profiles --core-include ../core/include --out mbcore/data/profiles.json"
        );
        for (f, c) in fresh.iter().zip(committed.iter()) {
            assert_eq!(f, c, "profile {} drifted from {}; regenerate mbcore/data/profiles.json", f.id, f.source.path);
        }
    }
}
