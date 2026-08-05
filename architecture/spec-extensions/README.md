# Extension point: further RISC-V spec features

Map of what exists: `../../agents/spec/INDEX.md`. Authoritative RTL status:
`../../AGENTS-specs-to-impl.md` / `../../AGENTS-specs-coverage.md`.

## Intent
Add spec-mandated features cleanly: encoding, discovery, config bit, RTL, tests, coverage, `.dts`.

## Current state snapshot (after U7ᵃ / U7ᵇ)
| Extension | Status | Knob / notes |
|-----------|--------|----------------|
| **Sstc** | implemented (config) | `SstcEn`, `stimecmp`, `rtc_time_i` |
| **Sscofpmf** | implemented (config) | `SscofpmfEn`, `scountovf`, LCOFI |
| **Zihintpause** | implemented (config) | `ZihintpauseEn`, PAUSE→NOP |
| **Zicboz** | partial (config) | `RVZiCboz`, CBO.ZERO + CBZE |
| **Zicbop** | partial (config) | `RVZiCbop`, PREFETCH→NOP |
| **Zicbom** | config (HPDCACHE) | `RVZiCbom` |
| **Svpbmt** | partial (config) | `SvpbmtEn`, PTE pbmt + PBMTE |
| **Zawrs** | partial (config) | `ZawrsEn`, WRS→WFI |
| **Svnapot** | implemented (config) | `SvnapotEn` |
| Smstateen / Svinval / CFI / V / … | absent or older partial | see coverage map |

## Process
1. Spec sub-file + INDEX row. 2. Config + `check_cfg`. 3. Discovery (`misa`/ISA string).
4. RTL at sanctioned seam. 5. Tests. 6. Update impl map + re-derive coverage + `.dts`.

## Invariants
Encoding matches ratified spec; off by default on minimal configs; no ISA change without anchor + test.
