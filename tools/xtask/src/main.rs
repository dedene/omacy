use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "usage: cargo xtask header <write|check>";

fn main() -> ExitCode {
    match run(env::args().skip(1)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(mut args: impl Iterator<Item = String>) -> Result<(), String> {
    match (args.next().as_deref(), args.next().as_deref(), args.next()) {
        (Some("header"), Some(mode @ ("write" | "check")), None) => generate_header(mode),
        _ => Err(USAGE.into()),
    }
}

fn generate_header(mode: &str) -> Result<(), String> {
    let root = workspace_root()?;
    let crate_dir = root.join("crates/omacy-engine");
    let header_path = crate_dir.join("include/omacy.h");
    let config_path = crate_dir.join("cbindgen.toml");
    let config = cbindgen::Config::from_file(&config_path)
        .map_err(|error| format!("read {}: {error}", config_path.display()))?;
    let bindings = cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .map_err(|error| format!("generate header: {error}"))?;
    let mut generated = Vec::new();
    bindings.write(&mut generated);
    let generated = preserve_public_spelling(generated)?;

    if mode == "write" {
        fs::write(&header_path, &generated)
            .map_err(|error| format!("write {}: {error}", header_path.display()))?;
        return Ok(());
    }

    let committed = fs::read(&header_path)
        .map_err(|error| format!("read {}: {error}", header_path.display()))?;
    check_header(&committed, &generated, &header_path)
}

fn check_header(committed: &[u8], generated: &[u8], path: &Path) -> Result<(), String> {
    if committed == generated {
        return Ok(());
    }
    Err(format!(
        "{} is stale; run `cargo xtask header write`",
        path.display()
    ))
}

fn preserve_public_spelling(generated: Vec<u8>) -> Result<Vec<u8>, String> {
    let mut header = String::from_utf8(generated)
        .map_err(|error| format!("cbindgen emitted non-UTF-8 output: {error}"))?;
    for (rust, public) in [("typedef OmacyCell OmacyCell;\n\n", "")] {
        if !header.contains(rust) {
            return Err(format!("expected cbindgen fragment is missing: {rust:?}"));
        }
        header = header.replacen(rust, public, 1);
    }
    Ok(header.into_bytes())
}

fn workspace_root() -> Result<PathBuf, String> {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| "xtask is not located at <workspace>/tools/xtask".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_incomplete_commands() {
        assert_eq!(run(["header".into()].into_iter()), Err(USAGE.into()));
    }

    #[test]
    fn rejects_extra_arguments() {
        assert_eq!(
            run(["header".into(), "check".into(), "extra".into()].into_iter()),
            Err(USAGE.into())
        );
    }

    #[test]
    fn header_check_rejects_drift() {
        let error = check_header(b"committed", b"generated", Path::new("omacy.h"))
            .expect_err("drift must fail the check");
        assert!(error.contains("omacy.h is stale"));
    }
}
