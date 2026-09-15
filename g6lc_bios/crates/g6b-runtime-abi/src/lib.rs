// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

#![no_std]
#![forbid(unsafe_code)]
#![allow(missing_docs)]

mod context;
mod heap;
pub use context::{ContextTable, Continuation, EXC_PAY_CELLS, RUNTIME_CTX_MAX};
pub use heap::{Bump, HEAP_ALIGN};

pub const ABI_VERSION: u16 = 1;
pub const REQUEST_BYTES: usize = 64;
const MAGIC: &[u8; 4] = b"G6SR";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Length,
    Magic,
    Version,
    Reserved,
    Opcode,
    Context,
    RequestId,
    Overflow,
    Bounds,
    Overlap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u16)]
pub enum Operation {
    Capabilities = 0,
    BootStatus = 1,
    BootTrial = 2,
    Poll = 3,
    Cancel = 4,
    FetchStart = 5,
    UpdateStage = 6,
    UpdateApply = 7,
    FrameRead = 8,
    Input = 9,
    Login = 10,
    Logout = 11,
}

impl TryFrom<u16> for Operation {
    type Error = Error;

    fn try_from(value: u16) -> Result<Self, Error> {
        Ok(match value {
            0 => Self::Capabilities,
            1 => Self::BootStatus,
            2 => Self::BootTrial,
            3 => Self::Poll,
            4 => Self::Cancel,
            5 => Self::FetchStart,
            6 => Self::UpdateStage,
            7 => Self::UpdateApply,
            8 => Self::FrameRead,
            9 => Self::Input,
            10 => Self::Login,
            11 => Self::Logout,
            _ => return Err(Error::Opcode),
        })
    }
}

