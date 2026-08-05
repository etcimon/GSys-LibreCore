// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// @sv-timing/js — public TypeScript API for hosts and integration tests.

export {
  SvTimingClient,
  createClient,
} from "./client.ts";

export {
  packageRootFromJs,
  analyzeSchemaPath,
  builtCliPath,
  containedCargo,
  containedRustEnv,
} from "./paths.ts";

export type {
  AnalyzeOptions,
  AnalyzeResult,
  AnalyzedFile,
  AstStub,
  CorrectOptions,
  CorrectResult,
  DebugExportOptions,
  DebugExportResult,
  EditRecordDto,
  IntegrityReportDto,
  OpportunityDto,
  OriginKind,
  SourceLoc,
  StatusResult,
  SvTimingClientOptions,
  VersionBannerDto,
} from "./types.ts";

export {
  isAnalyzeResult,
  isCorrectResult,
  isDebugExportResult,
} from "./types.ts";
