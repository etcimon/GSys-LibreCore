// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { join } from 'node:path'
import {
  findRiscvDev,
  workspaceDir,
  findKitProjectRoot,
  loadSvelteDConfig,
  templateDir,
  nativeExe,
} from 'svelte-d'

export { findRiscvDev, workspaceDir, templateDir, findKitProjectRoot, loadSvelteDConfig }

/** @deprecated use nativeExe() from svelte-d */
export function svelteDBin(_root?: string) {
  return nativeExe()
}

export function setenvHost(root: string) {
  return join(root, 'setenv.ps1')
}
