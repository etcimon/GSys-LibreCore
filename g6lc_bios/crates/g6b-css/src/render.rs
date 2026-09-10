// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded CSS block-flow rendering to a 16-colour pixel canvas.
//!
//! This is intentionally minimal: one root block container, children stacked
//! vertically, margin/padding/border/background-colour honoured, everything
//! else ignored. It is enough to produce a deterministic golden PPM for
//! `g6b-css` cascade and box-model tests. See `architecture/RENDER-VALIDATION.md`.

use crate::parse;
use crate::{
    absolute_origin, cascade, computed_absolute_box, computed_box, computed_position, ElementRef,
    Position,
};
use g6b_dom::Node;
use g6b_gr::canvas::Canvas;
use g6b_gr::{nearest_palette_index, PALETTE};

/// Budgets, matching the rest of `g6b-css`.
pub const MAX_RENDER_NODES: usize = 256;
/// Bound on out-of-flow boxes drained after the in-flow pass. Absolutes can
/// nest, so the drain loop needs its own budget independent of node depth.
pub const MAX_ABSOLUTE_BOXES: usize = 64;

/// Render-pass invariants. Bundled so the layout functions stay under the
/// argument-count limit as positioning threads more state through them.
#[derive(Clone, Copy)]
struct Ctx<'a> {
    sheet: &'a crate::Stylesheet,
    mode: ColorMode,
    draw_text: DrawText,
    font: Option<&'a g6b_ttf::BiosFont>,
    font_size: f32,
}

/// Flow position for one box: where it starts, how much width it may use, and
/// how deep the recursion is.
#[derive(Clone, Copy)]
struct Flow {
    x: i32,
    y: i32,
    avail_w: i32,
    depth: usize,
}

/// A containing-block rectangle — the padding box of the nearest positioned
/// ancestor, or the whole canvas for the initial containing block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Rect {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

/// An out-of-flow box parked until the in-flow pass finishes, so absolutes
/// paint on top of the content they overlay.
struct Absolute<'t> {
    node: &'t Node,
    cb: Rect,
    path: Vec<usize>,
    depth: usize,
}

/// Mutable render outputs. Kept apart from the canvas because `Cursor` borrows
/// the canvas mutably while these keep accumulating.
struct Sink<'t> {
    hit_boxes: Vec<HitBox>,
    absolutes: Vec<Absolute<'t>>,
}

/// How colour values are resolved. Golden-image tests use `Exact` (unknown
/// colours stay transparent); real UI raster uses `Approximate` so `#c8c8c8`
/// and `rgba(...)` fall back to the nearest 16-colour palette entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorMode {
    Exact,
    Approximate,
}

/// Whether to draw text on the canvas, or reserve it for the block-flow box
/// model only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DrawText {
    Yes,
    No,
}

