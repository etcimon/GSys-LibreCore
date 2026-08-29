// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! C ABI. Handles are heap boxes leaked into raw pointers / ids.

use crate::cycle::{LregBank, PregBank};
use crate::humanoid::{standing_humanoid, Humanoid};
use crate::intuition::{EnvWorld, Hit, Keyframe, PlanHint, Pose, Vec3};
use crate::motors::Articulation;
use crate::qram::Qram;
use std::collections::HashMap;
use std::ffi::c_int;
use std::sync::{Mutex, OnceLock};

fn worlds() -> &'static Mutex<HashMap<u64, EnvWorld>> {
    static W: OnceLock<Mutex<HashMap<u64, EnvWorld>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(HashMap::new()))
}

fn humanoids() -> &'static Mutex<HashMap<u64, Humanoid>> {
    static H: OnceLock<Mutex<HashMap<u64, Humanoid>>> = OnceLock::new();
    H.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_id() -> u64 {
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/* ======================== qrc_full.h ======================== */

#[no_mangle]
pub unsafe extern "C" fn qrc_preg_alloc(n: usize) -> *mut PregBank {
    Box::into_raw(Box::new(PregBank::new(n)))
}

#[no_mangle]
pub unsafe extern "C" fn qrc_lreg_alloc(n: usize) -> *mut LregBank {
    Box::into_raw(Box::new(LregBank::new(n)))
}

#[no_mangle]
pub unsafe extern "C" fn qrc_qram_alloc(capacity_slots: u64, data_width_bits: u32) -> *mut Qram {
    Box::into_raw(Box::new(Qram::new(capacity_slots, data_width_bits)))
}

#[no_mangle]
pub unsafe extern "C" fn qrc_preg_free(p: *mut PregBank) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_lreg_free(p: *mut LregBank) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_qram_free(p: *mut Qram) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

macro_rules! preg_gate {
    ($name:ident, $meth:ident) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(q: *mut PregBank) {
            if q.is_null() {
                return;
            }
            let bank = &mut *q;
            if let Some(m) = bank.modes.first_mut() {
                *m = m.$meth();
            }
        }
    };
}

preg_gate!(P_H, h);
preg_gate!(P_X, x);
preg_gate!(P_Z, z);
preg_gate!(P_S, s);
preg_gate!(P_T, t);

#[no_mangle]
pub unsafe extern "C" fn P_RZ(q: *mut PregBank, phi: f64) {
    if q.is_null() {
        return;
    }
    let bank = &mut *q;
    if let Some(m) = bank.modes.first_mut() {
        *m = m.rz(phi);
    }
}

#[no_mangle]
pub unsafe extern "C" fn P_CNOT(_c: *mut PregBank, t: *mut PregBank) {
    P_X(t);
}

#[no_mangle]
pub unsafe extern "C" fn P_CZ(c: *mut PregBank, t: *mut PregBank) {
    if c.is_null() || t.is_null() {
        return;
    }
    let ctrl = &*c;
    if ctrl.modes.first().map(|m| m.measure()) == Some(1) {
        P_Z(t);
    }
}

#[no_mangle]
pub unsafe extern "C" fn P_Toffoli(_c1: *mut PregBank, _c2: *mut PregBank, t: *mut PregBank) {
    P_X(t);
}

#[no_mangle]
pub unsafe extern "C" fn P_Measure(q: *mut PregBank, out: *mut c_int) {
    if q.is_null() || out.is_null() {
        return;
    }
    let bank = &*q;
    *out = bank.modes.first().map(|m| m.measure()).unwrap_or(0);
}

