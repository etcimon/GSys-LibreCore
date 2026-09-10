// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party compressed USB dump (`G6BS`). LZ77, no crates.io.

use crate::error::StoreError;

/// Magic for a compressed store dump on a USB key.
pub const MAGIC: &[u8; 4] = b"G6BS";
const VERSION: u8 = 1;
const FLAG_LZ: u8 = 1;

/// Pack dump JSON into a `G6BS` blob.
pub fn pack(json: &[u8]) -> Vec<u8> {
    let c = lz_compress(json);
    let mut o = Vec::with_capacity(10 + c.len());
    o.extend_from_slice(MAGIC);
    o.push(VERSION);
    o.push(FLAG_LZ);
    o.extend_from_slice(&(json.len() as u32).to_le_bytes());
    o.extend_from_slice(&c);
    o
}

/// Unpack a `G6BS` blob, or pass through raw JSON (`{...}`).
pub fn unpack(buf: &[u8]) -> Result<Vec<u8>, StoreError> {
    if buf.first() == Some(&b'{') {
        return Ok(buf.to_vec());
    }
    if buf.len() < 10 || buf.get(..4) != Some(MAGIC.as_slice()) {
        return Err(StoreError::exec("g6bs magic"));
    }
    if buf[4] != VERSION {
        return Err(StoreError::exec("g6bs version"));
    }
    let uncomp = u32::from_le_bytes(buf[6..10].try_into().unwrap()) as usize;
    if uncomp > 1024 * 1024 {
        return Err(StoreError::Budget("result"));
    }
    let body = &buf[10..];
    if buf[5] & FLAG_LZ == 0 {
        if body.len() != uncomp {
            return Err(StoreError::exec("g6bs length"));
        }
        return Ok(body.to_vec());
    }
    lz_decompress(body, uncomp)
}

fn lz_compress(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < src.len() {
        let mut best_len = 0usize;
        let mut best_dist = 0usize;
        let start = i.saturating_sub(4095);
        if i + 2 < src.len() {
            let mut j = start;
            while j < i {
                let mut n = 0;
                while i + n < src.len() && j + n < i && src[j + n] == src[i + n] && n < 258 {
                    n += 1;
                }
                if n >= 3 && n > best_len {
                    best_len = n;
                    best_dist = i - j;
                }
                j += 1;
            }
        }
        if best_len >= 3 {
            out.push(1);
            out.extend_from_slice(&(best_dist as u16).to_le_bytes());
            out.push((best_len - 3) as u8);
            i += best_len;
        } else {
            let lit_end = (i + 1).min(src.len());
            let mut end = lit_end;
            while end < src.len() && end - i < 255 {
                // stop a literal run if a match starts
                if end + 2 < src.len() {
                    let s = end.saturating_sub(4095);
                    let mut found = false;
                    let mut k = s;
                    while k < end {
                        if src[k] == src[end]
                            && src[k + 1] == src[end + 1]
                            && src[k + 2] == src[end + 2]
                        {
                            found = true;
                            break;
                        }
                        k += 1;
                    }
                    if found {
                        break;
                    }
                }
                end += 1;
            }
            let n = (end - i).min(255);
            out.push(0);
            out.push(n as u8);
            out.extend_from_slice(&src[i..i + n]);
            i += n;
        }
    }
    out
}

fn lz_decompress(src: &[u8], expect: usize) -> Result<Vec<u8>, StoreError> {
    let mut out = Vec::with_capacity(expect);
    let mut i = 0;
    while i < src.len() {
        match src[i] {
            0 => {
                i += 1;
                let n = *src.get(i).ok_or_else(|| StoreError::exec("g6bs lz"))? as usize;
                i += 1;
                if i + n > src.len() {
                    return Err(StoreError::exec("g6bs lz"));
                }
                out.extend_from_slice(&src[i..i + n]);
                i += n;
            }
            1 => {
                i += 1;
                if i + 3 > src.len() {
                    return Err(StoreError::exec("g6bs lz"));
                }
                let dist = u16::from_le_bytes([src[i], src[i + 1]]) as usize;
                let len = src[i + 2] as usize + 3;
                i += 3;
                if dist == 0 || dist > out.len() {
                    return Err(StoreError::exec("g6bs lz"));
                }
                for _ in 0..len {
                    let b = out[out.len() - dist];
                    out.push(b);
                }
            }
            _ => return Err(StoreError::exec("g6bs lz")),
        }
        if out.len() > expect {
            return Err(StoreError::Budget("result"));
        }
    }
    if out.len() != expect {
        return Err(StoreError::exec("g6bs length"));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_repeats_and_raw_json() {
        let src = br#"{"g6b_store":1,"uuid":"550e8400-e29b-41d4-a716-446655440000","purpose":"registry","tables":{"kv":{"cols":[{"name":"k","type":"TEXT","pk":true}],"rows":[["aaaaaaaaaaaaaaaa"]],"serial":1}}}"#;
        let packed = pack(src);
        assert!(packed.starts_with(MAGIC));
        assert_eq!(unpack(&packed).unwrap(), src);
        assert_eq!(unpack(src).unwrap(), src);
        let repeats = vec![b'a'; 256];
        let packed_rep = pack(&repeats);
        assert!(packed_rep.len() < repeats.len());
        assert_eq!(unpack(&packed_rep).unwrap(), repeats);
    }
}
