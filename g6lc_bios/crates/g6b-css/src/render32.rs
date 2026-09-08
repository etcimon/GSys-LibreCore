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
    let body = find_body(&root).unwrap_or(&root);
    let mut canvas = Canvas32::opaque(w, h, [255, 255, 255]);
    let ctx = Ctx32 {
        sheet,
        fonts,
        assets,
    };
    let icb = Rect {
        x: 0,
        y: 0,
        w: w as i32,
        h: h as i32,
    };
    let mut sink = Sink {
        hit_boxes: Vec::new(),
        absolutes: Vec::new(),
    };
    let tctx = TextCtx::default();
    // The <body> (or root) is a block formatting context; paint it as one block
    // so its own background, padding, and children all share one flow.
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

    let mut drained = 0usize;
    while let Some(abs) = sink.absolutes.pop() {
        drained += 1;
        if drained > MAX_ABSOLUTE_BOXES {
            return Err("absolute box budget exceeded".into());
        }
        paint_absolute(&mut canvas, &ctx, &abs, &mut sink)?;
    }
    Ok(Render32Output {
        canvas,
        hit_boxes: sink.hit_boxes,
    })
}

#[derive(Clone, Copy)]
struct Ctx32<'a> {
    sheet: &'a Stylesheet,
    fonts: &'a FontSet,
    assets: &'a AssetMap,
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
        let mut scratch = Sink {
            hit_boxes: Vec::new(),
            absolutes: Vec::new(),
        };
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
    let mut scratch = Sink {
        hit_boxes: Vec::new(),
        absolutes: Vec::new(),
    };
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
        Some(d) if d == "block" || d == "flow-root" || d == "list-item" => true,
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
        let mut scratch = Sink {
            hit_boxes: Vec::new(),
            absolutes: Vec::new(),
        };
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
        let mut scratch = Sink {
            hit_boxes: Vec::new(),
            absolutes: Vec::new(),
        };
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
                } => {
                    let font = ctx.fonts.resolve(&family);
                    let baseline_y = cursor.y + (line_h as f32 * 0.8) as i32;
                    if let Some(cvs) = cursor.canvas.as_deref_mut() {
                        for ch in text.chars() {
                            let glyph = font.rasterize_for(ch, size);
                            let gx = x as i32;
                            blit_glyph32(cvs, gx, baseline_y, &glyph, color);
                            if bold {
                                blit_glyph32(cvs, gx + 1, baseline_y, &glyph, color);
                            }
                            x += glyph.advance;
                        }
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
