# HolyC HTTPS / RISC-V TLS primitives

TempleOS has no TLS. ZealOS `Home/Net` is not the OS NIC after Linux. Spec of
record: [`kernel-spec/botan`](../kernel-spec/botan/) (BSD-2-Clause Botan D
port — **not compiled**). First-party rewrite is MIT in `g6b-tls` + `g6b-asm`
crypto IR.

| Primitive | Crate / IR | Web role |
|---|---|---|
| SHA-256 | `g6b-tls` | transcripts, PKCS#1 DigestInfo |
| AES-128 | `g6b-tls` | record cipher (CBC/GCM suites advertised) |
| HMAC-SHA256 | `g6b-tls` / `Purpose::Hmac` | Finished / CBC MAC |
| RSA PKCS#1 v1.5 SHA-256 | `g6b-tls` / `Purpose::Rsa` | `rsa_pkcs1_sha256` (0x0401) |
| ECDSA P-256 SHA-256 | `g6b-tls` / `Purpose::Ecdsa` | `ecdsa_secp256r1_sha256` (0x0403) |
| X.509 | `g6b-tls` / `Purpose::Cert` | CN + algo from PEM/DER |
| TLS 1.2 ClientHello | `g6b-tls::client_hello` | suites `c02b` ECDHE-ECDSA-AES128-GCM, `c02f` ECDHE-RSA-GCM, `003c` RSA-AES128-SHA256 |

HolyC: `TlsHandshake`, `TlsClientHello`, `TlsServerHello`, `HttpsGet`,
`HttpsServe`, `RsaVerify`, `EcdsaVerify`, `CertParse`, `NetOpenPort`.

ServerHello (TLS 1.2 record, suites `c02f`/`c02b`/`003c`, stub certificate
CN=`g6lc-bios`) is compiled when `kernel.tls.serve` or `http.files.https`.
Application-data records wrap HTTP for the file server; see [`FILE-SERVER.md`](FILE-SERVER.md).

Adapter ports (pre-`NET-DELEGATE` only): `net_expose.bios_https_port` (443) and
`net_expose.ssh_holyc_port` (2222). After handoff, both faces ride
`/dev/g6lc-bios`. QEMU BIOS argv still has **no** `-netdev`.

Refuse: linking Botan/OpenSSL; compiling `kernel-spec/botan`; a BIOS netdev
after Linux owns eth/wifi.
