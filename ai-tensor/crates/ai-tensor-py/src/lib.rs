// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Python: `import ai_tensor_native`

use ai_tensor_rt::{run_gemm_s8, Device, SimDevice};
use pyo3::exceptions::PyRuntimeError;
use pyo3::prelude::*;
use std::sync::Mutex;

#[pyclass]
struct Sim {
    inner: Mutex<SimDevice>,
}

#[pymethods]
impl Sim {
    #[new]
    fn new() -> Self {
        Self {
            inner: Mutex::new(SimDevice::new()),
        }
    }

    /// INT8 GEMM on sim: a,b as flat row-major lists; returns (c_list, ticket, status).
    fn gemm_s8(
        &self,
        m: u32,
        n: u32,
        k: u32,
        a: Vec<i8>,
        b: Vec<i8>,
        ticket: u32,
    ) -> PyResult<(Vec<i32>, u32, u16)> {
        let mut dev = self.inner.lock().unwrap();
        run_gemm_s8(&mut *dev, m, n, k, &a, &b, ticket)
            .map(|(c, comp)| (c, comp.ticket, comp.status))
            .map_err(|e| PyRuntimeError::new_err(e.to_string()))
    }

    fn enable(&self, on: bool) {
        self.inner.lock().unwrap().enable(on);
    }
}

/// Pack a GEMM descriptor header as bytes (for debugging / ELF compare).
#[pyfunction]
fn pack_gemm_desc(m: u32, n: u32, k: u32, ptr_a: u64, ptr_b: u64, ptr_c: u64, ptr_done: u64) -> Vec<u8> {
    let d = ai_tensor_abi::Desc64::gemm(m, n, k).with_ptrs(ptr_a, ptr_b, ptr_c, ptr_done);
    d.pack().to_vec()
}

#[pymodule]
fn ai_tensor_native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Sim>()?;
    m.add_function(wrap_pyfunction!(pack_gemm_desc, m)?)?;
    m.add("__version__", "0.1.0")?;
    Ok(())
}
