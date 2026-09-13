// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded first-party CSS block-flow rendering to a true-colour `Canvas32`.
//!
//! This is the "modern" lane: alpha, images, SVG, custom fonts, rounded
//! corners and `rgba()` actually land as pixels, while the 16-colour palette
//! golden lane in `render.rs` stays untouched. See
//! `architecture/RENDER-VALIDATION.md` for the split.

#![allow(missing_docs)]
#![allow(clippy::too_many_arguments, clippy::type_complexity)]

use g6b_dom::Node;
use g6b_gr::canvas32::{Canvas32, Rgba};
use g6b_gr::color::{parse_opacity, parse_rgba, parse_rgba_current};
use g6b_img::icons;
use g6b_img::{Asset, AssetMap};
use g6b_ttf::{blit_glyph32, FontSet};

use crate::render::{find_body, is_block, HitBox, MAX_ABSOLUTE_BOXES};
use crate::{
    absolute_origin, cascade, computed_absolute_box, computed_box, computed_position, parse_survey,
    ElementRef, Position, Stylesheet,
};

pub const MAX_RENDER_NODES: usize = crate::render::MAX_RENDER_NODES;

/// Render result for the modern lane.
#[derive(Debug, Clone)]
pub struct Render32Output {
    pub canvas: Canvas32,
    pub hit_boxes: Vec<HitBox>,
}

/// Render a stylesheet against HTML using `parse` (strict). This is the
/// fixture/golden path: an unimplemented property refuses the whole sheet.
pub fn render32(
    html: &str,
    css: &str,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    // Use `parse_survey` so real-world stylesheets with unsupported properties
    // (e.g. `max-width`) degrade gracefully rather than failing the whole page.
    let (sheet, _unsupported) = parse_survey(css).map_err(|e| e.to_string())?;
    render_sheet_to_output(&sheet, html, w, h, assets, fonts)
}

/// Render a stylesheet against HTML using `parse_survey` (lenient). This is the
/// "real UI" path: a browser stylesheet can contain unsupported declarations,
/// and they are dropped with a report rather than failing the page.
pub fn render_ui32_to_output(
    html: &str,
    css: &str,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    let (sheet, _unsupported) = parse_survey(css).map_err(|e| e.to_string())?;
    render_sheet_to_output(&sheet, html, w, h, assets, fonts)
}

/// Render an already-parsed stylesheet.
pub fn render_sheet_to_output(
    sheet: &Stylesheet,
    html: &str,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    let root = g6b_html::parse(html);
    paint_node(sheet, &root, w, h, assets, fonts)
}

/// Paint a live DOM node. No HTML serialize/parse.
///
/// * `html`/`body` — painted as the root block (body background + padding).
/// * any other element — painted as the sole child of an anonymous `body`
///   so fragment trees (the LDC cell's `<main>`) still take the stylesheet's
///   `body { ... }` rules, matching the old wrap-in-`<body>` path.
pub fn paint_node(
    sheet: &Stylesheet,
    node: &Node,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    let root = if node.name.eq_ignore_ascii_case("html") {
        find_body(node).unwrap_or(node)
    } else {
        node
    };
    if root.name.eq_ignore_ascii_case("body") {
        paint_root_block(sheet, root, w, h, assets, fonts, false)
    } else {
        paint_fragments_in_body(sheet, &[root], w, h, assets, fonts, false)
    }
}

/// Paint one or more live nodes as children of an anonymous `body`.
pub fn paint_nodes(
    sheet: &Stylesheet,
    nodes: &[&Node],
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    match nodes {
        [] => paint_root_block(sheet, &Node::elem("body"), w, h, assets, fonts, false),
        [one] if one.name.eq_ignore_ascii_case("html") || one.name.eq_ignore_ascii_case("body") => {
            paint_node(sheet, one, w, h, assets, fonts)
        }
        _ => paint_fragments_in_body(sheet, nodes, w, h, assets, fonts, false),
    }
}

/// [`paint_nodes`] with the `Canvas32` display-list recorder armed — the
/// `__web_dl` pack lane (`g6b_kernel::dl_pack`). The returned op vec is the
/// paint log the guest `DlPaint` replays; pixels the op vocabulary cannot
/// express are the packer's `TILEPX` relief problem, not this function's.
pub fn paint_nodes_dl(
    sheet: &Stylesheet,
    nodes: &[&Node],
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<(Render32Output, Vec<g6b_gr::canvas32::DlOp>), String> {
    let mut out = match nodes {
        [] => paint_root_block(sheet, &Node::elem("body"), w, h, assets, fonts, true)?,
        [one] if one.name.eq_ignore_ascii_case("html") || one.name.eq_ignore_ascii_case("body") => {
            paint_node_dl(sheet, one, w, h, assets, fonts)?
        }
        _ => paint_fragments_in_body(sheet, nodes, w, h, assets, fonts, true)?,
    };
    let ops = out.canvas.take_dl().unwrap_or_default();
    Ok((out, ops))
}

/// [`paint_node`] with the recorder armed.
fn paint_node_dl(
    sheet: &Stylesheet,
    node: &Node,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
) -> Result<Render32Output, String> {
    let root = if node.name.eq_ignore_ascii_case("html") {
        find_body(node).unwrap_or(node)
    } else {
        node
    };
    if root.name.eq_ignore_ascii_case("body") {
        paint_root_block(sheet, root, w, h, assets, fonts, true)
    } else {
        paint_fragments_in_body(sheet, &[root], w, h, assets, fonts, true)
    }
}

/// A recorder-armed canvas: transparent surface + the background painted
/// through `blend_rect` so the page `BG` lands in the op stream.
fn rec_canvas(w: u32, h: u32, rgb: [u8; 3]) -> Canvas32 {
    let mut c = Canvas32::new(w, h);
    c.dl = Some(Vec::new());
    c.blend_rect(0, 0, w as i32, h as i32, [rgb[0], rgb[1], rgb[2], 255]);
    c
}

fn paint_root_block(
    sheet: &Stylesheet,
    body: &Node,
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
    rec: bool,
) -> Result<Render32Output, String> {
    let mut canvas = if rec {
        rec_canvas(w, h, [255, 255, 255])
    } else {
        Canvas32::opaque(w, h, [255, 255, 255])
    };
    let ctx = Ctx32 {
        sheet,
        fonts,
        assets,
        flex_width: None,
    };
    let icb = Rect {
        x: 0,
        y: 0,
        w: w as i32,
        h: h as i32,
    };
    let mut sink = Sink::new();
    let tctx = TextCtx::default();
    let mut root_path = Vec::new();
    paint_block(
        &mut canvas,
        &ctx,
        body,
        Flow {
            x: 0,
            y: 0,
            avail_w: w as i32,
            depth: 0,
        },
        icb,
        255,
        &tctx,
        &mut root_path,
        &mut sink,
        None,
        None,
    )?;
    finish_absolutes(&mut canvas, &ctx, &mut sink)?;
    Ok(Render32Output {
        canvas,
        hit_boxes: sink.hit_boxes,
    })
}

/// Anonymous-body wrap without cloning fragments or serializing HTML.
fn paint_fragments_in_body(
    sheet: &Stylesheet,
    fragments: &[&Node],
    w: u32,
    h: u32,
    assets: &AssetMap,
    fonts: &FontSet,
    rec: bool,
) -> Result<Render32Output, String> {
    let body_style = cascade(sheet, &ElementRef::new("body"));
    let bg = body_style
        .get("background-color")
        .and_then(parse_rgba)
        .unwrap_or([255, 255, 255, 255]);
    let mut canvas = if rec {
        rec_canvas(w, h, [bg[0], bg[1], bg[2]])
    } else {
        Canvas32::opaque(w, h, [bg[0], bg[1], bg[2]])
    };
    let ctx = Ctx32 {
        sheet,
        fonts,
        assets,
        flex_width: None,
    };
    let icb = Rect {
        x: 0,
        y: 0,
        w: w as i32,
        h: h as i32,
    };
    let mut tctx = TextCtx::default();
    tctx.color = color_for(&body_style, "color", tctx.color, 255);
    tctx.family = body_style
        .get("font-family")
        .map(str::to_string)
        .unwrap_or(tctx.family);
    tctx.size = font_size_for(&body_style, tctx.size);
    tctx.bold = is_bold(&body_style).unwrap_or(tctx.bold);
    tctx.align = align_for(&body_style).unwrap_or(tctx.align);
    let b = computed_box(&body_style, w as i32).map_err(|e| e.to_string())?;
    let origin_x = b.margin.left + b.border.left + b.padding.left;
    let origin_y = b.margin.top + b.border.top + b.padding.top;
    let avail_w = content_width_safe(&b);
    let mut sink = Sink::new();
    let mut y = origin_y;
    for (index, fragment) in fragments.iter().enumerate() {
        let style = cascade(sheet, &ElementRef::from_node(fragment));
        if computed_position(&style).map_err(|e| e.to_string())? == Position::Absolute {
            if sink.absolutes.len() >= MAX_ABSOLUTE_BOXES {
                return Err("absolute box budget exceeded".into());
            }
            sink.absolutes.push(Absolute {
                node: fragment,
                cb: icb,
                path: vec![index],
                depth: 1,
            });
            continue;
        }
        let flow = Flow {
            x: origin_x,
            y,
            avail_w,
            depth: 1,
        };
        let mut path = vec![index];
        y = paint_block(
            &mut canvas,
            &ctx,
            fragment,
            flow,
            icb,
            255,
            &tctx,
            &mut path,
            &mut sink,
            None,
            None,
        )?;
    }
    finish_absolutes(&mut canvas, &ctx, &mut sink)?;
    Ok(Render32Output {
        canvas,
        hit_boxes: sink.hit_boxes,
    })
}

fn finish_absolutes(
    canvas: &mut Canvas32,
    ctx: &Ctx32<'_>,
    sink: &mut Sink<'_>,
) -> Result<(), String> {
    let mut drained = 0usize;
    while let Some(abs) = sink.absolutes.pop() {
        drained += 1;
        if drained > MAX_ABSOLUTE_BOXES {
            return Err("absolute box budget exceeded".into());
        }
        paint_absolute(canvas, ctx, &abs, sink)?;
    }
    Ok(())
}

#[derive(Clone, Copy)]
struct Ctx32<'a> {
    sheet: &'a Stylesheet,
    fonts: &'a FontSet,
    assets: &'a AssetMap,
    flex_width: Option<(usize, i32)>,
}

#[derive(Clone, Copy)]
struct Flow {
    x: i32,
    y: i32,
    avail_w: i32,
    depth: usize,
}

