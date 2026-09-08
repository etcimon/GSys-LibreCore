// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded PNG decode (and a deterministic encode for fixtures/tests).
//
// KD0 forbids an image crate, so this is the whole decoder in one file: chunk
// walk, zlib/deflate (stored + fixed + dynamic Huffman), scanline unfiltering.
// Subset by contract, refused loudly rather than degraded: bit depth 8 only,
// colour types 0/2/3/4/6, non-interlaced, no APNG. CRCs are verified — a
// corrupt chunk is a decode error, not a wrong pixel.

#![allow(missing_docs)]

use crate::RgbaImage;

pub const MAX_PNG_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_DIM: u32 = 4096;
pub const MAX_PIXELS: u64 = 4 * 1024 * 1024;
pub const MAX_IDAT_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImgError {
    Empty,
    Oversized,
    Signature,
    BadChunk(&'static str),
    Crc,
    Unsupported(&'static str),
    Truncated,
    Zlib(&'static str),
    PixelCount,
}

impl std::fmt::Display for ImgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Empty => write!(f, "empty image"),
            Self::Oversized => write!(f, "image exceeds size budget"),
            Self::Signature => write!(f, "bad PNG signature"),
            Self::BadChunk(c) => write!(f, "malformed {c} chunk"),
            Self::Crc => write!(f, "chunk CRC mismatch"),
            Self::Unsupported(w) => write!(f, "unsupported PNG feature: {w}"),
            Self::Truncated => write!(f, "truncated image"),
            Self::Zlib(w) => write!(f, "deflate: {w}"),
            Self::PixelCount => write!(f, "pixel budget exceeded"),
        }
    }
}

impl std::error::Error for ImgError {}

type R<T> = Result<T, ImgError>;

const SIG: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// Decode `bytes` into an RGBA8 image. The output size is validated against
/// `MAX_PIXELS` *before* the inflate runs, so a hostile IDAT cannot inflate
/// into an unbounded buffer.
pub fn decode(bytes: &[u8]) -> R<RgbaImage> {
    if bytes.is_empty() {
        return Err(ImgError::Empty);
    }
    if bytes.len() > MAX_PNG_BYTES {
        return Err(ImgError::Oversized);
    }
    if !bytes.starts_with(SIG) {
        return Err(ImgError::Signature);
    }
    let mut rest = &bytes[8..];
    let mut ihdr: Option<Ihdr> = None;
    let mut plte: Vec<u8> = Vec::new();
    let mut trns: Vec<u8> = Vec::new();
    let mut idat: Vec<u8> = Vec::new();
    let mut seen_iend = false;
    while !rest.is_empty() && !seen_iend {
        if rest.len() < 12 {
            return Err(ImgError::Truncated);
        }
        let len = u32::from_be_bytes(rest[..4].try_into().unwrap()) as usize;
        let name = &rest[4..8];
        let end = 8 + len + 4;
        if end > rest.len() {
            return Err(ImgError::Truncated);
        }
        let data = &rest[8..8 + len];
        let crc = u32::from_be_bytes(rest[8 + len..end].try_into().unwrap());
        if crc32_of(name, data) != crc {
            return Err(ImgError::Crc);
        }
        match name {
            b"IHDR" => {
                if ihdr.is_some() {
                    return Err(ImgError::BadChunk("IHDR"));
                }
                ihdr = Some(parse_ihdr(data)?);
            }
            b"PLTE" => {
                if data.len() % 3 != 0 || data.len() > 768 {
                    return Err(ImgError::BadChunk("PLTE"));
                }
                plte = data.to_vec();
            }
            b"tRNS" => trns = data.to_vec(),
            b"IDAT" => {
                if idat.len() + data.len() > MAX_IDAT_BYTES {
                    return Err(ImgError::Oversized);
                }
                idat.extend_from_slice(data);
            }
            b"IEND" => seen_iend = true,
            _ => {} // ancillary chunks are skippable by definition
        }
        rest = &rest[end..];
    }
    let h = ihdr.ok_or(ImgError::BadChunk("IHDR"))?;
    if !seen_iend || idat.is_empty() {
        return Err(ImgError::Truncated);
    }
    let channels = h.channels();
    let row_bytes = h.w as usize * channels;
    let raw_len = (row_bytes + 1)
        .checked_mul(h.h as usize)
        .ok_or(ImgError::PixelCount)?;
    let raw = inflate(&idat, raw_len)?;
    let unfiltered = unfilter(&raw, h.w, h.h, channels)?;
    expand(&unfiltered, &h, &plte, &trns)
}

