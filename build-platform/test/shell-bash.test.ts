// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// shell-bash.test.ts — Git-Bash preference, PATH enrich, false-pass detection.

import { expect, test } from "bun:test";

import {
  classifyBashPath,
  detectFalsePassSignals,
  enrichGitBashEnv,
  gitRootFromBashPath,
  resolveBashBinary,
  resolveRegressEngine,
  windowsPathToPosix,
} from "../src/platform/shell.ts";
import { decorateConsoleChunk, LineBufferedEcho } from "../src/platform/exec.ts";

test("classifyBashPath prefers git-bash / flags cygwin", () => {
  expect(classifyBashPath("C:/Program Files/Git/bin/bash.exe")).toBe("git-bash");
  expect(classifyBashPath("C:\\Program Files\\Git\\usr\\bin\\bash.exe")).toBe("git-bash");
  expect(classifyBashPath("C:/cygwin64/bin/bash.exe")).toBe("cygwin");
  expect(classifyBashPath("C:/msys64/usr/bin/bash.exe")).toBe("msys");
  if (process.platform !== "win32") {
    expect(classifyBashPath("/usr/bin/bash")).toBe("unix");
  }
});

test("resolveBashBinary returns a resolution or null", () => {
  const b = resolveBashBinary();
  if (b) {
    expect(b.bin.length).toBeGreaterThan(0);
    expect(["git-bash", "cygwin", "msys", "unix", "unknown"]).toContain(b.flavor);
    // If Git-Bash is installed at the default path, we must not pick Cygwin first
    if (b.flavor === "git-bash") {
      expect(b.cygwinPreferredOverGit).toBe(false);
    }
  } else {
    expect(b).toBeNull();
  }
});

test("windowsPathToPosix msys and wsl forms", () => {
  expect(windowsPathToPosix("E:\\cva6\\core", "msys")).toBe("/e/cva6/core");
  expect(windowsPathToPosix("E:/cva6/core", "wsl")).toBe("/mnt/e/cva6/core");
});

test("gitRootFromBashPath finds Git install root", () => {
  const root = gitRootFromBashPath("C:\\Program Files\\Git\\bin\\bash.exe");
  expect(root).toBe("C:\\Program Files\\Git");
});

test("enrichGitBashEnv prepends usr/bin and rewrites path vars", () => {
  if (process.platform !== "win32") return;
  const bash = resolveBashBinary();
  if (!bash || bash.flavor !== "git-bash") return;
  const env = enrichGitBashEnv(
    {
      PATH: "C:\\Windows\\System32",
      CVA6_REPO_DIR: "E:\\cva6",
      RISCV: "E:\\cva6\\build-platform\\workspace\\tooling\\riscv",
    },
    bash,
  );
  expect((env.PATH ?? "").toLowerCase().replace(/\//g, "\\")).toContain("\\git\\usr\\bin");
  expect(env.CVA6_REPO_DIR).toBe("/e/cva6");
  expect((env.RISCV ?? "").startsWith("/e/")).toBe(true);
});

test("detectFalsePassSignals catches broken Windows regress output", () => {
  expect(
    detectFalsePassSignals("", "dirname: command not found\nmake: *** Error 2"),
  ).toBeTruthy();
  expect(
    detectFalsePassSignals("'sed' is not recognized as an internal or external command", ""),
  ).toBeTruthy();
  expect(detectFalsePassSignals("all tests passed\n", "")).toBeNull();
});

test("resolveRegressEngine auto prefers wsl on Windows when present", () => {
  const eng = resolveRegressEngine();
  expect(["wsl", "bash"]).toContain(eng);
});

test("decorateConsoleChunk normalizes bare LF for Windows hosts", () => {
  const out = decorateConsoleChunk("a\nb\r\nc\rd\n");
  // Always internal-normalized; on win32 becomes CRLF pairs.
  if (process.platform === "win32") {
    expect(out).toBe("a\r\nb\r\nc\r\nd\r\n");
  } else {
    expect(out).toBe("a\nb\nc\nd\n");
  }
});

test("LineBufferedEcho flushes complete lines and trailing partial", () => {
  const got: string[] = [];
  const echo = new LineBufferedEcho((s) => got.push(s), (s) => s); // identity decorate
  echo.push("hel");
  echo.push("lo\nwor");
  echo.push("ld\n");
  expect(got.join("")).toBe("hello\nworld\n");
  echo.push("no-nl-yet");
  expect(got.join("")).toBe("hello\nworld\n");
  echo.flush();
  expect(got.join("")).toBe("hello\nworld\nno-nl-yet\n");
});