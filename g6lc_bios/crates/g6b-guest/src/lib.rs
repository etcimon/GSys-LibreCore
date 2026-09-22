// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

#![no_std]
#![forbid(unsafe_code)]
#![allow(missing_docs)]

mod service;

use g6b_runtime_abi::{
    Operation, Request, Response, Span, Status, ABI_VERSION, BOOT_CONTEXT, CANCEL_BYTES,
    CAPABILITIES_BYTES, INPUT_BYTES, IRQ_SLOW, IRQ_WATCHDOG, NATIVE_FRAME_BYTES, PAYLOAD_OFFSET,
    POLL_REPORT_BYTES, REQUEST_BYTES, RESPONSE_BYTES, RESPONSE_OFFSET,
};

/// Keeps `native_entry` live in the `staticlib` object. `#[no_mangle]` is
/// refused by workspace `unsafe_code = forbid`; the linker script aliases
/// the rustc-mangled symbol as `__g6b_native_entry`.
#[cfg(feature = "native")]
#[used]
static NATIVE_ENTRY: extern "C" fn(&mut [u8; NATIVE_FRAME_BYTES]) -> u32 = native_entry;

/// C ABI entry for the composed BIOS `jalr`. This is a service callee, not
/// firmware `_start`; OpenSBI next-stage entry stays in the generated ASM
/// payload. IRQ-class operations only enqueue; `Poll` runs bounded work.
pub extern "C" fn native_entry(frame: &mut [u8; NATIVE_FRAME_BYTES]) -> u32 {
    dispatch(frame) as u32
}

pub fn dispatch(frame: &mut [u8; NATIVE_FRAME_BYTES]) -> Status {
    let request = match Request::decode(
        &frame[..REQUEST_BYTES],
        BOOT_CONTEXT,
        Span {
            address: 0,
            length: NATIVE_FRAME_BYTES as u64,
        },
        Span {
            address: 0,
            length: REQUEST_BYTES as u64,
        },
    ) {
        Ok(request) => request,
        Err(_) => return Status::InvalidRequest,
    };
    if [request.input, request.output]
        .iter()
        .any(|span| span.length != 0 && span.address < PAYLOAD_OFFSET as u64)
    {
        return Status::InvalidRequest;
    }
    let (status, written) = match request.operation {
        Operation::Capabilities if request.input.length != 0 => (Status::InvalidRequest, 0),
        Operation::Capabilities if request.output.length < CAPABILITIES_BYTES as u64 => {
            (Status::BufferTooSmall, 0)
        }
        Operation::Capabilities => {
            service::init(frame);
            let mut payload = [0u8; CAPABILITIES_BYTES];
            payload[..2].copy_from_slice(&ABI_VERSION.to_le_bytes());
            payload[4..8].copy_from_slice(&(REQUEST_BYTES as u32).to_le_bytes());
            payload[8..12].copy_from_slice(&(NATIVE_FRAME_BYTES as u32).to_le_bytes());
            payload[12..16].copy_from_slice(&service::implemented_mask().to_le_bytes());
            let start = request.output.address as usize;
            frame[start..start + CAPABILITIES_BYTES].copy_from_slice(&payload);
            (Status::Ok, CAPABILITIES_BYTES as u32)
        }
        Operation::Input => match input_args(frame, &request) {
            None => (Status::InvalidRequest, 0),
            Some((kind, token)) => {
                if !service::ready(frame) {
                    (Status::NotReady, 0)
                } else if service::enqueue(frame, kind, token) {
                    (Status::Ok, 0)
                } else if kind == IRQ_WATCHDOG {
                    (Status::BufferTooSmall, 0)
                } else {
                    (Status::Ok, 0)
                }
            }
        },
        Operation::Poll if request.output.length < POLL_REPORT_BYTES as u64 => {
            (Status::BufferTooSmall, 0)
        }
        Operation::Poll => {
            if !service::ready(frame) {
                (Status::NotReady, 0)
            } else {
                let (quota, now) = poll_args(frame, &request);
                let report = service::poll(frame, quota, now);
                let start = request.output.address as usize;
                frame[start..start + POLL_REPORT_BYTES].copy_from_slice(&report);
                (Status::Ok, POLL_REPORT_BYTES as u32)
            }
        }
        Operation::Cancel => match cancel_args(frame, &request) {
            None => (Status::InvalidRequest, 0),
            Some((slot, generation)) => {
                if service::cancel(frame, slot, generation) {
                    (Status::Ok, 0)
                } else {
                    (Status::InvalidRequest, 0)
                }
            }
        },
        Operation::BootStatus | Operation::BootTrial => (Status::NotReady, 0),
        _ => (Status::Unsupported, 0),
    };
    let response = Response {
        request_id: request.request_id,
        status,
        written,
    };
    frame[RESPONSE_OFFSET..RESPONSE_OFFSET + RESPONSE_BYTES].copy_from_slice(&response.encode());
    status
}

