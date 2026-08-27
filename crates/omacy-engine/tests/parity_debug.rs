//! Regression: effects that restore coordinates after ctx.frame() (unstable rumble)
//! must still publish the displayed grid.

use omacy_engine::abi::OmacyCell;
use ttfx::effects::EffectCommand;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::terminal::TerminalConfig;
use ttfx::utils::graphics::Color;
use ttfx::utils::rng::Rng;

#[path = "sgr_decode.rs"]
mod sgr_decode;

fn run(name: &str, input: &str, cols: i64, rows: i64, frames: u32) {
    let mut effect = EffectCommand::from_name(name).unwrap();
    let config = TerminalConfig::gui(cols, rows, Color::from_hex("000000").unwrap());
    let mut ctx =
        EngineCtx::new(input, config, Rng::seeded(1), Clock::virtual_with_frame_rate(60)).unwrap();
    effect.build(&mut ctx).unwrap();
    let mut packed = vec![OmacyCell::default(); (cols * rows) as usize];
    for frame in 0..frames {
        let Some(ansi) = effect.next_frame(&mut ctx) else {
            break;
        };
        ctx.terminal.fill_grid(&mut packed, [0, 0, 0]);
        let oracle = sgr_decode::decode_ansi(&ansi, cols as u32, rows as u32, [0, 0, 0]);
        for (i, (got, want)) in packed.iter().zip(oracle.iter()).enumerate() {
            assert_eq!(
                (got.occupancy, got.glyph, got.fg_r, got.bg_r),
                (want.occupancy, want.glyph, want.fg_r, want.bg_r),
                "{name} frame={frame} cell={i} row={} col={}",
                i / cols as usize,
                i % cols as usize
            );
        }
    }
}

#[test]
fn unstable_rumble_fill_grid_matches_ansi() {
    let input = std::fs::read_to_string(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap();
    run("unstable", &input, 80, 24, 180);
}
