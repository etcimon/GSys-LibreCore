// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Binaryen Asyncify runtime for the guest WASM interpreter.
//!
//! This implements the five Asyncify control exports (`asyncify_start_unwind`,
//! `asyncify_stop_unwind`, `asyncify_start_rewind`, `asyncify_stop_rewind`,
//! `asyncify_get_state`) and the host rewind loop.  The asyncify stack lives in
//! linear memory at the descriptor pointed to by `__asyncify_data`.
//!
//! See `kernel-spec/svelte-d/binaryen/src/passes/Asyncify.cpp` for the source
//! of truth: the descriptor is `{ i32 pos, i32 end }` for wasm32; `pos` is the
//! current top of the asyncify stack and `end` is the limit.  The call-index
//! and local-save area grows upward from `pos`.

use crate::binary::{Instr, Module, MAX_MEMORY_PAGES};
use crate::interp::{run_with_fuel_mut, Host, DEFAULT_FUEL, MAX_FUEL};

/// Asyncify execution state.
pub const STATE_NORMAL: i32 = 0;
pub const STATE_UNWINDING: i32 = 1;
pub const STATE_REWINDING: i32 = 2;

// Offsets inside the `__asyncify_data` descriptor (wasm32):
//   pos = data + 0
//   end = data + 4
// The stack starts at `data + 8`.

/// Result of one guest async step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// The export finished normally.  Contains the function results.
    Done(Vec<i32>),
    /// The guest is unwinding and the host must await a Promise.  Contains the
    /// slot/handle that was passed to the sleeping import and the asyncify data
    /// pointer that was active when the unwind happened.
    Sleeping { slot: i32, data: u32 },
}

/// Indices of the five Asyncify control exports plus the globals.
#[derive(Debug, Clone)]
pub struct Asyncify {
    pub start_unwind: u32,
    pub stop_unwind: u32,
    pub start_rewind: u32,
    pub stop_rewind: u32,
    pub get_state: u32,
    pub state_global: u32,
    pub data_global: u32,
}

impl Asyncify {
    /// Find the Asyncify exports and globals in a decoded module.
    pub fn new(m: &Module) -> Result<Self, String> {
        let get_state = find_func_export(m, "asyncify_get_state")?;
        let start_unwind = find_func_export(m, "asyncify_start_unwind")?;
        let imports = m.imports.len() as u32;
        if get_state < imports || start_unwind < imports {
            return Err("asyncify control exports must be module functions, not imports".into());
        }
        let get_state_body = (get_state - imports) as usize;
        let start_unwind_body = (start_unwind - imports) as usize;
        let state_global = first_global_get(&m.bodies[get_state_body])
            .ok_or("asyncify_get_state must be a single global.get")?;
        let data_global = second_global_set(&m.bodies[start_unwind_body])
            .ok_or("asyncify_start_unwind must set __asyncify_data")?;
        Ok(Self {
            start_unwind,
            stop_unwind: find_func_export(m, "asyncify_stop_unwind")?,
            start_rewind: find_func_export(m, "asyncify_start_rewind")?,
            stop_rewind: find_func_export(m, "asyncify_stop_rewind")?,
            get_state,
            state_global,
            data_global,
        })
    }

    /// Read the current `__asyncify_state` by calling `asyncify_get_state`.
    pub fn state(&self, m: &mut Module, host: &mut impl Host) -> Result<i32, String> {
        let out = run_with_fuel_mut(m, self.get_state, &[], host, DEFAULT_FUEL)?;
        out.into_iter()
            .next()
            .ok_or_else(|| "asyncify_get_state returned no value".into())
    }

    /// Run an export and drive one Asyncify step.  The caller is responsible for
    /// resolving the `Sleeping` slot and calling back.
    pub fn step(
        &self,
        m: &mut Module,
        export_idx: u32,
        args: &[i32],
        data: u32,
        stack_end: u32,
        host: &mut impl Host,
    ) -> Result<Step, String> {
        m.globals[self.state_global as usize].value = STATE_NORMAL as i64;
        m.globals[self.data_global as usize].value = data as i64;
        write_asyncify_data(&mut m.memory, data, data + 8, stack_end)?;
        self.step_inner(m, export_idx, args, data, host)
    }

