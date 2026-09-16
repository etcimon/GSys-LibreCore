// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Botan spec vectors must be on disk before tests/build include_str them.

fn main() {
    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let botan =
        manifest.join("../../kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem");
    println!("cargo:rerun-if-changed={}", botan.display());
    if !botan.is_file() {
        panic!(
            "kernel-spec/botan is missing ({})\nRun: python tools/g6b.py spec-sync\n(git submodule update --init, then botan fetch/pull)",
            botan.display()
        );
    }
}