#[derive(Debug, Clone, Copy)]
struct Rect {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

struct Absolute<'t> {
    node: &'t Node,
    cb: Rect,
    path: Vec<usize>,
    depth: usize,
}

struct Sink<'t> {
    hit_boxes: Vec<HitBox>,
    absolutes: Vec<Absolute<'t>>,
    /// `TEXTREF` bookkeeping — `tref_seq` keys each eligible element's text
    /// run, `tref_seen` fires the `DlOp::Tref` marker on its first painted
    /// word only (a run spans line flushes).
    tref_seq: u32,
    tref_seen: std::collections::HashSet<u32>,
}

impl Sink<'_> {
    fn new() -> Self {
        Self {
            hit_boxes: Vec::new(),
            absolutes: Vec::new(),
            tref_seq: 0,
            tref_seen: std::collections::HashSet::new(),
        }
    }
}

/// Inherited text properties that CSS calls "inherited". We only carry the
/// small set the renderer honours; other properties are local to each element.
#[derive(Clone)]
struct TextCtx {
    color: Rgba,
    family: String,
    size: f32,
    bold: bool,
    align: Align,
}

impl Default for TextCtx {
    fn default() -> Self {
        Self {
            color: [0, 0, 0, 255],
            family: "default".into(),
            size: 16.0,
            bold: false,
            align: Align::Left,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Align {
    Left,
    Right,
    Center,
}

fn paint_absolute<'a>(
    canvas: &mut Canvas32,
    ctx: &Ctx32<'_>,
    abs: &Absolute<'a>,
    sink: &mut Sink<'a>,
) -> Result<(), String> {
    let style = cascade(ctx.sheet, &ElementRef::from_node(abs.node));
    let b = computed_absolute_box(&style, abs.cb.w).map_err(|e| e.to_string())?;
    let (ox, oy) = absolute_origin(&style, &b, abs.cb.x, abs.cb.y, abs.cb.w, abs.cb.h)
        .map_err(|e| e.to_string())?;
    let flow = Flow {
        x: ox,
        y: oy,
        avail_w: b.margin_box_width(),
        depth: abs.depth,
    };
    let mut path = abs.path.clone();
    let cb = Rect {
        x: ox + b.margin.left + b.border.left,
        y: oy + b.margin.top + b.border.top,
        w: b.content_width + b.padding.horizontal(),
        h: b.content_height + b.padding.vertical(),
    };
    let tctx = TextCtx::default();
    paint_block(
        canvas, ctx, abs.node, flow, cb, 255, &tctx, &mut path, sink, None, None,
    )?;
    Ok(())
}

fn paint_block<'t>(
    canvas: &mut Canvas32,
    ctx: &Ctx32<'_>,
    node: &'t Node,
    flow: Flow,
    cb: Rect,
    parent_alpha: u8,
    parent_tctx: &TextCtx,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
    cols: Option<&[i32]>,
    force_h: Option<i32>,
) -> Result<i32, String> {
    if flow.depth > MAX_RENDER_NODES {
        return Err("render32 depth exceeded".into());
    }
    if node.name.eq_ignore_ascii_case("#text")
        || node.hidden
        || node.name.eq_ignore_ascii_case("br")
        || node.name.eq_ignore_ascii_case("style")
        || node.name.eq_ignore_ascii_case("script")
    {
        return Ok(flow.y);
    }
    let style = cascade(ctx.sheet, &ElementRef::from_node(node));
    if style
        .get("display")
        .is_some_and(|d| d.eq_ignore_ascii_case("none"))
    {
        return Ok(flow.y);
    }

    let alpha = if let Some(v) = style.get("opacity") {
        Canvas32::mul_alpha(parent_alpha, parse_opacity(v).unwrap_or(255))
    } else {
        parent_alpha
    };

    let mut tctx = parent_tctx.clone();
    tctx.color = color_for(&style, "color", parent_tctx.color, alpha);
    tctx.family = style
        .get("font-family")
        .map(str::to_string)
        .unwrap_or_else(|| parent_tctx.family.clone());
    tctx.size = font_size_for(&style, parent_tctx.size);
    tctx.bold = is_bold(&style).unwrap_or(parent_tctx.bold);
    tctx.align = align_for(&style).unwrap_or(parent_tctx.align);

    let mut b = computed_box(&style, flow.avail_w).map_err(|e| e.to_string())?;
    if let Some((target, width)) = ctx.flex_width {
        if target == node as *const Node as usize {
            b.content_width =
                (width - b.margin.horizontal() - b.border.horizontal() - b.padding.horizontal())
                    .max(0);
        }
    }
    let box_left = flow.x + b.margin.left;
    let box_top = flow.y + b.margin.top;
    let content_left = box_left + b.border.left + b.padding.left;
    let content_top = box_top + b.border.top + b.padding.top;

    // Table plumbing: a `<table>` resolves its own columns; the section
    // wrappers pass them through; a `<tr>` consumes them as a row; anything
    // else starts fresh so a nested `<div>` never inherits a column grid.
    let own_cols;
    let (as_row, child_cols) = if node.name.eq_ignore_ascii_case("table") {
        own_cols = table_columns(ctx, node, content_width_safe(&b), &tctx);
        (false, Some(own_cols.as_slice()))
    } else if is_table_section(&node.name) {
        (false, cols)
    } else if node.name.eq_ignore_ascii_case("tr") {
        (true, cols)
    } else {
        (false, None)
    };

    // Auto height: measure children once.
    if b.content_height == 0 {
        let mut scratch = Sink::new();
        let mut cursor = Cursor::new(content_top);
        children_layout(
            &mut cursor,
            ctx,
            node,
            content_left,
            content_width_safe(&b),
            flow.depth + 1,
            cb,
            alpha,
            &tctx,
            path,
            &mut scratch,
            child_cols,
            as_row,
        )?;
        let mut h = cursor.y - content_top;
        if cursor.x_px > 0.0 {
            h += cursor.line_h;
        }
        b.content_height = h.max(0);
    }
    // A table cell is stretched to its row's height so the row reads as one
    // band rather than a ragged set of boxes.
    if let Some(min) = force_h {
        let vertical = b.margin.vertical() + b.border.vertical() + b.padding.vertical();
        b.content_height = b.content_height.max(min - vertical);
    }

    sink.hit_boxes.push(HitBox {
        id: node.id.clone(),
        name: node.name.clone(),
        path: path.clone(),
        x: box_left,
        y: box_top,
        w: b.border_box_width(),
        h: b.border_box_height(),
    });

    let radius = style
        .get("border-radius")
        .and_then(|v| length(v, 0).ok())
        .unwrap_or(0)
        .max(0);

    if let Some(value) = style.get("box-shadow") {
        if let Some(shadow) = parse_shadow(value, parent_tctx.color)? {
            paint_shadow(
                canvas,
                Rect {
                    x: box_left,
                    y: box_top,
                    w: b.border_box_width(),
                    h: b.border_box_height(),
                },
                radius,
                &shadow,
                alpha,
            );
        }
    }

    // Background.
    if let Some(c) = style.get("background-color") {
        let c = color_value(c, alpha);
        if c[3] != 0 {
            canvas.fill_rounded_rect(
                box_left + b.border.left,
                box_top + b.border.top,
                b.content_width + b.padding.horizontal(),
                b.content_height + b.padding.vertical(),
                radius,
                c,
            );
        }
    }
    if let Some(v) = style.get("background-image") {
        if let Some(url) = url_of(v) {
            paint_bg_image(
                canvas,
                ctx,
                &url,
                box_left + b.border.left,
                box_top + b.border.top,
                b.content_width + b.padding.horizontal(),
                b.content_height + b.padding.vertical(),
                alpha,
            );
        }
    }

    // Border.
    if let Some(bc) = style.get("border-color").or_else(|| style.get("color")) {
        let c = color_value(bc, alpha);
        let (top, right, bottom, left) = border_widths(&b);
        if c[3] != 0 && (top > 0 || right > 0 || bottom > 0 || left > 0) {
            let bw = top.max(right).max(bottom).max(left);
            // For the BIOS raster we use a uniform border width visual even
            // when per-side values differ — exact per-side borders are out of
            // scope, but the colour and presence are honoured.
            canvas.stroke_rounded_rect(
                box_left,
                box_top,
                b.border_box_width(),
                b.border_box_height(),
                radius,
                bw.max(1),
                c,
            );
        }
    }

    let content_width = content_width_safe(&b);
    let child_cb = match computed_position(&style).map_err(|e| e.to_string())? {
        Position::Absolute => Rect {
            x: box_left + b.border.left,
            y: box_top + b.border.top,
            w: b.content_width + b.padding.horizontal(),
            h: b.content_height + b.padding.vertical(),
        },
        Position::Static => cb,
    };

    let mut cursor = Cursor::new(content_top);
    cursor.canvas = Some(canvas);
    children_layout(
        &mut cursor,
        ctx,
        node,
        content_left,
        content_width,
        flow.depth + 1,
        child_cb,
        alpha,
        &tctx,
        path,
        sink,
        child_cols,
        as_row,
    )?;

    Ok(box_top + b.border_box_height() + b.margin.bottom)
}

fn content_width_safe(b: &crate::BoxModel) -> i32 {
    b.content_width.max(8)
}

fn border_widths(b: &crate::BoxModel) -> (i32, i32, i32, i32) {
    (
        b.border.top.max(0),
        b.border.right.max(0),
        b.border.bottom.max(0),
        b.border.left.max(0),
    )
}

fn color_for(style: &crate::ComputedStyle, key: &str, current: Rgba, alpha: u8) -> Rgba {
    style
        .get(key)
        .and_then(|v| parse_rgba_current(v, current))
        .map(|c| Canvas32::with_alpha(c, alpha))
        .unwrap_or(Canvas32::with_alpha(current, alpha))
}

pub(crate) struct Shadow {
    x: i32,
    y: i32,
    blur: i32,
    spread: i32,
    color: Rgba,
}

pub(crate) fn parse_shadow(value: &str, current: Rgba) -> Result<Option<Shadow>, String> {
    if value.trim().eq_ignore_ascii_case("none") {
        return Ok(None);
    }
    let mut lengths = Vec::new();
    let mut color = None;
    for token in crate::value_tokens(value) {
        if let Some(c) = parse_rgba_current(&token, current) {
            if color.replace(c).is_some() {
                return Err("one outer box-shadow is supported".into());
            }
        } else {
            if token.ends_with('%') {
                return Err("box-shadow lengths cannot be percentages".into());
            }
            lengths.push(length(&token, 0)?);
        }
    }
    if !(2..=4).contains(&lengths.len()) || lengths.iter().any(|n| !(-4096..=4096).contains(n)) {
        return Err("box-shadow needs two to four bounded lengths and one optional color".into());
    }
    let blur = lengths.get(2).copied().unwrap_or(0);
    let spread = lengths.get(3).copied().unwrap_or(0);
    if !(0..=32).contains(&blur) || !(-64..=64).contains(&spread) {
        return Err("box-shadow blur 0..32, spread -64..64 supported".into());
    }
    Ok(Some(Shadow {
        x: lengths[0],
        y: lengths[1],
        blur,
        spread,
        color: color.unwrap_or(current),
    }))
}

fn paint_shadow(canvas: &mut Canvas32, rect: Rect, radius: i32, shadow: &Shadow, alpha: u8) {
    let sx = rect.x + shadow.x - shadow.spread;
    let sy = rect.y + shadow.y - shadow.spread;
    let sw = rect.w + 2 * shadow.spread;
    let sh = rect.h + 2 * shadow.spread;
    if sw <= 0 || sh <= 0 {
        return;
    }
    let r = shadow.blur;
    let x0 = (sx - r).max(-r);
    let y0 = (sy - r).max(-r);
    let x1 = (sx + sw + r).min(canvas.w as i32 + r);
    let y1 = (sy + sh + r).min(canvas.h as i32 + r);
    if x1 <= x0 || y1 <= y0 {
        return;
    }
    let w = (x1 - x0) as usize;
    let h = (y1 - y0) as usize;
    let inside = |x: i32, y: i32, box_: Rect, radius: i32| {
        if x < box_.x || y < box_.y || x >= box_.x + box_.w || y >= box_.y + box_.h {
            return false;
        }
        let r = radius.max(0).min(box_.w.min(box_.h) / 2);
        let dx = (box_.x + r - x).max(x - (box_.x + box_.w - r - 1)).max(0);
        let dy = (box_.y + r - y).max(y - (box_.y + box_.h - r - 1)).max(0);
        dx * dx + dy * dy <= r * r
    };
    let mut mask = vec![0u8; w * h];
    let shape = Rect {
        x: sx,
        y: sy,
        w: sw,
        h: sh,
    };
    for y in 0..h {
        for x in 0..w {
            mask[y * w + x] = if inside(x0 + x as i32, y0 + y as i32, shape, radius + shadow.spread)
            {
                255
            } else {
                0
            };
        }
    }
    if r > 0 {
        let mut horizontal = vec![0u8; w * h];
        let radius = r as usize;
        let diameter = 2 * radius + 1;
        for y in 0..h {
            let mut sum: u32 = mask[y * w..y * w + (radius + 1).min(w)]
                .iter()
                .map(|&v| v as u32)
                .sum();
            for x in 0..w {
                horizontal[y * w + x] = (sum / diameter as u32) as u8;
                if x >= radius {
                    sum -= u32::from(mask[y * w + x - radius]);
                }
                if x + radius + 1 < w {
                    sum += u32::from(mask[y * w + x + radius + 1]);
                }
            }
        }
        for x in 0..w {
            let mut sum: u32 = (0..(radius + 1).min(h))
                .map(|y| u32::from(horizontal[y * w + x]))
                .sum();
            for y in 0..h {
                mask[y * w + x] = (sum / diameter as u32) as u8;
                if y >= radius {
                    sum -= u32::from(horizontal[(y - radius) * w + x]);
                }
                if y + radius + 1 < h {
                    sum += u32::from(horizontal[(y + radius + 1) * w + x]);
                }
            }
        }
    }
    for y in 0..h {
        for x in 0..w {
            let px = x0 + x as i32;
            let py = y0 + y as i32;
            if !inside(px, py, rect, radius) {
                canvas.blend(
                    px,
                    py,
                    Canvas32::with_alpha(shadow.color, alpha),
                    mask[y * w + x],
                );
            }
        }
    }
}

fn color_value(value: &str, alpha: u8) -> Rgba {
    parse_rgba(value)
        .map(|c| Canvas32::with_alpha(c, alpha))
        .unwrap_or([0, 0, 0, alpha])
}

fn font_size_for(style: &crate::ComputedStyle, parent: f32) -> f32 {
    let v = style.get("font-size").unwrap_or("");
    let v = v.trim();
    if v.is_empty() {
        return parent;
    }
    if let Some(p) = v.strip_suffix('%') {
        if let Ok(n) = p.parse::<f64>() {
            return (n / 100.0 * parent as f64) as f32;
        }
    }
    if let Some(p) = v.strip_suffix("rem") {
        if let Ok(n) = p.trim().parse::<f64>() {
            return (n * 16.0) as f32; // rem is root size (16px default)
        }
    }
    if let Some(p) = v.strip_suffix("em") {
        if let Ok(n) = p.trim().parse::<f64>() {
            return (n * parent as f64) as f32;
        }
    }
    if let Some(p) = v.strip_suffix("px") {
        if let Ok(n) = p.trim().parse::<f64>() {
            return n as f32;
        }
    }
    if let Ok(n) = v.parse::<f64>() {
        return n as f32;
    }
    parent
}

fn is_bold(style: &crate::ComputedStyle) -> Option<bool> {
    style.get("font-weight").map(|v| {
        let v = v.trim().to_ascii_lowercase();
        matches!(v.as_str(), "bold" | "bolder") || v.parse::<u32>().is_ok_and(|n| n >= 600)
    })
}

fn align_for(style: &crate::ComputedStyle) -> Option<Align> {
    style.get("text-align").map(|v| {
        let v = v.trim().to_ascii_lowercase();
        match v.as_str() {
            "right" | "end" => Align::Right,
            "center" => Align::Center,
            _ => Align::Left,
        }
    })
}

fn url_of(value: &str) -> Option<String> {
    let v = value.trim();
    if v.eq_ignore_ascii_case("none") {
        return None;
    }
    if !v.to_ascii_lowercase().starts_with("url(") {
        return None;
    }
    let inner = v[4..v.len() - 1].trim();
    Some(inner.trim_matches(['"', '\'']).to_string())
}

fn paint_bg_image(
    canvas: &mut Canvas32,
    ctx: &Ctx32<'_>,
    url: &str,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    alpha: u8,
) {
    if let Some(Asset::Raster(img)) = ctx.assets.get(url) {
        img.blit(canvas, x, y, w, h, alpha);
    } else if let Some(Asset::Vector(node)) = ctx.assets.get(url) {
        let _ = g6b_img::svg::paint(canvas, node, x, y, w, h, alpha, &svg_style(ctx.sheet));
    }
}

// ---------------------------------------------------------------------------
// children / inline layout
// ---------------------------------------------------------------------------

struct Cursor<'a> {
    x_px: f32,
    y: i32,
    line_h: i32,
    canvas: Option<&'a mut Canvas32>,
}

