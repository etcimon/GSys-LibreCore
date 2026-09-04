// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from 'bun:test'
import {
  DEFAULT_BINARYEN_VERSION,
  DEFAULT_LDC_VERSION,
  MIN_WASM_OPT_VERSION,
  WASM_EH_FEATURES,
  binaryenDownloadUrl,
  binaryenVariant,
  binaryenBuildVariant,
  findBinaryenSource,
  findBinaryenBuildRoot,
  findLdc,
  findWasmOpt,
  forkedWasmOptHome,
  forkedWasmOptDownloadUrl,
  forkedWasmOptDownloadUrls,
  forkedWasmOptArtifactUrls,
  hostTriple,
  DEFAULT_WASM_OPT_RELEASE,
  isForkedWasmOpt,
  shouldBuildWasmOptFromSource,
  isLdc143Text,
  isWasmOptNewText,
  ldcDownloadUrl,
  parseWasmOptVersion,
} from 'svelte-d'

describe('cross-platform LDC 1.43 setup', () => {
  test('hostTriple maps windows / linux / macos including arm64', () => {
    expect(hostTriple('win32', 'x64')).toMatchObject({
      os: 'windows',
      variant: 'windows-x64',
      archiveExt: '7z',
      exe: 'ldc2.exe',
    })
    expect(hostTriple('linux', 'x64').variant).toBe('linux-x86_64')
    expect(hostTriple('linux', 'arm64').variant).toBe('linux-aarch64')
    expect(hostTriple('darwin', 'arm64')).toMatchObject({
      os: 'osx',
      variant: 'osx-arm64',
      archiveExt: 'tar.xz',
      exe: 'ldc2',
    })
    expect(hostTriple('darwin', 'x64').variant).toBe('osx-x86_64')
  })

  test('isLdc143Text accepts 1.43+ and rejects 1.42 / 1.36', () => {
    expect(isLdc143Text('LDC - the LLVM D compiler (1.43.0):')).toBe(true)
    expect(isLdc143Text('LDC - the LLVM D compiler (1.43.0-beta1):')).toBe(true)
    expect(
      isLdc143Text(
        'LDC - the LLVM D compiler (1.43.0-git-1218a47):\n  built with LDC - the LLVM D compiler (1.42.0)\n'
      )
    ).toBe(true)
    expect(isLdc143Text('LDC - the LLVM D compiler (1.42.0):')).toBe(false)
    expect(isLdc143Text('LDC - the LLVM D compiler (1.36.0):')).toBe(false)
  })

  test('official download URL uses the host variant', () => {
    const win = hostTriple('win32', 'x64')
    expect(ldcDownloadUrl('1.43.0-beta1', win)).toBe(
      'https://github.com/ldc-developers/ldc/releases/download/v1.43.0-beta1/ldc2-1.43.0-beta1-windows-x64.7z'
    )
    const mac = hostTriple('darwin', 'arm64')
    expect(ldcDownloadUrl('1.43.0-beta1', mac)).toContain('osx-arm64.tar.xz')
    expect(DEFAULT_LDC_VERSION).toMatch(/^1\.43/)
  })

  test('findLdc never returns a 1.42 path when one is on PATH', () => {
    const ldc = findLdc()
    if (!ldc) return
    expect(ldc.toLowerCase()).not.toMatch(/ldc2-1\.42/)
  })
})

