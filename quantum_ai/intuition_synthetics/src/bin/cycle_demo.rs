// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Cycle-function gate walk on a physical register via the C ABI symbols.

use qrc_env; // pull in the cdylib-exported crate

fn main() {
    println!("qrc_env loaded. Use examples/warehouse.rs for intuition.");
    let _ = qrc_env::EnvWorld::new(8);
}
