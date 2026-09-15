// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RFB / browser-KVM / local pointer normalize.
//!
//! P3 leftover after SYN_REPORT: remote KVM clients speak framebuffer
//! pixels (RFB PointerEvent, first-party KVM record), while the guest
//! tablet lane is virtio-input `ABS`/`REL`/`BTN` in `0..=VIO_ABS_MAX`.
//! This module is the adapter — scaling/clipping, one owner at a time,
//! and move coalescing that still emits every button/wheel edge.
//!
//! Not RFB 3.8 session/auth (P8), not a QEMU `-vnc` frontend.

use crate::encode::{
    VIO_INP_EV_ABS, VIO_INP_EV_KEY, VIO_INP_EV_REL, VIO_INP_EV_SYN, VIO_SYN_REPORT,
};
use crate::vio::{
    VIO_ABS_MAX, VIO_ABS_X, VIO_ABS_Y, VIO_BTN_LEFT, VIO_BTN_MIDDLE, VIO_BTN_RIGHT, VIO_REL_WHEEL,
};

/// RFB 3.8 `PointerEvent` message-type.
pub const RFB_POINTER: u8 = 5;
/// RFB button-mask bit 0 — left.
pub const RFB_BTN_LEFT: u8 = 1;
/// RFB button-mask bit 1 — middle.
pub const RFB_BTN_MIDDLE: u8 = 1 << 1;
/// RFB button-mask bit 2 — right.
pub const RFB_BTN_RIGHT: u8 = 1 << 2;
/// Buttons that hold pointer ownership.
pub const RFB_HELD: u8 = RFB_BTN_LEFT | RFB_BTN_MIDDLE | RFB_BTN_RIGHT;
/// RFB button 4 — wheel up (Tight/RealVNC convention, rising edge).
pub const RFB_BTN_WHEEL_UP: u8 = 1 << 3;
/// RFB button 5 — wheel down.
pub const RFB_BTN_WHEEL_DOWN: u8 = 1 << 4;

/// Who currently owns the pointer. A source with left held rejects the others.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PtrSource {
    Local,
    Rfb,
    BrowserKvm,
}

/// Display-pixel sample from one source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PtrSample {
    pub source: PtrSource,
    pub x_px: i32,
    pub y_px: i32,
    /// Bit 0 left; bits 3/4 RFB wheel buttons.
    pub buttons: u8,
    /// Explicit wheel delta (browser KVM). Combined with RFB wheel bits.
    pub wheel: i32,
}

/// First-party browser-KVM pointer record (not RFB, not WebSocket).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KvmPointer {
    pub x: i32,
    pub y: i32,
    pub buttons: u8,
    pub wheel: i32,
}

impl KvmPointer {
    /// Display-pixel sample tagged [`PtrSource::BrowserKvm`].
    pub fn sample(self) -> PtrSample {
        PtrSample {
            source: PtrSource::BrowserKvm,
            x_px: self.x,
            y_px: self.y,
            buttons: self.buttons,
            wheel: self.wheel,
        }
    }
}

/// One virtio-input event the guest `TabDrain` already understands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PtrEv {
    pub ty: u16,
    pub code: u16,
    pub value: u32,
}

/// Stateful normalizer: display px → tablet ABS + BTN/WHEEL + SYN_REPORT.
pub struct PtrNorm {
    disp_w: u32,
    disp_h: u32,
    owner: Option<PtrSource>,
    held: u8,
    last_x: u32,
    last_y: u32,
    have_pos: bool,
    pending_abs: bool,
    out: Vec<PtrEv>,
}

impl PtrNorm {
    pub fn new(disp_w: u32, disp_h: u32) -> Self {
        Self {
            disp_w: disp_w.max(1),
            disp_h: disp_h.max(1),
            owner: None,
            held: 0,
            last_x: 0,
            last_y: 0,
            have_pos: false,
            pending_abs: false,
            out: Vec::new(),
        }
    }

