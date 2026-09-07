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

use crate::binary::{Instr, Module};
use crate::interp::{run_with_fuel_mut, Host, DEFAULT_FUEL};

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
        let out = run_with_fuel_mut(m, export_idx, args, host, DEFAULT_FUEL)?;
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

    /// Continue after a `Sleeping` step.  `value` is the resolved value for the
    /// sleeping slot (the slot itself has already been written to by the host).
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
}
