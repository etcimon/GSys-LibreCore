// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// schema.ts — The single, typed control surface for the LibreCore build platform.
//
// The top-level `.config.ts` at the repository root is the ONLY file a
// feature author should normally touch. Everything the platform does (which
// tools to install, which SoC config to elaborate, which regressions to run,
// which submodule pins to honour) is derived from a `ResolvedBuildConfig`.
//
// Authors write a `BuildConfigInput` (a deep-partial) via `defineBuildConfig`.
// `src/config/load.ts` deep-merges it over `src/config/defaults.ts` to produce
// a `ResolvedBuildConfig`, then validates it. Keeping the resolved shape and
// the input shape distinct means new options only need a default to become
// optional for every existing config — the key to "minimal customization work
// to adapt to new features".

/** Recursive partial used for the user-authored config. */
export type DeepPartial<T> = T extends (infer U)[]
  ? U[] | undefined
  : T extends object
    ? { [K in keyof T]?: DeepPartial<T[K]> }
    : T;

/** Host operating systems the platform targets. */
export type HostOS = "windows" | "linux" | "darwin";

/** Shells the platform can dispatch conditional commands into. */
export type ShellKind = "pwsh" | "powershell" | "bash" | "zsh" | "sh" | "cmd";

/** OS-native package managers used to bootstrap host prerequisites. */
export type PackageManager =
  | "chocolatey"
  | "winget"
  | "scoop"
  | "apt"
  | "dnf"
  | "pacman"
  | "zypper"
  | "brew";

/** RTL simulators / ISS the flow can drive. Open tools auto-install; the rest are detect-only. */
export type Simulator =
  | "verilator"
  | "spike"
  | "iverilog"
  | "vcs"
  | "questa"
  | "xcelium"
  | "vivado";

/** Open-source tools the platform installs into workspace/tooling. */
export type ManagedTool = "riscv-gcc" | "verilator" | "spike" | "iverilog";

/** Physical-design / synthesis back-ends. */
export type PhysicalDesignFlow =
  | "none"
  | "openroad"
  | "siliconcompiler"
  | "design-compiler";

/** How a build dependency (tool or submodule) is acquired. */
export type AcquisitionMethod = "git" | "prebuilt" | "package-manager" | "system";

// ---------------------------------------------------------------------------
// SoC / hardware target
// ---------------------------------------------------------------------------

/**
 * Describes the silicon target. `coreConfig` maps to a CVA6 config package in
 * `core/include/<coreConfig>_config_pkg.sv` (or a generated hwconfig). The
 * frequency/voltage/process fields feed the physical-design constraints and
 * the SoC-readiness reporting; they never silently change RTL behaviour.
 */
export interface SocConfig {
  /** CVA6 target config package name, e.g. "cv64a6_imafdc_sv39". */
  coreConfig: string;
  /** Register width. Must be consistent with `coreConfig`. */
  xlen: 32 | 64;
  /** ISA extension letters/keys advertised for this target (drives riscv,isa). */
  extensions: string[];
  /** Optional explicit ISA string; when omitted it is derived from `extensions`. */
  isaString?: string;
  /** Target clock frequency in MHz (drives clock-period constraints). */
  targetFrequencyMHz: number;
  /** Target core voltage in volts (documentation / power reporting). */
  targetVoltageV: number;
  /** Process/PDK node label, e.g. "sky130hd", "asap7", "gf12". */
  process: string;
  /** Optional path to a riscv-config YAML overriding the generated config. */
  riscvConfigYaml?: string;
  /** Optional hwconfig option string forwarded to cva6.py --hwconfig_opts. */
  hwconfigOpts?: string;
}

// ---------------------------------------------------------------------------
// Toolchain (compilers, python, pinned tool versions)
// ---------------------------------------------------------------------------

export interface RiscvGccConfig {
  /** Acquire a prebuilt tarball or build from source. */
  source: "prebuilt" | "source";
  /** Human-readable version tag for pinning / cache keys. */
  version: string;
  /** Download URL for a prebuilt toolchain (used when source === "prebuilt"). */
  prebuiltUrl?: Partial<Record<HostOS, string>>;
  /** Git repo + ref when building from source. */
  git?: { url: string; ref: string };
  /** Tool prefix, e.g. "riscv-none-elf-" or "riscv64-unknown-elf-". */
  toolPrefix?: string;
}