pub const RESPONSE_BYTES: usize = 32;
pub const NATIVE_FRAME_BYTES: usize = 256;
pub const RESPONSE_OFFSET: usize = REQUEST_BYTES;
pub const PAYLOAD_OFFSET: usize = REQUEST_BYTES + RESPONSE_BYTES;
pub const CAPABILITIES_BYTES: usize = 16;
pub const CORE_OFFSET: usize = 128;
pub const CORE_BYTES: usize = NATIVE_FRAME_BYTES - CORE_OFFSET;
pub const POLL_REPORT_BYTES: usize = 16;
pub const INPUT_BYTES: usize = 8;
pub const CANCEL_BYTES: usize = 8;
pub const IRQ_WATCHDOG: u32 = 1;
pub const IRQ_INPUT: u32 = 2;
pub const IRQ_SLOW: u32 = 3;
pub const POLL_FLAG_WATCHDOG: u32 = 1;
pub const POLL_FLAG_QUOTA: u32 = 2;
pub const BOOT_CONTEXT: Context = Context {
    slot: 0,
    generation: 1,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Status {
    Ok = 0,
    InvalidRequest = 1,
    Unsupported = 2,
    NotReady = 3,
    BufferTooSmall = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Response {
    pub request_id: u64,
    pub status: Status,
    pub written: u32,
}

impl Response {
    pub fn encode(self) -> [u8; RESPONSE_BYTES] {
        let mut bytes = [0; RESPONSE_BYTES];
        bytes[..4].copy_from_slice(b"G6SP");
        bytes[4..6].copy_from_slice(&ABI_VERSION.to_le_bytes());
        bytes[6..8].copy_from_slice(&(RESPONSE_BYTES as u16).to_le_bytes());
        bytes[8..12].copy_from_slice(&(self.status as u32).to_le_bytes());
        bytes[16..24].copy_from_slice(&self.request_id.to_le_bytes());
        bytes[24..28].copy_from_slice(&self.written.to_le_bytes());
        bytes
    }

    pub fn decode(bytes: &[u8], request_id: u64, capacity: u64) -> Result<Self, Error> {
        if bytes.len() != RESPONSE_BYTES
            || u16::from_le_bytes(bytes[6..8].try_into().unwrap()) as usize != RESPONSE_BYTES
        {
            return Err(Error::Length);
        }
        if &bytes[..4] != b"G6SP" {
            return Err(Error::Magic);
        }
        if u16::from_le_bytes(bytes[4..6].try_into().unwrap()) != ABI_VERSION {
            return Err(Error::Version);
        }
        if bytes[12..16].iter().chain(&bytes[28..32]).any(|&b| b != 0) {
            return Err(Error::Reserved);
        }
        let status = match u32::from_le_bytes(bytes[8..12].try_into().unwrap()) {
            0 => Status::Ok,
            1 => Status::InvalidRequest,
            2 => Status::Unsupported,
            3 => Status::NotReady,
            4 => Status::BufferTooSmall,
            _ => return Err(Error::Opcode),
        };
        let actual_id = u64::from_le_bytes(bytes[16..24].try_into().unwrap());
        if request_id == 0 || actual_id != request_id {
            return Err(Error::RequestId);
        }
        let written = u32::from_le_bytes(bytes[24..28].try_into().unwrap());
        if u64::from(written) > capacity || (status != Status::Ok && written != 0) {
            return Err(Error::Length);
        }
        Ok(Self {
            request_id,
            status,
            written,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Context {
    pub slot: u32,
    pub generation: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Span {
    pub address: u64,
    pub length: u64,
}

impl Span {
    pub fn end(self) -> Result<u64, Error> {
        self.address.checked_add(self.length).ok_or(Error::Overflow)
    }

    pub fn within(self, window: Span) -> Result<(), Error> {
        let end = self.end()?;
        let bound = window.end()?;
        if self == Self::default() {
            return Ok(());
        }
        if self.address < window.address || end > bound {
            return Err(Error::Bounds);
        }
        Ok(())
    }

    pub fn overlaps(self, other: Self) -> Result<bool, Error> {
        Ok(self.length != 0
            && other.length != 0
            && self.address < other.end()?
            && other.address < self.end()?)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Request {
    pub operation: Operation,
    pub request_id: u64,
    pub context: Context,
    pub input: Span,
    pub output: Span,
}

impl Request {
    pub fn encode(self) -> [u8; REQUEST_BYTES] {
        let mut bytes = [0; REQUEST_BYTES];
        bytes[..4].copy_from_slice(MAGIC);
        bytes[4..6].copy_from_slice(&ABI_VERSION.to_le_bytes());
        bytes[6..8].copy_from_slice(&(REQUEST_BYTES as u16).to_le_bytes());
        bytes[8..10].copy_from_slice(&(self.operation as u16).to_le_bytes());
        bytes[16..24].copy_from_slice(&self.request_id.to_le_bytes());
        bytes[24..28].copy_from_slice(&self.context.slot.to_le_bytes());
        bytes[28..32].copy_from_slice(&self.context.generation.to_le_bytes());
        for (at, word) in [
            (32, self.input.address),
            (40, self.input.length),
            (48, self.output.address),
            (56, self.output.length),
        ] {
            bytes[at..at + 8].copy_from_slice(&word.to_le_bytes());
        }
        bytes
    }

    pub fn decode(
        bytes: &[u8],
        context: Context,
        memory: Span,
        request_storage: Span,
    ) -> Result<Self, Error> {
        if bytes.len() != REQUEST_BYTES {
            return Err(Error::Length);
        }
        if bytes[..4] != MAGIC[..] {
            return Err(Error::Magic);
        }
        let short = |at| u16::from_le_bytes(bytes[at..at + 2].try_into().unwrap());
        let word = |at| u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap());
        if short(4) != ABI_VERSION {
            return Err(Error::Version);
        }
        if short(6) as usize != REQUEST_BYTES {
            return Err(Error::Length);
        }
        if bytes[10..16].iter().any(|&byte| byte != 0) {
            return Err(Error::Reserved);
        }
        let operation = Operation::try_from(short(8))?;
        let request_id = word(16);
        if request_id == 0 {
            return Err(Error::RequestId);
        }
        let actual = Context {
            slot: u32::from_le_bytes(bytes[24..28].try_into().unwrap()),
            generation: u32::from_le_bytes(bytes[28..32].try_into().unwrap()),
        };
        if context.generation == 0 || actual != context {
            return Err(Error::Context);
        }
        if request_storage.length != REQUEST_BYTES as u64 {
            return Err(Error::Length);
        }
        request_storage.within(memory)?;
        let input = Span {
            address: word(32),
            length: word(40),
        };
        let output = Span {
            address: word(48),
            length: word(56),
        };
        input.within(memory)?;
        output.within(memory)?;
        if output.overlaps(input)? || output.overlaps(request_storage)? {
            return Err(Error::Overlap);
        }
        Ok(Self {
            operation,
            request_id,
            context: actual,
            input,
            output,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTEXT: Context = Context {
        slot: 3,
        generation: 7,
    };
    const MEMORY: Span = Span {
        address: 0x8000_0000,
        length: 0x1000,
    };
    const STORAGE: Span = Span {
        address: 0x8000_0000,
        length: REQUEST_BYTES as u64,
    };

    fn request() -> Request {
        Request {
            operation: Operation::BootStatus,
            request_id: 123,
            context: CONTEXT,
            input: Span {
                address: 0x8000_0040,
                length: 8,
            },
            output: Span {
                address: 0x8000_0100,
                length: 256,
            },
        }
    }

    fn decode(request: Request) -> Result<Request, Error> {
        Request::decode(&request.encode(), CONTEXT, MEMORY, STORAGE)
    }

    #[test]
    fn wire_layout_and_exact_round_trip() {
        let request = request();
        assert_eq!(&request.encode()[..10], b"G6SR\x01\0\x40\0\x01\0");
        assert_eq!(decode(request), Ok(request));
    }

    #[test]
    fn every_short_header_is_rejected_without_reading_past_it() {
        let bytes = request().encode();
        for length in 0..REQUEST_BYTES {
            assert_eq!(
                Request::decode(&bytes[..length], CONTEXT, MEMORY, STORAGE),
                Err(Error::Length)
            );
        }
    }

    #[test]
    fn unsupported_version_flags_and_opcode_fail_closed() {
        for (at, expected) in [
            (0, Error::Magic),
            (4, Error::Version),
            (6, Error::Length),
            (8, Error::Opcode),
            (10, Error::Reserved),
            (15, Error::Reserved),
        ] {
            let mut bytes = request().encode();
            bytes[at] = 255;
            assert_eq!(
                Request::decode(&bytes, CONTEXT, MEMORY, STORAGE),
                Err(expected)
            );
        }
    }

    #[test]
    fn foreign_and_stale_contexts_and_zero_request_ids_are_rejected() {
        let mut request = request();
        request.context.generation += 1;
        assert_eq!(decode(request), Err(Error::Context));
        request.context = Context { slot: 4, ..CONTEXT };
        assert_eq!(decode(request), Err(Error::Context));
        request.context = CONTEXT;
        request.request_id = 0;
        assert_eq!(decode(request), Err(Error::RequestId));
    }

    #[test]
    fn overflow_out_of_bounds_and_writable_aliases_are_rejected() {
        let mut request = request();
        request.output = Span {
            address: u64::MAX,
            length: 1,
        };
        assert_eq!(decode(request), Err(Error::Overflow));
        request.output = Span {
            address: 0x8000_0ff0,
            length: 17,
        };
        assert_eq!(decode(request), Err(Error::Bounds));
        request.output = request.input;
        assert_eq!(decode(request), Err(Error::Overlap));
        request.output = STORAGE;
        assert_eq!(decode(request), Err(Error::Overlap));
        request.output = Span {
            address: 0x7fff_ffff,
            length: 1,
        };
        assert_eq!(decode(request), Err(Error::Bounds));
    }

    #[test]
    fn empty_spans_and_exact_memory_boundary_are_supported() {
        let mut request = request();
        request.input = Span::default();
        request.output = Span {
            address: 0x8000_0f00,
            length: 256,
        };
        assert_eq!(decode(request), Ok(request));
        request.output = Span {
            address: 0x8000_1000,
            length: 0,
        };
        assert_eq!(decode(request), Ok(request));
        let bad_memory = Span {
            address: u64::MAX,
            length: 1,
        };
        assert_eq!(
            Request::decode(&request.encode(), CONTEXT, bad_memory, STORAGE),
            Err(Error::Overflow)
        );
    }
}
