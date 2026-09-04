// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { catalogJson, marker, refuseKit } from "./constructs.ts";
import { compileProject } from "./index.ts";
import { isLdc143Text, resolveToolchain } from "./ldc.ts";
import { parseSvelte } from "./parse.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("svelte-d BIOS compile", () => {
  test("refuses SvelteKit", () => {
    expect(refuseKit("export const load = () => {}")).not.toBeNull();
    expect(refuseKit("+page.svelte")).not.toBeNull();
    expect(refuseKit("<p id=\"x\">ok</p>")).toBeNull();
  });

  test("parses FileMgr fetch + holyc", () => {
    const f = parseSvelte(
      "src/FileMgr.svelte",
      `<script lang="ts">
let listing = "USB-FILES";
fetchBios("/bios/files/ntfs");
holycEval("UsbLs(\\"ntfs\\")");
</script>
<section id="filemgr"><p id="fm-list">{listing}</p></section>
`,
    );
    expect(f.langTs).toBe(true);
    expect(f.ops.some((o) => o.kind === "fetch" && o.url === "/bios/files/ntfs")).toBe(true);
    expect(f.ops.some((o) => o.kind === "text" && o.id === "fm-list" && o.value === "USB-FILES")).toBe(
      true,
    );
    expect(f.ops.some((o) => o.kind === "holyc" && o.line.includes("UsbLs"))).toBe(true);
  });

  test("LDC 1.43 is the wasm cell; 1.41/1.42 refused", () => {
    expect(isLdc143Text("LDC - the LLVM D compiler (1.43.0-git-1218a47):")).toBe(true);
    expect(isLdc143Text("LDC - the LLVM D compiler (1.41.0):")).toBe(false);
    expect(isLdc143Text("LDC - the LLVM D compiler (1.42.0):")).toBe(false);
    const tc = resolveToolchain(root);
    if (tc.ldc) {
      expect(tc.ok).toBe(true);
      expect(tc.versionLine).toMatch(/1\.43|1\.44|1\.45|1\.46/);
      expect(tc.versionLine).not.toMatch(/1\.41|1\.42/);
    }
  });

  test("project compiles to wasm + js exports", () => {
    const r = compileProject(root, { dub: false });
    expect(r.wasm[0]).toBe(0x00);
    expect(r.wasm[1]).toBe(0x61);
    expect(r.wasm[2]).toBe(0x73);
    expect(r.wasm[3]).toBe(0x6d);
    expect(r.js).toContain('document.getElementById("status").innerText = "UI-BOOT"');
    expect(r.js).toContain('fetch("/bios/files/ntfs")');
    expect(r.js).toContain("kernel.holyc");
    expect(r.js).toContain("kernel.register");
    expect(r.wsFiles.some((p) => p.includes("src-d/app.d"))).toBe(true);
    expect(r.wsFiles.some((p) => p.includes("src-ts/jsExports.ts"))).toBe(true);
    expect(r.wsFiles.some((p) => p.includes(".svelte-d/manifest.json"))).toBe(true);
    expect(r.wsFiles.some((p) => p === "dub.sdl")).toBe(true);
    expect(r.wsFiles.some((p) => p.includes("src-d/app.d"))).toBe(true);
    expect(r.js).toContain('fetch("/bios/menu")');
    expect(r.js).toContain('fetch("/bios/menu/settings")');
    expect(r.js).toContain('fetch("/bios/menu/cpu")');
    expect(r.catalog).toContain("Settings");
    expect(r.cell?.via).toBe("skip");
    expect(r.catalog).toContain("FileMgr");
    expect(marker("NodeDef")).toBe("SVELTE-LIVE NodeDef");
    expect(marker("{#await}")).toBe("SVELTE-STUB {#await}");
    expect(marker("sveltekit")).toBe("SVELTE-REFUSED sveltekit");
    expect(catalogJson()).toContain('"_start"');
  });
});
