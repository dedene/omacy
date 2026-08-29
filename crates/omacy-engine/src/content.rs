use crate::limits;
use crate::status::EngineError;
use ttfx::effects::EffectCommand;
use ttfx::utils::rng::Rng;

#[derive(Clone, Debug)]
pub struct Content {
    pub art: String,
    pub effect: String,
    pub bg: [u8; 4],
    /// Include list for `effect == "random"`. Empty means all 37 names.
    pub pool: Vec<String>,
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
        return Err(EngineError::InvalidArg(
            "ASCII art must not contain ESC".into(),
        ));
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

/// Validates an explicit random-effect pool without silently changing it.
/// An empty list is the canonical representation of "all effects".
pub fn validate_pool(names: &[String]) -> Result<(), EngineError> {
    for (index, name) in names.iter().enumerate() {
        if !EffectCommand::NAMES.contains(&name.as_str()) {
            return Err(EngineError::InvalidArg(format!(
                "unknown effect '{name}' in pool"
            )));
        }
        if names[..index].contains(name) {
            return Err(EngineError::InvalidArg(format!(
                "duplicate effect '{name}' in pool"
            )));
        }
    }
    Ok(())
}

impl Content {
    pub fn from_parts(
        art: String,
        effect: String,
        pool: Vec<String>,
        bg: [u8; 4],
    ) -> Result<Self, EngineError> {
        validate_art(&art)?;
        validate_effect(&effect)?;
        validate_pool(&pool)?;
        if effect != "random" && !pool.is_empty() && !pool.contains(&effect) {
            return Err(EngineError::InvalidArg(format!(
                "pinned effect '{effect}' is not in the effect pool"
            )));
        }
        if art.is_empty() {
            return Err(EngineError::InvalidArg("ASCII art is empty".into()));
        }
        Ok(Content {
            art,
            effect,
            bg,
            pool,
        })
    }
}

pub fn pick_effect_name<'a>(effect: &'a str, pool: &'a [String], rng: &mut Rng) -> &'a str {
    if effect != "random" {
        return effect;
    }
    if pool.is_empty() {
        EffectCommand::NAMES[rng.choice_index(EffectCommand::NAMES.len())]
    } else {
        pool[rng.choice_index(pool.len())].as_str()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_named_effect_ignores_pool() {
        let pool = vec!["wipe".to_string()];
        let mut rng = Rng::seeded(1);
        assert_eq!(pick_effect_name("beams", &pool, &mut rng), "beams");
    }

    #[test]
    fn pick_random_uses_pool() {
        let pool = vec!["wipe".to_string(), "beams".to_string()];
        let mut rng = Rng::seeded(1);
        for _ in 0..1_000 {
            let name = pick_effect_name("random", &pool, &mut rng);
            assert!(pool.iter().any(|n| n == name), "{name}");
        }
    }

    #[test]
    fn pick_random_empty_pool_uses_all_names() {
        let pool: Vec<String> = Vec::new();
        let mut rng = Rng::seeded(7);
        let name = pick_effect_name("random", &pool, &mut rng);
        assert!(EffectCommand::NAMES.contains(&name), "{name}");
    }

    #[test]
    fn explicit_pool_rejects_unknown_and_duplicate_names() {
        assert!(matches!(
            validate_pool(&["wipe".into(), "nope".into()]),
            Err(EngineError::InvalidArg(_))
        ));
        assert!(matches!(
            validate_pool(&["wipe".into(), "wipe".into()]),
            Err(EngineError::InvalidArg(_))
        ));
        validate_pool(&[]).unwrap();
        validate_pool(&["wipe".into(), "beams".into()]).unwrap();
    }
}