    fn step_inner(
        &self,
        m: &mut Module,
        export_idx: u32,
        args: &[i32],
        data: u32,
        host: &mut impl Host,
    ) -> Result<Step, String> {
        let out = run_with_fuel_mut(m, export_idx, args, host, MAX_FUEL)?;
        let state = self.state(m, host)?;
        if state == STATE_NORMAL {
            return Ok(Step::Done(out));
        }
        if state == STATE_UNWINDING {
            let slot = host
                .take_slot()
                .ok_or("asyncify unwind without a pending slot")?;
            self.stop_unwind(m, host)?;
            return Ok(Step::Sleeping { slot, data });
        }
        Err(format!("unexpected asyncify state {state}"))
    }

    /// Continue after a `Sleeping` step.
    ///
    /// Matches `wrapExportFn` in `svelte-engine/src-ts/modules/asyncify.ts`:
    /// settle the Promise (`resolve_slot`, including reject → `libwasmAwaitFailed`)
    /// **then** `asyncify_start_rewind` and re-enter the export. Do not throw
    /// on reject before rewind — wasm-eh landing pads run after it.
    pub fn resume(
        &self,
        m: &mut Module,
        export_idx: u32,
        args: &[i32],
        data: u32,
        stack_end: u32,
        host: &mut impl Host,
    ) -> Result<Step, String> {
        let _ = stack_end;
        self.start_rewind(m, data, host)?;
        self.step_inner(m, export_idx, args, data, host)
    }

    /// Prepare an asyncify data region in the module's memory and call
    /// `asyncify_start_unwind`.  `stack_end` is the exclusive end of the reserved
    /// region.  The descriptor is written at `data`; the stack starts at
    /// `data + 8`.
    pub fn start_unwind(
        &self,
        m: &mut Module,
        data: u32,
        stack_end: u32,
        host: &mut impl Host,
    ) -> Result<(), String> {
        // This should not normally be called by the host: the sleeping import
        // implementation inside the module calls it.  Exposed for tests.
        write_asyncify_data(&mut m.memory, data, data + 8, stack_end)?;
        run_with_fuel_mut(m, self.start_unwind, &[data as i32], host, DEFAULT_FUEL).map(|_| ())
    }

    /// Call `asyncify_stop_unwind`.
    pub fn stop_unwind(&self, m: &mut Module, host: &mut impl Host) -> Result<(), String> {
        run_with_fuel_mut(m, self.stop_unwind, &[], host, DEFAULT_FUEL).map(|_| ())
    }

    /// Call `asyncify_start_rewind` with the same data descriptor.
    pub fn start_rewind(
        &self,
        m: &mut Module,
        data: u32,
        host: &mut impl Host,
    ) -> Result<(), String> {
        run_with_fuel_mut(m, self.start_rewind, &[data as i32], host, DEFAULT_FUEL).map(|_| ())
    }

    /// Call `asyncify_stop_rewind`.
    pub fn stop_rewind(&self, m: &mut Module, host: &mut impl Host) -> Result<(), String> {
        run_with_fuel_mut(m, self.stop_rewind, &[], host, DEFAULT_FUEL).map(|_| ())
    }
}

fn find_func_export(m: &Module, name: &str) -> Result<u32, String> {
    m.exports
        .iter()
        .find(|e| e.name == name && e.kind == 0)
        .map(|e| e.idx)
        .ok_or_else(|| format!("missing asyncify export {name}"))
}

fn first_global_get(body: &[Instr]) -> Option<u32> {
    body.iter().find_map(|ins| match ins {
        Instr::GlobalGet(idx) => Some(*idx),
        _ => None,
    })
}

fn second_global_set(body: &[Instr]) -> Option<u32> {
    let mut found_state_set = false;
    for ins in body {
        if let Instr::GlobalSet(idx) = ins {
            if !found_state_set {
                found_state_set = true;
            } else {
                return Some(*idx);
            }
        }
    }
    None
}

