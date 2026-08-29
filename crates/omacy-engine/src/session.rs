use ttfx::effects::EffectCommand;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::terminal::{PackedCell, TerminalConfig};
use ttfx::utils::graphics::Color;
use ttfx::utils::rng::Rng;

use crate::abi::OmacyFrame;
use crate::content::{parse_utf8, pick_effect_name, validate_art, validate_pool, Content};
use crate::limits::{self, check_geometry};
use crate::status::EngineError;

#[derive(Clone, Copy, Debug)]
pub enum ClockKind {
    Real,
    #[cfg(test)]
    Virtual60,
}

enum LiveState {
    Running {
        effect: Box<dyn Effect>,
        ctx: EngineCtx,
    },
    Waiting,
    Dead,
}

pub struct Session {
    state: LiveState,
    selected: Content,
    selected_next: Content,
    cols: u32,
    rows: u32,
    cache: Vec<PackedCell>,
    clear: [u8; 4],
    accumulator: f64,
    generation: u64,
    pick_rng: Rng,
    seed: Option<u64>,
    clock_kind: ClockKind,
    stepping: bool,
    last_error: String,
}

#[derive(Clone, Copy, Debug)]
pub struct StepPublish {
    pub frame: OmacyFrame,
    pub waiting: bool,
    pub steps_taken: u8,
}

impl Session {
    pub fn create(
        art: String,
        effect: String,
        pool: Vec<String>,
        bg: [u8; 4],
        seed: Option<u64>,
        cols: u32,
        rows: u32,
        clock_kind: ClockKind,
    ) -> Result<Self, EngineError> {
        let (cols, rows) = check_geometry(cols, rows)?;
        let selected = Content::from_parts(art, effect, pool, bg)?;
        let pick_rng = match seed {
            Some(s) => Rng::seeded(s),
            None => Rng::from_entropy(),
        };
        let clear = bg_or_opaque(selected.bg);
        let mut session = Session {
            state: LiveState::Dead,
            selected: selected.clone(),
            selected_next: selected,
            cols,
            rows,
            cache: vec![PackedCell::default(); (cols * rows) as usize],
            clear,
            accumulator: 0.0,
            generation: 0,
            pick_rng,
            seed,
            clock_kind,
            stepping: false,
            last_error: String::new(),
        };
        session.install_effect()?;
        Ok(session)
    }

