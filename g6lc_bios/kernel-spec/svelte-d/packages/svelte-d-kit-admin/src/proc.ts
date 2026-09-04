// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Kill leftover Vite / node that lock svelte-engine-ws on Windows.
import { execSync, type ChildProcess } from 'node:child_process'

export function killProcessTree(child: ChildProcess | number | undefined): void {
  const pid = typeof child === 'number' ? child : child?.pid
  if (!pid) return
  if (process.platform === 'win32') {
    try {
      execSync(`taskkill /F /T /PID ${pid}`, { stdio: 'ignore' })
    } catch {
      /* already gone */
    }
    return
  }
  try {
    process.kill(pid, 'SIGTERM')
  } catch {
    /* already gone */
  }
}

export function killPort(port: number): void {
  if (process.platform === 'win32') {
    try {
      const out = execSync(
        `powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort ${port} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique"`,
        { encoding: 'utf8' }
      )
      for (const raw of out.split(/\s+/)) {
        const pid = Number(raw.trim())
        if (pid > 0) killProcessTree(pid)
      }
    } catch {
      /* nothing listening */
    }
    return
  }
  try {
    const out = execSync(`lsof -tiTCP:${port} -sTCP:LISTEN`, { encoding: 'utf8' })
    for (const raw of out.split(/\s+/)) {
      const pid = Number(raw.trim())
      if (pid > 0) killProcessTree(pid)
    }
  } catch {
    /* nothing listening */
  }
}