#[no_mangle]
pub unsafe extern "C" fn L_H(q: *mut LregBank) {
    if q.is_null() {
        return;
    }
    let b = &mut *q;
    let n = b.amps.len() as f32;
    if n > 0.0 {
        let v = 1.0 / n.sqrt();
        for a in b.amps.iter_mut() {
            *a = v;
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn L_X(q: *mut LregBank) {
    if q.is_null() {
        return;
    }
    let b = &mut *q;
    b.amps.reverse();
}

#[no_mangle]
pub unsafe extern "C" fn L_Z(q: *mut LregBank) {
    if q.is_null() {
        return;
    }
    let b = &mut *q;
    if let Some(a) = b.amps.last_mut() {
        *a = -*a;
    }
}

#[no_mangle]
pub unsafe extern "C" fn L_S(_q: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn L_T(_q: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn L_RZ(_q: *mut LregBank, _phi: f64) {}
#[no_mangle]
pub unsafe extern "C" fn L_CNOT(_c: *mut LregBank, _t: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn L_CZ(_c: *mut LregBank, _t: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn L_Toffoli(_c1: *mut LregBank, _c2: *mut LregBank, _t: *mut LregBank) {}

#[no_mangle]
pub unsafe extern "C" fn L_Measure(q: *mut LregBank, out: *mut c_int) {
    if q.is_null() || out.is_null() {
        return;
    }
    let b = &*q;
    let mut best = 0;
    let mut best_a = f32::MIN;
    for (i, a) in b.amps.iter().enumerate() {
        if *a > best_a {
            best_a = *a;
            best = i;
        }
    }
    *out = best as c_int;
}

#[no_mangle]
pub unsafe extern "C" fn L_H_all(q: *mut LregBank, _n: usize) {
    L_H(q);
}

#[no_mangle]
pub unsafe extern "C" fn L_X_all(q: *mut LregBank, _n: usize) {
    L_X(q);
}

#[no_mangle]
pub unsafe extern "C" fn L_Measure_all(q: *mut LregBank, n: usize, out_array: *mut c_int) {
    if q.is_null() || out_array.is_null() {
        return;
    }
    let b = &*q;
    for i in 0..n.min(b.amps.len()) {
        *out_array.add(i) = if b.amps[i] > 0.0 { 1 } else { 0 };
    }
}

#[no_mangle]
pub unsafe extern "C" fn QRAM_LoadAddress(_ram: *mut Qram, _addr: u64, _index: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_Store(_ram: *mut Qram, _data: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_Load(_ram: *mut Qram, _data: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_LoadSuperposition(_ram: *mut Qram, _index: *mut LregBank, _data: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_StoreSuperposition(_ram: *mut Qram, _index: *mut LregBank, _data: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_LoadClassical(_ram: *mut Qram, _addr: u64, _target: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn QRAM_StoreClassical(_ram: *mut Qram, _addr: u64, _source: *mut LregBank) {}

#[no_mangle]
pub unsafe extern "C" fn QRAM_StoreClassicalPacked(
    ram: *mut Qram,
    addr: u64,
    blob: *const u8,
    n: usize,
) {
    if ram.is_null() || blob.is_null() || n < std::mem::size_of::<Keyframe>() {
        return;
    }
    let kf = std::ptr::read_unaligned(blob as *const Keyframe);
    let _ = (*ram).store(addr, kf);
}

#[no_mangle]
pub unsafe extern "C" fn encode_vector_classical(vec: *const f32, dim: usize, q: *mut LregBank) {
    if vec.is_null() || q.is_null() {
        return;
    }
    let b = &mut *q;
    let n = dim.min(b.amps.len());
    let sl = std::slice::from_raw_parts(vec, n);
    let norm = sl.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
    for i in 0..n {
        b.amps[i] = sl[i] / norm;
    }
}

#[no_mangle]
pub unsafe extern "C" fn kernel_swap_test(_a: *mut LregBank, _b: *mut LregBank, anc: *mut LregBank) {
    if anc.is_null() {
        return;
    }
    if let Some(x) = (*anc).amps.first_mut() {
        *x = 0.5;
    }
}

#[no_mangle]
pub unsafe extern "C" fn L_HHL_solve(_b: *mut LregBank, _m: *mut Qram, _x: *mut LregBank) {}
#[no_mangle]
pub unsafe extern "C" fn L_block_encode_oracle(_ram: *mut Qram, _sys: *mut LregBank) {}

#[no_mangle]
pub unsafe extern "C" fn amp_estimate(flagged: *mut LregBank, p_hat: *mut f64, _shots: u32) {
    if flagged.is_null() || p_hat.is_null() {
        return;
    }
    let b = &*flagged;
    let s: f32 = b.amps.iter().map(|a| a * a).sum();
    *p_hat = s as f64;
}

#[no_mangle]
pub unsafe extern "C" fn amp_estimate_to_dram(
    flagged: *mut LregBank,
    dram_buffer: *mut f64,
    n: usize,
    _shots: u32,
) {
    if flagged.is_null() || dram_buffer.is_null() {
        return;
    }
    let b = &*flagged;
    for i in 0..n.min(b.amps.len()) {
        *dram_buffer.add(i) = b.amps[i] as f64;
    }
}

/* ======================== qrc_env.h ======================== */

#[no_mangle]
pub extern "C" fn qrc_env_create(capacity_slots: u64) -> u64 {
    let id = next_id();
    worlds()
        .lock()
        .unwrap()
        .insert(id, EnvWorld::new(capacity_slots));
    id
}

#[no_mangle]
pub extern "C" fn qrc_env_destroy(env: u64) {
    worlds().lock().unwrap().remove(&env);
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_load_keyframe(
    env: u64,
    slot: u64,
    kf: *const Keyframe,
) -> c_int {
    if kf.is_null() {
        return -1;
    }
    match worlds().lock().unwrap().get_mut(&env) {
        Some(w) => {
            if w.load(slot, *kf) {
                0
            } else {
                -2
            }
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_load_batch(
    env: u64,
    base_slot: u64,
    kfs: *const Keyframe,
    n: usize,
) -> c_int {
    if kfs.is_null() {
        return -1;
    }
    let sl = std::slice::from_raw_parts(kfs, n);
    match worlds().lock().unwrap().get_mut(&env) {
        Some(w) => {
            for (i, kf) in sl.iter().enumerate() {
                let _ = w.load(base_slot + i as u64, *kf);
            }
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn qrc_env_len(env: u64) -> u64 {
    worlds()
        .lock()
        .unwrap()
        .get(&env)
        .map(|w| w.len())
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_query(
    env: u64,
    query: *const Pose,
    out_hits: *mut Hit,
    max_hits: usize,
    n_hits: *mut usize,
    _shots: u32,
) -> c_int {
    if query.is_null() || out_hits.is_null() || n_hits.is_null() {
        return -1;
    }
    let guard = worlds().lock().unwrap();
    let Some(w) = guard.get(&env) else {
        return -1;
    };
    let hits = w.query(&*query, max_hits);
    *n_hits = hits.len();
    for (i, h) in hits.iter().enumerate() {
        *out_hits.add(i) = *h;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_plan_hint(
    env: u64,
    here: *const Pose,
    out: *mut PlanHint,
) -> c_int {
    if here.is_null() || out.is_null() {
        return -1;
    }
    let guard = worlds().lock().unwrap();
    let Some(w) = guard.get(&env) else {
        return -1;
    };
    *out = w.plan_hint(&*here);
    0
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_remember_failure(
    env: u64,
    where_: *const Pose,
    severity: f32,
) -> c_int {
    if where_.is_null() {
        return -1;
    }
    match worlds().lock().unwrap().get_mut(&env) {
        Some(w) => {
            w.remember_failure(&*where_, severity);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_env_remember_success(
    env: u64,
    where_: *const Pose,
    quality: f32,
) -> c_int {
    if where_.is_null() {
        return -1;
    }
    match worlds().lock().unwrap().get_mut(&env) {
        Some(w) => {
            w.remember_success(&*where_, quality);
            0
        }
        None => -1,
    }
}


/* ======================== qrc_humanoid.h ======================== */

#[repr(C)]
pub struct QrcHuCirculation {
    // Mirrors qrc_hu_circulation in qrc_humanoid.h, field-for-field.
    pub stator_pressure_kpa: f32,
    pub stator_temp_k: f32,
    pub stator_flow_lpm: f32,
    pub rotor_pressure_kpa: f32,
    pub rotor_temp_k: f32,
    pub rotor_flow_lpm: f32,
    pub purge_cycles: u32,
}

#[no_mangle]
pub extern "C" fn qrc_hu_create() -> u64 {
    let id = next_id();
    humanoids()
        .lock()
        .unwrap()
        .insert(id, standing_humanoid());
    id
}

#[no_mangle]
pub extern "C" fn qrc_hu_destroy(h: u64) {
    humanoids().lock().unwrap().remove(&h);
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_look_at(h: u64, world_point: *const Vec3) -> c_int {
    if world_point.is_null() {
        return -1;
    }
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            hu.look_at(*world_point);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_head_pose(h: u64, out: *mut Pose) -> c_int {
    if out.is_null() {
        return -1;
    }
    let guard = humanoids().lock().unwrap();
    let Some(hu) = guard.get(&h) else {
        return -1;
    };
    *out = hu.pose;
    0
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_sensor_frame(
    h: u64,
    out: *mut f32,
    max: usize,
    n_written: *mut usize,
) -> c_int {
    if out.is_null() || n_written.is_null() {
        return -1;
    }
    let mut guard = humanoids().lock().unwrap();
    let Some(hu) = guard.get_mut(&h) else {
        return -1;
    };
    let frame = hu.sensor_frame();
    let n = frame.len().min(max);
    for (i, v) in frame.iter().take(n).enumerate() {
        *out.add(i) = *v;
    }
    *n_written = n;
    0
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_motor_frame(
    h: u64,
    out: *mut f32,
    max: usize,
    n_written: *mut usize,
) -> c_int {
    if out.is_null() || n_written.is_null() {
        return -1;
    }
    let guard = humanoids().lock().unwrap();
    let Some(hu) = guard.get(&h) else {
        return -1;
    };
    let frame = hu.motor_frame();
    let n = frame.len().min(max);
    for (i, v) in frame.iter().take(n).enumerate() {
        *out.add(i) = *v;
    }
    *n_written = n;
    0
}

#[no_mangle]
pub extern "C" fn qrc_hu_sensor_dimension(h: u64) -> usize {
    humanoids()
        .lock()
        .unwrap()
        .get(&h)
        .map(|hu| hu.captors.n_cells())
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn qrc_hu_motor_dimension(h: u64) -> usize {
    humanoids()
        .lock()
        .unwrap()
        .get(&h)
        .map(|hu| hu.motors.flatten().len())
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_set_thermo(
    h: u64,
    part: u16,
    idx: u8,
    kelvin: f32,
) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            hu.captors.set_temperature(crate::anatomy::PartId(part), idx, kelvin);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_set_touch(
    h: u64,
    part: u16,
    idx: u8,
    pressure: f32,
    proximity: f32,
    shear: f32,
) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            hu.captors.set_touch(crate::anatomy::PartId(part), idx, pressure, proximity, shear);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_articulate(
    h: u64,
    joint_id: u16,
    target_rad: f32,
    effort: f32,
) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            let mut purpose = [0u8; 48];
            let text = b"ffi-articulate";
            purpose[..text.len()].copy_from_slice(text);
            if hu.articulate(Articulation {
                joint: crate::anatomy::JointId(joint_id),
                target: target_rad,
                effort,
                purpose,
            }) {
                0
            } else {
                -2
            }
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn qrc_hu_zipper_open(h: u64) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            hu.zipper.open(&mut hu.circulation);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn qrc_hu_zipper_replace_cord(h: u64, cord_idx: u8) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            if hu.zipper.replace_cord(cord_idx as usize, &mut hu.circulation) {
                0
            } else {
                -2
            }
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn qrc_hu_zipper_sealed(h: u64) -> c_int {
    humanoids()
        .lock()
        .unwrap()
        .get(&h)
        .map(|hu| if hu.zipper.sealed() { 1 } else { 0 })
        .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn qrc_hu_get_circulation(h: u64, out: *mut QrcHuCirculation) -> c_int {
    if out.is_null() {
        return -1;
    }
    let guard = humanoids().lock().unwrap();
    let Some(hu) = guard.get(&h) else {
        return -1;
    };
    *out = QrcHuCirculation {
        stator_pressure_kpa: hu.circulation.stator.pressure_kpa,
        stator_temp_k: hu.circulation.stator.temperature_k,
        stator_flow_lpm: hu.circulation.stator.flow_rate_lpm,
        rotor_pressure_kpa: hu.circulation.rotor.pressure_kpa,
        rotor_temp_k: hu.circulation.rotor.temperature_k,
        rotor_flow_lpm: hu.circulation.rotor.flow_rate_lpm,
        purge_cycles: hu.circulation.purge_cycles,
    };
    0
}

#[no_mangle]
pub extern "C" fn qrc_hu_bind_env(h: u64, env: u64) -> c_int {
    match humanoids().lock().unwrap().get_mut(&h) {
        Some(hu) => {
            hu.bind_env_id(env);
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn qrc_hu_tick(h: u64, dt_s: f32) -> c_int {
    let env_id = {
        let guard = humanoids().lock().unwrap();
        guard.get(&h).map(|hu| hu.env_id).unwrap_or(0)
    };
    if env_id == 0 {
        let mut guard = humanoids().lock().unwrap();
        match guard.get_mut(&h) {
            Some(hu) => {
                hu.tick(dt_s, None);
                0
            }
            None => -1,
        }
    } else {
        // Hold the env guard for the duration of the tick so the world ref is valid.
        let guard = worlds().lock().unwrap();
        let world = guard.get(&env_id);
        let mut hguard = humanoids().lock().unwrap();
        match hguard.get_mut(&h) {
            Some(hu) => {
                hu.tick(dt_s, world);
                0
            }
            None => -1,
        }
    }
}