    fn install_effect(&mut self) -> Result<(), EngineError> {
        let (effect, ctx) = construct_effect(
            &self.selected_next,
            self.cols,
            self.rows,
            self.seed,
            self.generation,
            &mut self.pick_rng,
            self.clock_kind,
        )?;
        self.selected = self.selected_next.clone();
        self.clear = bg_or_opaque(self.selected.bg);
        self.cache
            .resize((self.cols * self.rows) as usize, PackedCell::default());
        self.accumulator = 0.0;
        self.state = LiveState::Running { effect, ctx };
        Ok(())
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn error_message(&self) -> &str {
        &self.last_error
    }

    pub fn set_last_error(&mut self, msg: String) {
        self.last_error = msg;
    }

    pub fn is_dead(&self) -> bool {
        matches!(self.state, LiveState::Dead)
    }

    #[cfg(test)]
    pub fn is_waiting(&self) -> bool {
        matches!(self.state, LiveState::Waiting)
    }

    #[cfg(test)]
    pub fn force_reentrant_step(&mut self) -> Result<StepPublish, EngineError> {
        self.stepping = true;
        let result = self.step(1.0 / 60.0);
        self.stepping = false;
        result
    }

    pub fn mark_dead(&mut self, message: String) {
        self.state = LiveState::Dead;
        self.last_error = message;
        self.cache.clear();
    }

    /// Builds a complete next generation before changing any published state.
    /// On error, content, geometry, frame storage, clear color and generation
    /// remain untouched.
    pub fn begin_next_with_config(
        &mut self,
        art: String,
        pool: Vec<String>,
        cols: u32,
        rows: u32,
    ) -> Result<(), EngineError> {
        self.begin_next_with_config_using(art, pool, cols, rows, construct_effect)
    }

    fn begin_next_with_config_using<F>(
        &mut self,
        art: String,
        pool: Vec<String>,
        cols: u32,
        rows: u32,
        build: F,
    ) -> Result<(), EngineError>
    where
        F: FnOnce(
            &Content,
            u32,
            u32,
            Option<u64>,
            u64,
            &mut Rng,
            ClockKind,
        ) -> Result<(Box<dyn Effect>, EngineCtx), EngineError>,
    {
        if !matches!(self.state, LiveState::Waiting) {
            return Err(EngineError::InvalidArg(
                "begin_next_with_config is only legal while waiting".into(),
            ));
        }
        let (cols, rows) = check_geometry(cols, rows)?;
        validate_art(&art)?;
        if art.is_empty() {
            return Err(EngineError::InvalidArg("ASCII art is empty".into()));
        }
        validate_pool(&pool)?;

        let candidate = Content {
            art,
            effect: "random".into(),
            bg: self.selected.bg,
            pool,
        };
        let next_generation = self.generation.saturating_add(1);
        // Candidate selection advances a transactional copy. Failure leaves
        // the live stream untouched; success promotes the advanced stream.
        let mut candidate_picker = self.pick_rng.clone();
        let (effect, ctx) = build(
            &candidate,
            cols,
            rows,
            self.seed,
            next_generation,
            &mut candidate_picker,
            self.clock_kind,
        )?;
        let cache = vec![PackedCell::default(); (cols * rows) as usize];
        let clear = bg_or_opaque(candidate.bg);

        self.state = LiveState::Running { effect, ctx };
        self.selected = candidate.clone();
        self.selected_next = candidate;
        self.cols = cols;
        self.rows = rows;
        self.cache = cache;
        self.clear = clear;
        self.accumulator = 0.0;
        self.generation = next_generation;
        self.pick_rng = candidate_picker;
        Ok(())
    }

    #[cfg(test)]
    pub fn selected_effect_pool(&self) -> &[String] {
        &self.selected.pool
    }

    pub fn step(&mut self, elapsed: f64) -> Result<StepPublish, EngineError> {
        if self.stepping {
            return Err(EngineError::InvalidArg("re-entrant step".into()));
        }
        if !elapsed.is_finite() || elapsed < 0.0 {
            return Err(EngineError::InvalidArg(
                "elapsed must be finite and non-negative".into(),
            ));
        }
        self.require_live()?;
        self.stepping = true;
        let inner = self.step_inner(elapsed);
        self.stepping = false;
        let (waiting, steps_taken) = inner?;
        Ok(StepPublish {
            frame: self.published_c_frame(),
            waiting,
            steps_taken,
        })
    }

    fn step_inner(&mut self, elapsed: f64) -> Result<(bool, u8), EngineError> {
        if matches!(self.state, LiveState::Waiting) {
            return Ok((true, 0));
        }
        if matches!(self.state, LiveState::Dead) {
            return Err(EngineError::Dead);
        }

        self.accumulator += elapsed;
        let mut steps = 0u32;
        let mut ended = false;
        while self.accumulator >= limits::STEP_DT && steps < limits::MAX_STEPS_PER_CALL {
            let going = match &mut self.state {
                LiveState::Running { effect, ctx } => effect.advance(ctx),
                _ => false,
            };
            if !going {
                ended = true;
                break;
            }
            self.accumulator -= limits::STEP_DT;
            steps += 1;
        }
        if steps == limits::MAX_STEPS_PER_CALL {
            self.accumulator = 0.0;
        }

        if steps > 0 || ended {
            self.fill_cache()?;
        }

        // Ending still paints the last frame even if the finishing advance
        // returned false before incrementing `steps`. Report that as a change.
        let steps_taken = if ended {
            steps.max(1) as u8
        } else {
            steps as u8
        };

        if ended {
            self.accumulator = 0.0;
            self.selected_next = self.selected.clone();
            self.state = LiveState::Waiting;
            return Ok((true, steps_taken));
        }

        Ok((false, steps_taken))
    }

    fn fill_cache(&mut self) -> Result<(), EngineError> {
        let term_bg = [self.clear[0], self.clear[1], self.clear[2]];
        match &mut self.state {
            LiveState::Running { ctx, .. } => {
                let needed = (self.cols as usize)
                    .checked_mul(self.rows as usize)
                    .ok_or_else(|| EngineError::Limit("grid overflow".into()))?;
                if self.cache.len() != needed {
                    self.cache.resize(needed, PackedCell::default());
                }
                ctx.terminal.fill_grid(&mut self.cache, term_bg);
                Ok(())
            }
            LiveState::Waiting => Ok(()),
            LiveState::Dead => Err(EngineError::Dead),
        }
    }

    fn require_live(&self) -> Result<(), EngineError> {
        match self.state {
            LiveState::Dead => Err(EngineError::Dead),
            _ => Ok(()),
        }
    }

    pub fn published_c_frame(&self) -> OmacyFrame {
        let cells = if self.cache.is_empty() || matches!(self.state, LiveState::Dead) {
            std::ptr::null()
        } else {
            self.cache.as_ptr()
        };
        OmacyFrame {
            cols: self.cols,
            rows: self.rows,
            clear_r: self.clear[0],
            clear_g: self.clear[1],
            clear_b: self.clear[2],
            clear_a: self.clear[3],
            _pad: 0,
            cells,
        }
    }
}

#[cfg(test)]
mod atomic_tests {
    use super::*;

