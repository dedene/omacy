use std::io::Cursor;

use image::{DynamicImage, GenericImageView, ImageFormat, RgbaImage};
use resvg::{tiny_skia, usvg};

use crate::abi::{OmacyAsciiConfig, OMACY_ASCII_BLOCK, OMACY_ASCII_BRAILLE};
use crate::limits;
use crate::status::EngineError;

pub fn validate_ascii_config(cfg: OmacyAsciiConfig) -> Result<OmacyAsciiConfig, EngineError> {
    if cfg.mode != OMACY_ASCII_BRAILLE && cfg.mode != OMACY_ASCII_BLOCK {
        return Err(EngineError::InvalidArg("ascii mode must be braille or block".into()));
    }
    if cfg.width < 1 || cfg.width > limits::CONV_COLUMNS {
        return Err(EngineError::Limit("conversion width out of range".into()));
    }
    if cfg.height < 1 || cfg.height > limits::CONV_ROWS {
        return Err(EngineError::Limit("conversion height out of range".into()));
    }
    let cells = cfg
        .width
        .checked_mul(cfg.height)
        .ok_or_else(|| EngineError::Limit("conversion cell count overflow".into()))?;
    if cells > limits::CONV_CELLS {
        return Err(EngineError::Limit("conversion cell count exceeds cap".into()));
    }
    if cfg.threshold > 100 {
        return Err(EngineError::InvalidArg("threshold must be 0..=100".into()));
    }
    if cfg.invert > 1 || cfg.trim > 1 {
        return Err(EngineError::InvalidArg("invert and trim must be 0 or 1".into()));
    }
    Ok(cfg)
}

pub fn ascii_from_bytes(cfg: OmacyAsciiConfig, bytes: &[u8]) -> Result<String, EngineError> {
    let cfg = validate_ascii_config(cfg)?;
    if bytes.len() > limits::PNG_BYTES && looks_like_png(bytes) {
        return Err(EngineError::Limit("PNG exceeds 8 MiB".into()));
    }
    if !looks_like_png(bytes) && bytes.len() > limits::SVG_BYTES {
        return Err(EngineError::Limit("SVG exceeds 2 MiB".into()));
    }
    let image = if looks_like_png(bytes) {
        decode_png(bytes)?
    } else {
        decode_svg(bytes)?
    };
    raster_to_text(&image, cfg)
}

fn looks_like_png(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
}

fn decode_png(bytes: &[u8]) -> Result<RgbaImage, EngineError> {
    if bytes.len() > limits::PNG_BYTES {
        return Err(EngineError::Limit("PNG exceeds 8 MiB".into()));
    }
    let img = image::load(Cursor::new(bytes), ImageFormat::Png)
        .map_err(|e| EngineError::Engine(e.to_string()))?;
    let (w, h) = img.dimensions();
    let pixels = w
        .checked_mul(h)
        .ok_or_else(|| EngineError::Limit("decoded pixel overflow".into()))?;
    if pixels > limits::DECODED_PIXELS {
        return Err(EngineError::Limit("decoded pixels exceed cap".into()));
    }
    Ok(img.to_rgba8())
}

fn decode_svg(bytes: &[u8]) -> Result<RgbaImage, EngineError> {
    if bytes.len() > limits::SVG_BYTES {
        return Err(EngineError::Limit("SVG exceeds 2 MiB".into()));
    }
    let mut options = usvg::Options {
        resources_dir: None,
        ..usvg::Options::default()
    };
    options.fontdb_mut().set_serif_family("");
    options.fontdb_mut().set_sans_serif_family("");
    options.fontdb_mut().set_cursive_family("");
    options.fontdb_mut().set_fantasy_family("");
    options.fontdb_mut().set_monospace_family("");
    let tree = usvg::Tree::from_data(bytes, &options)
        .map_err(|e| EngineError::Engine(e.to_string()))?;
    if count_svg_nodes(&tree.root()) > limits::SVG_ELEMENTS {
        return Err(EngineError::Limit("SVG element count exceeds cap".into()));
    }
    let size = tree.size();
    let width = size.width().ceil().max(1.0) as u32;
    let height = size.height().ceil().max(1.0) as u32;
    let pixels = width
        .checked_mul(height)
        .ok_or_else(|| EngineError::Limit("decoded pixel overflow".into()))?;
    if pixels > limits::DECODED_PIXELS {
        return Err(EngineError::Limit("decoded pixels exceed cap".into()));
    }
    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| EngineError::Engine("failed to allocate SVG pixmap".into()))?;
    resvg::render(&tree, tiny_skia::Transform::default(), &mut pixmap.as_mut());
    let mut img = RgbaImage::new(width, height);
    for (i, px) in pixmap.pixels().iter().enumerate() {
        let x = (i as u32) % width;
        let y = (i as u32) / width;
        let rgba = px.demultiply();
        img.put_pixel(x, y, image::Rgba([rgba.red(), rgba.green(), rgba.blue(), rgba.alpha()]));
    }
    Ok(img)
}

fn count_svg_nodes(root: &usvg::Group) -> u32 {
    let mut n = 1u32;
    for child in root.children() {
        n = n.saturating_add(1);
        if let usvg::Node::Group(g) = child {
            n = n.saturating_add(count_svg_nodes(g).saturating_sub(1));
        }
    }
    n
}

