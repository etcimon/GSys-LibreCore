// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// analyze_files with IR-only SQLite cache:
// design hit → skip all; else module-granular hit/miss → reparse only miss files.

//! Cached analyze entrypoint. See DESIGN § Cache.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use sv_timing_core::{
    analyze_files, remeasure_path_slacks, remeasure_path_slacks_with_hints, AnalyzeOutput,
    CoreResult, LowerOptions, NameTable, ParseOptions, TimingDesign, IR_VERSION,
};

use crate::crc::{digest_files, FileDigest};
use crate::pathkey::PathIndex;
use crate::store::{
    compute_pp_fingerprint, crc_set_for_file, CacheStats, ModuleIrBlob,
    TimingCache,
};

/// Result of cached analyze.
#[derive(Debug)]
pub struct CachedAnalyzeOutput {
    /// Same as uncached analyze.
    pub output: AnalyzeOutput,
    /// Cache statistics for this run.
    pub stats: CacheStats,
    /// True when **no** file was reparsed (design hit or all modules IR-hit).
    pub from_cache: bool,
}

/// Analyze with SQLite IR cache.
///
/// 1. Digest inputs (CRC-32C) → `pp_fingerprint` + `design_key`.
/// 2. **Design hit** → load full design (no parse).
/// 3. Else **module-granular**:
///    - For each known module (from `file_modules`), compute `crc_set` over its
///      contributing paths; **IR hit** loads blob, **miss** queues those paths.
///    - Paths with no module mapping (e.g. packages) always join the miss parse set
///      when any module misses (or when cold).
///    - Reparse **only** miss paths; merge with hit modules; remeasure; store.
/// 4. Cold start / empty mapping → full `analyze_files`.
pub fn analyze_with_cache(
    paths: &[PathBuf],
    parse: &ParseOptions,
    lower: &LowerOptions,
    cache: &mut TimingCache,
) -> CoreResult<CachedAnalyzeOutput> {
    let digests = digest_files(paths)?;
    let incdirs: Vec<String> = parse
        .include_paths
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    let pp_fp = compute_pp_fingerprint(
        &digests,
        &incdirs,
        &parse.defines,
        &[],
        &lower.cost_model.id,
    );
    // Design key = pp fingerprint + module filter + file CRCs + param keys, plus two
    // namespaced tokens so a **measurement-semantics** change or an analysis-affecting
    // dial change can never serve a stale blob (P15; `#`-prefixed tokens cannot collide
    // with param keys). Only `analysis_digest()` participates: thread count and the
    // transform dials cannot change an analyze result, so they must not evict the cache.
    let mut param_keys = lower.param_map.keys();
    param_keys.push(format!("#measurement={}", sv_timing_core::MEASUREMENT_VERSION));
    param_keys.push(format!("#opt={}", lower.opt.analysis_digest()));
    let design_key =
        crate::store::compute_design_key_with_params(&pp_fp, &lower.module_filter, &digests, &param_keys);

    let mut stats = CacheStats {
        pp_fingerprint: pp_fp.clone(),
        design_key: design_key.clone(),
        ..Default::default()
    };
    cache.reconcile_files(&digests, &pp_fp, &mut stats)?;

    // --- full design short-circuit ---
    if let Some(mut design) = cache.get_design(&design_key, &lower.cost_model.id)? {
        design.target = lower.target.clone();
        // Path-class table short-circuits exclusive detectors for known signatures.
        let class_hints = cache
            .get_path_class_hints(&design_key)
            .unwrap_or_default();
        if class_hints.is_empty() {
            remeasure_path_slacks(&mut design);
        } else {
            remeasure_path_slacks_with_hints(&mut design, Some(&class_hints));
        }
        design.versions.cost_model = lower.cost_model.id.clone();
        design.versions.ir = IR_VERSION.to_string();
        stats.design_hit = true;
        stats.module_hits = design.modules.len() as u32;
        let mut names = NameTable::new();
        for m in design.modules.values() {
            names.reserve(&m.name, &m.name);
        }
        let run_id = format!("hit-{}", stats.pp_fingerprint.get(..12).unwrap_or("x"));
        let mod_names: Vec<String> = design.module_names.keys().cloned().collect();
        cache.record_run(&run_id, "analyze", "ok_design_hit", &mod_names)?;
        // Refresh path_class denorm (in case classification refined).
        let _ = cache.put_path_classes(&design_key, &design);
        return Ok(CachedAnalyzeOutput {
            output: AnalyzeOutput { design, names, skipped_files: Vec::new() },
            stats,
            from_cache: true,
        });
    }

    // --- module-granular path ---
    let digest_by_path: BTreeMap<String, &FileDigest> =
        digests.iter().map(|d| (d.path.clone(), d)).collect();
    let path_keys: Vec<String> = digests.iter().map(|d| d.path.clone()).collect();
    // Normalize the run's paths **once** (B2); every "is this the same file?" question
    // below is then a hash lookup instead of a two-way `ends_with` over fresh Strings.
    let dindex = PathIndex::build(&path_keys);

    let fm = cache.list_file_modules_for_paths(&path_keys)?;
    // module_name -> contributing absolute paths (from prior successful runs)
    let mut contrib: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (path, mod_name) in &fm {
        contrib
            .entry(mod_name.clone())
            .or_default()
            .insert(path.clone());
    }
    // Ensure primary file from modules table is included
    for mod_name in contrib.keys().cloned().collect::<Vec<_>>() {
        if let Some(pf) = cache.module_primary_file(&mod_name)? {
            if let Some(d) = dindex.find(&pf).and_then(|i| digests.get(i)) {
                contrib.get_mut(&mod_name).unwrap().insert(d.path.clone());
            }
        }
    }

    let filter = &lower.module_filter;
    let mut hit_blobs: Vec<ModuleIrBlob> = Vec::new();
    let mut miss_modules: BTreeSet<String> = BTreeSet::new();
    let mut miss_path_set: BTreeSet<String> = BTreeSet::new();

    if contrib.is_empty() {
        // Cold: full reparse
        return full_rebuild(paths, parse, lower, cache, &digests, &pp_fp, &design_key, stats);
    }

    for (mod_name, files) in &contrib {
        if !filter.is_empty() && !filter.iter().any(|f| f == mod_name) {
            continue;
        }
        // crc_set over contributing files present in this run
        let mut pairs: Vec<(String, String)> = Vec::new();
        let mut all_present = true;
        for f in files {
            if let Some(d) = digest_by_path.get(f) {
                pairs.push((d.path.clone(), d.crc.clone()));
            } else if let Some(d) = dindex.find(f).and_then(|i| digests.get(i)) {
                pairs.push((d.path.clone(), d.crc.clone()));
            } else {
                all_present = false;
            }
        }
        if !all_present || pairs.is_empty() {
            miss_modules.insert(mod_name.clone());
            for f in files {
                miss_path_set.insert(f.clone());
            }
            continue;
        }
        let cs = crate::fingerprint::module_crc_set(&pairs);
        match cache.get_module(mod_name, &cs)? {
            Some(blob) => {
                stats.module_hits += 1;
                hit_blobs.push(blob);
            }
            None => {
                stats.module_misses += 1;
                miss_modules.insert(mod_name.clone());
                for (p, _) in pairs {
                    miss_path_set.insert(p);
                }
            }
        }
    }

    // Paths with no prior module mapping (packages / new files) — always reparse when
    // anything misses, or when we have zero hits (safety).
    let mapped_paths: BTreeSet<String> = fm.iter().map(|(p, _)| p.clone()).collect();
    // One index over the mapped set answers "is this digest known to a module?" in O(1).
    let mapped_index = PathIndex::build(mapped_paths.iter());
    for d in &digests {
        if !mapped_index.contains(&d.path) {
            miss_path_set.insert(d.path.clone());
        }
    }

    // If every selected module hit and no orphan paths require parse when hits cover all:
    if miss_modules.is_empty() && !hit_blobs.is_empty() {
        // Still reparse unmapped paths (packages) so design.packages is fresh if present
        let unmapped: Vec<PathBuf> = digests
            .iter()
            .filter(|d| !mapped_index.contains(&d.path))
            .map(|d| PathBuf::from(&d.path))
            .collect();
        let mut design = assemble_from_hits(&hit_blobs, lower);
        let mut names = NameTable::new();
        for m in design.modules.values() {
            names.reserve(&m.name, &m.name);
        }
        if !unmapped.is_empty() {
            // Lower packages/aux only
            let mut pkg_lower = lower.clone();
            pkg_lower.module_filter.clear(); // pick up packages; modules on those files rare
            if let Ok(aux) = analyze_files(&unmapped, parse, &pkg_lower) {
                for (k, v) in aux.design.packages.iter() {
                    design.packages.insert(k.clone(), v.clone());
                }
                // Don't pull extra modules unless filter empty
                if lower.module_filter.is_empty() {
                    merge_miss_into(&mut design, &mut names, aux.output_design_only());
                }
            }
        }
        remeasure_path_slacks(&mut design);
        design.versions.cost_model = lower.cost_model.id.clone();
        design.opportunities = sv_timing_core::suggest_opportunities(&design);
        commit_all(
            cache,
            &digests,
            &pp_fp,
            &design_key,
            &design,
            lower,
            &hit_blobs,
            None,
        )?;
        let run_id = format!("mhit-{}", stats.pp_fingerprint.get(..12).unwrap_or("x"));
        let mod_names: Vec<String> = design.module_names.keys().cloned().collect();
        cache.record_run(&run_id, "analyze", "ok_module_hits", &mod_names)?;
        return Ok(CachedAnalyzeOutput {
            output: AnalyzeOutput { design, names, skipped_files: Vec::new() },
            stats,
            from_cache: true,
        });
    }

    // Partial or full miss reparse
    let miss_paths: Vec<PathBuf> = if hit_blobs.is_empty() {
        paths.to_vec()
    } else {
        // miss module files + unmapped (packages)
        let mut set: BTreeSet<String> = miss_path_set;
        for d in &digests {
            if !mapped_index.contains(&d.path) {
                set.insert(d.path.clone());
            }
        }
        // Resolve to PathBuf present in digests
        let miss_index = PathIndex::build(set.iter());
        digests
            .iter()
            .filter(|d| miss_index.contains(&d.path))
            .map(|d| PathBuf::from(&d.path))
            .collect()
    };

    if miss_paths.is_empty() {
        return full_rebuild(paths, parse, lower, cache, &digests, &pp_fp, &design_key, stats);
    }

    let mut miss_lower = lower.clone();
    // When partial, only lower modules that missed (plus anything on those files)
    if !hit_blobs.is_empty() && !miss_modules.is_empty() {
        miss_lower.module_filter = miss_modules.iter().cloned().collect();
    }

    let miss_out = analyze_files(&miss_paths, parse, &miss_lower)?;
    stats.module_misses = stats.module_misses.max(miss_out.design.modules.len() as u32);
    // Parse skips happen during the miss reparse; carry them to the report.
    let skipped_files = miss_out.skipped_files.clone();

    let (design, names) = if hit_blobs.is_empty() {
        (miss_out.design, miss_out.names)
    } else {
        let mut design = assemble_from_hits(&hit_blobs, lower);
        let mut names = NameTable::new();
        for m in design.modules.values() {
            names.reserve(&m.name, &m.name);
        }
        // packages from miss
        for (k, v) in miss_out.design.packages {
            design.packages.insert(k, v);
        }
        merge_miss_into(&mut design, &mut names, MissSlice {
            modules: miss_out.design.modules,
            module_names: miss_out.design.module_names,
            paths: miss_out.design.paths,
        });
        remeasure_path_slacks(&mut design);
        design.opportunities = sv_timing_core::suggest_opportunities(&design);
        design.versions.cost_model = lower.cost_model.id.clone();
        (design, names)
    };

    commit_all(
        cache,
        &digests,
        &pp_fp,
        &design_key,
        &design,
        lower,
        &hit_blobs,
        Some(&design),
    )?;
    let run_id = format!("pmiss-{}", stats.pp_fingerprint.get(..12).unwrap_or("x"));
    let mod_names: Vec<String> = design.module_names.keys().cloned().collect();
    cache.record_run(&run_id, "analyze", "ok_partial_rebuild", &mod_names)?;

    Ok(CachedAnalyzeOutput {
        output: AnalyzeOutput {
            design,
            names,
            skipped_files,
        },
        stats,
        from_cache: false,
    })
}

