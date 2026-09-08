// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * Install the pinned LDC release into `browser-ui/toolchains`.
 *
 *   bun scripts/install-ldc.ts            # idempotent; no-op when installed
 *   bun scripts/install-ldc.ts --force    # re-download and re-extract
 *   bun scripts/install-ldc.ts --check    # report only, never write
 *
 * The pin is `toolchains/ldc.lock.json`. Every byte is checked against the
 * upstream `ldc2-<version>.sha256sums.txt` digest carried in that file BEFORE
 * anything is extracted, and the extracted compiler must then report exactly
 * the pinned version. Anything else is refused and removed; nothing is
 * installed "best effort".
 *
 * This only affects the OPTIONAL libwasm cell (`out/bios-ui-libwasm.wasm`).
 * The first-party `out/bios-ui.wasm` lane needs no D toolchain at all.
 */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { downloadUrl, isPinnedLdcText, pinnedAsset, readPin, receiptPath, toolchainsDir, type PinnedAsset } from "../compiler/ldc-pin.ts";
import { hostTriple } from "../compiler/ldc.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const force = process.argv.includes("--force");
const checkOnly = process.argv.includes("--check");

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function versionOf(bin: string): string {
  if (!existsSync(bin)) return "";
  const r = spawnSync(bin, ["--version"], { encoding: "utf8", shell: false });
  if (r.status !== 0) return "";
  const text = (r.stdout || "") + (r.stderr || "");
  return text.split(/\r?\n/).find((l) => /LDC - the LLVM D compiler/i.test(l)) || "";
}

/**
 * bsdtar (shipped with Windows 10+, macOS and most Linux) reads .tar.xz and
 * .7z alike, so one extractor covers every pinned asset. 7z is only a
 * fallback for hosts whose tar predates libarchive's 7-Zip reader.
 */
function extract(archive: string, into: string): void {
  const attempts: [string, string[]][] = [["tar", ["-xf", archive, "-C", into]]];
  if (archive.endsWith(".7z")) attempts.push(["7z", ["x", "-y", `-o${into}`, archive]]);
  const failures: string[] = [];
  for (const [bin, args] of attempts) {
    const r = spawnSync(bin, args, { encoding: "utf8", shell: false, maxBuffer: 64 * 1024 * 1024 });
    if (r.status === 0) return;
    failures.push(`${bin}: ${r.error ? String(r.error) : `status ${r.status}\n${r.stderr || ""}`}`);
  }
  throw new Error(`could not extract ${archive}:\n${failures.join("\n")}`);
}

function download(url: string, into: string, asset: PinnedAsset): void {
  const partial = `${into}.part`;
  rmSync(partial, { force: true });
  const r = spawnSync("curl", ["-fsSL", "--retry", "3", "--retry-delay", "2", "-o", partial, url], {
    encoding: "utf8",
    shell: false,
  });
  if (r.status !== 0) {
    rmSync(partial, { force: true });
    throw new Error(`download failed: ${url}\n${r.error ? String(r.error) : r.stderr || ""}`);
  }
  const size = statSync(partial).size;
  if (size !== asset.bytes) {
    rmSync(partial, { force: true });
    throw new Error(`pinned asset ${asset.file} is ${size} bytes, pin says ${asset.bytes}`);
  }
  renameSync(partial, into);
}

const pin = readPin(root);
const triple = hostTriple();
const key = `${triple.os}-${triple.arch}`;
const asset = pinnedAsset(key, root);
const home = join(toolchainsDir(root), asset.dir);
const bin = join(home, "bin", triple.exe);

const installed = versionOf(bin);
if (installed && isPinnedLdcText(installed, root) && !force) {
  console.log(`ldc: pinned ${pin.version} already installed at ${home}`);
  console.log(`ldc: ${installed}`);
  process.exit(0);
}
if (checkOnly) {
  console.error(
    installed
      ? `ldc: ${home} reports "${installed}", not the pinned ${pin.version}`
      : `ldc: pinned ${pin.version} is not installed (expected ${bin})`,
  );
  console.error("ldc: run `bun scripts/install-ldc.ts` to install it");
  process.exit(1);
}

const cache = join(toolchainsDir(root), ".cache");
mkdirSync(cache, { recursive: true });
const archive = join(cache, asset.file);
const url = downloadUrl(asset, pin);

if (force || !existsSync(archive) || sha256File(archive) !== asset.sha256) {
  console.log(`ldc: downloading ${url}`);
  rmSync(archive, { force: true });
  download(url, archive, asset);
}
const digest = sha256File(archive);
if (digest !== asset.sha256) {
  rmSync(archive, { force: true });
  throw new Error(`SHA-256 mismatch for ${asset.file}\n  expected ${asset.sha256}\n  actual   ${digest}`);
}
console.log(`ldc: verified ${asset.file} sha256=${digest}`);

rmSync(home, { recursive: true, force: true });
extract(archive, toolchainsDir(root));
if (!existsSync(bin)) {
  rmSync(home, { recursive: true, force: true });
  throw new Error(`${asset.file} did not extract to ${asset.dir}/bin/${triple.exe}`);
}

const line = versionOf(bin);
if (!isPinnedLdcText(line, root)) {
  rmSync(home, { recursive: true, force: true });
  throw new Error(`extracted compiler reports "${line || "<no version>"}", not the pinned ${pin.version}`);
}

const dubName = triple.os === "windows" ? "dub.exe" : "dub";
const dub = join(home, "bin", dubName);
if (pin.bundlesDub && !existsSync(dub)) {
  rmSync(home, { recursive: true, force: true });
  throw new Error(`pin claims a bundled dub but ${dub} is missing`);
}

writeFileSync(
  receiptPath(root),
  JSON.stringify(
    {
      schema: "g6lc-ldc-install/v1",
      version: pin.version,
      tag: pin.tag,
      triple: key,
      asset: asset.file,
      sha256: asset.sha256,
      home,
      ldc: bin,
      dub: existsSync(dub) ? dub : "",
      versionLine: line,
      installedAt: new Date().toISOString(),
    },
    null,
    2,
  ) + "\n",
);

console.log(`ldc: installed ${line}`);
console.log(`ldc:   ldc2 ${bin}`);
if (existsSync(dub)) console.log(`ldc:   dub  ${dub}`);
console.log("ldc: build the optional cell with `G6B_DUB_WASM=1 bun scripts/build.ts`");