    fn build_after_recording_selection(
        content: &Content,
        cols: u32,
        rows: u32,
        seed: Option<u64>,
        generation: u64,
        picker: &mut Rng,
        clock_kind: ClockKind,
        selected: &mut Option<String>,
    ) -> Result<(Box<dyn Effect>, EngineCtx), EngineError> {
        let name = pick_effect_name(&content.effect, &content.pool, picker).to_string();
        *selected = Some(name.clone());
        let mut pinned = content.clone();
        pinned.effect = name;
        construct_effect(&pinned, cols, rows, seed, generation, picker, clock_kind)
    }

    fn waiting_seeded_session() -> Session {
        let art = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../assets/branding/screensaver.txt"
        ))
        .unwrap();
        let mut session = Session::create(
            art,
            "wipe".into(),
            Vec::new(),
            [1, 2, 3, 255],
            Some(1),
            20,
            8,
            ClockKind::Virtual60,
        )
        .unwrap();
        for _ in 0..20_000 {
            if session.step(1.0 / 60.0).unwrap().waiting {
                break;
            }
        }
        assert!(session.is_waiting());
        session
    }

    #[test]
    fn construction_error_does_not_promote_candidate() {
        let mut session = waiting_seeded_session();
        let mut control = waiting_seeded_session();
        let before = session.published_c_frame();
        let selected_before = session.selected.clone();
        let selected_next_before = session.selected_next.clone();
        let accumulator_before = session.accumulator;
        let stepping_before = session.stepping;
        let error_before = session.last_error.clone();

        let result = session.begin_next_with_config_using(
            "CANDIDATE".into(),
            vec!["beams".into()],
            30,
            12,
            |_, _, _, _, _, _, _| Err(EngineError::Engine("injected build failure".into())),
        );

        assert!(matches!(result, Err(EngineError::Engine(_))));
        let after = session.published_c_frame();
        assert!(session.is_waiting());
        assert_eq!(session.generation(), 0);
        assert_eq!((after.cols, after.rows), (before.cols, before.rows));
        assert_eq!(after.cells, before.cells);
        assert_eq!(
            [after.clear_r, after.clear_g, after.clear_b, after.clear_a],
            [
                before.clear_r,
                before.clear_g,
                before.clear_b,
                before.clear_a
            ]
        );
        assert_eq!(session.selected.art, selected_before.art);
        assert_eq!(session.selected.effect, selected_before.effect);
        assert_eq!(session.selected.bg, selected_before.bg);
        assert_eq!(session.selected.pool, selected_before.pool);
        assert_eq!(session.selected_next.art, selected_next_before.art);
        assert_eq!(session.selected_next.effect, selected_next_before.effect);
        assert_eq!(session.selected_next.bg, selected_next_before.bg);
        assert_eq!(session.selected_next.pool, selected_next_before.pool);
        assert_eq!(session.accumulator, accumulator_before);
        assert_eq!(session.stepping, stepping_before);
        assert_eq!(session.last_error, error_before);

        // Compare the next random selection with an untouched seeded control
        // as an observable proxy that failure did not consume the live stream.
        session
            .begin_next_with_config("NEXT".into(), Vec::new(), 20, 8)
            .unwrap();
        control
            .begin_next_with_config("NEXT".into(), Vec::new(), 20, 8)
            .unwrap();
        let actual = session.step(1.0 / 60.0).unwrap().frame;
        let expected = control.step(1.0 / 60.0).unwrap().frame;
        assert_eq!((actual.cols, actual.rows), (expected.cols, expected.rows));
        let actual_cells = unsafe {
            std::slice::from_raw_parts(actual.cells, (actual.cols * actual.rows) as usize)
        };
        let expected_cells = unsafe {
            std::slice::from_raw_parts(expected.cells, (expected.cols * expected.rows) as usize)
        };
        assert_eq!(actual_cells.len(), expected_cells.len());
        for (actual, expected) in actual_cells.iter().zip(expected_cells) {
            assert_eq!(actual.glyph, expected.glyph);
            assert_eq!(
                (actual.fg_r, actual.fg_g, actual.fg_b, actual.fg_a),
                (expected.fg_r, expected.fg_g, expected.fg_b, expected.fg_a)
            );
            assert_eq!(
                (actual.bg_r, actual.bg_g, actual.bg_b, actual.bg_a),
                (expected.bg_r, expected.bg_g, expected.bg_b, expected.bg_a)
            );
            assert_eq!(actual.flags, expected.flags);
            assert_eq!(actual.occupancy, expected.occupancy);
        }
    }

    #[test]
    fn next_selection_continues_the_creation_selector_stream() {
        let seed = 17;
        let initial_pool = vec!["wipe".to_string(), "beams".to_string()];
        let next_pool = vec!["burn".to_string(), "slide".to_string()];
        let art = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../assets/branding/screensaver.txt"
        ))
        .unwrap();
        let mut session = Session::create(
            art,
            "random".into(),
            initial_pool.clone(),
            [0, 0, 0, 255],
            Some(seed),
            20,
            8,
            ClockKind::Virtual60,
        )
        .unwrap();
        for _ in 0..20_000 {
            if session.step(1.0 / 60.0).unwrap().waiting {
                break;
            }
        }
        assert!(session.is_waiting());

        let mut control = Rng::seeded(seed);
        pick_effect_name("random", &initial_pool, &mut control);
        let expected = pick_effect_name("random", &next_pool, &mut control).to_string();
        let mut actual = None;
        session
            .begin_next_with_config_using(
                "NEXT".into(),
                next_pool,
                20,
                8,
                |content, cols, rows, seed, generation, picker, clock| {
                    build_after_recording_selection(
                        content,
                        cols,
                        rows,
                        seed,
                        generation,
                        picker,
                        clock,
                        &mut actual,
                    )
                },
            )
            .unwrap();
        assert_eq!(actual.as_deref(), Some(expected.as_str()));
    }

    #[test]
    fn failed_selection_is_rolled_back_and_retry_matches_control() {
        let pool = vec!["wipe".to_string(), "beams".to_string()];
        let mut session = waiting_seeded_session();
        let mut control = Rng::seeded(1);
        let expected = pick_effect_name("random", &pool, &mut control).to_string();
        let mut failed = None;
        let result = session.begin_next_with_config_using(
            "NEXT".into(),
            pool.clone(),
            20,
            8,
            |content, _, _, _, _, picker, _| {
                failed = Some(pick_effect_name(&content.effect, &content.pool, picker).to_string());
                Err(EngineError::Engine("injected after selection".into()))
            },
        );
        assert!(matches!(result, Err(EngineError::Engine(_))));

        let mut retried = None;
        session
            .begin_next_with_config_using(
                "NEXT".into(),
                pool,
                20,
                8,
                |content, cols, rows, seed, generation, picker, clock| {
                    build_after_recording_selection(
                        content,
                        cols,
                        rows,
                        seed,
                        generation,
                        picker,
                        clock,
                        &mut retried,
                    )
                },
            )
            .unwrap();
        assert_eq!(failed.as_deref(), Some(expected.as_str()));
        assert_eq!(retried, failed);
    }
}

