// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: LicenseRef-Proprietary
//
// defaults.ts — The complete, resolved baseline configuration.
//
// Every option the platform understands has a value here, sourced from the
// real CVA6 flow (Makefile, verif/regress/*.sh, verif/sim/setup-env.sh,
// .gitmodules). A user's `.config.ts` only needs to override what differs, so
// adding a new option = adding one default here (never editing existing
// configs). This is the mechanism behind "minimal customization for new
// features".

import type { ResolvedBuildConfig } from "./schema.ts";

export const DEFAULT_CONFIG: ResolvedBuildConfig = {
  meta: {
    name: "CVA6",
    description: "OpenHW Group CVA6 application-class RISC-V core.",
  },

  workspace: {
    root: "workspace",
    buildDir: "build",
    toolingDir: "tooling",
    cacheDir: ".cache",
  },

  soc: {
    // Aligned with AGENTS-configuration.md §1.1 (router-class target of record).
    // Open-PDK study (sky130/gf180) is for flow bring-up only — see physicalDesign.
    coreConfig: "cv64a6_imafdc_sv39",
    xlen: 64,
    extensions: ["i", "m", "a", "f", "d", "c", "zicsr", "zifencei"],
    targetFrequencyMHz: 1250,
    targetVoltageV: 0.8,
    process: "tsmc12ffc-class",
  },

  toolchain: {
    riscvGcc: {
      source: "prebuilt",
      version: "gcc13.2.0/xpack-14.2.0",
      // Embecosm Linux tarball (CI); Windows xPack zip (native dual-hart/OpenSBI payload).
      prebuiltUrl: {
        // xPack linux-x64 matches toolPrefix riscv-none-elf- (rv64 dual-hart / sim).
        // Embecosm 32-bit tarball remains available for pure rv32 CI via override.
        linux:
          "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v14.2.0-3/xpack-riscv-none-elf-gcc-14.2.0-3-linux-x64.tar.gz",
        windows:
          "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v14.2.0-3/xpack-riscv-none-elf-gcc-14.2.0-3-win32-x64.zip",
        darwin:
          "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v14.2.0-3/xpack-riscv-none-elf-gcc-14.2.0-3-darwin-x64.tar.gz",
      },
      git: {
        url: "https://github.com/riscv-collab/riscv-gnu-toolchain.git",
        ref: "2024.09.03",
      },
      toolPrefix: "riscv-none-elf-",
    },
    python: {
      minVersion: "3.8",
      requirements: ["PyYAML", "pandas", "tabulate", "Mako", "regex"],
      // Repo-relative requirement sets the CVA6 flows already ship.
      requirementsFiles: [
        "verif/sim/dv/requirements.txt",
        "config/gen_from_riscv_config/requirements.txt",
      ],
    },
    versions: {
      verilator: "v5.008",
      spike: "vendored",
      iverilog: "v12_0",
      dtc: "1.6.1",
    },
    packageManager: {
      windows: "chocolatey",
      linux: "apt",
      darwin: "brew",
    },
  },

  simulation: {
    enabled: ["verilator", "spike"],
    default: "verilator",
    maxCycles: 10_000_000,
    verilator: {
      trace: false,
      traceFormat: "fst",
      threads: 0,
      timing: false,
    },
  },

  tests: {
    // Catalog of every non-vendored regression script under verif/regress.
    // `openSource: true` suites run on the managed Verilator+Spike toolchain;
    // `requiresUvm`/`requiresSubmodule` suites are preflight-skipped unless the
    // extra dependency is present. Scripts read their own DV_TARGET default, so
    // dvTarget is only pinned where it documents that same default.
    suites: [
      // --- smoke: fast per-target sanity -----------------------------------
      {
        id: "smoke-cv64a6",
        description: "Smoke sanity for cv64a6_imafdc_sv39 (compliance/tests/arch subset).",
        script: "verif/regress/smoke-tests-cv64a6_imafdc_sv39.sh",
        group: "smoke",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv64a6_imafdc_sv39",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-compliance", "riscv-tests", "riscv-arch-test"],
        openSource: true,
      },
      {
        id: "smoke-cv32a6",
        description: "Smoke sanity for cv32a6_imac_sv32 (compliance/tests/arch subset).",
        script: "verif/regress/smoke-tests-cv32a6_imac_sv32.sh",
        group: "smoke",
        target: "cv32a6_imac_sv32",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv32a6_imac_sv32",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-compliance", "riscv-tests", "riscv-arch-test"],
        openSource: true,
      },
      {
        id: "smoke-cv32a65x",
        description: "Smoke sanity for the embedded cv32a65x target (hello-world).",
        script: "verif/regress/smoke-tests-cv32a65x.sh",
        group: "smoke",
        target: "cv32a65x",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
      },
      // --- arch: ISA suites (riscv-tests / arch-test / compliance) ---------
      {
        id: "riscv-tests",
        description: "riscv-tests ISA regression (rv32/rv64 unit tests).",
        script: "verif/regress/dv-riscv-tests.sh",
        group: "arch",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv64a6_imafdc_sv39",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-tests"],
        openSource: true,
      },
      {
        id: "riscv-arch-test",
        description: "riscv-arch-test architectural compatibility suite.",
        script: "verif/regress/dv-riscv-arch-test.sh",
        group: "arch",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv64a6_imafdc_sv39",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-arch-test"],
        openSource: true,
      },
      {
        id: "riscv-compliance",
        description: "Legacy riscv-compliance ISA suite.",
        script: "verif/regress/dv-riscv-compliance.sh",
        group: "arch",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv64a6_imafdc_sv39",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-compliance"],
        openSource: true,
      },
      {
        id: "csr-access",
        description: "CSR access architectural test (cv32a6_imac_sv32).",
        script: "verif/regress/dv-riscv-csr-access-test.sh",
        group: "arch",
        target: "cv32a6_imac_sv32",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv32a6_imac_sv32",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-arch-test"],
        openSource: true,
      },
      {
        id: "mmu-sv32",
        description: "Sv32 MMU architectural test (cv32a6_imac_sv32).",
        script: "verif/regress/dv-riscv-mmu-sv32-test.sh",
        group: "arch",
        target: "cv32a6_imac_sv32",
        dvSimulators: "veri-testharness,spike",
        dvTarget: "cv32a6_imac_sv32",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-arch-test"],
        openSource: true,
      },
      // --- directed: hand-written C/asm regressions ------------------------
      {
        id: "iss-tests",
        description: "Instruction-set simulator directed tests.",
        script: "verif/regress/iss-tests.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-compliance"],
        openSource: true,
      },
      {
        id: "issue-tests",
        description: "Regression tests for previously-filed issues.",
        script: "verif/regress/issue-tests.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        testSuiteInstallers: ["riscv-compliance", "riscv-tests"],
        openSource: true,
      },
      {
        id: "iti",
        description: "Instruction-trace-interface (ITI) directed test.",
        script: "verif/regress/iti_test.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "instr-tracing",
        description: "Instruction tracing directed test.",
        script: "verif/regress/Instr_tracing_test.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "debug",
        description: "Debug-module test (needs OpenOCD + riscv-gdb on PATH).",
        script: "verif/regress/debug_test.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: false,
        optional: true,
      },
      // --- benchmark: performance workloads --------------------------------
      {
        id: "dhrystone",
        description: "Dhrystone benchmark (veri-testharness).",
        script: "verif/regress/dhrystone.sh",
        group: "benchmark",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "dhrystone-smoke",
        description: "Fast single-run Dhrystone smoke.",
        script: "verif/regress/dhrystone_smoke.sh",
        group: "benchmark",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "coremark",
        description: "CoreMark benchmark (veri-testharness).",
        script: "verif/regress/coremark.sh",
        group: "benchmark",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "benchmark",
        description: "Combined benchmark regression driver.",
        script: "verif/regress/benchmark.sh",
        group: "benchmark",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      // --- directed per-config test batteries (CI tier1) -------------------
      {
        id: "cv32a6-tests",
        description: "cv32a6 directed test battery (CI execute-riscv32-tests).",
        script: "verif/regress/cv32a6_tests.sh",
        group: "directed",
        target: "cv32a65x",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "cv64a6-tests",
        description: "cv64a6 directed test battery (CI execute-riscv64-tests).",
        script: "verif/regress/cv64a6_imafdc_tests.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "ooo-l3-tests",
        description:
          "OPTIONAL / lengthy: U5 production OoO directed. Runs cva6.py when DV ready, else real lint of DV_TARGET.",
        script: "verif/regress/ooo-l3-tests.sh",
        group: "directed",
        target: "cv64a6_ooo_server",
        dvTarget: "cv64a6_ooo_server",
        dvSimulators: "veri-testharness,spike",
        // Empty tools: script falls back to build.ps1 lint; full sim needs setup.
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "mc-stream-tests",
        description:
          "OPTIONAL: U6/p6 stream plane × multicore (inclusive L3→L2/L1, ServerPrefetch, multi-stream, Zacas/spo). Default DV_TARGET=cv64a6_ooo_server.",
        script: "verif/regress/mc-stream-tests.sh",
        group: "directed",
        target: "cv64a6_ooo_server",
        dvTarget: "cv64a6_ooo_server",
        dvSimulators: "veri-testharness,spike",
        tools: [],
        openSource: true,
        optional: true,
      },
      // --- sv-timing host gates (build-platform timings → svt.py) -------------
      {
        id: "sv-timing-smoke",
        description:
          "sv-timing host smoke: timings analyze on package fixture project_mini (workspace out-dir).",
        script: "verif/regress/sv-timing-smoke.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "sv-timing-core-sparse",
        description:
          "sv-timing sparse core EX (packages+alu/mult/…): timings flist+analyze; soft-pass if packages need param-map.",
        script: "verif/regress/sv-timing-core-sparse.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "sv-timing-autocorrect",
        description:
          "sv-timing auto-correct dry-run + emit on fixture (and soft sparse core) under workspace build/sv-timing/verif-tests.",
        script: "verif/regress/sv-timing-autocorrect.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "sv-timing-advanced",
        description:
          "sv-timing advanced: multi sparse flists + correct emit + optional pyslang smoke on emit tree.",
        script: "verif/regress/sv-timing-advanced.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "timings-sta-handoff",
        description:
          "OpenSTA handoff S0–S2/S4a: pure-Verilog sta_smoke (comb_adder) → seeds.sdc + optional Yosys netlist/OpenSTA/OpenROAD (soft-skip without tools).",
        script: "verif/regress/timings-sta-handoff.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "mc-spo-soak",
        description:
          "OPTIONAL: Soak assemble + dual-target lint for multi-core stream × spo/CF/CAS narrow diagnostics.",
        script: "verif/regress/mc-spo-soak.sh",
        group: "directed",
        target: "g6lc64_ooo_server",
        dvTarget: "g6lc64_ooo_server",
        dvSimulators: "none",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "mc-spo-spike",
        description:
          "OPTIONAL: Spike ISS soak of mc_stream spo/CF/Zacas narrow tests (Linux/WSL: gcc+spike+make+dtc).",
        script: "verif/regress/mc-spo-spike.sh",
        group: "directed",
        target: "cv64a6_server_math",
        dvTarget: "cv64a6_server_math",
        dvSimulators: "spike",
        tools: ["riscv-gcc", "spike"],
        openSource: true,
        optional: true,
      },
      {
        // Hard CAS golden: Spike has no zacas — do not soft-pass AMOCAS on ISS-only paths.
        id: "mc-mini-veri",
        description:
          "OPTIONAL: Verilator bare-metal mini gate (no CRT) — mini_tohost/jumps + hard AMOCAS.W/D on Variane. Default DV_TARGET=cv64a6_imafdc_sv39 (RVZacas). Prefer over CRT for CAS.",
        script: "verif/regress/mc-mini-veri.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvTarget: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "zacas-policy",
        description:
          "OPTIONAL: §8 Zacas residual — AMOCAS.W/D/Q hard mini golden + odd-pair illegal; Spike never CAS golden.",
        script: "verif/regress/zacas-policy.sh",
        group: "directed",
        target: "cv64a6_imafdc_sv39",
        dvTarget: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "s9-lab-gate",
        description:
          "OPTIONAL: §9 lab FO4/STA residual — host timings doctor+lab-run offline; soft-skip real S3b-lab/S4b without liberty/OpenSTA/OpenROAD.",
        script: "verif/regress/s9-lab-gate.sh",
        group: "directed",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        // Full CRT residual: budget/density sensitive; mini remains hard CAS golden.
        id: "mc-spo-veri",
        description:
          "OPTIONAL / residual: Verilator CRT multicore stream×spo/CF/Zacas soak (Variane). Default server_math; MC_SPO_VERI_FORCE_IMAFDC=1 for single-core smoke. Prefer mc-mini-veri for hard AMOCAS.",
        script: "verif/regress/mc-spo-veri.sh",
        group: "directed",
        target: "cv64a6_server_math",
        dvTarget: "cv64a6_server_math",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "ara-vector-path",
        description:
          "OPTIONAL: U10ᵇ Ara path gate (Flist.ara + upstream + server_math_v package). Live flist via verify.extraFlists.",
        script: "verif/regress/ara-vector-path.sh",
        group: "directed",
        target: "cv64a6_server_math",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "ara-vector-cosim",
        description:
          "OPTIONAL: §7 Ara cosim + OpenSBI VRF/Linux ISA_V contract (soft skip/misa; live lmul via ARA_COSIM_LIVE).",
        script: "verif/regress/ara-vector-cosim.sh",
        group: "directed",
        target: "g6lc64_server_math_v",
        dvTarget: "g6lc64_server_math_v",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "spec-deep-path",
        description:
          "OPTIONAL: FSE S1–S5 path gate + real lint of cv64a6_spec_deep and cv64a6_ooo.",
        script: "verif/regress/spec-deep-path.sh",
        group: "directed",
        target: "cv64a6_spec_deep",
        dvTarget: "cv64a6_spec_deep",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "spec-deep-tests",
        description:
          "OPTIONAL: FSE S6 directed suite (mispredict, STQ, fence, RVWMO/A litmus). DV_TARGET=cv64a6_spec_deep; lint fallback.",
        script: "verif/regress/spec-deep-tests.sh",
        group: "directed",
        target: "cv64a6_spec_deep",
        dvTarget: "cv64a6_spec_deep",
        dvSimulators: "veri-testharness,spike",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "server-math-tests",
        description:
          "OPTIONAL: U10 server-math C-light (misa B/H, cbo.zero, scalar memcpy). DV_TARGET=cv64a6_server_math.",
        script: "verif/regress/server-math-tests.sh",
        group: "directed",
        target: "cv64a6_server_math",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "kvm-h-tests",
        description:
          "OPTIONAL: KVM/H stress + H-edge (hedeleg WARL, VTSR/VTVM/VTW→22). DV_TARGET=g6lc64_server_math.",
        script: "verif/regress/kvm-h-tests.sh",
        group: "directed",
        target: "g6lc64_server_math",
        dvTarget: "g6lc64_server_math",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc", "verilator", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "kvm-h-spike",
        description:
          "OPTIONAL: Spike-first H-edge directed (h_edge_diag + kvm_h_stress). No Verilator required.",
        script: "verif/regress/kvm-h-spike.sh",
        group: "directed",
        target: "g6lc64_server_math",
        dvTarget: "g6lc64_server_math",
        dvSimulators: "spike",
        tools: ["riscv-gcc", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "stability-regress",
        description:
          "OPTIONAL: §4 residual battery (kvm-h-spike + mc-spo-spike + mini compile). STABILITY_PROFILE=artifact|spike|full.",
        script: "verif/regress/stability-regress.sh",
        group: "directed",
        target: "g6lc64_server_math",
        dvTarget: "g6lc64_server_math",
        dvSimulators: "spike",
        tools: ["riscv-gcc", "spike"],
        openSource: true,
        optional: true,
      },
      {
        id: "dual-iss-regress",
        description:
          "OPTIONAL: §5 dual-ISS residual — same ELF on Spike+Variane (tohost golden; optional trace). Not Zacas golden.",
        script: "verif/regress/dual-iss-regress.sh",
        group: "directed",
        target: "g6lc64_server_math",
        dvTarget: "g6lc64_server_math",
        dvSimulators: "spike,veri-testharness",
        tools: ["riscv-gcc", "spike", "verilator"],
        openSource: true,
        optional: true,
      },
      {
        id: "stream8-smoke",
        description:
          "OPTIONAL: stream8-class package contract + mini golden compile + soft lint of g6lc64_stream8.",
        script: "verif/regress/stream8-smoke.sh",
        group: "directed",
        target: "g6lc64_stream8",
        dvTarget: "g6lc64_stream8",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        // Xg6lcai AI matrix — config surface smoke (package + check_cfg).
        // Not in defaultSuites. Map: architecture/ai-matrix/README.md · AGENTS-todo AI-1
        id: "ai-config-smoke",
        description:
          "OPTIONAL: Xg6lcai config-surface smoke (g6lc64_ai package, AiCfg defaults/legality).",
        script: "verif/regress/ai-config-smoke.sh",
        group: "directed",
        target: "g6lc64_ai",
        dvTarget: "g6lc64_ai",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        // Xg6lcai directed: CSR/AI-X + ai.dot4/mma/requant contract + ELF compile.
        id: "ai-matrix-directed",
        description:
          "OPTIONAL: Xg6lcai directed gate (RTL contract, CSR addr, compile CSR/dot4/mma/requant smokes).",
        script: "verif/regress/ai-matrix-directed.sh",
        group: "directed",
        target: "g6lc64_ai",
        dvTarget: "g6lc64_ai",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        // Live Variane on g6lc64_ai (rebuild with AI_MATRIX_VERI_REBUILD=1).
        id: "ai-matrix-veri",
        description:
          "OPTIONAL: live Variane run of Xg6lcai directed ELFs on g6lc64_ai (work-ver-ai).",
        script: "verif/regress/ai-matrix-veri.sh",
        group: "directed",
        target: "g6lc64_ai",
        dvTarget: "g6lc64_ai",
        dvSimulators: "veri-testharness",
        tools: ["verilator", "riscv-gcc"],
        openSource: true,
        optional: true,
      },
      {
        id: "kvm-h-veri",
        description:
          "OPTIONAL: H-edge Variane 3/3 (h_edge_diag/kvm_h_stress/hlv_hsv). Prefers work-ver-stream8.",
        script: "verif/regress/kvm-h-veri.sh",
        group: "directed",
        target: "g6lc64_stream8",
        dvTarget: "g6lc64_stream8",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "dual-hart-ci",
        description:
          "OPTIONAL: dual-hart/SMT2 artifact + real lint of cv64a6_smt2.",
        script: "verif/regress/dual-hart-ci.sh",
        group: "directed",
        target: "cv64a6_smt2",
        dvTarget: "cv64a6_smt2",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        // Residual scaffold P1: bare DI minis (B1). Prefers work-ver-smt2-fw64 harness.
        // Not in defaultSuites. Map: architecture/multi-threading/soft-ladder/README.md
        id: "soft-ladder-di",
        description:
          "OPTIONAL residual: soft-ladder B1 directed DI minis (AMO/LRSC/CSR/c.mv + FDT minis). Prefers SOFT_LADDER_HARNESS=work-ver-smt2-fw64; COMPILE_ONLY=1 without harness. Not Zacas golden.",
        script: "verif/regress/soft-ladder-di-regress.sh",
        group: "directed",
        target: "g6lc64_smt2",
        dvTarget: "g6lc64_smt2",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc"],
        openSource: true,
        optional: true,
      },
      {
        // Residual scaffold P3: OpenSBI cookie soak. SUCCESS = trapdump 51b1babe only.
        // PEEL_* bisect only; soft getprop may be holding. Not defaultSuites.
        id: "soft-ladder-osbi",
        description:
          "OPTIONAL residual: OpenSBI DI soft-ladder cookie soak. SUCCESS=cookie 51b1babe only (not tohost). Prefers work-ver-smt2-fw64; PEEL_* env for bisect; needs oracle ELF source + prebuilt harness.",
        script: "verif/regress/soft-ladder-opensbi-soak.sh",
        group: "directed",
        target: "g6lc64_smt2",
        dvTarget: "g6lc64_smt2",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "smt-linux-boot-path",
        description:
          "OPTIONAL: SMT Linux boot path gate + real lint of cv64a6_smt2.",
        script: "verif/regress/smt-linux-boot-path.sh",
        group: "directed",
        target: "cv64a6_smt2",
        dvTarget: "cv64a6_smt2",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      {
        id: "smt-linux-rootfs",
        description:
          "OPTIONAL: SMT OpenSBI/rootfs track (R1–R3a). Auto-builds software/smt2-linux OpenSBI when toolchain+dtc present; sim if fw_payload.elf or CVA6_LINUX_PAYLOAD.",
        script: "verif/regress/smt-linux-rootfs.sh",
        group: "linux",
        target: "cv64a6_smt2",
        dvTarget: "cv64a6_smt2",
        dvSimulators: "veri-testharness",
        tools: [],
        openSource: true,
        optional: true,
      },
      // --- pk: proxy-kernel hosted suites ----------------------------------
      {
        id: "pk-tests",
        description: "Proxy-kernel (pk) hosted tests via veri-testharness-pk.",
        script: "verif/regress/veri-testharness-pk-tests.sh",
        group: "pk",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness-pk",
        tools: ["riscv-gcc", "verilator"],
        testSuiteInstallers: ["pk"],
        openSource: true,
        optional: true,
      },
      // --- uvm: UVM testbench suites (need a UVM-class simulator) -----------
      {
        id: "interrupt",
        description: "Interrupt UVM test (coverage-enabled).",
        script: "verif/regress/dv-interrupt-test.sh",
        group: "uvm",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm,spike",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "verilator", "spike"],
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "r3b-linux-image",
        description:
          "OPTIONAL: R3b Linux Image gate (contract + soft-skip without Image; CVA6_R3B_BUILD embeds Image in OpenSBI).",
        script: "verif/regress/r3b-linux-image.sh",
        group: "linux",
        target: "g6lc64_smt2",
        dvTarget: "g6lc64_smt2",
        dvSimulators: "veri-testharness,spike",
        tools: ["riscv-gcc"],
        openSource: true,
        optional: true,
      },
      {
        id: "csr-embedded",
        description: "Embedded CSR UVM tests.",
        script: "verif/regress/dv-csr-embedded-tests.sh",
        group: "uvm",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm,spike",
        tools: ["riscv-gcc", "spike"],
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "hwconfig",
        description: "Hardware-config permutation UVM tests.",
        script: "verif/regress/hwconfig_tests.sh",
        group: "uvm",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "verilator", "spike"],
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "pmp",
        description: "PMP UVM tests for cv32a65x.",
        script: "verif/regress/pmp_cv32a65x_tests.sh",
        group: "uvm",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm",
        tools: ["riscv-gcc", "spike"],
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "cvxif",
        description: "CV-X-IF coprocessor-interface UVM regression.",
        script: "verif/regress/cvxif_verif_regression.sh",
        group: "uvm",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm",
        tools: ["riscv-gcc", "verilator", "spike"],
        requiresUvm: true,
        openSource: false,
      },
      // --- generated: riscv-dv / corev-dv constrained-random ----------------
      {
        id: "smoke-gen",
        description: "Smoke of the corev-dv constrained-random generator flow.",
        script: "verif/regress/smoke-gen_tests.sh",
        group: "generated",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "verilator", "spike"],
        requiresSubmodule: "riscv-dv",
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "generated",
        description: "riscv-dv generated random program regression.",
        script: "verif/regress/dv-generated-tests.sh",
        group: "generated",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm,spike",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "spike"],
        requiresSubmodule: "riscv-dv",
        requiresUvm: true,
        openSource: false,
      },
      {
        id: "generated-xif",
        description: "riscv-dv generated CV-X-IF program regression.",
        script: "verif/regress/dv-generated-xif-tests.sh",
        group: "generated",
        target: "cv32a65x",
        dvSimulators: "vcs-uvm,spike",
        dvTarget: "cv32a65x",
        tools: ["riscv-gcc", "spike"],
        requiresSubmodule: "riscv-dv",
        requiresUvm: true,
        openSource: false,
      },
      // --- linux: full boot (heavy) ----------------------------------------
      {
        id: "linux",
        description: "Boot Linux (buildroot/opensbi image) on veri-testharness.",
        script: "verif/regress/linux.sh",
        group: "linux",
        target: "cv64a6_imafdc_sv39",
        dvSimulators: "veri-testharness",
        tools: ["riscv-gcc", "verilator"],
        openSource: false,
        optional: true,
      },
    ],
    defaultSuites: ["smoke-cv64a6"],
    parallelism: 1,
    seed: 1,
    uvmVerbosity: "UVM_NONE",
  },

  dependencies: {
    submodules: {
      "core-v-verif": {
        path: "verif/core-v-verif",
        url: "https://github.com/openhwgroup/core-v-verif",
        enabled: true,
      },
      cvfpu: {
        path: "core/cvfpu",
        url: "https://github.com/openhwgroup/cvfpu.git",
        enabled: true,
      },
      hpdcache: {
        path: "core/cache_subsystem/hpdcache",
        url: "https://github.com/openhwgroup/cv-hpdcache.git",
        enabled: true,
      },
      "riscv-dv": {
        path: "verif/sim/dv",
        url: "https://github.com/google/riscv-dv.git",
        enabled: true,
      },
    },
    gitTools: [],
    shallow: true,
    jobs: 4,
  },

  // Uncore controller + PHY catalog (the corev_apu "surrounding die"). This is
  // the typed migration of ad-hoc vendor/*.vendor.hjson pins into one control
  // surface the `vendor` command drives. Every entry is planned + disabled by
  // default: nothing is fetched until a contributor runs `vendor sync <id>` (or
  // `--all`). Refs are intentionally left to the default branch here; pin each
  // to a commit SHA before it moves from "vendored" to "integrated". Domains
  // and PHY notes are the source of the AGENTS-core-platform-vendor-actives.md
  // substructure table. See AGENTS-vendor.md for behaviour + licensing scope.
  vendor: {
    root: "vendor",
    jobs: 4,
    shallow: true,
    controllers: [
      // --- compute: RVV / Ara (U10ᵇ) ----------------------------------------
      {
        id: "ara",
        description: "PULP Ara RVV 1.0 vector unit for CVA6 accelerator seam (U10ᵇ).",
        domain: "util",
        kind: "support",
        mechanism: "submodule",
        url: "https://github.com/pulp-platform/ara.git",
        path: "vendor/ara/upstream",
        license: "Solderpad-0.51 / Apache-2.0 (upstream)",
        status: "vendored",
        enabled: false, // opt-in: do not auto-fetch; tree present after `vendor sync ara`
        scanPaths: ["hardware", "src", "ara"],
        integrationSeam: "core/acc_dispatcher.sv + vendor/ara/Flist.ara; package cv64a6_server_math_v",
        phyNote: "Soft vector datapath; place as own clock/power island on ASIC.",
        architectureDoc: "architecture/ara-vector-attach.md",
      },
      // --- memory: DDR4/LPDDR controller + PHY -----------------------------
      {
        id: "litedram",
        description: "LiteDRAM DDR3/DDR4/LPDDR4 controller + FPGA PHYs (Migen-generated Verilog).",
        domain: "memory",
        kind: "controller+phy",
        mechanism: "submodule",
        url: "https://github.com/enjoy-digital/litedram.git",
        path: "vendor/litex/litedram",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["litedram/core", "litedram/phy"],
        integrationSeam: "corev_apu (AXI memory-side) / corev_apu/fpga/src",
        phyNote:
          "Controller is soft RTL; the DDR PHY is an FPGA vendor hard block (Xilinx MIG / Altera EMIF) or an ASIC foundry hard macro. Board supplies DIMM/clocking.",
        architectureDoc: "architecture/uncore/ddr4-controller.md",
      },
      // --- network: Ethernet MAC / NIC -------------------------------------
      {
        id: "verilog-ethernet",
        description: "Hand-written Verilog Ethernet MAC (MII/GMII/RGMII/XGMII); Corundum's base library.",
        domain: "network",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/alexforencich/verilog-ethernet.git",
        path: "vendor/forencich/verilog-ethernet",
        license: "MIT",
        status: "planned",
        enabled: false,
        scanPaths: ["rtl"],
        integrationSeam: "corev_apu/fpga/src (AXI-Stream ↔ AXI bridge)",
        phyNote:
          "MAC is on-die; external Ethernet PHY chip (e.g. RTL8211/DP83867) + magnetics + RJ45 on the board.",
        architectureDoc: "architecture/uncore/ethernet-controller.md",
      },
      {
        id: "liteeth",
        description: "LiteEth MAC + UDP/IP core (Migen-generated); alternative to verilog-ethernet.",
        domain: "network",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/enjoy-digital/liteeth.git",
        path: "vendor/litex/liteeth",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["liteeth"],
        integrationSeam: "corev_apu/fpga/src",
        phyNote: "MAC on-die; external PHY on board.",
        architectureDoc: "architecture/uncore/ethernet-controller.md",
      },
      {
        id: "corundum",
        description: "Corundum 10/25/100G NIC (verilog-ethernet + verilog-pcie based); high-end networking.",
        domain: "network",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/corundum/corundum.git",
        path: "vendor/corundum/corundum",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["fpga/common/rtl"],
        integrationSeam: "corev_apu (PCIe/AXI) — heavy; a stretch-goal NIC",
        phyNote: "MAC/PCS on-die; high-speed SerDes PHY is FPGA/ASIC vendor IP.",
        architectureDoc: "architecture/uncore/ethernet-controller.md",
      },
      // --- interconnect: PCIe root complex ---------------------------------
      {
        id: "verilog-pcie",
        description: "Hand-written Verilog PCIe DMA/host glue over vendor hard IP; NVMe/GPU expansion path.",
        domain: "interconnect",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/alexforencich/verilog-pcie.git",
        path: "vendor/forencich/verilog-pcie",
        license: "MIT",
        status: "planned",
        enabled: false,
        scanPaths: ["rtl"],
        integrationSeam: "corev_apu (AXI master/slave bridge to PCIe hard IP)",
        phyNote:
          "Controller glue is soft RTL; the PCIe SerDes PHY + link layer is a vendor hard block (Xilinx/Intel) on FPGA or DesignWare-class IP on ASIC. NVMe/GPU are PCIe endpoints reached through this + a Linux driver.",
        architectureDoc: "architecture/uncore/pcie-root-complex.md",
      },
      {
        id: "litepcie",
        description: "LitePCIe endpoint/DMA core (Migen-generated); alternative PCIe path for FPGA.",
        domain: "interconnect",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/enjoy-digital/litepcie.git",
        path: "vendor/litex/litepcie",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["litepcie"],
        integrationSeam: "corev_apu (AXI bridge to PCIe hard IP)",
        phyNote: "Uses FPGA PCIe hard block + transceivers; ASIC needs a hard PCIe PHY.",
        architectureDoc: "architecture/uncore/pcie-root-complex.md",
      },
      // --- display: HDMI/DVI encoder ---------------------------------------
      {
        id: "hdmi",
        description: "hdl-util/hdmi: pure-SystemVerilog HDMI 1.4b TMDS transmitter (video + audio).",
        domain: "display",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/hdl-util/hdmi.git",
        path: "vendor/hdl-util/hdmi",
        license: "MIT",
        status: "planned",
        enabled: false,
        scanPaths: ["src"],
        integrationSeam: "corev_apu/fpga/src (framebuffer/AXI-VDMA ↔ TMDS)",
        phyNote:
          "TMDS encoder is on-die; board carries the HDMI connector and (often) an ESD/level-shift or re-driver (e.g. TPD12S016 / SN65DP159).",
        architectureDoc: "architecture/uncore/hdmi-display.md",
      },
      // --- storage: SATA / SD (+ NVMe over PCIe, see storage doc) ----------
      {
        id: "litesata",
        description: "LiteSATA AHCI-style SATA controller (Migen-generated).",
        domain: "storage",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/enjoy-digital/litesata.git",
        path: "vendor/litex/litesata",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["litesata"],
        integrationSeam: "corev_apu (AXI) / corev_apu/fpga/src",
        phyNote: "Controller on-die; SATA SerDes PHY is FPGA transceiver / ASIC hard PHY.",
        architectureDoc: "architecture/uncore/storage-controllers.md",
      },
      {
        id: "litesdcard",
        description: "LiteSDCard SD/eMMC controller (Migen-generated).",
        domain: "storage",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/enjoy-digital/litesdcard.git",
        path: "vendor/litex/litesdcard",
        license: "BSD-2-Clause",
        status: "planned",
        enabled: false,
        scanPaths: ["litesdcard"],
        integrationSeam: "corev_apu (AXI) / corev_apu/fpga/src",
        phyNote: "Controller on-die; SD card slot + level shift on board.",
        architectureDoc: "architecture/uncore/storage-controllers.md",
      },
      // --- existing, already integrated (documented, not re-fetched) -------
      {
        id: "ariane-ethernet",
        description: "lowRISC RGMII 1G Ethernet already used by the Xilinx FPGA top (existing submodule).",
        domain: "network",
        kind: "controller",
        mechanism: "submodule",
        url: "https://github.com/lowRISC/ariane-ethernet.git",
        path: "corev_apu/fpga/src/ariane-ethernet",
        license: "SHL-0.51",
        status: "integrated",
        enabled: false,
        integrationSeam: "corev_apu/fpga/src/ariane_xilinx.sv",
        phyNote: "MAC on-die (FPGA); board RGMII PHY. Managed by .gitmodules, listed here for the map.",
        architectureDoc: "architecture/uncore/ethernet-controller.md",
      },
    ],
  },

  // Motherboard (corev-mb): no board is active by default so existing configs
  // and CI are untouched. `mb select <id>` sets activeBoard (via the gitignored
  // overlay) and adapts soc.coreConfig to the board's declared requirement.
  motherboard: {
    activeBoard: null,
    boardsRoot: "corev-mb/boards",
    architectureRoot: "corev-mb/architecture",
    libRoot: "corev-mb/lib",
    pcbParts: {
      mcpUrl: "https://pcbparts.dev/mcp",
      timeoutMs: 30000,
      retries: 2,
      // Under the managed workspace cache (gitignored), so re-queries are fast.
      cacheDir: ".cache/pcbparts",
      // Never hit the network unless a subcommand explicitly asks for it.
      requireExplicit: true,
      maxFixIterations: 4,
    },
  },

  physicalDesign: {
    flow: "none",
    constraintFiles: [],
  },

  // Technology optimization pass: OFF + "omitted" PDK by default, so every
  // existing config elaborates the generic, macro-protected tech-cell path and
  // CI is untouched. Arming needs BOTH technology.optimizationPass = true AND a
  // *.tech-spec.md doc under core/** or corev_apu/**; proprietary PDK views are
  // dropped under pdkRoot (gitignored). See AGENTS-technology.md / `cva6-build
  // tech`. The guard macro gates the RTL adaptation: undefined ⇒ generic path.
  technology: {
    optimizationPass: false,
    pdkMode: "omitted",
    activeTechnology: null,
    pdkRoot: "pd/pdk",
    areaRoots: ["pd/pdk/core", "pd/pdk/corev_apu"],
    specGlobs: ["core/**/*.tech-spec.md", "corev_apu/**/*.tech-spec.md"],
    guardMacro: "CVA6_TECH_OPT",
    protectedGlobs: ["pd/pdk/**"],
    requireExplicit: true,
  },

  // Per-change verification gate (AGENTS.md §0.2). One extracted OSS CAD Suite
  // supplies Verilator (lint/elab), SymbiYosys (bounded formal) and Yosys
  // (synthesis smoke); the sim stage reuses the regression suites above. The
  // suite root is relative to workspace/tooling and is fully gitignored.
  verify: {
    suite: {
      root: "oss-cad-suite",
      version: "2026-07-24",
    },
    flist: "core/Flist.cva6",
    // Global extras: empty so default targets stay free of opt-in IP deps.
    extraFlists: [],
    // Per-target extras: Ara RVV IP only when linting/synthing the _v package.
    // Requires `cva6-build vendor sync ara` (upstream tree + Flist.ara present).
    extraFlistsByTarget: {
      g6lc64_server_math_v: ["vendor/ara/Flist.ara"],
    },
    waiverFile: "verilator_config.vlt",
    top: "cva6",
    // RVV package needs typed accelerator interfaces for LSU/acc paths.
    topByTarget: {
      g6lc64_server_math_v: "g6lc_ara_lint_top",
    },
    // Default gate: full-feature 64-bit + minimal 32-bit. Production-heavy
    // packages (g6lc64_ooo / ooo_server, server_math, smt2, spec_deep) are
    // opt-in so every PR stays fast:
    //   cva6-build verify --target g6lc64_ooo_server
    //   cva6-build test --suite ooo-l3-tests
    targets: ["cv64a6_imafdc_sv39", "cv32a65x"],
    // Mirrors the accepted Verilator flag set in the repo-root Makefile
    // (`verilate_command`): -Wall with the project's long-standing waivers, and
    // PINMISSING/IMPLICIT promoted to errors. -Wno-fatal keeps Verilator's exit
    // code clean so the gate below can judge warnings against a baseline.
    lintArgs: [
      "--no-timing",
      "-Wall",
      "-Werror-PINMISSING",
      "-Werror-IMPLICIT",
      "-Wno-fatal",
      "-Wno-PINCONNECTEMPTY",
      "-Wno-ASSIGNDLY",
      "-Wno-DECLFILENAME",
      "-Wno-UNUSED",
      "-Wno-UNOPTFLAT",
      "-Wno-BLKANDNBLK",
      "-Wno-style",
    ],
    // Synthesis does not consume SVA. HPDCACHE_ASSERT_OFF is the hpdcache IP's
    // own guard (see hpdcache/rtl/src/common/hpdcache_fxarb.sv); SYNTHESIS is
    // the conventional macro. Neither is defined for lint or simulation.
    synthDefines: ["HPDCACHE_ASSERT_OFF", "SYNTHESIS"],
    // U5 OoO bounded formal scaffolds (architecture/remaining-upgrade-sequence.md
    // next-work #3; AGENTS-specs-to-impl.md "OoO formal"). Self-contained prop
    // modules under core/ooo/formal/ — do not require full-core elaboration.
    formalTasks: [
      "core/ooo/formal/g6lc_ooo_freelist.sby",
      "core/ooo/formal/g6lc_ooo_rob.sby",
      "core/ooo/formal/g6lc_ooo_cancel.sby",
      "core/ooo/formal/g6lc_ooo_rename.sby",
    ],
    simSuites: ["smoke-cv64a6", "smoke-cv32a65x"],
    stages: { lint: true, formal: true, sim: true, synth: true },
    // Measured 2026-07-24 with the flag set above. Dominated by vendored cvfpu
    // and cache IP: WIDTHEXPAND 207, ASCRANGE 101, WIDTHTRUNC 72, SELRANGE 61,
    // LATCH 38. New RTL must not push these up.
    warningBaseline: {
      // 483 at the 2026-07-24 measurement; ratcheted to 482 when U8a's explicit
      // mhpmevent WARL slice removed a WIDTHTRUNC warning; ratcheted to 481
      // when U7a landed; 482 with U1 TAGE-lite; 483 with U3 I$ way-predictor.
      // cv32a65x: was 138 when g6lc_* instances failed to elaborate (under-count);
      // re-measured 2026-08-06 after g6lc instance rename (full elab): 146.
      cv64a6_imafdc_sv39: 483,
      cv32a65x: 146,
    },
    failOnMissingBaseline: false,
  },

  // Compartmentalized diagnostics: each test owns Verilator surface / probe caps.
  // Run: `cva6-build diag run` or `probe diag`. Not a substitute for full verify.
  diagnostics: {
    defaultCompartments: ["host", "core"],
    tests: [
      // --- host: probe-style capability gates (no Verilator) ---------------
      {
        id: "diag-host-bun",
        description: "Bun runtime on PATH (build-platform CLI).",
        compartment: "host",
        kind: "probe-cap",
        probeCaps: ["bun"],
      },
      {
        id: "diag-host-git",
        description: "git on PATH (submodules / vendor).",
        compartment: "host",
        kind: "probe-cap",
        probeCaps: ["git"],
      },
      {
        id: "diag-host-shell",
        description: "bash or pwsh available for regress scripts.",
        compartment: "host",
        kind: "probe-cap",
        probeCaps: ["bash"],
        optional: true,
      },
      {
        id: "diag-host-wsl",
        description: "WSL on Windows for Spike / R3 cosim (n/a on Linux).",
        compartment: "host",
        kind: "probe-cap",
        probeCaps: ["linux-or-wsl"],
      },
      // --- core: default verify surface (imafdc) ---------------------------
      {
        id: "diag-core-lint-imafdc",
        description: "Verilator --lint-only for cv64a6_imafdc_sv39 (default top cva6).",
        compartment: "core",
        kind: "verilator-lint",
        tools: ["verilator"],
        verilator: {
          target: "cv64a6_imafdc_sv39",
          // inherit verify.lintArgs + baseline
        },
      },
      {
        id: "diag-core-lint-cv32a65x",
        description: "Verilator lint of minimal 32-bit package (elaboration hygiene).",
        compartment: "core",
        kind: "verilator-lint",
        tools: ["verilator"],
        verilator: {
          target: "cv32a65x",
        },
      },
      {
        id: "diag-core-flist",
        description: "core/Flist.cva6 and verilator_config.vlt present.",
        compartment: "core",
        kind: "path-check",
        paths: ["core/Flist.cva6", "verilator_config.vlt", "core/include/config_pkg.sv"],
      },
      // --- smt2: dual-hart package (own TARGET_CFG) ------------------------
      {
        id: "diag-smt2-paths",
        description: "SMT2 config package + dual-hart DTS artifacts.",
        compartment: "smt2",
        kind: "path-check",
        paths: [
          "core/include/g6lc64_smt2_config_pkg.sv",
          "corev_apu/bootrom/ariane-smt2.dts",
          "verif/regress/smt-linux-r3-cosim.sh",
        ],
      },
      {
        // Residual scaffold P0: scripts + docs present (not a sim gate).
        id: "diag-soft-ladder-paths",
        description:
          "Soft-ladder residual scaffold: suite drivers + architecture map + oracle path.",
        compartment: "residual",
        kind: "path-check",
        paths: [
          "verif/regress/soft-ladder-di-regress.sh",
          "verif/regress/soft-ladder-opensbi-soak.sh",
          "architecture/multi-threading/soft-ladder/README.md",
          "software/smt2-linux/soft-ladder/mk_plat_skip.py",
        ],
      },
      {
        id: "diag-smt2-lint",
        description: "Verilator lint of g6lc64_smt2 (NrHarts=2 package).",
        compartment: "smt2",
        kind: "verilator-lint",
        tools: ["verilator"],
        optional: true,
        verilator: {
          target: "g6lc64_smt2",
          // SMT2 may add warnings; own budget so core baseline is not polluted.
          warningBudget: 600,
        },
      },
      {
        id: "diag-smt2-payload",
        description: "OpenSBI fw_payload.elf present (R3a).",
        compartment: "smt2",
        kind: "path-check",
        optional: true,
        paths: ["build-platform/workspace/smt2-linux/fw_payload.elf"],
      },
      {
        id: "diag-smt2-caps",
        description: "Probe caps for dual-hart residual path.",
        compartment: "smt2",
        kind: "probe-cap",
        optional: true,
        probeCaps: ["riscv-gcc", "opensbi-smt2"],
      },
      // --- ooo: formal props present (path) + package lint -----------------
      {
        id: "diag-ooo-formal-paths",
        description: "OoO formal property packages on disk.",
        compartment: "ooo",
        kind: "path-check",
        paths: [
          "core/ooo/formal/g6lc_ooo_freelist.sby",
          "core/ooo/formal/g6lc_ooo_rob.sby",
          "core/ooo/formal/g6lc_ooo_rename.sby",
        ],
      },
      {
        id: "diag-ooo-lint",
        description: "Verilator lint of g6lc64_ooo config package.",
        compartment: "ooo",
        kind: "verilator-lint",
        tools: ["verilator"],
        optional: true,
        verilator: {
          target: "g6lc64_ooo",
          warningBudget: 650,
        },
      },
      // --- apu / ara residual ----------------------------------------------
      {
        id: "diag-ara-flist",
        description: "Ara Flist present when RVV path is in-tree.",
        compartment: "apu",
        kind: "path-check",
        optional: true,
        paths: ["vendor/ara/Flist.ara", "verif/tb/g6lc_ara_lint_top.sv"],
      },
      {
        id: "diag-ara-lint",
        description: "Verilator lint of server_math_v with Ara extras (own flist/top).",
        compartment: "apu",
        kind: "verilator-lint",
        tools: ["verilator"],
        optional: true,
        verilator: {
          target: "g6lc64_server_math_v",
          top: "g6lc_ara_lint_top",
          extraFlists: ["vendor/ara/Flist.ara"],
          warningBudget: 800,
        },
      },
      // --- residual: managed tooling paths ---------------------------------
      {
        id: "diag-residual-spike",
        description: "Managed Spike binary under workspace/tooling.",
        compartment: "residual",
        kind: "probe-cap",
        optional: true,
        probeCaps: ["spike"],
      },
      {
        id: "diag-residual-verilator",
        description: "Verilator available (managed, PATH, or WSL residual).",
        compartment: "residual",
        kind: "probe-cap",
        optional: true,
        probeCaps: ["verilator"],
      },
    ],
  },

  platform: {
    // Installing OS packages is destructive/side-effecting, so it is opt-in.
    allowSystemInstall: false,
    windowsUseVsBuildTools: true,
    vsBuildToolsEdition: "2026",
  },

  logging: {
    level: "info",
    color: true,
    timestamps: false,
  },
};