struct MissSlice {
    modules: BTreeMap<u32, sv_timing_core::TimingModule>,
    module_names: BTreeMap<String, u32>,
    paths: Vec<sv_timing_core::TimingPath>,
}

/// Helper so analyze_files result can be partially moved — we only need design fields.
trait DesignOnly {
    fn output_design_only(self) -> MissSlice;
}

impl DesignOnly for AnalyzeOutput {
    fn output_design_only(self) -> MissSlice {
        MissSlice {
            modules: self.design.modules,
            module_names: self.design.module_names,
            paths: self.design.paths,
        }
    }
}

fn full_rebuild(
    paths: &[PathBuf],
    parse: &ParseOptions,
    lower: &LowerOptions,
    cache: &mut TimingCache,
    digests: &[FileDigest],
    pp_fp: &str,
    design_key: &str,
    mut stats: CacheStats,
) -> CoreResult<CachedAnalyzeOutput> {
    let out = analyze_files(paths, parse, lower)?;
    stats.module_misses = out.design.modules.len() as u32;
    commit_all(
        cache,
        digests,
        pp_fp,
        design_key,
        &out.design,
        lower,
        &[],
        Some(&out.design),
    )?;
    let run_id = format!("full-{}", stats.pp_fingerprint.get(..12).unwrap_or("x"));
    let mod_names: Vec<String> = out.design.module_names.keys().cloned().collect();
    cache.record_run(&run_id, "analyze", "ok_full_rebuild", &mod_names)?;
    Ok(CachedAnalyzeOutput {
        output: out,
        stats,
        from_cache: false,
    })
}

