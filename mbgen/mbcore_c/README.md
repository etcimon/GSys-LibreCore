# mbcore_c

C ABI for the mbgen live session. JSON in, JSON out. `panic = abort`.

```text
cargo rustc -p mbcore_c -- -C panic=abort
```

Debug `cargo test` keeps unwind. The editor load must abort: `cargo rustc -p mbcore_c -- -C panic=abort` writes `target/debug/mbcore_c.dll` next to `mbgen.exe`. `cargo build -p mbcore_c --release` also aborts. Unreal 5.8 `AMbgenBoardActor::EnsureCore` loads that DLL with `GetDllHandle` when the file exists; `LiveRouting` still defaults off so `mb_route` is not called until the flag is on. **UBT does not build this crate.** Stop `UnrealEditor` on `MbgenSim.uproject` before rebuilding the DLL once the editor holds it (file lock, same as UBT).

ABI: `mb_session_open/close`, `mb_apply`, `mb_route`, `mb_scene`, `mb_anchors`, `mb_library_json`, `mb_string_free`. `mb_anchors` is optional at load; Unreal paints snap ticks from that JSON when the export exists. `mb_library_json` is pretty-printed.

Canonical load path (Development): `ProjectDir/../../target/debug/mbcore_c.dll`.
