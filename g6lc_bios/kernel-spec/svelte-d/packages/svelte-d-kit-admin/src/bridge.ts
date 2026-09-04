// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Print rewritten browser + vibe.0 host logs to the bun command prompt.
import {
  formatBridgeLine,
  loadDebugMap,
  rewriteConsole,
  rewriteStack,
  type DebugMap,
} from 'svelte-d'

export type BridgeSource = 'chrome' | 'firefox' | 'host' | 'vite' | 'compile'

export function printKitLine(
  source: BridgeSource,
  kind: string,
  text: string,
  map?: DebugMap,
  out: NodeJS.WriteStream = process.stdout
): string {
  const dm = map ?? loadDebugMap()
  const rewritten =
    source === 'host' || source === 'vite' || source === 'compile'
      ? rewriteStack(dm, text)
      : rewriteConsole(dm, [text]).text
  const line = formatBridgeLine({ source, kind, text: rewritten })
  out.write(line + '\n')
  return line
}

export function printHostChunk(chunk: string, map?: DebugMap): void {
  for (const raw of chunk.split(/\r?\n/)) {
    if (!raw.trim()) continue
    printKitLine('host', 'log', raw, map)
  }
}
