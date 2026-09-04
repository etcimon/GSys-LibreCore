# DESIGN — spec rewrite onto BoardSpec

TempleOS/ZealOS (`kernel-spec/`) specify services. LibreCore validates
inferences. BoardSpec is the only customisation IR.

```
kernel-spec (spec) + LibreCore architecture (conformity)
                →  BoardSpec JSON
                →  g6b-spec (legality + inferred_arch)
                →  g6b-asm    analyze objects/purposes → Module (CODEGEN.md)
                →  g6b-design (Config.ZC …; KStart.S / KInts.S / MemCpy.S from IR)
                →  g6b-holyc  fast init (HOLYC-READY); ISel wraps g6b-asm
                →  g6b-html / g6b-js / g6b-dom  → UART viewport (UI-BOOT)
                →  g6b-gr     SysGrInit 16-colour 8×8 plane + display-proxy
                               (HDMI/DP / host-GL, 30/60/120 fps) + GLES2 listing
                →  g6b-webidl / g6b-js / g6b-dom / g6b-wasm + browser-ui
                               BIOS browser + svelte-d NodeDef + WASM-JIT on the kernel
                →  g6b-tls    Botan rewrite: SHA-256 / AES-128 / HMAC / RSA / ECDSA / X.509
                               HolyC HttpsGet + TlsClientHello; adapter :443 / :2222 until NET-DELEGATE
                →  g6b-http   HTTP/1.1 + HTTP/2 parse; JS fetch ≡ HolyC RegisterEndpoint
                               profiles embedded→full; /bios/flash|settings|update
                               file server /ui/{index.html,app.js,ui.wasm} + TLS ServerHello
                →  g6b-fs     USB FAT32 flash listings always; key FileMgr FAT32/NTFS/ext4
                →  menus      infer CPU/uncore/boot tree; HolycUi.ZC ⊥ svelte-d Menu
                →  g6b-elf    RV32/64 words from the same Module (tp/sp/stvec)
OpenSBI fw_dynamic -kernel g6lc_bios.elf   (g6q --loader bios)
                UART0 stdio + UART1 tcp:2222 (HolyC dual-band, ssh-like)
                →  timeout/Esc → Linux | U-Boot | EDK2
                →  postboot.enable keeps a management instantiation
```

XLEN 32 vs 64 and RVV are `#define`s in generated `Config.ZC`. `Mem.ZC` mentions
`vsetvli` only when `extensions.v=live` and `xlen=64`.

KVM faces (both, not either/or): **HTML+JS** viewport and **SSH+HolyC** ZealOS
CLI (`postboot.backends`). Dual-band UART + tcp:2222 is the pre-delegate
SSH+HolyC stand-in (chardev, not a NIC). Optional `net_expose=until-delegate`
lets the adapter serve gateway/web and SSH+HolyC until `LinuxHandoff` prints
`NET-DELEGATE` and Linux owns eth/wifi. After that, `LOOPBACK-MBOX` (PLIC IRQ,
`/dev/g6lc-bios`) is the only in-guest path — MEI/SMC/IPMI-BT shaped, never a
netdev. Generated `linux/g6lc_bios_mbox.c` is a platform miscdriver (`file_operations`,
PLIC irq, probe) — MEI/SMC/IPMI-BT shaped, never `alloc_netdev`. See [`PLAN.md`](PLAN.md).
