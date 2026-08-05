// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vendor.ts — Fetch / update / scan uncore controller + PHY IP.
//
// This is the engine behind the `vendor` command. It turns the typed catalog
// in config.vendor.controllers (schema.ts / defaults.ts) into concrete git
// actions, and reports checkout + scan state. It intentionally performs no
// implicit network work: callers pass explicit ids or --all. Two mechanisms
// are supported:
//   - "submodule": `git submodule add` (first time) / `update --init` + ref
//     checkout (thereafter). Preferred for controllers that get bumped+rescanned.
//   - "vendor": a flattened source snapshot (clone → prune excludes → strip
//     .git → copy into place → write a lock), mirroring vendor/*.vendor.hjson.

import { existsSync } from "node:fs";
import { cp, mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";

import type {
  VendorControllerSpec,
  VendorScanTrigger,
} from "../config/schema.ts";
import type { PlatformContext } from "../context.ts";
import { run } from "../platform/exec.ts";

/** RTL file extensions a scan enumerates. */
const RTL_EXTENSIONS = [".sv", ".svh", ".v", ".vh"];
/** Default scan triggers when a spec does not pin its own. */
const DEFAULT_SCAN_ON: VendorScanTrigger[] = ["on-fetch", "on-update", "on-integrate"];
/** Safety cap so a scan of a huge third-party tree cannot flood output. */
const MAX_SCAN_FILES = 4000;

export interface VendorSelectOptions {
  /** Explicit ids to act on. When empty, selection falls back to `enabled`. */
  ids?: string[];
  /** Act on the whole catalog regardless of `enabled`. */
  all?: boolean;
}

export interface VendorActionOptions extends VendorSelectOptions {
  dryRun?: boolean;
}

export type VendorAction = "add" | "update" | "vendor" | "skip";

export interface VendorSyncResult {
  id: string;
  path: string;
  ref?: string;
  action: VendorAction;
  ok: boolean;
  skipped: boolean;
  reason?: string;
}

export interface VendorCheckoutStatus {
  id: string;
  path: string;
  exists: boolean;
  registered: boolean;
  status: VendorControllerSpec["status"];
}

export interface VendorScanResult {
  id: string;
  path: string;
  exists: boolean;
  scannedRoots: string[];
  files: string[];
  byExtension: Record<string, number>;
  truncated: boolean;
}

/** Absolute checkout path for a controller. */
export function controllerPath(ctx: PlatformContext, spec: VendorControllerSpec): string {
  return join(ctx.repoRoot, spec.path);
}

/** Look a controller up by id (undefined if absent). */
export function findController(
  ctx: PlatformContext,
  id: string,
): VendorControllerSpec | undefined {
  return ctx.config.vendor.controllers.find((c) => c.id === id);
}

/** Whether a re-scan is required for a given lifecycle event. */
export function needsScan(spec: VendorControllerSpec, trigger: VendorScanTrigger): boolean {
  return (spec.scanOn ?? DEFAULT_SCAN_ON).includes(trigger);
}

/** True if `.gitmodules` already declares this path (so `add` would fail). */
async function submoduleRegistered(repoRoot: string, path: string): Promise<boolean> {
  const gm = join(repoRoot, ".gitmodules");
  if (!existsSync(gm)) return false;
  const text = await readFile(gm, "utf8");
  return text.split(/\r?\n/).some((line) => line.trim() === `path = ${path}`);
}

/** True if the checkout directory exists and is non-empty. */
async function checkedOut(abs: string): Promise<boolean> {
  if (!existsSync(abs)) return false;
  try {
    const entries = await readdir(abs);
    return entries.length > 0;
  } catch {
    return false;
  }
}

/** Resolve which catalog entries an action targets. */
export function selectControllers(
  ctx: PlatformContext,
  options: VendorSelectOptions,
): { selected: VendorControllerSpec[]; unknown: string[] } {
  const catalog = ctx.config.vendor.controllers;
  if (options.ids && options.ids.length > 0) {
    const selected: VendorControllerSpec[] = [];
    const unknown: string[] = [];
    for (const id of options.ids) {
      const spec = catalog.find((c) => c.id === id);
      if (spec) selected.push(spec);
      else unknown.push(id);
    }
    return { selected, unknown };
  }
  if (options.all) return { selected: [...catalog], unknown: [] };
  return { selected: catalog.filter((c) => c.enabled), unknown: [] };
}

/** Report checkout + registration state for every catalogued controller. */
export async function checkoutStatuses(ctx: PlatformContext): Promise<VendorCheckoutStatus[]> {
  const out: VendorCheckoutStatus[] = [];
  for (const spec of ctx.config.vendor.controllers) {
    out.push({
      id: spec.id,
      path: spec.path,
      exists: await checkedOut(controllerPath(ctx, spec)),
      registered: await submoduleRegistered(ctx.repoRoot, spec.path),
      status: spec.status,
    });
  }
  return out;
}

/** Fetch a single controller according to its mechanism. */
export async function syncController(
  ctx: PlatformContext,
  spec: VendorControllerSpec,
  options: { dryRun?: boolean } = {},
): Promise<VendorSyncResult> {
  const { repoRoot, logger } = ctx;
  const abs = controllerPath(ctx, spec);
  const shallow = spec.shallow ?? ctx.config.vendor.shallow;

  if (spec.mechanism === "vendor") {
    return vendorSnapshot(ctx, spec, options.dryRun ?? false);
  }

  // submodule mechanism
  const registered = await submoduleRegistered(repoRoot, spec.path);
  const present = await checkedOut(abs);
  const depthArgs = shallow ? ["--depth", "1"] : [];

  if (!registered && !present) {
    // First-time add.
    if (options.dryRun) {
      logger.info(`[dry-run] git submodule add ${spec.url} ${spec.path}`);
      if (spec.ref) logger.info(`[dry-run] git -C ${spec.path} checkout ${spec.ref}`);
      return { id: spec.id, path: spec.path, ref: spec.ref, action: "add", ok: true, skipped: true };
    }
    const add = await run("git", ["submodule", "add", "--force", spec.url, spec.path], {
      cwd: repoRoot,
      logger,
      allowFailure: true,
    });
    let ok = add.ok;
    if (ok && spec.ref) {
      const co = await run("git", ["-C", spec.path, "checkout", spec.ref], {
        cwd: repoRoot,
        logger,
        allowFailure: true,
      });
      ok = co.ok;
    }
    return { id: spec.id, path: spec.path, ref: spec.ref, action: "add", ok, skipped: false };
  }

  // Update / init existing.
  if (options.dryRun) {
    logger.info(`[dry-run] git submodule update --init ${depthArgs.join(" ")} -- ${spec.path}`);
    if (spec.ref) logger.info(`[dry-run] git -C ${spec.path} checkout ${spec.ref}`);
    return { id: spec.id, path: spec.path, ref: spec.ref, action: "update", ok: true, skipped: true };
  }
  const upd = await run(
    "git",
    ["submodule", "update", "--init", ...depthArgs, "--", spec.path],
    { cwd: repoRoot, logger, allowFailure: true },
  );
  let ok = upd.ok;
  if (ok && spec.ref) {
    const co = await run("git", ["-C", spec.path, "checkout", spec.ref], {
      cwd: repoRoot,
      logger,
      allowFailure: true,
    });
    ok = co.ok;
  }
  return { id: spec.id, path: spec.path, ref: spec.ref, action: "update", ok, skipped: false };
}

/** Snapshot-vendor a controller: clone → prune excludes → strip .git → copy. */
export async function vendorSnapshot(
  ctx: PlatformContext,
  spec: VendorControllerSpec,
  dryRun: boolean,
): Promise<VendorSyncResult> {
  const { repoRoot, logger } = ctx;
  const abs = controllerPath(ctx, spec);
  const tmp = join(ctx.paths.cache, "vendor-clone", spec.id);
  const shallow = spec.shallow ?? ctx.config.vendor.shallow;
  const depthArgs = shallow && !spec.ref ? ["--depth", "1"] : [];

  if (dryRun) {
    logger.info(`[dry-run] git clone ${depthArgs.join(" ")} ${spec.url} ${tmp}`);
    if (spec.ref) logger.info(`[dry-run] git -C ${tmp} checkout ${spec.ref}`);
    for (const ex of spec.excludeFromUpstream ?? []) logger.info(`[dry-run] rm -rf ${join(spec.path, ex)}`);
    logger.info(`[dry-run] copy snapshot → ${spec.path} (strip .git, write .vendor-lock.json)`);
    return { id: spec.id, path: spec.path, ref: spec.ref, action: "vendor", ok: true, skipped: true };
  }

  await rm(tmp, { recursive: true, force: true });
  await mkdir(join(ctx.paths.cache, "vendor-clone"), { recursive: true });

  const clone = await run("git", ["clone", ...depthArgs, spec.url, tmp], {
    cwd: repoRoot,
    logger,
    allowFailure: true,
  });
  if (!clone.ok) {
    return { id: spec.id, path: spec.path, action: "vendor", ok: false, skipped: false, reason: "clone failed" };
  }
  if (spec.ref) {
    await run("git", ["-C", tmp, "fetch", "origin", spec.ref], { cwd: repoRoot, logger, allowFailure: true });
    const co = await run("git", ["-C", tmp, "checkout", spec.ref], { cwd: repoRoot, logger, allowFailure: true });
    if (!co.ok) return { id: spec.id, path: spec.path, action: "vendor", ok: false, skipped: false, reason: "ref checkout failed" };
  }

  for (const ex of spec.excludeFromUpstream ?? []) {
    await rm(join(tmp, ex), { recursive: true, force: true });
  }
  await rm(join(tmp, ".git"), { recursive: true, force: true });

  await rm(abs, { recursive: true, force: true });
  await mkdir(abs, { recursive: true });
  await cp(tmp, abs, { recursive: true });

  const lock = {
    id: spec.id,
    url: spec.url,
    ref: spec.ref ?? null,
    fetchedAt: new Date().toISOString(),
    mechanism: "vendor",
  };
  await Bun.write(join(abs, ".vendor-lock.json"), JSON.stringify(lock, null, 2) + "\n");
  await rm(tmp, { recursive: true, force: true });

  return { id: spec.id, path: spec.path, ref: spec.ref, action: "vendor", ok: true, skipped: false };
}

/** Sync a selection of controllers; logs a numbered step per entry. */
export async function syncControllers(
  ctx: PlatformContext,
  options: VendorActionOptions = {},
): Promise<VendorSyncResult[]> {
  const { logger } = ctx;
  const { selected, unknown } = selectControllers(ctx, options);
  const results: VendorSyncResult[] = [];
  for (const id of unknown) {
    logger.error(`unknown controller id '${id}'`);
    results.push({
      id,
      path: "",
      action: "skip",
      ok: false,
      skipped: true,
      reason: "unknown id",
    });
  }
  let index = 0;
  for (const spec of selected) {
    index++;
    logger.step(index, selected.length, `${spec.id} (${spec.mechanism}) → ${spec.path}`);
    const result = await syncController(ctx, spec, { dryRun: options.dryRun });
    if (result.ok) logger.success(`${spec.id}: ${result.skipped ? "dry-run" : result.action}`);
    else logger.error(`${spec.id}: ${result.reason ?? "failed"}`);
    if (result.ok && !result.skipped && needsScan(spec, result.action === "add" ? "on-fetch" : "on-update")) {
      logger.info(`  scan recommended: bun run src/cli/index.ts vendor scan ${spec.id}`);
    }
    results.push(result);
  }
  return results;
}

/** Bump a controller's checked-out ref (submodule) or re-snapshot (vendor). */
export async function updateController(
  ctx: PlatformContext,
  id: string,
  newRef: string | undefined,
  dryRun: boolean,
): Promise<VendorSyncResult> {
  const spec = findController(ctx, id);
  if (!spec) return { id, path: "", action: "skip", ok: false, skipped: true, reason: "unknown id" };
  const ref = newRef ?? spec.ref;
  const effective: VendorControllerSpec = { ...spec, ref };

  if (spec.mechanism === "vendor") {
    return vendorSnapshot(ctx, effective, dryRun);
  }

  const { repoRoot, logger } = ctx;
  if (!(await checkedOut(controllerPath(ctx, spec)))) {
    // Not present yet — fall back to a normal sync.
    return syncController(ctx, effective, { dryRun });
  }
  if (dryRun) {
    logger.info(`[dry-run] git -C ${spec.path} fetch`);
    if (ref) logger.info(`[dry-run] git -C ${spec.path} checkout ${ref}`);
    return { id, path: spec.path, ref, action: "update", ok: true, skipped: true };
  }
  await run("git", ["-C", spec.path, "fetch", "--tags"], { cwd: repoRoot, logger, allowFailure: true });
  let ok = true;
  if (ref) {
    const co = await run("git", ["-C", spec.path, "checkout", ref], { cwd: repoRoot, logger, allowFailure: true });
    ok = co.ok;
  }
  return { id, path: spec.path, ref, action: "update", ok, skipped: false };
}

/** Bounded recursive walk collecting RTL files under `root`. */
async function collectRtl(root: string, acc: string[]): Promise<boolean> {
  if (acc.length >= MAX_SCAN_FILES) return true;
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return false;
  }
  let truncated = false;
  for (const entry of entries) {
    const name = String(entry.name);
    if (name === ".git") continue;
    const full = join(root, name);
    if (entry.isDirectory()) {
      truncated = (await collectRtl(full, acc)) || truncated;
    } else if (RTL_EXTENSIONS.some((ext) => name.toLowerCase().endsWith(ext))) {
      acc.push(full);
    }
    if (acc.length >= MAX_SCAN_FILES) return true;
  }
  return truncated;
}

