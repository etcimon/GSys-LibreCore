# HolyC HTTPS / RISC-V TLS primitives

TempleOS has no TLS. ZealOS `Home/Net` is not the OS NIC after Linux. Spec of
record: [`kernel-spec/botan`](../kernel-spec/botan/) (BSD-2-Clause Botan D
port — **not compiled**). First-party rewrite is MIT in `g6b-tls` + `g6b-asm`
crypto IR.

| Primitive | Crate / IR | Web role |
|---|---|---|
| SHA-256 | `g6b-tls` / Zknh names; `g6b-asm` `sha256sum*` when `isa.zknh` live | transcripts, PKCS#1 DigestInfo |
| AES-128 | `g6b-tls` software; `g6b-asm` `aes64es*` when `isa.zkne` live (CVA6: absent) | record cipher |
| HMAC-SHA256 | `g6b-tls` / `Purpose::Hmac` | Finished / CBC MAC |
| RSA PKCS#1 v1.5 SHA-256 | `g6b-tls` / `Purpose::Rsa` | `rsa_pkcs1_sha256` (0x0401) |
| ECDSA P-256 SHA-256 | `g6b-tls` / `Purpose::Ecdsa` | `ecdsa_secp256r1_sha256` (0x0403) |
| X.509 | `g6b-tls` / `Purpose::Cert` | CN + algo from PEM/DER |
| TLS 1.2 ClientHello | `g6b-tls::client_hello` / `client_hello_for_peer` | ECDHE-GCM `c02b`/`c02f`, `supported_versions` 1.2 (no X25519). ALPN `h2` then `http/1.1`. CBC/RSA-KEX not advertised. An IP peer omits SNI. |
| TLS 1.3 ClientHello | `client_hello_tls13` / `client_hello_tls13_psk` | `0x1301` + X25519 `key_share`, then 1.2 ECDHE-GCM fallback; versions 1.3 then 1.2. ALPN `h2` then `http/1.1`. No 0-RTT. HelloRetryRequest refused. `push_server_name` omits SNI for an IP; the PSK binder covers that hello. |
| TLS 1.2 PRF | `tls12_prf_sha256` | RFC 5246 P_SHA256. |
| TLS 1.2 CCS/GCM | `change_cipher_spec` / `seal_record_tls12` | RFC 5288 salt\|\|seq nonce. `wrap_app` stays plaintext. |
| TLS 1.2 Finished | `tls12_finished` | 12-byte verify_data. |
| TLS 1.2 ECDHE | `complete_tls12_ecdhe_gcm` | X25519 + PKCS#1 SHA-256 SKE (RFC 8448 leaf). |
| X25519 | `x25519` | 51-bit limbs, mask cswap. RFC 7748. Not a side-channel lab review. |
| HMAC-DRBG | `HmacDrbg` + `entropy_health` | Stuck-zero/ones/weight/run fail closed. Not SP 800-90B. |
| TLS 1.3 1-RTT | `complete_tls13_1rtt` | CH/SH/dummy CCS/EE/Cert/CV/Finished/NST. RSA-PSS CV. Not a CA path. |
| TLS 1.3 padding | `seal_record_padded` / `open_record` | Inner `content \|\| type \|\| zeros`. |
| TLS alerts | `bad_record_mac` / `decrypt_error` | Fatal 20 / 51. |
| virtio-rtc | `VirtioRtc` | 8-byte BE unix seconds. Fail closed if short. Not `rdtime`. |
| X.509 path | `CertStore` | SAN/KU/BC/EKU serverAuth; DNS name constraints (permitted/excluded). Not a system store. |
| OCSP | `ocsp_plan` / BasicOCSP | Isolated NAT HTTP `10.0.2.2`/`10.0.2.3` only. HTTPS chicken-egg refused. Not a live public responder. |

An IP literal is the TCP peer only. `client_hello_with` still returns
`tls: sni` for an empty name, an address, a colon, `..`, a leading hyphen,
and `/`, `\`, `@`, or `_`. `client_hello_for_peer` sends `client_hello_no_sni`
when the host parses as `IpAddr`, and `client_hello_with` otherwise, so
HolyC `TlsClientHello` / `TlsServerHello` / `HttpsGet` do not panic on
`127.0.0.1` or `::1`. `127.0.0.1:443` is not an address literal and is still
`tls: sni`. Kernel HTTPS to an IP uses the same omission before the bytes
go onto hw TCP. Setup of that call is [`SETUP.md`](SETUP.md).

HolyC: `TlsHandshake`, `TlsClientHello`, `TlsServerHello`, `HttpsGet`,
`HttpGet` (kernel path, plaintext GET on hw TCP), `HttpsServe`,
`RsaVerify`, `EcdsaVerify`, `CertParse`, `NetOpenPort`.

ServerHello (TLS 1.2 record, suites `c02f`/`c02b`/`003c`, stub certificate
CN=`g6lc-bios`) is compiled when `kernel.tls.serve` or `http.files.https`.
Application-data records wrap HTTP for the file server; see [`FILE-SERVER.md`](FILE-SERVER.md).

Adapter ports (pre-`NET-DELEGATE` only): `net_expose.bios_https_port` (443) and
`net_expose.ssh_holyc_port` (2222). After handoff, both faces ride
`/dev/g6lc-bios`. QEMU BIOS argv still has **no** `-netdev`.

Refuse: linking Botan/OpenSSL; compiling `kernel-spec/botan`; a BIOS netdev
after Linux owns eth/wifi.

Kernel `HttpsGet` / outbound `https:` **plans** in `g6b-http`, writes a
`g6b-tls` ClientHello, and lowers the bytes onto `g6b-hw` TCP/IP
(`via=hw-tcp`). `g6b-hw` does not speak TLS. Guest `HttpsGet` through
the kernel is that fingerprint until B54. Plain `HttpGet` is the same
path without ClientHello (HTTP/1.1 GET on the socket). See
[`g6b-hw.md`](g6b-hw.md).
