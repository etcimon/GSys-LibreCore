// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Parameterized localization spec for g6lc_tb.cpp.
// Off unless CVA6_TRACE / CVA6_TRACE_SPEC / CVA6_TRACE_FILE is set.
// Default soak-exit rules are installed separately (cookie / pin / WFI).

#ifndef G6LC_TB_TRACE_H
#define G6LC_TB_TRACE_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

enum G6lcTraceKind {
  G6LC_EXIT_COOKIE = 1,
  G6LC_EXIT_PIN,
  G6LC_EXIT_WFI,
  G6LC_EXIT_NPC,
  G6LC_LOG_NPC,
  G6LC_LOG_COMMIT,
  G6LC_LOG_MEM,
  G6LC_LOG_GPR
};

struct G6lcTraceRule {
  G6lcTraceKind kind;
  char tag[24];
  uint64_t lo, hi, val, off;
  unsigned hart, after, hits, maxn, every;
  unsigned gpr_mask;  // bits 1..31
  unsigned seen;
  uint64_t last_npc;
  uint64_t last_gpr[32];
  unsigned last_gpr_valid;
};

inline int g6lc_gpr_idx(const char *n) {
  if (!n || !*n) return -1;
  if (n[0] == 'x' || n[0] == 'X') {
    char *end = nullptr;
    long v = std::strtol(n + 1, &end, 10);
    if (end != n + 1 && v >= 0 && v <= 31) return (int)v;
  }
  static const char *abi[32] = {
      "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
      "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
      "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
      "s8",   "s9", "s10","s11","t3", "t4", "t5", "t6"};
  for (int i = 0; i < 32; i++)
    if (std::strcmp(n, abi[i]) == 0) return i;
  if (std::strcmp(n, "fp") == 0) return 8;
  return -1;
}

inline void g6lc_rule_init(G6lcTraceRule *r) {
  std::memset(r, 0, sizeof(*r));
  r->hi = ~0ULL;
  r->maxn = 16;
  r->every = 1;
  std::snprintf(r->tag, sizeof(r->tag), "loc");
}

inline void g6lc_rule_kv(G6lcTraceRule *r, const char *k, const char *v) {
  if (std::strcmp(k, "tag") == 0) {
    std::snprintf(r->tag, sizeof(r->tag), "%s", v);
  } else if (std::strcmp(k, "lo") == 0 || std::strcmp(k, "pc") == 0 ||
             std::strcmp(k, "mepc") == 0) {
    r->lo = std::strtoull(v, nullptr, 0);
    if (r->hi == ~0ULL) r->hi = r->lo;
  } else if (std::strcmp(k, "hi") == 0) {
    r->hi = std::strtoull(v, nullptr, 0);
  } else if (std::strcmp(k, "val") == 0 || std::strcmp(k, "mcause") == 0) {
    r->val = std::strtoull(v, nullptr, 0);
  } else if (std::strcmp(k, "off") == 0) {
    r->off = std::strtoull(v, nullptr, 0);
  } else if (std::strcmp(k, "hart") == 0) {
    r->hart = (unsigned)std::strtoul(v, nullptr, 0);
  } else if (std::strcmp(k, "after") == 0) {
    r->after = (unsigned)std::strtoul(v, nullptr, 0);
  } else if (std::strcmp(k, "hits") == 0) {
    r->hits = (unsigned)std::strtoul(v, nullptr, 0);
  } else if (std::strcmp(k, "max") == 0) {
    r->maxn = (unsigned)std::strtoul(v, nullptr, 0);
  } else if (std::strcmp(k, "every") == 0) {
    r->every = (unsigned)std::strtoul(v, nullptr, 0);
    if (r->every == 0) r->every = 1;
  } else if (std::strcmp(k, "gpr") == 0) {
    // Do not strtok the line (clobbers later kv: hart=/tag=).
    const char *p = v;
    while (*p) {
      while (*p == ',') p++;
      if (!*p) break;
      const char *e = p;
      while (*e && *e != ',') e++;
      char tok[8];
      unsigned n = (unsigned)(e - p);
      if (n >= sizeof(tok)) n = sizeof(tok) - 1;
      std::memcpy(tok, p, n);
      tok[n] = 0;
      int idx = g6lc_gpr_idx(tok);
      if (idx > 0 && idx < 32) r->gpr_mask |= 1u << idx;
      p = e;
    }
  }
}

