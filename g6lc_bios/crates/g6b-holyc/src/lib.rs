// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Fast HolyC subset used to initialize rust-generated ZealOS.
//!
//! Parses generated `KMain.ZC` / `Adam.ZC` / `PostBoot.ZC` and interprets them
//! on the host. RISC-V ISel (`isel`) is a Target wrapper around `g6b-asm` IR
//! (purpose-tagged nodes, not string `.S`). RVV only when the BoardSpec says so.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_http::Router;

pub mod isel;

/// Result of one REPL line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplResult {
    /// Function/Print output (may be empty).
    Output(String),
    /// Client asked to hang up.
    Exit,
}

/// Parsed HolyC program plus post-boot flags.
#[derive(Debug, Clone)]
pub struct Program {
    fns: BTreeMap<String, Vec<Stmt>>,
    consts: BTreeMap<String, i64>,
    /// Section names that become write-disabled after [`Program::linux_handoff`].
    pub immutable: Vec<String>,
    /// Set by the `LinuxHandoff` builtin.
    pub linux_booted: bool,
    /// Last power verb (`reboot` / `shutdown` / `wakeup`).
    pub last_power: Option<String>,
    /// Print `NET-DELEGATE` on handoff (adapter released to Linux).
    pub net_delegates: bool,
    /// Print `LOOPBACK-MBOX` on handoff (sideband stays).
    pub loopback: bool,
    /// Print `SSH-HOLYC` when the ZealOS CLI KVM face is live.
    pub ssh_holyc: bool,
    /// Shared kernel HTTP router (HolyC ≡ JS).
    pub router: Router,
}

#[derive(Debug, Clone)]
enum Stmt {
    Call { name: String, args: Vec<Expr> },
}

#[derive(Debug, Clone)]
enum Expr {
    Int(i64),
    Str(String),
    Var(String),
}

impl Default for Program {
    fn default() -> Self {
        Self {
            fns: BTreeMap::new(),
            consts: BTreeMap::new(),
            immutable: vec!["config".into(), "keys".into(), "boot-policy".into()],
            linux_booted: false,
            last_power: None,
            net_delegates: false,
            loopback: false,
            ssh_holyc: false,
            router: Router::default(),
        }
    }
}

impl Program {
    /// Parse a HolyC subset document.
    pub fn parse(src: &str) -> Result<Self, String> {
        let mut p = Program::default();
        let body = strip_comments(src);
        let mut rest = body.as_str();
        while !rest.trim().is_empty() {
            skip_ws(&mut rest);
            if rest.is_empty() {
                break;
            }
            if rest.starts_with("#include") {
                skip_line(&mut rest);
                continue;
            }
            if rest.starts_with("#define") {
                parse_define(&mut p, &mut rest)?;
                continue;
            }
            parse_fn(&mut p, &mut rest)?;
        }
        Ok(p)
    }

    /// Run `Adam` if present, else `KMain`.
    pub fn start(&mut self) -> Result<String, String> {
        if self.fns.contains_key("Adam") {
            self.call("Adam")
        } else if self.fns.contains_key("KMain") {
            self.call("KMain")
        } else if self.fns.contains_key("HolycInit") {
            self.call("HolycInit")
        } else {
            Ok(String::new())
        }
    }

    /// Invoke a named function (or builtin).
    pub fn call(&mut self, name: &str) -> Result<String, String> {
        self.call_args(name, &[])
    }

    fn call_args(&mut self, name: &str, args: &[Expr]) -> Result<String, String> {
        if let Some(out) = self.builtin(name, args)? {
            return Ok(out);
        }
        let body = self
            .fns
            .get(name)
            .cloned()
            .ok_or_else(|| format!("unknown fn {name}"))?;
        let mut out = String::new();
        for s in body {
            match s {
                Stmt::Call {
                    name: inner,
                    args: ia,
                } => out.push_str(&self.call_args(&inner, &ia)?),
            }
        }
        Ok(out)
    }