export interface PythonConfig {
  /** Minimum interpreter version required (e.g. "3.10"). */
  minVersion: string;
  /** Explicit interpreter to base the venv on; auto-detected when omitted. */
  interpreter?: string;
  /** Inline pinned requirements added to the managed venv. */
  requirements: string[];
  /** Repo-relative requirements.txt files to install into the venv. */
  requirementsFiles: string[];
}

/** Pinned versions for tools the platform can build/install itself. */
export interface ToolVersions {
  verilator: string;
  spike: string;
  iverilog: string;
  dtc: string;
  openroad?: string;
  siliconcompiler?: string;
}

export interface ToolchainConfig {
  riscvGcc: RiscvGccConfig;
  python: PythonConfig;
  versions: ToolVersions;
  /**
   * Preferred package manager per OS. `undefined` lets the platform pick the
   * first available manager it detects on the host.
   */
  packageManager: Partial<Record<HostOS, PackageManager>>;
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

export interface VerilatorOptions {
  /** Emit FST waveform tracing. */
  trace: boolean;
  /** Trace format when tracing is enabled. */
  traceFormat: "fst" | "vcd";
  /** Worker threads for the verilated model (0 = auto). */
  threads: number;
  /** Enable --timing (needed by some testbenches). */
  timing: boolean;
}

export interface SimulationConfig {
  /** Simulators the flow may use, in preference order. */
  enabled: Simulator[];
  /** Default simulator for `build`/`test` when none is specified. */
  default: Simulator;
  /** Maximum simulation cycles before a run is considered hung. */
  maxCycles: number;
  verilator: VerilatorOptions;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * Families of regression scripts under verif/regress. Groups let the CLI run a
 * coherent slice (e.g. every `arch` suite) and let `--open-source` pick only
 * the families runnable with the managed open-source toolchain.
 */
export type TestGroup =
  | "smoke" // fast per-target sanity (veri-testharness + spike)
  | "benchmark" // dhrystone / coremark / embench performance runs
  | "arch" // riscv-tests / riscv-arch-test / compliance ISA suites
  | "directed" // hand-written directed C/asm regressions
  | "uvm" // UVM testbench suites (need a UVM-class simulator)
  | "generated" // riscv-dv / corev-dv constrained-random generation
  | "pk" // proxy-kernel (pk) hosted suites
  | "linux"; // full Linux boot (buildroot/opensbi) — heavy

export interface TestSuite {
  /** Stable identifier used on the CLI and in bun test names. */
  id: string;
  /** One-line human description shown by `test --list`. */
  description: string;
  /** Repo-relative path to the driving regression script (verif/regress/*.sh). */
  script: string;
  /** Family this suite belongs to (drives group selection). */
  group: TestGroup;
  /** CVA6 target this suite runs against (documentation / DV_TARGET default). */
  target: string;
  /** Value exported as DV_SIMULATORS for the script. */
  dvSimulators: string;
  /** Exported as DV_TARGET when set (else the script's own default applies). */
  dvTarget?: string;
  /** Managed tools that must be present for the suite to run (preflight). */
  tools: ManagedTool[];
  /** verif/regress/install-*.sh test-suite installers the script sources. */
  testSuiteInstallers?: string[];
  /** Submodule id (see dependencies.submodules) the suite needs checked out. */
  requiresSubmodule?: string;
  /** Needs a UVM-capable simulator; skipped in open-source-only runs. */
  requiresUvm?: boolean;
  /** Runnable with only the managed open-source toolchain (no commercial EDA). */
  openSource: boolean;
  /** Heavy/slow — excluded from `--all` unless explicitly named. */
  optional?: boolean;
}

export interface TestsConfig {
  /** Named regression suites the platform knows how to run. */
  suites: TestSuite[];
  /** Suites that make up the default `bun test` / `test` run. */
  defaultSuites: string[];
  /** Parallel suite workers (hardware sims are heavy — keep small). */
  parallelism: number;
  /** Base RNG seed forwarded to constrained-random generation. */
  seed: number;
  /** UVM verbosity forwarded to the UVM testbench. */
  uvmVerbosity: "UVM_NONE" | "UVM_LOW" | "UVM_MEDIUM" | "UVM_HIGH" | "UVM_FULL";
}

// ---------------------------------------------------------------------------
// Dependencies (git-focused, cargo-like)
// ---------------------------------------------------------------------------

export interface SubmoduleSpec {
  /** Repo-relative checkout path (matches .gitmodules). */
  path: string;
  /** Upstream URL. */
  url: string;
  /** Pin: a tag, branch, or commit SHA the platform will checkout. */
  ref?: string;
  /** Whether `setup` should initialise/update this submodule. */
  enabled: boolean;
}

export interface GitToolSource {
  /** Tool id (matches a recipe in src/tooling/recipes). */
  id: string;
  url: string;
  ref: string;
}

export interface DependenciesConfig {
  /** Named submodule pins keyed by submodule id. */
  submodules: Record<string, SubmoduleSpec>;
  /** Extra git-sourced tools resolved cargo-style into workspace/tooling. */
  gitTools: GitToolSource[];
  /** Use shallow clones where possible. */
  shallow: boolean;
  /** Parallel git jobs for submodule update. */
  jobs: number;
}

// ---------------------------------------------------------------------------
// Vendor: uncore controllers + PHY (the corev_apu "surrounding die")
// ---------------------------------------------------------------------------
//
// The vendor catalog is the migration of the ad-hoc `vendor/*.vendor.hjson`
// pins + peripheral submodules into ONE typed, discoverable control surface.
// It answers "which external controller/PHY IP does the SoC uncore draw on,
// where does it live, at what pin, under what license, and is it wired in
// yet?" — and lets `vendor <sub>` fetch/update/scan them on demand. It never
// fetches anything implicitly: every entry defaults to disabled + planned so
// minimal checkouts stay minimal (mirrors the tests/dependencies philosophy).

/**
 * Functional domain of a vendored block. Drives grouping in `vendor --list`
 * and the recommended corev_apu placement (see AGENTS-core-platform-vendor-
 * actives.md). Domains map to the desktop-class uncore subsystems.
 */
export type VendorDomain =
  | "memory" // DDR/LPDDR/HBM controller + PHY
  | "network" // Ethernet MAC / PCS / NIC
  | "interconnect" // PCIe root complex, AXI/NoC bridges
  | "storage" // SATA/AHCI, SD/eMMC, NVMe glue
  | "display" // HDMI/DVI/DisplayPort encoders
  | "usb" // USB host/device controllers
  | "phy" // standalone PHY / SerDes wrappers
  | "peripheral" // low-speed: UART/SPI/I2C/GPIO/timer
  | "util"; // support IP: clocking, CDC, FIFOs

/** Whether a block is RTL controller logic, an analog/hard PHY, or both. */
export type VendorKind = "controller" | "phy" | "controller+phy" | "support";

/**
 * How the IP is brought into the tree:
 *  - "submodule": tracked git submodule (easy pinned update + scan). Preferred
 *    for controllers/PHY that are version-bumped and re-scanned over time.
 *  - "vendor": a flattened source snapshot (clone → strip .git → apply
 *    excludes → lock), mirroring the legacy `vendor/*.vendor.hjson` flow for
 *    IP that must be patched in-tree.
 */
export type VendorMechanism = "submodule" | "vendor";

/**
 * Lifecycle of a vendored block relative to the RTL build:
 *  - "planned": catalogued, not yet fetched or wired in.
 *  - "vendored": checked out on disk, not yet in a flist.
 *  - "integrated": referenced by a corev_apu flist / instantiated.
 */
export type VendorStatus = "planned" | "vendored" | "integrated";

/**
 * When a checked-out block must be re-scanned (its RTL enumerated so an agent
 * knows what to read before touching filelists / instantiation). Scanning is
 * deliberately explicit — big third-party trees are not walked on every run.
 */
export type VendorScanTrigger =
  | "on-fetch" // right after the initial checkout
  | "on-update" // after a ref bump / upgrade
  | "on-integrate" // when wiring the block into a corev_apu flist
  | "manual"; // only when explicitly requested

export interface VendorControllerSpec {
  /** Stable id used on the CLI and as the catalog key. */
  id: string;
  /** One-line human description (shown by `vendor --list`). */
  description: string;
  /** Functional domain (drives grouping + corev_apu placement guidance). */
  domain: VendorDomain;
  /** Controller vs PHY vs both vs support IP. */
  kind: VendorKind;
  /** Acquisition mechanism. */
  mechanism: VendorMechanism;
  /** Upstream git URL. */
  url: string;
  /** Pin: a tag/branch/commit the platform checks out. Pin to a SHA before integration. */
  ref?: string;
  /** Checkout path, repo-relative. For submodules this matches .gitmodules. */
  path: string;
  /** SPDX license id of the upstream (compliance / AGENTS-licensing.md). */
  license: string;
  /** Lifecycle relative to the RTL build. */
  status: VendorStatus;
  /** Whether a bare `vendor sync` (no ids) fetches this block. */
  enabled: boolean;
  /** Sub-paths (relative to `path`) worth scanning first; drives `vendor scan`. */
  scanPaths?: string[];
  /** Events that require a re-scan. Defaults to ["on-fetch","on-update","on-integrate"]. */
  scanOn?: VendorScanTrigger[];
  /** corev_apu integration seam pointer (e.g. "corev_apu/fpga/src"). */
  integrationSeam?: string;
  /** PHY split note: what is on-die controller vs board/external PHY. */
  phyNote?: string;
  /** Architecture outline doc, repo-relative (architecture/uncore/*.md). */
  architectureDoc?: string;
  /** Excludes applied when mechanism === "vendor" (snapshot prune list). */
  excludeFromUpstream?: string[];
  /** Override the catalog-wide shallow default for this block. */
  shallow?: boolean;
}

export interface VendorConfig {
  /** Root under which submodule/vendored controllers land (repo-relative). */
  root: string;
  /** The catalog of controller/PHY IP the platform can fetch, track, and scan. */
  controllers: VendorControllerSpec[];
  /** Parallel git jobs for vendor fetch. */
  jobs: number;
  /** Default to shallow clones where the mechanism allows. */
  shallow: boolean;
}

// ---------------------------------------------------------------------------
// Motherboard (corev-mb) — the board layer around the SoC/uncore
// ---------------------------------------------------------------------------

/**
 * How a board's schematic is authored. This is what lets the `mb` flow behave
 * like a unified "SoC + MB die and board configure" step while still allowing
 * the PCB schematic to be skipped when it does not apply:
 *  - "omitted": no SKiDL schematic (a third-party FPGA/dev board we only target
 *    — e.g. genesys2 — or any board whose PCB we do not author).
 *  - "reference": an OSHW board we reproduce/annotate for study, schematic is a
 *    read-only reference (pcbparts.dev `board_get`), not something we tape out.
 *  - "custom": a board we design in-tree with SKiDL (`design.py`), the only mode
 *    that runs ERC + emits a netlist/BOM.
 */
export type MotherboardSkidlMode = "omitted" | "reference" | "custom";

export interface PcbPartsConfig {
  /** pcbparts.dev MCP endpoint (Streamable HTTP JSON-RPC). */
  mcpUrl: string;
  /** Per-request timeout in milliseconds. */
  timeoutMs: number;
  /** Network retries for a failed tool call. */
  retries: number;
  /** Cache directory (workspace-relative unless absolute); tool results are memoised here. */
  cacheDir: string;
  /** Never touch the network implicitly — a tool call must be explicitly requested. */
  requireExplicit: boolean;
  /** Max ERC↔alternatives iterations `mb design --fix` will attempt. */
  maxFixIterations: number;
}

export interface MotherboardConfig {
  /** The single active board id, or null when no board is selected. */
  activeBoard: string | null;
  /** Root holding per-board machine specs: `<boardsRoot>/<id>/board.json`. */
  boardsRoot: string;
  /** Root holding per-board development architectural targets: `<architectureRoot>/<id>/`. */
  architectureRoot: string;
  /** Python package implementing the SKiDL design flow (custom boards only). */
  libRoot: string;
  /** pcbparts.dev MCP client settings. */
  pcbParts: PcbPartsConfig;
}

// ---------------------------------------------------------------------------
// Physical design
// ---------------------------------------------------------------------------

export interface PhysicalDesignConfig {
  flow: PhysicalDesignFlow;
  /** PDK descriptor; only required for real PnR flows. */
  pdk?: { name: string; root?: string; source?: AcquisitionMethod };
  /** Extra TCL/constraint files layered on top of pd/synth. */
  constraintFiles: string[];
}

// ---------------------------------------------------------------------------
// Technology optimization (proprietary / NDA PDK adaptation)
// ---------------------------------------------------------------------------
//
// CVA6 already exposes a PDK-swap seam: the tech_cells_generic primitives
// (tc_sram / tc_clk / tc_pwr), the `sram_cache` TECHNO_CUT parameter, and the
// hpdcache behav/blackbox/<tech> macro selection. This block is the *build*
// orchestration surface for an agentic "technology optimization pass" that
// binds a foundry's proprietary, high-level abstraction layers (memory
// compilers, ICG / retention / level-shifter cells, power kits, hard macros)
// at that seam WITHOUT ever committing NDA content.
//
// The pass is armed by a two-key ignition: (1) `optimizationPass: true`, and
// (2) the presence of a `*.tech-spec.md` doc (specGlobs) in a relevant core/**
// or corev_apu/** area. When either key is absent — the shipped default — the
// pass is inert and the generic, macro-protected RTL path elaborates exactly as
// today. Proprietary PDK views live under `pdkRoot` (gitignored; only the
// README/templates are committed). See AGENTS-technology.md.

/**
 * How the PDK is provided:
 *  - "omitted": no PDK on disk — the shipped default. The generic, behavioural
 *    tech-cell path is used and the pass is inert (guard macro undefined).
 *  - "open": an open/free PDK (e.g. sky130, nangate45 / FakeRAM) is present for
 *    study — trackable, not under NDA.
 *  - "nda": a proprietary foundry PDK is dropped in under `pdkRoot` — never
 *    committed; consumed only at synthesis / PnR behind the guard macro.
 */
export type TechnologyPdkMode = "omitted" | "open" | "nda";

export interface TechnologyConfig {
  /** Master switch (key 1 of the two-key ignition). Default false → pass inert. */
  optimizationPass: boolean;
  /** How the PDK is provided. Default "omitted" (no PDK; generic path). */
  pdkMode: TechnologyPdkMode;
  /** Active technology id (e.g. "tsmcN5", "gf12lp", "sky130hd"); null when omitted. */
  activeTechnology: string | null;
  /** Protected NDA drop-in root, repo-relative. Content gitignored; README/templates committed. */
  pdkRoot: string;
  /** Per-area protected roots the pass may write macro-protected wrappers into (core + corev_apu). */
  areaRoots: string[];
  /** Globs that locate the tech-spec docs scoping the pass (key 2 of the ignition). */
  specGlobs: string[];
  /** SystemVerilog `define` that macro-protects every adaptation (undefined ⇒ generic path). */
  guardMacro: string;
  /** Paths the pass must treat as protected: never commit content, never edit outside them. */
  protectedGlobs: string[];
  /** Never edit RTL / touch the network implicitly — an action must be explicitly requested. */
  requireExplicit: boolean;
}

// ---------------------------------------------------------------------------
// Verification gate (lint / formal / sim / synth)
// ---------------------------------------------------------------------------
//
// `AGENTS.md` §0.2 requires every RTL change to be synth-clean, verified and
// timing-aware. This block describes the per-change gate that enforces it with
// open tools: Verilator (lint + elaboration), SymbiYosys (bounded formal),
// Verilator/verif regress (simulation), and Yosys (synthesis smoke). The tools
// come from a single extracted OSS CAD Suite so the four stages share one pin.

/** Stages of the per-change gate; each can be toggled independently. */
export interface GateStages {
  lint: boolean;
  formal: boolean;
  sim: boolean;
  synth: boolean;
}

export interface EdaSuiteConfig {
  /**
   * Extracted OSS CAD Suite root. Relative paths resolve under
   * `workspace/tooling`; absolute paths are used as-is. The suite is a managed,
   * gitignored artifact — never committed.
   */
  root: string;
  /** Pinned release tag (YYYY-MM-DD) for reproducibility. */
  version: string;
}

export interface VerifyConfig {
  /** Where the open EDA binaries live. */
  suite: EdaSuiteConfig;
  /** Core manifest driven by every stage, repo-relative. */
  flist: string;
  /**
   * Optional additional manifests appended after `flist` (repo-relative).
   * Applied to **every** verify target. Prefer `extraFlistsByTarget` for
   * opt-in IP (e.g. Ara) so default targets stay free of extra deps.
   */
  extraFlists: string[];
  /**
   * Per-target extra manifests (repo-relative). Keys are bare config names
   * (e.g. `g6lc64_server_math_v`). Merged **after** global `extraFlists`.
   */
  extraFlistsByTarget: Record<string, string[]>;
  /** Verilator waiver/config file, repo-relative. */
  waiverFile: string;
  /** Top module elaborated by lint and synthesis (default). */
  top: string;
  /**
   * Per-target top override (e.g. `g6lc64_server_math_v` → `g6lc_ara_lint_top`
   * so accelerator interface types are injected for RVV packages).
   */
  topByTarget: Record<string, string>;
  /**
   * Config-package targets that must still elaborate. `AGENTS.md` §0.2 requires
   * minimal configs to keep elaborating, so the gate sweeps more than one.
   */
  targets: string[];
  /** Extra Verilator arguments appended to the lint invocation. */
  lintArgs: string[];
  /**
   * Macros defined for the synthesis stage only. Synthesis does not consume
   * SVA, so the IP's own assertion guards are asserted here rather than editing
   * or weakening the RTL.
   */
  synthDefines: string[];
  /** SymbiYosys task files run by the formal stage, repo-relative. */
  formalTasks: string[];
  /** Test suite ids (see tests.suites) run by the sim stage. */
  simSuites: string[];
  /** Stages enabled when `verify` runs with no explicit stage flag. */
  stages: GateStages;
  /**
   * Accepted Verilator warning count per target. The gate enforces "no NEW
   * warnings": it fails when a target exceeds its baseline. An absolute
   * zero-warning rule is not usable here because the vendored FPU and cache IP
   * carry a large, pre-existing and deliberately un-waived warning set.
   * Lower these numbers whenever a change removes warnings; never raise one
   * without saying why in the commit message.
   */
  warningBaseline: Record<string, number>;
  /** Fail a target that has no recorded baseline (forces the baseline to be owned). */
  failOnMissingBaseline: boolean;
}

// ---------------------------------------------------------------------------
// Compartmentalized diagnostics (probe + Verilator per-test configs)
// ---------------------------------------------------------------------------
//
// Diagnostics are small, self-contained gates used by `diag` / `probe diag`.
// Unlike `verify` (full multi-target sweep) each entry owns its Verilator
// surface: top, flist extras, lintArgs, warning budget, defines. Compartments
// group related checks (host probe caps, core lint, smt2, ooo, residual WSL).

/** Logical grouping for diagnostic tests (tab / filter key). */
export type DiagnosticCompartment =
  | "host"
  | "core"
  | "smt2"
  | "ooo"
  | "apu"
  | "residual";

/**
 * Per-diagnostic Verilator configuration. Unset fields fall back to
 * `verify.*` (top/flist/lintArgs/waiver/baseline for the target).
 */
export interface DiagnosticVerilatorConfig {
  /** Config-package name exported as TARGET_CFG (e.g. g6lc64_smt2). */
  target: string;
  /** Top module (default: verify.top / topByTarget). */
  top?: string;
  /** Primary flist, repo-relative (default: verify.flist). */
  flist?: string;
  /** Extra manifests for this diag only (repo-relative). */
  extraFlists?: string[];
  /**
   * Verilator CLI args. With lintArgsMode "append" (default) these follow
   * verify.lintArgs; "replace" uses only this list.
   */
  lintArgs?: string[];
  lintArgsMode?: "append" | "replace";
  /** +define+ macros for this diag only. */
  defines?: string[];
  /** Waiver file repo-relative (default: verify.waiverFile). */
  waiverFile?: string;
  /**
   * Max Verilator warnings accepted. `null` = use verify.warningBaseline[target]
   * when present, else unlimited for this diag. Omit to use baseline.
   */
  warningBudget?: number | null;
  /** Skip slang elaboration even when available. */
  skipSlang?: boolean;
}

export type DiagnosticKind =
  | "verilator-lint" // Verilator --lint-only with DiagnosticVerilatorConfig
  | "verilator-elab" // slang elaboration with same surface
  | "probe-cap" // capability ids from the probe matrix
  | "path-check"; // repo-relative paths that must exist

export interface DiagnosticTest {
  /** Stable id (`diag run <id>`). */
  id: string;
  description: string;
  compartment: DiagnosticCompartment;
  kind: DiagnosticKind;
  /** Soft: skip without failing the compartment if tools missing. */
  optional?: boolean;
  /** Managed tools required (preflight). */
  tools?: ManagedTool[];
  /** Own Verilator surface (required for verilator-* kinds). */
  verilator?: DiagnosticVerilatorConfig;
  /** Capability ids for kind probe-cap (e.g. bun, wsl, opensbi-smt2). */
  probeCaps?: string[];
  /** Repo-relative paths that must exist (kind path-check). */
  paths?: string[];
}

export interface DiagnosticsConfig {
  /** Named diagnostic tests, each with its own config surface. */
  tests: DiagnosticTest[];
  /**
   * Compartments included when `diag run` / `probe diag run` has no filter.
   * Empty = all non-optional tests.
   */
  defaultCompartments: DiagnosticCompartment[];
}

// ---------------------------------------------------------------------------
// Platform behaviour & logging
// ---------------------------------------------------------------------------

export interface PlatformConfig {
  /** Force a shell instead of the OS default (advanced/debug use). */
  shell?: Partial<Record<HostOS, ShellKind>>;
  /** Allow the platform to install OS packages (setup prerequisites). */
  allowSystemInstall: boolean;
  /** On Windows, request Visual Studio Build Tools provisioning. */
  windowsUseVsBuildTools: boolean;
  /** VS Build Tools edition label (e.g. "2026", "2022"). */
  vsBuildToolsEdition: string;
}

export interface LoggingConfig {
  level: "silent" | "error" | "warn" | "info" | "debug" | "trace";
  color: boolean;
  timestamps: boolean;
}

export interface WorkspaceConfig {
  /** Workspace root, relative to build-platform/ unless absolute. */
  root: string;
  /** Build-output subdirectory (fully managed, gitignored). */
  buildDir: string;
  /** Installed-tools + python venv subdirectory (fully managed). */
  toolingDir: string;
  /** Cache subdirectory for downloads and change-detection manifests. */
  cacheDir: string;
}

export interface MetaConfig {
  name: string;
  description: string;
  /** Repository root; auto-detected via git when omitted. */
  repoRoot?: string;
}

// ---------------------------------------------------------------------------
// Top-level shapes
// ---------------------------------------------------------------------------

/** Fully-resolved configuration consumed by the platform internals. */
export interface ResolvedBuildConfig {
  meta: MetaConfig;
  workspace: WorkspaceConfig;
  soc: SocConfig;
  toolchain: ToolchainConfig;
  simulation: SimulationConfig;
  tests: TestsConfig;
  dependencies: DependenciesConfig;
  vendor: VendorConfig;
  motherboard: MotherboardConfig;
  physicalDesign: PhysicalDesignConfig;
  technology: TechnologyConfig;
  verify: VerifyConfig;
  /** Compartmentalized diagnostic tests (probe + per-test Verilator configs). */
  diagnostics: DiagnosticsConfig;
  platform: PlatformConfig;
  logging: LoggingConfig;
}

/** User-authored configuration: any subset of the resolved shape. */
export type BuildConfigInput = DeepPartial<ResolvedBuildConfig>;

/**
 * Identity helper that gives full IntelliSense + type-checking in the
 * repository-root `.config.ts`. It intentionally returns the input unchanged;
 * resolution against defaults happens in `src/config/load.ts`.
 */
export function defineBuildConfig(config: BuildConfigInput): BuildConfigInput {
  return config;
}