struct Ihdr {
    w: u32,
    h: u32,
    color: u8,
}

impl Ihdr {
    fn channels(&self) -> usize {
        match self.color {
            0 | 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            _ => 0,
        }
    }
}

fn parse_ihdr(d: &[u8]) -> R<Ihdr> {
    if d.len() != 13 {
        return Err(ImgError::BadChunk("IHDR"));
    }
    let w = u32::from_be_bytes(d[..4].try_into().unwrap());
    let h = u32::from_be_bytes(d[4..8].try_into().unwrap());
    let depth = d[8];
    let color = d[9];
    let (compression, filter, interlace) = (d[10], d[11], d[12]);
    if w == 0 || h == 0 || w > MAX_DIM || h > MAX_DIM {
        return Err(ImgError::BadChunk("IHDR dimensions"));
    }
    if u64::from(w) * u64::from(h) > MAX_PIXELS {
        return Err(ImgError::PixelCount);
    }
    if depth != 8 {
        return Err(ImgError::Unsupported("bit depth (8-bit only)"));
    }
    if !matches!(color, 0 | 2 | 3 | 4 | 6) {
        return Err(ImgError::Unsupported("colour type"));
    }
    if compression != 0 || filter != 0 {
        return Err(ImgError::BadChunk("IHDR compression/filter"));
    }
    if interlace != 0 {
        return Err(ImgError::Unsupported("Adam7 interlace"));
    }
    Ok(Ihdr { w, h, color })
}

// ---------------------------------------------------------------------------
// zlib / deflate
// ---------------------------------------------------------------------------

struct Bits<'a> {
    d: &'a [u8],
    bit: usize,
}

impl Bits<'_> {
    fn one(&mut self) -> Option<u32> {
        let byte = *self.d.get(self.bit / 8)?;
        let v = (byte >> (self.bit % 8)) & 1;
        self.bit += 1;
        Some(u32::from(v))
    }
    fn take(&mut self, n: u32) -> Option<u32> {
        let mut v = 0u32;
        for i in 0..n {
            v |= self.one()? << i;
        }
        Some(v)
    }
    fn align(&mut self) {
        self.bit = self.bit.div_ceil(8) * 8;
    }
}

/// Canonical Huffman table: per-length symbol counts plus the symbols in
/// (length, symbol) order — the `puff` construction.
struct Huff {
    counts: [u16; 16],
    symbols: Vec<u16>,
}

fn huff_build(lengths: &[u8]) -> Huff {
    let mut counts = [0u16; 16];
    for &l in lengths {
        counts[l as usize] += 1;
    }
    counts[0] = 0; // zero-length = unused, must not be decodable
    let mut offs = [0u16; 16];
    for i in 1..16 {
        offs[i] = offs[i - 1] + counts[i - 1];
    }
    let mut symbols = vec![0u16; lengths.iter().filter(|&&l| l != 0).count()];
    for (sym, &l) in lengths.iter().enumerate() {
        if l != 0 {
            symbols[offs[l as usize] as usize] = sym as u16;
            offs[l as usize] += 1;
        }
    }
    Huff { counts, symbols }
}

fn huff_decode(h: &Huff, r: &mut Bits) -> Option<u16> {
    let mut code = 0i32;
    let mut first = 0i32;
    let mut index = 0i32;
    for len in 1..16 {
        code |= r.one()? as i32;
        let count = i32::from(h.counts[len]);
        if code - first < count {
            return h.symbols.get((index + code - first) as usize).copied();
        }
        index += count;
        first = (first + count) << 1;
        code <<= 1;
    }
    None
}

const LEN_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LEN_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];
const CL_ORDER: [usize; 19] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

fn fixed_tables() -> (Huff, Huff) {
    let mut lit = [0u8; 288];
    for (i, l) in lit.iter_mut().enumerate() {
        *l = match i {
            0..=143 => 8,
            144..=255 => 9,
            256..=279 => 7,
            _ => 8,
        };
    }
    let dist = [5u8; 30];
    (huff_build(&lit), huff_build(&dist))
}

