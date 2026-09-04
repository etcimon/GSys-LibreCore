#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Cross-platform svelte-d setup: one LDC 1.43+, dub, libwasm, vibe.0.
// bunx svelte-d setup  /  bun run setup
import { setupPlatform } from '../packages/svelte-d/ts/platform.ts'

const download = !process.argv.includes('--no-download')
const report = await setupPlatform({ download })
console.log('os      ', report.triple.os, report.triple.arch, report.triple.variant)
console.log('ldc     ', report.ldc || '(missing)')
console.log('dub     ', report.dub || '(missing)')
console.log(
  'wasm-opt',
  report.wasmOpt ||
    '(missing — bunx svelte-d setup downloads darwin-arm64 / host triple into binaryen-build/)'
)
console.log('libwasm ', report.libwasm || '(dub fetch ~master on first wasm build)')
console.log('vibe.0  ', report.vibe0 || '(dub registry vibe-0 on first host build)')
if (report.downloaded) console.log('downloaded toolchain into ~/.svelte-d/toolchains')
if (!report.ok) {
  console.error(
    'svelte-d setup: LDC 1.43 + dub required. Retry with network, or set SVELTE_D_LDC.'
  )
  process.exit(3)
}