fn bg_or_opaque(bg: [u8; 4]) -> [u8; 4] {
    if bg[3] == 0 {
        [bg[0], bg[1], bg[2], 255]
    } else {
        bg
    }
}

fn construct_effect(
    content: &Content,
    cols: u32,
    rows: u32,
    seed: Option<u64>,
    generation: u64,
    pick_rng: &mut Rng,
    clock_kind: ClockKind,
) -> Result<(Box<dyn Effect>, EngineCtx), EngineError> {
    let name = pick_effect_name(&content.effect, &content.pool, pick_rng);
    let mut effect = EffectCommand::from_name(name)
        .ok_or_else(|| EngineError::InvalidArg(format!("unknown effect '{name}'")))?;
    let color = Color::from_hex(&format!(
        "{:02x}{:02x}{:02x}",
        content.bg[0], content.bg[1], content.bg[2]
    ))
    .map_err(EngineError::Engine)?;
    let config = TerminalConfig::gui(cols as i64, rows as i64, color);
    let rng = match seed {
        Some(s) => Rng::seeded(s.wrapping_add(generation)),
        None => Rng::from_entropy(),
    };
    let clock = match clock_kind {
        ClockKind::Real => Clock::real(),
        #[cfg(test)]
        ClockKind::Virtual60 => Clock::virtual_with_frame_rate(60),
    };
    let mut ctx = EngineCtx::new(&content.art, config, rng, clock)
        .map_err(|e| EngineError::Engine(e.to_string()))?;
    ctx.suppress_ansi = true;
    effect
        .build(&mut ctx)
        .map_err(|e| EngineError::Engine(e.to_string()))?;
    Ok((effect, ctx))
}

pub fn parse_c_string(
    bytes: Option<&[u8]>,
    required: bool,
    what: &str,
) -> Result<String, EngineError> {
    match bytes {
        None if required => Err(EngineError::InvalidArg(format!("{what} is required"))),
        None => Ok(String::new()),
        Some(b) => parse_utf8(b, what),
    }
}
