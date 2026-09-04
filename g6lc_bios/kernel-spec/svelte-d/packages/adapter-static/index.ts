// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { adaptWorkspace, type AdaptOpts, type AdapterReport } from 'svelte-d'

export default function adapter(
  opts: Omit<AdaptOpts, 'adapter'>
): AdapterReport {
  return adaptWorkspace({ ...opts, adapter: 'static' })
}
