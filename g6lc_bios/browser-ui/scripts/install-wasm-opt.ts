// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * Install the forked `wasm-opt` into `browser-ui/toolchains/binaryen-svelte-d`.
 *
 *   bun scripts/install-wasm-opt.ts             # idempotent
 *   bun scripts/install-wasm-opt.ts --force     # re-download
 *   bun scripts/install-wasm-opt.ts --check     # report only, never write
 *   bun scripts/install-wasm-opt.ts --from-source   # cmake the submodule
 *
 * The binary is the `etcimon/binaryen` `svelte-d` fork, which is **required**,
 * not preferred: stock Binaryen cannot `--asyncify` a module containing
 * `try_table`, and LDC 1.43 emits `try_table` for wasm-eh. The fork's Flatten
 * pass is what makes the asyncified cell possible.
 *
 * Unlike LDC there is no upstream SHA-256 manifest to pin against — the fork
 * publishes rolling CI binaries. So instead of pretending to pin, this records
 * the URL, size and the digest it actually received in a receipt, and verifies
 * the tool by *behaviour*: it must asyncify a `try_table` module, which is the
 * property we depend on. A stock wasm-opt fails that check and is refused.
 */
import { createHash } from "node:crypto";
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync,
  rmSync, statSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import {
  binaryenLicense, binaryenSource, binaryenVariant, isBinaryenSource,
  localBinaryenHome, MIN_WASM_OPT_VERSION, resolveWasmOpt, svelteDRoot,
  wasmOptDownloadUrls, wasmOptExeName, wasmOptVersion,
} from "../compiler/binaryen.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const force = process.argv.includes("--force");
const checkOnly = process.argv.includes("--check");
const fromSource = process.argv.includes("--from-source");

const home = localBinaryenHome(root);
const exe = wasmOptExeName();
const dest = join(home, "bin", exe);

/**
 * The property we actually need: asyncify must survive `try_table`. Building a
 * tiny module by hand keeps the check independent of the browser-ui build, so
 * this cannot pass because some other artifact happens to exist.
 */
/**
 * Why the last `asyncifiesTryTable` probe failed, when it failed before
 * producing a verdict: a binary that cannot start (missing GLIBC_2.38 on a
 * Debian bookworm host, wrong arch) must not be reported as "not the fork".
 */
let lastProbeFailure = "";