/// Place the Asyncify descriptor above the D heap and leave room for the
/// interpreter string pool to grow (`MAX_MEMORY_PAGES` is 64).
pub fn reserve_asyncify_scratch(m: &mut Module, heap_base: u32) -> (u32, u32) {
    const STACK: u32 = 64 * 1024;
    const HEAP_ROOM: u32 = 512 * 1024;
    let orig = m.memory.len() as u32;
    let mut data = heap_base.max(orig).saturating_add(HEAP_ROOM) & !7;
    let mut stack_end = data + 8 + STACK;
    let max_bytes = (MAX_MEMORY_PAGES.saturating_sub(1)) * 65536;
    if stack_end > max_bytes {
        data = (max_bytes - 8 - STACK) & !7;
        stack_end = data + 8 + STACK;
    }
    let pages = ((stack_end + 65535) / 65536)
        .max(m.mem_pages)
        .min(MAX_MEMORY_PAGES);
    m.max_mem_pages = Some(MAX_MEMORY_PAGES);
    m.mem_pages = pages;
    m.memory.resize(pages as usize * 65536, 0);
    debug_assert_eq!(m.memory.len(), m.mem_pages as usize * 65536);
    (data, stack_end)
}

/// Write the `{ pos, end }` descriptor at `data` in module memory.
fn write_asyncify_data(mem: &mut [u8], data: u32, pos: u32, end: u32) -> Result<(), String> {
    let base = data as usize;
    let end_mem = base + 8;
    if end_mem > mem.len() {
        return Err("asyncify data region outside linear memory".into());
    }
    mem[base..base + 4].copy_from_slice(&pos.to_le_bytes());
    mem[base + 4..base + 8].copy_from_slice(&end.to_le_bytes());
    Ok(())
}