    /// Accept `sample` or reject it when another source holds the left button.
    /// Returns `false` when ownership refused (no events queued).
    pub fn push(&mut self, sample: PtrSample) -> bool {
        if let Some(owner) = self.owner {
            if owner != sample.source {
                if self.held & RFB_HELD != 0 {
                    return false;
                }
                self.owner = Some(sample.source);
                self.held = 0;
            }
        } else {
            self.owner = Some(sample.source);
        }
        let ax = px_to_abs(sample.x_px, self.disp_w);
        let ay = px_to_abs(sample.y_px, self.disp_h);
        if !self.have_pos || ax != self.last_x || ay != self.last_y {
            self.last_x = ax;
            self.last_y = ay;
            self.have_pos = true;
            self.pending_abs = true;
        }
        let mut wheel = sample.wheel;
        if sample.buttons & RFB_BTN_WHEEL_UP != 0 && self.held & RFB_BTN_WHEEL_UP == 0 {
            wheel += 1;
        }
        if sample.buttons & RFB_BTN_WHEEL_DOWN != 0 && self.held & RFB_BTN_WHEEL_DOWN == 0 {
            wheel -= 1;
        }
        let btn_edge = (sample.buttons ^ self.held) & RFB_HELD;
        if btn_edge != 0 || wheel != 0 {
            self.flush_abs();
            if wheel != 0 {
                self.out.push(PtrEv {
                    ty: VIO_INP_EV_REL as u16,
                    code: VIO_REL_WHEEL as u16,
                    value: wheel as u32,
                });
            }
            self.emit_btn(RFB_BTN_LEFT, VIO_BTN_LEFT, sample.buttons);
            self.emit_btn(RFB_BTN_MIDDLE, VIO_BTN_MIDDLE, sample.buttons);
            self.emit_btn(RFB_BTN_RIGHT, VIO_BTN_RIGHT, sample.buttons);
        }
        self.held = sample.buttons;
        true
    }

    /// Flush coalesced ABS and a trailing `SYN_REPORT`.
    pub fn finish(&mut self) -> Vec<PtrEv> {
        self.flush_abs();
        if !self.out.is_empty() {
            self.out.push(PtrEv {
                ty: VIO_INP_EV_SYN as u16,
                code: VIO_SYN_REPORT as u16,
                value: 0,
            });
        }
        core::mem::take(&mut self.out)
    }

    fn emit_btn(&mut self, bit: u8, code: i64, sample: u8) {
        let now = sample & bit;
        let was = self.held & bit;
        if now != was {
            self.out.push(PtrEv {
                ty: VIO_INP_EV_KEY as u16,
                code: code as u16,
                value: u32::from(now != 0),
            });
        }
    }

    fn flush_abs(&mut self) {
        if !self.pending_abs {
            return;
        }
        self.pending_abs = false;
        self.out.push(PtrEv {
            ty: VIO_INP_EV_ABS as u16,
            code: VIO_ABS_X as u16,
            value: self.last_x,
        });
        self.out.push(PtrEv {
            ty: VIO_INP_EV_ABS as u16,
            code: VIO_ABS_Y as u16,
            value: self.last_y,
        });
    }
}

/// Inverse of guest `DomtPtr` (`abs * disp >> 15`): `px * 0x8000 / disp`,
/// clipped to the framebuffer.
pub fn px_to_abs(px: i32, disp: u32) -> u32 {
    let disp = disp.max(1);
    let max_px = disp.saturating_sub(1) as i32;
    let px = px.clamp(0, max_px) as u32;
    let abs = (u64::from(px) * 0x8000u64) / u64::from(disp);
    abs.min(u64::from(VIO_ABS_MAX)) as u32
}

/// RFB 3.8 PointerEvent: `[5, mask, x_be, y_be]`.
pub fn decode_rfb_pointer(bytes: &[u8]) -> Option<PtrSample> {
    if bytes.len() != 6 || bytes[0] != RFB_POINTER {
        return None;
    }
    let x = u16::from_be_bytes([bytes[2], bytes[3]]);
    let y = u16::from_be_bytes([bytes[4], bytes[5]]);
    Some(PtrSample {
        source: PtrSource::Rfb,
        x_px: i32::from(x),
        y_px: i32::from(y),
        buttons: bytes[1],
        wheel: 0,
    })
}

