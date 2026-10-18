// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { test, expect } from "bun:test";
import { bashDoubleQuoted } from "../src/tooling/rtlTiming.ts";

test("yosys selectors stay literal while shell paths still expand", () => {
  const script = 'read_slang -f $RUN/x.f; async2sync t:$aldff t:$aldffe; tee -o "$RUN/s" stat';
  const out = bashDoubleQuoted(script);
  expect(out.startsWith('"') && out.endsWith('"')).toBe(true);
  expect(out).toContain("$RUN/x.f");
  expect(out).toContain("t:\\$aldff t:\\$aldffe");
  expect(out).toContain('\\"$RUN/s\\"');
});
