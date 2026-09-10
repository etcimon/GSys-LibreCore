// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! USB MSC / HID catalog. The USB-key file manager and pointer HID live
//! here so VGA zealcli need not depend on this crate.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind};

pub fn key_from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.kernel.usb.enable || !spec.kernel.usb.key {
        return None;
    }
    Some(Adapter {
        id: "usbkey0".into(),
        class: AdapterClass::Usb,
        kind: AdapterKind::UsbKey,
        vendor: "msc".into(),
        features: vec!["fat32".into(), "key".into()],
        transport: "usb".into(),
        device_id: None,
        slot: None,
        mmio: String::new(),
    })
}

pub fn flash_from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.kernel.usb.enable || !spec.kernel.usb.flash_fat32 {
        return None;
    }
    Some(Adapter {
        id: "usbflash0".into(),
        class: AdapterClass::Usb,
        kind: AdapterKind::UsbMsc,
        vendor: "msc".into(),
        features: vec!["fat32".into(), "flash".into()],
        transport: "usb".into(),
        device_id: None,
        slot: None,
        mmio: String::new(),
    })
}

pub fn hid_from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.kernel.usb.enable {
        return None;
    }
    Some(Adapter {
        id: "usbhid0".into(),
        class: AdapterClass::Input,
        kind: AdapterKind::UsbHid,
        vendor: "hid".into(),
        features: vec!["pointer".into()],
        transport: "usb".into(),
        device_id: None,
        slot: None,
        mmio: String::new(),
    })
}
