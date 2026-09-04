# botan queue — bring this tree up to date with randombit/botan

Untracked-local. Work on **`feature/randombit-sync`** (merges to **this** repo’s
`master`, etcimon/botan). Do not commit this file unless asked.

**Up to date** here means: every **missing** algorithm and security behaviour
listed in `architecture/inventory-randombit.md` is either landed behind a
`version` (with `dub test`) or still on this queue — **not** a Botan 3 API
rebase. Historic D-only algos stay. vibe.0 keeps the same TLS delegates.

## How (read these, do not reinvent)

| Question | Open |
|---|---|
| How a pass is run (one increment, copyright, finished cells) | `AGENTS-upgrade.md` |
| What a pass is / what finished means | `AGENTS-development.md` |
| Full increment table (IDs S1, H1, K1, CS1, T13a, …) | `architecture/upgrade-randombit.md` |
| What C++ 3.13 has that this pin does not | `architecture/inventory-randombit.md` |
| How to *select* a new algo (SCAN string by purpose, same ASN.1/OID) | `architecture/scan-asn1.md` |
| How to *test* it (`dub test`, `CanTest`, `SKIP_*`, `runTestsBb`) | `architecture/dub-test.md` |
| How to rebuild faster / test only added families | `architecture/incremental-build.md`, `scripts/inc-build.ps1` |
| How configs work (`full` = all, `standard` = popular, nothing retired) | `architecture/dub-configs.md` |
| How cert chains work for TLS 1.2 and 1.3 | `architecture/cert-stores.md` |
| How ASM/SIMD is ported (own `version`, LDC/GDC/DMD, same KATs) | `architecture/asm-accel.md` |
| How vibe.0 attaches (delegates frozen) | `architecture/vibe-delegates.md` |
| How flags are named | `architecture/feature-versions.md` |
| How to write headers on touched files | `architecture/copyright.md` |
| How the factory/engines already work | `architecture/libstate-factory.md` |
| Navigation | `AGENTS.md`, `architecture/README.md` |

Start of every increment: git sync in `architecture/upgrade-randombit.md`
(“Git sync”). Compare pin: `../randombit-botan`. If that `HEAD` moved, update
the pin lines here and in `inventory-randombit.md` before coding.

## Current state

| Item | Value |
|---|---|
| Branch | `feature/randombit-sync` @ `460336f` + uncommitted Train 0 + CS1–3/H2 + K1–K5 + P1–P6 + R1–R2 + B1–B4/Hsh1–6/M1 + A1–A2 + Str1 + C3–C6 |
| C++ lineage claim | `BOTAN_VERSION_*` 1.12.3 (`constants.d`) — do not lie and set this to 3 |
| D package version | `dub.json` `1.13.9` |
| Reference | `../randombit-botan` @ `6931ef6fd` (3.13.0-24), fetched even 2026-08-15 |
| vibe.0 | `../vibe.0` `feature/botan-delegate-sync` @ `7b77638` |
| Green | `dub build --compiler=ldc2` PASS; `dub test` historically PASS. This turn: `PSS_Raw` + `rsa_pss_raw` **80**; explicit-curve ECDSA PKCS8 **13**. `inc-build test rsa` / `ecdsa` exit 0 (RSA 825, Wycheproof 11864). Prior re-val of EC/X.509/TLS/DH still stands. Full `dub test` not re-run. |
| memutils | `dub.selections.json` now `1.0.12` (was 1.0.11; Embed.opEquals needed for T0 compile) |

## First blocked

**Vec-impl done** — … + Roughtime + C++ x509test **34/37**. RFC 3779 `ASBlocks` + `IPAddressBlocks` decode (`IPAddrBlocksAll` poked). Leftover: 3 NC PEMs; `IPAddrBlocksUnsorted` inherit/SAFI; BSI/name_constraints testdata; extended x509; timing CLI; AVX-512.

## Vec-fix plan (this pass)

| # | Failure | Cause | Fix | Status |
|---|---|---|---|---|
| 1 | `ChaCha(20)` tests 9+ (`103AF111…` vs shifted `3AF111…`) | C++ `Seek = N`; D had no `seek()`. 32-bit wrap inside SSE2 x4/x8 batch. | `StreamCipher.seek`; sequential refill near wrap; factory `CTR-BE(cipher,n)`. | done |
| 2 | `Blowfish` key length 57 | C++ max 72; D max 56. | Raise max key to 72. | done |
| 3 | CCM `assert` `Length field fits` | `L==8` is legal (C++ 2..8). | Match C++ `encode_length`. | done |
| 4 | `CAST-128/CBC/PKCS7` wrong CT / `Invalid CBC padding` | 13-byte key leftover in LSB; hex case in `modeTest`. | Zero-pad to 16 + `load_be`; compare decoded hex. | done |
| 5 | `KDF1(SHA-1)` 20 B vs 10 B prefix | `derive` ignored `key_len`. | Truncate / reject like C++ 3.13. | done |
| 6 | GCM tag 12 / large GCM KATs | D used `CTR-BE(cipher)` 16-byte counter; C++ `CTR_BE(cipher, 4)`. | `new CTRBE(cipher, 4)`; tags 8 or 12–16. | done |
| 7 | Threefish-512 encrypt assert | C++ vecs have `Tweak=`. | `blockTest` calls `setTweak`. | done |
| 8 | `ml_kem.vec` 15× `KAT PK hash mismatch` | Runner fired on `SS` (2nd field). First case skipped (PK/SK/CT not yet parsed); later cases hashed leftover PK from the previous record. Keygen `z` then `d`, SHAKE-256(128) of `public_key_bits` / seed `d‖z` already match C++ / ACVP. | Fire `runTestsBb` on last field `SS_N`; run all 25/instance. | done |
| 9 | `ml-dsa-*_Deterministic` 7× `HashSk mismatch` | C++ `HashSk` is SHA-3-256 of `private_key_bits()` = 32-byte seed ξ (`ML_DSA_Expanding_Keypair_Codec`). D hashed `mldsaEncodeExpandedSk`. HashPk already matched. | Hash PKCS#8 / seed bits (ξ), not expanded SK. Run all 25/instance. | done |

Then re-run `inc-build.ps1 test ml_kem,ml_dsa`.

**Train 5 leftover:** AVX-512 (this host has no AVX2/512).

## Trains (do in order; one increment per pass)

IDs are those in `architecture/upgrade-randombit.md`. **How** is always
`AGENTS-upgrade.md` plus the note in the last column.

### Train 0 — suite + hygiene