/// A box on the rendered page that can be hit-tested for input dispatch.
/// Coordinates are in CSS pixels relative to the top-left of the canvas.
#[derive(Debug, Clone)]
pub struct HitBox {
    /// DOM node `id` if any.
    pub id: Option<String>,
    /// Element tag name or `#text`.
    pub name: String,
    /// Path from the document root to this node (child indices).
    pub path: Vec<usize>,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// Render result carrying both the canvas and the hit boxes produced while
/// painting.
#[derive(Debug, Clone)]
pub struct RenderOutput {
    pub canvas: Canvas,
    pub hit_boxes: Vec<HitBox>,
}

/// Parse a CSS colour to `[r,g,b]`. Supports hex `#rgb`/`#rrggbb`, named
/// colours, `rgb(r,g,b)` and `rgba(r,g,b,a)`. Percentages and the alpha
/// channel are accepted and ignored/flattened because the canvas is a 16-index
/// palette: this function returns the *intended* opaque colour, and the caller
/// decides whether to blend or approximate.
pub fn parse_color(value: &str) -> Option<[u8; 3]> {
    let v = value.trim().to_ascii_lowercase();
    if v.eq_ignore_ascii_case("transparent") {
        return None;
    }
    if let Some(rest) = v.strip_prefix("rgba(") {
        return rgb(rest);
    }
    if let Some(rest) = v.strip_prefix("rgb(") {
        return rgb(rest);
    }
    if let Some(rest) = v.strip_prefix('#') {
        return hex_to_rgb(rest);
    }
    match v.as_str() {
        "black" => Some([0, 0, 0]),
        "blue" => Some([0, 0, 170]),
        "green" => Some([0, 170, 0]),
        "cyan" | "aqua" => Some([0, 170, 170]),
        "red" => Some([170, 0, 0]),
        "magenta" | "fuchsia" | "purple" => Some([170, 0, 170]),
        "brown" | "orange" => Some([170, 85, 0]),
        "lightgray" | "lightgrey" | "silver" | "gray" | "grey" => Some([170, 170, 170]),
        "darkgray" | "darkgrey" => Some([85, 85, 85]),
        "lightblue" => Some([85, 85, 255]),
        "lightgreen" | "lime" => Some([85, 255, 85]),
        "lightcyan" => Some([85, 255, 255]),
        "lightred" => Some([255, 85, 85]),
        "pink" => Some([255, 85, 255]),
        "yellow" => Some([255, 255, 85]),
        "white" => Some([255, 255, 255]),
        _ => None,
    }
}

fn hex_to_rgb(hex: &str) -> Option<[u8; 3]> {
    let hex = if hex.len() == 3 {
        let mut out = String::with_capacity(6);
        for c in hex.chars() {
            out.push(c);
            out.push(c);
        }
        out
    } else {
        hex.to_string()
    };
    if hex.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&hex[..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    Some([r, g, b])
}

fn rgb(rest: &str) -> Option<[u8; 3]> {
    let rest = rest.strip_suffix(')')?;
    let parts: Vec<&str> = rest.split(',').map(str::trim).collect();
    if parts.len() < 3 {
        return None;
    }
    let mut out = [0u8; 3];
    for i in 0..3 {
        let p = parts[i];
        out[i] = if let Some(rest) = p.strip_suffix('%') {
            let n: f64 = rest.parse().ok()?;
            (n * 2.55).round() as u8
        } else {
            p.parse().ok()?
        };
    }
    Some(out)
}

/// Exact match against the 16-colour palette. Used for golden images where a
/// non-palette colour is a test failure, not an approximation.
pub fn color_to_index(value: &str) -> Option<u8> {
    let rgb = parse_color(value)?;
    for (i, &c) in PALETTE.iter().enumerate() {
        if c == rgb {
            return Some(i as u8);
        }
    }
    None
}

/// Nearest palette entry by Euclidean distance. For UI raster where the source
/// palette has 24-bit colours, this is the only honest fallback.
pub fn nearest_color_index(value: &str) -> Option<u8> {
    Some(nearest_palette_index(parse_color(value)?))
}

fn resolve_color(value: &str, mode: ColorMode) -> Option<u8> {
    match mode {
        ColorMode::Exact => color_to_index(value),
        ColorMode::Approximate => nearest_color_index(value),
    }
}

/// Render a tiny HTML document with CSS to a `w`×`h` canvas.
///
/// The page background is white (index 15). Unsupported properties are treated
/// as absent, not defaulted, so a missing colour is a missing fill — a
/// deliberate visual bug, which is the point of a correctness gate.
pub fn render_to_canvas(html: &str, css: &str, w: u32, h: u32) -> Result<Canvas, String> {
    render_to_canvas_ex(html, css, w, h, ColorMode::Exact, DrawText::No)
}

/// Render a real UI document, with approximate colours and text drawn.
/// Unknown properties are ignored so a real-world stylesheet does not fail on
/// the first unsupported declaration.
pub fn render_ui_to_canvas(html: &str, css: &str, w: u32, h: u32) -> Result<Canvas, String> {
    Ok(render_ui_to_output(html, css, w, h)?.canvas)
}

/// Render a real UI document and return the canvas plus hit boxes.
#[allow(clippy::too_many_arguments)]
pub fn render_ui_to_output(html: &str, css: &str, w: u32, h: u32) -> Result<RenderOutput, String> {
    let (sheet, _unsupported) = crate::parse_survey(css).map_err(|e| e.to_string())?;
    let font = g6b_ttf::default_bios_font().ok();
    render_sheet_to_output(
        &sheet,
        html,
        w,
        h,
        ColorMode::Approximate,
        DrawText::Yes,
        font.as_ref(),
        16.0,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn render_to_canvas_ex(
    html: &str,
    css: &str,
    w: u32,
    h: u32,
    mode: ColorMode,
    draw_text: DrawText,
) -> Result<Canvas, String> {
    let sheet = parse(css).map_err(|e| e.to_string())?;
    Ok(render_sheet_to_output(&sheet, html, w, h, mode, draw_text, None, 8.0)?.canvas)
}

/// Render an already-parsed stylesheet and HTML document.
#[allow(clippy::too_many_arguments)]
pub fn render_sheet_to_canvas(
    sheet: &crate::Stylesheet,
    html: &str,
    w: u32,
    h: u32,
    mode: ColorMode,
    draw_text: DrawText,
    font: Option<&g6b_ttf::BiosFont>,
    font_size: f32,
) -> Result<Canvas, String> {
    Ok(render_sheet_to_output(sheet, html, w, h, mode, draw_text, font, font_size)?.canvas)
}

#[allow(clippy::too_many_arguments)]
pub fn render_sheet_to_output(
    sheet: &crate::Stylesheet,
    html: &str,
    w: u32,
    h: u32,
    mode: ColorMode,
    draw_text: DrawText,
    font: Option<&g6b_ttf::BiosFont>,
    font_size: f32,
) -> Result<RenderOutput, String> {
    let root = g6b_html::parse(html);

    // Find <body> if present, otherwise paint the document's children.
    let body = find_body(&root).unwrap_or(&root);
    let mut canvas = Canvas::white(w, h);
    let ctx = Ctx {
        sheet,
        mode,
        draw_text,
        font,
        font_size,
    };
    // Initial containing block: the whole canvas.
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
    let mut y = 0i32;
    for (count, child) in body.children.iter().enumerate() {
        if count >= MAX_RENDER_NODES {
            return Err("render node budget exceeded".into());
        }
        let mut path = vec![count];
        // A top-level absolute is parked exactly like a nested one; the body
        // loop is a flow context too, so it must not advance `y` for it.
        let style = cascade(sheet, &ElementRef::from_node(child));
        if computed_position(&style).map_err(|e| e.to_string())? == Position::Absolute {
            if sink.absolutes.len() >= MAX_ABSOLUTE_BOXES {
                return Err("absolute box budget exceeded".into());
            }
            sink.absolutes.push(Absolute {
                node: child,
                cb: icb,
                path,
                depth: 0,
            });
            continue;
        }
        let flow = Flow {
            x: 0,
            y,
            avail_w: w as i32,
            depth: 0,
        };
        y = paint_block(&mut canvas, &ctx, child, flow, icb, &mut path, &mut sink)?;
    }
    // Out-of-flow pass: absolutes paint over the in-flow content. Draining a
    // queue (rather than recursing inline) is what puts them on top and lets a
    // nested absolute enqueue itself.
    let mut drained = 0usize;
    while let Some(abs) = sink.absolutes.pop() {
        drained += 1;
        if drained > MAX_ABSOLUTE_BOXES {
            return Err("absolute box budget exceeded".into());
        }
        paint_absolute(&mut canvas, &ctx, &abs, &mut sink)?;
    }
    Ok(RenderOutput {
        canvas,
        hit_boxes: sink.hit_boxes,
    })
}

/// Paint one out-of-flow box against its containing block.
///
/// The box is sized by [`computed_absolute_box`] (explicit `width`/`height`
/// required) and placed by [`absolute_origin`], then handed to the ordinary
/// block painter at that origin with zero available-width slack, so its own
/// children lay out exactly as they would in flow.
fn paint_absolute<'t>(
    canvas: &mut Canvas,
    ctx: &Ctx<'_>,
    abs: &Absolute<'t>,
    sink: &mut Sink<'t>,
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
    // An absolute box is itself a containing block for its descendants.
    let cb = Rect {
        x: ox + b.margin.left + b.border.left,
        y: oy + b.margin.top + b.border.top,
        w: b.content_width + b.padding.horizontal(),
        h: b.content_height + b.padding.vertical(),
    };
    paint_block(canvas, ctx, abs.node, flow, cb, &mut path, sink)?;
    Ok(())
}

pub(crate) fn find_body(root: &Node) -> Option<&Node> {
    if root.name.eq_ignore_ascii_case("body") {
        return Some(root);
    }
    root.children.iter().find_map(find_body)
}

pub(crate) fn is_block(name: &str) -> bool {
    matches!(
        name,
        "body"
            | "html"
            | "main"
            | "div"
            | "p"
            | "section"
            | "nav"
            | "header"
            | "footer"
            | "article"
            | "aside"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "ul"
            | "ol"
            | "li"
            | "pre"
            | "table"
            | "tbody"
            | "thead"
            | "tfoot"
            | "tr"
            | "form"
            | "blockquote"
    )
}

fn prepare_box<'t>(
    ctx: &Ctx<'_>,
    node: &'t Node,
    flow: Flow,
    cb: Rect,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
) -> Result<(crate::BoxModel, i32, i32), String> {
    let style = cascade(ctx.sheet, &ElementRef::from_node(node));
    let mut b = computed_box(&style, flow.avail_w).map_err(|e| e.to_string())?;

    let box_left = flow.x + b.margin.left;
    let box_top = flow.y + b.margin.top;
    let content_left = box_left + b.border.left + b.padding.left;
    let content_top = box_top + b.border.top + b.padding.top;

    if b.content_height == 0 {
        // Auto height: measure children to know how much background to fill.
        // The cursor `y` is a baseline; if there is any inline content we add
        // one line of pixels to include it.
        let mut cursor = Cursor::new(
            content_left,
            content_top,
            content_width_safe(&b),
            ctx.font,
            ctx.font_size,
        );
        // Measuring must not enqueue absolutes a second time — the painting
        // pass below re-walks the same children.
        let mut scratch = Sink {
            hit_boxes: Vec::new(),
            absolutes: Vec::new(),
        };
        children_layout(
            &mut cursor,
            ctx,
            node,
            content_left,
            content_width_safe(&b),
            flow.depth + 1,
            cb,
            path,
            &mut scratch,
        )?;
        let mut h = cursor.y - content_top;
        if cursor.x_px > 0.0 {
            h += cursor.line_height();
        }
        b.content_height = h.max(0);
        let _ = sink;
    }

    Ok((b, content_left, content_top))
}

fn content_width_safe(b: &crate::BoxModel) -> i32 {
    b.content_width.max(8)
}

fn paint_block<'t>(
    canvas: &mut Canvas,
    ctx: &Ctx<'_>,
    node: &'t Node,
    flow: Flow,
    cb: Rect,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
) -> Result<i32, String> {
    let (x0, y0, mode) = (flow.x, flow.y, ctx.mode);
    if flow.depth > MAX_RENDER_NODES {
        return Err("render depth exceeded".into());
    }
    if node.name.eq_ignore_ascii_case("#text")
        || node.hidden
        || node.name.eq_ignore_ascii_case("br")
        || node.name.eq_ignore_ascii_case("style")
        || node.name.eq_ignore_ascii_case("script")
    {
        return Ok(y0);
    }
    if let Some(d) = cascade(ctx.sheet, &ElementRef::from_node(node)).get("display") {
        if d.eq_ignore_ascii_case("none") {
            return Ok(y0);
        }
    }

    let (b, content_left, content_top) = prepare_box(ctx, node, flow, cb, path, sink)?;
    let style = cascade(ctx.sheet, &ElementRef::from_node(node));

    // Record this block's visual box for hit testing.
    let box_left = x0 + b.margin.left;
    let box_top = y0 + b.margin.top;
    sink.hit_boxes.push(HitBox {
        id: node.id.clone(),
        name: node.name.clone(),
        path: path.clone(),
        x: box_left,
        y: box_top,
        w: b.border_box_width(),
        h: b.border_box_height(),
    });

    // Background fills the content + padding box.
    if let Some(c) = style
        .get("background-color")
        .and_then(|v| resolve_color(v, mode))
    {
        canvas.fill_rect(
            box_left + b.border.left,
            box_top + b.border.top,
            b.border_box_width() - b.border.horizontal(),
            b.border_box_height() - b.border.vertical(),
            c,
        );
    }

    // Border outlines the border box with the declared widths. Unknown
    // border-color is transparent, not defaulted to the text `color`.
    let border_color = style
        .get("border-color")
        .or_else(|| style.get("color"))
        .and_then(|v| resolve_color(v, mode));
    if let Some(border_color) = border_color {
        if b.border.top > 0 {
            canvas.fill_rect(
                box_left,
                box_top,
                b.border_box_width(),
                b.border.top,
                border_color,
            );
        }
        if b.border.bottom > 0 {
            canvas.fill_rect(
                box_left,
                box_top + b.border_box_height() - b.border.bottom,
                b.border_box_width(),
                b.border.bottom,
                border_color,
            );
        }
        if b.border.left > 0 {
            canvas.fill_rect(
                box_left,
                box_top,
                b.border.left,
                b.border_box_height(),
                border_color,
            );
        }
        if b.border.right > 0 {
            canvas.fill_rect(
                box_left + b.border_box_width() - b.border.right,
                box_top,
                b.border.right,
                b.border_box_height(),
                border_color,
            );
        }
    }

    // Children are painted inside the content box.
    let fg = style
        .get("color")
        .and_then(|v| resolve_color(v, mode))
        .unwrap_or(15);
    let bg = style
        .get("background-color")
        .and_then(|v| resolve_color(v, mode))
        .unwrap_or(15);
    let content_width = content_width_safe(&b);
    let mut cursor = Cursor::new(
        content_left,
        content_top,
        content_width,
        ctx.font,
        ctx.font_size,
    );
    cursor.canvas = Some(canvas);
    cursor.text = ctx.draw_text;
    cursor.fg = fg;
    cursor.bg = bg;
    // A positioned box is a containing block for its descendants; a static one
    // passes the inherited containing block straight through.
    let child_cb = match computed_position(&style).map_err(|e| e.to_string())? {
        Position::Absolute => Rect {
            x: box_left + b.border.left,
            y: box_top + b.border.top,
            w: b.content_width + b.padding.horizontal(),
            h: b.content_height + b.padding.vertical(),
        },
        Position::Static => cb,
    };
    children_layout(
        &mut cursor,
        ctx,
        node,
        content_left,
        content_width,
        flow.depth + 1,
        child_cb,
        path,
        sink,
    )?;

    Ok(y0 + b.margin_box_height())
}

fn measure_block<'t>(
    ctx: &Ctx<'_>,
    node: &'t Node,
    flow: Flow,
    cb: Rect,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
) -> Result<i32, String> {
    if flow.depth > MAX_RENDER_NODES {
        return Err("render depth exceeded".into());
    }
    if node.name.eq_ignore_ascii_case("#text")
        || node.hidden
        || node.name.eq_ignore_ascii_case("br")
        || node.name.eq_ignore_ascii_case("style")
        || node.name.eq_ignore_ascii_case("script")
    {
        return Ok(flow.y);
    }
    if let Some(d) = cascade(ctx.sheet, &ElementRef::from_node(node)).get("display") {
        if d.eq_ignore_ascii_case("none") {
            return Ok(flow.y);
        }
    }

    let (b, _, _) = prepare_box(ctx, node, flow, cb, path, sink)?;
    Ok(flow.y + b.margin_box_height())
}

