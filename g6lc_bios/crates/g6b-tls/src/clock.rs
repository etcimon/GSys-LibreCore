// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Trusted time for certificate validity. Counters and `Instant` are not
//! trusted time. Absent time fails closed.

/// Unix seconds. Not a tick counter.
pub trait Clock {
    fn unix_seconds(&self) -> Result<u64, String>;
}

/// Production default: no virtio RTC / board clock is wired yet.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoClock;

impl Clock for NoClock {
    fn unix_seconds(&self) -> Result<u64, String> {
        Err("tls: no trusted time".into())
    }
}

/// Test-only. Not wall-clock, not `rdtime`.
#[derive(Clone, Copy, Debug)]
pub struct FixtureClock {
    pub unix: u64,
}

impl Clock for FixtureClock {
    fn unix_seconds(&self) -> Result<u64, String> {
        Ok(self.unix)
    }
}

/// Device-supplied unix seconds (8-byte BE). Empty/short fails closed.
/// Not `rdtime`, not a host wall clock, not QEMU virtio-rtc proof.
#[derive(Clone, Debug, Default)]
pub struct VirtioRtc {
    unix: Option<u64>,
}

impl VirtioRtc {
    pub fn from_device(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() < 8 {
            return Err("tls: virtio-rtc short".into());
        }
        let mut b = [0u8; 8];
        b.copy_from_slice(&bytes[..8]);
        Ok(Self {
            unix: Some(u64::from_be_bytes(b)),
        })
    }
}

impl Clock for VirtioRtc {
    fn unix_seconds(&self) -> Result<u64, String> {
        self.unix.ok_or_else(|| "tls: no virtio-rtc".into())
    }
}

/// `notBefore <= now <= notAfter`. Needs a clock; does not skip on failure.
pub fn check_validity(not_before: u64, not_after: u64, clock: &dyn Clock) -> Result<(), String> {
    if not_after < not_before {
        return Err("tls: inverted validity".into());
    }
    let now = clock.unix_seconds()?;
    if now < not_before {
        return Err("tls: certificate not yet valid".into());
    }
    if now > not_after {
        return Err("tls: certificate expired".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_clock_fails_closed() {
        assert!(NoClock.unix_seconds().unwrap_err().contains("time"));
        assert!(check_validity(1, 3, &NoClock).unwrap_err().contains("time"));
    }

    #[test]
    fn fixture_clock_enforces_window() {
        let c = FixtureClock { unix: 2 };
        check_validity(1, 3, &c).unwrap();
        assert!(check_validity(3, 5, &c).unwrap_err().contains("not yet"));
        assert!(check_validity(0, 1, &c).unwrap_err().contains("expired"));
    }

    #[test]
    fn virtio_rtc_fail_closed_then_reads() {
        assert!(VirtioRtc::from_device(&[1, 2, 3])
            .unwrap_err()
            .contains("virtio-rtc"));
        let t = VirtioRtc::from_device(&1_700_000_000u64.to_be_bytes()).unwrap();
        assert_eq!(t.unix_seconds().unwrap(), 1_700_000_000);
        check_validity(1_699_000_000, 1_701_000_000, &t).unwrap();
        assert!(VirtioRtc::default()
            .unix_seconds()
            .unwrap_err()
            .contains("virtio-rtc"));
    }
}
