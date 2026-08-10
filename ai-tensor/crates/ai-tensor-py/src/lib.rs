// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Python: `import ai_tensor_native`

use ai_tensor_rt::{run_gemm_s8, Device, MmioDevice, SimDevice};
use pyo3::exceptions::PyRuntimeError;
use pyo3::prelude::*;
use pyo3::types::PyDict;
use std::sync::Mutex;

fn caps_to_dict(py: Python<'_>, caps: ai_tensor_rt::Caps) -> PyResult<Py<PyDict>> {
    let d = PyDict::new_bound(py);
    d.set_item("acc_tile_m", caps.acc_tile.m)?;
    d.set_item("acc_tile_n", caps.acc_tile.n)?;
    d.set_item("acc_tile_k", caps.acc_tile.k)?;
    d.set_item("macs_per_cycle", caps.macs_per_cycle)?;
    d.set_item("noc_width", caps.noc_width)?;
    d.set_item("clusters", caps.clusters)?;
    d.set_item("compute_ref", caps.compute_ref)?;
    d.set_item("wr_cpl_en", caps.wr_cpl_en)?;
    d.set_item("op_gemm", caps.op_gemm)?;
    Ok(d.into())
}

fn pmu_to_dict(py: Python<'_>, p: ai_tensor_abi::PmuSnapshot) -> PyResult<Py<PyDict>> {
    let d = PyDict::new_bound(py);
    d.set_item("r_beats", p.r_beats)?;
    d.set_item("w_beats", p.w_beats)?;
    d.set_item("cycles", p.cycles)?;
    d.set_item("gbps_x1000", p.gbps_x1000)?;
    Ok(d.into())
}

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

    fn caps(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        let dev = self.inner.lock().unwrap();
        caps_to_dict(py, dev.caps())
    }

    fn pmu(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        let dev = self.inner.lock().unwrap();
        pmu_to_dict(py, dev.pmu())
    }
}

#[pyclass]
struct Mmio {
    inner: Mutex<MmioDevice>,
}

#[pymethods]
impl Mmio {
    #[new]
    fn new() -> Self {
        let mut d = MmioDevice::new();
        d.probe_caps();
        Self {
            inner: Mutex::new(d),
        }
    }

    fn probe_caps(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        let mut dev = self.inner.lock().unwrap();
        let c = dev.probe_caps();
        caps_to_dict(py, c)
    }

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

    fn caps(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        let dev = self.inner.lock().unwrap();
        caps_to_dict(py, dev.caps())
    }

    fn pmu(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        let dev = self.inner.lock().unwrap();
        pmu_to_dict(py, dev.pmu())
    }
}

#[pyfunction]
fn pack_gemm_desc(
    m: u32,
    n: u32,
    k: u32,
    ptr_a: u64,
    ptr_b: u64,
    ptr_c: u64,
    ptr_done: u64,
) -> Vec<u8> {
    let d = ai_tensor_abi::Desc64::gemm(m, n, k).with_ptrs(ptr_a, ptr_b, ptr_c, ptr_done);
    d.pack().to_vec()
}

#[pymodule]
fn ai_tensor_native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Sim>()?;
    m.add_class::<Mmio>()?;
    m.add_function(wrap_pyfunction!(pack_gemm_desc, m)?)?;
    m.add("__version__", "0.1.0")?;
    Ok(())
}
