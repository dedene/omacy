use std::collections::HashSet;

fn imageset() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/Omacy/OmacyScreensaver/Assets.xcassets/thumbnail.imageset")
}

#[test]
fn screensaver_thumbnails_are_landscape_brand() {
    let dir = imageset();
    let one_x = image::open(dir.join("thumbnail.png")).expect("thumbnail.png");
    let two_x = image::open(dir.join("thumbnail@2x.png")).expect("thumbnail@2x.png");
    assert_eq!(one_x.width(), 107);
    assert_eq!(one_x.height(), 65);
    assert_eq!(two_x.width(), 214);
    assert_eq!(two_x.height(), 65 * 2);

    let rgb = one_x.to_rgb8();
    let colors: HashSet<_> = rgb.pixels().map(|p| p.0).collect();
    assert!(
        colors.len() >= 3,
        "thumbnail must have field + glyph + edges, got {} colors",
        colors.len()
    );
    assert!(
        colors
            .iter()
            .any(|c| c[1] > 180 && c[0] > 100 && c[2] < 140),
        "field is brand green"
    );
    assert!(colors.contains(&[0, 0, 0]), "glyph is black");
}