    fn builtin(&mut self, name: &str, args: &[Expr]) -> Result<Option<String>, String> {
        match name {
            "Print" => {
                let mut s = String::new();
                for a in args {
                    s.push_str(&self.eval_str(a));
                }
                Ok(Some(s))
            }
            "Reboot" => {
                self.last_power = Some("reboot".into());
                Ok(Some("POWER-REBOOT\n".into()))
            }
            "Shutdown" => {
                self.last_power = Some("shutdown".into());
                Ok(Some("POWER-SHUTDOWN\n".into()))
            }
            "Wakeup" => {
                self.last_power = Some("wakeup".into());
                Ok(Some("POWER-WAKEUP\n".into()))
            }
            "LinuxHandoff" => {
                self.linux_booted = true;
                let mut s = String::from("POSTBOOT-LIVE\n");
                if self.net_delegates {
                    s.push_str("NET-DELEGATE\n");
                }
                if self.loopback {
                    s.push_str("LOOPBACK-MBOX\n");
                }
                if self.ssh_holyc {
                    s.push_str("SSH-HOLYC\n");
                }
                Ok(Some(s))
            }
            "ViewSection" => {
                let n = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("VIEW {n}\n")))
            }
            "WriteSection" => {
                let n = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                if self.linux_booted && self.immutable.iter().any(|i| i == &n) {
                    Ok(Some(format!("IMMUTABLE-DISABLED {n}\n")))
                } else {
                    Ok(Some(format!("WRITE {n}\n")))
                }
            }
            "TimerInit" => Ok(Some("TIMER-READY SBI-TIME\n".into())),
            "TlsHandshake" => Ok(Some("TLS-HELLO\n".into())),
            "TlsServerHello" => {
                let h = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "localhost".into());
                let ch = g6b_tls::client_hello(&h);
                let sh = g6b_tls::server_handshake(&ch)?;
                Ok(Some(format!(
                    "TLS-SERVERHELLO host={h} bytes={}\n",
                    sh.len()
                )))
            }
            "HttpsServe" => Ok(Some("HTTPS-SERVE files\n".into())),
            "FileServe" | "HttpFile" => {
                let path = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "/ui/index.html".into());
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!(
                    "FILE-SERVE {} {} bytes={}\n",
                    resp.status,
                    path,
                    resp.body.len()
                )))
            }
            "HttpsGet" => {
                let u = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("{}\n", g6b_tls::https_get(&u))))
            }
            "TlsClientHello" => {
                let h = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "localhost".into());
                let hello = g6b_tls::client_hello(&h);
                Ok(Some(format!(
                    "TLS-CLIENTHELLO host={h} bytes={} web={}\n",
                    hello.len(),
                    g6b_tls::is_web_compatible(&hello)
                )))
            }
            "CertParse" => {
                let _ = args;
                Ok(Some("CERT-OK algo=rsa\n".into()))
            }
            "RsaVerify" => Ok(Some("RSA-VERIFY PKCS1-SHA256\n".into())),
            "EcdsaVerify" => Ok(Some("ECDSA-VERIFY P256-SHA256\n".into())),
            "NetOpenPort" => {
                let kind = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                Ok(Some(format!("NET-OPEN {kind}\n")))
            }
            "RegisterEndpoint" => {
                let path = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                let method = args
                    .get(1)
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "GET".into());
                self.router.insert(
                    &method,
                    &path,
                    "holyc",
                    format!("{{\"origin\":\"holyc\",\"path\":\"{path}\"}}"),
                );
                Ok(Some(format!("EP-REG {method} {path}\n")))
            }
            "HttpHandle" => {
                let raw = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                match self.router.handle_bytes(raw.as_bytes()) {
                    Ok(b) => Ok(Some(format!("HTTP-OK bytes={}\n", b.len()))),
                    Err(e) => Ok(Some(format!("HTTP-ERR {e}\n"))),
                }
            }
            "KernelGet" => {
                let path = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                let path = if path.starts_with('/') {
                    path
                } else {
                    format!("/bios/{path}")
                };
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!(
                    "KERNEL-GET {} {}\n",
                    resp.status,
                    resp.body_str()
                )))
            }
            "SettingsExport" => {
                let via = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "uart".into());
                Ok(Some(format!("SETTINGS-EXPORT via={via}\n")))
            }
            "SettingsImport" => {
                let via = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "uart".into());
                Ok(Some(format!("SETTINGS-IMPORT via={via}\n")))
            }
            "FlashImage" => {
                let img = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "openwrt".into());
                Ok(Some(format!("FLASH-IMAGE {img}\n")))
            }
            "BiosUpdate" => Ok(Some("BIOS-UPDATE self\n".into())),
            "UsbKey" => {
                let op = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "present".into());
                Ok(Some(format!("USB-KEY {op}\n")))
            }
            "UsbLs" => {
                let kind = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "flash".into());
                Ok(Some(format!("USB-LS {kind}\n")))
            }
            "UsbFlash" => {
                let name = args
                    .first()
                    .map(|a| self.eval_str(a))
                    .unwrap_or_else(|| "openwrt.bin".into());
                Ok(Some(format!("USB-FLASH fat32 {name}\n")))
            }
            "Menu" | "MenuCpu" | "MenuUncore" | "MenuMemory" | "MenuBoot" => {
                let path = match name {
                    "MenuCpu" => "/bios/menu/cpu".into(),
                    "MenuUncore" => "/bios/menu/uncore".into(),
                    "MenuMemory" => "/bios/menu/memory".into(),
                    "MenuBoot" => "/bios/menu/boot".into(),
                    _ => {
                        let id = args.first().map(|a| self.eval_str(a)).unwrap_or_default();
                        if id.is_empty() {
                            "/bios/menu".into()
                        } else {
                            format!("/bios/menu/{id}")
                        }
                    }
                };
                let resp = self.router.fetch_get(&path);
                Ok(Some(format!("MENU {} {}\n", resp.status, resp.body_str())))
            }
            _ => Ok(None),
        }
    }

    fn eval_str(&self, e: &Expr) -> String {
        match e {
            Expr::Str(s) => unescape(s),
            Expr::Int(i) => i.to_string(),
            Expr::Var(v) => self
                .consts
                .get(v)
                .map(|n| n.to_string())
                .unwrap_or_default(),
        }
    }

    /// One dual-band REPL line. `Exit;` hangs up.
    pub fn repl(&mut self, line: &str) -> Result<ReplResult, String> {
        let t = line.trim();
        if t.is_empty() {
            return Ok(ReplResult::Output(String::new()));
        }
        if t.eq_ignore_ascii_case("exit")
            || t.eq_ignore_ascii_case("exit;")
            || t.eq_ignore_ascii_case("quit")
            || t.eq_ignore_ascii_case("quit;")
        {
            return Ok(ReplResult::Exit);
        }
        // `Name();` or `Name("arg");`
        let mut rest = t.trim_end_matches(';').trim();
        skip_ws(&mut rest);
        let name = take_ident(&mut rest).ok_or_else(|| format!("bad repl line: {t}"))?;
        skip_ws(&mut rest);
        let args = if rest.starts_with('(') {
            parse_arg_list(&mut rest)?
        } else {
            Vec::new()
        };
        let out = self.call_args(&name, &args)?;
        Ok(ReplResult::Output(out))
    }
}

