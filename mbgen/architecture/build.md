# Build and verify

Commands run from `E:\cva6\mbgen` unless noted. Engine: `C:\Program Files\Epic Games\UE_5.8`.

## Rust

```text
cargo test --workspace
cargo rustc -p mbcore_c -- -C panic=abort
```

`mbcore_c` must abort: `[profile.dev.package.mbcore_c] panic=abort` is invalid; use `cargo rustc`. Debug `cargo test` keeps unwind. Editor load path (Development): `ProjectDir/../../target/debug/mbcore_c.dll` (from `mbsim/MbgenSim` that is `mbgen/target/debug/mbcore_c.dll`). Dual `mbcore_c.h` copies (`mbcore_c/include` and `mbsim/.../Source/MbgenSim`) must stay identical. UBT does **not** build this crate.

Incremental `Access is denied (os error 5)` under `target/debug/incremental` is expected while Unreal holds `mbcore_c.dll`. Stop `UnrealEditor` whose command line contains `MbgenSim.uproject` before relinking the DLL or running UBT.

Last recorded `cargo test --workspace`: 115 mbcore + 10 mbcore_c + 23 mbcompiler (counts drift). Nav: `cargo test -p mbcore --lib nav`. Circuit/recipes/router: `cargo test -p mbcore circuit` / `recipes` / `route` (the 32-net Mini-ITX fixture has an 8 s debug / 400 ms release budget). Dual-source: `cargo test -p mbcompiler catia` / `navdiag`. Profiles vs `core/include`: `cargo test -p mbcore committed_profiles_agree_with_core_include` (skips in a standalone checkout).

## Board flow (corev-mb, Python + TS)

```text
# from E:\cva6
python -m unittest discover -s corev-mb/tests -p "test_*.py"      # 21 tests; live ngspice/kicad tests skip when absent
cd build-platform && bunx tsc --noEmit && bun test test/mb-bundle.test.ts test/core-profile.test.ts
# end to end on a compiled bundle (see `mbgen compile --design FILE --out DIR`):
bun build-platform/src/cli/index.ts mb ingest --from <DIR>/platform.json --board <id>   # refuses a bundle that does not match manifest.json
bun build-platform/src/cli/index.ts mb design <id>        # circuit.json present → lossless SKiDL: *.erc.json, *.net, *.parity.json, *_bom.json; exit 1 on ERC error / parity mismatch
bun build-platform/src/cli/index.ts mb simulate <id> <scenario>   # boards/<id>/sim/<scenario>.json → outputs/sim/<scenario>.{cir,log,json}; exit 4 = incomplete (e.g. no ngspice)
```

SKiDL writes `skidl_REPL.*` / `<script>.erc` / `<script>_sklib.py` into the cwd; they are byproducts, not outputs — delete them (`*.log` is gitignored, the others are not).

CLI: `preview`, `compile`, `scene`, `anchors`, `library`, `profiles`, `package`, `build`, `open`, `mini-itx`, `textures`. `mbgen open` prefers a path containing `UE_5.8` (test `open_prefers_ue_5_8_over_5_4`). Missing-editor help says Engine 5.8.

`mbgen profiles --core-include ../core/include --out mbcore/data/profiles.json` regenerates the processor profiles from the SystemVerilog config packages (reads `config_pkg.sv` for shared constants). Run it after any `core/include/*_config_pkg.sv` change; the mbcore test above fails until the committed file matches. Unresolved fields are printed and keep that profile out of the processor window.

`mbcore_c` ABI is versioned (`MBCORE_C_ABI_VERSION` = 3, `mb_abi_version()`). The Unreal nav helper (`MbgenNav.cpp`) binds `mb_nav_*`; an older DLL logs `mbgen nav=local (reduced …)` — rebuild the DLL (editor stopped) and relaunch. v3 adds `mb_circuit` and makes `mb_route(dirty_only=1)` incremental (every net + surviving paths + `changed_nets`/`removed_nets`); the route log line now ends with `rev=N changed=K removed=M`.

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
- `mbgen nav=mbcore_c`
- `mbgen PBR materials ready`
- `mbgen frame` (Mini-ITX: `170 170 2`)
- `mbgen product sections=22`
- `mbgen board placed sections=144`
- `mbgen board capture wrote`

`LogAutomationTest Condition failed` at startup is UE UnifiedErrorTest. `aqProf.dll` / `VtuneApi.dll` load failures are Unreal noise.

Python-only changes need an editor restart, not UBT. Startup Python uses `UnrealEditorSubsystem`, `EditorActorSubsystem`, `LevelEditorSubsystem` (not `EditorLevelLibrary`).

Do not commit `Saved/`, `Binaries/`, `Intermediate/`, `DerivedDataCache/`, or `target/` (see `mbgen/.gitignore`).
