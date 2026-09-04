// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BIOS kernel host path: TempleOS/ZealOS services rewritten onto BoardSpec.
//!
//! HolyC init, HTML+JS viewport, optional Gr (SysGrInit), dual-band REPL.

#![allow(missing_docs)]

use g6b_dom::Node;
use g6b_holyc::{eval_src, Program, ReplResult};
use g6b_html::{parse, script_sources, to_uart_lines};
use g6b_http::Router;
use g6b_js::Op;
use g6b_spec::BoardSpec;
use g6b_wasm::Host;

/// Banner OpenSBI-next-stage QEMU eval greps for (`--expect G6LC-BIOS`).
pub const BANNER: &str = "G6LC-BIOS";

/// Fast-init marker printed by generated `HolycInit`.
pub const HOLYC_READY: &str = "HOLYC-READY";

/// DOM+JS UI boot marker.
pub const UI_BOOT: &str = "UI-BOOT";

/// Dual-band HolyC REPL banner (SSH-like TCP band / SSH+HolyC KVM face).
pub const REPL_BANNER: &str = "G6LC-BIOS HOLYC-REPL proto=holyc-repl backend=ssh-holyc";

/// Post-delegate mailbox loopback (not a netdev).
pub const LOOPBACK_BANNER: &str = "G6LC-BIOS LOOPBACK-MBOX proto=holyc-repl not_netdev=1";

/// g6b-wasm Host: DOM + kernel HTTP router (browser-ui `_start` imports).
struct KernelHost<'a> {
    dom: &'a mut Node,
    router: &'a Router,
    last_fetch: Option<String>,
}

impl Host for KernelHost<'_> {
    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
        if let Some(n) = self.dom.get_element_by_id(id) {
            n.set_inner_text(val);
        }
        Ok(())
    }

    fn log(&mut self, _msg: &str) {}

    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String> {
        if let Some(n) = self.dom.get_element_by_id(id) {
            if !on {
                n.set_inner_text("");
            }
        }
        Ok(())
    }

    fn fetch(&mut self, url: &str) -> Result<String, String> {
        let resp = self.router.fetch_get(url);
        self.last_fetch = Some(format!("WASM-FETCH {url} {}", resp.status));
        if let Some(face) = g6b_ui::face_for_fetch(url) {
            let id = face.paint_id();
            if !id.is_empty() {
                if let Some(n) = self.dom.get_element_by_id(id) {
                    n.set_inner_text(&g6b_ui::paint_body(&resp.body_str()));
                }
            }
        }
        Ok(resp.body_str())
    }
}

/// Default setup page: HTML + AOT JS painted on the BIOS viewport.
/// Always includes the FAT32 flash picker; FileMgr is added by [`setup_html`].
pub const SETUP_HTML: &str = r#"<!DOCTYPE html>
<html><head><title>G6LC-BIOS</title></head>
<body>
<h1 id="banner">G6LC-BIOS</h1>
<p>Hold DEL to stay. Esc or timeout continues boot.</p>
<p id="opp">opp: idle</p>
<p id="status">boot</p>
<section id="usb-flash">
<h2 id="usb-title">USB-FAT32</h2>
<p id="usb-list">openwrt.bin g6lc_bios.elf linux.img</p>
</section>
<script>
document.getElementById("status").innerText = "UI-BOOT";
document.getElementById("opp").innerText = "opp: idle";
fetch("/bios/clocks");
fetch("/bios/usb/ls");
fetch("/bios/menu");
</script>
</body></html>
"#;

