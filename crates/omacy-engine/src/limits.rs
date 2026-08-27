pub const ASCII_BYTES: usize = 64 * 1024;
pub const ASCII_LINES: usize = 128;
pub const ASCII_COLUMNS: usize = 256;
pub const GRID_AXIS: u32 = 512;
pub const GRID_CELLS: u32 = 32_768;
pub const CONV_COLUMNS: u32 = 256;
pub const CONV_ROWS: u32 = 128;
pub const CONV_CELLS: u32 = 32_768;
pub const PNG_BYTES: usize = 8 * 1024 * 1024;
pub const SVG_BYTES: usize = 2 * 1024 * 1024;
pub const DECODED_PIXELS: u32 = 4_194_304;
pub const SVG_ELEMENTS: u32 = 8_192;
pub const STEP_HZ: f64 = 60.0;
pub const STEP_DT: f64 = 1.0 / STEP_HZ;
pub const MAX_STEPS_PER_CALL: u32 = 4;

pub fn check_geometry(cols: u32, rows: u32) -> Result<(u32, u32), super::status::EngineError> {
    if cols < 1 || rows < 1 || cols > GRID_AXIS || rows > GRID_AXIS {
        return Err(super::status::EngineError::Limit(
            "grid width or height exceeds cap".into(),
        ));
    }
    let cells = cols
        .checked_mul(rows)
        .ok_or_else(|| super::status::EngineError::Limit("grid cell count overflow".into()))?;
    if cells > GRID_CELLS {
        return Err(super::status::EngineError::Limit(
            "grid cell count exceeds 32768".into(),
        ));
    }
    Ok((cols, rows))
}
