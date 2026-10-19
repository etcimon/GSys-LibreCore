//! C ABI for a live mbgen session. JSON in and out. `panic = abort` on this crate.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint, c_ulonglong};
use std::ptr;

use mbcore::{
    anchors, library_export, look_in_place, orbit_around, pick_nav_pivot, preview, resolve, route, route_incremental,
    scene, zoom_distance, zoom_toward, Design, Desk, Gesture, NavVec3, PreviewResult, RouteResult,
};
use serde::Serialize;

/// Bump the major when a message shape or function signature changes.
/// Mirrored by `MBCORE_C_ABI_VERSION` in `include/mbcore_c.h`.
pub const ABI_VERSION: c_uint = 3;

#[allow(non_camel_case_types)]
pub struct mb_session {
    design: Design,
    last_part: Option<String>,
    /// Bumps once per applied gesture. Zero for a freshly opened session.
    revision: u64,
    /// Parts touched since the last route; drives incremental invalidation.
    dirty_parts: BTreeSet<String>,
    /// Last full or incremental route, so dirty routing can keep clean paths.
    last_route: Option<RouteResult>,
}

type Session = mb_session;

/// `PreviewResult` plus the revision the session is at after this call.
#[derive(Serialize)]
struct ApplyResult {
    #[serde(flatten)]
    preview: PreviewResult,
    revision: u64,
}

/// `RouteResult` plus the revision it was computed against and whether it is
/// a filtered (dirty) view, so a host cannot mistake a subset for the whole.
#[derive(Serialize)]
struct RouteMessage {
    #[serde(flatten)]
    route: RouteResult,
    revision: u64,
    dirty_only: bool,
}

fn err_json(msg: &str) -> *mut c_char {
    to_cstr(&format!("{{\"error\":{}}}", serde_json::to_string(msg).unwrap_or_else(|_| "\"error\"".into())))
}

fn to_cstr(s: &str) -> *mut c_char {
    let cleaned: String = s.chars().filter(|c| *c != '\0').collect();
    CString::new(cleaned)
        .unwrap_or_else(|_| CString::new("{\"error\":\"nul\"}").expect("static"))
        .into_raw()
}

fn json_ptr<T: serde::Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(s) => to_cstr(&s),
        Err(_) => err_json("serialize"),
    }
}

unsafe fn read_str<'a>(p: *const c_char) -> Result<&'a str, &'static str> {
    if p.is_null() {
        return Err("null");
    }
    CStr::from_ptr(p).to_str().map_err(|_| "utf8")
}

fn gesture_id(g: &Gesture) -> Option<String> {
    match g {
        Gesture::Nudge { id, .. }
        | Gesture::Drag { id, .. }
        | Gesture::Copy { id }
        | Gesture::Place { id, .. }
        | Gesture::Turn { id }
        | Gesture::Delete { id }
        | Gesture::SetProperty { id, .. }
        | Gesture::SetPart { id, .. }
        | Gesture::Flip { id }
        | Gesture::AutoConnect { id } => Some(id.clone()),
        Gesture::ExpandRecipe { host, .. } => Some(host.clone()),
        Gesture::Connect { pins, .. } => pins.first().and_then(|p| p.rsplit_once('.')).map(|(part, _)| part.to_string()),
        Gesture::Disconnect { pin } | Gesture::NoConnect { pin } => pin.rsplit_once('.').map(|(part, _)| part.to_string()),
        Gesture::Add { .. } | Gesture::SetOutline { .. } | Gesture::RemoveRecipe { .. } | Gesture::Unknown => None,
    }
}

/// Every part whose geometry or membership can differ between two designs.
fn changed_parts(before: &Design, after: &Design) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for p in &after.placements {
        match before.placements.iter().find(|q| q.id == p.id) {
            None => {
                out.insert(p.id.clone());
            }
            Some(q) if q != p => {
                out.insert(p.id.clone());
            }
            _ => {}
        }
    }
    for q in &before.placements {
        if !after.placements.iter().any(|p| p.id == q.id) {
            out.insert(q.id.clone());
        }
    }
    // Connection edits change membership without moving anything.
    if before.connections != after.connections || before.no_connects != after.no_connects {
        for c in after.connections.iter().chain(before.connections.iter()) {
            for pin in &c.pins {
                if let Some((part, _)) = pin.rsplit_once('.') {
                    out.insert(part.to_string());
                }
            }
        }
    }
    out
}