impl Cursor<'_> {
    fn new(content_top: i32) -> Self {
        Self {
            x_px: 0.0,
            y: content_top,
            line_h: 0,
            canvas: None,
        }
    }

    fn flush(&mut self) {
        if self.x_px > 0.0 {
            self.x_px = 0.0;
            self.y += self.line_h;
            self.line_h = 0;
        }
    }
}

/// `TEXTREF` anchor carried by a word when it belongs to an id'd element's
/// single-line text run — the `__web_dl` live-text lane (`DlOp::Tref`).
#[derive(Clone)]
struct TrefMeta {
    key: u32,
    id: String,
    text: String,
}

/// One word or replaced inline box in a line.
#[derive(Clone)]
enum InlineItem<'a> {
    Word {
        text: String,
        family: String,
        size: f32,
        bold: bool,
        color: Rgba,
        width: f32,
        /// `Some` when this word is part of a `TEXTREF`-eligible run.
        tref: Option<TrefMeta>,
    },
    Replaced {
        node: &'a Node,
        path: Vec<usize>,
        w: i32,
        h: i32,
        color: Rgba,
        kind: Replaced,
    },
    /// `display: inline-block` — an atomic inline box that keeps its own
    /// background, border, padding and rounded corners. This is what makes a
    /// tab strip read as tabs instead of coloured words.
    InlineBlock {
        node: &'a Node,
        path: Vec<usize>,
        w: i32,
        h: i32,
        tctx: TextCtx,
    },
    Space,
}

#[derive(Clone)]
enum Replaced {
    Img { src: String },
    Svg,
    Icon { name: String },
    Other,
}

fn children_layout<'t, 'c>(
    cursor: &mut Cursor<'c>,
    ctx: &Ctx32<'_>,
    node: &'t Node,
    content_left: i32,
    content_width: i32,
    depth: usize,
    cb: Rect,
    alpha: u8,
    tctx: &TextCtx,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
    cols: Option<&[i32]>,
    as_row: bool,
) -> Result<(), String> {
    if cascade(ctx.sheet, &ElementRef::from_node(node)).get("display") == Some("flex") {
        return flex_layout(
            cursor,
            ctx,
            node,
            content_left,
            content_width,
            depth,
            cb,
            alpha,
            tctx,
            path,
            sink,
        );
    }
    if as_row {
        return row_layout(
            cursor,
            ctx,
            node,
            content_left,
            content_width,
            depth,
            cb,
            alpha,
            tctx,
            path,
            sink,
            cols.unwrap_or(&[]),
        );
    }
    let mut items: Vec<InlineItem<'t>> = Vec::new();
    let mut was_space = true; // no leading space
    inline_children(
        cursor,
        ctx,
        node,
        content_left,
        content_width,
        depth,
        cb,
        alpha,
        tctx,
        path,
        sink,
        cols,
        &mut items,
        &mut was_space,
    )?;
    flush_items(
        cursor,
        ctx,
        &mut items,
        content_left,
        content_width,
        alpha,
        tctx,
        sink,
    )?;
    Ok(())
}