/// Encode one RFB PointerEvent (tests / exec-model poke).
pub fn encode_rfb_pointer(x: u16, y: u16, buttons: u8) -> [u8; 6] {
    let xb = x.to_be_bytes();
    let yb = y.to_be_bytes();
    [RFB_POINTER, buttons, xb[0], xb[1], yb[0], yb[1]]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn abs_xy(evs: &[PtrEv]) -> Option<(u32, u32)> {
        let mut x = None;
        let mut y = None;
        for e in evs {
            if e.ty == VIO_INP_EV_ABS as u16 && e.code == VIO_ABS_X as u16 {
                x = Some(e.value);
            }
            if e.ty == VIO_INP_EV_ABS as u16 && e.code == VIO_ABS_Y as u16 {
                y = Some(e.value);
            }
        }
        Some((x?, y?))
    }

    #[test]
    fn rfb_decode_rejects_wrong_type() {
        assert!(decode_rfb_pointer(&[4, 1, 0, 0, 0, 0]).is_none());
        assert!(decode_rfb_pointer(&[5, 1, 0, 0]).is_none());
    }

    #[test]
    fn rfb_click_scales_and_emits_abs_btn_syn() {
        let mut n = PtrNorm::new(640, 480);
        let pkt = encode_rfb_pointer(320, 240, RFB_BTN_LEFT);
        assert!(n.push(decode_rfb_pointer(&pkt).unwrap()));
        let evs = n.finish();
        assert_eq!(
            abs_xy(&evs),
            Some((px_to_abs(320, 640), px_to_abs(240, 480)))
        );
        assert!(evs.iter().any(|e| e.ty == VIO_INP_EV_KEY as u16
            && e.code == VIO_BTN_LEFT as u16
            && e.value == 1));
        assert_eq!(evs.last().unwrap().ty, VIO_INP_EV_SYN as u16);
        // Guest scale-back: 320 * 640 >> 15 wait — abs * disp >> 15.
        let (ax, _) = abs_xy(&evs).unwrap();
        assert_eq!((u64::from(ax) * 640) >> 15, 320);
    }

    #[test]
    fn clips_negative_and_overflow() {
        assert_eq!(px_to_abs(-40, 640), 0);
        assert_eq!(px_to_abs(9000, 640), px_to_abs(639, 640));
    }

    #[test]
    fn coalesces_moves_to_last_abs() {
        let mut n = PtrNorm::new(640, 480);
        assert!(n.push(PtrSample {
            source: PtrSource::Rfb,
            x_px: 10,
            y_px: 10,
            buttons: 0,
            wheel: 0,
        }));
        assert!(n.push(PtrSample {
            source: PtrSource::Rfb,
            x_px: 100,
            y_px: 80,
            buttons: 0,
            wheel: 0,
        }));
        let evs = n.finish();
        let abs = evs.iter().filter(|e| e.ty == VIO_INP_EV_ABS as u16).count();
        assert_eq!(abs, 2, "one coalesced ABS pair, not two: {evs:?}");
        assert_eq!(
            abs_xy(&evs),
            Some((px_to_abs(100, 640), px_to_abs(80, 480)))
        );
        assert!(!evs.iter().any(|e| e.ty == VIO_INP_EV_KEY as u16));
    }

    #[test]
    fn preserves_button_press_and_release() {
        let mut n = PtrNorm::new(640, 480);
        assert!(n.push(PtrSample {
            source: PtrSource::Rfb,
            x_px: 20,
            y_px: 20,
            buttons: RFB_BTN_LEFT,
            wheel: 0,
        }));
        assert!(n.push(PtrSample {
            source: PtrSource::Rfb,
            x_px: 20,
            y_px: 20,
            buttons: 0,
            wheel: 0,
        }));
        let evs = n.finish();
        let btns: Vec<u32> = evs
            .iter()
            .filter(|e| e.ty == VIO_INP_EV_KEY as u16)
            .map(|e| e.value)
            .collect();
        assert_eq!(
            btns,
            vec![1, 0],
            "press then release, not coalesced away: {evs:?}"
        );
    }

    #[test]
    fn owner_with_held_button_rejects_other_source() {
        let mut n = PtrNorm::new(640, 480);
        assert!(n.push(PtrSample {
            source: PtrSource::Local,
            x_px: 1,
            y_px: 1,
            buttons: RFB_BTN_LEFT,
            wheel: 0,
        }));
        assert!(!n.push(PtrSample {
            source: PtrSource::Rfb,
            x_px: 200,
            y_px: 200,
            buttons: RFB_BTN_LEFT,
            wheel: 0,
        }));
        let evs = n.finish();
        let (ax, _) = abs_xy(&evs).unwrap();
        assert_eq!(ax, px_to_abs(1, 640));
    }

    #[test]
    fn rfb_right_emits_btn_right_not_left() {
        let mut n = PtrNorm::new(640, 480);
        let pkt = encode_rfb_pointer(10, 10, RFB_BTN_RIGHT);
        assert!(n.push(decode_rfb_pointer(&pkt).unwrap()));
        let evs = n.finish();
        assert!(evs.iter().any(|e| e.ty == VIO_INP_EV_KEY as u16
            && e.code == VIO_BTN_RIGHT as u16
            && e.value == 1));
        assert!(!evs.iter().any(|e| e.code == VIO_BTN_LEFT as u16));
    }

    #[test]
    fn kvm_wheel_emits_rel_wheel_without_click() {
        let mut n = PtrNorm::new(640, 480);
        assert!(n.push(
            KvmPointer {
                x: 320,
                y: 240,
                buttons: 0,
                wheel: -3,
            }
            .sample()
        ));
        let evs = n.finish();
        assert!(evs.iter().any(|e| e.ty == VIO_INP_EV_REL as u16
            && e.code == VIO_REL_WHEEL as u16
            && e.value == (-3i32) as u32));
        assert!(!evs.iter().any(|e| e.ty == VIO_INP_EV_KEY as u16));
    }
}
