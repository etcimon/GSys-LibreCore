// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// regress.test.ts — Run the configured LibreCore regression suites via `bun test`.
//
// By default the suites are SKIPPED so `bun test` stays fast and green on an
// unprovisioned host. Set CVA6_BUILD_RUN_HW=1 (and provision the toolchain via
// `bun run src/cli/index.ts setup`) to actually execute them. Suite selection follows
// tests.defaultSuites in .config.ts, overridable with BUILD_PLATFORM_SUITES.

import { describe, expect, test } from "bun:test";

import { createContext } from "../src/context.ts";
import { canRunSuites, runSuite, selectSuites } from "../src/tests/runner.ts";

const RUN_HW = process.env.CVA6_BUILD_RUN_HW === "1";
const OVERRIDE = process.env.BUILD_PLATFORM_SUITES?.split(",").map((s) => s.trim()).filter(Boolean);

const ctx = await createContext({ logLevel: "warn" });
const { suites } = selectSuites(ctx.config, OVERRIDE);

describe("LibreCore regression suites", () => {
  const enabled = RUN_HW && canRunSuites();

  if (!enabled) {
    test.skip(
      `suites skipped (set CVA6_BUILD_RUN_HW=1 and run 'bun run src/cli/index.ts setup' to enable) [${suites.map((s) => s.id).join(", ")}]`,
      () => {},
    );
    return;
  }

  for (const suite of suites) {
    test(
      suite.id,
      async () => {
        const result = await runSuite(ctx, suite);
        expect(result.ok).toBe(true);
      },
      3_600_000,
    );
  }
});
