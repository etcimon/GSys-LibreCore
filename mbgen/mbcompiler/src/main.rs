//! mbgen commands.
//!
//! preview  — one gesture, previous design kept when it does not pack
//! compile  — netlist, platform.json, firmware.json, scene, nets, paths, errors
//! scene / anchors / library / package
//! build    — those files plus a generated Unreal editor project

mod gltf;
mod textures;
mod unreal;

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use mbcore::{anchors, apply_package, compile, preview, scene, Design, Gesture};
use unreal::BuilderConfig;

fn main() -> ExitCode {
    if let Err(err) = run() {
        eprintln!("{err}");
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    match args.next().unwrap_or_else(|| "help".into()).as_str() {
        "preview" => preview_cmd(&mut args),
        "compile" => compile_cmd(&mut args),
        "scene" => scene_cmd(&mut args),
        "anchors" => anchors_cmd(&mut args),
        "package" => package_cmd(&mut args),
        "library" => library_cmd(&mut args),
        "profiles" => profiles_cmd(&mut args),
        "textures" => textures_cmd(&mut args),
        "build" => build_cmd(&mut args),
        "open" => open_cmd(&mut args),
        "mini-itx" => {
            let design = Design::mini_itx().map_err(|e| e.reason)?;
            println!("{}", serde_json::to_string_pretty(&design).map_err(|e| e.to_string())?);
            Ok(())
        }
        _ => {
            eprintln!("mbgen preview --design FILE --gesture FILE --out FILE");
            eprintln!("mbgen compile --design FILE --out DIR");
            eprintln!("mbgen scene --design FILE --out scene.json");
            eprintln!("mbgen anchors --design FILE --out anchors.json");
            eprintln!("mbgen package --design FILE --package ID --out FILE");
            eprintln!("mbgen library --out library.json");
            eprintln!("mbgen profiles --core-include DIR --out mbcore/data/profiles.json [--prefix core/include/]");
            eprintln!("mbgen textures --design FILE --out DIR");
            eprintln!("mbgen build --config builder.json");
            eprintln!("mbgen open [--project UPROJECT]");
            eprintln!("mbgen mini-itx");
            Ok(())
        }
    }
}

fn preview_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let gesture: Gesture = read_gesture(flags.get("--gesture").ok_or("--gesture is required")?)?;
    let out = flags.get("--out").ok_or("--out is required")?;
    let result = preview(&design, &gesture);
    fs::write(out, serde_json::to_string_pretty(&result).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if !result.applied {
        eprintln!("{}", result.reason.clone().unwrap_or_else(|| "rejected".into()));
    }
    Ok(())
}

fn scene_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let out = flags.get("--out").ok_or("--out is required")?;
    let bodies = scene(&design).map_err(|e| e.reason)?;
    fs::write(out, serde_json::to_string_pretty(&bodies).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn anchors_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let out = flags.get("--out").ok_or("--out is required")?;
    let marks = anchors(&design);
    fs::write(out, serde_json::to_string_pretty(&marks).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn package_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let package_id = flags.get("--package").ok_or("--package is required")?;
    let out = flags.get("--out").ok_or("--out is required")?;
    let result = match apply_package(&design, package_id) {
        Ok(next) => mbcore::PreviewResult { design: next, applied: true, reason: None },
        Err(err) => mbcore::PreviewResult { design, applied: false, reason: Some(err.reason) },
    };
    fs::write(out, serde_json::to_string_pretty(&result).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if !result.applied {
        eprintln!("{}", result.reason.clone().unwrap_or_else(|| "rejected".into()));
    }
    Ok(())
}

/// Regenerate `mbcore/data/profiles.json` from the SystemVerilog config
/// packages. The committed file is what the processor window offers; a
/// `cargo test` in mbcore fails when it drifts from `core/include`.
fn profiles_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let dir = PathBuf::from(flags.get("--core-include").ok_or("--core-include is required")?);
    let out = flags.get("--out").ok_or("--out is required")?;
    let prefix = flags.get("--prefix").cloned().unwrap_or_else(|| "core/include/".into());
    let profiles = mbcore::generate_from_dir(&dir, &prefix).map_err(|e| format!("{}: {e}", dir.display()))?;
    if profiles.is_empty() {
        return Err(format!("no *_config_pkg.sv targets under {}", dir.display()));
    }
    fs::write(out, mbcore::profiles_json(&profiles)).map_err(|e| e.to_string())?;
    let qualified = profiles.iter().filter(|p| p.is_qualified()).count();
    println!("{out}: {} profiles, {qualified} qualified", profiles.len());
    for p in profiles.iter().filter(|p| !p.is_qualified()) {
        eprintln!("unresolved {}: {}", p.id, p.unresolved.join(", "));
    }
    Ok(())
}

fn library_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let out = flags.get("--out").ok_or("--out is required")?;
    let rows = mbcore::library_export();
    fs::write(out, serde_json::to_string_pretty(&rows).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    println!("{out}");
    Ok(())
}

fn textures_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let out = flags.get("--out").ok_or("--out is required")?;
    crate::textures::write_solder_for(std::path::Path::new(out), &design)?;
    println!("{out}");
    Ok(())
}

fn compile_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let design = read_design(flags.get("--design").ok_or("--design is required")?)?;
    let out = PathBuf::from(flags.get("--out").ok_or("--out is required")?);
    write_bundle(&design, &out)
}

