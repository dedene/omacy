//! Omacy engine: ttfx session, packed cell grid, C ABI.

pub mod abi;
pub mod ascii;
mod content;
pub mod ffi;
mod limits;
pub mod session;
mod settings;
pub mod status;

pub use abi::{
    OmacyAsciiConfig, OmacyCell, OmacyFrame, OmacyStepResult, OMACY_CELL_HAS_BACKGROUND,
    OMACY_CELL_HAS_GLYPH,
};
pub use session::{ClockKind, Session, StepPublish};
pub use settings::write_atomic;
pub use status::{EngineError, OmacyStatus};