/// Spec-shaped setup page: FAT32 flash always; USB-key FileMgr when `usb.key`.
pub fn setup_html(spec: &BoardSpec) -> String {
    let mut html = SETUP_HTML.to_string();
    html = html.replace(
        "<script>",
        "<nav id=\"bios-menu\">Main CPU Memory Uncore Devices Boot Settings</nav>\n\
<p id=\"cpu-title\"></p><p id=\"settings-title\"></p>\n<script>",
    );
    if spec.isa.xlen == 64 {
        html = html.replace(
            "</script>",
            "fetch(\"/bios/menu/cpu\");\nfetch(\"/bios/menu/uncore\");\n</script>",
        );
    }
    if spec.kernel.usb.key {
        html = html.replace(
            "<script>",
            "<section id=\"filemgr\">\n\
<p id=\"fm-tabs\">fat32 ntfs ext4</p>\n\
<p id=\"fm-list\">USB-FILES</p>\n\
</section>\n\
<script>",
        );
        let mut extra = String::from("fetch(\"/bios/files\");\n");
        extra.push_str("fetch(\"/bios/files/fat32\");\n");
        if spec.kernel.usb.fs_ntfs {
            extra.push_str("fetch(\"/bios/files/ntfs\");\n");
        }
        if spec.kernel.usb.fs_ext4 {
            extra.push_str("fetch(\"/bios/files/ext4\");\n");
        }
        html = html.replace("</script>", &(extra + "</script>"));
    }
    html
}

/// QEMU extra argv: `-smp` from BoardSpec harts, UART1 chardev for SSH+HolyC.
/// Never a guest netdev. `virtio-gpu-device` when Gr/proxy wants a high-res stand-in.
pub fn qemu_dual_band_argv(spec: &BoardSpec) -> Vec<String> {
    let mut a = vec!["-nographic".to_string()];
    a.push("-smp".into());
    a.push(spec.harts.max(1).to_string());
    if let Some(port) = spec.holyc_tcp_port() {
        a.push("-serial".into());
        a.push(format!("tcp:127.0.0.1:{port},server,nowait"));
    }
    let gpu = spec.kernel.gr.enable
        && (spec.kernel.gr.backend == "virtio-gpu"
            || spec.kernel.proxy.enable
                && matches!(
                    spec.kernel.proxy.link.as_str(),
                    "virtio-gpu" | "hdmi" | "displayport" | "host-gl"
                ));
    if gpu {
        a.push("-device".into());
        a.push("virtio-gpu-device".into());
    }
    a
}

/// Dual-band / SSH+HolyC REPL greeting.
pub fn repl_banner(spec: &BoardSpec) -> String {
    let port = spec.holyc_tcp_port().unwrap_or(0);
    format!(
        "{REPL_BANNER} port={port} postboot={} access={} backends={}",
        spec.postboot.enable.as_str(),
        spec.postboot.access,
        spec.postboot.backends.join(",")
    )
}

/// Post-delegate mailbox loopback greeting (host stand-in for `/dev/g6lc-bios`).
pub fn loopback_banner(spec: &BoardSpec) -> String {
    format!(
        "{LOOPBACK_BANNER} base={} irq={} chardev={} backends={}",
        spec.loopback.base,
        spec.loopback.irq,
        spec.loopback.chardev,
        spec.postboot.backends.join(",")
    )
}

/// Load generated ZealOS (KMain + Adam + PostBoot) into an interpreter.
pub fn load_program(spec: &BoardSpec) -> Result<Program, String> {
    let d = g6b_design::compile(spec);
    let src = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        d.kmain_zc,
        d.adam_zc,
        d.postboot_zc,
        d.loopback_zc,
        d.browser_zc,
        d.tls_zc,
        d.https_zc,
        d.svelte_zc,
        d.endpoints_zc,
        d.holyc_ui_zc
    );
    let mut p = Program::parse(&src)?;
    p.immutable = spec.postboot.immutable.clone();
    p.net_delegates = spec.net_expose.mode == g6b_spec::NetExposeMode::UntilDelegate;
    p.loopback = spec.loopback.enable;
    p.ssh_holyc = spec.postboot.backends.iter().any(|b| b == "ssh-holyc");
    p.router = Router::from_spec(spec);
    Ok(p)
}

