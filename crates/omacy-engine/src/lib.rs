//! Omacy engine: ttfx session, packed cell grid, C ABI.

pub mod abi;
pub mod ascii;
mod content;
pub mod ffi;
mod limits;
pub mod session;
mod settings;
pub mod status;

pub use abi::{OmacyAsciiConfig, OmacyCell, OmacyFrame, OmacyStepResult};
pub use session::{ClockKind, Session};
pub use settings::write_atomic;
pub use status::{EngineError, OmacyStatus};