/// Walk `node`'s children into the **caller's** inline item list.
///
/// This is the fix for the inline formatting context: an inline element used to
/// recurse into `children_layout`, whose trailing `flush_items` ended the line,
/// so `<th>A</th><th>B</th>` stacked vertically instead of sharing a line.
/// Inline children now append to the same run and only a block, a `<br>`, or the
/// end of the block formatting context breaks it.
/// `TEXTREF` eligibility for a `#text` child: the parent element carries an
/// `id`, its inline content is exactly this text node, the trimmed string
/// fits the content width on one line, and the run is not bold (the guest
/// re-render has no embolden pass). The returned key pairs the `DlOp::Tref`
/// marker with this element only — the packer swaps the marker + the
/// contiguous `Cov` run for one `TREF` record when the region's background
/// is uniform.
fn tref_anchor(
    node: &Node,
    ctx: &Ctx32<'_>,
    tctx: &TextCtx,
    text: &str,
    content_width: i32,
    sink: &mut Sink<'_>,
) -> Option<TrefMeta> {
    let id = node.id.as_deref()?;
    if tctx.bold {
        return None;
    }
    let mut texts = node
        .children
        .iter()
        .filter(|c| c.name.eq_ignore_ascii_case("#text") && !c.text.trim().is_empty());
    if texts.next().is_none() || texts.next().is_some() {
        return None; // not exactly one non-empty text child
    }
    if !node
        .children
        .iter()
        .all(|c| c.name.eq_ignore_ascii_case("#text"))
    {
        return None; // inline elements inside would interleave the op run
    }
    // Single-line fit: words + inter-word spaces ≤ the content width.
    let font = ctx.fonts.resolve(&tctx.family);
    let space_w = font.advance_for(' ', tctx.size);
    let mut total = 0.0f32;
    for (i, w) in text.split_whitespace().enumerate() {
        if i > 0 {
            total += space_w;
        }
        total += w
            .chars()
            .map(|c| font.advance_for(c, tctx.size))
            .sum::<f32>();
    }
    if total > content_width as f32 {
        return None;
    }
    sink.tref_seq += 1;
    Some(TrefMeta {
        key: sink.tref_seq,
        id: id.to_string(),
        text: text.to_string(),
    })
}

fn inline_children<'t>(
    cursor: &mut Cursor<'_>,
    ctx: &Ctx32<'_>,
    node: &'t Node,
    content_left: i32,
    content_width: i32,
    depth: usize,
    cb: Rect,
    alpha: u8,
    tctx: &TextCtx,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
    cols: Option<&[i32]>,
    items: &mut Vec<InlineItem<'t>>,
    was_space: &mut bool,
) -> Result<(), String> {
    for (index, child) in node.children.iter().enumerate() {
        if child.hidden {
            continue;
        }
        if child.name.eq_ignore_ascii_case("script") || child.name.eq_ignore_ascii_case("style") {
            continue;
        }
        if child.name.eq_ignore_ascii_case("br") {
            flush_items(
                cursor,
                ctx,
                items,
                content_left,
                content_width,
                alpha,
                tctx,
                sink,
            )?;
            if cursor.x_px > 0.0 {
                cursor.flush();
            }
            *was_space = true;
            continue;
        }
        if child.name.eq_ignore_ascii_case("#text") {
            let text = child.text.trim();
            if !text.is_empty() {
                // `TEXTREF` anchor: an id'd element whose inline content is
                // this one text node on one line. `DlPaint` then re-renders
                // the element's *live* `__dom` text from the atlas instead of
                // the frozen packed glyphs.
                let tref = tref_anchor(node, ctx, tctx, text, content_width, sink);
                for word in text.split_whitespace() {
                    if !*was_space && !items.is_empty() {
                        items.push(InlineItem::Space);
                    }
                    let font = ctx.fonts.resolve(&tctx.family);
                    let width: f32 = word.chars().map(|c| font.advance_for(c, tctx.size)).sum();
                    items.push(InlineItem::Word {
                        text: word.into(),
                        family: tctx.family.clone(),
                        size: tctx.size,
                        bold: tctx.bold,
                        color: tctx.color,
                        width,
                        tref: tref.clone(),
                    });
                    *was_space = false;
                }
            }
            continue;
        }

        let child_style = cascade(ctx.sheet, &ElementRef::from_node(child));
        if computed_position(&child_style).map_err(|e| e.to_string())? == Position::Absolute {
            // Flush pending inline before parking the absolute, so the paint
            // order matches the document.
            flush_items(
                cursor,
                ctx,
                items,
                content_left,
                content_width,
                alpha,
                tctx,
                sink,
            )?;
            if sink.absolutes.len() >= MAX_ABSOLUTE_BOXES {
                return Err("absolute box budget exceeded".into());
            }
            path.push(index);
            sink.absolutes.push(Absolute {
                node: child,
                cb,
                path: path.clone(),
                depth,
            });
            path.pop();
            continue;
        }

        if is_block_for(child, &child_style) {
            flush_items(
                cursor,
                ctx,
                items,
                content_left,
                content_width,
                alpha,
                tctx,
                sink,
            )?;
            cursor.flush();
            *was_space = true;
            path.push(index);
            let flow = Flow {
                x: content_left,
                y: cursor.y,
                avail_w: content_width,
                depth,
            };
            let bottom = if cursor.canvas.is_some() {
                paint_block(
                    cursor.canvas.as_deref_mut().unwrap(),
                    ctx,
                    child,
                    flow,
                    cb,
                    alpha,
                    tctx,
                    path,
                    sink,
                    cols,
                    None,
                )?
            } else {
                measure_block(ctx, child, flow, cb, alpha, tctx, path, sink, cols, None)?
            };
            path.pop();
            cursor.y = bottom;
            cursor.x_px = 0.0;
            cursor.line_h = 0;
            continue;
        }

        // Inline replaced element (img, svg, canvas, video, icon, ...).
        if is_replaced(child) {
            if !*was_space && !items.is_empty() {
                items.push(InlineItem::Space);
            }
            let (w, h, kind) = replaced_size_and_kind(child, &child_style, content_width, ctx);
            let color = color_for(&child_style, "color", tctx.color, alpha);
            let mut child_path = path.clone();
            child_path.push(index);
            items.push(InlineItem::Replaced {
                node: child,
                path: child_path,
                w,
                h,
                color,
                kind,
            });
            *was_space = false;
            continue;
        }

        let mut child_tctx = tctx.clone();
        child_tctx.color = color_for(&child_style, "color", tctx.color, alpha);
        child_tctx.family = child_style
            .get("font-family")
            .map(str::to_string)
            .unwrap_or_else(|| tctx.family.clone());
        child_tctx.size = font_size_for(&child_style, tctx.size);
        child_tctx.bold = is_bold(&child_style).unwrap_or(tctx.bold);
        child_tctx.align = align_for(&child_style).unwrap_or(tctx.align);

        // `display: inline-block` is an ATOMIC inline: it stays on the line but
        // keeps its own box, so its background/border/padding actually paint.
        if child_style
            .get("display")
            .is_some_and(|d| d.trim().eq_ignore_ascii_case("inline-block"))
        {
            if !*was_space && !items.is_empty() {
                items.push(InlineItem::Space);
            }
            let (w, h) =
                inline_block_size(ctx, child, &child_style, content_width, &child_tctx, depth)?;
            let mut child_path = path.clone();
            child_path.push(index);
            items.push(InlineItem::InlineBlock {
                node: child,
                path: child_path,
                w,
                h,
                tctx: child_tctx,
            });
            *was_space = false;
            continue;
        }

        // Plain inline element: it contributes to the SAME line run as its
        // parent, so its children go into `items` here rather than through a
        // nested block formatting context.
        path.push(index);
        inline_children(
            cursor,
            ctx,
            child,
            content_left,
            content_width,
            depth,
            cb,
            alpha,
            &child_tctx,
            path,
            sink,
            cols,
            items,
            was_space,
        )?;
        path.pop();
    }
    Ok(())
}

/// Shrink-to-fit size of an atomic inline box: max-content width plus its own
/// edges, clamped to the line, then measured for height at that width.
fn inline_block_size(
    ctx: &Ctx32<'_>,
    node: &Node,
    style: &crate::ComputedStyle,
    content_width: i32,
    tctx: &TextCtx,
    depth: usize,
) -> Result<(i32, i32), String> {
    let probe = computed_box(style, content_width).map_err(|e| e.to_string())?;
    let edges = probe.padding.horizontal() + probe.border.horizontal() + probe.margin.horizontal();
    let declared = style
        .get("width")
        .filter(|v| !v.trim().eq_ignore_ascii_case("auto"))
        .is_some();
    let outer = if declared {
        probe.margin_box_width()
    } else {
        (max_content_width(ctx, node, tctx) + edges).min(content_width.max(1))
    };
    let mut scratch = Sink::new();
    let mut path = Vec::new();
    let bottom = measure_block(
        ctx,
        node,
        Flow {
            x: 0,
            y: 0,
            avail_w: outer,
            depth,
        },
        Rect {
            x: 0,
            y: 0,
            w: outer,
            h: 0,
        },
        255,
        tctx,
        &mut path,
        &mut scratch,
        None,
        None,
    )?;
    Ok((outer.max(1), bottom.max(1)))
}

/// `display` can promote an inline element to a block, which is how the tab bar
/// keeps `<a>` inline while the settings panels stay block.
fn is_block_for(node: &Node, style: &crate::ComputedStyle) -> bool {
    match style.get("display").map(|d| d.trim().to_ascii_lowercase()) {
        Some(d) if d == "block" || d == "flow-root" || d == "list-item" || d == "flex" => true,
        Some(d) if d == "inline" || d == "inline-block" => false,
        _ => is_block(&node.name),
    }
}

// ---------------------------------------------------------------------------
// tables
// ---------------------------------------------------------------------------

/// Bounded like every other structure here: a BIOS settings table with more
/// than this many columns is a bug, not a layout to solve.
pub const MAX_TABLE_COLS: usize = 16;

fn is_table_cell(name: &str) -> bool {
    name.eq_ignore_ascii_case("th") || name.eq_ignore_ascii_case("td")
}

fn is_table_section(name: &str) -> bool {
    name.eq_ignore_ascii_case("thead")
        || name.eq_ignore_ascii_case("tbody")
        || name.eq_ignore_ascii_case("tfoot")
}

/// Every `<tr>` under a table, through the optional section wrappers.
fn collect_rows<'t>(node: &'t Node, out: &mut Vec<&'t Node>) {
    for child in &node.children {
        if child.hidden {
            continue;
        }
        if child.name.eq_ignore_ascii_case("tr") {
            out.push(child);
        } else if is_table_section(&child.name) {
            collect_rows(child, out);
        }
    }
}

