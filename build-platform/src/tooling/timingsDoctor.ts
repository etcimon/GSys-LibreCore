// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// timingsDoctor.ts — One-glance readiness for timings / STA / FO4 lab path.

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { hasBinary } from "../platform/exec.ts";
import { resolveBashBinary } from "../platform/shell.ts";
import { assessSimPreflight } from "./simPreflight.ts";
import { inventoryFo4Model, fo4RetuneChecklist } from "./fo4Inventory.ts";
import { resolveSvTimingRoot } from "./timings.ts";
import { posixPath } from "./eda.ts";

export interface TimingsDoctorReport {
  ok: boolean;
  svTimingRoot: string | null;
  packages: { dir: string; count: number };
  staHandoff: { dir: string; count: number; lastLabReport: string | null };
  tools: {
    bash: string;
    yosys: boolean;
    opensta: boolean;
    openroad: boolean;
    liberty: string | null;
  };
  sim: ReturnType<typeof assessSimPreflight>;
  fo4: ReturnType<typeof inventoryFo4Model>;
  retuneChecklist: string[];
  hints: string[];
}

function resolveLibertyEnv(): string | null {
  if (process.env.CVA6_LIBERTY && existsSync(process.env.CVA6_LIBERTY)) {
    return process.env.CVA6_LIBERTY;
  }
  return null;
}

export function assessTimingsDoctor(ctx: PlatformContext): TimingsDoctorReport {
  const hints: string[] = [];
  const svt = resolveSvTimingRoot(ctx);
  const packagesDir = join(ctx.paths.build, "sv-timing");
  const staDir = join(ctx.paths.build, "sta-handoff");
  let pkgCount = 0;
  let staCount = 0;
  try {
    if (existsSync(packagesDir)) pkgCount = readdirSync(packagesDir).length;
  } catch {
    /* ignore */
  }
  try {
    if (existsSync(staDir)) staCount = readdirSync(staDir).length;
  } catch {
    /* ignore */
  }

  const labReport = join(staDir, "lab-run", "lab-report.md");
  const lastLab = existsSync(labReport) ? posixPath(labReport) : null;

  const bash = resolveBashBinary();
  const liberty = resolveLibertyEnv();
  const yosys = hasBinary("yosys");
  const opensta = hasBinary("sta") || hasBinary("opensta");
  const openroad = hasBinary("openroad");

  if (!svt) hints.push("Clone/check out sv-timing at repo root");
  if (!liberty) hints.push("Set CVA6_LIBERTY for OpenSTA S2 (optional)");
  if (!yosys) hints.push("Install OSS CAD suite / yosys for S1 synth smoke");
  if (!opensta) hints.push("Install OpenSTA (sta) for S2 path reports");
  if (!lastLab) hints.push("Run: timings lab-run  (offline S0 + soft S1–S4)");

  const fo4 = inventoryFo4Model(ctx);
  const sim = assessSimPreflight(ctx);

  const ok = svt != null && fo4.present;

  return {
    ok,
    svTimingRoot: svt,
    packages: { dir: posixPath(packagesDir), count: pkgCount },
    staHandoff: {
      dir: posixPath(staDir),
      count: staCount,
      lastLabReport: lastLab,
    },
    tools: {
      bash: bash ? `${bash.flavor} ${bash.path ?? bash.bin}` : "missing",
      yosys,
      opensta,
      openroad,
      liberty,
    },
    sim,
    fo4,
    retuneChecklist: fo4RetuneChecklist(fo4),
    hints,
  };
}
