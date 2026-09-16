// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! X25519 (RFC 7748). Montgomery ladder on 51-bit limbs with mask cswap.
//! Field ops are fixed-width (not BigUint). Not a side-channel lab review.

#![allow(missing_docs)]

type Fe = [u64; 5];
const MASK: u64 = (1 << 51) - 1;
const TWO52M38: i128 = 0x000f_ffff_ffff_ffda;
const TWO52M2: i128 = 0x000f_ffff_ffff_fffe;

fn load_le_u64(b: &[u8]) -> u64 {
    let mut x = [0u8; 8];
    let n = b.len().min(8);
    x[..n].copy_from_slice(&b[..n]);
    u64::from_le_bytes(x)
}

fn fe0() -> Fe {
    [0; 5]
}

fn fe1() -> Fe {
    [1, 0, 0, 0, 0]
}

fn fe_frombytes(s: &[u8; 32]) -> Fe {
    [
        load_le_u64(&s[0..8]) & MASK,
        (load_le_u64(&s[6..14]) >> 3) & MASK,
        (load_le_u64(&s[12..20]) >> 6) & MASK,
        (load_le_u64(&s[19..27]) >> 1) & MASK,
        (load_le_u64(&s[24..32]) >> 12) & MASK,
    ]
}

fn carry(t: &mut [i128; 5]) -> Fe {
    t[1] += t[0] >> 51;
    t[0] &= MASK as i128;
    t[2] += t[1] >> 51;
    t[1] &= MASK as i128;
    t[3] += t[2] >> 51;
    t[2] &= MASK as i128;
    t[4] += t[3] >> 51;
    t[3] &= MASK as i128;
    t[0] += 19 * (t[4] >> 51);
    t[4] &= MASK as i128;
    t[1] += t[0] >> 51;
    t[0] &= MASK as i128;
    [
        t[0] as u64,
        t[1] as u64,
        t[2] as u64,
        t[3] as u64,
        t[4] as u64,
    ]
}

fn fe_add(a: &Fe, b: &Fe) -> Fe {
    let mut t = [0i128; 5];
    for i in 0..5 {
        t[i] = a[i] as i128 + b[i] as i128;
    }
    carry(&mut t)
}

fn fe_sub(a: &Fe, b: &Fe) -> Fe {
    let mut t = [0i128; 5];
    t[0] = a[0] as i128 + TWO52M38 - b[0] as i128;
    t[1] = a[1] as i128 + TWO52M2 - b[1] as i128;
    t[2] = a[2] as i128 + TWO52M2 - b[2] as i128;
    t[3] = a[3] as i128 + TWO52M2 - b[3] as i128;
    t[4] = a[4] as i128 + TWO52M2 - b[4] as i128;
    carry(&mut t)
}

fn fe_mul(a: &Fe, b: &Fe) -> Fe {
    let (a0, a1, a2, a3, a4) = (
        a[0] as i128,
        a[1] as i128,
        a[2] as i128,
        a[3] as i128,
        a[4] as i128,
    );
    let (b0, b1, b2, b3, b4) = (
        b[0] as i128,
        b[1] as i128,
        b[2] as i128,
        b[3] as i128,
        b[4] as i128,
    );
    let mut t = [0i128; 5];
    t[0] = a0 * b0 + 19 * a1 * b4 + 19 * a2 * b3 + 19 * a3 * b2 + 19 * a4 * b1;
    t[1] = a0 * b1 + a1 * b0 + 19 * a2 * b4 + 19 * a3 * b3 + 19 * a4 * b2;
    t[2] = a0 * b2 + a1 * b1 + a2 * b0 + 19 * a3 * b4 + 19 * a4 * b3;
    t[3] = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + 19 * a4 * b4;
    t[4] = a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0;
    carry(&mut t)
}

fn fe_sq(a: &Fe) -> Fe {
    fe_mul(a, a)
}

fn fe_mul_small(a: &Fe, k: u64) -> Fe {
    let mut t = [0i128; 5];
    for i in 0..5 {
        t[i] = (a[i] as i128) * (k as i128);
    }
    carry(&mut t)
}

