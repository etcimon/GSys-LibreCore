// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * Public TypeScript API for a bun + svelte-d project.
 * Native side: bin/svelte-d.exe (CLI) + lib/svelte-d.dll (bun:ffi).
 *
 * Guiding principles:
 *  - Kit syntax falls through to libwasm / vibe.0 in an equivalent
 *    svelte-engine-ws tree (mapKitPath).
 *  - Kit features and further development are accommodated in
 *    svelte-engine / libwasm / vibe.0; compile integrates the engine
 *    as the ws bootstrap (accommodateFeatures / verifyBootstrap).
 */
export {
  compileWorkspace,
  dropWorkspace,
  buildWasm,
  buildHost,
  parseSvelte,
  runCli,
  ffiAvailable,
  type RunResult,
  type CompileOpts,
} from './native.ts'
export {
  findRiscvDev,
  findLibwasmRoot,
  findLibwasmCheckout,
  workspaceDir,
  templateDir,
  bundledTemplateDir,
  isSvelteDPackage,
  kitProjectDir,
  findKitProjectRoot,
  nativeExe,
  nativeLib,
  nativeArtifacts,
  pkgRoot,
} from './paths.ts'
export {
  defineConfig,
  loadSvelteDConfig,
  findSvelteDConfigPath,
  resolveConfigWorkspace,
  parseWorkspaceField,
  svelteDConfigNames,
  type SvelteDConfig,
  type LoadedSvelteDConfig,
} from './config.ts'
export {
  mapKitPath,
  normalizeKitRel,
  identFromRel,
  sanitizeDestDir,
  sanitizeDestSeg,
  kitToPattern,
  kitToPatterns,
  type Fallthrough,
} from './fallthrough.ts'
export {
  requiredSurfaces,
  accommodateFeatures,
  missingSurfaces,
  verifyBootstrap,
  type Surface,
  type Accommodate,
} from './bootstrap.ts'
export {
  lodashCore,
  libwasmLodashPath,
  scanLodashCatalog,
  loadLodashCatalog,
  lodashMethodsUsed,
} from './lodash.ts'
export {
  coreTypes,
  coreBindings,
  routerNames,
  libwasmRoot,
  loadBindingsCatalog,
  serveSurfaces,
} from './libwasm.ts'
export { domUdas, extractDomUdas } from './dom.ts'
export {
  debugMapPath,
  loadDebugMap,
  lookupOrig,
  rewriteStack,
  rewriteConsole,
  destFromUrl,
  rewriteDevtoolsFrame,
  rewriteCdpStack,
  formatWasmAbort,
  kitLogLevel,
  colorizeHostLog,
  formatBridgeLine,
  overlayPath,
  loadOverlay,
  inspectorPath,
  loadInspector,
  destFromWasmName,
  destToModule,
  demangleD,
  lookupWasmOrig,
  isWasmUrl,
  type DebugEntry,
  type DebugMap,
  type DevtoolsFrame,
  type KitLogLevel,
  type OverlayDiag,
  type OverlayReport,
  type InspectorReport,
} from './debug.ts'
export {
  adaptWorkspace,
  normalizeAdapter,
  readWsManifest,
  manifestPath,
  ADAPTERS,
  type AdapterName,
  type AdaptOpts,
  type AdapterReport,
  type ManifestV1,
} from './adapter.ts'
export {
  hostTriple,
  findLdc,
  findDub,
  findVibe0Checkout,
  findWasmOpt,
  findBinaryenSource,
  findBinaryenBuildRoot,
  findCMake,
  buildWasmOptFromSource,
  shouldBuildWasmOptFromSource,
  isForkedWasmOpt,
  forkedWasmOptHome,
  forkedWasmOptDownloadUrl,
  forkedWasmOptDownloadUrls,
  forkedWasmOptArtifactUrls,
  setupPlatform,
  downloadLdc,
  downloadBinaryen,
  downloadForkedWasmOpt,
  ensureForkedWasmOpt,
  ensureForkedWasmOptSync,
  ensureOpensslForDub,
  ldcDownloadUrl,
  binaryenDownloadUrl,
  binaryenVariant,
  binaryenBuildVariant,
  isLdc143,
  isLdc143Text,
  isWasmOptNew,
  isWasmOptNewText,
  parseWasmOptVersion,
  optimizeWasm,
  DEFAULT_LDC_VERSION,
  DEFAULT_BINARYEN_VERSION,
  DEFAULT_WASM_OPT_RELEASE,
  DEFAULT_WASM_OPT_REPO,
  DEFAULT_WASM_OPT_BINARIES_BRANCH,
  BINARYEN_FORK_TAG,
  MIN_WASM_OPT_VERSION,
  WASM_EH_FEATURES,
  WASM_ASYNCIFY_ARGS,
  type HostTriple,
  type PlatformReport,
  type OptimizeWasmMode,
  type OptimizeWasmResult,
} from './platform.ts'
export {
  parseWasmNames,
  writeWasmNameMap,
  loadWasmNames,
  wasmNamesPath,
  encodeNamedWasm,
  type WasmNameFn,
  type WasmNameReport,
} from './wasm_names.ts'