/// Full host boot: HolyC fast init, then HTML parse + JS AOT, then UART paint.
pub fn boot(spec: &BoardSpec) -> String {
    let d = g6b_design::compile(spec);
    let holyc_src = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        d.kmain_zc,
        d.adam_zc,
        d.postboot_zc,
        d.loopback_zc,
        d.browser_zc,
        d.tls_zc,
        d.https_zc,
        d.svelte_zc,
        d.endpoints_zc,
        d.holyc_ui_zc
    );
    let mut prog = match Program::parse(&holyc_src) {
        Ok(mut p) => {
            p.immutable = spec.postboot.immutable.clone();
            p.net_delegates = spec.net_expose.mode == g6b_spec::NetExposeMode::UntilDelegate;
            p.loopback = spec.loopback.enable;
            p.ssh_holyc = spec.postboot.backends.iter().any(|b| b == "ssh-holyc");
            p.router = Router::from_spec(spec);
            p
        }
        Err(e) => {
            let _ = e;
            Program::default()
        }
    };
    let holyc_out = prog
        .start()
        .or_else(|_| eval_src(&holyc_src))
        .unwrap_or_else(|e| format!("HOLYC-ERR {e}\n"));

    let mut router = prog.router.clone();
    let mut js_fetch = None;
    let mut holyc_eval = None;
    let mut wasm_fetch = None;
    let mut dom = parse(&setup_html(spec));
    let mut apply_ops = |ops: Vec<Op>, router: &mut Router, dom: &mut Node| {
        for op in ops {
            match op {
                Op::Fetch { url, .. } => {
                    if spec.kernel.http.enable && spec.kernel.http.proxy_js {
                        let resp = router.fetch_get(&url);
                        js_fetch = Some(format!("JS-FETCH {url} {}", resp.status));
                        if let Some(face) = g6b_ui::face_for_fetch(&url) {
                            let id = face.paint_id();
                            if !id.is_empty() {
                                if let Some(n) = dom.get_element_by_id(id) {
                                    n.set_inner_text(&g6b_ui::paint_body(&resp.body_str()));
                                }
                            }
                        }
                    }
                }
                Op::RegisterEndpoint { method, path } => {
                    router.insert(
                        &method,
                        &path,
                        "js",
                        format!("{{\"origin\":\"js\",\"path\":\"{path}\"}}"),
                    );
                }
                Op::HolycEval { line } => {
                    prog.router = router.clone();
                    match prog.repl(&line) {
                        Ok(ReplResult::Output(s)) => {
                            let head = s.lines().next().unwrap_or("").trim();
                            holyc_eval = Some(if head.is_empty() {
                                format!("HOLYC-EVAL {line}")
                            } else {
                                format!("HOLYC-EVAL {head}")
                            });
                            *router = prog.router.clone();
                        }
                        _ => {
                            holyc_eval = Some(format!("HOLYC-EVAL {line}"));
                        }
                    }
                }
                other => {
                    let _ = g6b_js::run(&[other], dom);
                }
            }
        }
    };
    for src in script_sources(&dom) {
        if let Ok(ops) = g6b_js::compile(&src) {
            apply_ops(ops, &mut router, &mut dom);
        }
    }
    if spec.kernel.ui == "svelte-d" {
        if let Ok(ops) = g6b_js::compile(g6b_wasm::BIOS_UI_JS) {
            apply_ops(ops, &mut router, &mut dom);
        }
    }
    if spec.kernel.wasm.enable {
        if let Ok(m) = g6b_wasm::decode(g6b_wasm::bios_ui_wasm()) {
            let mut host = KernelHost {
                dom: &mut dom,
                router: &router,
                last_fetch: None,
            };
            let _ = g6b_wasm::run_start(&m, &mut host);
            wasm_fetch = host.last_fetch;
        }
    }

    let mut lines = Vec::new();
    let holyc = holyc_out.trim_end();
    if holyc.is_empty() {
        lines.push(BANNER.to_string());
    } else {
        lines.push(holyc.to_string());
    }
    lines.push(format!(
        "xlen={} march={} product={}",
        spec.isa.xlen, spec.isa.march, spec.product
    ));
    lines.extend(to_uart_lines(&dom, 80));
    if spec.kernel.gr.enable {
        let mut frame = g6b_gr::Frame::from_spec(spec);
        frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
        lines.push(frame.init_line());
    }
    if spec.entry.timeout_ms > 0 {
        lines.push(format!(
            "entry {} timeout {} ms",
            spec.entry.hotkey, spec.entry.timeout_ms
        ));
    }
    if let Some(port) = spec.holyc_tcp_port() {
        let uart = if spec.holyc.dual_band.uart {
            "uart+"
        } else {
            ""
        };
        lines.push(format!("dual-band {uart}tcp:{port}"));
    }
    if spec.postboot.enable != g6b_spec::PostbootMode::Never {
        lines.push(format!(
            "postboot {} access={} backends={} immutable={}",
            spec.postboot.enable.as_str(),
            spec.postboot.access,
            spec.postboot.backends.join(","),
            spec.postboot.immutable.join(",")
        ));
    }
    if spec.net_expose.mode != g6b_spec::NetExposeMode::Never {
        lines.push(format!(
            "net-expose {} via={} web={} ssh-holyc={}",
            spec.net_expose.mode.as_str(),
            spec.net_expose.via,
            spec.net_expose.web,
            spec.net_expose.ssh_holyc
        ));
    }
    if spec.loopback.enable {
        lines.push(format!(
            "loopback mbox {} irq {} {}",
            spec.loopback.base, spec.loopback.irq, spec.loopback.chardev
        ));
    }
    lines.push(if spec.rvv_live() {
        "ISEL-RVV".into()
    } else {
        "ISEL-SCALAR".into()
    });
    lines.push("TIMER-READY SBI-TIME".into());
    if spec.kernel.proxy.enable {
        let p = g6b_gr::proxy::Proxy::from_spec(spec);
        lines.push(p.init_line());
        if p.gl {
            lines.push("GL-ADAPTER opengl-es2".into());
        }
    }
    if spec.kernel.tls.enable {
        lines.push("TLS-READY".into());
    }
    if spec.kernel.tls.https {
        lines.push("HTTPS-READY".into());
    }
    if spec.kernel.tls.rsa {
        lines.push("TLS-RSA PKCS1-SHA256".into());
    }
    if spec.kernel.tls.ecdsa {
        lines.push("TLS-ECDSA P256-SHA256".into());
    }
    if spec.kernel.tls.certificates {
        lines.push("TLS-CERT X509".into());
    }
    if spec.net_expose.mode != g6b_spec::NetExposeMode::Never {
        lines.push(format!(
            "adapter-ports bios-https={} ssh-holyc={}",
            spec.net_expose.bios_https_port, spec.net_expose.ssh_holyc_port
        ));
    }
    if spec.kernel.profile != g6b_spec::BiosProfile::Custom {
        lines.push(format!("PROFILE-{}", spec.kernel.profile.as_str()));
    }
    if spec.kernel.http.enable {
        lines.push("HTTP-READY".into());
        if spec.kernel.http.http1 {
            lines.push("HTTP/1.1".into());
        }
        if spec.kernel.http.http2 {
            lines.push("HTTP/2".into());
        }
        if spec.kernel.http.serve {
            lines.push(if spec.kernel.tls.https {
                "HTTPS-SERVE".into()
            } else {
                "HTTP-SERVE".into()
            });
        }
        if spec.kernel.http.files.enable {
            lines.push("FILES-SERVE".into());
            if spec.kernel.http.files.html {
                lines.push("FILES-HTML".into());
            }
            if spec.kernel.http.files.js {
                lines.push("FILES-JS".into());
            }
            if spec.kernel.http.files.wasm {
                lines.push("FILES-WASM".into());
            }
            if spec.kernel.http.files.https {
                lines.push("HTTPS-FILES".into());
            }
        }
        if let Some(s) = js_fetch {
            lines.push(s);
        }
    }
    if spec.kernel.flash.enable {
        lines.push(format!(
            "FLASH-READY image={} backend={}",
            spec.kernel.flash.image, spec.kernel.flash.backend
        ));
    }
    if spec.kernel.settings.enable {
        lines.push("SETTINGS-READY".into());
    }
    if spec.kernel.usb.enable {
        lines.push("USB-FAT32".into());
        if spec.kernel.usb.key {
            lines.push("USB-FILES fat32/ntfs/ext4".into());
        }
    }
    lines.push(format!(
        "CPU-{} cores={} threads={} issue={}",
        spec.topology_kind().to_ascii_uppercase(),
        spec.cores,
        spec.threads,
        spec.geo.issue_ports
    ));
    if spec.hypervisor_live() {
        lines.push("CPU-H".into());
    }
    if spec.uncore.clint {
        lines.push("UNCORE-CLINT".into());
    }
    if spec.uncore.plic {
        lines.push("UNCORE-PLIC".into());
    }
    if spec.uncore.ddr {
        lines.push("UNCORE-DDR".into());
    }
    if spec.uncore.pcie {
        lines.push("UNCORE-PCIE".into());
    }
    lines.push("HOLYC-UI".into());
    for m in g6b_ui::menu_markers() {
        lines.push(m);
    }
    if spec.kernel.ui == "svelte-d" {
        for m in g6b_wasm::svelte_live_markers() {
            if m.contains("FileMgr") && !spec.kernel.usb.key {
                continue;
            }
            lines.push(m);
        }
    }
    if spec.kernel.wasm.enable {
        lines.push(g6b_wasm::MARKER.into());
        if spec.kernel.wasm.jit {
            lines.push("WASM-JIT-RV add a0,a0,a1".into());
        }
        if let Some(s) = wasm_fetch {
            lines.push(s);
        }
    }
    if let Some(s) = holyc_eval {
        lines.push(s);
    }
    lines.join("\n")
}

