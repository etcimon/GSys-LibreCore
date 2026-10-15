# Build and verify

Commands run from `E:\cva6\mbgen` unless noted. Engine: `C:\Program Files\Epic Games\UE_5.8`.

## Rust

```text
cargo test --workspace
cargo rustc -p mbcore_c -- -C panic=abort
```

`mbcore_c` must abort: `[profile.dev.package.mbcore_c] panic=abort` is invalid; use `cargo rustc`. Debug `cargo test` keeps unwind. Editor load path (Development): `ProjectDir/../../target/debug/mbcore_c.dll` (from `mbsim/MbgenSim` that is `mbgen/target/debug/mbcore_c.dll`). Dual `mbcore_c.h` copies (`mbcore_c/include` and `mbsim/.../Source/MbgenSim`) must stay identical. UBT does **not** build this crate.

Incremental `Access is denied (os error 5)` under `target/debug/incremental` is expected while Unreal holds `mbcore_c.dll`. Stop `UnrealEditor` whose command line contains `MbgenSim.uproject` before relinking the DLL or running UBT.

Last recorded `cargo test --workspace`: 72 mbcore + 7 mbcore_c + 21 mbcompiler (counts drift). Nav: `cargo test -p mbcore --lib nav`. Dual-source: `cargo test -p mbcompiler catia` / `navdiag`.

CLI: `preview`, `compile`, `scene`, `anchors`, `library`, `package`, `build`, `open`, `mini-itx`, `textures`. `mbgen open` prefers a path containing `UE_5.8` (test `open_prefers_ue_5_8_over_5_4`). Missing-editor help says Engine 5.8.

`mbgen textures --design FILE --out DIR` writes only `T_SolderMask` / `T_SolderData` / `T_SolderNormal` from live `scene()` AABBs.

## Unreal

```text
# stop UnrealEditor on MbgenSim.uproject first
"%UE%\Engine\Build\BatchFiles\Build.bat" MbgenSimEditor Win64 Development -Project=E:\cva6\mbgen\mbsim\MbgenSim\MbgenSim.uproject -WaitMutex
```

Launch:

1. Write `Saved/Autosaves/PackageRestoreData.json` as UTF-16 LE `{"RestoreEnabled": false}`.
2. Start `UnrealEditor.exe` on `MbgenSim.uproject` with `-AbsLog=<Saved\log>`.
3. Wait for ready markers.

Ready markers (log):

- `mbgen dll=mbcore_c`
- `mbgen PBR materials ready`
- `mbgen frame` (Mini-ITX: `170 170 2`)
- `mbgen product sections=22`
- `mbgen board placed sections=144`
- `mbgen board capture wrote`

`LogAutomationTest Condition failed` at startup is UE UnifiedErrorTest. `aqProf.dll` / `VtuneApi.dll` load failures are Unreal noise.

Python-only changes need an editor restart, not UBT. Startup Python uses `UnrealEditorSubsystem`, `EditorActorSubsystem`, `LevelEditorSubsystem` (not `EditorLevelLibrary`).

Do not commit `Saved/`, `Binaries/`, `Intermediate/`, `DerivedDataCache/`, or `target/` (see `mbgen/.gitignore`).