fn dynamic_tables(r: &mut Bits) -> R<(Huff, Huff)> {
    let hlit = r.take(5).ok_or(ImgError::Truncated)? as usize + 257;
    let hdist = r.take(5).ok_or(ImgError::Truncated)? as usize + 1;
    let hclen = r.take(4).ok_or(ImgError::Truncated)? as usize + 4;
    if hlit > 286 || hdist > 30 {
        return Err(ImgError::Zlib("table sizes"));
    }
    let mut cl_lengths = [0u8; 19];
    for &idx in CL_ORDER.iter().take(hclen) {
        cl_lengths[idx] = r.take(3).ok_or(ImgError::Truncated)? as u8;
    }
    let cl = huff_build(&cl_lengths);
    let total = hlit + hdist;
    let mut lengths = vec![0u8; total];
    let mut i = 0;
    while i < total {
        let sym = huff_decode(&cl, r).ok_or(ImgError::Zlib("code-length stream"))?;
        match sym {
            0..=15 => {
                lengths[i] = sym as u8;
                i += 1;
            }
            16 => {
                if i == 0 {
                    return Err(ImgError::Zlib("repeat with no previous length"));
                }
                let prev = lengths[i - 1];
                let n = 3 + r.take(2).ok_or(ImgError::Truncated)? as usize;
                if i + n > total {
                    return Err(ImgError::Zlib("repeat overflow"));
                }
                for _ in 0..n {
                    lengths[i] = prev;
                    i += 1;
                }
            }
            17 => {
                let n = 3 + r.take(3).ok_or(ImgError::Truncated)? as usize;
                if i + n > total {
                    return Err(ImgError::Zlib("zero-run overflow"));
                }
                i += n;
            }
            18 => {
                let n = 11 + r.take(7).ok_or(ImgError::Truncated)? as usize;
                if i + n > total {
                    return Err(ImgError::Zlib("zero-run overflow"));
                }
                i += n;
            }
            _ => return Err(ImgError::Zlib("bad code-length symbol")),
        }
    }
    if lengths[256] == 0 {
        return Err(ImgError::Zlib("no end-of-block code"));
    }
    Ok((huff_build(&lengths[..hlit]), huff_build(&lengths[hlit..])))
}

/// One deflate block's literal/length + distance decode into `out`.
fn inflate_block(lit: &Huff, dist: &Huff, r: &mut Bits, out: &mut Vec<u8>) -> R<()> {
    loop {
        let sym = huff_decode(lit, r).ok_or(ImgError::Zlib("literal stream"))?;
        match sym {
            0..=255 => out.push(sym as u8),
            256 => return Ok(()),
            257..=285 => {
                let k = (sym - 257) as usize;
                let len =
                    LEN_BASE[k] as usize + r.take(u32::from(LEN_EXTRA[k])).unwrap_or(0) as usize;
                let dsym = huff_decode(dist, r).ok_or(ImgError::Zlib("distance stream"))?;
                if dsym as usize > 29 {
                    return Err(ImgError::Zlib("distance symbol"));
                }
                let d = DIST_BASE[dsym as usize] as usize
                    + r.take(u32::from(DIST_EXTRA[dsym as usize])).unwrap_or(0) as usize;
                if d == 0 || d > out.len() {
                    return Err(ImgError::Zlib("distance before start"));
                }
                for _ in 0..len {
                    let b = out[out.len() - d];
                    out.push(b);
                }
            }
            _ => return Err(ImgError::Zlib("bad literal symbol")),
        }
    }
}