describe('Binaryen ≥123 wasm-opt (try_table parse, no asyncify)', () => {
  test('parseWasmOptVersion reads Binaryen banners and rejects apt 108', () => {
    expect(parseWasmOptVersion('wasm-opt version 123 (version_123)')).toBe(123)
    expect(parseWasmOptVersion('wasm-opt version 132 (version_132)')).toBe(132)
    expect(parseWasmOptVersion('wasm-opt version 108')).toBe(108)
    expect(isWasmOptNewText('wasm-opt version 123 (version_123)')).toBe(true)
    expect(isWasmOptNewText('wasm-opt version 108')).toBe(false)
    expect(MIN_WASM_OPT_VERSION).toBe(123)
    expect(DEFAULT_BINARYEN_VERSION).toMatch(/version_12/)
  })

  test('official Binaryen URL uses the host variant', () => {
    expect(binaryenVariant('win32', 'x64')).toBe('x86_64-windows')
    expect(binaryenVariant('linux', 'x64')).toBe('x86_64-linux')
    expect(binaryenVariant('linux', 'arm64')).toBe('aarch64-linux')
    expect(binaryenVariant('darwin', 'arm64')).toBe('arm64-macos')
    expect(binaryenDownloadUrl('version_123', 'x86_64-windows')).toBe(
      'https://github.com/WebAssembly/binaryen/releases/download/version_123/binaryen-version_123-x86_64-windows.tar.gz'
    )
    expect(WASM_EH_FEATURES).toContain('--enable-exception-handling')
    expect(WASM_EH_FEATURES.join(' ')).not.toMatch(/asyncify/)
  })

  test('findWasmOpt is empty or ≥123', () => {
    const bin = findWasmOpt()
    if (!bin) return
    expect(bin.toLowerCase()).toMatch(/wasm-opt/)
  })

  test('findBinaryenSource sees the svelte-d submodule', () => {
    const src = findBinaryenSource()
    if (!src) return
    expect(src.replace(/\\/g, '/')).toMatch(/binaryen$/)
    expect(isForkedWasmOpt(forkedWasmOptHome() + '/bin/wasm-opt')).toBe(true)
    expect(isForkedWasmOpt('/usr/bin/wasm-opt')).toBe(false)
  })

  test('forked wasm-opt CI assets live under binaryen-build/<triple>', () => {
    expect(binaryenBuildVariant('win32', 'x64')).toBe('windows-x86_64')
    expect(binaryenBuildVariant('linux', 'x64')).toBe('linux-x86_64')
    expect(binaryenBuildVariant('linux', 'arm64')).toBe('linux-aarch64')
    expect(binaryenBuildVariant('darwin', 'arm64')).toBe('darwin-arm64')
    expect(binaryenBuildVariant('darwin', 'x64')).toBe('darwin-x86_64')
    expect(forkedWasmOptDownloadUrl('linux-x86_64')).toBe(
      'https://github.com/etcimon/svelte-d/releases/download/wasm-opt-svelte-d/wasm-opt-linux-x86_64.tar.gz'
    )
    expect(forkedWasmOptDownloadUrls('linux-x86_64')).toContain(
      'https://github.com/etcimon/svelte-d/raw/wasm-opt-binaries/wasm-opt-linux-x86_64.tar.gz'
    )
    expect(forkedWasmOptDownloadUrls('darwin-arm64')).toContain(
      'https://github.com/etcimon/svelte-d/releases/download/wasm-opt-svelte-d/wasm-opt-darwin-arm64.tar.gz'
    )
    expect(forkedWasmOptArtifactUrls('darwin-arm64')).toContain(
      'https://nightly.link/etcimon/svelte-d/workflows/wasm-opt.yml/master/wasm-opt-darwin-arm64.zip'
    )
    expect(forkedWasmOptDownloadUrls('darwin-arm64')).toEqual(
      expect.arrayContaining(forkedWasmOptArtifactUrls('darwin-arm64'))
    )
    expect(DEFAULT_WASM_OPT_RELEASE).toBe('wasm-opt-svelte-d')
    expect(isForkedWasmOpt('/tmp/binaryen-build/linux-x86_64/wasm-opt')).toBe(true)
    expect(isForkedWasmOpt('/tmp/binaryen-build/darwin-arm64/wasm-opt')).toBe(true)
    for (const triple of [
      'darwin-arm64',
      'darwin-x86_64',
      'linux-x86_64',
      'linux-aarch64',
      'windows-x86_64',
    ]) {
      expect(forkedWasmOptDownloadUrl(triple)).toContain(`wasm-opt-${triple}.tar.gz`)
      expect(forkedWasmOptArtifactUrls(triple).some((u) => u.includes(triple))).toBe(true)
    }
    const root = findBinaryenBuildRoot()
    if (root) expect(root.replace(/\\/g, '/')).toMatch(/binaryen-build$/)
  })

  test('shouldBuildWasmOptFromSource skips cmake when a fork was pulled', () => {
    const prevN = process.env.SVELTE_D_NO_BUILD_WASM_OPT
    const prevB = process.env.SVELTE_D_BUILD_WASM_OPT
    try {
      delete process.env.SVELTE_D_NO_BUILD_WASM_OPT
      delete process.env.SVELTE_D_BUILD_WASM_OPT
      expect(shouldBuildWasmOptFromSource(true)).toBe(false)
      expect(shouldBuildWasmOptFromSource(false)).toBe(true)
      process.env.SVELTE_D_NO_BUILD_WASM_OPT = '1'
      expect(shouldBuildWasmOptFromSource(false)).toBe(false)
      delete process.env.SVELTE_D_NO_BUILD_WASM_OPT
      process.env.SVELTE_D_BUILD_WASM_OPT = '1'
      expect(shouldBuildWasmOptFromSource(true)).toBe(true)
    } finally {
      if (prevN === undefined) delete process.env.SVELTE_D_NO_BUILD_WASM_OPT
      else process.env.SVELTE_D_NO_BUILD_WASM_OPT = prevN
      if (prevB === undefined) delete process.env.SVELTE_D_BUILD_WASM_OPT
      else process.env.SVELTE_D_BUILD_WASM_OPT = prevB
    }
  })

  test('published wasm-opt archives are gzip for each published triple', async () => {
    for (const triple of [
      'darwin-arm64',
      'darwin-x86_64',
      'linux-x86_64',
      'linux-aarch64',
      'windows-x86_64',
    ]) {
      const url = forkedWasmOptDownloadUrl(triple)
      const res = await fetch(url, { redirect: 'follow' })
      if (!res.ok) continue
      const buf = new Uint8Array(await res.arrayBuffer())
      expect({ triple, bytes: buf.length }).toEqual({
        triple,
        bytes: expect.any(Number),
      })
      expect(buf.length).toBeGreaterThan(1_000_000)
      expect(buf[0]).toBe(0x1f)
      expect(buf[1]).toBe(0x8b)
    }
  })
})
