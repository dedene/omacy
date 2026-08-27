use std::collections::HashSet;

fn imageset() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/Omacy/OmacyScreensaver/Assets.xcassets/thumbnail.imageset")
}

#[test]
fn screensaver_thumbnails_are_landscape_canary() {
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
        "thumbnail must show the canary (field + blank + glyph), got {} colors",
        colors.len()
    );
    assert!(colors.contains(&[0, 0, 0]), "field is black");
    assert!(colors.iter().any(|c| c[2] > 200 && c[0] < 80), "bottom-left blank is blue");
    assert!(colors.contains(&[255, 255, 255]), "top-right glyph is white");
}