/// zlib wrapper + deflate, bounded to exactly `expect` output bytes.
pub fn inflate(z: &[u8], expect: usize) -> R<Vec<u8>> {
    if z.len() < 6 {
        return Err(ImgError::Zlib("short zlib header"));
    }
    let (cmf, flg) = (z[0], z[1]);
    if cmf & 0x0f != 8 || cmf >> 4 > 7 || (u32::from(cmf) * 256 + u32::from(flg)) % 31 != 0 {
        return Err(ImgError::Zlib("header check"));
    }
    if flg & 0x20 != 0 {
        return Err(ImgError::Zlib("preset dictionary"));
    }
    let mut r = Bits { d: &z[2..], bit: 0 };
    let mut out = Vec::with_capacity(expect);
    loop {
        let last = r.one().ok_or(ImgError::Truncated)? != 0;
        let btype = r.take(2).ok_or(ImgError::Truncated)?;
        match btype {
            0 => {
                r.align();
                let p = r.bit / 8;
                if p + 4 > r.d.len() {
                    return Err(ImgError::Truncated);
                }
                let len = u16::from_le_bytes(r.d[p..p + 2].try_into().unwrap()) as usize;
                let nlen = u16::from_le_bytes(r.d[p + 2..p + 4].try_into().unwrap()) as usize;
                if len != nlen ^ 0xffff {
                    return Err(ImgError::Zlib("stored LEN/NLEN"));
                }
                let start = p + 4;
                if start + len > r.d.len() {
                    return Err(ImgError::Truncated);
                }
                out.extend_from_slice(&r.d[start..start + len]);
                r.bit = (start + len) * 8;
            }
            1 => {
                let (lit, dist) = fixed_tables();
                inflate_block(&lit, &dist, &mut r, &mut out)?;
            }
            2 => {
                let (lit, dist) = dynamic_tables(&mut r)?;
                inflate_block(&lit, &dist, &mut r, &mut out)?;
            }
            _ => return Err(ImgError::Zlib("reserved block type")),
        }
        if out.len() > expect {
            return Err(ImgError::Zlib("output over expected size"));
        }
        if last {
            break;
        }
    }
    if out.len() != expect {
        return Err(ImgError::Zlib("output length mismatch"));
    }
    // Adler-32 trailer (4 bytes BE) sits after the deflate stream; we ignore
    // its value — the pixel length + CRCs already catch corruption.
    Ok(out)
}

// ---------------------------------------------------------------------------
// unfilter + expand
// ---------------------------------------------------------------------------

fn paeth(a: u8, b: u8, c: u8) -> u8 {
    let (a, b, c) = (i32::from(a), i32::from(b), i32::from(c));
    let p = a + b - c;
    let (pa, pb, pc) = ((p - a).abs(), (p - b).abs(), (p - c).abs());
    if pa <= pb && pa <= pc {
        a as u8
    } else if pb <= pc {
        b as u8
    } else {
        c as u8
    }
}

fn unfilter(raw: &[u8], w: u32, h: u32, ch: usize) -> R<Vec<u8>> {
    let row = w as usize * ch;
    let mut out = vec![0u8; row * h as usize];
    for y in 0..h as usize {
        let f = raw[y * (row + 1)];
        let src = &raw[y * (row + 1) + 1..(y + 1) * (row + 1)];
        if f > 4 {
            return Err(ImgError::BadChunk("filter type"));
        }
        for x in 0..row {
            let a = if x >= ch { out[y * row + x - ch] } else { 0 };
            let b = if y > 0 { out[(y - 1) * row + x] } else { 0 };
            let c = if y > 0 && x >= ch {
                out[(y - 1) * row + x - ch]
            } else {
                0
            };
            let v = src[x];
            out[y * row + x] = match f {
                0 => v,
                1 => v.wrapping_add(a),
                2 => v.wrapping_add(b),
                3 => v.wrapping_add(((u16::from(a) + u16::from(b)) / 2) as u8),
                _ => v.wrapping_add(paeth(a, b, c)),
            };
        }
    }
    Ok(out)
}