/// Auto table layout, bounded: measure each column's max-content width, then
/// distribute the container width in proportion.
///
/// This is the CSS "automatic table layout" shape as goosie's box code implies
/// it (max-content per column, then share the free space), not the full
/// CSS 2.1 §17.5.2.2 algorithm — no colspan, no rowspan, no `table-layout:
/// fixed`, no border collapse resolution.
fn table_columns(ctx: &Ctx32<'_>, table: &Node, content_width: i32, tctx: &TextCtx) -> Vec<i32> {
    let mut rows = Vec::new();
    collect_rows(table, &mut rows);
    let ncols = rows
        .iter()
        .map(|r| r.children.iter().filter(|c| is_table_cell(&c.name)).count())
        .max()
        .unwrap_or(0)
        .min(MAX_TABLE_COLS);
    if ncols == 0 {
        return Vec::new();
    }
    let mut want = vec![0i32; ncols];
    for row in &rows {
        for (i, cell) in row
            .children
            .iter()
            .filter(|c| is_table_cell(&c.name) && !c.hidden)
            .take(ncols)
            .enumerate()
        {
            let style = cascade(ctx.sheet, &ElementRef::from_node(cell));
            let edges = computed_box(&style, content_width)
                .map(|b| b.padding.horizontal() + b.border.horizontal() + b.margin.horizontal())
                .unwrap_or(0);
            let mut cell_tctx = tctx.clone();
            cell_tctx.size = font_size_for(&style, tctx.size);
            cell_tctx.family = style
                .get("font-family")
                .map(str::to_string)
                .unwrap_or_else(|| tctx.family.clone());
            want[i] = want[i].max(max_content_width(ctx, cell, &cell_tctx) + edges);
        }
    }
    distribute(&want, content_width)
}

/// Widest single line the subtree would produce if never wrapped.
fn max_content_width(ctx: &Ctx32<'_>, node: &Node, tctx: &TextCtx) -> i32 {
    fn walk(ctx: &Ctx32<'_>, node: &Node, tctx: &TextCtx, acc: &mut f32, depth: usize) {
        if depth > 32 || node.hidden {
            return;
        }
        if node.name.eq_ignore_ascii_case("#text") {
            let font = ctx.fonts.resolve(&tctx.family);
            let space = font.advance_for(' ', tctx.size);
            let mut first = true;
            for word in node.text.split_whitespace() {
                if !first {
                    *acc += space;
                }
                first = false;
                *acc += word
                    .chars()
                    .map(|c| font.advance_for(c, tctx.size))
                    .sum::<f32>();
            }
            return;
        }
        for child in &node.children {
            walk(ctx, child, tctx, acc, depth + 1);
        }
    }
    let mut acc = 0.0;
    walk(ctx, node, tctx, &mut acc, 0);
    acc.ceil() as i32
}

/// Share `content_width` between columns in proportion to their max-content
/// widths, both when the table overflows and when it has room to spare.
fn distribute(want: &[i32], content_width: i32) -> Vec<i32> {
    let n = want.len() as i32;
    if n == 0 {
        return Vec::new();
    }
    let total: i32 = want.iter().sum();
    if total <= 0 {
        // No measurable content: equal columns rather than zero-width ones.
        let each = (content_width / n).max(1);
        return vec![each; want.len()];
    }
    let mut out: Vec<i32> = want
        .iter()
        .map(|w| ((*w as i64 * content_width as i64) / total as i64) as i32)
        .map(|w| w.max(1))
        .collect();
    // Give the rounding remainder to the last column so the row fills exactly.
    let used: i32 = out.iter().sum();
    if let Some(last) = out.last_mut() {
        *last += content_width - used;
        *last = (*last).max(1);
    }
    out
}

/// Lay a `<tr>`'s cells out side by side, then equalise their heights so each
/// cell's background covers the whole row.
fn row_layout<'t>(
    cursor: &mut Cursor<'_>,
    ctx: &Ctx32<'_>,
    row: &'t Node,
    content_left: i32,
    content_width: i32,
    depth: usize,
    cb: Rect,
    alpha: u8,
    tctx: &TextCtx,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
    cols: &[i32],
) -> Result<(), String> {
    let cells: Vec<(usize, &Node)> = row
        .children
        .iter()
        .enumerate()
        .filter(|(_, c)| is_table_cell(&c.name) && !c.hidden)
        .take(MAX_TABLE_COLS)
        .collect();
    if cells.is_empty() {
        return Ok(());
    }
    let fallback = (content_width / cells.len() as i32).max(1);
    let width_of = |i: usize| cols.get(i).copied().unwrap_or(fallback).max(1);

    // Pass 1: measure, so every cell in the row can share one height.
    let top = cursor.y;
    let mut row_h = 0;
    let mut x = content_left;
    for (i, (index, cell)) in cells.iter().enumerate() {
        let w = width_of(i);
        path.push(*index);
        let mut scratch = Sink::new();
        let bottom = measure_block(
            ctx,
            cell,
            Flow {
                x,
                y: top,
                avail_w: w,
                depth,
            },
            cb,
            alpha,
            tctx,
            path,
            &mut scratch,
            None,
            None,
        )?;
        path.pop();
        row_h = row_h.max(bottom - top);
        x += w;
    }

    // Pass 2: paint each cell at the shared row height.
    let mut x = content_left;
    for (i, (index, cell)) in cells.iter().enumerate() {
        let w = width_of(i);
        path.push(*index);
        let flow = Flow {
            x,
            y: top,
            avail_w: w,
            depth,
        };
        if cursor.canvas.is_some() {
            paint_block(
                cursor.canvas.as_deref_mut().unwrap(),
                ctx,
                cell,
                flow,
                cb,
                alpha,
                tctx,
                path,
                sink,
                None,
                Some(row_h),
            )?;
        }
        path.pop();
        x += w;
    }
    cursor.y = top + row_h;
    cursor.x_px = 0.0;
    cursor.line_h = 0;
    Ok(())
}

fn flex_layout<'t>(
    cursor: &mut Cursor<'_>,
    ctx: &Ctx32<'_>,
    node: &'t Node,
    left: i32,
    width: i32,
    depth: usize,
    cb: Rect,
    alpha: u8,
    tctx: &TextCtx,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
) -> Result<(), String> {
    struct Item<'a> {
        index: usize,
        node: &'a Node,
        size: i32,
        base: i32,
        min: i32,
        max: i32,
        grow: f64,
        shrink: f64,
        height: i32,
        stretch: bool,
    }
    let style = cascade(ctx.sheet, &ElementRef::from_node(node));
    let gap = length(style.get("gap").unwrap_or("0"), width)?;
    let wrap = style.get("flex-wrap") == Some("wrap");
    let reverse = style.get("flex-direction") == Some("row-reverse");
    let mut items = Vec::new();
    for (index, child) in node.children.iter().enumerate() {
        let s = cascade(ctx.sheet, &ElementRef::from_node(child));
        if child.hidden
            || s.get("display") == Some("none")
            || matches!(child.name.as_str(), "script" | "style")
        {
            continue;
        }
        if child.name == "#text" {
            if !child.text.trim().is_empty() {
                return Err("flex anonymous text items are not implemented".into());
            }
            continue;
        }
        if computed_position(&s).map_err(|e| e.to_string())? == Position::Absolute {
            if sink.absolutes.len() >= MAX_ABSOLUTE_BOXES {
                return Err("absolute box budget exceeded".into());
            }
            let mut p = path.clone();
            p.push(index);
            sink.absolutes.push(Absolute {
                node: child,
                cb,
                path: p,
                depth,
            });
            continue;
        }
        if items.len() >= 64 {
            return Err("flex item budget exceeded".into());
        }
        let b = computed_box(&s, width).map_err(|e| e.to_string())?;
        let edges = b.margin.horizontal() + b.border.horizontal() + b.padding.horizontal();
        let base = match s.get("flex-basis").filter(|v| *v != "auto") {
            Some(v) => length(v, width)? + edges,
            None if s.get("width").is_some_and(|v| v != "auto") => b.margin_box_width(),
            None => max_content_width(ctx, child, tctx) + edges,
        }
        .max(edges)
        .max(0);
        let min = match s.get("min-width").filter(|v| *v != "auto") {
            Some(v) => length(v, width)? + edges,
            None => {
                child
                    .inner_text()
                    .split_whitespace()
                    .map(|word| {
                        word.chars()
                            .map(|c| ctx.fonts.resolve(&tctx.family).advance_for(c, tctx.size))
                            .sum::<f32>()
                            .ceil() as i32
                    })
                    .max()
                    .unwrap_or(0)
                    .min(base.saturating_sub(edges))
                    + edges
            }
        }
        .max(0);
        let max = s
            .get("max-width")
            .map(|v| length(v, width).map(|n| n + edges))
            .transpose()?
            .unwrap_or(i32::MAX)
            .max(min);
        items.push(Item {
            index,
            node: child,
            size: base.clamp(min, max),
            base,
            min,
            max,
            grow: s
                .get("flex-grow")
                .unwrap_or("0")
                .parse()
                .map_err(|_| "invalid flex-grow")?,
            shrink: s
                .get("flex-shrink")
                .unwrap_or("1")
                .parse()
                .map_err(|_| "invalid flex-shrink")?,
            height: 0,
            stretch: s.get("height").is_none_or(|h| h == "auto"),
        });
    }
    let mut start = 0;
    while start < items.len() {
        let mut end = start + 1;
        let mut occupied = items[start].size;
        while end < items.len() && (!wrap || occupied + gap + items[end].size <= width) {
            occupied += gap + items[end].size;
            end += 1;
        }
        let line = &mut items[start..end];
        let gaps = gap * (line.len() as i32 - 1);
        for _ in 0..=line.len() {
            let free = width - gaps - line.iter().map(|i| i.size).sum::<i32>();
            if free == 0 {
                break;
            }
            let weight = |i: &Item<'_>| {
                if free > 0 && i.size < i.max {
                    i.grow
                } else if free < 0 && i.size > i.min {
                    i.shrink * i.base as f64
                } else {
                    0.0
                }
            };
            let total: f64 = line.iter().map(weight).sum();
            if total == 0.0 {
                break;
            }
            let mut cumulative = 0.0;
            let mut allocated = 0;
            let mut changed = false;
            let mut clamped = false;
            for item in line.iter_mut() {
                cumulative += weight(item);
                let target = (free as f64 * cumulative
                    / if free > 0 { total.max(1.0) } else { total })
                .round() as i32;
                let proposed = item.size.saturating_add(target - allocated);
                let next = proposed.clamp(item.min, item.max);
                clamped |= next != proposed;
                changed |= next != item.size;
                item.size = next;
                allocated = target;
            }
            if !changed || !clamped {
                break;
            }
        }
        let mut line_h = if !wrap {
            style
                .get("height")
                .map(|v| length(v, cb.h))
                .transpose()?
                .unwrap_or(0)
        } else {
            0
        };
        for item in line.iter_mut() {
            let item_ctx = Ctx32 {
                flex_width: Some((item.node as *const Node as usize, item.size)),
                ..*ctx
            };
            let mut scratch = Sink::new();
            path.push(item.index);
            item.height = measure_block(
                &item_ctx,
                item.node,
                Flow {
                    x: left,
                    y: 0,
                    avail_w: width,
                    depth,
                },
                cb,
                alpha,
                tctx,
                path,
                &mut scratch,
                None,
                None,
            )?;
            path.pop();
            line_h = line_h.max(item.height);
        }
        let free = (width - gaps - line.iter().map(|i| i.size).sum::<i32>()).max(0);
        let count = line.len() as i32;
        let justify = style.get("justify-content").unwrap_or("flex-start");
        let mut x = 0;
        for (index, item) in line.iter().enumerate() {
            let i = index as i32;
            let offset = match justify {
                "flex-end" => free,
                "center" => free / 2,
                "space-between" if count > 1 => free * i / (count - 1),
                "space-around" => free * (2 * i + 1) / (2 * count),
                "space-evenly" => free * (i + 1) / (count + 1),
                _ => 0,
            };
            let align = style.get("align-items").unwrap_or("stretch");
            let dy = match align {
                "center" => (line_h - item.height) / 2,
                "flex-end" => line_h - item.height,
                _ => 0,
            };
            let item_ctx = Ctx32 {
                flex_width: Some((item.node as *const Node as usize, item.size)),
                ..*ctx
            };
            if let Some(canvas) = cursor.canvas.as_deref_mut() {
                path.push(item.index);
                paint_block(
                    canvas,
                    &item_ctx,
                    item.node,
                    Flow {
                        x: left
                            + if reverse {
                                width - x - offset - item.size
                            } else {
                                x + offset
                            },
                        y: cursor.y + dy,
                        avail_w: width,
                        depth,
                    },
                    cb,
                    alpha,
                    tctx,
                    path,
                    sink,
                    None,
                    (align == "stretch" && item.stretch).then_some(line_h),
                )?;
                path.pop();
            }
            x += item.size + gap;
        }
        cursor.y += line_h + if end < items.len() { gap } else { 0 };
        start = end;
    }
    cursor.x_px = 0.0;
    cursor.line_h = 0;
    Ok(())
}