/// High-res display-proxy PPM (ZealOS plane scaled + DOM status strip).
pub fn proxy_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    frame.paint_lines(&to_uart_lines(&parse(&setup_html(spec)), 80));
    let p = g6b_gr::proxy::Proxy::from_spec(spec);
    p.to_ppm(&frame, "DOM status=UI-BOOT")
}

/// OpenGL-ES2 adapter listing for the display-proxy.
pub fn gl_listing(spec: &BoardSpec) -> String {
    let p = g6b_gr::proxy::Proxy::from_spec(spec);
    g6b_gr::gl::listing(&p)
}

/// Host-side stand-in for `_start`.
pub fn host_start(spec: &BoardSpec) -> String {
    boot(spec)
}

/// UART-only display helper (HTML without HolyC). Prefer [`boot`].
pub fn uart_display(spec: &BoardSpec, html: &str) -> String {
    let dom = parse(html);
    let mut lines = vec![BANNER.to_string()];
    lines.push(format!(
        "xlen={} march={} product={}",
        spec.isa.xlen, spec.isa.march, spec.product
    ));
    lines.extend(to_uart_lines(&dom, 80));
    lines.join("\n")
}

/// Drive one HolyC REPL line (dual-band / bios-regress).
pub fn repl_line(prog: &mut Program, line: &str) -> Result<ReplResult, String> {
    prog.repl(line)
}