fn raster_to_text(img: &RgbaImage, cfg: OmacyAsciiConfig) -> Result<String, EngineError> {
    let (pixel_w, pixel_h) = if cfg.mode == OMACY_ASCII_BRAILLE {
        (cfg.width.saturating_mul(2), cfg.height.saturating_mul(4))
    } else {
        (cfg.width, cfg.height.saturating_mul(2))
    };

    let mut luma = to_luma(img, cfg.invert != 0);
    if cfg.trim != 0 {
        luma = trim_black(&add_black_border(&luma, 1));
    }
    let resized = resize_nearest_then_lanczos(&luma, pixel_w.max(1), pixel_h.max(1));
    let threshold = (cfg.threshold as f32 / 100.0 * 255.0).round() as u8;
    let bits = threshold_bits(&resized, threshold);
    let packed = if cfg.mode == OMACY_ASCII_BRAILLE {
        pack_braille(&bits)
    } else {
        pack_block(&bits)
    };
    Ok(trim_output_lines(&packed))
}

fn to_luma(img: &RgbaImage, invert: bool) -> image::GrayImage {
    let (w, h) = img.dimensions();
    let mut min_a = 255u8;
    let mut max_a = 0u8;
    for p in img.pixels() {
        min_a = min_a.min(p.0[3]);
        max_a = max_a.max(p.0[3]);
    }
    let use_alpha = (min_a as f32 / 255.0) < 0.999 && max_a > min_a;
    let mut out = image::GrayImage::new(w, h);
    for (x, y, p) in img.enumerate_pixels() {
        let v = if use_alpha {
            p.0[3]
        } else {
            let a = p.0[3] as u16;
            let r = p.0[0] as u16;
            let g = p.0[1] as u16;
            let b = p.0[2] as u16;
            let gray = (r * 30 + g * 59 + b * 11) / 100;
            ((gray * a) / 255) as u8
        };
        let mut v = v;
        if use_alpha {
            if invert {
                v = 255 - v;
            }
        } else if !invert {
            v = 255 - v;
        }
        out.put_pixel(x, y, image::Luma([v]));
    }
    out
}

fn trim_black(img: &image::GrayImage) -> image::GrayImage {
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 {
        return img.clone();
    }
    let mut min_x = w;
    let mut min_y = h;
    let mut max_x = 0u32;
    let mut max_y = 0u32;
    for (x, y, p) in img.enumerate_pixels() {
        if p.0[0] > 0 {
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
        }
    }
    if min_x > max_x {
        return image::GrayImage::new(1, 1);
    }
    DynamicImage::ImageLuma8(img.clone())
        .crop_imm(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
        .to_luma8()
}

fn resize_nearest_then_lanczos(img: &image::GrayImage, w: u32, h: u32) -> image::GrayImage {
    if img.width() == w && img.height() == h {
        return img.clone();
    }
    DynamicImage::ImageLuma8(img.clone())
        .resize(w, h, image::imageops::FilterType::Lanczos3)
        .to_luma8()
}

fn add_black_border(img: &image::GrayImage, px: u32) -> image::GrayImage {
    let w = img.width() + px * 2;
    let h = img.height() + px * 2;
    let mut out = image::GrayImage::from_pixel(w, h, image::Luma([0]));
    for (x, y, p) in img.enumerate_pixels() {
        out.put_pixel(x + px, y + px, *p);
    }
    out
}

fn threshold_bits(img: &image::GrayImage, threshold: u8) -> image::GrayImage {
    let mut out = img.clone();
    for p in out.pixels_mut() {
        // magick -threshold then -negate then PBM (black=1) is: above threshold → on.
        p.0[0] = if p.0[0] > threshold { 255 } else { 0 };
    }
    out
}

fn pack_braille(img: &image::GrayImage) -> String {
    let w = img.width();
    let h = img.height();
    let mut lines = Vec::new();
    let mut y = 0;
    while y < h {
        let mut line = String::new();
        let mut x = 0;
        while x < w {
            let mut code = 0u32;
            const DOTS: [[u32; 4]; 2] = [[1, 2, 4, 64], [8, 16, 32, 128]];
            for dx in 0..2 {
                for dy in 0..4 {
                    if y + dy < h && x + dx < w && img.get_pixel(x + dx, y + dy).0[0] > 0 {
                        code += DOTS[dx as usize][dy as usize];
                    }
                }
            }
            if code == 0 {
                line.push(' ');
            } else {
                line.push(char::from_u32(0x2800 + code).unwrap_or(' '));
            }
            x += 2;
        }
        lines.push(line);
        y += 4;
    }
    lines.join("\n")
}

fn pack_block(img: &image::GrayImage) -> String {
    let w = img.width();
    let h = img.height();
    let mut lines = Vec::new();
    let mut y = 0;
    while y < h {
        let mut line = String::new();
        for x in 0..w {
            let top = y < h && img.get_pixel(x, y).0[0] > 0;
            let bot = y + 1 < h && img.get_pixel(x, y + 1).0[0] > 0;
            line.push(match (top, bot) {
                (true, true) => '█',
                (true, false) => '▀',
                (false, true) => '▄',
                (false, false) => ' ',
            });
        }
        lines.push(line);
        y += 2;
    }
    lines.join("\n")
}

fn trim_output_lines(text: &str) -> String {
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| l.trim_end().to_string())
        .collect();
    while lines.first().is_some_and(|l| l.is_empty()) {
        lines.remove(0);
    }
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    if lines.is_empty() {
        "No logo pixels found".into()
    } else {
        lines.join("\n")
    }
}
