#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Pull the CI-built etcimon/binaryen wasm-opt for this host into
// binaryen-build/<triple>/ and the toolchain home.
// darwin-arm64 / darwin-x86_64 / linux-x86_64 / linux-aarch64 / windows-x86_64.
// Used by bunx svelte-d setup / wasm / build and by CI.
import {
  binaryenBuildVariant,
  ensureForkedWasmOpt,
  hostTriple,
  isForkedWasmOpt,
} from '../packages/svelte-d/ts/platform.ts'

process.env.SVELTE_D_NO_BUILD_WASM_OPT = '1'
const triple = binaryenBuildVariant()
const host = hostTriple()
console.log('host   ', host.os, host.arch, host.variant)
console.log('wasm-opt triple', triple)
const bin = await ensureForkedWasmOpt()
if (!bin || !isForkedWasmOpt(bin)) {
  console.error('forked wasm-opt missing after download:', bin)
  process.exit(3)
}
console.log('wasm-opt', bin)
const n = bin.replace(/\\/g, '/')
if (!n.includes(triple) && !n.includes('binaryen-svelte-d')) {
  console.error(`host ${host.os}/${host.arch} did not install the ${triple} fork`)
  process.exit(3)
}
console.log('pulled — did not compile Binaryen (SVELTE_D_NO_BUILD_WASM_OPT=1)')