| ID | What | How |
|---|---|---|
| T0 | Record `dub test` | `dub-test.md` |
| S1, S5, S6, S7 | RSA length, RNG clear, default TLS policy, RSA 2048 floor | `upgrade-randombit.md` §S*; `dub-test.md` negatives |
| H1 | HKDF / AutoSeeded / codec / padding become real `version`s | `feature-versions.md`, `scan-asn1.md` |
| S8, S2, S3 | **S2/S3/S8 done** | `open-questions.md` |
| S4 | **done** OCSP HTTP is a delegate; POST never follows redirects | `http_util.d`, `ocsp.d`, `vibe-delegates.md` |

### Train 1 — certs + dub shape (before TLS 1.3)

| ID | What | How |
|---|---|---|
| CS1 | PEM-bundle store + `addFromFile` | **done** `cert-stores.md` |
| CS3 | TLS 1.3 scheme → `algoName` for `certChain` | **done** `cert-stores.md` |
| H2 | Add `standard` config; `full` stays include-all | **done** `dub-configs.md` |
| CS2 | Optional system trust store | **done** `cert-stores.md` |

### Train 2 — popular primitives

| ID | What | How |
|---|---|---|
| K1, K2 | Argon2 **done**, scrypt **done** | `scan-asn1.md` |
| P1–P6 | Ed25519/X25519/Ed448/X448 **done** + SM2 **done** + ECGDSA/ECKCDSA **done** + ECIES **done** (`full` only) | `scan-asn1.md` (`OIDS`/`pk_algs`), `pubkey.md` |
| R1 | `System_RNG` **done** | `rng-entropy.md` |
| R2 | `Stateful_RNG` + `ChaCha_RNG` **done** | `rng-entropy.md` |
| B1–B4, Hsh1–6, M1, K3–K5 | ARIA/SHACAL2/SM4/Kuznyechik **done**, BLAKE2s/SM3/Streebog/Ascon-Hash256/Truncated/XOF **done**, SipHash/GMAC/KMAC/BLAKE2bMAC **done**, SP800 + KDF1-18033/XMD + Bcrypt-PBKDF/OpenPGP-S2K/PKCS12-KDF **done** | `scan-asn1.md`, `symmetric.md` |
| A1, A2 | AES-GCM-SIV **done**; Ascon-AEAD128 **done** | `scan-asn1.md`, `symmetric.md` |
| Str1 | SHAKE_Cipher **done** (`full` only; C++ deprecated) | `scan-asn1.md`, `symmetric.md` |
| C3 | HOTP/TOTP **done** (RFC 4226/6238; `full` + `standard`) | `scan-asn1.md`, `symmetric.md` |
| C5 | Base32/Base58 **done** (`full` + `standard`) | `scan-asn1.md` |
| C4 | NIST KW/KWP **done** (`full` + `standard`) | `scan-asn1.md` |
| C6 | EME_RAW **done** (`full` + `standard`) | `scan-asn1.md`, `pubkey.md` |
| C2 | SPAKE2P **done** (RFC 9383 HMAC suites; `full` + `standard`) | `scan-asn1.md`, `pubkey.md` |
| H1b | HKDF **is** a `KDF`: `getKdf("HKDF(SHA-256)")` / Extract / Expand, `cast(HKDF)` | `scan-asn1.md` |
| C7 | ISO9796 **done** (`getEmsa("ISO_9796_DS2/DS3")` → `EMSA`; `full` only) | `scan-asn1.md`, `pubkey.md` |

Remaining B/Hsh/M/A/K/P/C/R rows in the upgrade table: same how; add to `full`
always, to `standard` only if `dub-configs.md` says popular.

### Train 3 — TLS 1.3 (same delegates)

| ID | What | How |
|---|---|---|
| T13a | **done** `TLS_13` + `TLS_V13`; `latestTlsVersion()` stays 1.2; default policy rejects 1.3 | `vibe-delegates.md`, `tls.md` |
| T13b | **done** 1.3 record layer + AEAD wrap (`tls/tls13/`); not wired into `TLSChannel` yet | `tls.md` |
| T13c | **done** parse ClientHello/ServerHello 1.3 (`supported_versions` + `key_share`); not wired into `TLSChannel` | `tls.md`, `dub-test.md` |
| T13d | **done** in-process `isActive` at 1.3 + record-layer handshake/app keys | `vibe-delegates.md`, `tls.md`, `dub-test.md` |
| T13e | **done** `OCSP_Staple`: CH `status_request` + 1.3 cert-entry staple; creds `ocspStaple` default empty | `tls.md`, `cert-stores.md` |
| V1 | **vibe.0 branch**: Botan for `TLSVersion.tls1_3` + bundle `useTrustedCertificateFile` | `vibe-delegates.md`; `../vibe.0/architecture/botan-delegates.md` |

### Train 4 — PQC then TLS-PQC

| ID | What | How |
|---|---|---|
| P7–P9 | ML-KEM, ML-DSA, SLH-DSA (`full` only until needed) | `scan-asn1.md` (`algoName` + OID; no `retrieveKem`) |
| T13p | **done** `TLS_13_PQC`: X25519MLKEM768 + secp ML-KEM hybrids + pure ML-KEM + libOQS eFrodo 0xFE00–0xFE0F (classical-first concat); default policy does not offer | `vibe-delegates.md`, `tls.md` |

### Train 5 — ASM/SIMD (anytime after the portable algo exists)

One ISA flavour per pass. How: `architecture/asm-accel.md`. Own `version` on
`versions-x86_64` only; LDC/GDC/`D_InlineAsm_*`; same SCAN + same `dub test`
vectors. Portable `CoreEngine` stays. AES-NI already exists; **SHA-2 SIMD**,
**ChaCha SIMD/AVX2**, **SM4/ARIA/Camellia HWAES**, and **SHA-NI** done. Next: further ISA flavours (`asm-accel.md`).

## What “done / up to date” is not

- Not a merge of C++ 3.x `Callbacks` / engine removal.
- Not deleting RC4/MD5/MARS (`dub-configs.md`).
- Not flipping `latestTlsVersion()` to 1.3.
- Not C++ `botan-test` as the D harness (`dub-test.md`).
- Not vendoring `../randombit-botan`.
- Not RISC-V ISA versions without a recorded compiler cell (`open-questions.md`).

## Do not

Commit these notes unless asked; edit the LibreCore host scaffold; weaken
`TLSCredentialsManager` / key types to dodge Embed; land with
`SKIP_*_TEST = true`; add a second algorithm registry.

## Pass log

