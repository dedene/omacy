use crate::limits;
use crate::status::EngineError;
use ttfx::effects::EffectCommand;

#[derive(Clone, Debug)]
pub struct Content {
    pub art: String,
    pub effect: String,
    pub bg: [u8; 4],
}

pub fn is_known_effect(name: &str) -> bool {
    name == "random" || EffectCommand::NAMES.contains(&name)
}

pub fn parse_utf8(bytes: &[u8], what: &str) -> Result<String, EngineError> {
    std::str::from_utf8(bytes)
        .map(|s| s.to_owned())
        .map_err(|_| EngineError::InvalidArg(format!("{what} is not UTF-8")))
}

pub fn validate_art(art: &str) -> Result<(), EngineError> {
    if art.len() > limits::ASCII_BYTES {
        return Err(EngineError::Limit("ASCII input exceeds 64 KiB".into()));
    }
    if art.bytes().any(|b| b == 0x1B) {
        return Err(EngineError::InvalidArg("ASCII art must not contain ESC".into()));
    }
    let mut lines = 0usize;
    let mut longest = 0usize;
    for line in art.split('\n') {
        lines += 1;
        longest = longest.max(line.chars().count());
        if lines > limits::ASCII_LINES {
            return Err(EngineError::Limit("ASCII line count exceeds 128".into()));
        }
        if longest > limits::ASCII_COLUMNS {
            return Err(EngineError::Limit("ASCII column count exceeds 256".into()));
        }
    }
    Ok(())
}

pub fn validate_effect(name: &str) -> Result<(), EngineError> {
    if is_known_effect(name) {
        Ok(())
    } else {
        Err(EngineError::InvalidArg(format!("unknown effect '{name}'")))
    }
}

pub fn parse_hex_color(s: &str) -> Result<[u8; 4], EngineError> {
    let t = s.trim().trim_start_matches('#');
    let err = || EngineError::InvalidArg(format!("invalid background color '{s}'"));
    match t.len() {
        6 => {
            let n = u32::from_str_radix(t, 16).map_err(|_| err())?;
            Ok([
                ((n >> 16) & 0xFF) as u8,
                ((n >> 8) & 0xFF) as u8,
                (n & 0xFF) as u8,
                255,
            ])
        }
        8 => {
            let n = u32::from_str_radix(t, 16).map_err(|_| err())?;
            Ok([
                ((n >> 24) & 0xFF) as u8,
                ((n >> 16) & 0xFF) as u8,
                ((n >> 8) & 0xFF) as u8,
                (n & 0xFF) as u8,
            ])
        }
        _ => Err(err()),
    }
}

impl Content {
    pub fn from_parts(art: String, effect: String, bg: [u8; 4]) -> Result<Self, EngineError> {
        validate_art(&art)?;
        validate_effect(&effect)?;
        if art.is_empty() {
            return Err(EngineError::InvalidArg("ASCII art is empty".into()));
        }
        Ok(Content { art, effect, bg })
    }
}