/** Enumerate the RTL a controller exposes (its scanPaths, or the whole tree). */
export async function scanController(
  ctx: PlatformContext,
  spec: VendorControllerSpec,
): Promise<VendorScanResult> {
  const abs = controllerPath(ctx, spec);
  const result: VendorScanResult = {
    id: spec.id,
    path: spec.path,
    exists: existsSync(abs),
    scannedRoots: [],
    files: [],
    byExtension: {},
    truncated: false,
  };
  if (!result.exists) return result;

  const roots =
    spec.scanPaths && spec.scanPaths.length > 0
      ? spec.scanPaths.map((p) => join(abs, p))
      : [abs];

  for (const root of roots) {
    if (!existsSync(root)) continue;
    result.scannedRoots.push(root);
    const s = await stat(root);
    if (s.isDirectory()) {
      result.truncated = (await collectRtl(root, result.files)) || result.truncated;
    } else if (RTL_EXTENSIONS.some((ext) => root.toLowerCase().endsWith(ext))) {
      result.files.push(root);
    }
  }

  for (const f of result.files) {
    const dot = f.lastIndexOf(".");
    const ext = dot >= 0 ? f.slice(dot).toLowerCase() : "(none)";
    result.byExtension[ext] = (result.byExtension[ext] ?? 0) + 1;
  }
  return result;
}