#[allow(clippy::too_many_arguments)]
fn children_layout<'t>(
    cursor: &mut Cursor<'_>,
    ctx: &Ctx<'_>,
    node: &'t Node,
    content_left: i32,
    content_width: i32,
    depth: usize,
    cb: Rect,
    path: &mut Vec<usize>,
    sink: &mut Sink<'t>,
) -> Result<(), String> {
    for (index, child) in node.children.iter().enumerate() {
        if child.hidden {
            continue;
        }
        if child.name.eq_ignore_ascii_case("script") || child.name.eq_ignore_ascii_case("style") {
            continue;
        }
        if child.name.eq_ignore_ascii_case("br") {
            cursor.flush();
            continue;
        }
        if child.name.eq_ignore_ascii_case("#text") {
            let text = child.text.trim();
            if !text.is_empty() {
                cursor.emit_text(text);
            }
            continue;
        }
        // Out of flow: park it and do not advance the cursor. Skipping the
        // cursor is the whole point — an absolute box must not push the
        // content it overlays downward.
        let child_style = cascade(ctx.sheet, &ElementRef::from_node(child));
        if computed_position(&child_style).map_err(|e| e.to_string())? == Position::Absolute {
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
        if is_block(&child.name) {
            cursor.flush();
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
                    path,
                    sink,
                )?
            } else {
                measure_block(ctx, child, flow, cb, path, sink)?
            };
            path.pop();
            cursor.y = bottom;
            cursor.x_px = 0.0;
            continue;
        }
        // Inline element: recurse, using its colour if it has one.
        let fg = child_style
            .get("color")
            .and_then(|v| resolve_color(v, ctx.mode))
            .unwrap_or(cursor.fg);
        let old_fg = cursor.fg;
        cursor.fg = fg;
        path.push(index);
        children_layout(
            cursor,
            ctx,
            child,
            content_left,
            content_width,
            depth,
            cb,
            path,
            sink,
        )?;
        path.pop();
        cursor.fg = old_fg;
    }
    Ok(())
}

