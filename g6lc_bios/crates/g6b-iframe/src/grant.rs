// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Nested-iframe embedding grants (P9). postMessage must match origin+nonce.
//! No password in a URL. Child fetches never target parent `/bios/*`.

#![allow(missing_docs)]

/// View-only nested grant. Not a reusable password.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbedGrant {
    pub parent: String,
    pub child: String,
    pub nonce: String,
    pub expires: u64,
}

/// `https://host[:port]` only. Credentials and paths are refused.
pub fn origin_of(url: &str) -> Result<String, String> {
    let url = url.trim();
    if url.contains('@') || url.contains("password=") || url.contains("token=") {
        return Err("iframe: credentials in url".into());
    }
    let rest = url
        .strip_prefix("https://")
        .ok_or("iframe: parent must be https")?;
    let hostport = rest.split('/').next().unwrap_or(rest);
    if hostport.is_empty() || hostport.contains('\\') || hostport.contains('[') {
        return Err("iframe: origin refused".into());
    }
    if let Some((_, p)) = hostport.rsplit_once(':') {
        if p.is_empty() || p.parse::<u16>().ok() == Some(0) {
            return Err("iframe: origin refused".into());
        }
    }
    Ok(format!("https://{hostport}"))
}

/// Nested iframe sandbox. Top-navigation/popups are parent-escape.
pub fn sandbox_allowed(flags: &str) -> Result<(), String> {
    for t in flags.split_whitespace() {
        if t == "allow-top-navigation"
            || t == "allow-top-navigation-by-user-activation"
            || t == "allow-popups"
            || t == "allow-popups-to-escape-sandbox"
        {
            return Err("iframe: sandbox escape".into());
        }
    }
    Ok(())
}

pub fn child_path_allowed(path: &str) -> Result<(), String> {
    let p = path.split('?').next().unwrap_or(path);
    if p.starts_with("/bios/") || p == "/bios" {
        return Err("iframe: child must not target parent /bios/*".into());
    }
    Ok(())
}

impl EmbedGrant {
    pub fn issue(
        parent_url: &str,
        child_url: &str,
        nonce: String,
        now: u64,
        ttl: u64,
    ) -> Result<Self, String> {
        let parent = origin_of(parent_url)?;
        let child = origin_of(child_url)?;
        if parent == child {
            return Err("iframe: parent and child origins must differ".into());
        }
        if nonce.len() < 16 {
            return Err("iframe: nonce".into());
        }
        if ttl == 0 || ttl > 86400 {
            return Err("iframe: ttl".into());
        }
        Ok(Self {
            parent,
            child,
            nonce,
            expires: now.saturating_add(ttl),
        })
    }

    /// Exact source origin and nonce. Expired or hostile parent is refused.
    pub fn verify_post_message(
        &self,
        source_origin: &str,
        nonce: &str,
        now: u64,
    ) -> Result<(), String> {
        if now > self.expires {
            return Err("iframe: grant expired".into());
        }
        let src = origin_of(source_origin)?;
        if src != self.parent {
            return Err("iframe: hostile parent".into());
        }
        if nonce != self.nonce {
            return Err("iframe: nonce".into());
        }
        Ok(())
    }

    /// Third-party cookies / SameSite=None / Partitioned are not a grant.
    /// Unsupported embed flows require a direct login, not an insecure bypass.
    pub fn embed_requires_direct_login(set_cookie: &str) -> bool {
        let s = set_cookie.to_ascii_lowercase();
        s.contains("samesite=none") || s.contains("partitioned")
    }
}

/// Named refusal when partitioned cookies cannot carry the session.
pub fn direct_login_required() -> &'static str {
    "iframe: direct-login required"
}

/// Child may load its own `/bios/login`. Parent `/bios/*` stays refused.
pub fn nested_nav_allowed(grant: &EmbedGrant, url: &str) -> Result<(), String> {
    if url.starts_with("https://") {
        let origin = origin_of(url)?;
        let path = url
            .split_once("://")
            .and_then(|(_, r)| r.split_once('/'))
            .map(|(_, p)| format!("/{p}"))
            .unwrap_or_else(|| "/".into());
        let path = path.split(['?', '#']).next().unwrap_or(&path).to_string();
        if origin == grant.parent && (path == "/bios" || path.starts_with("/bios/")) {
            return Err("iframe: child must not target parent /bios/*".into());
        }
        if origin == grant.child {
            return Ok(());
        }
        return Err("iframe: origin".into());
    }
    child_path_allowed(url.split(['?', '#']).next().unwrap_or(url))
}

/// Parent and child sessions must not share a sid.
pub fn nested_login_isolated(parent_sid: &str, child_sid: &str) -> Result<(), String> {
    if parent_sid.is_empty() || child_sid.is_empty() {
        return Err("iframe: nested login".into());
    }
    if parent_sid == child_sid {
        return Err("iframe: nested login must not reuse parent session".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grant_requires_https_origin_and_nonce() {
        let g = EmbedGrant::issue(
            "https://parent.example:443/app",
            "https://child.example/ui",
            "n".repeat(16),
            10,
            5,
        )
        .unwrap();
        assert_eq!(g.parent, "https://parent.example:443");
        g.verify_post_message("https://parent.example:443/x", &"n".repeat(16), 12)
            .unwrap();
        assert!(g
            .verify_post_message("https://evil.example/", &"n".repeat(16), 12)
            .unwrap_err()
            .contains("hostile"));
        assert!(g
            .verify_post_message("https://parent.example:443/", "wrong-wrong-wrong", 12)
            .unwrap_err()
            .contains("nonce"));
        assert!(g
            .verify_post_message("https://parent.example:443/", &"n".repeat(16), 20)
            .unwrap_err()
            .contains("expired"));
        assert!(origin_of("https://user:pass@h/")
            .unwrap_err()
            .contains("credentials"));
        assert!(origin_of("https://h:0/").unwrap_err().contains("origin"));
        assert!(origin_of("https://h:/").unwrap_err().contains("origin"));
        assert!(child_path_allowed("/bios/flash").is_err());
        assert!(child_path_allowed("/ui/app.wasm").is_ok());
        assert!(EmbedGrant::embed_requires_direct_login(
            "sid=x; SameSite=None; Secure; Partitioned"
        ));
        assert!(!EmbedGrant::embed_requires_direct_login(
            "g6b_sid=x; HttpOnly; Secure; SameSite=Strict; Path=/"
        ));
        assert_eq!(direct_login_required(), "iframe: direct-login required");
        nested_nav_allowed(&g, "https://child.example/bios/login").unwrap();
        assert!(
            nested_nav_allowed(&g, "https://parent.example:443/bios/login")
                .unwrap_err()
                .contains("parent /bios")
        );
        nested_login_isolated("parent-sid-aaaa", "child-sid-bbbb").unwrap();
        assert!(nested_login_isolated("same", "same")
            .unwrap_err()
            .contains("reuse parent"));
        sandbox_allowed("allow-scripts").unwrap();
        assert!(EmbedGrant::issue(
            "https://parent.example/",
            "https://child.example/",
            "n".repeat(16),
            10,
            0,
        )
        .unwrap_err()
        .contains("ttl"));
        assert!(EmbedGrant::issue(
            "https://parent.example/",
            "https://child.example/",
            "n".repeat(16),
            10,
            86_401,
        )
        .unwrap_err()
        .contains("ttl"));
        assert!(sandbox_allowed("allow-scripts allow-popups")
            .unwrap_err()
            .contains("sandbox escape"));
        assert!(sandbox_allowed("allow-top-navigation")
            .unwrap_err()
            .contains("sandbox escape"));
    }
}
