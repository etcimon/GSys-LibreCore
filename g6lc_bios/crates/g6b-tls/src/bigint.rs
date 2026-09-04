// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Unsigned big integers for RSA / ECDSA (schoolbook). Spec: Botan math.

#![allow(missing_docs)]

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BigUint {
    /// Little-endian 32-bit limbs.
    limbs: Vec<u32>,
}

impl BigUint {
    pub fn zero() -> Self {
        Self { limbs: vec![0] }
    }

    pub fn from_u32(v: u32) -> Self {
        Self { limbs: vec![v] }
    }

    pub fn from_be_bytes(b: &[u8]) -> Self {
        if b.is_empty() {
            return Self::zero();
        }
        let mut limbs = Vec::new();
        let mut i = b.len();
        while i > 0 {
            let start = i.saturating_sub(4);
            let mut x = 0u32;
            for &byte in &b[start..i] {
                x = (x << 8) | u32::from(byte);
            }
            limbs.push(x);
            i = start;
        }
        let mut n = Self { limbs };
        n.norm();
        n
    }

    pub fn to_be_bytes(&self, width: usize) -> Vec<u8> {
        let mut out = vec![0u8; width];
        let raw = self.to_be_vec();
        if raw.len() > width {
            out.copy_from_slice(&raw[raw.len() - width..]);
        } else {
            out[width - raw.len()..].copy_from_slice(&raw);
        }
        out
    }

    fn to_be_vec(&self) -> Vec<u8> {
        if self.is_zero() {
            return vec![0];
        }
        let mut out = Vec::new();
        for &l in self.limbs.iter().rev() {
            out.extend_from_slice(&l.to_be_bytes());
        }
        let i = out.iter().position(|&b| b != 0).unwrap_or(out.len() - 1);
        out[i..].to_vec()
    }

    pub fn is_zero(&self) -> bool {
        self.limbs.iter().all(|&l| l == 0)
    }

    fn norm(&mut self) {
        while self.limbs.len() > 1 && *self.limbs.last().unwrap() == 0 {
            self.limbs.pop();
        }
        if self.limbs.is_empty() {
            self.limbs.push(0);
        }
    }

    pub fn cmp(&self, o: &Self) -> core::cmp::Ordering {
        let a = self.limbs.len();
        let b = o.limbs.len();
        if a != b {
            return a.cmp(&b);
        }
        for i in (0..a).rev() {
            if self.limbs[i] != o.limbs[i] {
                return self.limbs[i].cmp(&o.limbs[i]);
            }
        }
        core::cmp::Ordering::Equal
    }

    pub fn add(&self, o: &Self) -> Self {
        let n = self.limbs.len().max(o.limbs.len());
        let mut out = vec![0u32; n + 1];
        let mut c = 0u64;
        for (i, slot) in out.iter_mut().take(n).enumerate() {
            let x = u64::from(*self.limbs.get(i).unwrap_or(&0));
            let y = u64::from(*o.limbs.get(i).unwrap_or(&0));
            let s = x + y + c;
            *slot = s as u32;
            c = s >> 32;
        }
        out[n] = c as u32;
        let mut r = Self { limbs: out };
        r.norm();
        r
    }

    pub fn sub(&self, o: &Self) -> Self {
        debug_assert!(self.cmp(o) != core::cmp::Ordering::Less);
        let mut out = self.limbs.clone();
        let mut br = 0i64;
        for (i, slot) in out.iter_mut().enumerate() {
            let y = i64::from(*o.limbs.get(i).unwrap_or(&0)) + br;
            let x = i64::from(*slot);
            let d = x - y;
            if d < 0 {
                *slot = (d + (1i64 << 32)) as u32;
                br = 1;
            } else {
                *slot = d as u32;
                br = 0;
            }
        }
        let mut r = Self { limbs: out };
        r.norm();
        r
    }

    pub fn shl1(&self) -> Self {
        let mut out = vec![0u32; self.limbs.len() + 1];
        let mut c = 0u32;
        for (i, &l) in self.limbs.iter().enumerate() {
            out[i] = (l << 1) | c;
            c = l >> 31;
        }
        *out.last_mut().unwrap() = c;
        let mut r = Self { limbs: out };
        r.norm();
        r
    }

    pub fn bit(&self, i: usize) -> bool {
        let li = i / 32;
        let b = i % 32;
        self.limbs
            .get(li)
            .map(|l| (l >> b) & 1 == 1)
            .unwrap_or(false)
    }

    pub fn bit_len(&self) -> usize {
        if self.is_zero() {
            return 0;
        }
        let last = *self.limbs.last().unwrap();
        32 * (self.limbs.len() - 1) + (32 - last.leading_zeros() as usize)
    }

    pub fn mul(&self, o: &Self) -> Self {
        let mut out = vec![0u32; self.limbs.len() + o.limbs.len() + 1];
        for (i, &a) in self.limbs.iter().enumerate() {
            let mut c = 0u64;
            for (j, &b) in o.limbs.iter().enumerate() {
                let t = u64::from(out[i + j]) + u64::from(a) * u64::from(b) + c;
                out[i + j] = t as u32;
                c = t >> 32;
            }
            let mut k = i + o.limbs.len();
            while c > 0 {
                let t = u64::from(out[k]) + c;
                out[k] = t as u32;
                c = t >> 32;
                k += 1;
            }
        }
        let mut r = Self { limbs: out };
        r.norm();
        r
    }

    pub fn modulo(&self, m: &Self) -> Self {
        self.divmod(m).1
    }

    pub fn divmod(&self, m: &Self) -> (Self, Self) {
        assert!(!m.is_zero());
        if self.cmp(m) == core::cmp::Ordering::Less {
            return (Self::zero(), self.clone());
        }
        let mut q = Self::zero();
        let mut r = Self::zero();
        for i in (0..self.bit_len()).rev() {
            r = r.shl1();
            if self.bit(i) {
                r = r.add(&Self::from_u32(1));
            }
            if r.cmp(m) != core::cmp::Ordering::Less {
                r = r.sub(m);
                // q |= 1<<i
                let mut bit = Self::from_u32(1);
                for _ in 0..i {
                    bit = bit.shl1();
                }
                q = q.add(&bit);
            }
        }
        q.norm();
        r.norm();
        (q, r)
    }

    pub fn modpow(&self, exp: &Self, m: &Self) -> Self {
        let mut base = self.modulo(m);
        let mut res = Self::from_u32(1);
        for i in 0..exp.bit_len() {
            if exp.bit(i) {
                res = res.mul(&base).modulo(m);
            }
            base = base.mul(&base).modulo(m);
        }
        res
    }

    /// Modular inverse for **prime** moduli (Fermat).
    pub fn modinv_prime(&self, p: &Self) -> Self {
        let two = Self::from_u32(2);
        let exp = p.sub(&two);
        self.modpow(&exp, p)
    }
}
