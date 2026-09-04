#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Push whatever wasm-opt-*.tar.gz files are in release/ onto the
// wasm-opt-binaries branch so setup can fetch them without a GitHub Release.
import { existsSync, mkdirSync, readdirSync, copyFileSync, rmSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const srcDir = process.argv[2] ? resolve(process.argv[2]) : join(root, 'release')
const branch = process.env.SVELTE_D_WASM_OPT_BRANCH || 'wasm-opt-binaries'
const repo =
  process.env.GITHUB_REPOSITORY ||
  'etcimon/svelte-d'
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || ''

function run(cmd: string, args: string[], cwd?: string): number {
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit', shell: false })
  return r.status ?? 1
}

if (!existsSync(srcDir)) {
  console.error('no release dir', srcDir)
  process.exit(1)
}
const archives = readdirSync(srcDir).filter((n) => /^wasm-opt-.+\.tar\.gz$/.test(n))
if (!archives.length) {
  console.error('no wasm-opt-*.tar.gz in', srcDir)
  process.exit(1)
}

const work = join(root, '.wasm-opt-binaries-work')
if (existsSync(work)) rmSync(work, { recursive: true, force: true })
const url = token
  ? `https://x-access-token:${token}@github.com/${repo}.git`
  : `https://github.com/${repo}.git`

let st = run('git', ['clone', '--depth', '1', '--branch', branch, url, work])
if (st !== 0) {
  mkdirSync(work, { recursive: true })
  run('git', ['init', '-b', branch, work])
  run('git', ['remote', 'add', 'origin', url], work)
}

run('git', ['config', 'user.name', 'github-actions[bot]'], work)
run('git', ['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com'], work)

for (const name of archives) {
  copyFileSync(join(srcDir, name), join(work, name))
}
const readme = `# wasm-opt-binaries

Prebuilt \`wasm-opt\` from the etcimon/binaryen \`svelte-d\` fork.
\`bunx svelte-d setup\` downloads \`wasm-opt-<triple>.tar.gz\` from this branch.

${archives.map((n) => `- ${n}`).join('\n')}
`
const { writeFileSync } = await import('node:fs')
writeFileSync(join(work, 'README.md'), readme)

run('git', ['add', '-A'], work)
const dirty = spawnSync('git', ['status', '--porcelain'], {
  cwd: work,
  encoding: 'utf8',
  shell: false,
})
if (!(dirty.stdout || '').trim()) {
  console.log('wasm-opt-binaries already up to date')
  process.exit(0)
}
if (run('git', ['commit', '-m', `Update wasm-opt binaries (${archives.join(', ')})`], work) !== 0)
  process.exit(1)
if (run('git', ['push', '-u', 'origin', `HEAD:${branch}`], work) !== 0) process.exit(1)
console.log('pushed', branch, archives.join(' '))
