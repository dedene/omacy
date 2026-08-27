use std::fs;
use std::path::Path;

use serde::Deserialize;

use crate::content::{parse_hex_color, validate_art, validate_effect, Content};
use crate::status::EngineError;

#[derive(Debug, Deserialize)]
struct SettingsFile {
    effect: Option<String>,
    background: Option<String>,
}

pub fn load_from_dir(dir: &Path, fallback: &Content) -> Content {
    let art_path = dir.join("screensaver.txt");
    let settings_path = dir.join("settings.json");

    let mut next = fallback.clone();

    match fs::read_to_string(&art_path) {
        Ok(art) => match validate_art(&art) {
            Ok(()) if !art.is_empty() => next.art = art,
            _ => {}
        },
        Err(_) => {}
    }

    match fs::read_to_string(&settings_path) {
        Ok(text) => {
            if let Ok(parsed) = serde_json::from_str::<SettingsFile>(&text) {
                if let Some(effect) = parsed.effect {
                    if validate_effect(&effect).is_ok() {
                        next.effect = effect;
                    }
                }
                if let Some(bg) = parsed.background {
                    if let Ok(rgba) = parse_hex_color(&bg) {
                        next.bg = rgba;
                    }
                }
            }
        }
        Err(_) => {}
    }

    next
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), EngineError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let tmp = parent.join(format!(
        ".{}.tmp",
        path.file_name().and_then(|s| s.to_str()).unwrap_or("omacy")
    ));
    fs::write(&tmp, bytes).map_err(|e| EngineError::Engine(e.to_string()))?;
    fs::rename(&tmp, path).map_err(|e| EngineError::Engine(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::Content;
    use std::env;

    #[test]
    fn atomic_write_replaces_file() {
        let dir = env::temp_dir().join(format!("omacy-atomic-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        write_atomic(&path, b"{\"effect\":\"random\"}").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"{\"effect\":\"random\"}");
        write_atomic(&path, b"{\"effect\":\"beams\"}").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"{\"effect\":\"beams\"}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn invalid_json_keeps_last_known_good() {
        let dir = env::temp_dir().join(format!("omacy-badjson-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("settings.json"), b"{not json").unwrap();
        fs::write(dir.join("screensaver.txt"), b"HELLO").unwrap();
        let fallback = Content::from_parts("FALLBACK".into(), "beams".into(), [1, 2, 3, 255]).unwrap();
        let next = load_from_dir(&dir, &fallback);
        assert_eq!(next.effect, "beams");
        assert_eq!(next.bg, [1, 2, 3, 255]);
        assert_eq!(next.art, "HELLO");
        let _ = fs::remove_dir_all(&dir);
    }
}
