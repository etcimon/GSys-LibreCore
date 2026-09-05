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
    "WorkerGlobalScope",
    "DedicatedWorkerGlobalScope",
    "MessageEvent",
    "MessagePort",
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerKind {
    Dedicated,
    Shared,
    Service,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerContract {
    pub interface: &'static str,
    pub global_scope: &'static str,
    pub document_access: bool,
    pub registration_required: bool,
    pub operations: &'static [&'static str],
    pub implemented_subset: bool,
}

pub fn worker_contract(kind: WorkerKind) -> WorkerContract {
    match kind {
        WorkerKind::Dedicated => WorkerContract {
            interface: "Worker",
            global_scope: "DedicatedWorkerGlobalScope",
            document_access: false,
            registration_required: false,
            operations: &[
                "postMessage",
                "terminate",
                "message",
                "messageerror",
                "error",
                "close",
            ],
            implemented_subset: true,
        },
        WorkerKind::Shared => WorkerContract {
            interface: "SharedWorker",
            global_scope: "SharedWorkerGlobalScope",
            document_access: false,
            registration_required: false,
            operations: &[],
            implemented_subset: false,
        },
        WorkerKind::Service => WorkerContract {
            interface: "ServiceWorker",
            global_scope: "ServiceWorkerGlobalScope",
            document_access: false,
            registration_required: true,
            operations: &[],
            implemented_subset: false,
        },
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerErrorName {
    AbortError,
    DataCloneError,
    DataError,
    InvalidStateError,
    NotSupportedError,
    OperationError,
    QuotaExceededError,
}

impl WorkerErrorName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AbortError => "AbortError",
            Self::DataCloneError => "DataCloneError",
            Self::DataError => "DataError",
            Self::InvalidStateError => "InvalidStateError",
            Self::NotSupportedError => "NotSupportedError",
            Self::OperationError => "OperationError",
            Self::QuotaExceededError => "QuotaExceededError",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerError {
    pub name: WorkerErrorName,
    pub message: String,
}

impl WorkerError {
    pub fn new(name: WorkerErrorName, message: impl AsRef<str>) -> Self {
        Self {
            name,
            message: message.as_ref().chars().take(1024).collect(),
        }
    }
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.name.as_str(), self.message)
    }
}
impl std::error::Error for WorkerError {}

pub fn clone_worker_buffer(bytes: &[u8], limit: usize) -> Result<Vec<u8>, WorkerError> {
    if limit > 1048576 || bytes.len() > limit {
        return Err(WorkerError::new(
            WorkerErrorName::QuotaExceededError,
            "worker message budget exceeded",
        ));
    }
    Ok(bytes.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedicated_compute_is_not_service_worker_registration() {
        let dedicated = worker_contract(WorkerKind::Dedicated);
        assert_eq!(dedicated.interface, "Worker");
        assert!(!dedicated.document_access);
        assert!(dedicated.operations.contains(&"postMessage"));
        let service = worker_contract(WorkerKind::Service);
        assert!(service.registration_required);
        assert!(!service.implemented_subset);
        assert_eq!(status("ServiceWorker"), Status::Refused);
        let source = vec![1, 2, 3];
        let mut copied = clone_worker_buffer(&source, 3).unwrap();
        copied[0] = 0;
        assert_eq!(source[0], 1);
        assert_eq!(
            clone_worker_buffer(&source, 2).unwrap_err().name,
            WorkerErrorName::QuotaExceededError
        );
    }

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
