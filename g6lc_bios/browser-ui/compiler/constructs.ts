// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** svelte-d / libwasm construct catalog for BIOS UI. SvelteKit is refused. */

export type Status = "live" | "stub" | "refused";

export type Construct =
  | "NodeDef"
  | "@prop"
  | "@child"
  | "@visible"
  | "_start"
  | "{#each}"
  | "{#await}"
  | "Slot"
  | "@callback"
  | "router"
  | "$state"
  | "sveltekit"
  | "FileMgr"
  | "Menu"
  | "Settings"
  | "Store";

export const LIVE: Construct[] = [
  "NodeDef",
  "@prop",
  "@child",
  "@visible",
  "_start",
  "FileMgr",
  "Menu",
  "Settings",
  "Store",
];

export const STUB: Construct[] = ["{#each}", "{#await}", "Slot", "@callback"];

export const REFUSED: Construct[] = ["router", "$state", "sveltekit"];

export function statusOf(c: Construct): Status {
  if ((LIVE as string[]).includes(c)) return "live";
  if ((STUB as string[]).includes(c)) return "stub";
  return "refused";
}

export function marker(c: Construct): string {
  const st = statusOf(c);
  const tag = st === "live" ? "LIVE" : st === "stub" ? "STUB" : "REFUSED";
  return `SVELTE-${tag} ${c}`;
}

export function catalogJson(): string {
  return JSON.stringify({ live: LIVE, stub: STUB, refused: REFUSED }, null, 2) + "\n";
}

const KIT_NEEDLES = ["handleFetch", "+page", "export const load", "sveltekit"];

export function refuseKit(src: string): string | null {
  for (const n of KIT_NEEDLES) {
    if (src.includes(n)) {
      return `sveltekit refused; BIOS UI is svelte-d NodeDef (needle ${n})`;
    }
  }
  return null;
}
