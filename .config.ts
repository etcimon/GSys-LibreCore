// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// .config.ts — CVA6 build-platform control surface.
//
// This is the SINGLE file most contributors edit. Every knob the platform
// understands (SoC target, toolchain pins, simulators, test suites, submodule
// pins, physical-design options) is set here; unspecified values fall back to
// build-platform/src/config/defaults.ts. See the full option catalog and
// documentation in build-platform/src/config/schema.ts.
//
//   ./build.sh config          (Linux/macOS)   — show the resolved config
//   .\build.ps1 config         (Windows)
//   bun build-platform/src/cli/index.ts config

import { defineBuildConfig } from "./build-platform/src/config/schema.ts";

export default defineBuildConfig({
  meta: {
    name: "CVA6",
    description: "OpenHW Group CVA6 application-class RISC-V core.",
  },

  // --- Silicon target (AGENTS-configuration.md §1.1 router class) ----------
  soc: {
    coreConfig: "cv64a6_imafdc_sv39",
    xlen: 64,
    extensions: ["i", "m", "a", "f", "d", "c", "zicsr", "zifencei"],
    targetFrequencyMHz: 1250,
    targetVoltageV: 0.8,
    process: "tsmc12ffc-class",
  },

  // --- Simulators ----------------------------------------------------------
  simulation: {
    enabled: ["verilator", "spike"],
    default: "verilator",
  },

  // --- Toolchain pins (see schema.ts for every field) ----------------------
  toolchain: {
    versions: {
      verilator: "v5.008",
      spike: "vendored",
      iverilog: "v12_0",
      dtc: "1.6.1",
    },
  },

  // --- Regression suites run by `test` and `bun test` ----------------------
  tests: {
    defaultSuites: ["smoke-cv64a6"],
    parallelism: 1,
    seed: 1,
  },

  // --- Dependency pins (git-focused). Pin refs as the project needs. -------
  // dependencies: {
  //   submodules: {
  //     "core-v-verif": { ref: "cv6.0.0" },
  //   },
  // },

  // --- Uncore controllers + PHY (the corev_apu "surrounding die") ----------
  // The catalog (build-platform/src/config/defaults.ts → vendor.controllers)
  // lists DDR4/Ethernet/PCIe/HDMI/SATA/SD controllers the SoC can draw on.
  // Everything is planned + disabled by default; fetch on demand with:
  //   ./build.sh vendor list         (see the catalog grouped by domain)
  //   ./build.sh vendor sync <id>    (git submodule add/update a controller)
  //   ./build.sh vendor scan <id>    (enumerate its RTL before wiring it in)
  // Enable or re-pin an entry here, e.g.:
  // vendor: {
  //   controllers: [
  //     { id: "litedram", enabled: true, ref: "<commit-sha>" } as never,
  //   ],
  // },
  // See AGENTS-vendor.md and AGENTS-core-platform-vendor-actives.md.

  // --- Physical design (open flow off pd/synth; "none" by default) ---------
  physicalDesign: {
    flow: "none",
    // pdk: { name: "sky130hd" },
  },
});