fn assemble_from_hits(hits: &[ModuleIrBlob], lower: &LowerOptions) -> TimingDesign {
    let mut design = TimingDesign::empty(lower.target.clone());
    let mut next_mid = 0u32;
    for blob in hits {
        let mut m = blob.module.clone();
        let old_id = m.id;
        m.id = next_mid;
        for r in m.regions.values_mut() {
            r.module = next_mid;
        }
        for inst in &mut m.instances {
            inst.parent_module = next_mid;
        }
        for mut path in blob.paths.clone() {
            path.module = next_mid;
            // Remap region ownership already on module; path.region_id stays
            design.paths.push(path);
        }
        design.module_names.insert(m.name.clone(), next_mid);
        design.instances.extend(m.instances.iter().cloned());
        design.modules.insert(next_mid, m);
        let _ = old_id;
        next_mid += 1;
    }
    // Re-resolve child ids after all modules are present
    let name_map = design.module_names.clone();
    for inst in &mut design.instances {
        inst.child_module = name_map.get(&inst.child_type).copied();
    }
    for module in design.modules.values_mut() {
        for inst in &mut module.instances {
            inst.child_module = name_map.get(&inst.child_type).copied();
        }
    }
    design.versions.cost_model = lower.cost_model.id.clone();
    design.versions.ir = IR_VERSION.to_string();
    design
}