fn fe_invert(z: &Fe) -> Fe {
    let mut t0 = fe_sq(z);
    let mut t1 = fe_sq(&fe_sq(&t0));
    t1 = fe_mul(z, &t1);
    t0 = fe_mul(&t0, &t1);
    let mut t2 = fe_sq(&t0);
    t1 = fe_mul(&t1, &t2);
    t2 = fe_sq(&t1);
    for _ in 1..5 {
        t2 = fe_sq(&t2);
    }
    t1 = fe_mul(&t2, &t1);
    t2 = fe_sq(&t1);
    for _ in 1..10 {
        t2 = fe_sq(&t2);
    }
    t2 = fe_mul(&t2, &t1);
    let mut t3 = fe_sq(&t2);
    for _ in 1..20 {
        t3 = fe_sq(&t3);
    }
    t2 = fe_mul(&t3, &t2);
    t2 = fe_sq(&t2);
    for _ in 1..10 {
        t2 = fe_sq(&t2);
    }
    t1 = fe_mul(&t2, &t1);
    t2 = fe_sq(&t1);
    for _ in 1..50 {
        t2 = fe_sq(&t2);
    }
    t2 = fe_mul(&t2, &t1);
    t3 = fe_sq(&t2);
    for _ in 1..100 {
        t3 = fe_sq(&t3);
    }
    t2 = fe_mul(&t3, &t2);
    t2 = fe_sq(&t2);
    for _ in 1..50 {
        t2 = fe_sq(&t2);
    }
    t1 = fe_mul(&t2, &t1);
    t1 = fe_sq(&t1);
    for _ in 1..5 {
        t1 = fe_sq(&t1);
    }
    fe_mul(&t1, &t0)
}

fn fe_tobytes(f: &Fe) -> [u8; 32] {
    let mut t = [
        f[0] as i128,
        f[1] as i128,
        f[2] as i128,
        f[3] as i128,
        f[4] as i128,
    ];
    for _ in 0..3 {
        t[1] += t[0] >> 51;
        t[0] &= MASK as i128;
        t[2] += t[1] >> 51;
        t[1] &= MASK as i128;
        t[3] += t[2] >> 51;
        t[2] &= MASK as i128;
        t[4] += t[3] >> 51;
        t[3] &= MASK as i128;
        t[0] += 19 * (t[4] >> 51);
        t[4] &= MASK as i128;
    }
    let mut q = (t[0] + 19) >> 51;
    q = (t[1] + q) >> 51;
    q = (t[2] + q) >> 51;
    q = (t[3] + q) >> 51;
    q = (t[4] + q) >> 51;
    t[0] += 19 * q;
    t[1] += t[0] >> 51;
    t[0] &= MASK as i128;
    t[2] += t[1] >> 51;
    t[1] &= MASK as i128;
    t[3] += t[2] >> 51;
    t[2] &= MASK as i128;
    t[4] += t[3] >> 51;
    t[3] &= MASK as i128;
    t[4] &= MASK as i128;
    let (t0, t1, t2, t3, t4) = (
        t[0] as u64,
        t[1] as u64,
        t[2] as u64,
        t[3] as u64,
        t[4] as u64,
    );
    let mut s = [0u8; 32];
    s[0] = t0 as u8;
    s[1] = (t0 >> 8) as u8;
    s[2] = (t0 >> 16) as u8;
    s[3] = (t0 >> 24) as u8;
    s[4] = (t0 >> 32) as u8;
    s[5] = (t0 >> 40) as u8;
    s[6] = ((t0 >> 48) | (t1 << 3)) as u8;
    s[7] = (t1 >> 5) as u8;
    s[8] = (t1 >> 13) as u8;
    s[9] = (t1 >> 21) as u8;
    s[10] = (t1 >> 29) as u8;
    s[11] = (t1 >> 37) as u8;
    s[12] = ((t1 >> 45) | (t2 << 6)) as u8;
    s[13] = (t2 >> 2) as u8;
    s[14] = (t2 >> 10) as u8;
    s[15] = (t2 >> 18) as u8;
    s[16] = (t2 >> 26) as u8;
    s[17] = (t2 >> 34) as u8;
    s[18] = (t2 >> 42) as u8;
    s[19] = ((t2 >> 50) | (t3 << 1)) as u8;
    s[20] = (t3 >> 7) as u8;
    s[21] = (t3 >> 15) as u8;
    s[22] = (t3 >> 23) as u8;
    s[23] = (t3 >> 31) as u8;
    s[24] = (t3 >> 39) as u8;
    s[25] = ((t3 >> 47) | (t4 << 4)) as u8;
    s[26] = (t4 >> 4) as u8;
    s[27] = (t4 >> 12) as u8;
    s[28] = (t4 >> 20) as u8;
    s[29] = (t4 >> 28) as u8;
    s[30] = (t4 >> 36) as u8;
    s[31] = (t4 >> 44) as u8;
    s
}