function asyncifiesTryTable(bin: string): boolean {
  lastProbeFailure = "";
  if (!existsSync(bin)) {
    lastProbeFailure = `${bin} does not exist`;
    return false;
  }
  const tmp = mkdtempSync(join(tmpdir(), "g6b-wasmopt-"));
  try {
    const wat = join(tmp, "t.wat");
    // (try_table (catch_all ...)) inside a function, plus an import to asyncify.
    writeFileSync(
      wat,
      `(module
  (import "env" "libwasm_await__void" (func $await (param i32)))
  (func (export "_start")
    block $done
      try_table (catch_all $done)
        i32.const 0
        call $await
      end
    end))
`,
    );
    const out = join(tmp, "t.wasm");
    const r = spawnSync(
      bin,
      ["--enable-exception-handling", "--enable-reference-types", "--asyncify",
       "--pass-arg=asyncify-imports@env.libwasm_await__void", wat, "-o", out],
      { encoding: "utf8", shell: false, maxBuffer: 16 * 1024 * 1024 },
    );
    if (r.error) {
      lastProbeFailure = `wasm-opt could not be executed: ${String(r.error)}`;
      return false;
    }
    if (r.status !== 0) {
      const err = (r.stderr || "").trim().split(/\r?\n/).slice(0, 3).join(" | ");
      lastProbeFailure = `wasm-opt exited ${r.status}${r.signal ? ` (${r.signal})` : ""}${err ? `: ${err}` : ""}`;
      return false;
    }
    if (!existsSync(out) || statSync(out).size <= 8) {
      lastProbeFailure = "wasm-opt produced no asyncified module";
      return false;
    }
    return true;
  } catch (e) {
    lastProbeFailure = String(e);
    return false;
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

function report(bin: string): void {
  const v = wasmOptVersion(bin);
  console.log(`wasm-opt: ${bin}`);
  console.log(`wasm-opt:   version ${v || "<unknown>"}`);
  console.log(`wasm-opt:   asyncify(try_table) ${asyncifiesTryTable(bin) ? "OK" : "FAILED"}`);
}

function extract(archive: string, into: string): void {
  const attempts: [string, string[]][] = [["tar", ["-xf", archive, "-C", into]]];
  if (archive.endsWith(".zip")) attempts.push(["7z", ["x", "-y", `-o${into}`, archive]]);
  const failures: string[] = [];
  for (const [bin, args] of attempts) {
    const r = spawnSync(bin, args, { encoding: "utf8", shell: false, maxBuffer: 64 * 1024 * 1024 });
    if (r.status === 0) return;
    failures.push(`${bin}: ${r.error ? String(r.error) : `status ${r.status}\n${r.stderr || ""}`}`);
  }
  throw new Error(`could not extract ${archive}:\n${failures.join("\n")}`);
}

/** Depth-first search for the extracted wasm-opt, whatever the archive nesting. */
function findExtracted(dir: string, depth = 0): string {
  if (depth > 6) return "";
  let names: string[] = [];
  try {
    names = readdirSync(dir, { withFileTypes: true }).map((d) => d.name + (d.isDirectory() ? "/" : ""));
  } catch {
    return "";
  }
  for (const n of names) {
    if (!n.endsWith("/") && (n === exe || n === "wasm-opt")) return join(dir, n);
  }
  for (const n of names) {
    if (n.endsWith("/")) {
      const hit = findExtracted(join(dir, n.slice(0, -1)), depth + 1);
      if (hit) return hit;
    }
  }
  return "";
}

function buildFromSource(): string {
  const src = binaryenSource();
  if (!src || !isBinaryenSource(src)) {
    throw new Error(
      "binaryen fork source missing; run:\n" +
        "  git submodule update --init --recursive -- svelte-d\n" +
        "(from g6lc_bios, which initialises svelte-d/binaryen)",
    );
  }
  const cmake = process.env.CMAKE || "cmake";
  const probe = spawnSync(cmake, ["--version"], { encoding: "utf8", shell: false });
  if (probe.status !== 0) throw new Error("cmake missing (install CMake, or set CMAKE)");
  const buildDir = join(home, "build");
  mkdirSync(buildDir, { recursive: true });
  mkdirSync(dirname(dest), { recursive: true });
  const isWin = process.platform === "win32";
  const configure = [
    "-S", src, "-B", buildDir, "-DENABLE_WERROR=OFF", "-DBUILD_TESTS=OFF",
    ...(isWin ? ["-A", "x64"] : ["-DCMAKE_BUILD_TYPE=Release"]),
  ];
  console.log(`wasm-opt: cmake configure ${src}`);
  if ((spawnSync(cmake, configure, { stdio: "inherit", shell: false }).status ?? 1) !== 0) {
    throw new Error("cmake configure failed for the binaryen fork");
  }
  const buildArgs = ["--build", buildDir, "--target", "wasm-opt", "--parallel", "2"];
  if (isWin) buildArgs.push("--config", "Release");
  console.log("wasm-opt: cmake --build wasm-opt (this takes a while)");
  if ((spawnSync(cmake, buildArgs, { stdio: "inherit", shell: false }).status ?? 1) !== 0) {
    throw new Error("cmake --build wasm-opt failed");
  }
  const built = findExtracted(buildDir);
  if (!built) throw new Error(`wasm-opt missing after cmake build in ${buildDir}`);
  copyFileSync(built, dest);
  return dest;
}

function download(): string {
  const variant = binaryenVariant();
  const urls = wasmOptDownloadUrls(variant);
  const cache = join(home, ".cache");
  mkdirSync(cache, { recursive: true });
  const failures: string[] = [];
  for (const url of urls) {
    const file = join(cache, url.endsWith(".zip") ? `wasm-opt-${variant}.zip` : `wasm-opt-${variant}.tar.gz`);
    const partial = `${file}.part`;
    rmSync(partial, { force: true });
    console.log(`wasm-opt: trying ${url}`);
    const r = spawnSync("curl", ["-fsSL", "--retry", "2", "--retry-delay", "2", "-o", partial, url], {
      encoding: "utf8", shell: false,
    });
    if (r.status !== 0 || !existsSync(partial) || statSync(partial).size === 0) {
      rmSync(partial, { force: true });
      failures.push(`${url}: ${r.error ? String(r.error) : `curl status ${r.status}`}`);
      continue;
    }
    rmSync(file, { force: true });
    require("node:fs").renameSync(partial, file);
    const staging = mkdtempSync(join(tmpdir(), "g6b-wasmopt-x-"));
    try {
      extract(file, staging);
      const got = findExtracted(staging);
      if (!got) {
        failures.push(`${url}: archive contained no ${exe}`);
        continue;
      }
      mkdirSync(dirname(dest), { recursive: true });
      copyFileSync(got, dest);
      if (process.platform !== "win32") spawnSync("chmod", ["+x", dest], { shell: false });
      const digest = createHash("sha256").update(readFileSync(file)).digest("hex");
      writeReceipt(url, statSync(file).size, digest);
      return dest;
    } catch (error) {
      failures.push(`${url}: ${String(error)}`);
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  }
  throw new Error(`no forked wasm-opt could be downloaded:\n  ${failures.join("\n  ")}`);
}

function writeReceipt(url: string, bytes: number, sha256: string): void {
  // There is no upstream digest manifest for a rolling CI binary, so the
  // receipt records what was received rather than claiming a pin.
  writeFileSync(
    join(home, "installed.json"),
    JSON.stringify(
      {
        schema: "g6lc-wasm-opt-install/v1",
        note: "rolling CI binary from the etcimon/binaryen svelte-d fork; digest is observed, not pinned",
        variant: binaryenVariant(),
        url,
        bytes,
        sha256,
        bin: dest,
        version: wasmOptVersion(dest),
        asyncifiesTryTable: asyncifiesTryTable(dest),
        svelteD: svelteDRoot(),
        installedAt: new Date().toISOString(),
      },
      null,
      2,
    ) + "\n",
  );
  const license = binaryenLicense();
  if (license) writeFileSync(join(home, "LICENSE"), license);
}

// ---------------------------------------------------------------------------

if (checkOnly) {
  const info = resolveWasmOpt();
  if (!info.bin) {
    console.error("wasm-opt: not installed; run `bun scripts/install-wasm-opt.ts`");
    process.exit(1);
  }
  report(info.bin);
  if (!asyncifiesTryTable(info.bin)) {
    console.error(`wasm-opt: ${info.bin} cannot asyncify try_table (stock Binaryen?)`);
    process.exit(1);
  }
  console.log(`wasm-opt: provider ${info.source}${info.forked ? " (fork)" : " (NOT the fork)"}`);
  process.exit(0);
}

if (!force && existsSync(dest) && asyncifiesTryTable(dest)) {
  console.log(`wasm-opt: already installed at ${dest}`);
  report(dest);
  process.exit(0);
}

// An out-of-tree fork that already works is *adopted* rather than
// re-downloaded, so `bunx svelte-d setup` and this script do not fight over
// the same binary and no network round trip is needed.
//
// Adopting means copying it to `browser-ui/toolchains/binaryen-svelte-d/`
// instead of merely pointing at it. wasm-opt is a toolchain on the same
// footing as the pinned LDC, and the point of the in-tree `toolchains/`
// directory is that the build resolves the *same* location on every host.
// Leaving the tool in `~/.svelte-d` makes the environment host-dependent for
// no benefit, since it is the identical verified binary either way.
if (!force && !fromSource) {
  const info = resolveWasmOpt();
  if (info.bin && info.forked && asyncifiesTryTable(info.bin)) {
    if (resolve(info.bin) === resolve(dest)) {
      console.log(`wasm-opt: reusing existing fork from ${info.source}`);
      report(info.bin);
      process.exit(0);
    }
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(info.bin, dest);
    if (process.platform !== "win32") spawnSync("chmod", ["+x", dest], { shell: false });
    if (!asyncifiesTryTable(dest)) {
      rmSync(dest, { force: true });
      throw new Error(`adopted wasm-opt from ${info.bin} does not work at ${dest}`);
    }
    writeReceipt(
      `adopted:${info.source}:${resolve(info.bin)}`,
      statSync(info.bin).size,
      createHash("sha256").update(readFileSync(info.bin)).digest("hex"),
    );
    console.log(`wasm-opt: adopted the ${info.source} fork into ${dest}`);
    report(dest);
    process.exit(0);
  }
}

function install(): string {
  if (fromSource) return buildFromSource();
  try {
    return download();
  } catch (error) {
    // Seamless fallback. The svelte-d submodule *carries the fork source*, so a
    // network failure, a rate-limited release, or a host variant with no CI
    // asset is recoverable here rather than by telling the operator to re-run
    // with a different flag. Only attempt it when the source is actually
    // present and identifiable as the fork (`Flatten.cpp`), otherwise the
    // original download error is the honest one to surface.
    const src = binaryenSource();
    if (!src || !isBinaryenSource(src)) throw error;
    console.error(`wasm-opt: download failed (${String(error).split("\n")[0]})`);
    console.error(`wasm-opt: falling back to a cmake build of the fork at ${src}`);
    return buildFromSource();
  }
}

const installed = install();
const version = wasmOptVersion(installed);
if (version && version < MIN_WASM_OPT_VERSION) {
  rmSync(installed, { force: true });
  throw new Error(`installed wasm-opt is ${version}, need >= ${MIN_WASM_OPT_VERSION}`);
}
if (!asyncifiesTryTable(installed)) {
  rmSync(installed, { force: true });
  // A loader failure (e.g. "version `GLIBC_2.38' not found": the release is
  // built on Ubuntu 24.04) is a host problem, not a wrong binary; say which.
  const why = lastProbeFailure;
  const hostProblem = /GLIBC|GLIBCXX|cannot execute|No such file|ENOENT|Exec format/i.test(why);
  throw new Error(
    hostProblem
      ? `installed wasm-opt cannot run on this host (${why}); the fork release is built on Ubuntu 24.04 (glibc >= 2.38) -- use such a host or build from source (--from-source)`
      : `installed wasm-opt cannot asyncify try_table, so it is not the svelte-d fork; refusing it (${why})`,
  );
}
console.log("wasm-opt: installed");
report(installed);
