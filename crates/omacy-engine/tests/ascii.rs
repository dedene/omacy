use crate::abi::{OmacyAsciiConfig, OMACY_ASCII_BLOCK, OMACY_ASCII_BRAILLE};
use crate::ascii::ascii_from_bytes;

fn solid_png(w: u32, h: u32, rgba: [u8; 4]) -> Vec<u8> {
    let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba(rgba));
    // stamp an opaque black logo block in the middle so both modes emit glyphs
    for y in h / 4..h * 3 / 4 {
        for x in w / 4..w * 3 / 4 {
            img.put_pixel(x, y, image::Rgba([0, 0, 0, 255]));
        }
    }
    let mut buf = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
        .unwrap();
    buf
}

#[test]
fn png_braille_emits_cells() {
    let png = solid_png(16, 16, [255, 255, 255, 255]);
    let cfg = OmacyAsciiConfig {
        mode: OMACY_ASCII_BRAILLE,
        width: 8,
        height: 4,
        threshold: 50,
        invert: 0,
        trim: 1,
        _pad: 0,
    };
    let text = ascii_from_bytes(cfg, &png).expect("convert");
    assert!(!text.is_empty());
    assert_ne!(text, "No logo pixels found");
}

#[test]
fn png_block_emits_cells() {
    let png = solid_png(16, 16, [255, 255, 255, 255]);
    let cfg = OmacyAsciiConfig {
        mode: OMACY_ASCII_BLOCK,
        width: 8,
        height: 4,
        threshold: 50,
        invert: 0,
        trim: 1,
        _pad: 0,
    };
    let text = ascii_from_bytes(cfg, &png).expect("convert");
    assert!(text.chars().any(|c| c == '█' || c == '▀' || c == '▄'));
}

#[test]
fn oversized_svg_is_limit() {
    let huge = vec![b'x'; 2 * 1024 * 1024 + 1];
    let cfg = OmacyAsciiConfig {
        mode: OMACY_ASCII_BRAILLE,
        width: 8,
        height: 4,
        threshold: 50,
        invert: 0,
        trim: 1,
        _pad: 0,
    };
    match ascii_from_bytes(cfg, &huge) {
        Err(crate::status::EngineError::Limit(_)) => {}
        other => panic!("expected limit, got {other:?}"),
    }
}

#[test]
fn svg_file_href_is_ignored() {
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
  <rect width="16" height="16" fill="black"/>
  <image href="file:///etc/passwd" width="16" height="16"/>
</svg>"#;
    let cfg = OmacyAsciiConfig {
        mode: OMACY_ASCII_BLOCK,
        width: 8,
        height: 4,
        threshold: 50,
        invert: 0,
        trim: 1,
        _pad: 0,
    };
    let text = ascii_from_bytes(cfg, svg).expect("svg with file href must not load the file");
    assert!(!text.is_empty());
}
