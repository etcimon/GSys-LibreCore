// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WebIDL catalog for the BIOS browser. Specs live in
//! `kernel-spec/webidl/definitions` (MPL-2.0, not compiled). This crate is MIT
//! and names which interfaces are live, stub, or refused.

#![allow(missing_docs)]

/// How far a WebIDL interface is implemented.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// First-party rewrite in `g6b-dom` / `g6b-js`.
    Live,
    /// Named stub (`STUB <iface>`); not a Chromium/Gecko object.
    Stub,
    /// Must not appear in the BIOS browser.
    Refused,
}

/// BIOS UI + GL viewport.
pub const LIVE: &[&str] = &[
    "Attr",
    "CharacterData",
    "ChildNode",
    "Comment",
    "Console",
    "Document",
    "DocumentFragment",
    "DOMStringMap",
    "Element",
    "Event",
    "EventHandler",
    "EventListener",
    "EventTarget",
    "Fetch",
    "Headers",
    "HTMLBodyElement",
    "HTMLCanvasElement",
    "HTMLCollection",
    "HTMLDivElement",
    "HTMLDocument",
    "HTMLElement",
    "HTMLHeadElement",
    "HTMLHeadingElement",
    "HTMLHtmlElement",
    "HTMLImageElement",
    "HTMLParagraphElement",
    "HTMLScriptElement",
    "HTMLSpanElement",
    "HTMLTitleElement",
    "Node",
    "NodeList",
    "ParentNode",
    "Text",
    "WebAssembly",
    "Window",
    "XMLHttpRequest",
    "Request",
    "Response",
];

/// Named stubs: Fetch/HTTPS, crypto, GL context (bound to display-proxy).
pub const STUB: &[&str] = &[
    "AbortController",
    "Blob",
    "CanvasRenderingContext2D",
    "Crypto",
    "CSSStyleDeclaration",
    "DOMParser",
    "File",
    "FormData",
    "History",
    "ImageData",
    "KeyboardEvent",
    "Location",
    "MouseEvent",
    "Navigator",
    "Storage",
    "SubtleCrypto",
    "URL",
    "WebGL2RenderingContext",
    "WebGLRenderingContext",
    "Worker",
];

const REFUSED: &[&str] = &[
    "RTCPeerConnection",
    "ServiceWorker",
    "AddonManager",
    "MIDIAccess",
];

/// Classify a WebIDL interface name.
pub fn status(name: &str) -> Status {
    if LIVE.iter().any(|s| *s == name) {
        Status::Live
    } else if STUB.iter().any(|s| *s == name) {
        Status::Stub
    } else if REFUSED.iter().any(|s| *s == name) {
        Status::Refused
    } else {
        Status::Stub
    }
}

/// Marker printed in generated Browser.ZC / boot log.
pub fn marker(name: &str) -> String {
    match status(name) {
        Status::Live => format!("WEBIDL-LIVE {name}"),
        Status::Stub => format!("WEBIDL-STUB {name}"),
        Status::Refused => format!("WEBIDL-REFUSED {name}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_is_live_webrtc_refused() {
        assert_eq!(status("Document"), Status::Live);
        assert_eq!(status("HTMLCanvasElement"), Status::Live);
        assert_eq!(status("Fetch"), Status::Live);
        assert_eq!(status("WebGLRenderingContext"), Status::Stub);
        assert_eq!(status("RTCPeerConnection"), Status::Refused);
        assert!(marker("Document").contains("LIVE"));
    }
}
