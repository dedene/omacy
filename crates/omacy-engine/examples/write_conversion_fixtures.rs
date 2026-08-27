//! Generate committed conversion goldens. Run from repo root:
//! `cargo run -p omacy-engine --example write_conversion_fixtures`

use omacy_engine::abi::{OmacyAsciiConfig, OMACY_ASCII_BLOCK, OMACY_ASCII_BRAILLE};
use omacy_engine::ascii::ascii_from_bytes;
use std::fs;
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn solid_png(w: u32, h: u32, bg: [u8; 4], fg: [u8; 4]) -> Vec<u8> {
    let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba(bg));
    for y in h / 4..h * 3 / 4 {
        for x in w / 4..w * 3 / 4 {
            img.put_pixel(x, y, image::Rgba(fg));
        }
    }
    let mut buf = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
        .unwrap();
    buf
}

fn alpha_png(w: u32, h: u32) -> Vec<u8> {
    let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba([0, 0, 0, 0]));
    for y in h / 4..h * 3 / 4 {
        for x in w / 4..w * 3 / 4 {
            img.put_pixel(x, y, image::Rgba([255, 255, 255, 255]));
        }
    }
    let mut buf = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
        .unwrap();
    buf
}

fn cfg(mode: u32, width: u32, height: u32, threshold: u8, invert: u8, trim: u8) -> OmacyAsciiConfig {
    OmacyAsciiConfig {
        mode,
        width,
        height,
        threshold,
        invert,
        trim,
        _pad: 0,
    }
}

fn write_pair(dir: &std::path::Path, stem: &str, bytes: &[u8], c: OmacyAsciiConfig, label: &str) {
    let text = ascii_from_bytes(c, bytes).expect(label);
    fs::write(dir.join(format!("{stem}.{label}.txt")), text).unwrap();
}

fn main() {
    let dir = repo_root().join("assets/fixtures/conversion");
    fs::create_dir_all(&dir).unwrap();

    let opaque = solid_png(32, 32, [255, 255, 255, 255], [0, 0, 0, 255]);
    fs::write(dir.join("solid-black-on-white.png"), &opaque).unwrap();

    let alpha = alpha_png(32, 32);
    fs::write(dir.join("alpha-logo.png"), &alpha).unwrap();

    let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
  <rect x="8" y="8" width="16" height="16" fill="black"/>
</svg>"#;
    fs::write(dir.join("logo.svg"), svg).unwrap();

    write_pair(
        &dir,
        "solid-black-on-white",
        &opaque,
        cfg(OMACY_ASCII_BRAILLE, 8, 4, 50, 0, 1),
        "braille.t50.inv0.trim1",
    );
    write_pair(
        &dir,
        "solid-black-on-white",
        &opaque,
        cfg(OMACY_ASCII_BLOCK, 8, 4, 50, 0, 1),
        "block.t50.inv0.trim1",
    );
    write_pair(
        &dir,
        "solid-black-on-white",
        &opaque,
        cfg(OMACY_ASCII_BRAILLE, 8, 4, 50, 1, 1),
        "braille.t50.inv1.trim1",
    );
    write_pair(
        &dir,
        "solid-black-on-white",
        &opaque,
        cfg(OMACY_ASCII_BLOCK, 16, 8, 80, 0, 0),
        "block.t80.inv0.trim0",
    );
    write_pair(
        &dir,
        "alpha-logo",
        &alpha,
        cfg(OMACY_ASCII_BRAILLE, 8, 4, 50, 0, 1),
        "braille.t50.inv0.trim1",
    );
    write_pair(
        &dir,
        "logo.svg",
        svg.as_bytes(),
        cfg(OMACY_ASCII_BRAILLE, 8, 4, 50, 0, 1),
        "braille.t50.inv0.trim1",
    );

    println!("wrote {}", dir.display());
}