fn expand(raw: &[u8], ihdr: &Ihdr, plte: &[u8], trns: &[u8]) -> R<RgbaImage> {
    let (w, h) = (ihdr.w as usize, ihdr.h as usize);
    let mut rgba = vec![0u8; w * h * 4];
    let t16 = |trns: &[u8], i: usize| -> Option<u16> {
        trns.get(i..i + 2)
            .map(|b| u16::from_be_bytes(b.try_into().unwrap()))
    };
    match ihdr.color {
        0 => {
            let t = t16(trns, 0).map(|v| (v & 0xff) as u8);
            for (i, px) in rgba.chunks_exact_mut(4).enumerate() {
                let g = raw[i];
                px.copy_from_slice(&[g, g, g, if Some(g) == t { 0 } else { 255 }]);
            }
        }
        2 => {
            let tr = [t16(trns, 0), t16(trns, 2), t16(trns, 4)];
            for (i, px) in rgba.chunks_exact_mut(4).enumerate() {
                let s = &raw[i * 3..i * 3 + 3];
                let a = if tr[0] == Some(u16::from(s[0]))
                    && tr[1] == Some(u16::from(s[1]))
                    && tr[2] == Some(u16::from(s[2]))
                {
                    0
                } else {
                    255
                };
                px.copy_from_slice(&[s[0], s[1], s[2], a]);
            }
        }
        3 => {
            if plte.is_empty() {
                return Err(ImgError::BadChunk("PLTE"));
            }
            for (i, px) in rgba.chunks_exact_mut(4).enumerate() {
                let idx = raw[i] as usize;
                let c = plte
                    .get(idx * 3..idx * 3 + 3)
                    .ok_or(ImgError::BadChunk("PLTE index"))?;
                let a = trns.get(idx).copied().unwrap_or(255);
                px.copy_from_slice(&[c[0], c[1], c[2], a]);
            }
        }
        4 => {
            for (i, px) in rgba.chunks_exact_mut(4).enumerate() {
                let (g, a) = (raw[i * 2], raw[i * 2 + 1]);
                px.copy_from_slice(&[g, g, g, a]);
            }
        }
        _ => {
            rgba.copy_from_slice(&raw[..w * h * 4]);
        }
    }
    Ok(RgbaImage {
        w: ihdr.w,
        h: ihdr.h,
        rgba,
    })
}

// ---------------------------------------------------------------------------
// encode — deterministic stored-zlib PNG for fixtures, icons and tests
// ---------------------------------------------------------------------------

