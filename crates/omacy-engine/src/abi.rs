use std::os::raw::c_char;

use ttfx::engine::PackedCell;

pub type OmacyCell = PackedCell;

pub const OMACY_CELL_HAS_BACKGROUND: u8 = ttfx::engine::CELL_HAS_BACKGROUND;
pub const OMACY_CELL_HAS_GLYPH: u8 = ttfx::engine::CELL_HAS_GLYPH;

pub const OMACY_ASCII_BRAILLE: u32 = 0;
pub const OMACY_ASCII_BLOCK: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct OmacyFrame {
    pub cols: u32,
    pub rows: u32,
    pub clear_r: u8,
    pub clear_g: u8,
    pub clear_b: u8,
    pub clear_a: u8,
    pub _pad: u32,
    pub cells: *const OmacyCell,
}

impl OmacyFrame {
    pub fn zeroed() -> Self {
        Self {
            cols: 0,
            rows: 0,
            clear_r: 0,
            clear_g: 0,
            clear_b: 0,
            clear_a: 0,
            _pad: 0,
            cells: std::ptr::null(),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct OmacyStepResult {
    pub frame: OmacyFrame,
    pub needs_begin_next: u8,
    pub steps_taken: u8,
    pub _pad: [u8; 2],
}

impl OmacyStepResult {
    pub fn zeroed() -> Self {
        Self {
            frame: OmacyFrame::zeroed(),
            needs_begin_next: 0,
            steps_taken: 0,
            _pad: [0; 2],
        }
    }
}

#[repr(C)]
pub struct OmacySessionConfig {
    pub config_dir: *const u8,
    pub config_dir_len: usize,
    pub ascii: *const u8,
    pub ascii_len: usize,
    pub effect: *const u8,
    pub effect_len: usize,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bg_a: u8,
    pub has_seed: u8,
    pub _pad: [u8; 3],
    pub seed: u64,
}

#[repr(C)]
pub struct OmacyPendingConfig {
    pub ascii: *const u8,
    pub ascii_len: usize,
    pub effect: *const u8,
    pub effect_len: usize,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bg_a: u8,
    pub _pad: [u8; 3],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct OmacyAsciiConfig {
    pub mode: u32,
    pub width: u32,
    pub height: u32,
    pub threshold: u8,
    pub invert: u8,
    pub trim: u8,
    pub _pad: u8,
}

#[repr(C)]
pub struct OmacyText {
    pub bytes: Vec<u8>,
}

pub unsafe fn slice_ptr_len<'a>(
    ptr: *const u8,
    len: usize,
) -> Result<Option<&'a [u8]>, super::status::EngineError> {
    if ptr.is_null() {
        if len == 0 {
            Ok(None)
        } else {
            Err(super::status::EngineError::InvalidArg(
                "null pointer with nonzero length".into(),
            ))
        }
    } else {
        Ok(Some(std::slice::from_raw_parts(ptr, len)))
    }
}

pub fn c_str_static(s: &'static str) -> *const c_char {
    s.as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn cell_layout() {
        assert_eq!(size_of::<OmacyCell>(), 16);
        assert_eq!(align_of::<OmacyCell>(), 4);
        assert_eq!(offset_of!(OmacyCell, glyph), 0);
        assert_eq!(offset_of!(OmacyCell, occupancy), 13);
    }

    #[test]
    fn ascii_config_layout() {
        assert_eq!(size_of::<OmacyAsciiConfig>(), 16);
        assert_eq!(align_of::<OmacyAsciiConfig>(), 4);
        assert_eq!(offset_of!(OmacyAsciiConfig, mode), 0);
        assert_eq!(offset_of!(OmacyAsciiConfig, threshold), 12);
    }

    #[test]
    fn step_result_layout() {
        assert_eq!(offset_of!(OmacyStepResult, needs_begin_next), 24);
        assert_eq!(offset_of!(OmacyStepResult, steps_taken), 25);
        assert_eq!(size_of::<OmacyStepResult>(), 32);
        assert_eq!(align_of::<OmacyStepResult>(), 8);
    }

    #[test]
    fn occupancy_constants_match_ttfx() {
        assert_eq!(OMACY_CELL_HAS_BACKGROUND, 1);
        assert_eq!(OMACY_CELL_HAS_GLYPH, 2);
        assert_eq!(OMACY_CELL_HAS_BACKGROUND, ttfx::engine::CELL_HAS_BACKGROUND);
        assert_eq!(OMACY_CELL_HAS_GLYPH, ttfx::engine::CELL_HAS_GLYPH);
    }
}