fn new_port_id(before: &Design, after: &Design) -> Option<String> {
    after
        .ports
        .iter()
        .find(|p| before.ports.iter().all(|q| q.id != p.id))
        .map(|p| p.id.clone())
}

#[no_mangle]
pub unsafe extern "C" fn mb_session_open(design_json: *const c_char) -> *mut Session {
    let Ok(text) = read_str(design_json) else {
        return ptr::null_mut();
    };
    let Ok(design) = serde_json::from_str::<Design>(text) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(Session {
        design,
        last_part: None,
        revision: 0,
        dirty_parts: BTreeSet::new(),
        last_route: None,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn mb_session_close(session: *mut Session) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

#[no_mangle]
pub extern "C" fn mb_abi_version() -> c_uint {
    ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn mb_session_revision(session: *const Session) -> c_ulonglong {
    if session.is_null() {
        return 0;
    }
    (*session).revision
}

#[no_mangle]
pub unsafe extern "C" fn mb_apply(session: *mut Session, gesture_json: *const c_char) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let Ok(text) = read_str(gesture_json) else {
        return err_json("null gesture");
    };
    if text.len() > 256 * 1024 {
        return err_json("gesture too large");
    }
    let Ok(gesture) = serde_json::from_str::<Gesture>(text) else {
        return err_json("bad gesture");
    };
    let sess = &mut *session;
    let before = sess.design.clone();
    let result = preview(&sess.design, &gesture);
    if result.applied {
        sess.last_part = new_port_id(&before, &result.design).or_else(|| gesture_id(&gesture));
        sess.dirty_parts.extend(changed_parts(&before, &result.design));
        sess.design = result.design.clone();
        sess.revision += 1;
    }
    json_ptr(&ApplyResult {
        preview: result,
        revision: sess.revision,
    })
}

/// `dirty_only != 0`: keep the previous paths of nets untouched since the
/// last route and recompute only nets touching parts that moved, changed
/// membership, or whose routes a moved body now crosses. The result still
/// carries every net and every surviving path; `changed_nets` /
/// `removed_nets` say what differs. A full route resets the dirty set.
#[no_mangle]
pub unsafe extern "C" fn mb_route(session: *mut Session, dirty_only: c_int) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let sess = &mut *session;
    let computed = match (&sess.last_route, dirty_only != 0) {
        (Some(prev), true) => {
            let changed: Vec<String> = sess.dirty_parts.iter().cloned().collect();
            route_incremental(&sess.design, prev, &changed)
        }
        _ => route(&sess.design),
    };
    match computed {
        Ok(out) => {
            sess.dirty_parts.clear();
            sess.last_route = Some(out.clone());
            json_ptr(&RouteMessage {
                route: out,
                revision: sess.revision,
                dirty_only: dirty_only != 0,
            })
        }
        Err(err) => err_json(&err.reason),
    }
}

/// What `set_outline` to `template_id` would do: kept / re-edged / dropped
/// (with reasons) / added stock / dropped blocks / affected nets. Nothing is
/// applied. Hosts show this before offering the change.
#[no_mangle]
pub unsafe extern "C" fn mb_outline_proposal(session: *const Session, template_id: *const c_char) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let Ok(id) = read_str(template_id) else {
        return err_json("null template id");
    };
    let sess = &*session;
    match mbcore::propose_outline(&sess.design, id) {
        Ok(p) => {
            #[derive(Serialize)]
            struct Msg {
                #[serde(flatten)]
                proposal: mbcore::OutlineProposal,
                revision: u64,
            }
            json_ptr(&Msg { proposal: p, revision: sess.revision })
        }
        Err(err) => err_json(&err.reason),
    }
}

/// The resolved circuit (components, pins, nets, obligations, diagnostics)
/// for the current design, with the session revision.
#[no_mangle]
pub unsafe extern "C" fn mb_circuit(session: *const Session) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let sess = &*session;
    match resolve(&sess.design) {
        Ok(circuit) => {
            #[derive(Serialize)]
            struct Msg {
                #[serde(flatten)]
                circuit: mbcore::Circuit,
                revision: u64,
                /// Same hash `mbgen compile` writes as `manifest.circuit_sha256`, so a
                /// host can tell which ingested board's outputs belong to this circuit.
                circuit_sha256: String,
            }
            let circuit_sha256 = mbcore::circuit_sha256(&circuit);
            json_ptr(&Msg { circuit, revision: sess.revision, circuit_sha256 })
        }
        Err(err) => err_json(&err.reason),
    }
}

