// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// benchMetrics.ts — Parse software-bench log text into CVA6_BENCH_* style metrics.
// Used by timings correlate and regress scripts (Dhrystone / CoreMark).

export type BenchMetricMap = Record<string, string | number>;

/**
 * Extract common Dhrystone / CoreMark / cycle markers from simulator or printf logs.
 * Best-effort: missing fields are omitted (caller may still set placeholders).
 */
export function parseBenchLog(text: string): BenchMetricMap {
  const m: BenchMetricMap = {};
  const lines = text.split(/\r?\n/);

  for (const line of lines) {
    // CoreMark — prefer value after colon (line may start with "CoreMark/MHz 1.0 : 3.14")
    let x = /CoreMark\/MHz[^:]*:\s*(\d+)\.(\d+)/i.exec(line);
    if (!x) x = /CoreMark\/MHz[^\d]*(\d+)\.(\d+)/i.exec(line);
    if (x) {
      m.CVA6_BENCH_SCORE = Number(`${x[1]}.${x[2]}`);
      m.CVA6_BENCH_COREMARK_MHZ = m.CVA6_BENCH_SCORE;
    }
    x = /Iterations\/Sec\s*:\s*([0-9.]+)/i.exec(line);
    if (x) m.CVA6_BENCH_ITER_PER_SEC = Number(x[1]);
    x = /Iterations\s*:\s*(\d+)/i.exec(line);
    if (x) m.CVA6_BENCH_ITERATIONS = Number(x[1]);
    x = /CoreMark Size\s*:\s*(\d+)/i.exec(line);
    if (x) m.CVA6_BENCH_SIZE = Number(x[1]);

    // Dhrystone
    x = /Dhrystone[^\d]*([0-9.]+)\s*DMIPS/i.exec(line);
    if (x) {
      m.CVA6_BENCH_DMIPS = Number(x[1]);
      m.CVA6_BENCH_SCORE = Number(x[1]);
    }
    x = /([0-9.]+)\s*DMIPS/i.exec(line);
    if (x && m.CVA6_BENCH_DMIPS == null) {
      m.CVA6_BENCH_DMIPS = Number(x[1]);
      if (m.CVA6_BENCH_SCORE == null) m.CVA6_BENCH_SCORE = Number(x[1]);
    }
    x = /Dhrystones\s+per\s+Second:\s*([0-9.]+)/i.exec(line);
    if (x) m.CVA6_BENCH_DHRYSTONES_PER_SEC = Number(x[1]);

    // Cycles / time
    x = /(\d+)\s*cycles/i.exec(line);
    if (x && m.CVA6_BENCH_CYCLES == null) m.CVA6_BENCH_CYCLES = Number(x[1]);
    x = /mcycle[^\d]*(\d+)/i.exec(line);
    if (x) m.CVA6_BENCH_CYCLES = Number(x[1]);
    x = /Total time\s*[:=]\s*([0-9.]+)\s*s/i.exec(line);
    if (x) m.CVA6_BENCH_RUNTIME_S = Number(x[1]);
    x = /time_out\s*=\s*(\d+)/i.exec(line);
    if (x) m.CVA6_BENCH_TIMEOUT = Number(x[1]);
  }

  return m;
}

/** Apply metrics onto process.env for child correlate (string values only). */
export function applyBenchMetricsToEnv(
  metrics: BenchMetricMap,
  env: Record<string, string | undefined> = process.env as Record<
    string,
    string | undefined
  >,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(metrics)) {
    const s = String(v);
    out[k] = s;
    env[k] = s;
  }
  return out;
}