| date | pass | outcome |
|---|---|---|
| 2026-08-12 | Architecture notes + guider (B3–B5) | `dub build` PASS on `460336f` |
| 2026-08-15 | Compare `../randombit-botan` `6931ef6fd`; write upgrade plan | Plan only |
| 2026-08-16 | Hsh6 XOF (SHAKE/cSHAKE/Ascon-XOF128) + C++ vecs | focused `inc-build.ps1 test xof` |
| 2026-08-16 | K3 SP800-108/56A/56C + C++ vecs | focused `inc-build.ps1 test kdf` |
| 2026-08-16 | K4 KDF1-18033 + XMD + C++ vecs | focused `inc-build.ps1 test kdf` |
| 2026-08-16 | K5 Bcrypt-PBKDF / OpenPGP-S2K / PKCS12-KDF + C++ vecs | focused `inc-build.ps1 test pbkdf` |
| 2026-08-15 | **T0** `dub test --compiler=ldc2` | PASS after selections → memutils 1.0.12 (35 then 36 modules) |
| 2026-08-15 | **S1** RSA cipher/sig length == `n.bytes()`; **S5** HMAC_DRBG `clear` resets reseed counter; **S6** default policy prefers ECDSA, still no FFDH/RC4/3DES/static-RSA; **S7** keygen floor 2048 unless `version(RSA_Insecure)` | `dub test` PASS; ctor signature unchanged |
| 2026-08-15 | **H1** `HKDF` / `Auto_Seeding_RNG` / `Codec_Filters` / `Cipher_Mode_Padding` are real `version`s | `dub build`, `dub build -c hash`, `dub test` PASS |
| 2026-08-15 | **CS1** `CertificateStoreInMemory.addFromFile` + `CertificateStoreFlatfile` (`CertStore_Flatfile`); **CS3** `certChainAlgoName` / `allowedSignatureSchemes`; **H2** dub `standard` | `inc-build.ps1 test x509` PASS (15 CS1 + 74 NIST); `inc-build.ps1 test tls` PASS (7); `dub build`, `dub build -c hash`, `dub build -c standard` PASS; **`dub test --compiler=ldc2` PASS (36 modules)** |
| 2026-08-15 | **CS2** `CertificateStoreSystem` (`CertStore_System`): Windows `Root`+`CA` via CryptoAPI; POSIX well-known PEM bundles | `inc-build.ps1 test x509` PASS (5 CS2 live Windows store); `dub build -c hash`, `dub build -c standard` PASS |
| 2026-08-15 | **K1** portable Argon2d/i/id via `getPbkdf("Argon2id")` / `Argon2id(M,t,p)` | `inc-build.ps1 test pbkdf` PASS (20 PBKDF + 357 Argon2 KATs) |
| 2026-08-15 | **K2** scrypt via `getPbkdf("Scrypt")` / `Scrypt(N,r,p)` | `inc-build.ps1 test pbkdf` PASS (13 KATs + 8 negatives; 1 GiB RFC cases omitted) |
| 2026-08-16 | **M1** GMAC + KMAC-128/256 (`MacStart` nonce/S); **A1** AES-GCM-SIV + POLYVAL (RFC 8452) | `inc-build.ps1 test mac,aead` PASS: GMAC 143, KMAC 14, SipHash 59, POLYVAL 3, AES-128/256/GCM-SIV 82; mac 1362; aead 1905 |
| 2026-08-16 | **M1** BLAKE2bMAC (`retrieveMac("BLAKE2b")`); **B2** SHACAL2 | `inc-build.ps1 test mac,block` PASS: BLAKE2b MAC 273, SHACAL2 1021; mac 2181; block 24516 |
| 2026-08-16 | **B3** SM4 (CT key schedule); **Hsh2** SM3 | `inc-build.ps1 test hash,block` PASS: SM3 139, SM4 22; hash 20084; block 24582 |
| 2026-08-16 | **B4** Kuznyechik; **Hsh3** Streebog-256/512 | `inc-build.ps1 test hash,block` PASS: Kuznyechik 65, Streebog 265; hash 21144; block 24777 |
| 2026-08-16 | **Hsh4** Ascon-Hash256; **Hsh5** Truncated; **A2** Ascon-AEAD128 | `inc-build.ps1 test hash,aead` PASS: Ascon-Hash256 106, Truncated 7, Ascon-AEAD128 121; hash 21596; aead 2510 |
| 2026-08-16 | **P6** ECIES ISO 18033-2 + C++ vecs | `inc-build.ps1 test ecies` PASS: ECIES-ISO 2, ECIES 12 |
| 2026-08-16 | **Str1** SHAKE-128/256 stream cipher + C++ vecs | `inc-build.ps1 test stream` PASS: SHAKE-128 1145, SHAKE-256 1145; stream 2931 |
| 2026-08-16 | **C3** HOTP/TOTP + C++ RFC vecs | `inc-build.ps1 test hotp` PASS: HOTP SHA-1/256/512 20+6+6, TOTP SHA-1 3 |
| 2026-08-16 | **C5** Base32 + Base58/Base58Check + C++ vecs | `inc-build.ps1 test codec` PASS: Base32 24+9, Base58 36+14, Base58Check 4+5 |
| 2026-08-16 | **C4** NIST KW/KWP + C++ vecs | `inc-build.ps1 test nist_keywrap` PASS: KW 7+7, KWP 129+3 |
| 2026-08-16 | **C6** EME-Raw `getEme("Raw")` | `inc-build.ps1 test eme_raw,rsa` PASS: pad/unpad + RSAES 123 / sig 110 / verify 27 |
| 2026-08-16 | **R2** Stateful_RNG + ChaCha_RNG + C++ vecs | `inc-build.ps1 test chacha_rng` PASS: 21 |
| 2026-08-16 | **C2** SPAKE2+ RFC 9383 + C++ vecs | `inc-build.ps1 test spake2p` PASS: 5 |
| 2026-08-16 | **H1b** HKDF/Extract/Expand inherit `KDF`; `getKdf` SCAN; SPAKE2+ uses factory | `inc-build.ps1 test hkdf,kdf,spake2p` PASS: RFC 7, factory HKDF 37, kdf 1648, SPAKE2+ 5 |
| 2026-08-16 | **C7** ISO-9796-2 DS2/DS3 `getEmsa` + C++ verify vecs | `inc-build.ps1 test iso9796` PASS: 6 |
| 2026-08-16 | **T13a** `TLS_13` + `TLS_V13`; latest stays 1.2; policy caps at 1.2 | `inc-build.ps1 test tls` PASS: 8 |
| 2026-08-16 | **T13b** TLS 1.3 record layer + `getAead` wrap | `inc-build.ps1 test tls` PASS: record 6 + TLS 8 |
| 2026-08-16 | **T13c** ClientHello/ServerHello 1.3 parse (`supported_versions`, `key_share`, cookie, psk_modes, record_size_limit); HRR random; latest stays 1.2 | `inc-build.ps1 test tls` PASS: client_hello 16 + server_hello 8 + record 6 + TLS 8 |
| 2026-08-16 | **memutils** pin `../memutils`; Unique-wrap T13 tests; GC-safe `botanDestroyIfLive`; `DebugAllocator` leak snaps; HashMap.clear destroys struct values | `inc-build.ps1 test tls` PASS; hello/record repeat 0 growth; 1.2 handshake leftover 548 B logged; shutdown CryptoSafe 0 |
| 2026-08-16 | **MM** HashMap.remove same struct-destroy; GCM/Pipe/SecureQueue skip `.destroy` in GC finalizer; Unique-wrap HMAC_DRBG; leak snap on HKDF repeat | `inc-build.ps1 test "tls,rng,kdf"` PASS: rng 1117, kdf 1648, tls hello/record 0 growth |
| 2026-08-16 | **MM-algos** `checkMemutilsRepeat` on hash/block/mac/aead/stream/xof/pbkdf/mode/hkdf/kdf/hotp/nist_kw/chacha_rng; `Unique!HOTP` inside TOTP; Unique-wrap HOTP/TOTP/ChaChaRNG tests | `inc-build.ps1 test "chacha_rng,hotp,hash,mac,aead,stream,xof,hkdf,nist_keywrap,kdf,rng,tls"` PASS (17 modules); no family-probe growth; 1.2 handshake 548 B still logged |
| 2026-08-16 | **CT** `utils/ct.d` (Mask, `constantTimeCompare`, `secureScrubMemory`); `sameMem` is CT; PKCS7/X9.23/OneAndZeros unpad CT; HMAC short-key schedule CT | `inc-build.ps1 test "mac,mode"` PASS: ct 10, mode_pad_ct 3, cipher_mode 2244, mac 2181 |
| 2026-08-16 | **CT** ESP pad (RFC 4303) + `getBcPad("ESP")`; `CTMask.isWithinRange`/`isAnyOf`; Base32 decode + Base58 encode/decode CT lookup | `inc-build.ps1 test "mode,codec"` PASS: ct 14, mode_pad_ct 8, cipher_mode 2245, base32 24+9, base58 36+14+4+5 |
| 2026-08-16 | **CT** `version(No_CT)` → `BOTAN_HAS_CT` in `constants.d` (default on); variable-time unpad / compare / HMAC / codec tables | default + `--d-version=No_CT` PASS: ct 14, mode_pad_ct 8, cipher_mode 2245, mac 2181, base32 24+9, base58 36+14+4+5 |
| 2026-08-16 | **CT** default is `No_CT` (`BOTAN_HAS_CT=false`); opt-in `version(CT)` like algos; X509 gates use `BOTAN_HAS_X509_CERTIFICATES` | default + `--d-version=CT` PASS: ct 14, mode_pad_ct 8, cipher_mode 2245, mac 2181, codec vecs |
| 2026-08-16 | **vers** gate padding/auto_rng/codec filters/PEM/OpenPGP/X509 leftovers via `BOTAN_HAS_*`; `Locking_Allocator` mapped; `Codec_Filters` on `pubkey` | `inc-build test "mode,codec"` PASS; `dub build -c hash` PASS; `dub build -c pubkey` PASS |
| 2026-08-16 | **vers** audit of all C++-ported increments: already `BOTAN_HAS_*` husks; `X25519`/`TOTP` aliases; HOTP asserts HMAC; inventory in `feature-versions.md` | `dub build -c hash` PASS |
| 2026-08-16 | **license** align touched D headers with C++ counterpart author lists + Cimon 2014–2026; `LICENSE.md` Jack 1999–2026 + missing names | headers only; `LICENSE.md` |
| 2026-08-16 | **license** remaining git-touched TLS/KDF/types/HMAC_DRBG/stream: C++ author lists (Meusel, Elektrobit, Somorovsky, Warta, …) | headers + `LICENSE.md` |
| 2026-08-16 | **T13d** emit 1.3 ClientHello (legacy 1.2 + `supported_versions` + x25519 `key_share` + 0x1301/02/03); `tls13/handshake.d` ECDHE secrets; latest stays 1.2; default policy still rejects 1.3 | `inc-build.ps1 test tls` PASS: hello 16+8, handshake 3, record 6, TLS 8 |
| 2026-08-16 | **T13d** ServerHello 1.3 emit (legacy 0x0303 + SV + key_share); EncryptedExtensions type 8; `tls13SelectVersion` 1.3→1.2 fallback; server sends SH+EE when both accept 1.3; Cert/CV/Finished/`isActive` next | `inc-build.ps1 test tls` PASS: hello 16+8, handshake 8, record 6, TLS 8 |
| 2026-08-16 | **T13d** in-process `isActive` at 1.3: Cert/CV/Finished + ECDHE secrets + TestPolicy handshake; post-SH records still plaintext; latest stays 1.2 | `inc-build.ps1 test tls` PASS: hello 16+8, handshake 12, record 6, TLS 9 |
| 2026-08-16 | **T13d** `TLS13RecordLayer` on `TLSChannel`: handshake then application traffic keys; post-SH EE/Cert/CV/Finished + app data AEAD-wrapped | `inc-build.ps1 test tls` PASS: hello 16+8, handshake 14, record 6, TLS 9 |
| 2026-08-16 | **S4** `setHttpExchangeHandler` + `ocspHttpPost` (0 redirects); `OnlineCheck` skips if no transport | `inc-build.ps1 test x509` PASS: http_util 8, NIST path 74, CS1 15, CS2 5 |
| 2026-08-16 | **T13e** `OCSP_Staple`: CH offers `status_request`; 1.3 CertificateEntry staple (RFC 6066 CertificateStatus); `ocspStaple` default empty | `inc-build.ps1 test tls` PASS: handshake 16, TLS 9 |
| 2026-08-16 | **Vec** C++ KATs + decode/decrypt for current D: TLS 1.2 msgs (`CertificateStatus`), HKDF-label, RFC3394, Base64, POLYVAL, RFC6979, FPE, CryptoBox raw, SPAKE2+ custom, pad, bcrypt `$2b$`/`$2y`/72-byte, passhash9, ECDH, ECDSA/DSA verify, RSA-PSS, ElGamal decrypt | `inc-build.ps1 test tls` PASS (alert 6, HR 2, HV 5, NST 5, CV 4, CS 5, hkdf_label 4); codec/mode/bcrypt/fpe PASS (base64 22+9, pad, bcrypt 93); ecdh 156, rsa_pss 88, dsa_vfy 2, elgamal dec 16+6; ecdsa_vfy 27/31 (4 C++-3 edge cases logged) |
| 2026-08-16 | **Vec/mem** `checkMemutilsRepeat` on new families; Unique-wrap SPAKE2+ params/secret/record/prover/verifier + Polyval + pad methods | `inc-build.ps1 test` tls/codec/spake2p/rfc3394/fpe/cryptobox/rfc6979/bcrypt + tls/ecdh/ecdsa/dsa/rsa/elgamal/mode/aead/passhash9 PASS; no new DebugAllocator growth (1.2 handshake still +548 B) |
| 2026-08-16 | **Vec** ECDSA/DSA RFC6979 verify-only; invalid EC points; ECC base-point mul; SRP-6a with explicit `a`/`b` + Unique leak probe | `inc-build.ps1 test ecdsa,dsa,srp6` PASS: RFC6979 104+21, invalid 48, base-mul all named groups, SRP6a 50; CryptoSafe 0; ecdsa_vfy still 4/31 logged |
| 2026-08-16 | **Vec** SIV multi-AD (`setAssociatedDataN` on `AEADMode`, gap = empty-AD MAC) + charset UCS-2/UCS-4/UTF-8 | `inc-build.ps1 test aead,charset` PASS: siv_ad 5 + decrypt + gapped AD; charset 53 (4+11+1+11+13+10+3) |
| 2026-08-16 | **Vec** `CMAC.polyDouble` 24/128-byte reductions + `poly_dbl.vec` | `inc-build.ps1 test mac` PASS: PolyDbl 82 |
| 2026-08-16 | **Vec** salted Blowfish EKS + C++ `bn/*.vec`; `gcd(0,n)=|n|`; `BigInt-` sign on equal mag; `isPrime` table without sentinel 0 | `inc-build.ps1 test block` PASS: salted 11; `bigint` PASS: add 78 sub 77 mul 104 sqr 21 div 792 mod 80 lsh 51 rsh 54 powmod 48 gcd 182 jacobi 698 prime 25+107 invmod 138 cmp 19 |
| 2026-08-16 | **Vec** `isPerfectSquare` + `fromRadixDigits` + TSS recovery; reconstruct no longer `hash.release()` before use | `inc-build.ps1 test bigint` PASS: square 7, ressol 17 (large leftover), radix 60+9; `tss` PASS: recovery 3+1, split 2 |
| 2026-08-16 | **Vec** `readKv` (C++ `read_kv`) + OCB long from `ocb_long.vec` | `inc-build.ps1 test parsing,ocb` PASS: read_kv 7+9, OCBLong 9 |
| 2026-08-16 | **Vec** strict IPv4 (`tryStringToIpv4`, no leading zeros) + canonical IPv4 CIDR | `inc-build.ps1 test parsing` PASS: ipv4 13+34, subnet 6+13 |
| 2026-08-16 | **Vec** IPv6 (RFC 4291/5952) + IPv6 CIDR + DNS name / SAN wildcard + RFC 6125 host match | `inc-build.ps1 test parsing` PASS: ipv6 15+35, v6subnet 7+18, dns 23+4+47, wildcards 24+34 |
| 2026-08-16 | **Vec** non-canonical IPv6 (`ipv6_nc.vec`) + contiguous CIDR mask check (`general_name_ip.vec`) | `inc-build.ps1 test parsing` PASS: ipv6_nc 23, IP mask 12+7 |
| 2026-08-16 | **Vec** TLS CBC+HMAC AEAD (`tls_cbc.d`): Unique-null ctor fix; `tls_cbc_kat.vec` enc/dec; `tls_cbc.vec` Valid via ZeroMac+noop | `inc-build.ps1 test tls` PASS: AES-128/HMAC-SHA-256 6, 3DES/HMAC-SHA-1 4, Valid 10, padding 22 |
| 2026-08-16 | **Vec** NIST hash Monte Carlo (`hash_mc.vec`) + 1 MiB long-rep (`hash_rep.vec`; skip 1 GiB) | `inc-build.ps1 test hash` PASS: MC SHA-1/224/256/384/512; SHA-512-224 leftover (C++ also lacks it); long-rep SHA-1/2/3 1 MiB |
| 2026-08-16 | **Vec** `CalendarPoint` (`dates.vec`) + SHA-512-256 (FIPS IVs) + `X509_DN` RFC 4514 parse | `inc-build.ps1 test calendar,hash,asn1` PASS: dates 9+3+4; SHA-512-256 MC; DN valid 19 DER + invalid 23 |
| 2026-08-16 | **Vec** C++ 3 `randomInteger` + `bn/random.vec`; TSS `Hash=None`/`SHA-1` generation; X.500 DN order | `inc-build.ps1 test bigint,tss,asn1` PASS: random 4; TSS gen 6 + recovery 3+1; DN order Equal 18 + Unequal 11 |
| 2026-08-16 | **Vec** RFC 4514 `X509_DN.toString` + BER `requireDer` (bool/int) + `asn1_decoding.vec` walker | `inc-build.ps1 test asn1` PASS: DN valid 19 (toString) + invalid 23; decoding 58 |
| 2026-08-16 | **Vec** BER/DER Limits: long-form tag, EOC, indefinite, 128 MiB cap, OID consume, BIT STRING pad | `inc-build.ps1 test asn1,x509` PASS: decoding 58; OID 19+15; NIST path 74 |
| 2026-08-16 | **Vec** OCB wide-block: toy cipher + `ocb_wide.vec` / `ocb_wide_long.vec`; ctor 16/24/32/64; MASKLEN/stretch | `inc-build.ps1 test ocb` PASS: OCBLong 9, OCBWide 10, Toy128/192/256/512 + SHACAL2 |
| 2026-08-16 | **Vec** `ASN1PrettyPrinter` + `asn1_print/` 8 DER/txt; indefinite BER strips EOC from value | `inc-build.ps1 test asn1,x509` PASS: print 8; decoding 58; OID 19+15; NIST path 74 |
| 2026-08-16 | **K1** Argon2 PHC (`generateArgon2Pwhash` / `checkArgon2Pwhash`); `version(Argon2_Fmt)` | `inc-build.ps1 test argon2fmt` PASS: Verify 3 + Generate 3 |
| 2026-08-16 | **Vec** TLS extension parse KATs (ALPN RFC 7301, groups, sig_algs_cert, SV, cookie, key_share) | `inc-build.ps1 test tls` PASS: alpn 6, groups 6, sig_algs_cert 5, SV 2, cookie 8, KS 4+2+2; hello 16+8 |
| 2026-08-16 | **Vec** ECDSA key recovery (SEC 1 `v` + compressed lift; `recoveryParam`) | `inc-build.ps1 test ecdsa` PASS: Recovery 2 (secp256k1 + secp256r1) |
| 2026-08-16 | **Vec** PKCS8 unencrypted BER PrivateKeyInfo (was leftover Tag INTEGER vs SEQUENCE) | `inc-build.ps1 test ecdsa` PASS: KeyEncoding 1 (short secp521r1) |
| 2026-08-16 | **T12n** Lucky13 extra HMAC compressions on TLS CBC MtE fail; CT pad walk; `TLS_NULL` HMAC AEAD (`full` only) | `inc-build.ps1 test tls` PASS: TLS_NULL 3+InvalidMAC 1+bad AD 1; AES-128/HMAC-SHA-256 6, 3DES/HMAC-SHA-1 4, Valid 10, padding 22; hello 16+8; handshake 16; TLS 9; ext parse all green |
| 2026-08-16 | **C8 / XofA / T13f** ZFEC + AES-256/CTR XOF + dummy CCS/KeyUpdate | `inc-build.ps1 test "zfec,xof,tls"` PASS: ZFEC 81; CTR-BE(AES-256) 27 (xof 3393); hello 16+8; handshake 16; TLS 9; KeyUpdate parse + traffic-upd roundtrip |
| 2026-08-16 | **C1** PKCS#12 parse (RFC 7292 + OpenSSL empty-pwd MAC/PBE); `version(PKCS12)` | `inc-build.ps1 test pkcs12` PASS: fixture parse + nesting/version/enveloped/unknown-bag/wrong-password/RC2 negatives |
| 2026-08-16 | **C1** PKCS#12 export (`PKCS12ExportOptions` modern/legacyCompat + `exportTo`); PBE-SHA1-3DES + PBES2 | `inc-build.ps1 test pkcs12` PASS: 54 (parse fixtures + export roundtrip/legacy/PBES2/empty-pw/no-mac/key-only/cert-only/mismatch/iter) |
| 2026-08-16 | **P9b** FIPS 205 SLH-DSA SHA2-128/192/256 s/f (compressed ADRS, SHA-256/512 F/H/T, HMAC PRF_msg, MGF1 H_msg) | `inc-build.ps1 test slh_dsa` PASS: pairwise SHAKE+SHA2 128f; generic SHAKE-128s 2; HashSigDet SHAKE+SHA2 128f; OIDs 20–31 |
| 2026-08-16 | **P11** FrodoKEM SHAKE-640/976/1344 + eFrodo; `version(FrodoKEM)` (asserts PUBKEY+SHAKE_XOF) | `inc-build.ps1 test frodo` PASS: pairwise 6 + implicit reject + factory/OID + SK reload |
| 2026-08-16 | **P12** XMSS RFC 8391 / SP 800-208 verify-only (21 param OIDs); `version(XMSS)` (asserts PUBKEY+SHA2_32+SHA2_64+Truncated_Hash+Shake); no keygen/sign/HSS-LMS | `inc-build.ps1 test xmss` PASS: verify 63 + invalid 336 + factory/OID/PKVerifier + leftovers 0 |
| 2026-08-16 | **P11b** FrodoKEM AES-A 640/976/1344 + eFrodo (AES-128-ECB matrix-A) | `inc-build.ps1 test frodo` PASS: pairwise 12 (SHAKE+AES) + implicit reject + factory/OID |
| 2026-08-16 | **P9c** HashSLH-DSA pre-hash (`0x01‖ctx‖PH.OID‖PH(M)`) SHA-256/512/SHAKE-128/256 | `inc-build.ps1 test slh_dsa` PASS: HashSLH pairwise SHA-256 + SHAKE-256; not accepted as pure SLH |
| 2026-08-16 | **P12b** XMSS keygen+sign (NIST SP 800-208 + Botan2x WOTS derivation; no BDS) | `inc-build.ps1 test xmss` PASS: sign SHA2_10_256 (incl. legacy) + keygen SHA2_10_256 + verify 63 + invalid 336 |
| 2026-08-16 | **P12c** HSS-LMS RFC 8554 verify-only; `version(HSS_LMS)` | `inc-build.ps1 test hss` PASS: verify 5 + invalid 4 + leftover 0 |
| 2026-08-16 | **P12d** HSS-LMS keygen+sign (SECRET_METHOD 2; no BDS; auth path recomputed) | `inc-build.ps1 test hss` PASS: sign 2 + verify 5 + invalid 4 |
| 2026-08-16 | **P14** SPHINCS+ r3.1 (empty H_msg/PRF_msg prefix; FORS LSB-first) on `slh_dsa.d`; names `SphincsPlus-{shake,sha2}-{128,192,256}{s,f}-r3.1`; OIDs `1.3.6.1.4.1.25258.1.12.{1,2}.{1–6}` | `inc-build.ps1 test slh_dsa` PASS: SPHINCS+ pairwise shake+sha2 128f; HashSigRand 128f both; SLH generic 2 + HashSigDet 12 |
| 2026-08-16 | **P10** Classic McEliece NIST+ISO (Goppa/Benes/GE; all 16 names); `version(Classic_McEliece)` (asserts PUBKEY+SHAKE_XOF); OIDs `1.3.6.1.4.1.22554.5.1.{1–10}` + pc `25258.1.18.{1–6}` | `inc-build.ps1 test cmce` PASS: GF/PRG/minpoly/mul; hashed KAT 348864 + 348864f (SHAKE-256(512) PK/SK + SS/CT) |
| 2026-08-17 | **P11c** FrodoKEM CTR_DRBG KATs (`frodokem_kat.vec`; SHAKE-256(128) of PK/SK/CT; SS raw) | `inc-build.ps1 test frodo` PASS: 640 all 25×4 + first of each 976/1344 (8); pairwise 12 |
| 2026-08-17 | **R3** `Processor_RNG` (x86 RDRAND; 10 retries; not AutoSeeded default) | `inc-build.ps1 test processor_rng` PASS: available, name rdrand, 0–127-byte randomize, two 32-byte buffers differ |
| 2026-08-17 | **R4** `Entropy_Rdseed` + `Entropy_Getentropy` (RDSEED mixed, 0 claimed bits; getentropy POSIX 256 B / Windows no-op) | `inc-build.ps1 test rdseed,getentropy` PASS: name + poll |
| 2026-08-17 | **Hsh leftover** SCAN `SHA-512/256` → `SHA-512-256`; CoreEngine `SHA-512/256`; C++ empty + "message digest" KATs | `inc-build.ps1 test hash` PASS: sha2_64_scan 3 + SHA-512-256 2 |
| 2026-08-17 | **Re-val** focused families after RFC 3779 work. Combined multi-focus AV (LDC). TLS 1.2 leftover 548 B still logged not failed. | `inc-build test x509` PASS; `tls,rsa,ecdsa,roughtime,asn1,x509_key` each PASS |
| 2026-08-17 | **Vec-impl** Roughtime (C++ 2019 Nuno Goncalves): `encodeRequest` 1024-byte NONC/PAD; `fromBits` CERT/DELE/SIG/SREP Merkle SHA-512; `nonceFromBlind` SHA-512(SHA-512(prev)‖blind); Chain + `serversFromStr`. `version(Roughtime)` on `full` (asserts Ed25519+SHA2_64). No online UDP. | `inc-build.ps1 test roughtime` PASS: request 1+1; response Invalid 14 + Valid 3; nonce_from_blind 1+1; chain/servers unit; CryptoSafe 0 / Lockless 0 |
| 2026-08-17 | **Vec-impl** C++ `generate_rsa_prime` (`p≡3 (mod 4)`, step 4, MR [2,n)); `version(RSA_Insecure)` on dub `full`; NUMS `numsp512d1` (OID `1.3.6.1.4.1.25258.4.3`, SSWU Z=−4). | `inc-build.ps1 test rsa,ecdsa,spake2p` PASS: rsa_keygen 1024; h2s numsp 2; SSWU-RO/NU numsp 5+5; ecc var-mul 95; SPAKE2+ custom 27; CryptoSafe 0 |
| 2026-08-17 | **Vec-impl** `createPrivateKey` factory + `api_sign`; TLS 1.3 ClientHello `key_share` generation (x25519, secp256r1, RFC 7919 ffdhe2048); `PSS`/`EMSA1(hash)` EMSA aliases. | `inc-build.ps1 test tls,x509_key` PASS: key_share_CH_offers 11; api_sign 14 (Dilithium/DSA/ECDSA/ECGDSA/ECKCDSA/Ed25519/GOST/HSS/RSA/SM2/SLH/XMSS) |
| 2026-08-17 | **Vec-impl** RFC 9380 `EC_Scalar::hash` + SSWU hash-to-curve; RFC 9258 PSK importer; SPHINCS+ FORS/WOTS runners on existing `forsSign`/`wotsSignAndPkgen`. | `inc-build.ps1 test ecdsa,slh_dsa,tls` PASS: h2s 16; SSWU-RO/NU 73; psk_import 6; FORS 12 + WOTS 12; ECDSA CAVS 251 still green |
| 2026-08-17 | **Vec-impl** CAVS + DSA paramgen + EC PKCS#8: `k.randomize(..., false)`; `generateDsaPrimes` SHA-1+offset; EC domain from alg_id and/or inner OID; PKCS#8 named-curve + public point. | `inc-build.ps1 test ecdsa,dsa,ecdh,bigint` PASS: ECDSA CAVS 251 + keygen 3; DSA CAVS 302; dsa_gen 20; ecc-key-and-param 5 |
| 2026-08-17 | **Vec-migrate** wire leftover C++ KATs: ML-DSA/Dilithium Randomized; `kyber_encodings` (expanded SK + coeff range); `cmce_negative`; RSA-KEM ISO-18033-2. Copy h2c/dsa_prob/ecdsa_keygen. Licenses from C++ counterparts. | `inc-build.ps1 test ml_kem,ml_dsa,cmce,rsa` PASS: encodings 15; ML-DSA Rand 75; Dilithium Rand 600; cmce_negative 2; RSA-KEM 10; allocator 0 B |
| 2026-08-17 | **Vec-fix** C++ `ml_kem.vec` + `ml-dsa-*_Deterministic.vec`: fire hashed KEM on last field `SS_N`; HashSk = SHA-3-256 of 32-byte seed ξ (C++ `private_key_bits()`). | `inc-build.ps1 test ml_kem,ml_dsa` PASS: ACVP 150 + hashed ML-KEM 75 + Kyber R3/90s 150; verify 221 + Dilithium 14 + ML-DSA Deterministic 75 |
| 2026-08-17 | **T5** `ChaCha_AVX2` x8 (LDC `int8` + shufflevector transpose); refill prefers AVX2 then two SSE2 x4; this host has no AVX2 so pairwise 0 | `inc-build.ps1 test stream` PASS: chacha_avx2 0 + chacha_sse2 3 + ChaCha(8/12/20) 20+2+10 |
| 2026-08-17 | **T5** `Camellia_HWAES` AES-NI S-boxes + affine S1–S4 + 2-way 18/24-round; CPUID AES-NI+SSSE3 | `inc-build.ps1 test block` PASS: camellia_hwaes 9 + Camellia-128/192/256 6+3+5 |
| 2026-08-17 | **T5** `SHA2_32_X86` Intel SHA-NI SHA-224/256; SIMDEngine prefers SHA-NI over SSE2; this host has no SHA-NI so pairwise 0, family vectors via SSE2 | `inc-build.ps1 test hash` PASS: sha2_32_x86 0 (no SHA-NI) + sha2_32_sse2 6 + SHA-256 262 + SHA-224 2 |
| 2026-08-17 | **P1/P3 leftover** Ed25519ph (RFC 8032 SHA-512 + dom2) + hashed SHA-256; Ed448ph / SHAKE-256(512); `PKSigner(key,"Ed25519ph")` | `inc-build.ps1 test ed25519,ed448` PASS: Ed25519ph 1 + SHA-256 1 + Pure 709; Ed448ph 1 + SHAKE-256(512) 1 + Pure 87 |
| 2026-08-19 | **TLS 1.3 OpenSSL GET** Root cause was **release `donna128 *` dropping `h`** (assert `h==0` stripped in `-b release`). X25519 SS started `0000000000000000…`; OpenSSL/curl failed EE (bad MAC); Node sent a 19-byte encrypted alert. Fix: full `(h:l)*y`. Also: C++-style one-direction rekey, SH record `0x0303`, unprotected Alert until client Finished, SSLKEYLOGFILE. curl/bun GET **200**. `DonnaLdcX64` stays off. | `donna128.d` / `cipher_state.d` / `server.d` / `client.d` / `record_layer.d` / `channel.d` |
| 2026-08-19 | **T13d** HS→app keys one direction at a time (`deriveWriteTrafficKey` / `deriveReadTrafficKey`, C++ `derive_{write,read}_traffic_key`). Do not replace `Unique!TLS13CipherState` after the first install (that reset the other seq and could drop the third CS). Server accepts unprotected Alert until client Finished. Node/OpenSSL GET GCM-fail was the bench blocker. | `cipher_state.d` / `server.d` / `client.d` / `record_layer.d` |
| 2026-08-19 | **P-256 Solinas** `CurveGFpP256` (Botan 1.11 `redc_p256` / SP 800-186 G.1.2) in `chooseRepr` by limb match. Identity rep + `comba_mul4`/`sqr4` + in-place 512-bit redc (no Montgomery; no `normalize`/`swapReg` on the mul/sqr hot path). Extra-limb `normalize` for other curves. P-521 stays Montgomery (`matchesPrime` ready, not selected). `DonnaLdcX64` still off. | ECDSA+EC PASS (Group 11864, ECC 6415). Callgrind 16 HS Ir **2.05e8 → 2.89e7**; monty_redc/cios4 gone; first Solinas still had `normalize` 58% incl. WSL 8×bun TLS1.3 no-ticket after in-place: ossl **594** / botan **256** RPS (0.43×, 0 err) `bench-ecdsa-hs-wsl-2026-08-19T14-29-03-494Z.json`. Cross-host RPS is noisy (ossl 941→748→594). Next: SHA-256 SSE2, X25519 `fmul`. |
| 2026-08-17 | **T13p leftover** libOQS eFrodo 0xFE00–0xFE0F (pure + x25519/x448/secp256/384/521 hybrids; classical-first concat); `offerTls13PqcExtraGroup()` | `inc-build.ps1 test tls` PASS: tls13_handshake 32 + TLS 9 |
| 2026-08-17 | **T5** `ARIA_HWAES` AES-NI S1/X1 + affine S2/X2 + FO/FE 4-way; CPUID AES-NI+SSSE3 | `inc-build.ps1 test block` PASS: aria_hwaes 9 + ARIA-128/192/256 3 each |
| 2026-08-17 | **T5** `SM4_HWAES` AES-NI S-box + affine nibble tables + 4-way encrypt/decrypt; CPUID AES-NI+SSSE3 | `inc-build.ps1 test block` PASS: sm4_hwaes 3 + SM4 22 |
| 2026-08-17 | **T5** `ChaCha_SIMD` SSE2 x4 extracted from `chacha.d` to `chacha_sse2.d`; `constants.d` not raw `version(SIMD_SSE2)` | `inc-build.ps1 test stream` PASS: chacha_sse2 3 + ChaCha(8) 20 + (12) 2 + (20) 10 |
| 2026-08-17 | **T5** `SHA2_32_SSE2` SHA-224/256 SSE2 message expansion; SIMDEngine; same SHA-2 vectors | `inc-build.ps1 test hash` PASS: sha2_32_sse2 6 + SHA-256 262 + SHA-224 2 |
| 2026-08-17 | **T13p leftover** SecP256r1MLKEM768 `0x11EB` + SecP384r1MLKEM1024 `0x11ED` (ECDH first) + pure ML-KEM-512/768/1024 `0x0200`/`01`/`02` | `inc-build.ps1 test tls` PASS: tls13_handshake 26 + TLS 9 |
| 2026-08-17 | **T13p** `TLS_13_PQC` X25519MLKEM768 IANA 0x11EC; CH 1216 / SH 1120 concat; SS concat into HKDF; `offerTls13PqcHybrid()` default false | `inc-build.ps1 test tls` PASS: tls13_handshake 20 + TLS 9 (1.3 still x25519 unless policy offers hybrid) + key_share KATs |
| 2026-08-17 | **S8** portable AES bitslice (native word: 32-bit 2 blocks, 64-bit 4); T-tables removed; AES-NI/SSSE3 engines unchanged. | `inc-build.ps1 test block` PASS: AES-128 385 + AES-192 449 + AES-256 513 |
| 2026-08-17 | **P10** Classic McEliece hashed KATs all 16 (CTR_DRBG encaps is one generate per attempt, not one bulk dump). | `inc-build.ps1 test cmce` PASS: 348864/f + 460896/f + 6688/6960/8192 ±f ±pc |
| 2026-08-17 | **leftovers** Dilithium-AES (`Dilithium-{4x4,6x5,8x7}-AES-r3`); CMCE hashed KAT +460896/f. | `ml_dsa` PASS: AES 5+1+1 + R3 5+1+1 + verify 221; `cmce` PASS 348864/f + 460896/f (6688+ encaps leftover) |
| 2026-08-17 | **leftovers** Kyber-90s (`Kyber-{512,768,1024}-90s-r3`); remaining Kyber R3 + Frodo KATs 25/instance; POWER DARN; S2 nest 16; S3 NameConstraints structure. S8 read (T-table AES). | `ml_kem` PASS: ACVP 150 + R3 75 + 90s 75; `frodo` PASS 12×25; `processor_rng` PASS 6; `asn1` PASS S2 2; `x509` PASS NIST 74 + S3 |
| 2026-08-17 | **P14** Dilithium R3 modern (`Dilithium-{4x4,6x5,8x7}-r3`) on `ml_dsa.d`; tr=32; G(ξ); μ=H(tr‖M); det ρ'=H(K‖μ); expanded SK; OIDs `25258.1.9.{1,2,3}`. Not AES. | `inc-build.ps1 test ml_dsa` PASS: pairwise 3 R3 + mutate; factory/OID; hashed KAT 4x4-r3 5 + 6x5/8x7 first; ML-DSA verify 221 still green |
| 2026-08-17 | **P14** Kyber R3 modern (`Kyber-{512,768,1024}-r3`) on `ml_kem.d`; G(d) no k; m=H(seed); SS=SHAKE-256(K̄‖H(c)); expanded SK for KATs. Not 90s. | `inc-build.ps1 test ml_kem` PASS: pairwise 512-r3; hashed KAT 512-r3 5 + 768/1024 first; ML-KEM ACVP 150 still green |
| 2026-08-16 | **P13** Hybrid-ML-KEM-768-X25519; SHA-3-256 combiner; `version(Hybrid_KEM)` | `inc-build.ps1 test hybrid` PASS: pairwise + mutate reject + factory/OID |
| 2026-08-16 | **V1** vibe.0 `createTLSContext(tls1_3)` → `BotanTLSContext` + `defaultProtocolOffer = TLS_V13` | delegates unchanged; OpenSSL still available via factory |
| 2026-08-16 | **P7** FIPS 203 ML-KEM-512/768/1024; `version(ML_KEM)` (asserts PUBKEY+SHA3+SHAKE_XOF); OIDs `2.16.840.1.101.3.4.4.{1,2,3}` | `inc-build.ps1 test ml_kem` PASS: pairwise 3 + implicit reject; ACVP keygen 25+25+25; ACVP encap 25+25+25; factory seed/OID |
| 2026-08-16 | **P8** FIPS 204 ML-DSA-4x4/6x5/8x7; `version(ML_DSA)` (asserts PUBKEY+SHAKE_XOF); OIDs `2.16.840.1.101.3.4.3.{17,18,19}` | `inc-build.ps1 test ml_dsa` PASS: pairwise 3 + mutate reject; verify KATs 221; factory seed/OID |
| 2026-08-16 | **P9** FIPS 205 SLH-DSA SHAKE-128/192/256 s/f; `version(SLH_DSA)` (asserts PUBKEY+SHAKE_XOF); OIDs `2.16.840.1.101.3.4.3.{26–31}` | `inc-build.ps1 test slh_dsa` PASS: pairwise 128f; generic sign/verify 2 (128s det+rand); HashSigDet 128f; factory/OID |