// ---- Navigation laws -------------------------------------------------------

unsafe fn vec3(p: *const f64) -> Option<NavVec3> {
    if p.is_null() {
        return None;
    }
    Some(NavVec3::new(*p, *p.add(1), *p.add(2)))
}

unsafe fn put3(out: *mut f64, v: NavVec3) {
    *out = v.x;
    *out.add(1) = v.y;
    *out.add(2) = v.z;
}

unsafe fn desk(p: *const f64) -> Option<Desk> {
    if p.is_null() {
        return None;
    }
    Some(Desk {
        cx: *p,
        cy: *p.add(1),
        z: *p.add(2),
        hx: *p.add(3),
        hy: *p.add(4),
    })
}

#[no_mangle]
pub unsafe extern "C" fn mb_nav_desk(board_w_cm: f64, board_d_cm: f64, z_cm: f64, out_desk5: *mut f64) -> c_int {
    if out_desk5.is_null() {
        return 1;
    }
    let d = mbcore::desk_from_board(board_w_cm, board_d_cm, z_cm);
    *out_desk5 = d.cx;
    *out_desk5.add(1) = d.cy;
    *out_desk5.add(2) = d.z;
    *out_desk5.add(3) = d.hx;
    *out_desk5.add(4) = d.hy;
    0
}

#[no_mangle]
pub unsafe extern "C" fn mb_nav_pick_pivot(
    desk5: *const f64,
    cam3: *const f64,
    dir3: *const f64,
    last_pivot3: *const f64,
    out_pivot3: *mut f64,
) -> c_int {
    let (Some(d), Some(cam), Some(dir), Some(last)) = (desk(desk5), vec3(cam3), vec3(dir3), vec3(last_pivot3)) else {
        return 1;
    };
    if out_pivot3.is_null() {
        return 1;
    }
    put3(out_pivot3, pick_nav_pivot(d, cam, dir, last));
    0
}

#[no_mangle]
pub unsafe extern "C" fn mb_nav_orbit(
    pivot3: *const f64,
    cam3: *const f64,
    yaw_deg: f64,
    pitch_deg: f64,
    out_cam3: *mut f64,
    out_forward3: *mut f64,
) -> c_int {
    let (Some(pivot), Some(cam)) = (vec3(pivot3), vec3(cam3)) else {
        return 1;
    };
    if out_cam3.is_null() || out_forward3.is_null() {
        return 1;
    }
    let next = orbit_around(pivot, cam, yaw_deg, pitch_deg);
    let forward = pivot.sub(next).norm();
    put3(out_cam3, next);
    put3(out_forward3, forward);
    0
}

#[no_mangle]
pub unsafe extern "C" fn mb_nav_look(forward3: *const f64, yaw_deg: f64, pitch_deg: f64, out_forward3: *mut f64) -> c_int {
    let Some(f) = vec3(forward3) else {
        return 1;
    };
    if out_forward3.is_null() {
        return 1;
    }
    put3(out_forward3, look_in_place(f, yaw_deg, pitch_deg));
    0
}

#[no_mangle]
pub unsafe extern "C" fn mb_nav_zoom_toward(
    cam3: *const f64,
    hit3: *const f64,
    notches: f64,
    sens: f64,
    out_cam3: *mut f64,
) -> c_int {
    let (Some(cam), Some(hit)) = (vec3(cam3), vec3(hit3)) else {
        return 1;
    };
    if out_cam3.is_null() {
        return 1;
    }
    put3(out_cam3, zoom_toward(cam, hit, notches, sens));
    0
}

#[no_mangle]
pub extern "C" fn mb_nav_zoom_distance(dist: f64, notches: f64, sens: f64) -> f64 {
    zoom_distance(dist, notches, sens)
}

#[no_mangle]
pub unsafe extern "C" fn mb_scene(session: *mut Session) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let sess = &*session;
    match scene(&sess.design) {
        Ok(bodies) => json_ptr(&bodies),
        Err(err) => err_json(&err.reason),
    }
}

#[no_mangle]
pub unsafe extern "C" fn mb_anchors(session: *mut Session) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let sess = &*session;
    json_ptr(&anchors(&sess.design))
}