inline bool g6lc_parse_rule(const char *line, G6lcTraceRule *r) {
  g6lc_rule_init(r);
  char buf[256];
  std::snprintf(buf, sizeof(buf), "%s", line);
  for (char *p = buf; *p; p++)
    if (*p == '\r' || *p == '\n') *p = 0;
  char *hash = std::strchr(buf, '#');
  if (hash) *hash = 0;
  char *act = std::strtok(buf, " \t");
  if (!act) return false;
  char *what = std::strtok(nullptr, " \t");
  if (!what) return false;
  if (std::strcmp(act, "exit") == 0) {
    if (std::strcmp(what, "cookie") == 0) {
      r->kind = G6LC_EXIT_COOKIE;
      r->off = 0x1000;
      r->val = 0x51b1babeULL;
      std::snprintf(r->tag, sizeof(r->tag), "cookie");
    } else if (std::strcmp(what, "pin") == 0) {
      r->kind = G6LC_EXIT_PIN;
      std::snprintf(r->tag, sizeof(r->tag), "pin");
    } else if (std::strcmp(what, "wfi") == 0) {
      r->kind = G6LC_EXIT_WFI;
      r->after = 200000;
      r->hits = 8;
      std::snprintf(r->tag, sizeof(r->tag), "wfi");
    } else if (std::strcmp(what, "npc") == 0) {
      r->kind = G6LC_EXIT_NPC;
      std::snprintf(r->tag, sizeof(r->tag), "npc");
    } else
      return false;
  } else if (std::strcmp(act, "log") == 0) {
    if (std::strcmp(what, "npc") == 0) {
      r->kind = G6LC_LOG_NPC;
      std::snprintf(r->tag, sizeof(r->tag), "npc");
    } else if (std::strcmp(what, "commit") == 0) {
      r->kind = G6LC_LOG_COMMIT;
      std::snprintf(r->tag, sizeof(r->tag), "commit");
    } else if (std::strcmp(what, "mem") == 0) {
      r->kind = G6LC_LOG_MEM;
      std::snprintf(r->tag, sizeof(r->tag), "mem");
    } else if (std::strcmp(what, "gpr") == 0) {
      r->kind = G6LC_LOG_GPR;
      std::snprintf(r->tag, sizeof(r->tag), "gpr");
    } else
      return false;
  } else
    return false;
  for (char *kv = std::strtok(nullptr, " \t"); kv; kv = std::strtok(nullptr, " \t")) {
    char *eq = std::strchr(kv, '=');
    if (!eq) continue;
    *eq = 0;
    g6lc_rule_kv(r, kv, eq + 1);
  }
  return r->kind != 0;
}

inline void g6lc_parse_text(const char *text, std::vector<G6lcTraceRule> *out) {
  if (!text) return;
  std::string s(text);
  for (char &c : s)
    if (c == ';') c = '\n';
  size_t i = 0;
  while (i < s.size()) {
    size_t j = i;
    while (j < s.size() && s[j] != '\n') j++;
    std::string line = s.substr(i, j - i);
    i = j + 1;
    const char *p = line.c_str();
    while (*p == ' ' || *p == '\t') p++;
    G6lcTraceRule r;
    if (g6lc_parse_rule(p, &r)) out->push_back(r);
  }
}

inline void g6lc_parse_file(const char *path, std::vector<G6lcTraceRule> *out) {
  FILE *f = std::fopen(path, "r");
  if (!f) return;
  char line[256];
  while (std::fgets(line, sizeof(line), f)) {
    G6lcTraceRule r;
    if (g6lc_parse_rule(line, &r)) out->push_back(r);
  }
  std::fclose(f);
}

inline void g6lc_default_exits(std::vector<G6lcTraceRule> *out, uint64_t pin_mepc,
                               uint64_t pin_mcause) {
  G6lcTraceRule r;
  g6lc_rule_init(&r);
  r.kind = G6LC_EXIT_COOKIE;
  r.off = 0x1000;
  r.val = 0x51b1babeULL;
  std::snprintf(r.tag, sizeof(r.tag), "cookie");
  out->push_back(r);
  g6lc_rule_init(&r);
  r.kind = G6LC_EXIT_PIN;
  r.lo = pin_mepc;
  r.val = pin_mcause;
  std::snprintf(r.tag, sizeof(r.tag), "pin");
  out->push_back(r);
  g6lc_rule_init(&r);
  r.kind = G6LC_EXIT_WFI;
  r.after = 200000;
  r.hits = 8;
  std::snprintf(r.tag, sizeof(r.tag), "wfi");
  out->push_back(r);
}

inline bool g6lc_in_win(uint64_t pc, uint64_t lo, uint64_t hi) {
  uint64_t p = pc & 0xffffffffULL;
  uint64_t a = lo & 0xffffffffULL;
  uint64_t b = hi & 0xffffffffULL;
  if (b < a) b = a;
  return p >= a && p <= b;
}

#endif