fn open_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let project = flags.get("--project").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../mbsim/MbgenSim/MbgenSim.uproject")
    });
    let project = project.canonicalize().map_err(|e| format!("{}: {e}", project.display()))?;
    let project = PathBuf::from(project.to_string_lossy().trim_start_matches(r"\\?\"));
    let Some(editor) = find_unreal_editor() else {
        eprintln!("Unreal Editor was not found.");
        eprintln!("Install Unreal Engine {UNREAL_VERSION}, then run:");
        eprintln!("  mbgen open --project {}", project.display());
        return Err("UnrealEditor.exe is not installed".into());
    };
    println!("opening {} with {}", project.display(), editor.display());
    std::process::Command::new(&editor)
        .arg(&project)
        .spawn()
        .map_err(|e| format!("failed to start {}: {e}", editor.display()))?;
    Ok(())
}

const UNREAL_VERSION: &str = "5.8";

fn prefer_unreal_editor(found: &[PathBuf]) -> Option<PathBuf> {
    let needle = format!("UE_{UNREAL_VERSION}");
    found
        .iter()
        .find(|p| p.to_string_lossy().contains(&needle))
        .cloned()
        .or_else(|| found.last().cloned())
}

fn find_unreal_editor() -> Option<PathBuf> {
    let roots = [
        r"C:\Program Files\Epic Games",
        r"C:\Program Files (x86)\Epic Games",
        r"D:\Epic Games",
        r"E:\Epic Games",
    ];
    let mut found = Vec::new();
    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            let exe = entry.path().join(r"Engine\Binaries\Win64\UnrealEditor.exe");
            if exe.is_file() {
                found.push(exe);
            }
        }
    }
    found.sort();
    prefer_unreal_editor(&found)
}

fn build_cmd(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    let flags = flags(args)?;
    let config_path = flags.get("--config").map(String::as_str).unwrap_or("builder.json");
    let cfg: BuilderConfig = read_json(config_path)?;
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    unreal::build(&cfg, &repo)?;
    Ok(())
}

/// Write the bundle into a staging directory, then publish: every file first,
/// `manifest.json` last. A consumer that finds the manifest has the whole
/// revision; one that does not has a partial write to ignore.
fn write_bundle(design: &Design, out: &PathBuf) -> Result<(), String> {
    let bundle = compile(design).map_err(|e| e.reason)?;
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let stale = out.join("manifest.json");
    if stale.exists() {
        fs::remove_file(&stale).map_err(|e| e.to_string())?;
    }
    for (name, text) in bundle.files() {
        fs::write(out.join(name), text).map_err(|e| format!("{name}: {e}"))?;
    }
    let manifest = serde_json::to_string_pretty(&bundle.manifest()).map_err(|e| e.to_string())?;
    let tmp = out.join("manifest.json.tmp");
    fs::write(&tmp, manifest).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &stale).map_err(|e| e.to_string())?;
    println!("{}", out.display());
    Ok(())
}

const GESTURE_MAX_BYTES: u64 = 256 * 1024;

fn read_design(path: &str) -> Result<Design, String> {
    read_json(path)
}

fn read_gesture(path: &str) -> Result<Gesture, String> {
    let len = fs::metadata(path).map_err(|e| format!("{path}: {e}"))?.len();
    if len > GESTURE_MAX_BYTES {
        return Err("gesture too large".into());
    }
    read_json(path)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &str) -> Result<T, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))
}

fn flags(args: &mut impl Iterator<Item = String>) -> Result<std::collections::HashMap<String, String>, String> {
    let mut out = std::collections::HashMap::new();
    let mut args = args.peekable();
    while let Some(flag) = args.next() {
        let value = args.next().ok_or_else(|| format!("{flag} needs a value"))?;
        out.insert(flag, value);
    }
    Ok(out)
}

#[cfg(test)]
mod gesture_cap_tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn oversized_gesture_file_is_rejected() {
        let dir = std::env::temp_dir().join("mbgen-gesture-cap");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("gesture.json");
        let mut file = fs::File::create(&path).unwrap();
        let pad = "x".repeat((GESTURE_MAX_BYTES as usize) + 8);
        write!(file, r#"{{"op":"nudge","id":"{pad}","delta_um":1}}"#).unwrap();
        let err = read_gesture(path.to_str().unwrap()).unwrap_err();
        assert!(err.contains("too large"), "{err}");
    }

    #[test]
    fn open_prefers_ue_5_8_over_5_4() {
        assert_eq!(UNREAL_VERSION, "5.8");
        let cfg = fs::read_to_string(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../builder.json"),
        )
        .unwrap();
        assert!(cfg.contains("\"unreal_version\": \"5.8\""));
        let v54 = PathBuf::from(r"C:\Program Files\Epic Games\UE_5.4\Engine\Binaries\Win64\UnrealEditor.exe");
        let v58 = PathBuf::from(r"C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor.exe");
        let v59 = PathBuf::from(r"C:\Program Files\Epic Games\UE_5.9\Engine\Binaries\Win64\UnrealEditor.exe");
        assert_eq!(prefer_unreal_editor(&[v54.clone(), v58.clone(), v59.clone()]), Some(v58.clone()));
        assert_eq!(prefer_unreal_editor(&[v54.clone()]), Some(v54));
    }

    #[test]
    fn small_nudge_gesture_file_parses() {
        let dir = std::env::temp_dir().join("mbgen-gesture-cap");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nudge.json");
        fs::write(&path, r#"{"op":"nudge","id":"usb0","delta_um":1000}"#).unwrap();
        let g = read_gesture(path.to_str().unwrap()).unwrap();
        assert!(matches!(g, Gesture::Nudge { .. }));
    }
}
