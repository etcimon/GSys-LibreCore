// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RISC-V ASM IR for Botan-shaped TLS primitives (RSA limb mul, HMAC xor).

#![allow(missing_docs)]

use crate::encode::{A0, A1, A2, RA, T0, T1, X0};
use crate::{Module, Node, Op, Purpose};

/// Procedural crypto leaves: HMAC xor, RSA limb `mul`, ECDSA add.
pub fn lib(tls: &g6b_spec::Tls) -> Module {
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
    m
}