/// Masked swap. `bit` is 0 or 1; no secret-dependent branch.
fn cswap(a: &mut Fe, b: &mut Fe, bit: u64) {
    let mask = 0u64.wrapping_sub(bit & 1);
    for i in 0..5 {
        let t = mask & (a[i] ^ b[i]);
        a[i] ^= t;
        b[i] ^= t;
    }
}

fn clamp_scalar(k: &mut [u8; 32]) {
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;
}

/// X25519(k, u). `k` is the scalar, `u` the u-coordinate.
pub fn x25519(k: &[u8; 32], u: &[u8; 32]) -> [u8; 32] {
    let mut k = *k;
    clamp_scalar(&mut k);
    let mut u = *u;
    u[31] &= 127;
    let x1 = fe_frombytes(&u);
    let mut x2 = fe1();
    let mut z2 = fe0();
    let mut x3 = x1;
    let mut z3 = fe1();
    let mut swap = 0u64;
    for t in (0..255).rev() {
        let kt = u64::from((k[t / 8] >> (t % 8)) & 1);
        swap ^= kt;
        cswap(&mut x2, &mut x3, swap);
        cswap(&mut z2, &mut z3, swap);
        swap = kt;
        let a = fe_add(&x2, &z2);
        let aa = fe_sq(&a);
        let b = fe_sub(&x2, &z2);
        let bb = fe_sq(&b);
        let e = fe_sub(&aa, &bb);
        let c = fe_add(&x3, &z3);
        let d = fe_sub(&x3, &z3);
        let da = fe_mul(&d, &a);
        let cb = fe_mul(&c, &b);
        x3 = fe_sq(&fe_add(&da, &cb));
        z3 = fe_mul(&x1, &fe_sq(&fe_sub(&da, &cb)));
        x2 = fe_mul(&aa, &bb);
        let t = fe_add(&aa, &fe_mul_small(&e, 121665));
        z2 = fe_mul(&e, &t);
    }
    cswap(&mut x2, &mut x3, swap);
    cswap(&mut z2, &mut z3, swap);
    fe_tobytes(&fe_mul(&x2, &fe_invert(&z2)))
}

/// Base point u=9.
pub fn x25519_public(sk: &[u8; 32]) -> [u8; 32] {
    let mut nine = [0u8; 32];
    nine[0] = 9;
    x25519(sk, &nine)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hx(s: &str) -> [u8; 32] {
        let v: Vec<u8> = (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect();
        let mut a = [0u8; 32];
        a.copy_from_slice(&v);
        a
    }

    #[test]
    fn rfc7748_alice() {
        let sk = hx("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        let pk = x25519_public(&sk);
        assert_eq!(
            pk,
            hx("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        );
    }

    #[test]
    fn rfc7748_shared() {
        let a = hx("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        let b = hx("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
        let pa = x25519_public(&a);
        let pb = x25519_public(&b);
        let sa = x25519(&a, &pb);
        let sb = x25519(&b, &pa);
        assert_eq!(sa, sb);
        assert_eq!(
            sa,
            hx("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        );
    }

    #[test]
    fn cswap_is_mask_not_branch() {
        let mut a = [1u64, 2, 3, 4, 5];
        let mut b = [9u64, 8, 7, 6, 0];
        let a0 = a;
        cswap(&mut a, &mut b, 0);
        assert_eq!(a, a0);
        cswap(&mut a, &mut b, 1);
        assert_eq!(a, [9, 8, 7, 6, 0]);
        assert_eq!(b, a0);
    }
}