/// A text cursor inside a block's content box. If `canvas` is `Some`, it paints;
/// otherwise it only measures. When `font` is `Some`, TTF metrics and raster
/// are used; otherwise the built-in 8×8 font is used.
struct Cursor<'a> {
    content_left: i32,
    content_width: i32,
    x_px: f32,
    y: i32,
    fg: u8,
    bg: u8,
    canvas: Option<&'a mut Canvas>,
    font: Option<&'a g6b_ttf::BiosFont>,
    font_size: f32,
    /// Whether glyphs reach the canvas. Separate from `canvas` because
    /// `canvas.is_some()` also means "paint nested blocks": box-model-only
    /// renders (`DrawText::No`, the golden fixtures) still need backgrounds
    /// and borders, they just must not draw text.
    text: DrawText,
}

impl<'a> Cursor<'a> {
    fn new(
        content_left: i32,
        content_top: i32,
        content_width: i32,
        font: Option<&'a g6b_ttf::BiosFont>,
        font_size: f32,
    ) -> Self {
        Self {
            content_left,
            content_width,
            x_px: 0.0,
            y: content_top,
            fg: 15,
            bg: 15,
            canvas: None,
            font,
            font_size,
            text: DrawText::No,
        }
    }

    fn line_height(&self) -> i32 {
        if self.font.is_some() {
            self.font_size as i32
        } else {
            8
        }
    }