fn span_bytes(frame: &[u8; NATIVE_FRAME_BYTES], span: Span, need: u64) -> Option<&[u8]> {
    if span.length < need {
        return None;
    }
    let start = span.address as usize;
    let end = start.checked_add(need as usize)?;
    frame.get(start..end)
}

fn input_args(frame: &[u8; NATIVE_FRAME_BYTES], request: &Request) -> Option<(u32, u32)> {
    let bytes = span_bytes(frame, request.input, INPUT_BYTES as u64)?;
    let kind = u32::from_le_bytes(bytes[..4].try_into().ok()?);
    let token = u32::from_le_bytes(bytes[4..8].try_into().ok()?);
    if kind != IRQ_WATCHDOG && kind != g6b_runtime_abi::IRQ_INPUT && kind != IRQ_SLOW {
        return None;
    }
    Some((kind, token))
}

fn poll_args(frame: &[u8; NATIVE_FRAME_BYTES], request: &Request) -> (u32, u32) {
    span_bytes(frame, request.input, 8)
        .map(|bytes| {
            (
                u32::from_le_bytes(bytes[..4].try_into().unwrap()),
                u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
            )
        })
        .unwrap_or((0, 0))
}

fn cancel_args(frame: &[u8; NATIVE_FRAME_BYTES], request: &Request) -> Option<(u32, u32)> {
    let bytes = span_bytes(frame, request.input, CANCEL_BYTES as u64)?;
    Some((
        u32::from_le_bytes(bytes[..4].try_into().ok()?),
        u32::from_le_bytes(bytes[4..8].try_into().ok()?),
    ))
}

