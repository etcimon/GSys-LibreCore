#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Build etcimon/binaryen wasm-opt (Flatten try_table) from the svelte-d
// submodule. Installs to ~/.svelte-d/toolchains/binaryen-svelte-d.
// Needs CMake + a C++ toolchain. bun run build-wasm-opt
import {
  buildWasmOptFromSource,
  findBinaryenSource,
  findCMake,
  forkedWasmOptHome,
} from '../packages/svelte-d/ts/platform.ts'

const src = findBinaryenSource()
const cmake = findCMake()
if (!src) {
  console.error('svelte-d: binaryen submodule missing. git submodule update --init binaryen')
  process.exit(3)
}
if (!cmake) {
  console.error('svelte-d: cmake missing. Install CMake or set CMAKE.')
  process.exit(3)
}
const bin = buildWasmOptFromSource(src, cmake)
console.log('wasm-opt', bin)
console.log('install ', forkedWasmOptHome())