    fn space_width(&self) -> f32 {
        self.font
            .map_or(8.0, |f| f.advance_for(' ', self.font_size))
    }

    fn advance_for(&self, c: char) -> f32 {
        self.font.map_or(8.0, |f| f.advance_for(c, self.font_size))
    }

    fn emit_char(&mut self, c: char) {
        if self.text == DrawText::No {
            // Advance only: the box model still accounts for the text, but no
            // glyph is drawn.
            self.x_px += self.advance_for(c);
            return;
        }
        if let Some(ref mut cvs) = self.canvas {
            if let Some(font) = self.font {
                let glyph = font.rasterize_for(c, self.font_size);
                // Baseline is `y + font_size`; next line increments by line_height.
                let baseline_y = self.y + self.font_size as i32;
                g6b_ttf::blit_glyph(
                    cvs,
                    self.content_left + self.x_px as i32,
                    baseline_y,
                    &glyph,
                    self.fg,
                );
                self.x_px += glyph.advance;
            } else {
                let ch = if c.is_ascii() { c as u8 } else { b'?' };
                cvs.draw_char(
                    self.content_left + self.x_px as i32,
                    self.y,
                    ch,
                    self.fg,
                    self.bg,
                );
                self.x_px += 8.0;
            }
        } else {
            self.x_px += self.advance_for(c);
        }
    }