fn merge_miss_into(design: &mut TimingDesign, names: &mut NameTable, miss: MissSlice) {
    let mut next_mid = design.modules.keys().next_back().copied().unwrap_or(0);
    if !design.modules.is_empty() {
        next_mid += 1;
    }
    let mut id_map: BTreeMap<u32, u32> = BTreeMap::new();
    for (old_id, mut m) in miss.modules {
        let new_id = next_mid;
        next_mid += 1;
        id_map.insert(old_id, new_id);
        m.id = new_id;
        for r in m.regions.values_mut() {
            r.module = new_id;
        }
        names.reserve(&m.name, &m.name);
        design.module_names.insert(m.name.clone(), new_id);
        design.modules.insert(new_id, m);
    }
    for mut path in miss.paths {
        if let Some(&nid) = id_map.get(&path.module) {
            path.module = nid;
            design.paths.push(path);
        }
    }
    let _ = miss.module_names;
}

fn commit_all(
    cache: &mut TimingCache,
    digests: &[FileDigest],
    pp_fp: &str,
    design_key: &str,
    design: &TimingDesign,
    lower: &LowerOptions,
    _hits: &[ModuleIrBlob],
    _full: Option<&TimingDesign>,
) -> CoreResult<()> {
    cache.upsert_files(digests, pp_fp)?;
    let mut fm_pairs: Vec<(String, String)> = Vec::new();
    let dindex = PathIndex::build(digests.iter().map(|d| d.path.as_str()));
    for m in design.modules.values() {
        let found = dindex.find(&m.file).and_then(|i| digests.get(i));
        let path_str = found
            .map(|d| d.path.clone())
            .unwrap_or_else(|| m.file.clone());
        let crc = found.map(|d| d.crc.as_str()).unwrap_or("unknown");
        let cs = crc_set_for_file(&path_str, crc);
        let paths_for_mod: Vec<_> = design
            .paths
            .iter()
            .filter(|p| p.module == m.id)
            .cloned()
            .collect();
        let blob = ModuleIrBlob {
            module: m.clone(),
            paths: paths_for_mod,
        };
        cache.put_module(&m.name, &path_str, &cs, &blob)?;
        fm_pairs.push((path_str, m.name.clone()));
    }
    // file_modules for packages: no module rows
    cache.replace_file_modules(&fm_pairs)?;
    cache.put_design(design_key, &lower.cost_model.id, design)?;
    Ok(())
}

