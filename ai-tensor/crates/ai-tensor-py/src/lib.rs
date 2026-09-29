// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Python: `import ai_tensor_native`

use ai_tensor_abi::{AccTile, CapRegs, VA_TURBO_TEST_MACS};
use ai_tensor_rt::{execute_va_turbo_test_s8_at, run_gemm_s8, Device, MmioDevice, SimDevice};
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
    d.set_item("dtype_mask", caps.dtype_mask)?;
    Ok(d.into())
}

fn is_directed(caps: ai_tensor_rt::Caps) -> bool {
    caps.macs_per_cycle == VA_TURBO_TEST_MACS && caps.acc_tile == AccTile::VA_TURBO_TEST
}

fn directed_sim() -> SimDevice {
    let mut caps = ai_tensor_rt::Caps::default();
    caps.macs_per_cycle = VA_TURBO_TEST_MACS;
    caps.acc_tile = AccTile::VA_TURBO_TEST;
    SimDevice::with_caps(caps)
}

fn va_turbo_dict<D: Device>(
    py: Python<'_>,
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
) -> PyResult<Py<PyDict>> {
    let got = execute_va_turbo_test_s8_at(dev, m, n, k, a, b, ticket)
        .map_err(|e| PyRuntimeError::new_err(e.to_string()))?;
    let d = PyDict::new_bound(py);
    d.set_item("c", got.c)?;
    d.set_item("flags", got.flags)?;
    d.set_item("read_a", got.read_a)?;
    d.set_item("read_b", got.read_b)?;
    d.set_item("hit_a", got.hit_a)?;
    d.set_item("hit_b", got.hit_b)?;
    d.set_item("reuse_enabled", got.reuse_enabled)?;
    d.set_item("requested_level", 0)?;
    d.set_item("applied_level", 0)?;
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
    #[pyo3(signature = (software_reference=false, directed=false))]
    fn new(software_reference: bool, directed: bool) -> Self {
        let dev = if software_reference {
            SimDevice::with_caps(ai_tensor_rt::Caps::software_reference_v2())
        } else if directed {
            directed_sim()
        } else {
            SimDevice::new()
        };
        Self {
            inner: Mutex::new(dev),
        }
    }

    fn reports_directed_tile(&self) -> bool {
        is_directed(self.inner.lock().unwrap().caps())
    }

    #[pyo3(signature = (m, n, k, a, b, ticket=1))]
    fn run_va_turbo_test_s8(
        &self,
        py: Python<'_>,
        m: u32,
        n: u32,
        k: u32,
        a: Vec<i8>,
        b: Vec<i8>,
        ticket: u32,
    ) -> PyResult<Py<PyDict>> {
        let mut dev = self.inner.lock().unwrap();
        va_turbo_dict(py, &mut *dev, m, n, k, &a, &b, ticket)
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

    fn gemm_native(
        &self, py: Python<'_>, a: Vec<u8>, b: Vec<u8>, m: u32, n: u32, k: u32,
        numfmt: u32, lda: u32, ldb: u32, ticket: u32,
    ) -> PyResult<Py<pyo3::types::PyBytes>> {
        let fmt = ai_tensor_abi::NumFmt::from_abi(numfmt)
            .ok_or_else(|| PyRuntimeError::new_err("ST_BAD_FMT: invalid numfmt"))?;
        let mut dev = self.inner.lock().unwrap();
        let (out, _) = ai_tensor_rt::run_gemm_native(&mut *dev, m, n, k, &a, &b, fmt, Some(lda), Some(ldb), ticket)
            .map_err(|e| PyRuntimeError::new_err(e.to_string()))?;
        Ok(pyo3::types::PyBytes::new_bound(py, &out).unbind())
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
    #[pyo3(signature = (software_reference=false, directed=false))]
    fn new(software_reference: bool, directed: bool) -> Self {
        let mut d = if software_reference {
            MmioDevice::software_reference_v2()
        } else if directed {
            let mut cap = CapRegs::island_p3_sim_default();
            cap.macs_per_cycle = VA_TURBO_TEST_MACS;
            cap.acc_tile = AccTile::VA_TURBO_TEST;
            MmioDevice::with_cap(cap)
        } else {
            MmioDevice::new()
        };
        d.probe_caps();
        Self {
            inner: Mutex::new(d),
        }
    }

    fn reports_directed_tile(&self) -> bool {
        is_directed(self.inner.lock().unwrap().caps())
    }

    #[pyo3(signature = (m, n, k, a, b, ticket=1))]
    fn run_va_turbo_test_s8(
        &self,
        py: Python<'_>,
        m: u32,
        n: u32,
        k: u32,
        a: Vec<i8>,
        b: Vec<i8>,
        ticket: u32,
    ) -> PyResult<Py<PyDict>> {
        let mut dev = self.inner.lock().unwrap();
        va_turbo_dict(py, &mut *dev, m, n, k, &a, &b, ticket)
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

    fn gemm_native(
        &self, py: Python<'_>, a: Vec<u8>, b: Vec<u8>, m: u32, n: u32, k: u32,
        numfmt: u32, lda: u32, ldb: u32, ticket: u32,
    ) -> PyResult<Py<pyo3::types::PyBytes>> {
        let fmt = ai_tensor_abi::NumFmt::from_abi(numfmt)
            .ok_or_else(|| PyRuntimeError::new_err("ST_BAD_FMT: invalid numfmt"))?;
        let mut dev = self.inner.lock().unwrap();
        let (out, _) = ai_tensor_rt::run_gemm_native(&mut *dev, m, n, k, &a, &b, fmt, Some(lda), Some(ldb), ticket)
            .map_err(|e| PyRuntimeError::new_err(e.to_string()))?;
        Ok(pyo3::types::PyBytes::new_bound(py, &out).unbind())
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
    m.add("CONTRACT_VERSION", ai_tensor_abi::CONTRACT_VERSION)?;
    Ok(())
}
