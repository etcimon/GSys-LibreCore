#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// bun+ts+svelte-d runner: drop packaged engine, ingest this project,
// compile, vite, vibe.0 host logs (colored), Chrome+Firefox console.
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  compileWorkspace,
  dropWorkspace,
  loadDebugMap,
} from 'svelte-d'
import {
  adminWorkspace,
  fmtBytes,
  hostExePath,
  wasmPath,
  fileBytes,
  writeWorkspaceEnv,
} from './ws.ts'
import { buildHostCell, buildWasmCell, compileCellsCompare, formatDualSizes } from './cells.ts'
import { printHostChunk, printKitLine } from './bridge.ts'
import { attachLiveBrowsers } from './browsers.ts'
import { killPort, killProcessTree } from './proc.ts'
import { ensureWasm } from './wasm.ts'

const project = dirname(dirname(fileURLToPath(import.meta.url)))
const cmd = process.argv[2] ?? 'dev'
const args = process.argv.slice(3)
const flag = (n: string) => args.includes(n)

function pipeChild(name: 'vite' | 'host' | 'compile', child: ChildProcess) {
  const map = () => loadDebugMap()
  child.stdout?.on('data', (b: Buffer) => {
    if (name === 'host') printHostChunk(String(b), map())
    else printKitLine(name === 'vite' ? 'vite' : 'compile', 'log', String(b).trimEnd(), map())
  })
  child.stderr?.on('data', (b: Buffer) => {
    if (name === 'host') printHostChunk(String(b), map())
    else printKitLine(name === 'vite' ? 'vite' : 'compile', 'error', String(b).trimEnd(), map())
  })
}

async function dev() {
  const ws = adminWorkspace()
  printKitLine('compile', 'info', 'drop packaged engine → ' + ws)
  const d = dropWorkspace({ force: flag('--force'), dest: ws })
  if (d.status !== 0) process.exit(d.status)
  writeWorkspaceEnv(ws)
  printKitLine('compile', 'info', 'compile --project ' + project)
  const c = compileWorkspace({ ws, project })
  if (c.stdout) printKitLine('compile', 'log', c.stdout.trimEnd())
  if (c.status !== 0) {
    if (c.stderr) printKitLine('compile', 'error', c.stderr.trimEnd())
    process.exit(c.status)
  }
  let wasmFile = wasmPath(ws)
  if (!wasmFile) {
    const w = buildWasmCell('debug', ws, false)
    printKitLine('compile', w.status === 0 ? 'info' : 'warn', 'wasm debug ' + w.label)
    wasmFile = w.path
  }
  const wasm = wasmFile ? ensureWasm(ws) : null
  printKitLine(
    'compile',
    wasm ? 'info' : 'warn',
    wasm
      ? 'wasm debug ' + wasm + ' ' + fmtBytes(fileBytes(wasmFile))
      : 'no svelte-engine.wasm'
  )

  const kids: ChildProcess[] = []
  const kill = () => {
    for (const k of kids) killProcessTree(k)
  }
  process.on('SIGINT', () => {
    kill()
    process.exit(0)
  })

  if (!flag('--no-host')) {
    let host = hostExePath(ws)
    if (!host) {
      const h = buildHostCell('debug', ws)
      printKitLine('host', h.status === 0 ? 'info' : 'warn', 'host debug ' + h.label)
      host = h.path
    }
    if (host) {
      printKitLine('host', 'info', 'vibe.0 debug ' + host + ' ' + fmtBytes(fileBytes(host)) + ' :8180')
      const h = spawn(host, [], {
        cwd: join(ws, 'webserver'),
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
      })
      kids.push(h)
      pipeChild('host', h)
    } else printKitLine('host', 'warn', 'no svelte-engine-server (skip)')
  }

  const viteJs = join(ws, 'node_modules', 'vite', 'package.json')
  if (!existsSync(viteJs)) {
    printKitLine('vite', 'info', 'bun install in workspace')
    const inst = spawn('bun', ['install'], { cwd: ws, stdio: 'inherit', shell: false })
    await new Promise<void>((res, rej) => {
      inst.on('exit', (code) => (code === 0 ? res() : rej(new Error('bun install ' + code))))
    })
  }

  const port = '5177'
  killPort(Number(port))
  printKitLine('vite', 'info', 'http://127.0.0.1:' + port)
  const viteBin = join(ws, 'node_modules', '.bin', process.platform === 'win32' ? 'vite.cmd' : 'vite')
  const vite = spawn(
    existsSync(viteBin) ? viteBin : 'vite',
    ['--host', '127.0.0.1', '--port', port, '--strictPort'],
    {
      cwd: ws,
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: process.platform === 'win32',
    }
  )
  kids.push(vite)
  pipeChild('vite', vite)
  vite.on('exit', (code) => {
    kill()
    process.exit(code ?? 1)
  })

  if (!flag('--no-browser')) {
    await new Promise((r) => setTimeout(r, 1500))
    const both = !flag('--chrome') && !flag('--firefox')
    const attached = await attachLiveBrowsers({
      url: 'http://127.0.0.1:' + port + '/',
      chrome: both || flag('--chrome'),
      firefox: both || flag('--firefox'),
    })
    printKitLine(
      'compile',
      'info',
      'browsers chrome=' + attached.chrome + ' firefox=' + attached.firefox
    )
  }
}

function buildRelease() {
  const ws = adminWorkspace()
  printKitLine('compile', 'info', 'drop packaged engine → ' + ws)
  const d = dropWorkspace({ force: flag('--force'), dest: ws })
  if (d.status !== 0) process.exit(d.status)
  writeWorkspaceEnv(ws)
  printKitLine('compile', 'info', 'compile --project ' + project)
  const c = compileWorkspace({ ws, project })
  if (c.stdout) printKitLine('compile', 'log', c.stdout.trimEnd())
  if (c.status !== 0) {
    if (c.stderr) printKitLine('compile', 'error', c.stderr.trimEnd())
    process.exit(c.status)
  }
  printKitLine('compile', 'info', 'release + lflags -strip-all (debug kept as *.debug)')
  const sizes = compileCellsCompare(ws)
  printKitLine('compile', 'info', formatDualSizes(sizes))
  if (sizes.wasm.release.status !== 0 && !sizes.wasm.release.bytes) process.exit(2)
  if (sizes.host.release.status !== 0 && !sizes.host.release.bytes) process.exit(2)
}

if (cmd === 'dev' || cmd === 'start' || cmd === 'run') {
  dev().catch((e) => {
    printKitLine('compile', 'error', String(e))
    process.exit(1)
  })
} else if (cmd === 'build') {
  try {
    buildRelease()
  } catch (e) {
    printKitLine('compile', 'error', String(e))
    process.exit(1)
  }
} else {
  console.log(`svelte-d-kit-admin — bun + ts + svelte-d
  bun src/cli.ts dev [--force] [--no-host] [--no-browser] [--chrome] [--firefox]
      drop, ingest, compile IR, debug wasm/host, vite, vibe.0 logs
  bun src/cli.ts build [--force]
      drop, ingest, compile IR, then release + lflags -strip-all for
      wasm and the vibe.0 host; print debug vs release sizes
`)
}
