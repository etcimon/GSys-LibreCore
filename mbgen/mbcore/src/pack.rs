//! One-dimensional pack along an edge. Free parts stay in sidebar order and
//! may advance into a later gap. They never swap order to fill a hole.

/// Split a width into the start-side and end-side of the center.
/// An odd micrometre goes to the start side of the edge.
pub fn split_span(width_um: i64) -> (i64, i64) {
    let lo = width_um.div_euclid(2) + width_um.rem_euclid(2);
    let hi = width_um - lo;
    (lo, hi)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Interval {
    pub start: i64,
    pub end: i64,
}

impl Interval {
    pub fn from_center(s_um: i64, width_um: i64) -> Self {
        let (lo, hi) = split_span(width_um);
        Self {
            start: s_um - lo,
            end: s_um + hi,
        }
    }

    pub fn overlaps(self, other: Self) -> bool {
        self.start < other.end && other.start < self.end
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpanPart {
    pub id: String,
    pub order: u32,
    pub width_um: i64,
    pub s_um: i64,
    pub pinned: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackError {
    pub reason: String,
}

/// Pack `parts` into `[s_min, s_max]`. Pinned centers stay. Free centers are
/// rewritten. `gap_um` is the clear space required between courtyards.
pub fn pack_edge(s_min: i64, s_max: i64, gap_um: i64, parts: &mut [SpanPart]) -> Result<(), PackError> {
    if s_max < s_min {
        return Err(PackError {
            reason: "edge interval is empty".into(),
        });
    }
    let mut pins: Vec<Interval> = Vec::new();
    for part in parts.iter().filter(|p| p.pinned) {
        let iv = Interval::from_center(part.s_um, part.width_um);
        if iv.start < s_min || iv.end > s_max {
            return Err(PackError {
                reason: format!("{} is outside the edge", part.id),
            });
        }
        for earlier in &pins {
            let separated = iv.start >= earlier.end + gap_um || earlier.start >= iv.end + gap_um;
            if !separated {
                return Err(PackError {
                    reason: format!("{} overlaps a pinned part", part.id),
                });
            }
        }
        pins.push(iv);
    }
    pins.sort_by_key(|iv| iv.start);

    let mut gaps: Vec<(i64, i64)> = Vec::new();
    let mut cursor = s_min;
    for pin in &pins {
        let limit = pin.start - gap_um;
        if limit > cursor {
            gaps.push((cursor, limit));
        }
        cursor = pin.end + gap_um;
    }
    if s_max > cursor {
        gaps.push((cursor, s_max));
    }

    let mut free: Vec<usize> = parts
        .iter()
        .enumerate()
        .filter(|(_, p)| !p.pinned)
        .map(|(i, _)| i)
        .collect();
    free.sort_by_key(|&i| parts[i].order);

    let mut gap_idx = 0usize;
    let mut at = gaps.first().map(|g| g.0).unwrap_or(s_min);
    for idx in free {
        let width = parts[idx].width_um;
        let (lo, _) = split_span(width);
        loop {
            if gap_idx >= gaps.len() {
                return Err(PackError {
                    reason: format!("{} does not fit on the edge", parts[idx].id),
                });
            }
            let (g0, g1) = gaps[gap_idx];
            let start = at.max(g0);
            if start + width <= g1 {
                parts[idx].s_um = start + lo;
                at = start + width + gap_um;
                break;
            }
            gap_idx += 1;
            if gap_idx < gaps.len() {
                at = gaps[gap_idx].0;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn odd_width_gives_the_extra_micrometre_to_the_start_side() {
        assert_eq!(split_span(15_001), (7_501, 7_500));
        assert_eq!(split_span(15_000), (7_500, 7_500));
    }

    #[test]
    fn free_parts_pack_from_the_start_without_overlap() {
        let mut parts = vec![
            part("a", 0, 15_000, false),
            part("b", 1, 16_000, false),
            part("c", 2, 15_000, false),
        ];
        pack_edge(0, 158_750, 1_500, &mut parts).unwrap();
        let intervals: Vec<_> = parts
            .iter()
            .map(|p| Interval::from_center(p.s_um, p.width_um))
            .collect();
        assert_eq!(intervals[0].start, 0);
        assert!(intervals[1].start >= intervals[0].end + 1_500);
        assert!(intervals[2].start >= intervals[1].end + 1_500);
        assert!(intervals[2].end <= 158_750);
    }

    #[test]
    fn a_part_that_cannot_fit_before_a_pin_uses_the_later_gap() {
        let mut parts = vec![
            SpanPart {
                id: "pin".into(),
                order: 0,
                width_um: 20_000,
                s_um: 30_000,
                pinned: true,
            },
            part("jack", 1, 20_000, false),
        ];
        // Pin occupies [20_000, 40_000]. The left gap is 18_500 long, short
        // of 20_000. The jack sits after the pin and keeps its order.
        pack_edge(0, 100_000, 1_500, &mut parts).unwrap();
        let jack = Interval::from_center(parts[1].s_um, parts[1].width_um);
        assert!(jack.start >= 40_000 + 1_500);
    }

    #[test]
    fn pinned_parts_that_overlap_are_rejected() {
        let mut parts = vec![
            SpanPart {
                id: "a".into(),
                order: 0,
                width_um: 20_000,
                s_um: 20_000,
                pinned: true,
            },
            SpanPart {
                id: "b".into(),
                order: 1,
                width_um: 20_000,
                s_um: 25_000,
                pinned: true,
            },
        ];
        let err = pack_edge(0, 100_000, 1_500, &mut parts).unwrap_err();
        assert!(err.reason.contains("overlaps"));
    }

    fn part(id: &str, order: u32, width: i64, pinned: bool) -> SpanPart {
        SpanPart {
            id: id.into(),
            order,
            width_um: width,
            s_um: 0,
            pinned,
        }
    }
}
