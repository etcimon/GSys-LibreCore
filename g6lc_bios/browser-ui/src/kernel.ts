// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * JS exports for HolyC / kernel interactivity.
 * svelte-d splices these into src-ts jsExports / window.__svelteD.ts.
 * g6b-js AOT understands fetch(), kernel.holyc(), kernel.register().
 */

declare const kernel: {
  holyc(line: string): string;
  register(path: string, method?: string): void;
};

export function fetchBios(url: string): void {
  fetch(url);
}

export function holycEval(line: string): string {
  return kernel.holyc(line);
}

export function registerEndpoint(path: string, method = "GET"): void {
  kernel.register(path, method);
}

/** Open a MENUS.md screen on both faces (fetch + HolyC). */
export function openMenu(id: string): void {
  fetchBios("/bios/menu/" + id);
  if (id === "cpu") kernel.holyc("MenuCpu()");
  else if (id === "uncore") kernel.holyc("MenuUncore()");
  else kernel.holyc("Menu(\"" + id + "\")");
}

export const jsExports = {
  env: {
    fetchBios,
    holycEval,
    registerEndpoint,
  },
};
