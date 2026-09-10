// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Opt-in named host GPU for the GLES2 listing. Never links libGL.
//! Refuses an empty name so the default iGPU is not guessed. Does not
//! mutate QEMU argv (`proxy.gl` stays `qemu-args`).

use std::process::Command;

use g6b_spec::quote_json;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostGpu {
    pub name: String,
    pub status: String,
    pub vendor: String,
}

impl HostGpu {
    pub fn json(&self) -> String {
        format!(
            "{{\"name\":{},\"status\":{},\"vendor\":{}}}",
            quote_json(&self.name),
            quote_json(&self.status),
            quote_json(&self.vendor)
        )
    }
}

/// List host GPUs. Empty list is OK (CI / no DRM node).
pub fn list_gpus() -> Result<Vec<HostGpu>, String> {
    if cfg!(windows) {
        list_windows()
    } else {
        list_unix()
    }
}

pub fn list_json() -> Result<String, String> {
    let items: Vec<String> = list_gpus()?.iter().map(HostGpu::json).collect();
    Ok(format!(
        "{{\"ok\":true,\"gpus\":[{}],\"env_untouched\":true}}",
        items.join(",")
    ))
}

/// Bind the GLES2 listing to a **named** host GPU. Does not create a
/// context here — that stays an OS helper. Empty name is refused.
pub fn apply(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(
            "host gl apply needs a GPU name (refusing to guess the default adapter)".into(),
        );
    }
    Ok(format!(
        "{{\"ok\":true,\"applied\":true,\"gpu\":{},\"gl\":\"host\",\"env_untouched\":false}}",
        quote_json(name)
    ))
}

pub fn revert(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("host gl revert needs a GPU name".into());
    }
    Ok(format!(
        "{{\"ok\":true,\"reverted\":true,\"gpu\":{},\"env_untouched\":true}}",
        quote_json(name)
    ))
}

fn list_windows() -> Result<Vec<HostGpu>, String> {
    let out = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + '|' + $_.Status + '|' + $_.AdapterCompatibility }",
        ])
        .output()
        .map_err(|e| format!("Win32_VideoController: {e}"))?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    Ok(parse_gpu_lines(&String::from_utf8_lossy(&out.stdout)))
}

fn list_unix() -> Result<Vec<HostGpu>, String> {
    let Ok(rd) = std::fs::read_dir("/dev/dri") else {
        return Ok(Vec::new());
    };
    let mut v = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with("card") {
            v.push(HostGpu {
                name,
                status: "Up".into(),
                vendor: String::new(),
            });
        }
    }
    Ok(v)
}

fn parse_gpu_lines(text: &str) -> Vec<HostGpu> {
    let mut v = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut p = line.split('|');
        let name = p.next().unwrap_or("").trim();
        if name.is_empty() {
            continue;
        }
        v.push(HostGpu {
            name: name.into(),
            status: p.next().unwrap_or("").trim().into(),
            vendor: p.next().unwrap_or("").trim().into(),
        });
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_refuses_empty_name() {
        let err = apply("").unwrap_err();
        assert!(err.contains("GPU name"), "{err}");
        let err = revert("   ").unwrap_err();
        assert!(err.contains("GPU name"), "{err}");
    }

    #[test]
    fn parses_gpu_table() {
        let v = parse_gpu_lines("NVIDIA GeForce RTX 3080|OK|NVIDIA\nAMD Radeon RX 6800|OK|AMD\n");
        assert_eq!(v.len(), 2);
        assert!(v[0].name.contains("NVIDIA"));
        assert_eq!(v[1].vendor, "AMD");
    }
}