// NOTE: the former `paths_match` helper (two-way `ends_with` on freshly lowercased
// copies, called from nested loops) was replaced by `pathkey::PathIndex` — bottleneck B2
// in `architecture/PERF-CACHE.md` §1. Normalization happens once per run and lookups are
// hash-based and path-boundary aware.

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use sv_timing_core::{load_fo4_v1_default, TimingTarget};

    fn write_mod(dir: &std::path::Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(format!("{name}.sv"));
        let mut f = std::fs::File::create(&p).unwrap();
        writeln!(
            f,
            "module {name}(input logic [7:0] a, b, output logic [8:0] y);\n{body}\nendmodule"
        )
        .unwrap();
        p
    }

    #[test]
    fn second_analyze_is_design_hit() {
        let dir = std::env::temp_dir().join(format!(
            "svt_ac_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let sv = write_mod(&dir, "cloud", "  always_comb y = a + b + a;");
        let db = dir.join("ir.sqlite");
        let mut cache = TimingCache::open(crate::store::CacheConfig::at(&db)).unwrap();
        let parse = ParseOptions::default();
        let mut lower = LowerOptions {
            target: TimingTarget::new(2000.0, 20.0, 0.2),
            cost_model: load_fo4_v1_default(),
            module_filter: vec!["cloud".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let paths = vec![sv.clone()];

        let r1 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("first");
        assert!(!r1.from_cache);
        let r2 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("second");
        assert!(r2.from_cache && r2.stats.design_hit);

        let mut f = std::fs::File::create(&sv).unwrap();
        writeln!(
            f,
            "module cloud(input logic [7:0] a, b, output logic [8:0] y);\n always_comb y = a + b + a + b;\nendmodule"
        )
        .unwrap();
        let r3 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("third");
        assert!(!r3.stats.design_hit);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn opt_level_change_invalidates_design_key() {
        let dir = std::env::temp_dir().join(format!(
            "svt_opt_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let sv = write_mod(&dir, "optmod", "  always_comb y = a + b + a;");
        let db = dir.join("ir.sqlite");
        let mut cache = TimingCache::open(crate::store::CacheConfig::at(&db)).unwrap();
        let parse = ParseOptions::default();
        let mut lower = LowerOptions {
            target: TimingTarget::new(2000.0, 20.0, 0.2),
            cost_model: load_fo4_v1_default(),
            module_filter: vec!["optmod".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let paths = vec![sv];

        let r1 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("cold");
        assert!(!r1.from_cache);
        let r2 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("warm");
        assert!(r2.stats.design_hit, "unchanged inputs must hit");

        // Same sources, analysis-affecting dial change (effort balanced → thorough)
        // ⇒ different design key ⇒ no stale blob.
        let mut other = lower.clone();
        other.opt = sv_timing_core::OptOptions::preset(sv_timing_core::OptLevel::O3);
        let r3 = analyze_with_cache(&paths, &parse, &other, &mut cache).expect("opt change");
        assert_ne!(r2.stats.design_key, r3.stats.design_key, "dial digest must key the design");
        assert!(!r3.stats.design_hit, "-O change must not reuse the -O2 blob");

        // Thread count cannot change a result, so it must NOT evict the cache.
        let mut jobs = lower.clone();
        jobs.opt.jobs = Some(4);
        let r4 = analyze_with_cache(&paths, &parse, &jobs, &mut cache).expect("jobs change");
        assert_eq!(
            r2.stats.design_key, r4.stats.design_key,
            "--opt-jobs must not participate in the design key"
        );
        assert!(r4.stats.design_hit, "changing jobs must still hit");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn partial_module_miss_only_recomputes_changed() {
        let dir = std::env::temp_dir().join(format!(
            "svt_partial_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let a = write_mod(&dir, "moda", "  always_comb y = a + b;");
        let b = write_mod(&dir, "modb", "  always_comb y = a + b + a;");
        let db = dir.join("ir.sqlite");
        let mut cache = TimingCache::open(crate::store::CacheConfig::at(&db)).unwrap();
        let parse = ParseOptions::default();
        let mut lower = LowerOptions {
            target: TimingTarget::new(2000.0, 20.0, 0.2),
            cost_model: load_fo4_v1_default(),
            module_filter: vec!["moda".into(), "modb".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let paths = vec![a.clone(), b.clone()];

        let r1 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("cold");
        assert!(!r1.from_cache);
        assert_eq!(r1.output.design.modules.len(), 2);

        // Unchanged → design hit
        let r2 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("warm");
        assert!(r2.from_cache);
        assert!(r2.stats.design_hit);

        // Change only moda.sv
        let mut f = std::fs::File::create(&a).unwrap();
        writeln!(
            f,
            "module moda(input logic [7:0] a, b, output logic [8:0] y);\n always_comb y = a + b + b + a;\nendmodule"
        )
        .unwrap();

        let r3 = analyze_with_cache(&paths, &parse, &lower, &mut cache).expect("partial");
        assert!(!r3.stats.design_hit, "design key must change when moda changes");
        // modb IR hit, moda miss → partial reparse
        assert!(
            r3.stats.module_hits >= 1,
            "expected modb IR hit, stats={:?}",
            r3.stats
        );
        assert!(
            r3.stats.module_misses >= 1,
            "expected moda IR miss, stats={:?}",
            r3.stats
        );
        assert_eq!(r3.output.design.modules.len(), 2);
        assert!(r3.output.design.module_names.contains_key("moda"));
        assert!(r3.output.design.module_names.contains_key("modb"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