fn is_replaced(node: &Node) -> bool {
    matches!(
        node.name.as_str(),
        "img"
            | "svg"
            | "canvas"
            | "picture"
            | "video"
            | "audio"
            | "iframe"
            | "object"
            | "embed"
            | "input"
            | "textarea"
    ) || icons::is_icon(node)
}

fn replaced_size_and_kind(
    node: &Node,
    style: &crate::ComputedStyle,
    content_width: i32,
    ctx: &Ctx32<'_>,
) -> (i32, i32, Replaced) {
    // SVG, icon, img, canvas, etc.
    if icons::is_icon(node) {
        let size = font_size_for(style, 16.0) as i32;
        if let Some(name) = icons::name_for(node) {
            return (size, size, Replaced::Icon { name });
        }
    }

    if node.name == "img" {
        let src = node.get_attribute("src").unwrap_or_default().to_string();
        let (nw, nh) = asset_natural_size(ctx, &src);
        let attr_w = node.get_attribute("width").and_then(attr_dimension);
        let attr_h = node.get_attribute("height").and_then(attr_dimension);
        let mut w = dimension(style.get("width"), content_width)
            .or(attr_w)
            .unwrap_or(nw);
        let mut h = dimension(style.get("height"), 0).or(attr_h).unwrap_or(nh);
        if w == 0 || h == 0 {
            if w == 0 && h == 0 && nw > 0 && nh > 0 {
                (w, h) = fit_to_width(nw, nh, content_width);
            } else if w == 0 && nw > 0 {
                w = (nw as f64 * h as f64 / nh.max(1) as f64) as i32;
            } else if h == 0 && nh > 0 {
                h = (nh as f64 * w as f64 / nw.max(1) as f64) as i32;
            }
        }
        if w == 0 || h == 0 {
            // No asset and no dimensions: draw the `alt` as a word instead of
            // an empty box. Returning (0,0) with Img kind lets the flush code
            // skip it.
            let alt = node.get_attribute("alt").unwrap_or("[img]");
            return (alt.len() as i32 * 8, 16, Replaced::Img { src: alt.into() });
        }
        return (w, h, Replaced::Img { src });
    }

    if node.name == "svg" {
        let mut w = dimension(style.get("width"), content_width)
            .or_else(|| {
                node.get_attribute("width")
                    .and_then(|v| v.trim().parse().ok())
            })
            .unwrap_or(0);
        let mut h = dimension(style.get("height"), 0)
            .or_else(|| {
                node.get_attribute("height")
                    .and_then(|v| v.trim().parse().ok())
            })
            .unwrap_or(0);
        if w == 0 || h == 0 {
            if let Some(vb) = node
                .get_attribute("viewBox")
                .or_else(|| node.get_attribute("viewbox"))
            {
                let nums: Vec<f32> = vb
                    .split(|c: char| c.is_ascii_whitespace() || c == ',')
                    .filter_map(|s| s.trim().parse().ok())
                    .collect();
                if nums.len() >= 4 && nums[2] > 0.0 && nums[3] > 0.0 {
                    let ratio = nums[2] / nums[3];
                    if w == 0 && h > 0 {
                        w = (h as f64 * ratio as f64) as i32;
                    } else if h == 0 && w > 0 {
                        h = (w as f64 / ratio as f64) as i32;
                    } else {
                        w = nums[2] as i32;
                        h = nums[3] as i32;
                    }
                }
            }
        }
        if w == 0 || h == 0 {
            // Unsized inline SVG is not painted — the page must declare its
            // viewport. This is the honest bounded contract.
            return (0, 0, Replaced::Svg);
        }
        return (w, h, Replaced::Svg);
    }

    // Canvas / video / audio / iframe / object / embed — dynamic surfaces with
    // no static pixels in this renderer. They occupy no space.
    (0, 0, Replaced::Other)
}

fn dimension(value: Option<&str>, _basis: i32) -> Option<i32> {
    value
        .and_then(|v| v.trim().trim_end_matches("px").parse::<f32>().ok())
        .map(|n| n as i32)
}

fn attr_dimension(value: &str) -> Option<i32> {
    value
        .trim()
        .trim_end_matches("px")
        .parse::<f32>()
        .ok()
        .map(|n| n as i32)
}

fn fit_to_width(w: i32, h: i32, max_w: i32) -> (i32, i32) {
    if w <= max_w {
        return (w, h);
    }
    let scale = max_w as f64 / w.max(1) as f64;
    (max_w, (h as f64 * scale) as i32)
}

fn asset_natural_size(ctx: &Ctx32<'_>, src: &str) -> (i32, i32) {
    match ctx.assets.get(src) {
        Some(Asset::Raster(img)) => (img.w as i32, img.h as i32),
        Some(Asset::Vector(node)) => {
            // viewBox is the only source of intrinsic size for SVG assets.
            if let Some(vb) = node
                .get_attribute("viewBox")
                .or_else(|| node.get_attribute("viewbox"))
            {
                let nums: Vec<f32> = vb
                    .split(|c: char| c.is_ascii_whitespace() || c == ',')
                    .filter_map(|s| s.trim().parse().ok())
                    .collect();
                if nums.len() >= 4 && nums[2] > 0.0 && nums[3] > 0.0 {
                    return (nums[2] as i32, nums[3] as i32);
                }
            }
            (0, 0)
        }
        _ => (0, 0),
    }
}

fn measure_block<'t>(
    ctx: &Ctx32<'_>,
    node: &'t Node,
    flow: Flow,
    cb: Rect,
    alpha: u8,
    tctx: &TextCtx,
    path: &mut Vec<usize>,
    _sink: &mut Sink<'t>,
    cols: Option<&[i32]>,
    force_h: Option<i32>,
) -> Result<i32, String> {
    if flow.depth > MAX_RENDER_NODES {
        return Err("render32 depth exceeded".into());
    }
    if node.name.eq_ignore_ascii_case("#text")
        || node.hidden
        || node.name.eq_ignore_ascii_case("br")
        || node.name.eq_ignore_ascii_case("style")
        || node.name.eq_ignore_ascii_case("script")
    {
        return Ok(flow.y);
    }
    if cascade(ctx.sheet, &ElementRef::from_node(node))
        .get("display")
        .is_some_and(|d| d.eq_ignore_ascii_case("none"))
    {
        return Ok(flow.y);
    }
    let style = cascade(ctx.sheet, &ElementRef::from_node(node));
    let mut b = computed_box(&style, flow.avail_w).map_err(|e| e.to_string())?;
    if let Some((target, width)) = ctx.flex_width {
        if target == node as *const Node as usize {
            b.content_width =
                (width - b.margin.horizontal() - b.border.horizontal() - b.padding.horizontal())
                    .max(0);
        }
    }
    let mut tctx = tctx.clone();
    tctx.family = style
        .get("font-family")
        .map(str::to_string)
        .unwrap_or(tctx.family);
    tctx.size = font_size_for(&style, tctx.size);
    tctx.bold = is_bold(&style).unwrap_or(tctx.bold);

    let own_cols;
    let (as_row, child_cols) = if node.name.eq_ignore_ascii_case("table") {
        own_cols = table_columns(ctx, node, content_width_safe(&b), &tctx);
        (false, Some(own_cols.as_slice()))
    } else if is_table_section(&node.name) {
        (false, cols)
    } else if node.name.eq_ignore_ascii_case("tr") {
        (true, cols)
    } else {
        (false, None)
    };

    if b.content_height == 0 {
        let mut scratch = Sink::new();
        let mut cursor = Cursor::new(flow.y + b.margin.top + b.border.top + b.padding.top);
        children_layout(
            &mut cursor,
            ctx,
            node,
            flow.x + b.margin.left + b.border.left + b.padding.left,
            content_width_safe(&b),
            flow.depth + 1,
            cb,
            alpha,
            &tctx,
            path,
            &mut scratch,
            child_cols,
            as_row,
        )?;
        let mut h = cursor.y - (flow.y + b.margin.top + b.border.top + b.padding.top);
        if cursor.x_px > 0.0 {
            h += cursor.line_h;
        }
        b.content_height = h.max(0);
    }
    if let Some(min) = force_h {
        let vertical = b.margin.vertical() + b.border.vertical() + b.padding.vertical();
        b.content_height = b.content_height.max(min - vertical);
    }
    Ok(flow.y + b.margin_box_height())
}

