// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virtio-net catalog constants. HTTP(S) fetch is a kernel abstraction that
//! lowers onto this crate's TCP/IP sockets — this module is not a TLS stack.

/// virtio-net feature names advertised in HwSpec (virtio spec 5.1 + 1.x).
pub const VIRTIO_NET_FEATURES: &[&str] = &["csum", "mac", "status", "version_1"];