/// Locate the etcimon/binaryen `svelte-d` `wasm-opt` (Flatten+`try_table`
/// asyncify). Same order as `browser-ui/compiler/binaryen.ts`.
pub fn find_fork_wasm_opt() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    let exe = if cfg!(windows) {
        "wasm-opt.exe"
    } else {
        "wasm-opt"
    };
    let mut dirs = Vec::new();
    for var in ["SVELTE_D_WASM_OPT", "WASM_OPT"] {
        if let Ok(p) = std::env::var(var) {
            let p = PathBuf::from(p);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    if let Ok(man) = std::env::var("CARGO_MANIFEST_DIR") {
        let root = std::path::Path::new(&man)
            .join("..")
            .join("..")
            .canonicalize()
            .ok();
        if let Some(root) = root {
            dirs.push(
                root.join("browser-ui")
                    .join("toolchains")
                    .join("binaryen-svelte-d")
                    .join("bin"),
            );
            dirs.push(root.join("svelte-d").join("binaryen-build").join("bin"));
            dirs.push(
                root.join("svelte-d")
                    .join("binaryen")
                    .join("build")
                    .join("bin"),
            );
        }
    }
    if let Some(home) = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")) {
        dirs.push(
            std::path::Path::new(&home)
                .join(".svelte-d")
                .join("toolchains")
                .join("binaryen-svelte-d")
                .join("bin"),
        );
    }
    for dir in dirs {
        let p = dir.join(exe);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// Run the forked `wasm-opt --asyncify` on WAT that uses wasm-eh `try`/`catch`
/// around `env.libwasm_await__void`. Stock Binaryen Flatten-crashes on this.
pub fn asyncify_wat(wat: &str) -> Result<Vec<u8>, String> {
    let opt = find_fork_wasm_opt().ok_or_else(|| {
        "forked wasm-opt not found (SVELTE_D_WASM_OPT / ~/.svelte-d/toolchains/binaryen-svelte-d)"
            .to_string()
    })?;
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "g6b-ay-eh-{}-{}",
        std::process::id(),
        N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let input = dir.join("in.wat");
    let output = dir.join("out.wasm");
    std::fs::write(&input, wat).map_err(|e| e.to_string())?;
    let run = std::process::Command::new(&opt)
        .args([
            "--enable-exception-handling",
            "--enable-bulk-memory",
            "--enable-reference-types",
            "--asyncify",
            "--pass-arg=asyncify-imports@env.libwasm_await__void",
        ])
        .arg(&input)
        .arg("-o")
        .arg(&output)
        .output()
        .map_err(|e| e.to_string())?;
    if !run.status.success() {
        return Err(format!(
            "wasm-opt --asyncify failed: {} {}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        ));
    }
    std::fs::read(&output).map_err(|e| e.to_string())
}

/// UI-thread job vs DOM event.
///
/// `$on_click` is the event export: no await, no catch, it only `call`s
/// `$thrower`. `$thrower` is the callee that actually throws. `$surrounding`
/// is the UI-thread job — `try { await; on_click(); } catch` — so the throw
/// is caught outside the event after asyncify rewind delivers it.
pub const UI_EVENT_THROW_WAT: &str = r#"(module
  (import "env" "libwasm_await__void" (func $await (param i32)))
  (tag $e (param i32))
  (memory (export "memory") 1)
  (func $thrower
    i32.const 7
    throw $e
  )
  (export "thrower" (func $thrower))
  (func $on_click
    call $thrower
  )
  (export "on_click" (func $on_click))
  (func $surrounding (result i32)
    (try (result i32)
      (do
        (call $await (i32.const 0))
        (call $on_click)
        (i32.const 0)
      )
      (catch $e
        (drop)
        (i32.const 1)
      )
    )
  )
  (export "surrounding" (func $surrounding))
)
"#;

/// Fork Binaryen `try_table` + asyncify (commits `0b66e0b71` Flatten,
/// `6f3b89e06` / `bd3206287` valued catch dests). Host drive matches
/// `asyncify.ts` `wrapImportFn` / `wrapExportFn`. `domEvent` is in
/// `EXPORTED_FROM_D` so the event export is the wrapped entry.
///
/// `$throw_in_await` — simple throw after `libwasm_await__void` inside
/// `try_table`; catch dest is the valued block (payload 7).
/// `$on_click` / `$domEvent` — async DOM event that awaits, then calls
/// `$thrower`; catch dest drops the payload and returns 1.
/// `$await_reject` — wrapExportFn reject still rewinds; D reads
/// `libwasm_await_failed` after rewind (no wasm-eh).
pub const TRY_TABLE_AWAIT_WAT: &str = r#"(module
  (import "env" "libwasm_await__void" (func $await (param i32)))
  (import "env" "libwasm_await_failed" (func $failed (result i32)))
  (tag $e (param i32))
  (memory (export "memory") 1)
  (func $thrower
    i32.const 7
    throw $e
  )
  (export "thrower" (func $thrower))
  (func $throw_in_await (result i32)
    (block $catch (result i32)
      (try_table (catch $e $catch)
        (call $await (i32.const 0))
        (throw $e (i32.const 7))
      )
      (unreachable)
    )
  )
  (export "throw_in_await" (func $throw_in_await))
  (func $on_click (result i32)
    (block $done (result i32)
      (drop
        (block $catch (result i32)
          (try_table (catch $e $catch)
            (call $await (i32.const 0))
            (call $thrower)
            (br $done (i32.const 0))
          )
          (unreachable)
        )
      )
      (i32.const 1)
    )
  )
  (export "on_click" (func $on_click))
  (export "domEvent" (func $on_click))
  (func $await_reject (result i32)
    (call $await (i32.const 2))
    (call $failed)
  )
  (export "await_reject" (func $await_reject))
)
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::binary::{Export, FuncType, Global, Module, ValType};
    use crate::interp::tests::TestHost;

    fn make_module() -> Module {
        Module {
            types: vec![
                FuncType {
                    params: vec![],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![],
            func_types: vec![2, 1, 0, 1, 0],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![
                Export {
                    name: "asyncify_get_state".into(),
                    kind: 0,
                    idx: 0,
                },
                Export {
                    name: "asyncify_start_unwind".into(),
                    kind: 0,
                    idx: 1,
                },
                Export {
                    name: "asyncify_stop_unwind".into(),
                    kind: 0,
                    idx: 2,
                },
                Export {
                    name: "asyncify_start_rewind".into(),
                    kind: 0,
                    idx: 3,
                },
                Export {
                    name: "asyncify_stop_rewind".into(),
                    kind: 0,
                    idx: 4,
                },
            ],
            bodies: vec![
                // 0: get_state
                vec![Instr::GlobalGet(0), Instr::End],
                // 1: start_unwind
                vec![
                    Instr::I32Const(STATE_UNWINDING),
                    Instr::GlobalSet(0),
                    Instr::LocalGet(0),
                    Instr::GlobalSet(1),
                    Instr::End,
                ],
                // 2: stop_unwind
                vec![
                    Instr::I32Const(STATE_NORMAL),
                    Instr::GlobalSet(0),
                    Instr::End,
                ],
                // 3: start_rewind
                vec![
                    Instr::I32Const(STATE_REWINDING),
                    Instr::GlobalSet(0),
                    Instr::LocalGet(0),
                    Instr::GlobalSet(1),
                    Instr::End,
                ],
                // 4: stop_rewind
                vec![
                    Instr::I32Const(STATE_NORMAL),
                    Instr::GlobalSet(0),
                    Instr::End,
                ],
            ],
            memory: vec![0; 65536],
            locals: vec![0, 0, 0, 0, 0],
            has_memory: true,
            tags: vec![],
            globals: vec![
                Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                },
                Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                },
            ],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: Vec::new(),
        }
    }

    fn make_sleep_module() -> Module {
        use crate::binary::Import;
        Module {
            types: vec![
                // 0: get_state () -> i32
                FuncType {
                    params: vec![],
                    results: vec![ValType::I32],
                },
                // 1: start_unwind (i32) -> ()
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                // 2: stop_unwind () -> ()
                FuncType {
                    params: vec![],
                    results: vec![],
                },
                // 3: _start (i32) -> i32
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![ValType::I32],
                },
            ],
            imports: vec![Import {
                module: "env".into(),
                name: "libwasm_await__void".into(),
                typeidx: 1,
            }],
            func_types: vec![0, 1, 2, 1, 2, 3],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![
                Export {
                    name: "asyncify_get_state".into(),
                    kind: 0,
                    idx: 1,
                },
                Export {
                    name: "asyncify_start_unwind".into(),
                    kind: 0,
                    idx: 2,
                },
                Export {
                    name: "asyncify_stop_unwind".into(),
                    kind: 0,
                    idx: 3,
                },
                Export {
                    name: "asyncify_start_rewind".into(),
                    kind: 0,
                    idx: 4,
                },
                Export {
                    name: "asyncify_stop_rewind".into(),
                    kind: 0,
                    idx: 5,
                },
                Export {
                    name: "_start".into(),
                    kind: 0,
                    idx: 6,
                },
            ],
            bodies: vec![
                // 0: get_state
                vec![Instr::GlobalGet(0), Instr::End],
                // 1: start_unwind
                vec![
                    Instr::I32Const(STATE_UNWINDING),
                    Instr::GlobalSet(0),
                    Instr::LocalGet(0),
                    Instr::GlobalSet(1),
                    Instr::End,
                ],
                // 2: stop_unwind
                vec![
                    Instr::I32Const(STATE_NORMAL),
                    Instr::GlobalSet(0),
                    Instr::End,
                ],
                // 3: start_rewind
                vec![
                    Instr::I32Const(STATE_REWINDING),
                    Instr::GlobalSet(0),
                    Instr::LocalGet(0),
                    Instr::GlobalSet(1),
                    Instr::End,
                ],
                // 4: stop_rewind
                vec![
                    Instr::I32Const(STATE_NORMAL),
                    Instr::GlobalSet(0),
                    Instr::End,
                ],
                // 5: _start
                vec![
                    Instr::GlobalGet(0),
                    Instr::I32Const(0),
                    Instr::I32Ne,
                    Instr::If(Some(ValType::I32)),
                    Instr::Call(5),
                    Instr::I32Const(42),
                    Instr::Else,
                    Instr::LocalGet(0),
                    Instr::Call(2),
                    Instr::I32Const(7),
                    Instr::Call(0),
                    Instr::I32Const(0),
                    Instr::End,
                    Instr::End,
                ],
            ],
            memory: vec![0; 65536],
            locals: vec![0, 0, 0, 0, 0, 0],
            has_memory: true,
            tags: vec![],
            globals: vec![
                Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                },
                Global {
                    valtype: ValType::I32,
                    mutable: true,
                    value: 0,
                },
            ],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: Vec::new(),
        }
    }

    #[test]
    fn asyncify_state_machine_round_trips() {
        let mut m = make_module();
        let a = Asyncify::new(&m).unwrap();
        assert_eq!(a.state_global, 0);
        assert_eq!(a.data_global, 1);
        let mut host = TestHost::default();
        let data = 1024;
        let stack_end = 2048;

        // Initial state is normal.
        assert_eq!(a.state(&mut m, &mut host).unwrap(), STATE_NORMAL);

        // Start unwind.
        a.start_unwind(&mut m, data, stack_end, &mut host).unwrap();
        assert_eq!(a.state(&mut m, &mut host).unwrap(), STATE_UNWINDING);

        // Descriptor is correct.
        let pos = u32::from_le_bytes(
            m.memory[data as usize..data as usize + 4]
                .try_into()
                .unwrap(),
        );
        let end = u32::from_le_bytes(
            m.memory[data as usize + 4..data as usize + 8]
                .try_into()
                .unwrap(),
        );
        assert_eq!(pos, data + 8);
        assert_eq!(end, stack_end);

        // Stop unwind.
        a.stop_unwind(&mut m, &mut host).unwrap();
        assert_eq!(a.state(&mut m, &mut host).unwrap(), STATE_NORMAL);

        // Start rewind.
        a.start_rewind(&mut m, data, &mut host).unwrap();
        assert_eq!(a.state(&mut m, &mut host).unwrap(), STATE_REWINDING);

        // Stop rewind.
        a.stop_rewind(&mut m, &mut host).unwrap();
        assert_eq!(a.state(&mut m, &mut host).unwrap(), STATE_NORMAL);
    }

    #[test]
    fn asyncify_step_resumes_through_libwasm_await_void() {
        let mut m = make_sleep_module();
        let a = Asyncify::new(&m).unwrap();
        let mut host = TestHost::default();
        let data = 1024u32;
        let stack_end = 2048u32;
        let start = m
            .exports
            .iter()
            .find(|e| e.name == "_start")
            .map(|e| e.idx)
            .unwrap();

        let step = a
            .step(&mut m, start, &[data as i32], data, stack_end, &mut host)
            .unwrap();
        match step {
            Step::Sleeping { slot, data: d } => {
                assert_eq!(slot, 7);
                assert_eq!(d, data);
            }
            _ => panic!("expected Sleeping"),
        }

        let step = a
            .resume(&mut m, start, &[data as i32], data, stack_end, &mut host)
            .unwrap();
        match step {
            Step::Done(v) => assert_eq!(v, vec![42]),
            _ => panic!("expected Done"),
        }
    }

    fn load_ui_event_throw_module() -> crate::binary::Module {
        let bytes = crate::asyncify_wat(crate::UI_EVENT_THROW_WAT)
            .expect("forked wasm-opt --asyncify of try/await/catch WAT");
        crate::decode(&bytes).expect("decode asyncified event-throw module")
    }

    fn export_idx(m: &crate::binary::Module, name: &str) -> u32 {
        m.exports
            .iter()
            .find(|e| e.name == name && e.kind == 0)
            .map(|e| e.idx)
            .unwrap_or_else(|| panic!("missing export {name}"))
    }

    #[test]
    fn ui_dom_event_thrower_is_uncaught_without_surrounding_try() {
        let mut m = load_ui_event_throw_module();
        let mut host = TestHost::default();
        let on_click = export_idx(&m, "on_click");
        let err = crate::run_with_fuel_mut(&mut m, on_click, &[], &mut host, crate::DEFAULT_FUEL)
            .expect_err("DOM event export has no catch");
        assert!(
            err.contains("unhandled wasm exception"),
            "event-only throw: {err}"
        );
        assert!(
            host.throw_stack.iter().any(|f| f == "thrower"),
            "callee of the event: {:?}",
            host.throw_stack
        );
        assert!(
            host.throw_stack.iter().any(|f| f == "on_click"),
            "event frame: {:?}",
            host.throw_stack
        );
        assert!(
            !host.throw_stack.iter().any(|f| f == "surrounding"),
            "event path must not enter try/await/catch: {:?}",
            host.throw_stack
        );
    }

    #[test]
    fn ui_try_await_catch_is_rejected_before_unwind() {
        let mut m = load_ui_event_throw_module();
        let a = Asyncify::new(&m).expect("wasm-opt left asyncify exports");
        let mut host = TestHost::default();
        let surrounding = export_idx(&m, "surrounding");
        let err = a
            .step(&mut m, surrounding, &[], 1024, 4096, &mut host)
            .expect_err("await inside try must not unwind");
        assert!(
            err.contains("await inside try"),
            "interp must refuse await-in-try: {err}"
        );
    }

    fn load_try_table_await_module() -> crate::binary::Module {
        let bytes = crate::asyncify_wat(crate::TRY_TABLE_AWAIT_WAT)
            .expect("forked wasm-opt --asyncify of try_table WAT");
        crate::decode(&bytes).expect("decode asyncified try_table module")
    }

    #[test]
    fn try_table_await_is_rejected_before_unwind() {
        let mut m = load_try_table_await_module();
        let a = Asyncify::new(&m).expect("wasm-opt left asyncify exports");
        let mut host = TestHost::default();
        let throw_in_await = export_idx(&m, "throw_in_await");
        let err = a
            .step(&mut m, throw_in_await, &[], 1024, 4096, &mut host)
            .expect_err("await inside try_table must not unwind");
        assert!(
            err.contains("await inside try"),
            "interp must refuse await-in-try_table: {err}"
        );
    }

    #[test]
    fn async_dom_event_await_inside_try_is_rejected() {
        let mut m = load_try_table_await_module();
        let a = Asyncify::new(&m).expect("wasm-opt left asyncify exports");
        let mut host = TestHost::default();
        let dom_event = export_idx(&m, "domEvent");
        let err = a
            .step(&mut m, dom_event, &[], 1024, 4096, &mut host)
            .expect_err("await inside try_table must not unwind");
        assert!(
            err.contains("await inside try"),
            "interp must refuse event await-in-try: {err}"
        );
    }

    #[test]
    fn wrap_export_fn_reject_still_rewinds() {
        let mut m = load_try_table_await_module();
        let a = Asyncify::new(&m).expect("wasm-opt left asyncify exports");
        let mut host = TestHost::default();
        let await_reject = export_idx(&m, "await_reject");
        let data = 1024u32;
        let stack_end = 4096u32;
        let slot = match a
            .step(&mut m, await_reject, &[], data, stack_end, &mut host)
            .expect("await unwind")
        {
            Step::Sleeping { slot, .. } => slot,
            other => panic!("expected Sleeping, {other:?}"),
        };
        // wrapExportFn: reject records fail, then start_rewind anyway.
        host.resolve_result = Some(Err("boom".into()));
        host.resolve_slot(slot).expect("recordAwaitFail");
        match a
            .resume(&mut m, await_reject, &[], data, stack_end, &mut host)
            .expect("reject still rewinds")
        {
            Step::Done(v) => assert_eq!(v, vec![1], "libwasm_await_failed after rewind"),
            other => panic!("expected Done(1), {other:?}"),
        }
        assert!(host.last_await_failed);
        assert_eq!(host.last_await_error, "boom");
    }

    #[test]
    fn reserve_scratch_keeps_memory_valid() {
        if !crate::bios_ui_libwasm_live() {
            return;
        }
        let mut m = crate::decode(crate::bios_ui_libwasm()).unwrap();
        crate::validate(&m).expect("before");
        let (data, end) = reserve_asyncify_scratch(&mut m, 1_112_560);
        assert!(end > data);
        crate::validate(&m).unwrap_or_else(|e| {
            panic!(
                "after reserve: {e} len={} pages={} max={:?} data={data} end={end}",
                m.memory.len(),
                m.mem_pages,
                m.max_mem_pages
            )
        });
    }
}
