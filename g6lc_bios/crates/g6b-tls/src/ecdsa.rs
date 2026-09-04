// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! ECDSA P-256 SHA-256 verify. Spec: Botan `pubkey/ecdsa` / secp256r1.
//! Affine I/O, Jacobian arithmetic (one inverse at the end).

#![allow(missing_docs)]

use crate::bigint::BigUint;
use crate::sha::sha256;

fn p() -> BigUint {
    BigUint::from_be_bytes(&hex32(
        "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF",
    ))
}
fn n() -> BigUint {
    BigUint::from_be_bytes(&hex32(
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551",
    ))
}
fn gx() -> BigUint {
    BigUint::from_be_bytes(&hex32(
        "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296",
    ))
}
fn gy() -> BigUint {
    BigUint::from_be_bytes(&hex32(
        "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5",
    ))
}

fn hex32(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn modp(x: &BigUint) -> BigUint {
    x.modulo(&p())
}

fn addp(a: &BigUint, b: &BigUint) -> BigUint {
    modp(&a.add(b))
}

fn subp(a: &BigUint, b: &BigUint) -> BigUint {
    if a.cmp(b) == core::cmp::Ordering::Less {
        p().sub(&b.sub(a))
    } else {
        a.sub(b)
    }
}

fn mulp(a: &BigUint, b: &BigUint) -> BigUint {
    modp(&a.mul(b))
}

fn three() -> BigUint {
    BigUint::from_u32(3)
}

/// Jacobian (X : Y : Z); Z = 0 is the point at infinity. a = -3.
#[derive(Clone)]
struct J {
    x: BigUint,
    y: BigUint,
    z: BigUint,
}

fn j_inf() -> J {
    J {
        x: BigUint::zero(),
        y: BigUint::from_u32(1),
        z: BigUint::zero(),
    }
}

fn is_inf(pt: &J) -> bool {
    pt.z.is_zero()
}

fn from_aff(x: BigUint, y: BigUint) -> J {
    J {
        x,
        y,
        z: BigUint::from_u32(1),
    }
}

fn to_aff(pt: &J) -> Option<(BigUint, BigUint)> {
    if is_inf(pt) {
        return None;
    }
    let zi = pt.z.modinv_prime(&p());
    let zi2 = mulp(&zi, &zi);
    let zi3 = mulp(&zi2, &zi);
    Some((mulp(&pt.x, &zi2), mulp(&pt.y, &zi3)))
}

/// dbl-2001-b (EFD shortw Jacobian a=-3).
fn jdouble(pt: &J) -> J {
    if is_inf(pt) || pt.y.is_zero() {
        return j_inf();
    }
    let delta = mulp(&pt.z, &pt.z);
    let gamma = mulp(&pt.y, &pt.y);
    let beta = mulp(&pt.x, &gamma);
    let alpha = mulp(&three(), &mulp(&subp(&pt.x, &delta), &addp(&pt.x, &delta)));
    let eight = BigUint::from_u32(8);
    let four = BigUint::from_u32(4);
    let x3 = subp(&mulp(&alpha, &alpha), &mulp(&eight, &beta));
    let yz = addp(&pt.y, &pt.z);
    let z3 = subp(&subp(&mulp(&yz, &yz), &gamma), &delta);
    let y3 = subp(
        &mulp(&alpha, &subp(&mulp(&four, &beta), &x3)),
        &mulp(&eight, &mulp(&gamma, &gamma)),
    );
    J {
        x: x3,
        y: y3,
        z: z3,
    }
}

/// add-2007-bl (EFD shortw Jacobian a=-3).
fn jadd(p1: &J, p2: &J) -> J {
    if is_inf(p1) {
        return p2.clone();
    }
    if is_inf(p2) {
        return p1.clone();
    }
    let z1z1 = mulp(&p1.z, &p1.z);
    let z2z2 = mulp(&p2.z, &p2.z);
    let u1 = mulp(&p1.x, &z2z2);
    let u2 = mulp(&p2.x, &z1z1);
    let s1 = mulp(&p1.y, &mulp(&p2.z, &z2z2));
    let s2 = mulp(&p2.y, &mulp(&p1.z, &z1z1));
    let h = subp(&u2, &u1);
    let r0 = subp(&s2, &s1);
    if h.is_zero() {
        if r0.is_zero() {
            return jdouble(p1);
        }
        return j_inf();
    }
    let r = addp(&r0, &r0);
    let hh = addp(&h, &h);
    let i = mulp(&hh, &hh);
    let j = mulp(&h, &i);
    let v = mulp(&u1, &i);
    let x3 = subp(&subp(&mulp(&r, &r), &j), &addp(&v, &v));
    let y3 = subp(
        &mulp(&r, &subp(&v, &x3)),
        &addp(&mulp(&s1, &j), &mulp(&s1, &j)),
    );
    let zsum = addp(&p1.z, &p2.z);
    let z3 = mulp(&subp(&subp(&mulp(&zsum, &zsum), &z1z1), &z2z2), &h);
    J {
        x: x3,
        y: y3,
        z: z3,
    }
}

fn jmul(k: &BigUint, pt: &J) -> J {
    let mut r = j_inf();
    let mut q = pt.clone();
    for i in 0..k.bit_len() {
        if k.bit(i) {
            r = jadd(&r, &q);
        }
        q = jdouble(&q);
    }
    r
}

/// Uncompressed P-256 public key (x‖y, 64 bytes) + (r,s).
pub fn ecdsa_p256_sha256_verify(qx: &[u8], qy: &[u8], msg: &[u8], r: &[u8], s: &[u8]) -> bool {
    let nn = n();
    let rr = BigUint::from_be_bytes(r);
    let ss = BigUint::from_be_bytes(s);
    if rr.is_zero()
        || ss.is_zero()
        || rr.cmp(&nn) != core::cmp::Ordering::Less
        || ss.cmp(&nn) != core::cmp::Ordering::Less
    {
        return false;
    }
    let e = BigUint::from_be_bytes(&sha256(msg));
    let w = ss.modinv_prime(&nn);
    let u1 = e.mul(&w).modulo(&nn);
    let u2 = rr.mul(&w).modulo(&nn);
    let g = from_aff(gx(), gy());
    let q = from_aff(BigUint::from_be_bytes(qx), BigUint::from_be_bytes(qy));
    let x = jadd(&jmul(&u1, &g), &jmul(&u2, &q));
    match to_aff(&x) {
        Some((xx, _)) => xx.modulo(&nn).cmp(&rr) == core::cmp::Ordering::Equal,
        None => false,
    }
}

#[cfg(test)]
pub fn rfc6979_p256_pub() -> ([u8; 32], [u8; 32]) {
    let ux = hex32("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6");
    let uy = hex32("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299");
    let mut x = [0u8; 32];
    let mut y = [0u8; 32];
    x.copy_from_slice(&ux);
    y.copy_from_slice(&uy);
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn double_generator() {
        let g = from_aff(gx(), gy());
        let d = jdouble(&g);
        let (x, y) = to_aff(&d).expect("2G");
        assert_eq!(
            x.to_be_bytes(32),
            hex32("7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978")
        );
        assert_eq!(
            y.to_be_bytes(32),
            hex32("07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1")
        );
    }

    #[test]
    fn add_g_plus_2g() {
        let g = from_aff(gx(), gy());
        let g2 = jdouble(&g);
        let g3 = jadd(&g, &g2);
        let (x, y) = to_aff(&g3).expect("3G");
        assert_eq!(
            x.to_be_bytes(32),
            hex32("5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C")
        );
        assert_eq!(
            y.to_be_bytes(32),
            hex32("8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032")
        );
    }
}