#[cfg(all(feature = "native", not(test)))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_runtime_abi::{IRQ_INPUT, POLL_FLAG_WATCHDOG};

    fn frame(operation: Operation) -> [u8; NATIVE_FRAME_BYTES] {
        request_frame(operation, Span::default(), default_output())
    }

    fn default_output() -> Span {
        Span {
            address: PAYLOAD_OFFSET as u64,
            length: CAPABILITIES_BYTES as u64,
        }
    }

    fn request_frame(operation: Operation, input: Span, output: Span) -> [u8; NATIVE_FRAME_BYTES] {
        let mut frame = [0xa5; NATIVE_FRAME_BYTES];
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation,
                request_id: 42,
                context: BOOT_CONTEXT,
                input,
                output,
            }
            .encode(),
        );
        frame
    }

    fn response(frame: &[u8; NATIVE_FRAME_BYTES]) -> Response {
        Response::decode(
            &frame[RESPONSE_OFFSET..PAYLOAD_OFFSET],
            42,
            CAPABILITIES_BYTES as u64,
        )
        .unwrap()
    }

    fn put_input(frame: &mut [u8; NATIVE_FRAME_BYTES], kind: u32, token: u32) {
        let start = PAYLOAD_OFFSET;
        frame[start..start + 4].copy_from_slice(&kind.to_le_bytes());
        frame[start + 4..start + 8].copy_from_slice(&token.to_le_bytes());
        let input = Span {
            address: PAYLOAD_OFFSET as u64,
            length: INPUT_BYTES as u64,
        };
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Input,
                request_id: 42,
                context: BOOT_CONTEXT,
                input,
                output: Span::default(),
            }
            .encode(),
        );
    }

    #[test]
    fn native_entry_reports_poll_cancel_and_input() {
        let mut frame = frame(Operation::Capabilities);
        let before = frame;
        assert_eq!(native_entry(&mut frame), Status::Ok as u32);
        assert_eq!(response(&frame).written, CAPABILITIES_BYTES as u32);
        assert_eq!(
            &frame[PAYLOAD_OFFSET..PAYLOAD_OFFSET + 16],
            &[
                1,
                0,
                0,
                0,
                64,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                service::implemented_mask() as u8,
                (service::implemented_mask() >> 8) as u8,
                0,
                0
            ]
        );
        assert_eq!(&frame[..REQUEST_BYTES], &before[..REQUEST_BYTES]);
    }

    #[test]
    fn absent_backends_never_report_success_or_touch_output() {
        let mut boot = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut boot), Status::Ok);
        for operation in [
            Operation::BootStatus,
            Operation::FetchStart,
            Operation::UpdateStage,
            Operation::UpdateApply,
            Operation::FrameRead,
            Operation::Login,
            Operation::Logout,
        ] {
            let mut frame = boot;
            frame[..REQUEST_BYTES].copy_from_slice(
                &Request {
                    operation,
                    request_id: 42,
                    context: BOOT_CONTEXT,
                    input: Span::default(),
                    output: default_output(),
                }
                .encode(),
            );
            let before = frame;
            let expected = if operation == Operation::BootStatus {
                Status::NotReady
            } else {
                Status::Unsupported
            };
            assert_eq!(dispatch(&mut frame), expected);
            assert_eq!(
                response(&frame),
                Response {
                    request_id: 42,
                    status: expected,
                    written: 0
                }
            );
            assert_eq!(&frame[PAYLOAD_OFFSET..], &before[PAYLOAD_OFFSET..]);
        }
    }

    #[test]
    fn irq_enqueue_does_not_run_slow_work() {
        let mut frame = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_SLOW, 8);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        assert_eq!(response(&frame).written, 0);
        let jobs = &frame[g6b_runtime_abi::CORE_OFFSET + 44..g6b_runtime_abi::CORE_OFFSET + 108];
        assert!(
            jobs.iter().all(|&b| b == 0),
            "Input must not admit slow jobs"
        );
    }

    #[test]
    fn poll_services_watchdog_before_slow_io() {
        let mut frame = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_SLOW, 8);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_WATCHDOG, 1);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Poll,
                request_id: 42,
                context: BOOT_CONTEXT,
                input: Span::default(),
                output: Span {
                    address: PAYLOAD_OFFSET as u64,
                    length: POLL_REPORT_BYTES as u64,
                },
            }
            .encode(),
        );
        assert_eq!(dispatch(&mut frame), Status::Ok);
        let units = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET..PAYLOAD_OFFSET + 4]
                .try_into()
                .unwrap(),
        );
        let remaining = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET + 4..PAYLOAD_OFFSET + 8]
                .try_into()
                .unwrap(),
        );
        let hits = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET + 8..PAYLOAD_OFFSET + 12]
                .try_into()
                .unwrap(),
        );
        let flags = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET + 12..PAYLOAD_OFFSET + 16]
                .try_into()
                .unwrap(),
        );
        assert!(units >= 1);
        assert_eq!(hits, 1);
        assert_ne!(flags & POLL_FLAG_WATCHDOG, 0);
        assert!(remaining > 0);
    }

    #[test]
    fn poll_second_tick_continues_remaining_slow() {
        let mut frame = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_SLOW, 8);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_WATCHDOG, 1);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Poll,
                request_id: 42,
                context: BOOT_CONTEXT,
                input: Span::default(),
                output: Span {
                    address: PAYLOAD_OFFSET as u64,
                    length: POLL_REPORT_BYTES as u64,
                },
            }
            .encode(),
        );
        assert_eq!(dispatch(&mut frame), Status::Ok);
        let first = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET + 4..PAYLOAD_OFFSET + 8]
                .try_into()
                .unwrap(),
        );
        assert!(first > 0);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        let second = u32::from_le_bytes(
            frame[PAYLOAD_OFFSET + 4..PAYLOAD_OFFSET + 8]
                .try_into()
                .unwrap(),
        );
        assert!(second < first);
    }

    #[test]
    fn cancel_tears_down_only_the_named_context() {
        let mut frame = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        put_input(&mut frame, IRQ_SLOW, 8);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Poll,
                request_id: 42,
                context: BOOT_CONTEXT,
                input: Span::default(),
                output: Span {
                    address: PAYLOAD_OFFSET as u64,
                    length: POLL_REPORT_BYTES as u64,
                },
            }
            .encode(),
        );
        assert_eq!(dispatch(&mut frame), Status::Ok);
        frame[PAYLOAD_OFFSET..PAYLOAD_OFFSET + 4].copy_from_slice(&0u32.to_le_bytes());
        frame[PAYLOAD_OFFSET + 4..PAYLOAD_OFFSET + 8].copy_from_slice(&1u32.to_le_bytes());
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Cancel,
                request_id: 42,
                context: BOOT_CONTEXT,
                input: Span {
                    address: PAYLOAD_OFFSET as u64,
                    length: CANCEL_BYTES as u64,
                },
                output: Span::default(),
            }
            .encode(),
        );
        assert_eq!(dispatch(&mut frame), Status::Ok);
        assert_eq!(dispatch(&mut frame), Status::InvalidRequest);
        frame[PAYLOAD_OFFSET..PAYLOAD_OFFSET + 4].copy_from_slice(&1u32.to_le_bytes());
        frame[PAYLOAD_OFFSET + 4..PAYLOAD_OFFSET + 8].copy_from_slice(&1u32.to_le_bytes());
        frame[..REQUEST_BYTES].copy_from_slice(
            &Request {
                operation: Operation::Cancel,
                request_id: 42,
                context: BOOT_CONTEXT,
                input: Span {
                    address: PAYLOAD_OFFSET as u64,
                    length: CANCEL_BYTES as u64,
                },
                output: Span::default(),
            }
            .encode(),
        );
        assert_eq!(dispatch(&mut frame), Status::Ok);
    }

    #[test]
    fn malformed_context_and_metadata_aliases_have_no_writes() {
        for (at, value) in [(4, 2), (28, 0), (48, 64), (48, 80)] {
            let mut frame = frame(Operation::Capabilities);
            frame[at] = value;
            let before = frame;
            assert_eq!(dispatch(&mut frame), Status::InvalidRequest);
            assert_eq!(frame, before);
        }
    }

    #[test]
    fn short_output_is_an_error_without_partial_payload() {
        let mut frame = frame(Operation::Capabilities);
        frame[56..64].copy_from_slice(&15u64.to_le_bytes());
        let before = frame;
        assert_eq!(dispatch(&mut frame), Status::BufferTooSmall);
        assert_eq!(response(&frame).written, 0);
        assert_eq!(&frame[PAYLOAD_OFFSET..], &before[PAYLOAD_OFFSET..]);
    }

    #[test]
    fn response_validation_rejects_short_stale_and_oversized_replies() {
        let reply = Response {
            request_id: 42,
            status: Status::Ok,
            written: 16,
        }
        .encode();
        for size in 0..RESPONSE_BYTES {
            assert!(Response::decode(&reply[..size], 42, 16).is_err());
        }
        assert!(Response::decode(&reply, 43, 16).is_err());
        assert!(Response::decode(&reply, 42, 15).is_err());
        let reply = Response {
            request_id: 42,
            status: Status::Unsupported,
            written: 1,
        }
        .encode();
        assert!(Response::decode(&reply, 42, 16).is_err());
    }

    #[test]
    fn boot_ops_inhibit_without_durable_journal() {
        let mut frame = frame(Operation::Capabilities);
        assert_eq!(dispatch(&mut frame), Status::Ok);
        for operation in [Operation::BootStatus, Operation::BootTrial] {
            frame[..REQUEST_BYTES].copy_from_slice(
                &Request {
                    operation,
                    request_id: 42,
                    context: BOOT_CONTEXT,
                    input: Span::default(),
                    output: Span::default(),
                }
                .encode(),
            );
            let before = frame;
            assert_eq!(dispatch(&mut frame), Status::NotReady);
            assert_eq!(response(&frame).written, 0);
            assert_eq!(&frame[PAYLOAD_OFFSET..], &before[PAYLOAD_OFFSET..]);
        }
    }

    #[test]
    fn poll_without_init_is_not_ready() {
        let mut frame = request_frame(
            Operation::Poll,
            Span::default(),
            Span {
                address: PAYLOAD_OFFSET as u64,
                length: POLL_REPORT_BYTES as u64,
            },
        );
        let before = frame;
        assert_eq!(dispatch(&mut frame), Status::NotReady);
        assert_eq!(&frame[PAYLOAD_OFFSET..], &before[PAYLOAD_OFFSET..]);
        let _ = IRQ_INPUT;
    }
}
