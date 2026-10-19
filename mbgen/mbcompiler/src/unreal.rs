//! Writes an Unreal Editor project that reads the compiled scene.
//! Content/Python/mbgen_materials.py is the startup script and the source
//! embedded below. It builds one lit material per slot from the PBR maps
//! this builder writes. Name plaques stay unlit.

use std::fs;
use std::path::Path;

use crate::gltf;
use crate::textures;
use mbcore::{compile, scene, Design};

#[derive(Clone, Debug, serde::Deserialize)]
pub struct BuilderConfig {
    pub project_name: String,
    pub unreal_version: String,
    pub engine_association: String,
    pub template: String,
    pub package_id: String,
    pub output: String,
}

pub fn build(cfg: &BuilderConfig, repo: &Path) -> Result<Design, String> {
    let mut design = Design::from_template(&cfg.template).map_err(|e| e.reason)?;
    design = mbcore::apply_package(&design, &cfg.package_id).map_err(|e| e.reason)?;
    let bundle = compile(&design).map_err(|e| e.reason)?;
    let root = repo.join(&cfg.output);
    fs::create_dir_all(root.join("Content/Boards")).map_err(|e| e.to_string())?;
    fs::create_dir_all(root.join("Content/Meshes")).map_err(|e| e.to_string())?;
    fs::create_dir_all(root.join("Content/Python")).map_err(|e| e.to_string())?;
    fs::create_dir_all(root.join("Config")).map_err(|e| e.to_string())?;
    fs::create_dir_all(root.join("Source/MbgenSim")).map_err(|e| e.to_string())?;
    textures::write_set_for(&root.join("Content/Textures"), &design)?;
    write(&root.join(format!("{}.uproject", cfg.project_name)), &uproject(&cfg.project_name, &cfg.engine_association))?;
    write(&root.join("Config/DefaultEngine.ini"), ENGINE)?;
    write(&root.join("Config/DefaultEditor.ini"), EDITOR)?;
    write(&root.join("Config/DefaultGame.ini"), GAME)?;
    write(&root.join("Config/Mbgen.ini"),
        "[/Script/MbgenSim.MbgenSettings]\nDesign=Boards/design.json\nScene=Boards/scene.json\nLiveRouting=False\nLiveRouteHz=10\nLengthUnit=mm\nMouseSensitivity=0.25\n"
    )?;
    write(&root.join("Source/MbgenSim.Target.cs"), TARGET)?;
    write(&root.join("Source/MbgenSimEditor.Target.cs"), EDITOR_TARGET)?;
    write(&root.join("Source/MbgenSim/MbgenSim.Build.cs"), BUILD)?;
    write(&root.join("Source/MbgenSim/MbgenSim.h"), MODULE_H)?;
    write(&root.join("Source/MbgenSim/MbgenSim.cpp"), MODULE_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenEditorBridge.h"), BRIDGE_H)?;
    write(&root.join("Source/MbgenSim/MbgenEditorBridge.cpp"), BRIDGE_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenSettings.h"), SETTINGS_H)?;
    write(&root.join("Source/MbgenSim/MbgenSettings.cpp"), SETTINGS_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenBoardActor.h"), ACTOR_H)?;
    write(&root.join("Source/MbgenSim/MbgenBoardActor.cpp"), ACTOR_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenGameMode.h"), MODE_H)?;
    write(&root.join("Source/MbgenSim/MbgenGameMode.cpp"), MODE_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenOrbitPawn.h"), PAWN_H)?;
    write(&root.join("Source/MbgenSim/MbgenOrbitPawn.cpp"), PAWN_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenNav.h"), NAV_H)?;
    write(&root.join("Source/MbgenSim/MbgenNav.cpp"), NAV_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenPlayerController.h"), PC_H)?;
    write(&root.join("Source/MbgenSim/MbgenPlayerController.cpp"), PC_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenPackageWidget.h"), WIDGET_H)?;
    write(&root.join("Source/MbgenSim/MbgenPackageWidget.cpp"), WIDGET_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenLibraryWidget.h"), LIBRARY_H)?;
    write(&root.join("Source/MbgenSim/MbgenLibraryWidget.cpp"), LIBRARY_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenOutlineWidget.h"), OUTLINE_H)?;
    write(&root.join("Source/MbgenSim/MbgenOutlineWidget.cpp"), OUTLINE_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenIssuesWidget.h"), ISSUES_H)?;
    write(&root.join("Source/MbgenSim/MbgenIssuesWidget.cpp"), ISSUES_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenPropertyWidget.h"), PROPERTY_H)?;
    write(&root.join("Source/MbgenSim/MbgenPropertyWidget.cpp"), PROPERTY_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenStore.h"), STORE_H)?;
    write(&root.join("Source/MbgenSim/MbgenStore.cpp"), STORE_CPP)?;
    write(&root.join("Source/MbgenSim/MbgenChrome.h"), CHROME_H)?;
    write(&root.join("Source/MbgenSim/MbgenChrome.cpp"), CHROME_CPP)?;
    write(&root.join("Source/MbgenSim/mbcore_c.h"), MBCORE_C_H)?;
    write(&root.join("Content/Python/mbgen_materials.py"), PYTHON)?;
    write(&root.join("Content/Python/paint_labels.py"), PAINT_LABELS)?;
    let packages: Vec<_> = mbcore::packages().iter().map(|c| serde_json::json!({
        "id": c.id, "group": c.group, "isa": c.isa, "xlen": c.xlen,
        "cores": c.cores, "threads": c.threads, "ooo": c.ooo, "l2": c.l2, "l3": c.l3, "ai": c.ai, "axi_bits": c.axi_bits
    })).collect();
    fs::write(root.join("Content/Boards/packages.json"), serde_json::to_string_pretty(&packages).unwrap()).map_err(|e| e.to_string())?;
    fs::write(
        root.join("Content/Boards/library.json"),
        serde_json::to_string_pretty(&mbcore::library_export()).unwrap(),
    )
    .map_err(|e| e.to_string())?;
    let outlines: Vec<_> = mbcore::outline_ids()
        .iter()
        .filter_map(|id| mbcore::template_by_id(id).ok().map(|t| serde_json::json!({
            "id": t.id,
            "w_um": t.board_w_um,
            "d_um": t.board_d_um,
            "cpu_y_frac": t.sit.cpu_y_frac,
            "has_cpu": t.edges.iter().any(|e| e.id == "cpu"),
        })))
        .collect();
    fs::write(
        root.join("Content/Boards/outlines.json"),
        serde_json::to_string_pretty(&outlines).unwrap(),
    )
    .map_err(|e| e.to_string())?;
    let preview = scene(&design).map_err(|e| e.reason)?;
    let product = root.join("Content/Boards/product");
    fs::create_dir_all(&product).map_err(|e| e.to_string())?;
    fs::write(root.join("Content/Boards/design.json"), serde_json::to_string_pretty(&design).unwrap()).map_err(|e| e.to_string())?;
    fs::write(root.join("Content/Boards/scene.json"), serde_json::to_string_pretty(&preview).unwrap()).map_err(|e| e.to_string())?;
    // Same bundle layout as `mbgen compile`: every file, then the manifest.
    for (name, text) in bundle.files() {
        fs::write(product.join(name), text).map_err(|e| format!("{name}: {e}"))?;
    }
    fs::write(product.join("manifest.json"), serde_json::to_string_pretty(&bundle.manifest()).unwrap()).map_err(|e| e.to_string())?;
    let boards = root.join("Content/Boards");
    fs::write(boards.join("firmware.json"), serde_json::to_string_pretty(&bundle.firmware).unwrap()).map_err(|e| e.to_string())?;
    fs::write(boards.join("platform.json"), serde_json::to_string_pretty(&bundle.platform).unwrap()).map_err(|e| e.to_string())?;
    fs::write(boards.join("board.net"), &bundle.netlist).map_err(|e| e.to_string())?;
    fs::write(boards.join("design_skidl.py"), &bundle.skidl_py).map_err(|e| e.to_string())?;
    gltf::write_board(&root.join("Content/Meshes/board.gltf"), &preview)?;
    let compiled: Vec<mbcore::Body> = serde_json::from_value(bundle.scene).map_err(|e| e.to_string())?;
    gltf::write_board(&root.join("Content/Meshes/board-product.gltf"), &compiled)?;
    let shown = root.canonicalize().unwrap_or(root);
    println!("unreal project {}", shown.display());
    println!("engine association {} ({})", cfg.engine_association, cfg.unreal_version);
    Ok(design)
}

fn write(path: &Path, text: &str) -> Result<(), String> {
    fs::write(path, text.replace("\r\n", "\n")).map_err(|e| e.to_string())
}

fn uproject(name: &str, engine: &str) -> String {
    format!(
        "{{\n  \"FileVersion\": 3,\n  \"EngineAssociation\": \"{engine}\",\n  \"Category\": \"\",\n  \"Description\": \"mbgen board preview. Generated. Open this in the Unreal editor, let it compile {name}, then press Play.\",\n  \"Modules\": [\n    {{\n      \"Name\": \"{name}\",\n      \"Type\": \"Runtime\",\n      \"LoadingPhase\": \"Default\"\n    }}\n  ],\n  \"Plugins\": [\n    {{ \"Name\": \"PythonScriptPlugin\", \"Enabled\": true }},\n    {{ \"Name\": \"ProceduralMeshComponent\", \"Enabled\": true }},\n    {{ \"Name\": \"EditorScriptingUtilities\", \"Enabled\": true }},\n    {{ \"Name\": \"SQLiteCore\", \"Enabled\": true }}\n  ],\n  \"TargetPlatforms\": [ \"Windows\" ]\n}}\n"
    )
}

const ENGINE: &str = r#"[/Script/EngineSettings.GameMapsSettings]
GameDefaultMap=/Game/Maps/MbgenPreview
EditorStartupMap=/Game/Maps/MbgenPreview
GlobalDefaultGameMode=/Script/MbgenSim.MbgenGameMode

[/Script/PythonScriptPlugin.PythonScriptPluginSettings]
bRemoteExecution=False
+StartupScripts=mbgen_materials.py

[/Script/Engine.RendererSettings]
r.DefaultFeature.AutoExposure=True
"#;

const EDITOR: &str = r#"[/Script/UnrealEd.UnrealEdOptions]
bProceduralFoliage=False
"#;

const GAME: &str = r#"[/Script/EngineSettings.GeneralProjectSettings]
ProjectName=MbgenSim
Description=Configurable motherboard preview generated by mbgen
CompanyName=mbgen
"#;

const TARGET: &str = r#"using UnrealBuildTool;
using System.Collections.Generic;
public class MbgenSimTarget : TargetRules
{
    public MbgenSimTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Game;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("MbgenSim");
    }
}
"#;

const EDITOR_TARGET: &str = r#"using UnrealBuildTool;
using System.Collections.Generic;
public class MbgenSimEditorTarget : TargetRules
{
    public MbgenSimEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("MbgenSim");
    }
}
"#;

const BUILD: &str = r#"using UnrealBuildTool;
public class MbgenSim : ModuleRules
{
    public MbgenSim(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new string[] {
            "Core", "CoreUObject", "Engine", "InputCore", "ProceduralMeshComponent", "Json", "JsonUtilities", "UMG", "Slate", "SlateCore", "SQLiteCore"
        });
        if (Target.bBuildEditor)
        {
            PrivateDependencyModuleNames.AddRange(new string[] { "UnrealEd", "LevelEditor" });
        }
    }
}
"#;

const MODULE_H: &str = r#"#pragma once
#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

class FMbgenSimModule : public FDefaultGameModuleImpl
{
public:
    virtual void StartupModule() override;
    virtual void ShutdownModule() override;
};
"#;

const MODULE_CPP: &str = r#"#include "MbgenSim.h"
#include "Modules/ModuleManager.h"
#if WITH_EDITOR
#include "MbgenEditorBridge.h"
#endif

void FMbgenSimModule::StartupModule()
{
#if WITH_EDITOR
    FMbgenEditorBridge::Start();
#endif
}

void FMbgenSimModule::ShutdownModule()
{
#if WITH_EDITOR
    FMbgenEditorBridge::Stop();
#endif
}

IMPLEMENT_PRIMARY_GAME_MODULE(FMbgenSimModule, MbgenSim, "MbgenSim");
"#;

const BRIDGE_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenEditorBridge.h");
const BRIDGE_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenEditorBridge.cpp");

const SETTINGS_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenSettings.h");
const SETTINGS_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenSettings.cpp");
const ACTOR_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenBoardActor.h");
const ACTOR_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenBoardActor.cpp");
const MODE_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenGameMode.h");
const MODE_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenGameMode.cpp");
const PAWN_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenOrbitPawn.h");
const PAWN_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenOrbitPawn.cpp");
const NAV_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenNav.h");
const NAV_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenNav.cpp");

const PC_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPlayerController.h");
const PC_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPlayerController.cpp");
const WIDGET_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPackageWidget.h");
const WIDGET_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPackageWidget.cpp");
const LIBRARY_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenLibraryWidget.h");
const LIBRARY_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenLibraryWidget.cpp");
const OUTLINE_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenOutlineWidget.h");
const OUTLINE_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenOutlineWidget.cpp");
const ISSUES_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenIssuesWidget.h");
const ISSUES_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenIssuesWidget.cpp");
const PROPERTY_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPropertyWidget.h");
const PROPERTY_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenPropertyWidget.cpp");
const STORE_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenStore.h");
const STORE_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenStore.cpp");
const CHROME_H: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenChrome.h");
const CHROME_CPP: &str = include_str!("../../mbsim/MbgenSim/Source/MbgenSim/MbgenChrome.cpp");
const MBCORE_C_H: &str = include_str!("../../mbcore_c/include/mbcore_c.h");
const PAINT_LABELS: &str = include_str!("../../mbsim/MbgenSim/Content/Python/paint_labels.py");

const PYTHON: &str = include_str!("../../mbsim/MbgenSim/Content/Python/mbgen_materials.py");

#[cfg(test)]
mod catia_nav_source_tests {
    use super::*;

    #[test]
    fn navdiag_reads_the_viewport() {
        assert!(BRIDGE_H.contains("static void DiagnoseNav()"));
        assert!(BRIDGE_CPP.contains("mbgen navdiag cam="));
        assert!(BRIDGE_CPP.contains("mbgen navdiag sweep look_moved="));
        assert!(BRIDGE_CPP.contains("DrawDebugLine"));
        assert!(BRIDGE_CPP.contains("mbgen-navdiag.json"));
        assert!(ACTOR_H.contains("void DiagnoseNav()"));
        assert!(PYTHON.contains("def diagnose_nav"));
        assert!(PYTHON.contains("mbgen-navdiag.png"));
    }

    #[test]
    fn nav_picks_the_finite_desk() {
        assert!(ACTOR_CPP.contains("bool AMbgenBoardActor::HitDeskWorld"));
        assert!(!ACTOR_CPP.contains("TEXT(\"desk\")"));
        assert!(ACTOR_H.contains("HitDeskWorld"));
        // Navigation picks go through the shared law; HitDeskWorld is only the
        // DiagnoseNav report of where the old clamp would have landed.
        assert!(ACTOR_CPP.contains("FVector AMbgenBoardActor::NavPickPivotWorld"));
        assert!(BRIDGE_CPP.contains("Board->NavPickPivotWorld(Cursor.GetOrigin(), Cursor.GetDirection(), GNavPivot)"));
        assert!(!BRIDGE_CPP.contains("if (Board->HitDeskWorld(Cursor.GetOrigin(), Cursor.GetDirection(), World)) { return World; }"));
        assert!(BRIDGE_CPP.contains("GNavPivot = PickNavPivot(Client)"));
        assert!(PC_CPP.contains("B->NavPickPivotWorld(Origin, Dir, Orbit->Pivot())"));
        assert!(!PC_CPP.contains("HitDeskWorld"));
        assert_eq!(mbcore::DESK_PAD, 1.5);
    }

    #[test]
    fn one_navigation_law_for_both_hosts() {
        // Every camera motion in both hosts is an FMbgenNav call, and FMbgenNav
        // binds the mbcore_c mb_nav_* exports that mbcore's nav.rs implements.
        for sym in ["mb_nav_desk", "mb_nav_pick_pivot", "mb_nav_orbit", "mb_nav_look", "mb_nav_zoom_toward", "mb_nav_zoom_distance"] {
            assert!(NAV_CPP.contains(&format!("TEXT(\"{sym}\")")), "{sym} not bound");
            assert!(MBCORE_C_H.contains(sym), "{sym} not in header");
        }
        assert!(NAV_CPP.contains("mbgen nav=mbcore_c"));
        assert!(NAV_CPP.contains("mbgen nav=local (reduced"));
        assert!(ACTOR_CPP.contains("FMbgenNav::BindFromDll(DllHandle)"));
        assert!(ACTOR_CPP.contains("FMbgenNav::Unbind()"));
        for call in ["FMbgenNav::Look(", "FMbgenNav::Orbit(", "FMbgenNav::ZoomToward("] {
            assert!(BRIDGE_CPP.contains(call), "editor lacks {call}");
            assert!(PAWN_CPP.contains(call), "pawn lacks {call}");
        }
        // The pawn no longer carries its own rigid pivot-camera model.
        assert!(!PAWN_CPP.contains("PlaceCamera"));
        assert!(!PAWN_CPP.contains("RotateAngleAxis"));
        assert!(!BRIDGE_CPP.contains("RotateAngleAxis"));
    }

    #[test]
    fn empty_look_pins_the_camera() {
        assert!(BRIDGE_CPP.contains("Client->ToggleOrbitCamera(false)"));
        assert!(BRIDGE_CPP.contains("static void PinView(FLevelEditorViewportClient* Client, const FVector& Cam, const FRotator& Rot, const FVector& LookAt)"));
        assert!(BRIDGE_CPP.contains("PinView(Client, Cam, Next, GNavPivot)"));
        // Pawn look: forward changes, camera location is reused unchanged.
        assert!(PAWN_CPP.contains("Pose(CameraLocation(), Fwd)"));
        // A click on empty space picks a pivot but never runs the diagnostic sweep.
        assert!(!BRIDGE_CPP.contains("GNavPivot = PickNavPivot(Client);\n            FMbgenEditorBridge::DiagnoseNav();"));
        assert!(PC_CPP.contains("Orbit->SetPivot(B->NavPickPivotWorld(Origin, Dir, Orbit->Pivot()))"));
    }

    #[test]
    fn wheel_dolly_keeps_view_rotation_and_moves_the_pivot_to_the_pick() {
        assert!(BRIDGE_CPP.contains("Keep.Roll = 0.f"));
        assert!(BRIDGE_CPP.contains("PinView(Client, NewLoc, Keep, Hit)"));
        assert!(BRIDGE_CPP.contains("GNavPivot = Hit;"));
        // Pawn: same law — dolly along the pick ray, keep rotation, pivot = pick.
        assert!(PAWN_CPP.contains("OrbitPivot = WorldHit;"));
        assert!(PAWN_CPP.contains("Pose(Cam, Forward());"));
        assert!(!PAWN_CPP.contains("SetActorLocation(NewCam + LookDir * Distance)"));
    }

    #[test]
    fn a_drag_ends_under_the_cursor() {
        assert!(ACTOR_H.contains("bool bFinal = false"));
        assert!(ACTOR_CPP.contains("(!bFinal && ShouldThrottlePlace())"));
        assert!(BRIDGE_CPP.contains("Board->PlaceSelectedAtRay(Cursor.GetOrigin(), Cursor.GetDirection(), true);"));
        assert!(PC_CPP.contains("B->PlaceSelectedAtRay(Origin, Dir, true);"));
    }

    #[test]
    fn a_drag_can_be_cancelled_and_belongs_to_the_viewport_it_started_in() {
        // Both hosts snapshot at mouse-down and restore on Escape, with no undo entry.
        assert!(ACTOR_CPP.contains("void AMbgenBoardActor::BeginPlaceDrag()"));
        assert!(ACTOR_CPP.contains("bool AMbgenBoardActor::CancelPlaceDrag()"));
        assert!(BRIDGE_CPP.contains("Board->BeginPlaceDrag();"));
        assert!(BRIDGE_CPP.contains("Dragging->CancelPlaceDrag()"));
        assert!(PC_CPP.contains("B->BeginPlaceDrag();"));
        assert!(PC_CPP.contains("B->CancelPlaceDrag()"));
        assert!(PC_CPP.contains("EKeys::Escape"));
        // The editor resolves every sample of a gesture against the initiating viewport.
        assert!(BRIDGE_CPP.contains("static TWeakPtr<SLevelViewport> GGestureViewport;"));
        assert!(BRIDGE_CPP.contains("GGestureViewport = Started;"));
        assert!(BRIDGE_CPP.contains("static TSharedPtr<SLevelViewport> GestureViewport()"));
        assert!(!BRIDGE_CPP.contains("TSharedPtr<SLevelViewport> Viewport = ActiveLevelViewport();\n                if (Viewport.IsValid())\n                {\n                    FLevelEditorViewportClient& Client = Viewport->GetLevelViewportClient();\n                    const FViewportCursorLocation Cursor = Client.GetCursorWorldLocationFromMousePos();\n                    Board->PlaceSelectedAtRay"));
    }

    #[test]
    fn both_hosts_show_the_same_issues_panel_from_mb_circuit() {
        // One widget, fed by the resolved circuit, opened on `I` in both hosts;
        // clicking a finding selects its part. Refreshed per committed gesture.
        assert!(ISSUES_CPP.contains("Board->CircuitJson()"));
        assert!(ISSUES_CPP.contains("Board->SelectPart(Part);"));
        assert!(ISSUES_CPP.contains("TEXT(\"soc_package\")"));
        // Outputs are bound to the circuit identity: matched by
        // manifest.source_circuit_sha256, otherwise reported stale.
        assert!(ISSUES_CPP.contains("TEXT(\"source_circuit_sha256\")"));
        assert!(ISSUES_CPP.contains("ingested from a previous circuit revision"));
        for file in [".erc.json", ".parity.json", "TEXT(\"sim\")"] {
            assert!(ISSUES_CPP.contains(file), "readback lacks {file}");
        }
        assert!(ACTOR_CPP.contains("TEXT(\"mb_circuit\")"));
        assert!(ACTOR_CPP.contains("TEXT(\"mb_outline_proposal\")"));
        assert!(ACTOR_CPP.contains("circuit --design"), "exe fallback for an old DLL");
        assert!(ACTOR_CPP.contains("UMbgenIssuesWidget::RefreshAll();"));
        assert!(MBCORE_C_H.contains("mb_circuit"));
        assert!(MBCORE_C_H.contains("mb_outline_proposal"));
        assert!(BRIDGE_CPP.contains("if (Key == EKeys::I) { ToggleIssuesWindow(); return true; }"));
        assert!(PC_CPP.contains("BindKey(EKeys::I, IE_Pressed, this, &AMbgenPlayerController::ToggleIssues)"));
        assert!(PC_H.contains("TObjectPtr<UMbgenIssuesWidget> IssuesWindow;"));
        // The Board window previews the outline proposal before an Apply.
        assert!(OUTLINE_CPP.contains("Board->OutlineProposalJson(TemplateId)"));
        assert!(OUTLINE_CPP.contains("PreviewOutline(Id)"));
        assert!(OUTLINE_CPP.contains("TEXT(\"Apply %s\")"));
        // The Properties sheet previews a recipe (adds / connections / missing)
        // and applies it as exactly one gesture; existing blocks can be removed.
        assert!(PROPERTY_CPP.contains("Board->RecipeProposalJson(Recipe, PartId, Params)"));
        assert!(PROPERTY_CPP.contains("\\\"op\\\":\\\"expand_recipe\\\""));
        assert!(PROPERTY_CPP.contains("\\\"op\\\":\\\"remove_recipe\\\""));
        assert!(PROPERTY_CPP.contains("Board->BlocksHostedOn(PartId)"));
        assert!(ACTOR_CPP.contains("TEXT(\"mb_recipe_proposal\")"));
        assert!(MBCORE_C_H.contains("mb_recipe_proposal"));
    }

    #[test]
    fn zoom_ratio_and_default_sens_match_mbcore() {
        assert!(STORE_CPP.contains("FMath::Pow(1.04f, N)"));
        assert!(STORE_CPP.contains("FMath::Clamp(Notches, -1.f, 1.f)"));
        assert!(STORE_CPP.contains("sens_law"));
        assert!(SETTINGS_H.contains("MouseSensitivity = 0.25f"));
        assert_eq!(mbcore::ZOOM_RATIO, 1.04);
        assert_eq!(mbcore::DEFAULT_SENS, 0.25);
        assert_eq!(mbcore::WHEEL_NOTCH_LIMIT, 1.0);
    }

    #[test]
    fn right_click_turns_the_part_under_the_cursor() {
        assert!(BRIDGE_CPP.contains("GRightPartId = HitPartId(Hit)"));
        assert!(BRIDGE_CPP.contains("if (!GRightPartId.IsEmpty()) { Board->SelectPart(GRightPartId); }"));
        assert!(PC_CPP.contains("B && AMbgenBoardActor::IsEditablePart(Id)) { B->SelectPart(Id); }"));
    }

    #[test]
    fn rebuild_drops_a_stale_selection() {
        assert!(ACTOR_CPP.contains("!BodyCentersCm.Contains(SelectedId)"));
        assert!(ACTOR_CPP.contains("Obj->TryGetStringField(TEXT(\"reason\"), Reason)"));
    }

    #[test]
    fn undo_keeps_the_camera() {
        assert!(CHROME_CPP.contains("if (FCString::Stricmp(Label, TEXT(\"open\")) == 0)"));
        assert!(CHROME_CPP.contains("Board->FrameOrbit()"));
        assert!(!ACTOR_CPP.contains("RefreshOpenSheets();\r\n    FrameOrbit();"));
        assert!(!ACTOR_CPP.contains("RefreshOpenSheets();\n    FrameOrbit();"));
    }

    #[test]
    fn undo_seed_skips_when_log_exists() {
        assert!(STORE_H.contains("static bool HasUndoLog()"));
        assert!(ACTOR_CPP.contains("!FMbgenStore::HasUndoLog()"));
        assert!(ACTOR_CPP.contains("TryGetStringField(TEXT(\"pin\"), Pin)"));
    }

    #[test]
    fn library_json_optional_fields_use_try_get() {
        assert!(LIBRARY_CPP.contains("JsonStr(Obj, TEXT(\"vendor_id\"))"));
        assert!(LIBRARY_CPP.contains("TryGetStringField(Field, Out)"));
        assert!(PROPERTY_CPP.contains("TryGetStringField(TEXT(\"lcsc\"), Lcsc)"));
        assert!(CHROME_CPP.contains("const FVector2D Size = Win->GetSizeInScreen()"));
        assert!(PC_CPP.contains("Size.X - W - 8.f"));
    }

    #[test]
    fn name_plaques_follow_incremental_place() {
        assert!(ACTOR_CPP.contains("Plate->ComponentTags.Add(FName(*PartId))"));
        assert!(PROPERTY_CPP.contains("Turn 90°"));
        assert!(PROPERTY_CPP.contains("TryGetNumberField(TEXT(\"yaw_q\"), YawV)"));
    }

    #[test]
    fn scene_rebuild_reads_yaw_q_without_requiring_the_field() {
        assert!(ACTOR_CPP.contains("JsonInt(Obj, TEXT(\"yaw_q\"))"));
        assert!(ACTOR_CPP.contains("TryGetNumberField"));
        assert!(!ACTOR_CPP.contains("GetIntegerField(TEXT(\"yaw_q\"))"));
        assert!(ACTOR_CPP.contains("const int32 Step = bFine ? 100 : 1000;"));
    }

    #[test]
    fn orbit_and_look_zero_roll() {
        assert!(BRIDGE_CPP.contains("static FRotator LevelLook(FRotator Rot)"));
        assert!(BRIDGE_CPP.contains("const FRotator Look = LevelLook((GNavPivot - NewLoc).Rotation())"));
        assert!(BRIDGE_CPP.contains("PinView(Client, NewLoc, Look, GNavPivot)"));
        assert!(PC_CPP.contains("Orbit->AddLook(DX * 0.12f, -DY * 0.10f)"));
        assert!(PC_CPP.contains("Orbit->AddOrbit(DX * 0.12f, -DY * 0.10f)"));
        assert!(BRIDGE_CPP.contains("Board->TurnSelected()"));
        assert!(PC_CPP.contains("B->TurnSelected()"));
    }
}