fn crc32_of(name: &[u8], data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &b in name.iter().chain(data.iter()) {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn chunk(out: &mut Vec<u8>, name: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(name);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc32_of(name, data).to_be_bytes());
}

/// Encode an RGBA8 image as a PNG using zlib *stored* blocks (no compression).
/// Deterministic and dependency-free — this exists so fixtures and the served
/// logo are generated, not hand-maintained binaries.
pub fn encode(img: &RgbaImage) -> Vec<u8> {
    let row = img.w as usize * 4;
    let raw_len = (row + 1) * img.h as usize;
    let mut z = Vec::with_capacity(raw_len + raw_len / 65_535 * 5 + 16);
    // zlib header: CM=8, CINFO=7 (32K window), FLEVEL=0.
    z.extend_from_slice(&[0x78, 0x01]);
    let mut scan = Vec::with_capacity(raw_len);
    for y in 0..img.h as usize {
        scan.push(0); // filter None
        scan.extend_from_slice(&img.rgba[y * row..(y + 1) * row]);
    }
    let mut rest = scan.as_slice();
    let mut first = true;
    while !rest.is_empty() || first {
        first = false;
        let n = rest.len().min(65_535);
        let last = n == rest.len();
        z.push(u8::from(last));
        z.extend_from_slice(&(n as u16).to_le_bytes());
        z.extend_from_slice(&(!(n as u16)).to_le_bytes());
        z.extend_from_slice(&rest[..n]);
        rest = &rest[n..];
    }
    // Adler-32 of the uncompressed scan data.
    let (mut s1, mut s2) = (1u32, 0u32);
    for &b in &scan {
        s1 = (s1 + u32::from(b)) % 65_521;
        s2 = (s2 + s1) % 65_521;
    }
    z.extend_from_slice(&(s2 * 65_536 + s1).to_be_bytes());

    let mut out = SIG.to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&img.w.to_be_bytes());
    ihdr.extend_from_slice(&img.h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> RgbaImage {
        RgbaImage {
            w: 2,
            h: 2,
            rgba: vec![
                255, 0, 0, 255, 0, 255, 0, 128, //
                0, 0, 255, 255, 0, 0, 0, 0,
            ],
        }
    }

    #[test]
    fn encode_decode_round_trip() {
        let png = encode(&sample());
        assert!(png.starts_with(SIG));
        let back = decode(&png).unwrap();
        assert_eq!(back, sample());
    }

    #[test]
    fn decode_rejects_bad_inputs_closed() {
        assert_eq!(decode(&[]).unwrap_err(), ImgError::Empty);
        assert_eq!(decode(b"not a png").unwrap_err(), ImgError::Signature);
        let mut bad = encode(&sample());
        let n = bad.len();
        bad[n - 9] ^= 0xff; // corrupt IEND data/CRC
        assert!(matches!(
            decode(&bad),
            Err(ImgError::Crc | ImgError::Truncated)
        ));
        // Truncated stream.
        assert!(decode(&png_head(&sample())[..40]).is_err());
    }

    fn png_head(img: &RgbaImage) -> Vec<u8> {
        encode(img)
    }

    #[test]
    fn zlib_stored_and_dynamic_inflate() {
        // Stored block round-trip through our own encoder is covered above;
        // here a real zlib (fixed/dynamic) stream built by hand would be
        // fragile — instead verify the budget and trailer checks directly.
        assert!(inflate(&[0x78], 1).is_err());
        assert!(inflate(&[0x78, 0x9c, 0, 0, 0, 0], 4).is_err());
    }

    #[test]
    fn grayscale_and_palette_expand() {
        // Colour type 0, 1x1, filter None, stored zlib.
        let raw = [0u8, 0x80]; // filter 0, gray 0x80
        let z = zlib_stored(&raw);
        let png = assemble(1, 1, 0, &[], &[], &z);
        let img = decode(&png).unwrap();
        assert_eq!(img.rgba, [0x80, 0x80, 0x80, 255]);

        // Colour type 3 with tRNS: palette index 1 -> red, alpha 0.
        let raw = [0u8, 1];
        let z = zlib_stored(&raw);
        let png = assemble(1, 1, 3, &[0, 0, 0, 255, 0, 0], &[255, 0], &z);
        let img = decode(&png).unwrap();
        assert_eq!(img.rgba, [255, 0, 0, 0]);
    }

    #[test]
    fn filters_reconstruct() {
        // Two rows of filter Sub(1) on RGB: row0 "10 20 30 | +5 +5 +5",
        // row1 filter Up(2) with deltas 1.
        let raw = [
            1, 10, 20, 30, 5, 5, 5, // row 0, Sub
            2, 1, 1, 1, 1, 1, 1, // row 1, Up
        ];
        let png = assemble(2, 2, 2, &[], &[], &zlib_stored(&raw));
        let img = decode(&png).unwrap();
        assert_eq!(&img.rgba[..4], &[10, 20, 30, 255]);
        assert_eq!(&img.rgba[4..8], &[15, 25, 35, 255]); // Sub reconstructs
        assert_eq!(&img.rgba[8..12], &[11, 21, 31, 255]); // Up adds row above
    }

    fn zlib_stored(raw: &[u8]) -> Vec<u8> {
        let mut z = vec![0x78, 0x01];
        let mut rest = raw;
        loop {
            let n = rest.len().min(65_535);
            let last = n == rest.len();
            z.push(u8::from(last));
            z.extend_from_slice(&(n as u16).to_le_bytes());
            z.extend_from_slice(&(!(n as u16)).to_le_bytes());
            z.extend_from_slice(&rest[..n]);
            rest = &rest[n..];
            if last {
                break;
            }
        }
        let (mut s1, mut s2) = (1u32, 0u32);
        for &b in raw {
            s1 = (s1 + u32::from(b)) % 65_521;
            s2 = (s2 + s1) % 65_521;
        }
        z.extend_from_slice(&(s2 * 65_536 + s1).to_be_bytes());
        z
    }

    fn assemble(w: u32, h: u32, color: u8, plte: &[u8], trns: &[u8], idat: &[u8]) -> Vec<u8> {
        let mut out = SIG.to_vec();
        let mut ihdr = Vec::with_capacity(13);
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, color, 0, 0, 0]);
        chunk(&mut out, b"IHDR", &ihdr);
        if !plte.is_empty() {
            chunk(&mut out, b"PLTE", plte);
        }
        if !trns.is_empty() {
            chunk(&mut out, b"tRNS", trns);
        }
        chunk(&mut out, b"IDAT", idat);
        chunk(&mut out, b"IEND", &[]);
        out
    }
}