    fn emit_text(&mut self, text: &str) {
        for word in text.split_whitespace() {
            let word_w: f32 = word.chars().map(|c| self.advance_for(c)).sum();
            if self.x_px > 0.0
                && self.x_px + self.space_width() + word_w > self.content_width as f32
            {
                self.x_px = 0.0;
                self.y += self.line_height();
            }
            if word_w > self.content_width as f32 {
                for c in word.chars() {
                    let w = self.advance_for(c);
                    if self.x_px + w > self.content_width as f32 {
                        self.x_px = 0.0;
                        self.y += self.line_height();
                    }
                    self.emit_char(c);
                }
                continue;
            }
            if self.x_px > 0.0 {
                self.x_px += self.space_width();
            }
            for c in word.chars() {
                self.emit_char(c);
            }
        }
    }

    fn flush(&mut self) {
        if self.x_px > 0.0 {
            self.x_px = 0.0;
            self.y += self.line_height();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_a_red_box_on_blue_background_with_margins() {
        let html = r#"<body><div class="box"></div></body>"#;
        let css = r#"
            .box {
                width: 30px;
                height: 20px;
                background-color: blue;
                border: 4px solid red;
                margin: 4px;
            }
        "#;
        let c = render_to_canvas(html, css, 64, 64).unwrap();
        let ppm = c.to_ppm();
        assert!(ppm.starts_with(b"P6\n64 64\n255\n"));
        // Pixel inside the content box is blue (1), inside the border is red (4).
        assert_eq!(c.get(12, 12), 1);
        assert_eq!(c.get(7, 7), 4);
    }

    #[test]
    fn display_none_and_hidden_are_not_painted() {
        let html = r#"<body><div id="gone"></div><div id="yes"></div></body>"#;
        let css = r#"
            #gone { display: none; }
            #yes { width: 10px; height: 10px; background-color: red; }
        "#;
        let c = render_to_canvas(html, css, 32, 32).unwrap();
        // The hidden one contributes nothing; the red box starts at (0,0).
        assert_eq!(c.get(0, 0), 4);
        assert_eq!(c.get(0, 12), 15); // white background below the 10px box
    }

    #[test]
    fn border_box_sizing_keeps_total_width_within_container() {
        let html = r#"<body><div class="box"></div></body>"#;
        let css = r#"
            .box {
                box-sizing: border-box;
                width: 32px;
                height: 16px;
                padding-left: 4px;
                border-left-width: 4px;
                margin-left: 2px;
                background-color: blue;
            }
        "#;
        let c = render_to_canvas(html, css, 64, 64).unwrap();
        // Background exists and does not overflow.
        assert!(c.pixels().iter().any(|&p| p == 1));
    }

    #[test]
    fn unknown_colour_is_transparent_not_defaulted() {
        let html = r#"<body><div class="box"></div></body>"#;
        let css = r#"
            .box {
                width: 16px; height: 16px;
                background-color: chartreuse;
                border: 2px solid aquamarine;
            }
        "#;
        let c = render_to_canvas(html, css, 32, 32).unwrap();
        // Neither colour is in our map, so the box area stays white.
        for y in 2..30 {
            for x in 2..30 {
                assert_eq!(c.get(x, y), 15);
            }
        }
    }

    #[test]
    fn renders_multiple_stacked_blocks() {
        let html = r#"<body><div class="a"></div><div class="b"></div></body>"#;
        let css = r#"
            .a { width: 20px; height: 10px; background-color: red; margin-bottom: 2px; }
            .b { width: 20px; height: 10px; background-color: blue; }
        "#;
        let c = render_to_canvas(html, css, 32, 32).unwrap();
        // a is at top, b below it.
        let mut red_y = None;
        let mut blue_y = None;
        for y in 0..32 {
            for x in 0..32 {
                if c.get(x, y) == 4 {
                    red_y = Some(y);
                }
                if c.get(x, y) == 1 {
                    blue_y = Some(y);
                }
            }
        }
        assert!(red_y < blue_y);
    }

    #[test]
    fn draws_text_in_block_flow() {
        let html = r#"<body><p id="greet">Hello world</p></body>"#;
        let css = r#"
            body { background-color: blue; color: white; }
            #greet { background-color: red; color: white; margin: 0; }
        "#;
        let c = render_ui_to_canvas(html, css, 128, 32).unwrap();
        // The paragraph has a red background and white text.
        assert!(c.pixels().iter().any(|&p| p == 4));
    }

    #[test]
    fn approximate_colour_maps_non_palette_hex() {
        assert_eq!(nearest_color_index("#c8c8c8"), Some(7));
        assert_eq!(nearest_color_index("rgba(0, 0, 64, 0.74)"), Some(0));
        assert_eq!(color_to_index("#c8c8c8"), None);
    }

    #[test]
    fn hit_boxes_record_block_ids_and_paths() {
        let html = r#"<body><div id="a" class="box"></div><div id="b" class="box"></div></body>"#;
        let css = r#"
            .box { width: 20px; height: 10px; }
            #a { background-color: red; }
            #b { background-color: blue; }
        "#;
        let out = render_ui_to_output(html, css, 64, 64).unwrap();
        let ids: Vec<_> = out
            .hit_boxes
            .iter()
            .filter_map(|h| h.id.as_deref())
            .collect();
        assert!(ids.contains(&"a"), "missing a hit box for #a: {ids:?}");
        assert!(ids.contains(&"b"), "missing a hit box for #b: {ids:?}");
        // The second block is painted after the first; reverse search finds it.
        let top = out
            .hit_boxes
            .iter()
            .rev()
            .find(|h| h.w > 0 && h.h > 0)
            .expect("at least one painted box");
        assert!(top.id == Some("a".into()) || top.id == Some("b".into()));
    }

    #[test]
    fn hidden_and_display_none_are_excluded_from_hit_boxes() {
        let html =
            r#"<body><div id="gone" hidden></div><div id="none"></div><div id="yes"></div></body>"#;
        let css = r#"
            #none { display: none; }
            #yes { width: 10px; height: 10px; background-color: red; }
        "#;
        let out = render_ui_to_output(html, css, 32, 32).unwrap();
        let ids: Vec<_> = out
            .hit_boxes
            .iter()
            .filter_map(|h| h.id.as_deref())
            .collect();
        assert!(!ids.contains(&"gone"));
        assert!(!ids.contains(&"none"));
        assert!(ids.contains(&"yes"));
    }

    #[test]
    fn hit_boxes_support_reverse_lookup_by_coordinate() {
        let html =
            r#"<body><div id="left" class="box"></div><div id="right" class="box"></div></body>"#;
        let css = r#"
            .box { width: 20px; height: 20px; display: inline-block; }
            #left { background-color: red; }
            #right { background-color: blue; }
        "#;
        let out = render_ui_to_output(html, css, 64, 32).unwrap();
        let left = out
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("left"))
            .unwrap();
        let right = out
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("right"))
            .unwrap();
        // Reverse search: find the last (topmost) hit box containing (x,y).
        let pick = |x, y| {
            out.hit_boxes
                .iter()
                .rev()
                .find(|h| x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h)
        };
        assert_eq!(
            pick(left.x + 2, left.y + 2).and_then(|h| h.id.clone()),
            Some("left".into())
        );
        assert_eq!(
            pick(right.x + 2, right.y + 2).and_then(|h| h.id.clone()),
            Some("right".into())
        );
    }