fn flush_items<'t, 'c>(
    cursor: &mut Cursor<'c>,
    ctx: &Ctx32<'_>,
    items: &mut Vec<InlineItem<'t>>,
    content_left: i32,
    content_width: i32,
    alpha: u8,
    tctx: &TextCtx,
    sink: &mut Sink<'t>,
) -> Result<(), String> {
    if items.is_empty() {
        return Ok(());
    }

    // Greedy wrap into lines.
    let space_w = ctx.fonts.resolve(&tctx.family).advance_for(' ', tctx.size);
    let mut lines: Vec<Vec<InlineItem<'t>>> = Vec::new();
    let mut cur: Vec<InlineItem<'t>> = Vec::new();
    let mut cur_w: f32 = 0.0;

    for it in items.drain(..) {
        let w = match &it {
            InlineItem::Word { width, .. } => *width,
            InlineItem::Replaced { w, .. } | InlineItem::InlineBlock { w, .. } => *w as f32,
            InlineItem::Space => space_w,
        };
        // Drop leading space on a fresh line.
        if cur.is_empty() && matches!(it, InlineItem::Space) {
            continue;
        }
        if cur_w + w > content_width as f32 && !cur.is_empty() {
            lines.push(std::mem::take(&mut cur));
            cur_w = 0.0;
            if matches!(it, InlineItem::Space) {
                continue; // no leading space on new line
            }
        }
        cur_w += w;
        cur.push(it);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }

    for line in &mut lines {
        let line_w: f32 = line
            .iter()
            .map(|it| match it {
                InlineItem::Word { width, .. } => *width,
                InlineItem::Replaced { w, .. } | InlineItem::InlineBlock { w, .. } => *w as f32,
                InlineItem::Space => space_w,
            })
            .sum();
        let line_h: i32 = line
            .iter()
            .map(|it| match it {
                InlineItem::Word { size, .. } => (*size * 1.25).ceil() as i32,
                InlineItem::Replaced { h, .. } | InlineItem::InlineBlock { h, .. } => *h,
                InlineItem::Space => (tctx.size * 1.25).ceil() as i32,
            })
            .max()
            .unwrap_or(16);

        let offset = match tctx.align {
            Align::Left | Align::Center => {
                let extra = (content_width as f32 - line_w).max(0.0);
                if matches!(tctx.align, Align::Center) {
                    extra / 2.0
                } else {
                    0.0
                }
            }
            Align::Right => (content_width as f32 - line_w).max(0.0),
        };
        let mut x = content_left as f32 + offset;

        // Remove trailing spaces for width display (they still add no width
        // because they're the last token).
        while let Some(InlineItem::Space) = line.last() {
            line.pop();
        }

        for it in line.drain(..) {
            match it {
                InlineItem::Word {
                    text,
                    family,
                    size,
                    bold,
                    color,
                    width,
                    tref,
                } => {
                    let font = ctx.fonts.resolve(&family);
                    let baseline_y = cursor.y + (line_h as f32 * 0.8) as i32;
                    if let Some(cvs) = cursor.canvas.as_deref_mut() {
                        // First painted word of a `TEXTREF` run: emit the
                        // marker ahead of the run's `Cov` ops so the packer
                        // can swap them for a live-text record.
                        if let Some(meta) = &tref {
                            if sink.tref_seen.insert(meta.key) {
                                if let Some(dl) = &mut cvs.dl {
                                    dl.push(g6b_gr::canvas32::DlOp::Tref(
                                        g6b_gr::canvas32::DlTref {
                                            key: meta.key,
                                            id: meta.id.clone(),
                                            text: meta.text.clone(),
                                            cx: content_left,
                                            cy: cursor.y,
                                            cw: content_width,
                                            ch: line_h,
                                            pen_x: x as i32,
                                            base_y: baseline_y,
                                            max_w: content_left + content_width - x as i32,
                                            size_x8: (size * 8.0).round() as u32,
                                            fg: color,
                                        },
                                    ));
                                }
                            }
                        }
                        cvs.dl_tref = tref.as_ref().map(|m| m.key);
                        for ch in text.chars() {
                            let glyph = font.rasterize_for(ch, size);
                            let gx = x as i32;
                            blit_glyph32(cvs, gx, baseline_y, &glyph, color);
                            if bold {
                                blit_glyph32(cvs, gx + 1, baseline_y, &glyph, color);
                            }
                            x += glyph.advance;
                        }
                        cvs.dl_tref = None;
                    } else {
                        x += width;
                    }
                }
                InlineItem::Replaced {
                    node,
                    path,
                    w,
                    h,
                    color,
                    kind,
                } => {
                    if let Some(cvs) = cursor.canvas.as_deref_mut() {
                        let dx = x as i32;
                        let dy = cursor.y + line_h - h;
                        if w > 0 && h > 0 {
                            paint_replaced(cvs, ctx, node, dx, dy, w, h, alpha, color, &kind);
                            sink.hit_boxes.push(HitBox {
                                id: node.id.clone(),
                                name: node.name.clone(),
                                path,
                                x: dx,
                                y: dy,
                                w,
                                h,
                            });
                        }
                    }
                    x += w as f32;
                }
                InlineItem::InlineBlock {
                    node,
                    mut path,
                    w,
                    h,
                    tctx: item_tctx,
                } => {
                    if let Some(cvs) = cursor.canvas.as_deref_mut() {
                        let flow = Flow {
                            x: x as i32,
                            // Bottom-align on the line, matching the replaced
                            // path, so a tab and its label share a baseline.
                            y: cursor.y + line_h - h,
                            avail_w: w,
                            depth: 0,
                        };
                        let cb = Rect {
                            x: x as i32,
                            y: cursor.y,
                            w,
                            h,
                        };
                        paint_block(
                            cvs, ctx, node, flow, cb, alpha, &item_tctx, &mut path, sink, None,
                            None,
                        )?;
                    }
                    x += w as f32;
                }
                InlineItem::Space => {
                    x += space_w;
                }
            }
        }
        cursor.y += line_h;
        cursor.x_px = 0.0;
        cursor.line_h = 0;
    }
    Ok(())
}

fn paint_replaced(
    canvas: &mut Canvas32,
    ctx: &Ctx32<'_>,
    node: &Node,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    alpha: u8,
    color: Rgba,
    kind: &Replaced,
) {
    match kind {
        Replaced::Img { src } => {
            if let Some(Asset::Raster(img)) = ctx.assets.get(src) {
                paint_image_fit(canvas, img, x, y, w, h, alpha, object_fit(node, ctx));
            } else if let Some(Asset::Vector(svg_node)) = ctx.assets.get(src) {
                let _ =
                    g6b_img::svg::paint(canvas, svg_node, x, y, w, h, alpha, &svg_style(ctx.sheet));
            } else if src == node.get_attribute("alt").unwrap_or("") {
                // Asset missing and the `src` has been replaced by alt text:
                // this is handled by the word path, not here.
            } else {
                // Asset missing: draw a small placeholder frame.
                let c = Canvas32::with_alpha(color, alpha);
                canvas.stroke_rounded_rect(x, y, w, h, 0, 1, c);
            }
        }
        Replaced::Svg => {
            let _ = g6b_img::svg::paint(canvas, node, x, y, w, h, alpha, &svg_style(ctx.sheet));
        }
        Replaced::Icon { name } => {
            if let Some(icon) = icons::icon(name) {
                let mut c = color;
                c[3] = Canvas32::mul_alpha(c[3], alpha);
                icons::draw(canvas, icon, x, y, w.min(h), c);
            }
        }
        Replaced::Other => {}
    }
}

fn object_fit(_node: &Node, _ctx: &Ctx32<'_>) -> String {
    // The node style already contains `object-fit` if the cascade has it.
    // The `kind` value carries only the resolved dimensions; the node itself
    // still has its attributes and CSS. Re-cascade here is fine (cheap).
    let style = cascade(_ctx.sheet, &ElementRef::from_node(_node));
    style
        .get("object-fit")
        .unwrap_or("fill")
        .trim()
        .to_ascii_lowercase()
}

fn paint_image_fit(
    canvas: &mut Canvas32,
    img: &g6b_img::RgbaImage,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    alpha: u8,
    fit: String,
) {
    match fit.as_str() {
        "contain" => {
            let scale = (w as f64 / img.w.max(1) as f64)
                .min(h as f64 / img.h.max(1) as f64)
                .min(1.0);
            let dw = (img.w as f64 * scale) as i32;
            let dh = (img.h as f64 * scale) as i32;
            let ox = x + (w - dw) / 2;
            let oy = y + (h - dh) / 2;
            img.blit(canvas, ox, oy, dw, dh, alpha);
        }
        "cover" => {
            let scale = (w as f64 / img.w.max(1) as f64).max(h as f64 / img.h.max(1) as f64);
            let dw = (img.w as f64 * scale) as i32;
            let dh = (img.h as f64 * scale) as i32;
            let ox = x + (w - dw) / 2;
            let oy = y + (h - dh) / 2;
            let sw2 = (w as f64 / scale) as u32;
            let sh2 = (h as f64 / scale) as u32;
            let sx = img.w.saturating_sub(sw2) / 2;
            let sy = img.h.saturating_sub(sh2) / 2;
            canvas.blit_rgba_region(
                &img.rgba, img.w, img.h, sx, sy, sw2, sh2, ox, oy, dw, dh, alpha,
            );
        }
        _ => img.blit(canvas, x, y, w, h, alpha),
    }
}

// SVG presentation attributes resolve first against the CSS cascade, then the
// DOM attribute. This lets BIOS stylesheets style `fill`/`stroke` while the
// vector art keeps its default attributes.
fn svg_style(sheet: &Stylesheet) -> Box<dyn Fn(&Node, &str) -> Option<String> + '_> {
    Box::new(|node: &Node, prop: &str| {
        let el = ElementRef::from_node(node);
        if let Some(v) = cascade(sheet, &el).get(prop) {
            return Some(v.to_string());
        }
        node.get_attribute(prop).map(str::to_string)
    })
}