/// Host PPM of the setup page (SysGrInit rewrite).
pub fn gr_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    let dom = parse(&setup_html(spec));
    frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
    frame.to_ppm()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desktop() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "product":"desktop",
            "isa":{"xlen":64,"march":"rv64imac"},
            "harts":{"count":2},
            "holyc":{"fast_init":true,"dual_band":{"uart":true,"tcp":{"enable":true,"host_port":2222}}},
            "postboot":{"enable":"runtime","access":"kvm","always_on_domain":true}
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn banner_is_g6lc_bios() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"product":"desktop","isa":{"xlen":64,"march":"rv64imac"}}"#,
        )
        .unwrap();
        let out = host_start(&spec);
        assert!(out.contains(BANNER), "{out}");
        assert!(out.contains("xlen=64"));
        assert!(out.contains("DEL") || out.contains("timeout"), "{out}");
    }

    #[test]
    fn holyc_then_dom_js_boot() {
        let spec = desktop();
        let out = boot(&spec);
        assert!(out.contains(HOLYC_READY), "{out}");
        assert!(out.contains(UI_BOOT), "{out}");
        assert!(out.contains("dual-band uart+tcp:2222"), "{out}");
        assert!(out.contains("postboot runtime"), "{out}");
        assert!(out.contains("ssh-holyc"), "{out}");
        assert!(out.contains("loopback mbox"), "{out}");
        assert!(out.contains("until-delegate"), "{out}");
        assert!(out.contains("opp: idle"), "{out}");
    }

    #[test]
    fn qemu_argv_has_ssh_like_serial() {
        let spec = desktop();
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(argv.contains("-nographic"), "{argv}");
        assert!(argv.contains("-smp"), "{argv}");
        assert!(argv.contains("tcp:127.0.0.1:2222,server,nowait"), "{argv}");
        assert!(
            !argv.contains("-netdev"),
            "BIOS path must not steal a NIC: {argv}"
        );
        assert!(!argv.contains("virtio-net"), "{argv}");
    }

    #[test]
    fn gr_init_when_enabled() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,"product":"desktop","isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}}
        }"#,
        )
        .unwrap();
        let out = boot(&spec);
        assert!(out.contains("GR-INIT 640x480x16"), "{out}");
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(argv.contains("virtio-gpu-device"), "{argv}");
        assert!(!argv.contains("virtio-net"), "{argv}");
    }

    #[test]
    fn usb_fat32_always_key_filemgr_on_full() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        let out = boot(&spec);
        assert!(out.contains("USB-FAT32"), "{out}");
        assert!(!out.contains("USB-FILES"), "{out}");
        let full = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let o = boot(&full);
        assert!(o.contains("USB-FAT32"), "{o}");
        assert!(o.contains("USB-FILES fat32/ntfs/ext4"), "{o}");
        assert!(o.contains("SVELTE-LIVE FileMgr"), "{o}");
        assert!(
            setup_html(&full).contains("id=\"filemgr\""),
            "{}",
            setup_html(&full)
        );
        assert!(
            !setup_html(&spec).contains("id=\"filemgr\""),
            "{}",
            setup_html(&spec)
        );
    }

    #[test]
    fn smt2_boot_exposes_cpu_and_uncore_menus() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64},"harts":{"count":2},"core":{"issue_ports":2}}"#,
        )
        .unwrap();
        let out = boot(&spec);
        assert!(out.contains("CPU-SMT"), "{out}");
        assert!(out.contains("UNCORE-PLIC"), "{out}");
        assert!(out.contains("HOLYC-UI"), "{out}");
        assert!(setup_html(&spec).contains("id=\"bios-menu\""));
        assert!(out.contains("MENU-cpu"), "{out}");
        assert!(out.contains("MENU-settings"), "{out}");
        assert!(out.contains("MENU-uncore"), "{out}");
        assert!(
            out.contains("HOLYC-EVAL") || out.contains("JS-FETCH /bios/menu"),
            "{out}"
        );
        assert!(out.contains("FILES-HTML"), "{out}");
        assert!(out.contains("FILES-WASM"), "{out}");
        assert!(out.contains("HTTPS-FILES"), "{out}");
    }

    #[test]
    fn postboot_repl_view_but_not_write() {
        let spec = desktop();
        let mut p = load_program(&spec).unwrap();
        let hand = p.call("LinuxHandoff").unwrap();
        assert!(hand.contains("POSTBOOT-LIVE"), "{hand}");
        assert!(hand.contains("NET-DELEGATE"), "{hand}");
        assert!(hand.contains("LOOPBACK-MBOX"), "{hand}");
        assert!(hand.contains("SSH-HOLYC"), "{hand}");
        match repl_line(&mut p, r#"ViewSection("config");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("VIEW config"), "{s}"),
            other => panic!("{other:?}"),
        }
        match repl_line(&mut p, r#"WriteSection("config");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("IMMUTABLE-DISABLED"), "{s}"),
            other => panic!("{other:?}"),
        }
        match repl_line(&mut p, "Reboot();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("POWER-REBOOT"), "{s}"),
            other => panic!("{other:?}"),
        }
    }
}