    #[test]
    fn absolute_top_right_anchors_to_the_containing_block() {
        let html =
            r#"<body><main id="ui"><div id="badge"></div><p id="flow">text</p></main></body>"#;
        let css = r#"
            #ui { position: absolute; top: 0; left: 0; width: 200px; height: 100px; }
            #badge { position: absolute; top: 4px; right: 8px; width: 20px; height: 10px;
                     background-color: red; }
        "#;
        let out = render_ui_to_output(html, css, 256, 128).unwrap();
        let badge = out
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("badge"))
            .expect("badge hit box");
        // #ui is the containing block: 200 wide at x=0, so right:8px with a
        // 20px box puts the left edge at 200 - 8 - 20 = 172.
        assert_eq!((badge.x, badge.y), (172, 4));
        assert_eq!((badge.w, badge.h), (20, 10));
        assert_eq!(out.canvas.get(175, 6), 4, "the badge is painted red");
    }

    #[test]
    fn absolute_box_does_not_push_in_flow_content_down() {
        let base = r#"<body><div id="a"></div><p id="flow">text</p></body>"#;
        let with_abs =
            r#"<body><div id="a"></div><div id="over"></div><p id="flow">text</p></body>"#;
        let css = r#"
            #a { width: 30px; height: 10px; }
            #over { position: absolute; top: 0; left: 0; width: 30px; height: 40px; }
        "#;
        let y_of = |html: &str| {
            render_ui_to_output(html, css, 128, 128)
                .unwrap()
                .hit_boxes
                .iter()
                .find(|h| h.id.as_deref() == Some("flow"))
                .map(|h| h.y)
                .unwrap()
        };
        assert_eq!(
            y_of(base),
            y_of(with_abs),
            "an out-of-flow box must not move the flow"
        );
    }

    #[test]
    fn absolute_paints_over_in_flow_content() {
        let html = r#"<body><div id="under"></div><div id="over"></div></body>"#;
        let css = r#"
            #under { width: 40px; height: 40px; background-color: blue; }
            #over { position: absolute; top: 0; left: 0; width: 20px; height: 20px;
                    background-color: red; }
        "#;
        let out = render_ui_to_output(html, css, 64, 64).unwrap();
        // Overlap region belongs to the absolute box even though it is written
        // earlier in the flow order, because absolutes drain after the pass.
        assert_eq!(out.canvas.get(5, 5), 4, "absolute wins the overlap");
        assert_eq!(out.canvas.get(30, 30), 1, "in-flow box keeps the rest");
    }

    #[test]
    fn absolute_without_a_size_is_refused_not_guessed() {
        let html = r#"<body><div id="x"></div></body>"#;
        for css in [
            "#x { position: absolute; top: 0; right: 0; height: 10px; }",
            "#x { position: absolute; top: 0; right: 0; width: 10px; }",
        ] {
            let err = render_ui_to_output(html, css, 64, 64).unwrap_err();
            assert!(err.contains("shrink-to-fit"), "{err}");
        }
    }

    #[test]
    fn unimplemented_position_keywords_are_refused_strictly_and_surveyed_leniently() {
        for bad in ["relative", "fixed", "sticky"] {
            let css = format!("#x {{ position: {bad}; width: 4px; height: 4px; }}");
            // Strict lane: the sheet is refused, so a golden render can never
            // silently disagree with a browser.
            let err = crate::parse(&css).unwrap_err().to_string();
            assert!(err.contains(bad), "{err}");
            // Survey lane: the declaration is dropped and *reported*, because a
            // real browser stylesheet legitimately uses these for stacking.
            let (_, missing) = crate::parse_survey(&css).unwrap();
            assert!(
                missing.contains(&format!("position:{bad}")),
                "missing={missing:?}"
            );
            // Dropped, not honoured: the box stays in flow at the origin.
            let out =
                render_ui_to_output(r#"<body><div id="x"></div></body>"#, &css, 32, 32).unwrap();
            let hit = out
                .hit_boxes
                .iter()
                .find(|h| h.id.as_deref() == Some("x"))
                .unwrap();
            assert_eq!((hit.x, hit.y), (0, 0));
        }
        // `static` is the default and must keep working in both lanes.
        assert!(crate::parse("#x { position: static; width: 4px; height: 4px; }").is_ok());
        assert!(render_ui_to_output(
            r#"<body><div id="x"></div></body>"#,
            "#x { position: static; width: 4px; height: 4px; }",
            32,
            32
        )
        .is_ok());
    }

    #[test]
    fn the_real_bios_stacking_css_still_renders() {
        // App.svelte uses position:fixed/relative + z-index for the particle
        // canvas. Those must survey-drop rather than fail the UI raster.
        let css = "#bios-fx { position: fixed; inset: 0; z-index: 0; } \
                   #bios-ui { position: relative; z-index: 1; }";
        let (_, missing) = crate::parse_survey(css).unwrap();
        assert!(
            missing.contains(&"position:fixed".to_string()),
            "{missing:?}"
        );
        assert!(
            missing.contains(&"position:relative".to_string()),
            "{missing:?}"
        );
        assert!(missing.contains(&"z-index".to_string()), "{missing:?}");
        assert!(render_ui_to_output(
            r#"<body><main id="bios-ui"><p>hi</p></main></body>"#,
            css,
            64,
            64
        )
        .is_ok());
    }
}
