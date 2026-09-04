// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * svelte-d consumer config. Workspace is the dropped compile dest.
 * BIOS UI is a NodeDef SPA — SvelteKit `+page` / `load` / `handleFetch` refused.
 */
export default {
  workspace: "./svelte-engine-ws",
  kit: false,
};
