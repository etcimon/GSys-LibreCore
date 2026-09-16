// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RISC-V ASM IR for Botan-shaped TLS primitives (RSA limb mul, HMAC xor).

#![allow(missing_docs)]

use crate::encode::{
    A0, A1, A2, RA, T0, T1, T2, T3, T4, VIO_DEV_RNG, VIO_MAGIC, VIO_MMIO_BASE, VIO_MMIO_SLOTS,
    VIO_MMIO_STEP, X0,
};
use crate::{Addr, Module, Node, Op, Purpose};
use g6b_spec::{ExtStatus, Isa, Tls};

fn leaf(purpose: Purpose, name: &str, comment: &str, body: Vec<Op>) -> Node {
    let mut ops = vec![
        Op::Comment(comment.into()),
        Op::Glob(name.into()),
        Op::Label(name.into()),
    ];
    ops.extend(body);
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node { purpose, ops }
}

/// RISC-V crypto IR. Zkne/Zknh/Zbkc only when BoardSpec says Live (CVA6: absent).
pub fn lib(tls: &Tls, isa: &Isa) -> Module {
    let mut m = Module::default();
    if !tls.enable {
        return m;
    }
    m.push(Node {
        purpose: Purpose::Hmac,
        ops: vec![
            Op::Comment("HMAC-SHA256 ipad/opad: xor key with 0x36 / 0x5c (Botan mac/hmac)".into()),
            Op::Glob("hmac_xor_pad".into()),
            Op::Label("hmac_xor_pad".into()),
            Op::Xor {
                rd: A0,
                rs1: A0,
                rs2: A1,
            },
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    });
    if tls.rsa {
        m.push(Node {
            purpose: Purpose::Rsa,
            ops: vec![
                Op::Comment("RSA modexp limb: mul a0, a1, a2  (PKCS#1 v1.5 SHA-256 verify)".into()),
                Op::Glob("rsa_limb_mul".into()),
                Op::Label("rsa_limb_mul".into()),
                Op::Mul {
                    rd: A0,
                    rs1: A1,
                    rs2: A2,
                },
                Op::Jalr {
                    rd: X0,
                    rs: RA,
                    imm: 0,
                },
            ],
        });
    }
    if tls.ecdsa {
        m.push(Node {
            purpose: Purpose::Ecdsa,
            ops: vec![
                Op::Comment("ECDSA P-256 point add: add t0, a0, a1 (field limb)".into()),
                Op::Glob("ecdsa_p256_add".into()),
                Op::Label("ecdsa_p256_add".into()),
                Op::Add {
                    rd: T0,
                    rs1: A0,
                    rs2: A1,
                },
                Op::Jalr {
                    rd: X0,
                    rs: RA,
                    imm: 0,
                },
            ],
        });
    }
    if tls.certificates {
        m.push(Node {
            purpose: Purpose::Cert,
            ops: vec![
                Op::Comment("X.509 DER length walk: lbu t1, 0(a0)".into()),
                Op::Glob("cert_der_len".into()),
                Op::Label("cert_der_len".into()),
                Op::Lbu {
                    rd: T1,
                    rs: A0,
                    off: 0,
                },
                Op::Jalr {
                    rd: X0,
                    rs: RA,
                    imm: 0,
                },
            ],
        });
    }
    if isa.xlen == 64 && tls.rsa {
        m.push(leaf(
            Purpose::Rsa,
            "rsa_limb_mulhu",
            "RV64M mulhu — high half of unsigned 64×64",
            vec![Op::Mulhu {
                rd: A0,
                rs1: A1,
                rs2: A2,
            }],
        ));
    }
    if isa.zkne == ExtStatus::Live && isa.xlen == 64 {
        m.push(leaf(
            Purpose::Tls,
            "aes64esm",
            "Zkne aes64esm — AES round with MixColumns (RV64)",
            vec![Op::Aes64esm {
                rd: A0,
                rs1: A0,
                rs2: A1,
            }],
        ));
        m.push(leaf(
            Purpose::Tls,
            "aes64es",
            "Zkne aes64es — final AES round",
            vec![Op::Aes64es {
                rd: A0,
                rs1: A0,
                rs2: A1,
            }],
        ));
        m.push(leaf(
            Purpose::Tls,
            "aes64ks1i",
            "Zkne aes64ks1i — key schedule SubWord/RotWord/Rcon",
            vec![Op::Aes64ks1i {
                rd: A0,
                rs: A0,
                rnum: 0,
            }],
        ));
        m.push(leaf(
            Purpose::Tls,
            "aes64ks2",
            "Zkne aes64ks2 — key schedule xor",
            vec![Op::Aes64ks2 {
                rd: A0,
                rs1: A0,
                rs2: A1,
            }],
        ));
    } else {
        m.push(Node {
            purpose: Purpose::Tls,
            ops: vec![Op::Comment(
                "AES-128 software (Zkne absent; CVA6 has no scalar crypto)".into(),
            )],
        });
    }
    if isa.zknh == ExtStatus::Live {
        m.push(leaf(
            Purpose::Hmac,
            "sha256sum0",
            "Zknh sha256sum0 — Σ0",
            vec![Op::Sha256sum0 { rd: A0, rs: A0 }],
        ));
        m.push(leaf(
            Purpose::Hmac,
            "sha256sum1",
            "Zknh sha256sum1 — Σ1",
            vec![Op::Sha256sum1 { rd: A0, rs: A0 }],
        ));
        m.push(leaf(
            Purpose::Hmac,
            "sha256sig0",
            "Zknh sha256sig0 — σ0",
            vec![Op::Sha256sig0 { rd: A0, rs: A0 }],
        ));
        m.push(leaf(
            Purpose::Hmac,
            "sha256sig1",
            "Zknh sha256sig1 — σ1",
            vec![Op::Sha256sig1 { rd: A0, rs: A0 }],
        ));
    }
    if isa.zbkc == ExtStatus::Live {
        m.push(leaf(
            Purpose::Tls,
            "ghash_clmul",
            "Zbkc clmul — GHASH carry-less product low",
            vec![Op::Clmul {
                rd: A0,
                rs1: A1,
                rs2: A2,
            }],
        ));
        m.push(leaf(
            Purpose::Tls,
            "ghash_clmulh",
            "Zbkc clmulh — GHASH carry-less product high",
            vec![Op::Clmulh {
                rd: A0,
                rs1: A1,
                rs2: A2,
            }],
        ));
    }
    m.push(vio_rng_probe());
    m
}

fn vio_rng_probe() -> Node {
    Node {
        purpose: Purpose::Tls,
        ops: vec![
            Op::Comment("virtio-rng DeviceID 4 slot scan (not a CSPRNG)".into()),
            Op::Glob("VioRngProbe".into()),
            Op::Label("VioRngProbe".into()),
            Op::La {
                rd: T0,
                addr: Addr::Abs(VIO_MMIO_BASE),
            },
            Op::Li {
                rd: T1,
                imm: VIO_MMIO_SLOTS,
            },
            Op::Li {
                rd: T4,
                imm: VIO_MMIO_STEP as i64,
            },
            Op::Label("vr_slot".into()),
            Op::Lw {
                rd: T2,
                rs: T0,
                off: 0,
            },
            Op::Li {
                rd: T3,
                imm: i64::from(VIO_MAGIC),
            },
            Op::Bne {
                rs1: T2,
                rs2: T3,
                to: "vr_next".into(),
            },
            Op::Lw {
                rd: T2,
                rs: T0,
                off: 8,
            },
            Op::Li {
                rd: T3,
                imm: i64::from(VIO_DEV_RNG),
            },
            Op::Beq {
                rs1: T2,
                rs2: T3,
                to: "vr_hit".into(),
            },
            Op::Label("vr_next".into()),
            Op::Add {
                rd: T0,
                rs1: T0,
                rs2: T4,
            },
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: -1,
            },
            Op::Bne {
                rs1: T1,
                rs2: X0,
                to: "vr_slot".into(),
            },
            Op::Li { rd: A0, imm: -1 },
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
            Op::Label("vr_hit".into()),
            Op::Li {
                rd: A0,
                imm: VIO_MMIO_SLOTS,
            },
            Op::Sub {
                rd: A0,
                rs1: A0,
                rs2: T1,
            },
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_spec::{ExtStatus, Isa, Tls};

    fn tls_on() -> Tls {
        Tls {
            enable: true,
            https: true,
            serve: false,
            rsa: true,
            ecdsa: true,
            certificates: true,
        }
    }

    #[test]
    fn cva6_default_has_no_zkne_insns() {
        let m = lib(&tls_on(), &Isa::default());
        let s = m.to_asm();
        assert!(s.contains("hmac_xor_pad"), "{s}");
        assert!(s.contains("rsa_limb_mulhu"), "{s}");
        assert!(s.contains("VioRngProbe"), "{s}");
        assert!(s.contains("Zkne absent"), "{s}");
        assert!(!s.contains("aes64es"), "{s}");
        assert!(!s.contains("\tclmul\t"), "{s}");
    }

    #[test]
    fn zk_live_emits_scalar_crypto() {
        let mut isa = Isa::default();
        isa.zkne = ExtStatus::Live;
        isa.zknh = ExtStatus::Live;
        isa.zbkc = ExtStatus::Live;
        let m = lib(&tls_on(), &isa);
        let s = m.to_asm();
        assert!(s.contains("aes64esm"), "{s}");
        assert!(s.contains("sha256sum0"), "{s}");
        assert!(s.contains("clmul"), "{s}");
        let (w, _) = m.to_words(0x8000_0000).unwrap();
        assert!(w.contains(&crate::encode::aes64es(10, 10, 11)));
        assert!(w.contains(&crate::encode::clmul(10, 11, 12)));
    }
}
