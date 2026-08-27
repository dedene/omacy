//! fill_grid vs ANSI oracle for the 37-effect matrix.

use omacy_engine::abi::OmacyCell;
use ttfx::effects::EffectCommand;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::terminal::TerminalConfig;
use ttfx::utils::graphics::Color;
use ttfx::utils::rng::Rng;

#[path = "sgr_decode.rs"]
mod sgr_decode;

fn wordmark() -> String {
    std::fs::read_to_string(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn asymmetric() -> String {
    std::fs::read_to_string(format!(
        "{}/../../assets/fixtures/asymmetric.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn compare_frame(name: &str, packed: &[OmacyCell], ansi: &str, cols: u32, rows: u32) {
    let oracle = sgr_decode::decode_ansi(ansi, cols, rows, [0, 0, 0]);
    assert_eq!(packed.len(), oracle.len(), "{name} length");
    for (i, (got, want)) in packed.iter().zip(oracle.iter()).enumerate() {
        assert_eq!(got.occupancy, want.occupancy, "{name} occupancy {i}");
        assert_eq!(got.glyph, want.glyph, "{name} glyph {i}");
        assert_eq!(got.flags, 0, "{name} flags {i}");
        assert_eq!(
            [got.fg_r, got.fg_g, got.fg_b, got.fg_a],
            [want.fg_r, want.fg_g, want.fg_b, want.fg_a],
            "{name} fg {i}"
        );
        assert_eq!(
            [got.bg_r, got.bg_g, got.bg_b, got.bg_a],
            [want.bg_r, want.bg_g, want.bg_b, want.bg_a],
            "{name} bg {i}"
        );
    }
}

fn run_effect(name: &str, input: &str, cols: i64, rows: i64, frames: u32) {
    let mut effect = EffectCommand::from_name(name).unwrap_or_else(|| panic!("{name}"));
    let config = TerminalConfig::gui(cols, rows, Color::from_hex("000000").unwrap());
    let mut ctx =
        EngineCtx::new(input, config, Rng::seeded(1), Clock::virtual_with_frame_rate(60))
            .expect("ctx");
    ctx.suppress_ansi = false;
    effect.build(&mut ctx).expect("build");
    let mut packed = vec![OmacyCell::default(); (cols * rows) as usize];
    let mut last_ansi = String::new();
    for _ in 0..frames {
        match effect.next_frame(&mut ctx) {
            Some(ansi) => {
                ctx.terminal.fill_grid(&mut packed, [0, 0, 0]);
                compare_frame(name, &packed, &ansi, cols as u32, rows as u32);
                last_ansi = ansi;
            }
            None => {
                if !last_ansi.is_empty() {
                    ctx.terminal.fill_grid(&mut packed, [0, 0, 0]);
                    compare_frame(name, &packed, &last_ansi, cols as u32, rows as u32);
                }
                return;
            }
        }
    }
}

#[test]
fn fill_grid_matches_oracle_for_all_effects() {
    let inputs = [wordmark(), asymmetric()];
    let canvases = [(80, 24), (160, 48)];
    for name in EffectCommand::NAMES {
        for input in &inputs {
            for &(cols, rows) in &canvases {
                run_effect(name, input, cols, rows, 180);
            }
        }
    }
}
