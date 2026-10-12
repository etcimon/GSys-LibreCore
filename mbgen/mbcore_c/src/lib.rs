//! C ABI for a live mbgen session. JSON in and out. `panic = abort` on this crate.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

use mbcore::{anchors, library_export, preview, route, scene, Design, Gesture, NetClass, RouteResult};

#[allow(non_camel_case_types)]
pub struct mb_session {
    design: Design,
    last_part: Option<String>,
}

type Session = mb_session;

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
        | Gesture::AutoConnect { id } => Some(id.clone()),
        Gesture::Add { .. } | Gesture::SetOutline { .. } | Gesture::Unknown => None,
    }
}

fn new_port_id(before: &Design, after: &Design) -> Option<String> {
    after
        .ports
        .iter()
        .find(|p| before.ports.iter().all(|q| q.id != p.id))
        .map(|p| p.id.clone())
}

fn dirty_route(full: RouteResult, part: Option<&str>) -> RouteResult {
    let Some(part) = part else {
        return full;
    };
    let prefix = format!("{part}.");
    let nets: Vec<_> = full
        .nets
        .iter()
        .filter(|n| {
            matches!(n.class, NetClass::Power | NetClass::Ground)
                || n.pins.iter().any(|p| p == part || p.starts_with(&prefix))
        })
        .cloned()
        .collect();
    let keep: Vec<String> = nets.iter().map(|n| n.id.clone()).collect();
    let paths = full
        .paths
        .into_iter()
        .filter(|p| keep.iter().any(|id| id == &p.net))
        .collect();
    let errors = full
        .errors
        .into_iter()
        .filter(|e| e.net.as_ref().map(|id| keep.iter().any(|k| k == id)).unwrap_or(true))
        .collect();
    RouteResult { nets, paths, errors }
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
    }))
}

#[no_mangle]
pub unsafe extern "C" fn mb_session_close(session: *mut Session) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
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
        sess.design = result.design.clone();
    }
    json_ptr(&result)
}

#[no_mangle]
pub unsafe extern "C" fn mb_route(session: *mut Session, dirty_only: c_int) -> *mut c_char {
    if session.is_null() {
        return err_json("no session");
    }
    let sess = &*session;
    match route(&sess.design) {
        Ok(full) => {
            let out = if dirty_only != 0 {
                dirty_route(full, sess.last_part.as_deref())
            } else {
                full
            };
            json_ptr(&out)
        }
        Err(err) => err_json(&err.reason),
    }
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
    fn route_returns_rails_with_empty_paths() {
        unsafe {
            let sess = open_mini();
            let full = take(mb_route(sess, 0));
            assert!(full.get("error").is_none());
            let nets = full["nets"].as_array().unwrap();
            assert!(nets.iter().any(|n| n["id"] == "P12V"));
            assert!(full["paths"].as_array().unwrap().is_empty());
            let g = cstring(r#"{"op":"nudge","id":"usb0","delta_um":1000}"#);
            let _ = take(mb_apply(sess, g.as_ptr()));
            let dirty = take(mb_route(sess, 1));
            assert!(dirty["nets"].as_array().unwrap().iter().any(|n| n["id"] == "GND"));
            mb_session_close(sess);
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
