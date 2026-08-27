//! Identity vs committed conversion goldens.

use omacy_engine::abi::{OmacyAsciiConfig, OMACY_ASCII_BLOCK, OMACY_ASCII_BRAILLE};
use omacy_engine::ascii::ascii_from_bytes;

struct Case {
    input: &'static str,
    mode: u32,
    width: u32,
    height: u32,
    threshold: u8,
    invert: u8,
    trim: u8,
    expected: &'static str,
}

fn load(name: &str) -> Vec<u8> {
    std::fs::read(format!(
        "{}/../../assets/fixtures/conversion/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[test]
fn conversion_matches_committed_fixtures() {
    let cases = [
        Case {
            input: "solid-black-on-white.png",
            mode: OMACY_ASCII_BRAILLE,
            width: 8,
            height: 4,
            threshold: 50,
            invert: 0,
            trim: 1,
            expected: "solid-black-on-white.braille.t50.inv0.trim1.txt",
        },
        Case {
            input: "solid-black-on-white.png",
            mode: OMACY_ASCII_BLOCK,
            width: 8,
            height: 4,
            threshold: 50,
            invert: 0,
            trim: 1,
            expected: "solid-black-on-white.block.t50.inv0.trim1.txt",
        },
        Case {
            input: "solid-black-on-white.png",
            mode: OMACY_ASCII_BRAILLE,
            width: 8,
            height: 4,
            threshold: 50,
            invert: 1,
            trim: 1,
            expected: "solid-black-on-white.braille.t50.inv1.trim1.txt",
        },
        Case {
            input: "solid-black-on-white.png",
            mode: OMACY_ASCII_BLOCK,
            width: 16,
            height: 8,
            threshold: 80,
            invert: 0,
            trim: 0,
            expected: "solid-black-on-white.block.t80.inv0.trim0.txt",
        },
        Case {
            input: "alpha-logo.png",
            mode: OMACY_ASCII_BRAILLE,
            width: 8,
            height: 4,
            threshold: 50,
            invert: 0,
            trim: 1,
            expected: "alpha-logo.braille.t50.inv0.trim1.txt",
        },
        Case {
            input: "logo.svg",
            mode: OMACY_ASCII_BRAILLE,
            width: 8,
            height: 4,
            threshold: 50,
            invert: 0,
            trim: 1,
            expected: "logo.svg.braille.t50.inv0.trim1.txt",
        },
    ];
    for case in cases {
        let cfg = OmacyAsciiConfig {
            mode: case.mode,
            width: case.width,
            height: case.height,
            threshold: case.threshold,
            invert: case.invert,
            trim: case.trim,
            _pad: 0,
        };
        let got = ascii_from_bytes(cfg, &load(case.input)).expect(case.expected);
        let want = String::from_utf8(load(case.expected)).unwrap();
        assert_eq!(got, want, "{}", case.expected);
    }
}
