use std::path::PathBuf;

use ttfx::effects::EffectCommand;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::terminal::{PackedCell, TerminalConfig};
use ttfx::utils::graphics::Color;
use ttfx::utils::rng::Rng;

use crate::abi::OmacyFrame;
use crate::content::{is_known_effect, parse_utf8, validate_art, validate_effect, Content};
use crate::limits::{self, check_geometry};
use crate::settings;
use crate::status::EngineError;

#[derive(Clone, Copy, Debug)]
pub enum ClockKind {
    Real,
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
    pending: Option<ContentPacket>,
    pending_geometry: Option<(u32, u32)>,
    cols: u32,
    rows: u32,
    cache: Vec<PackedCell>,
    clear: [u8; 4],
    accumulator: f64,
    generation: u64,
    config_dir: Option<PathBuf>,
    pick_rng: Rng,
    seed: Option<u64>,
    clock_kind: ClockKind,
    stepping: bool,
    last_error: String,
}

#[derive(Clone, Debug)]
pub struct ContentPacket {
    pub art: Option<String>,
    pub effect: String,
    pub bg: [u8; 4],
}

impl Session {
    pub fn create(
        art: String,
        effect: String,
        bg: [u8; 4],
        config_dir: Option<PathBuf>,
        seed: Option<u64>,
        cols: u32,
        rows: u32,
        clock_kind: ClockKind,
    ) -> Result<Self, EngineError> {
        let (cols, rows) = check_geometry(cols, rows)?;
        let selected = Content::from_parts(art, effect, bg)?;
        let pick_rng = match seed {
            Some(s) => Rng::seeded(s),
            None => Rng::from_entropy(),
        };
        let clear = bg_or_opaque(selected.bg);
        let mut session = Session {
            state: LiveState::Dead,
            selected: selected.clone(),
            selected_next: selected,
            pending: None,
            pending_geometry: None,
            cols,
            rows,
            cache: vec![PackedCell::default(); (cols * rows) as usize],
            clear,
            accumulator: 0.0,
            generation: 0,
            config_dir,
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

    pub fn is_waiting(&self) -> bool {
        matches!(self.state, LiveState::Waiting)
    }

    pub fn mark_dead(&mut self, message: String) {
        self.state = LiveState::Dead;
        self.last_error = message;
        self.cache.clear();
    }

    pub fn set_pending(&mut self, packet: ContentPacket) -> Result<(), EngineError> {
        self.require_live()?;
        validate_effect(&packet.effect)?;
        if let Some(art) = &packet.art {
            if !art.is_empty() {
                validate_art(art)?;
            }
        }
        self.pending = Some(packet);
        Ok(())
    }

    pub fn resize(&mut self, cols: u32, rows: u32) -> Result<(), EngineError> {
        self.require_live()?;
        let (cols, rows) = check_geometry(cols, rows)?;
        match &self.state {
            LiveState::Running { .. } => {
                if (cols, rows) == (self.cols, self.rows) {
                    self.pending_geometry = None;
                } else {
                    self.pending_geometry = Some((cols, rows));
                }
                Ok(())
            }
            LiveState::Waiting => {
                self.apply_geometry(cols, rows);
                Ok(())
            }
            LiveState::Dead => Err(EngineError::Dead),
        }
    }

    fn apply_geometry(&mut self, cols: u32, rows: u32) {
        self.cols = cols;
        self.rows = rows;
        self.pending_geometry = None;
        self.cache = vec![PackedCell::default(); (cols * rows) as usize];
    }

    pub fn begin_next(&mut self) -> Result<(), EngineError> {
        if !matches!(self.state, LiveState::Waiting) {
            return Err(EngineError::InvalidArg(
                "begin_next is only legal while waiting".into(),
            ));
        }
        let previous_geom = (self.cols, self.rows);
        let previous_pending = self.pending_geometry;
        let previous_cache = self.cache.clone();
        let previous_clear = self.clear;
        if let Some((cols, rows)) = self.pending_geometry {
            self.apply_geometry(cols, rows);
        }
        match self.install_effect() {
            Ok(()) => {
                self.generation = self.generation.saturating_add(1);
                Ok(())
            }
            Err(e) => {
                self.cols = previous_geom.0;
                self.rows = previous_geom.1;
                self.pending_geometry = previous_pending;
                self.cache = previous_cache;
                self.clear = previous_clear;
                self.state = LiveState::Waiting;
                Err(e)
            }
        }
    }

    pub fn step(&mut self, elapsed: f64) -> Result<(OmacyFrame, bool), EngineError> {
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
        let waiting = inner?;
        Ok((self.published_c_frame(), waiting))
    }

    fn step_inner(&mut self, elapsed: f64) -> Result<bool, EngineError> {
        if matches!(self.state, LiveState::Waiting) {
            return Ok(true);
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

        self.fill_cache()?;

        if ended {
            self.accumulator = 0.0;
            self.apply_boundary_content();
            self.state = LiveState::Waiting;
            return Ok(true);
        }

        Ok(false)
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

    fn apply_boundary_content(&mut self) {
        if let Some(packet) = self.pending.take() {
            let mut next = self.selected.clone();
            if let Some(art) = packet.art {
                if !art.is_empty() {
                    next.art = art;
                }
            }
            next.effect = packet.effect;
            next.bg = packet.bg;
            self.selected_next = next;
            return;
        }
        if let Some(dir) = &self.config_dir {
            self.selected_next = settings::load_from_dir(dir, &self.selected);
            return;
        }
        self.selected_next = self.selected.clone();
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
    let name = if content.effect == "random" {
        EffectCommand::NAMES[pick_rng.choice_index(EffectCommand::NAMES.len())]
    } else {
        content.effect.as_str()
    };
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

pub fn parse_c_string(bytes: Option<&[u8]>, required: bool, what: &str) -> Result<String, EngineError> {
    match bytes {
        None if required => Err(EngineError::InvalidArg(format!("{what} is required"))),
        None => Ok(String::new()),
        Some(b) => parse_utf8(b, what),
    }
}

pub fn parse_pending(
    ascii: Option<&[u8]>,
    effect: Option<&[u8]>,
    bg: [u8; 4],
) -> Result<ContentPacket, EngineError> {
    let effect = parse_c_string(effect, true, "effect")?;
    if effect.is_empty() {
        return Err(EngineError::InvalidArg("effect is required".into()));
    }
    validate_effect(&effect)?;
    let art = match ascii {
        None | Some([]) => None,
        Some(b) => {
            let s = parse_utf8(b, "ascii")?;
            validate_art(&s)?;
            Some(s)
        }
    };
    if !is_known_effect(&effect) {
        return Err(EngineError::InvalidArg("unknown effect".into()));
    }
    Ok(ContentPacket { art, effect, bg })
}