/// Parse + run generated sources (Adam/KMain).
pub fn eval_src(src: &str) -> Result<String, String> {
    let mut p = Program::parse(src)?;
    p.start()
}

fn unescape(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some(o) => out.push(o),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn strip_comments(src: &str) -> String {
    let mut out = String::new();
    for line in src.lines() {
        if let Some(i) = line.find("//") {
            out.push_str(&line[..i]);
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

fn skip_ws(rest: &mut &str) {
    *rest = rest.trim_start();
}

fn skip_line(rest: &mut &str) {
    if let Some(i) = rest.find('\n') {
        *rest = &rest[i + 1..];
    } else {
        *rest = "";
    }
}

fn take_ident(rest: &mut &str) -> Option<String> {
    skip_ws(rest);
    let s = *rest;
    let mut n = 0;
    for c in s.chars() {
        if n == 0 {
            if c.is_ascii_alphabetic() || c == '_' {
                n += c.len_utf8();
            } else {
                break;
            }
        } else if c.is_ascii_alphanumeric() || c == '_' {
            n += c.len_utf8();
        } else {
            break;
        }
    }
    if n == 0 {
        return None;
    }
    let id = s[..n].to_string();
    *rest = &s[n..];
    Some(id)
}

fn parse_define(p: &mut Program, rest: &mut &str) -> Result<(), String> {
    *rest = rest.trim_start_matches("#define").trim_start();
    let name = take_ident(rest).ok_or("bad #define")?;
    skip_ws(rest);
    let mut n = 0i64;
    let s = *rest;
    let mut i = 0;
    while s
        .as_bytes()
        .get(i)
        .map(|b| b.is_ascii_digit())
        .unwrap_or(false)
    {
        n = n * 10 + i64::from(s.as_bytes()[i] - b'0');
        i += 1;
    }
    p.consts.insert(name, n);
    skip_line(rest);
    Ok(())
}

fn parse_fn(p: &mut Program, rest: &mut &str) -> Result<(), String> {
    skip_ws(rest);
    // type: U0 / INative / U8 / I64
    let _ty = take_ident(rest).ok_or("expected type")?;
    skip_ws(rest);
    let name = take_ident(rest).ok_or("expected fn name")?;
    skip_ws(rest);
    if !rest.starts_with('(') {
        return Err(format!("expected ( after {name}"));
    }
    if let Some(i) = rest.find(')') {
        *rest = rest[i + 1..].trim_start();
    }
    skip_ws(rest);
    if !rest.starts_with('{') {
        return Err(format!("expected {{ for {name}"));
    }
    *rest = &rest[1..];
    let mut stmts = Vec::new();
    loop {
        skip_ws(rest);
        if rest.starts_with('}') {
            *rest = &rest[1..];
            break;
        }
        if rest.is_empty() {
            return Err(format!("unterminated fn {name}"));
        }
        stmts.push(parse_stmt(rest)?);
    }
    p.fns.insert(name, stmts);
    Ok(())
}

fn parse_stmt(rest: &mut &str) -> Result<Stmt, String> {
    skip_ws(rest);
    let name = take_ident(rest).ok_or("expected stmt")?;
    skip_ws(rest);
    let args = if rest.starts_with('(') {
        parse_arg_list(rest)?
    } else {
        Vec::new()
    };
    skip_ws(rest);
    if rest.starts_with(';') {
        *rest = &rest[1..];
    }
    Ok(Stmt::Call { name, args })
}

fn parse_arg_list(rest: &mut &str) -> Result<Vec<Expr>, String> {
    if !rest.starts_with('(') {
        return Ok(Vec::new());
    }
    *rest = &rest[1..];
    let mut args = Vec::new();
    loop {
        skip_ws(rest);
        if rest.starts_with(')') {
            *rest = &rest[1..];
            break;
        }
        if rest.is_empty() {
            return Err("unterminated arg list".into());
        }
        args.push(parse_expr(rest)?);
        skip_ws(rest);
        if rest.starts_with(',') {
            *rest = &rest[1..];
        }
    }
    Ok(args)
}

fn parse_expr(rest: &mut &str) -> Result<Expr, String> {
    skip_ws(rest);
    if rest.starts_with('"') {
        *rest = &rest[1..];
        let mut s = String::new();
        let bytes = rest.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'\\' && i + 1 < bytes.len() {
                s.push('\\');
                s.push(bytes[i + 1] as char);
                i += 2;
                continue;
            }
            if bytes[i] == b'"' {
                *rest = &rest[i + 1..];
                return Ok(Expr::Str(s));
            }
            s.push(bytes[i] as char);
            i += 1;
        }
        return Err("unterminated string".into());
    }
    if rest
        .as_bytes()
        .first()
        .map(|b| b.is_ascii_digit())
        .unwrap_or(false)
    {
        let mut n = 0i64;
        let s = *rest;
        let mut i = 0;
        while s
            .as_bytes()
            .get(i)
            .map(|b| b.is_ascii_digit())
            .unwrap_or(false)
        {
            n = n * 10 + i64::from(s.as_bytes()[i] - b'0');
            i += 1;
        }
        *rest = &s[i..];
        return Ok(Expr::Int(n));
    }
    let id = take_ident(rest).ok_or("expected expr")?;
    Ok(Expr::Var(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kmain_fast_init() {
        let src = r#"
U0 HolycInit() { Print("HOLYC-READY\n"); }
U0 UiBoot() { Print("UI-BOOT\n"); }
U0 KMain() { Print("G6LC-BIOS\n"); HolycInit(); UiBoot(); }
U0 Adam() { KMain(); }
"#;
        let out = eval_src(src).unwrap();
        assert!(out.contains("G6LC-BIOS"), "{out}");
        assert!(out.contains("HOLYC-READY"), "{out}");
        assert!(out.contains("UI-BOOT"), "{out}");
    }

    #[test]
    fn postboot_immutable_write_disabled() {
        let mut p = Program::parse(
            r#"
U0 LinuxHandoff() { Print("x"); }
U0 WriteSection(U8 *name) { Print("x"); }
"#,
        )
        .unwrap();
        let _ = p.call("LinuxHandoff").unwrap();
        assert!(p.linux_booted);
        let w = p
            .call_args("WriteSection", &[Expr::Str("config".into())])
            .unwrap();
        assert!(w.contains("IMMUTABLE-DISABLED"), "{w}");
        let v = p
            .call_args("ViewSection", &[Expr::Str("config".into())])
            .unwrap();
        assert!(v.contains("VIEW config"), "{v}");
    }

    #[test]
    fn repl_power_and_exit() {
        let mut p = Program::default();
        match p.repl("Reboot();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("POWER-REBOOT"), "{s}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(p.last_power.as_deref(), Some("reboot"));
        assert_eq!(p.repl("Exit;").unwrap(), ReplResult::Exit);
    }

    #[test]
    fn https_get_stub() {
        let mut p = Program::default();
        match p.repl(r#"HttpsGet("https://gsys.dev/");"#).unwrap() {
            ReplResult::Output(s) => {
                assert!(s.contains("HTTPS-GET"), "{s}");
                assert!(s.contains("gsys.dev"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        match p.repl("TlsHandshake();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("TLS-HELLO"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"NetOpenPort("bios-https");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("NET-OPEN bios-https"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"TlsClientHello("gsys.dev");"#).unwrap() {
            ReplResult::Output(s) => {
                assert!(s.contains("TLS-CLIENTHELLO"), "{s}");
                assert!(s.contains("web=true"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        match p.repl("RsaVerify();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("RSA-VERIFY"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl("EcdsaVerify();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("ECDSA-VERIFY"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl("CertParse();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("CERT-OK"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"TlsServerHello("localhost");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("TLS-SERVERHELLO"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"UsbFlash("openwrt.bin");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("USB-FLASH fat32"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"UsbLs("ntfs");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("USB-LS ntfs"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"FlashImage("openwrt");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("FLASH-IMAGE openwrt"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"SettingsExport("usb");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("SETTINGS-EXPORT via=usb"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p.repl(r#"RegisterEndpoint("/bios/custom");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("EP-REG"), "{s}"),
            other => panic!("{other:?}"),
        }
        match p
            .repl(r#"HttpHandle("GET /bios/custom HTTP/1.1\r\n\r\n");"#)
            .unwrap()
        {
            ReplResult::Output(s) => assert!(s.contains("HTTP-OK"), "{s}"),
            other => panic!("{other:?}"),
        }
    }
}