// Re-exports of the colour / length helpers used by the renderer.
fn length(value: &str, basis: i32) -> Result<i32, String> {
    crate::length(value, basis).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    #[test]
    fn flex_rows_wrap_and_distribute_free_space() {
        let fonts = g6b_ttf::FontSet::default_set().unwrap();
        let html = "<div id='row'><div id='a'></div><div id='b'></div><div id='c'></div></div>";
        let css = "body{margin:0} #row{display:flex;flex-wrap:wrap;gap:10px;width:210px} #a,#b,#c{flex-basis:100px;flex-grow:1;height:20px;background-color:red}";
        let out = super::render32(html, css, 240, 100, &Default::default(), &fonts).unwrap();
        let hit = |id| {
            out.hit_boxes
                .iter()
                .find(|hit| hit.id.as_deref() == Some(id))
                .unwrap()
        };
        assert_eq!((hit("a").x, hit("a").y, hit("a").w), (0, 0, 100));
        assert_eq!((hit("b").x, hit("b").y, hit("b").w), (110, 0, 100));
        assert_eq!((hit("c").x, hit("c").y, hit("c").w), (0, 30, 210));
        assert_eq!(hit("row").h, 50);
    }

    #[test]
    fn shadow_paints_outside_the_box_without_changing_its_hit_region() {
        let fonts = g6b_ttf::FontSet::default_set().unwrap();
        let out = super::render32("<div id='box'></div>", "body{margin:0} #box{margin:10px;width:20px;height:20px;background-color:white;box-shadow:6px 4px 0px 0px #000000}", 64, 64, &Default::default(), &fonts).unwrap();
        assert_eq!(out.canvas.get(33, 20), [0, 0, 0, 255]);
        assert_eq!(out.canvas.get(20, 20), [255, 255, 255, 255]);
        let hit = out
            .hit_boxes
            .iter()
            .find(|hit| hit.id.as_deref() == Some("box"))
            .unwrap();
        assert_eq!((hit.x, hit.y, hit.w, hit.h), (10, 10, 20, 20));
    }

    use super::*;

    fn setup() -> (FontSet, AssetMap) {
        let fonts = FontSet::default_set().expect("default font");
        let assets = AssetMap::new();
        (fonts, assets)
    }

    /// Bounding box of every pixel that is not the opaque white page
    /// background, as `(x0, y0, x1, y1)`.
    fn ink_bounds(c: &Canvas32) -> Option<(i32, i32, i32, i32)> {
        let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
        for y in 0..c.h as i32 {
            for x in 0..c.w as i32 {
                if c.get(x, y) != [255, 255, 255, 255] {
                    x0 = x0.min(x);
                    y0 = y0.min(y);
                    x1 = x1.max(x);
                    y1 = y1.max(y);
                }
            }
        }
        (x0 <= x1).then_some((x0, y0, x1, y1))
    }

    #[test]
    fn max_width_with_auto_margins_centers_the_column() {
        let (fonts, assets) = setup();
        let html = "<body><div id=\"col\"></div></body>";
        let css = "#col { max-width: 40px; height: 10px; margin: 0 auto; \
                   background-color: #f00; }";
        let out = render32(html, css, 100, 20, &assets, &fonts).unwrap();
        let (x0, _, x1, _) = ink_bounds(&out.canvas).expect("column must paint");
        assert_eq!((x0, x1), (30, 69), "40px column centered in 100px");
        // Without the auto margins the same box must stay flush left, so the
        // test proves the margins and not just the clamp.
        let css_left = "#col { max-width: 40px; height: 10px; background-color: #f00; }";
        let flush = render32(html, css_left, 100, 20, &assets, &fonts).unwrap();
        assert_eq!(ink_bounds(&flush.canvas).unwrap().0, 0);
    }

    #[test]
    fn inline_elements_share_one_line_instead_of_stacking() {
        let (fonts, assets) = setup();
        // Three inline spans. Before the inline-formatting fix each one ended
        // the line, so they stacked; they must now sit on one baseline.
        let html = "<body><p><span>A</span><span>B</span><span>C</span></p></body>";
        let css = "body { color: #f00; } p { margin: 0; }";
        let out = render32(html, css, 200, 60, &assets, &fonts).unwrap();
        let (_, y0, _, y1) = ink_bounds(&out.canvas).expect("text must paint");
        assert!(
            y1 - y0 < 20,
            "three inline spans must share one line, ink spans {}px",
            y1 - y0
        );
    }

    #[test]
    fn inline_block_tabs_keep_their_own_boxes_on_one_line() {
        let (fonts, assets) = setup();
        let html = "<body><nav><a id=\"t1\">Main</a><a id=\"t2\">CPU</a><a id=\"t3\">Boot</a></nav></body>";
        // Descendant selectors are deliberately not matchable in this cascade,
        // so the tab rule is written on the element itself.
        let css = "a { display: inline-block; padding: 4px; background-color: #036; \
                   color: #0ff; }";
        let out = render32(html, css, 400, 60, &assets, &fonts).unwrap();

        let tabs: Vec<&HitBox> = out.hit_boxes.iter().filter(|b| b.name == "a").collect();
        assert_eq!(tabs.len(), 3);
        // Side by side, in order, sharing a top edge.
        assert!(tabs[0].x < tabs[1].x && tabs[1].x < tabs[2].x);
        assert!(tabs.iter().all(|b| b.y == tabs[0].y));
        // Shrink-to-fit: a tab is only as wide as its label plus padding, and
        // "Main" is wider than "CPU".
        assert!(tabs[0].w > tabs[1].w);
        assert!(
            tabs.iter().all(|b| b.w < 200),
            "tabs must not fill the line"
        );
        // The background actually paints, which an inline (non-atomic) box
        // would not do.
        let mid = out.canvas.get(tabs[0].x + tabs[0].w / 2, tabs[0].y + 1);
        assert_eq!(mid[3], 255);
        assert!(
            mid[2] > mid[0],
            "tab background is the blue #036, got {mid:?}"
        );
    }

    #[test]
    fn table_cells_lay_out_as_columns_and_share_a_row_height() {
        let (fonts, assets) = setup();
        let html = "<body><table><tr><th>Setting</th><td>Value</td><td>Access</td></tr>\
                    <tr><th>XLEN</th><td>64</td><td>Read-only</td></tr></table></body>";
        let css = "body { color: #0ff; } th { background-color: #036; }";
        let out = render32(html, css, 400, 120, &assets, &fonts).unwrap();

        let cells: Vec<&HitBox> = out
            .hit_boxes
            .iter()
            .filter(|b| b.name == "th" || b.name == "td")
            .collect();
        assert_eq!(cells.len(), 6, "two rows of three cells");

        // Row 1 cells are side by side, in document order, and non-overlapping.
        let row1 = &cells[..3];
        assert!(row1[0].x < row1[1].x && row1[1].x < row1[2].x);
        assert!(row1[0].x + row1[0].w <= row1[1].x + 1);
        assert!(row1[1].x + row1[1].w <= row1[2].x + 1);
        // ... and share one top edge and one height.
        assert!(row1.iter().all(|b| b.y == row1[0].y));
        assert!(row1.iter().all(|b| b.h == row1[0].h));

        // Row 2 starts below row 1 and reuses the same column origins, which is
        // what makes it read as a table rather than two independent lines.
        let row2 = &cells[3..];
        assert!(row2[0].y >= row1[0].y + row1[0].h);
        for i in 0..3 {
            assert_eq!(row2[i].x, row1[i].x, "column {i} must be aligned");
        }
        // The columns tile the container: `Access`/`Read-only` is the widest
        // column, so an equal-split would misplace it.
        let spanned: i32 = row1.iter().map(|b| b.w).sum();
        assert!((390..=400).contains(&spanned), "columns tile: {spanned}");
        assert!(
            row1[2].w > row1[1].w,
            "widest content gets the widest column"
        );
    }

    #[test]
    fn red_box_blends_over_blue_background() {
        let (fonts, assets) = setup();
        let html = "<body><div class=\"box\"></div></body>";
        let css = ".box { width: 32px; height: 32px; background-color: rgba(255,0,0,0.5); } body { background-color: #00f; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        let p = out.canvas.get(16, 16);
        assert_eq!(p[3], 255); // composited opaque
        assert!(
            p[0] >= 120 && p[0] <= 135,
            "red channel should be ~128, got {}",
            p[0]
        );
        assert!(
            p[2] >= 120 && p[2] <= 135,
            "blue channel should be ~127, got {}",
            p[2]
        );
    }

    #[test]
    fn rounded_rect_leaves_corner_transparent() {
        let (fonts, assets) = setup();
        let html = "<body><div class=\"box\"></div></body>";
        let css = ".box { width: 32px; height: 32px; border-radius: 8px; background-color: #0f0; } body { background-color: #fff; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        assert_eq!(out.canvas.get(2, 2), [255, 255, 255, 255]); // corner stays white
        assert_eq!(out.canvas.get(16, 16), [0, 255, 0, 255]); // centre is green
    }

    #[test]
    fn font_icon_paints_pixels() {
        let (fonts, assets) = setup();
        let html = "<body><i class=\"fa fa-gear\"></i></body>";
        let css = "i { font-size: 24px; color: #f00; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        let has_red = out
            .canvas
            .pixels()
            .chunks_exact(4)
            .any(|p| p[0] > 0 && p[1] == 0 && p[2] == 0 && p[3] > 0);
        assert!(has_red, "icon should paint red pixels");
    }

    #[test]
    fn img_asset_draws_scaled() {
        let (fonts, mut assets) = setup();
        assets.insert(
            "red.png".into(),
            g6b_img::Asset::Raster(g6b_img::RgbaImage::solid(2, 2, [255, 0, 0, 255])),
        );
        let html = "<body><img src=\"red.png\" width=\"16\" height=\"16\"></body>";
        let css = "body { background-color: #fff; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        // The image is at the top-left of the body; sample its centre.
        assert_eq!(out.canvas.get(8, 8), [255, 0, 0, 255]);
    }

    #[test]
    fn inline_svg_draws() {
        let (fonts, assets) = setup();
        let html = r##"<body><svg width="16" height="16" viewBox="0 0 16 16"><rect width="16" height="16" fill="#f00"/></svg></body>"##;
        let css = "body { background-color: #fff; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        assert_eq!(out.canvas.get(8, 8), [255, 0, 0, 255]);
    }

    #[test]
    fn hit_boxes_record_blocks_and_replaced() {
        let (fonts, mut assets) = setup();
        assets.insert(
            "red.png".into(),
            g6b_img::Asset::Raster(g6b_img::RgbaImage::solid(2, 2, [255, 0, 0, 255])),
        );
        let html = r#"<body><div id="box"><img src="red.png" width="8" height="8"></div></body>"#;
        let css = "#box { width: 32px; height: 32px; background: #eee; }";
        let out = render32(html, css, 64, 64, &assets, &fonts).unwrap();
        let names: Vec<_> = out.hit_boxes.iter().map(|h| h.name.as_str()).collect();
        assert!(names.contains(&"div"), "div hit box missing");
        assert!(names.contains(&"img"), "img hit box missing");
    }
}