#[no_mangle]
pub unsafe extern "C" fn mb_library_json() -> *mut c_char {
    match serde_json::to_string_pretty(&library_export()) {
        Ok(s) => to_cstr(&s),
        Err(_) => err_json("serialize"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn mb_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mbcore::Design;
    use serde_json::Value;
    use std::ffi::CString;

    fn cstring(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    fn take(p: *mut c_char) -> Value {
        assert!(!p.is_null());
        let text = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { mb_string_free(p) };
        serde_json::from_str(&text).unwrap()
    }

    unsafe fn open_mini() -> *mut Session {
        let design = serde_json::to_string(&Design::mini_itx().unwrap()).unwrap();
        let raw = cstring(&design);
        let sess = mb_session_open(raw.as_ptr());
        assert!(!sess.is_null());
        sess
    }

    #[test]
    fn session_scene_has_pcb_and_library_hatches_usb_c() {
        unsafe {
            let sess = open_mini();
            let bodies = take(mb_scene(sess));
            assert!(bodies.as_array().unwrap().iter().any(|b| b["id"] == "pcb"));
            mb_session_close(sess);
            let lib_ptr = mb_library_json();
            let lib_text = CStr::from_ptr(lib_ptr).to_string_lossy().into_owned();
            assert!(lib_text.contains('\n'), "library json is pretty");
            let lib = take(lib_ptr);
            assert!(lib.as_array().unwrap().iter().any(|r| r["id"] == "usb_c" && r["hatch"] == true));
            assert!(lib.as_array().unwrap().iter().any(|r| {
                r["id"] == "pcie_slot"
                    && r["contracts"]
                        .as_array()
                        .map(|c| c.iter().any(|n| n == "P12V"))
                        .unwrap_or(false)
            }));
        }
    }

    #[test]
    fn apply_nudge_packs_and_a_rejected_nudge_keeps_the_design() {
        unsafe {
            let sess = open_mini();
            let g = cstring(r#"{"op":"nudge","id":"usb0","delta_um":1000}"#);
            let ok = take(mb_apply(sess, g.as_ptr()));
            assert_eq!(ok["applied"], true);
            let usb = ok["design"]["placements"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"] == "usb0")
                .unwrap();
            assert_eq!(usb["pinned"], true);
            let bad = cstring(r#"{"op":"nudge","id":"hdmi0","delta_um":500000}"#);
            let reject = take(mb_apply(sess, bad.as_ptr()));
            assert_eq!(reject["applied"], false);
            assert!(reject["reason"].as_str().unwrap().contains("outside"));
            assert_eq!(reject["design"]["placements"], ok["design"]["placements"]);
            mb_session_close(sess);
        }
    }

    #[test]
    fn unknown_gesture_keeps_the_session() {
        unsafe {
            let sess = open_mini();
            let g = cstring(r#"{"op":"teleport"}"#);
            let result = take(mb_apply(sess, g.as_ptr()));
            assert_eq!(result["applied"], false);
            assert_eq!(result["reason"], "unknown gesture");
            mb_session_close(sess);
        }
    }

    #[test]
    fn anchors_json_has_edge_and_courtyard_for_usb0() {
        unsafe {
            let sess = open_mini();
            let marks = take(mb_anchors(sess));
            let usb: Vec<_> = marks
                .as_array()
                .unwrap()
                .iter()
                .filter(|a| a["part"] == "usb0")
                .collect();
            assert!(usb.iter().any(|a| a["kind"] == "EdgeS"));
            assert_eq!(
                usb.iter().filter(|a| a["kind"] == "Courtyard").count(),
                4
            );
            assert!(usb.iter().all(|a| a["kind"] != "PinPad"));
            mb_session_close(sess);
        }
    }

    #[test]
    fn route_returns_rails_with_empty_paths_and_dirty_routing_keeps_every_net() {
        unsafe {
            let sess = open_mini();
            let full = take(mb_route(sess, 0));
            assert!(full.get("error").is_none());
            let nets = full["nets"].as_array().unwrap();
            assert!(nets.iter().any(|n| n["id"] == "P12V"));
            assert!(full["paths"].as_array().unwrap().is_empty());
            assert_eq!(full["dirty_only"], false);
            assert_eq!(full["grid_um"], 250);
            let g = cstring(r#"{"op":"nudge","id":"usb0","delta_um":1000}"#);
            let _ = take(mb_apply(sess, g.as_ptr()));
            let dirty = take(mb_route(sess, 1));
            assert_eq!(dirty["dirty_only"], true);
            // A dirty result is never a subset of the nets: every net is present.
            assert_eq!(dirty["nets"].as_array().unwrap().len(), nets.len());
            assert!(dirty["nets"].as_array().unwrap().iter().any(|n| n["id"] == "GND"));
            assert!(dirty["removed_nets"].as_array().unwrap().is_empty());
            mb_session_close(sess);
        }
    }

    #[test]
    fn circuit_json_carries_refdes_nets_and_diagnostics_with_the_revision() {
        unsafe {
            let sess = open_mini();
            let c = take(mb_circuit(sess));
            assert!(c.get("error").is_none());
            assert_eq!(c["revision"], 0);
            assert_eq!(c["circuit_sha256"].as_str().unwrap().len(), 64);
            let bundle = mbcore::compile(&Design::mini_itx().unwrap()).unwrap();
            assert_eq!(c["circuit_sha256"], bundle.manifest()["source_circuit_sha256"], "mb_circuit and the manifest agree on the editable circuit's identity");
            assert!(c["components"].as_array().unwrap().iter().all(|k| !k["refdes"].as_str().unwrap().is_empty()));
            assert!(c["nets"].as_array().unwrap().iter().any(|n| n["id"] == "P12V" && n["origins"][0] == "contract"));
            assert!(c["diagnostics"].as_array().unwrap().iter().any(|d| d["rule"] == "W-NET-NO-SOURCE"));
            let g = cstring(r#"{"op":"expand_recipe","recipe":"decap_per_rail","host":"slot0","params":{"per_rail":"1"}}"#);
            let applied = take(mb_apply(sess, g.as_ptr()));
            assert_eq!(applied["applied"], true, "{applied}");
            let c2 = take(mb_circuit(sess));
            assert_eq!(c2["revision"], 1);
            assert!(c2["components"].as_array().unwrap().iter().any(|k| k["id"] == "slot0_c_p12v_0" && k["owner_block"] == "slot0.decap_per_rail"));
            assert!(c2["nets"].as_array().unwrap().iter().any(|n| n["id"] == "P12V" && n["pins"].as_array().unwrap().iter().any(|p| p == "slot0_c_p12v_0.1")));
            mb_session_close(sess);
            assert_eq!(take(mb_circuit(ptr::null()))["error"], "no session");
        }
    }

    #[test]
    fn outline_proposal_is_read_only_and_names_drops() {
        unsafe {
            let sess = open_mini();
            let rev_before = mb_session_revision(sess);
            let id = cstring("pcie-card");
            let p = take(mb_outline_proposal(sess, id.as_ptr()));
            assert!(p.get("error").is_none(), "{p}");
            assert_eq!(p["from"], "mini-itx");
            assert_eq!(p["to"], "pcie-card");
            assert!(p["dropped"].as_array().unwrap().iter().any(|d| d["id"] == "socket" && d["reason"].as_str().unwrap().contains("edge")));
            assert!(p["added_stock"].as_array().unwrap().iter().any(|s| s == "cem0"));
            assert_eq!(mb_session_revision(sess), rev_before, "a proposal mutates nothing");
            let bad = cstring("nope");
            assert!(take(mb_outline_proposal(sess, bad.as_ptr())).get("error").is_some());
            mb_session_close(sess);
        }
    }

    #[test]
    fn revision_bumps_only_on_applied_gestures_and_rides_every_result() {
        unsafe {
            let sess = open_mini();
            assert_eq!(mb_abi_version(), ABI_VERSION);
            assert_eq!(mb_session_revision(sess), 0);
            let bad = cstring(r#"{"op":"teleport"}"#);
            let rejected = take(mb_apply(sess, bad.as_ptr()));
            assert_eq!(rejected["applied"], false);
            assert_eq!(rejected["revision"], 0);
            assert_eq!(mb_session_revision(sess), 0);
            let g = cstring(r#"{"op":"nudge","id":"usb0","delta_um":1000}"#);
            let ok = take(mb_apply(sess, g.as_ptr()));
            assert_eq!(ok["applied"], true);
            assert_eq!(ok["revision"], 1);
            assert_eq!(mb_session_revision(sess), 1);
            let full = take(mb_route(sess, 0));
            assert_eq!(full["revision"], 1);
            assert_eq!(full["dirty_only"], false);
            let dirty = take(mb_route(sess, 1));
            assert_eq!(dirty["dirty_only"], true);
            mb_session_close(sess);
            assert_eq!(mb_session_revision(ptr::null()), 0);
        }
    }

    #[test]
    fn nav_abi_matches_the_rust_laws_and_rejects_null() {
        unsafe {
            let mut desk5 = [0.0f64; 5];
            assert_eq!(mb_nav_desk(340.0, 340.0, 0.0, desk5.as_mut_ptr()), 0);
            assert_eq!(desk5, [170.0, 170.0, 0.0, 255.0, 255.0]);
            let cam = [392.6, 1.0, 185.2];
            let last = [170.0, 170.0, 1.6];
            let v = NavVec3::new(-700.0, 900.0, -20.0).norm();
            let dir = [v.x, v.y, v.z];
            let mut pivot = [0.0f64; 3];
            assert_eq!(mb_nav_pick_pivot(desk5.as_ptr(), cam.as_ptr(), dir.as_ptr(), last.as_ptr(), pivot.as_mut_ptr()), 0);
            assert!((pivot[0] - (-85.0)).abs() > 1.0 || (pivot[1] - 425.0).abs() > 1.0, "rim corner leaked through the ABI");
            let expect = pick_nav_pivot(mbcore::desk_from_board(340.0, 340.0, 0.0), NavVec3::new(392.6, 1.0, 185.2), v, NavVec3::new(170.0, 170.0, 1.6));
            assert!((pivot[0] - expect.x).abs() < 1e-9 && (pivot[1] - expect.y).abs() < 1e-9 && (pivot[2] - expect.z).abs() < 1e-9);
            let mut out_cam = [0.0f64; 3];
            let mut out_fwd = [0.0f64; 3];
            assert_eq!(mb_nav_orbit(last.as_ptr(), cam.as_ptr(), 25.0, -10.0, out_cam.as_mut_ptr(), out_fwd.as_mut_ptr()), 0);
            let d0 = NavVec3::new(392.6, 1.0, 185.2).sub(NavVec3::new(170.0, 170.0, 1.6)).length();
            let d1 = NavVec3::new(out_cam[0], out_cam[1], out_cam[2]).sub(NavVec3::new(170.0, 170.0, 1.6)).length();
            assert!((d0 - d1).abs() < 1e-6);
            let mut zoomed = [0.0f64; 3];
            assert_eq!(mb_nav_zoom_toward(cam.as_ptr(), last.as_ptr(), 1.0, 0.25, zoomed.as_mut_ptr()), 0);
            let dz = NavVec3::new(zoomed[0], zoomed[1], zoomed[2]).sub(NavVec3::new(170.0, 170.0, 1.6)).length();
            assert!((dz - mb_nav_zoom_distance(d0, 1.0, 0.25)).abs() < 1e-6);
            let mut fwd = [0.0f64; 3];
            assert_eq!(mb_nav_look([0.0, 1.0, 0.0].as_ptr(), 90.0, 0.0, fwd.as_mut_ptr()), 0);
            assert!(fwd[2].abs() < 1e-9);
            assert_eq!(mb_nav_pick_pivot(ptr::null(), cam.as_ptr(), dir.as_ptr(), last.as_ptr(), pivot.as_mut_ptr()), 1);
            assert_eq!(mb_nav_orbit(last.as_ptr(), cam.as_ptr(), 0.0, 0.0, ptr::null_mut(), out_fwd.as_mut_ptr()), 1);
        }
    }

    #[test]
    fn oversized_gesture_is_rejected() {
        unsafe {
            let sess = open_mini();
            let huge = format!("{{\"op\":\"nudge\",\"id\":\"{}\",\"delta_um\":1}}", "x".repeat(256 * 1024));
            let raw = cstring(&huge);
            let v = take(mb_apply(sess, raw.as_ptr()));
            assert_eq!(v["error"], "gesture too large");
            mb_session_close(sess);
        }
    }

    #[test]
    fn null_session_returns_error_json() {
        unsafe {
            let g = cstring("{}");
            let v = take(mb_apply(ptr::null_mut(), g.as_ptr()));
            assert_eq!(v["error"], "no session");
            mb_string_free(ptr::null_mut());
            mb_session_close(ptr::null_mut());
        }
    }
}
