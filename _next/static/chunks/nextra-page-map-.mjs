import meta from "../../../pages/_meta.ts";
import architecture_meta from "../../../pages/architecture/_meta.ts";
import build_platform_meta from "../../../pages/build-platform/_meta.ts";
import core_meta from "../../../pages/core/_meta.ts";
import corev_apu_meta from "../../../pages/corev-apu/_meta.ts";
import corev_mb_meta from "../../../pages/corev-mb/_meta.ts";
import guides_meta from "../../../pages/guides/_meta.ts";
import sv_timing_meta from "../../../pages/sv-timing/_meta.ts";
import technology_meta from "../../../pages/technology/_meta.ts";
export const pageMap = [{
  data: meta
}, {
  name: "architecture",
  route: "/architecture",
  children: [{
    data: architecture_meta
  }, {
    name: "ai-development",
    route: "/architecture/ai-development",
    frontMatter: {
      "title": "AI / Agent Development",
      "description": "How LLM agents navigate CVA6, use the AGENTS-* guides, and drive the build platform."
    }
  }, {
    name: "index",
    route: "/architecture",
    frontMatter: {
      "title": "Architecture & Worktree",
      "description": "How CVA6 is organized from core to product, and how to read the repository as an SoC architecture."
    }
  }, {
    name: "sku-matrix",
    route: "/architecture/sku-matrix",
    frontMatter: {
      "title": "Product SKU Matrix",
      "description": "Compare GSys LibreCore config packages — issue width, OoO, SMT, cores, L2/L3, H/Sstc, RVV, and typical use."
    }
  }, {
    name: "specs-and-dts",
    route: "/architecture/specs-and-dts",
    frontMatter: {
      "title": "Specs, DTS & Architecture",
      "description": "How the RISC-V specification, Linux device-tree, and architecture documents stay aligned across core, controllers, and board PHY."
    }
  }, {
    name: "upgrade-program",
    route: "/architecture/upgrade-program",
    frontMatter: {
      "title": "Upgrade Program",
      "description": "Product-level map of GSys LibreCore microarchitecture upgrades (U1–U10) — what shipped, what is gated, and where to read next."
    }
  }, {
    name: "worktree",
    route: "/architecture/worktree",
    frontMatter: {
      "title": "Worktree Map",
      "description": "A high-level tour of every top-level directory in the CVA6 repository and what it is for."
    }
  }]
}, {
  name: "build-platform",
  route: "/build-platform",
  children: [{
    data: build_platform_meta
  }, {
    name: "extending",
    route: "/build-platform/extending",
    frontMatter: {
      "title": "Extending the Platform",
      "description": "How to add a command, config option, tool, test suite, or vendor controller to g6lc-build."
    }
  }, {
    name: "index",
    route: "/build-platform",
    frontMatter: {
      "title": "Build Platform",
      "description": "The g6lc-build command and how it orchestrates the CVA6 flow."
    }
  }, {
    name: "timings",
    route: "/build-platform/timings",
    frontMatter: {
      "title": "Timings Command",
      "description": "g6lc-build timings — host adapter for the independent sv-timing package (structural FO4 analyze and auto-correct)."
    }
  }, {
    name: "verify-and-diag",
    route: "/build-platform/verify-and-diag",
    frontMatter: {
      "title": "Probe, Diag & Verify",
      "description": "Operator workflow for host readiness, compartmentalized diagnostics, and the AGENTS.md §0.2 verify gate."
    }
  }]
}, {
  name: "core",
  route: "/core",
  children: [{
    data: core_meta
  }, {
    name: "cpu-architecture",
    route: "/core/cpu-architecture",
    frontMatter: {
      "title": "CPU Architecture Guidelines",
      "description": "Patterns and rules for developing the CVA6 CPU architecture."
    }
  }, {
    name: "devin-agents",
    route: "/core/devin-agents",
    frontMatter: {
      "title": "Agent Workflow for Core Development",
      "description": "How an LLM agent develops CPU core features in CVA6."
    }
  }, {
    name: "frontend-extensions",
    route: "/core/frontend-extensions",
    frontMatter: {
      "title": "Frontend Extensions",
      "description": "GSys LibreCore frontend upgrades — prediction fabric, FTQ/FDIP, way prediction, and config seams."
    }
  }, {
    name: "hypervisor",
    route: "/core/hypervisor",
    frontMatter: {
      "title": "Hypervisor & Sstc",
      "description": "RISC-V H extension and Sstc guest timers on GSys LibreCore — CSR surface, G-stage, enable order."
    }
  }, {
    name: "index",
    route: "/core",
    frontMatter: {
      "title": "CPU Core",
      "description": "The CVA6 RISC-V core and how to develop it."
    }
  }, {
    name: "multi-issue",
    route: "/core/multi-issue",
    frontMatter: {
      "title": "Multi-Issue",
      "description": "Config-gated multi-issue (2–8 ports) on GSys LibreCore — width, superscalar, and interaction with OoO."
    }
  }, {
    name: "out-of-order",
    route: "/core/out-of-order",
    frontMatter: {
      "title": "Out-of-Order Execution",
      "description": "Production config-gated OoO backend (rename, IQ, ROB, LSQ) and slice-OoO path for GSys LibreCore."
    }
  }, {
    name: "server-profiles",
    route: "/core/server-profiles",
    frontMatter: {
      "title": "Server Profiles",
      "description": "Production config packages for server, OoO, math, and hypervisor-oriented GSys LibreCore targets."
    }
  }, {
    name: "smt",
    route: "/core/smt",
    frontMatter: {
      "title": "Simultaneous Multithreading",
      "description": "SMT2 on GSys LibreCore — banked arch state, fine-grain switch, Linux/OpenSBI bring-up."
    }
  }, {
    name: "vector",
    route: "/core/vector",
    frontMatter: {
      "title": "Vector (RVV) & Ara",
      "description": "RVV 1.0 / Ara accelerator attach on GSys LibreCore — packages, flist, DTS, and open software items."
    }
  }]
}, {
  name: "corev-apu",
  route: "/corev-apu",
  children: [{
    data: corev_apu_meta
  }, {
    name: "controllers",
    route: "/corev-apu/controllers",
    frontMatter: {
      "title": "Controllers & PHY",
      "description": "Adding uncore controllers and PHY to corev_apu, with AXI seams and board alignment."
    }
  }, {
    name: "devin-agents",
    route: "/corev-apu/devin-agents",
    frontMatter: {
      "title": "Agent Workflow for corev_apu",
      "description": "How an LLM agent integrates uncore controllers and PHY into corev_apu."
    }
  }, {
    name: "index",
    route: "/corev-apu",
    frontMatter: {
      "title": "corev_apu",
      "description": "The CORE-V-APU uncore / FPGA emulation platform that wraps the CVA6 core."
    }
  }, {
    name: "l2-l3-cache",
    route: "/corev-apu/l2-l3-cache",
    frontMatter: {
      "title": "L2 / L3 Cache",
      "description": "Memory-side L2/L3 hierarchy and server prefetcher in corev_apu — config-gated, RVWMO-safe."
    }
  }, {
    name: "multi-core",
    route: "/corev-apu/multi-core",
    frontMatter: {
      "title": "Multi-Core Cluster",
      "description": "Parameterized 1–8 coherent CVA6 cores — cluster wrapper, snoop hub, shared L2/L3, CLINT/PLIC scaling."
    }
  }]
}, {
  name: "corev-mb",
  route: "/corev-mb",
  children: [{
    data: corev_mb_meta
  }, {
    name: "board-layer",
    route: "/corev-mb/board-layer",
    frontMatter: {
      "title": "Board Layer",
      "description": "How corev-mb fits around the die and how boards are described, selected, and validated."
    }
  }, {
    name: "devin-agents",
    route: "/corev-mb/devin-agents",
    frontMatter: {
      "title": "Agent Workflow for corev-mb",
      "description": "How an LLM agent selects, checks, and designs a CVA6 board."
    }
  }, {
    name: "index",
    route: "/corev-mb",
    frontMatter: {
      "title": "corev-mb",
      "description": "The motherboard / board layer around the CVA6 die."
    }
  }, {
    name: "skidl-process",
    route: "/corev-mb/skidl-process",
    frontMatter: {
      "title": "SKiDL Process",
      "description": "The SKiDL-based PCB design flow for custom corev-mb boards."
    }
  }]
}, {
  name: "getting-started",
  route: "/getting-started",
  frontMatter: {
    "title": "Getting Started",
    "description": "Bootstrap the LibreCore build platform and build the documentation site in one command."
  }
}, {
  name: "guides",
  route: "/guides",
  children: [{
    data: guides_meta
  }, {
    name: "agent-workflow",
    route: "/guides/agent-workflow",
    frontMatter: {
      "title": "Agent Workflow",
      "description": "How an LLM agent navigates CVA6, the AGENTS-* guides, and the build platform."
    }
  }, {
    name: "building-the-docs",
    route: "/guides/building-the-docs",
    frontMatter: {
      "title": "Building the Docs",
      "description": "How the CVA6 Next.js + Nextra documentation site is structured and extended."
    }
  }, {
    name: "index",
    route: "/guides",
    frontMatter: {
      "title": "Guides",
      "description": "Cross-cutting guides for AI agents, workflows, and maintaining this documentation."
    }
  }]
}, {
  name: "index",
  route: "/",
  frontMatter: {
    "title": "Introduction",
    "description": "GSys LibreCore docs — a Next.js-powered guide to LibreCore (G6LC), covering the CPU, uncore, motherboard, build platform, and agentic workflows."
  }
}, {
  name: "sv-timing",
  route: "/sv-timing",
  children: [{
    data: sv_timing_meta
  }, {
    name: "auto-correct",
    route: "/sv-timing/auto-correct",
    frontMatter: {
      "title": "Auto-Correct & -O Levels",
      "description": "Optional allowlisted sv-timing transforms, optimization presets, and safety rules for emitted SystemVerilog."
    }
  }, {
    name: "host-integration",
    route: "/sv-timing/host-integration",
    frontMatter: {
      "title": "Host Integration",
      "description": "How external tools and the CVA6 build-platform consume sv-timing without linking monorepo code into the package."
    }
  }, {
    name: "index",
    route: "/sv-timing",
    frontMatter: {
      "title": "sv-timing",
      "description": "Standalone SystemVerilog structural timing package — FO4-style IR, path ranking, optional auto-correct. Not STA sign-off."
    }
  }, {
    name: "pipeline",
    route: "/sv-timing/pipeline",
    frontMatter: {
      "title": "Pipeline & IR",
      "description": "Multi-step sv-timing pipeline from ingest through FO4 path ranking, reporting, and SQLite cache."
    }
  }]
}, {
  name: "technology",
  route: "/technology",
  children: [{
    data: technology_meta
  }, {
    name: "index",
    route: "/technology",
    frontMatter: {
      "title": "Technology / PDK",
      "description": "Foundry PDK adaptation and technology optimization for CVA6."
    }
  }, {
    name: "nda-optimization",
    route: "/technology/nda-optimization",
    frontMatter: {
      "title": "NDA Optimization Pass",
      "description": "Step-by-step workflow for adding foundry technology optimizations under NDA protection."
    }
  }]
}];