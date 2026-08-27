#[path = "sgr_decode.rs"]
mod sgr_decode;

use omacy_engine::abi::OmacyCell;
use sgr_decode::{decode_ansi, occupancy};

fn fixture(name: &str) -> String {
    let path = format!(
        "{}/../../assets/fixtures/ansi-oracle/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    String::from_utf8(std::fs::read(path).expect("fixture")).expect("utf8")
}

fn cell_at(cells: &[OmacyCell], cols: u32, row: u32, col: u32) -> OmacyCell {
    cells[(row * cols + col) as usize]
}

#[test]
fn origin_asymmetric() {
    let cells = decode_ansi(&fixture("origin-asymmetric.ans"), 2, 2, [0, 0, 0]);
    let tr = cell_at(&cells, 2, 0, 1);
    let bl = cell_at(&cells, 2, 1, 0);
    let tl = cell_at(&cells, 2, 0, 0);
    let br = cell_at(&cells, 2, 1, 1);
    assert_eq!(occupancy(&tl), (false, false));
    assert_eq!(occupancy(&br), (false, false));
    assert_eq!(occupancy(&tr), (false, true));
    assert_eq!(tr.glyph, u32::from('X'));
    assert_eq!(occupancy(&bl), (true, false));
    assert_ne!([bl.bg_r, bl.bg_g, bl.bg_b], [0, 0, 0]);
    assert_eq!(tr.flags, 0);
    assert_eq!(bl.flags, 0);
}

#[test]
fn occupancy_four() {
    let cells = decode_ansi(&fixture("occupancy-four.ans"), 2, 2, [0, 0, 0]);
    assert_eq!(occupancy(&cell_at(&cells, 2, 0, 0)), (false, false));
    assert_eq!(occupancy(&cell_at(&cells, 2, 0, 1)), (false, true));
    assert_eq!(occupancy(&cell_at(&cells, 2, 1, 0)), (true, false));
    assert_eq!(occupancy(&cell_at(&cells, 2, 1, 1)), (true, true));
    assert_eq!(cell_at(&cells, 2, 0, 1).glyph, u32::from('A'));
    assert_eq!(cell_at(&cells, 2, 1, 1).glyph, u32::from('B'));
}

#[test]
fn sgr_reset_and_reverse() {
    let reset = decode_ansi(&fixture("sgr-reset.ans"), 2, 1, [0, 0, 0]);
    assert_eq!(occupancy(&reset[0]), (false, true));
    assert_eq!(reset[0].glyph, u32::from('A'));
    assert_eq!(occupancy(&reset[1]), (false, true));
    assert_eq!(reset[1].glyph, u32::from('B'));
    assert_eq!(reset[0].flags, 0);

    let rev = decode_ansi(&fixture("sgr-reverse.ans"), 3, 1, [0, 0, 0]);
    assert_eq!(occupancy(&rev[0]), (false, true));
    assert_eq!(occupancy(&rev[1]), (true, true));
    assert_eq!(occupancy(&rev[2]), (false, true));
    assert_eq!(rev[1].bg_r, rev[0].fg_r);
    assert_eq!([rev[1].fg_r, rev[1].fg_g, rev[1].fg_b], [0, 0, 0]);
}

#[test]
fn sgr_truecolor_and_xterm() {
    let tc = decode_ansi(&fixture("sgr-truecolor.ans"), 1, 1, [0, 0, 0]);
    assert_eq!([tc[0].fg_r, tc[0].fg_g, tc[0].fg_b], [255, 128, 0]);
    assert_eq!([tc[0].bg_r, tc[0].bg_g, tc[0].bg_b], [0, 0, 64]);
    assert_eq!(occupancy(&tc[0]), (true, true));

    let x = decode_ansi(&fixture("sgr-xterm256.ans"), 1, 1, [0, 0, 0]);
    assert_eq!(occupancy(&x[0]), (true, true));
    assert_eq!(x[0].glyph, u32::from('X'));
}

#[test]
fn sgr_style_does_not_set_flags() {
    let cells = decode_ansi(&fixture("sgr-style-ignored.ans"), 2, 1, [0, 0, 0]);
    assert_eq!(cells[0].flags, 0);
    assert_eq!(cells[1].flags, 0);
    assert_eq!(cells[0].glyph, u32::from('X'));
    assert_eq!(cells[1].glyph, u32::from('Y'));
}

#[test]
fn sgr_ansi16_lengths() {
    let fg = decode_ansi(&fixture("sgr-ansi16-fg.ans"), 16, 1, [0, 0, 0]);
    assert_eq!(fg[0].glyph, u32::from('A'));
    assert_eq!(fg[15].glyph, u32::from('P'));
    assert!(fg.iter().all(|c| occupancy(c) == (false, true) && c.flags == 0));

    let bg = decode_ansi(&fixture("sgr-ansi16-bg.ans"), 16, 1, [0, 0, 0]);
    assert!(bg.iter().all(|c| occupancy(c) == (true, false) && c.flags == 0));
}
