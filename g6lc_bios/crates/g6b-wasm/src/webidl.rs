// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WebIDL throw shapes for the BIOS UI JIT.
//!
//! Specs (not compiled): `libwasm/webidl/definitions/DOMException.webidl`,
//! `Document.webidl` (`createElement` `[Throws]`), `Node.webidl`
//! (`appendChild` `[Throws]`), `WindowOrWorkerGlobalScope.webidl` /
//! `Request.webidl` / `Fetch.webidl` (Request constructor `TypeError`;
//! Body methods `[Throws]`).
//! Bindings: `libwasm/source/libwasm/bindings/{DOMException,Document,Node,Window,WindowOrWorkerGlobalScope,Fetch}.d`.
//!
//! A JS host throw is catchable in wasm-eh when it is a `TypeError` or a
//! `DOMException` (the JS API wraps those as `WebAssembly.Exception` on the
//! imported `__cpp_exception` tag). Other host errors stay traps.

#![allow(missing_docs)]

/// `DOMException.HIERARCHY_REQUEST_ERR` — `Node.appendChild` cycle / ancestor.
pub const HIERARCHY_REQUEST_ERR: u16 = 3;
/// `DOMException.INVALID_CHARACTER_ERR` — `Document.createElement` bad `Name`.
pub const INVALID_CHARACTER_ERR: u16 = 5;

/// JavaScript `TypeError` (Fetch/Request invalid URL). Not `TYPE_MISMATCH_ERR`
/// (historical; the IDL says use `TypeError`).
pub fn type_error(message: &str) -> String {
    format!("TypeError: {message}")
}

/// `DOMException` with WebIDL `name` and `code` (`bindings/DOMException.d`).
pub fn dom_exception(name: &str, code: u16, message: &str) -> String {
    format!("DOMException:{name}:{code}:{message}")
}

pub fn hierarchy_request_append_child() -> String {
    dom_exception(
        "HierarchyRequestError",
        HIERARCHY_REQUEST_ERR,
        "Failed to execute 'appendChild' on 'Node': The new child element contains the parent.",
    )
}

pub fn invalid_character_create_element(local_name: &str) -> String {
    dom_exception(
        "InvalidCharacterError",
        INVALID_CHARACTER_ERR,
        &format!(
            "Failed to execute 'createElement' on 'Document': The tag name provided ('{local_name}') is not a valid name."
        ),
    )
}

pub fn request_type_error() -> String {
    type_error("Failed to construct 'Request': Invalid URL")
}

/// Host errors that wasm `try`/`catch` must land (JS `TypeError` / `DOMException`).
pub fn is_js_host_throw(err: &str) -> bool {
    err.starts_with("TypeError:") || err.starts_with("DOMException:")
}

/// Tag payload: `DOMException.code`, else 0 for `TypeError`.
pub fn js_throw_payload(err: &str) -> i32 {
    let Some(rest) = err.strip_prefix("DOMException:") else {
        return 0;
    };
    rest.split(':')
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or(0)
}

/// HTML `createElement` `Name` production (no `:`, no leading digit).
pub fn is_valid_element_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphabetic() {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Request/fetch URL the BIOS host accepts, or a parseable absolute URL.
/// Empty / `:` / `http://[` fail the Request constructor (`TypeError`).
pub fn is_valid_request_url(url: &str) -> bool {
    if url.is_empty() || url == ":" {
        return false;
    }
    if url.starts_with('/') {
        return !url.contains(' ');
    }
    if let Some(rest) = url.split_once("://") {
        !rest.0.is_empty() && !rest.1.is_empty() && !url.contains([' ', '[', ']'])
    } else {
        false
    }
}
