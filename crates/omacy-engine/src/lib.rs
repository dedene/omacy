//! Omacy engine: ttfx session, packed cell grid, C ABI.

mod abi;
mod ascii;
mod content;
mod ffi;
mod limits;
mod session;
mod status;

/// Narrow opt-in API for the fixture-writing development tool. The production
/// engine surface is the opaque C ABI generated from the private modules.
#[cfg(feature = "fixture-tools")]
pub mod fixture_tools {
    pub use crate::abi::{OmacyAsciiConfig, OMACY_ASCII_BLOCK, OMACY_ASCII_BRAILLE};
    pub use crate::ascii::ascii_from_bytes;
}

#[cfg(test)]
#[path = "../tests/ascii.rs"]
mod ascii_tests;
#[cfg(test)]
#[path = "../tests/budget.rs"]
mod budget_tests;
#[cfg(test)]
#[path = "../tests/conversion.rs"]
mod conversion_tests;
#[cfg(test)]
#[path = "../tests/ffi.rs"]
mod ffi_tests;
#[cfg(test)]
#[path = "../tests/oracle.rs"]
mod oracle_tests;
#[cfg(test)]
#[path = "../tests/parity_debug.rs"]
mod parity_debug_tests;
#[cfg(test)]
#[path = "../tests/parity.rs"]
mod parity_tests;
#[cfg(test)]
#[path = "../tests/session.rs"]
mod session_tests;
#[cfg(test)]
#[path = "../tests/sgr_decode.rs"]
mod sgr_decode_tests;
#[cfg(test)]
#[path = "../tests/thumbnails.rs"]
mod thumbnails_tests;
