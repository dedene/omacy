use crate::session::{ClockKind, Session, StepPublish};
use crate::status::EngineError;

fn wordmark() -> String {
    std::fs::read_to_string(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn session(effect: &str, cols: u32, rows: u32) -> Session {
    Session::create(
        wordmark(),
        effect.into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        cols,
        rows,
        ClockKind::Virtual60,
    )
    .expect("create")
}

#[test]
fn create_and_step_publishes_grid() {
    let mut s = session("beams", 80, 24);
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(frame.cols, 80);
    assert_eq!(frame.rows, 24);
    assert!(!frame.cells.is_null());
    assert_eq!(frame.clear_a, 255);
}

#[test]
fn invalid_elapsed_is_rejected() {
    let mut s = session("wipe", 40, 12);
    match s.step(f64::NAN) {
        Err(EngineError::InvalidArg(_)) => {}
        _ => panic!("expected invalid arg"),
    }
    match s.step(-0.1) {
        Err(EngineError::InvalidArg(_)) => {}
        _ => panic!("expected invalid arg"),
    }
}

#[test]
fn unknown_effect_is_invalid() {
    let err = match Session::create(
        wordmark(),
        "not-an-effect".into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        40,
        12,
        ClockKind::Virtual60,
    ) {
        Err(e) => e,
        Ok(_) => panic!("expected error"),
    };
    assert!(matches!(err, EngineError::InvalidArg(_)));
}

#[test]
fn create_retains_pool_and_enforces_pinned_effect_membership() {
    let pool = vec!["wipe".to_string(), "beams".to_string()];
    let random = Session::create(
        wordmark(),
        "random".into(),
        pool.clone(),
        [0, 0, 0, 255],
        Some(1),
        40,
        12,
        ClockKind::Virtual60,
    )
    .unwrap();
    assert_eq!(random.selected_effect_pool(), pool.as_slice());

    let err = match Session::create(
        wordmark(),
        "burn".into(),
        pool,
        [0, 0, 0, 255],
        Some(1),
        40,
        12,
        ClockKind::Virtual60,
    ) {
        Err(error) => error,
        Ok(_) => panic!("pinned effect outside pool must fail"),
    };
    assert!(matches!(err, EngineError::InvalidArg(_)));
}

#[test]
fn seeded_initial_random_effect_matches_the_selection_from_its_explicit_pool() {
    use ttfx::utils::rng::Rng;

    let seed = 17;
    let pool = vec!["wipe".to_string(), "beams".to_string()];
    let mut selector = Rng::seeded(seed);
    let expected = crate::content::pick_effect_name("random", &pool, &mut selector).to_string();

    let mut constrained = Session::create(
        wordmark(),
        "random".into(),
        pool.clone(),
        [0, 0, 0, 255],
        Some(seed),
        40,
        12,
        ClockKind::Virtual60,
    )
    .unwrap();
    let mut pinned_control = Session::create(
        wordmark(),
        expected,
        pool,
        [0, 0, 0, 255],
        Some(seed),
        40,
        12,
        ClockKind::Virtual60,
    )
    .unwrap();

    for _ in 0..120 {
        let actual = constrained.step(1.0 / 60.0).unwrap();
        let control = pinned_control.step(1.0 / 60.0).unwrap();
        assert_eq!(actual.waiting, control.waiting);
        assert_eq!(actual.steps_taken, control.steps_taken);
        assert_eq!((actual.frame.cols, actual.frame.rows), (40, 12));
        let actual_cells = unsafe { std::slice::from_raw_parts(actual.frame.cells, 40 * 12) };
        let control_cells = unsafe { std::slice::from_raw_parts(control.frame.cells, 40 * 12) };
        for (actual, control) in actual_cells.iter().zip(control_cells) {
            assert_eq!(actual.glyph, control.glyph);
            assert_eq!(actual.occupancy, control.occupancy);
            assert_eq!(
                (actual.fg_r, actual.fg_g, actual.fg_b, actual.fg_a),
                (control.fg_r, control.fg_g, control.fg_b, control.fg_a)
            );
            assert_eq!(
                (actual.bg_r, actual.bg_g, actual.bg_b, actual.bg_a),
                (control.bg_r, control.bg_g, control.bg_b, control.bg_a)
            );
        }
    }
}

#[test]
fn geometry_cap() {
    let err = match Session::create(
        wordmark(),
        "wipe".into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        513,
        1,
        ClockKind::Virtual60,
    ) {
        Err(e) => e,
        Ok(_) => panic!("expected error"),
    };
    assert!(matches!(err, EngineError::Limit(_)));
}

#[test]
fn ffi_create_off_main_fails() {
    use crate::ffi::is_main_thread;
    if is_main_thread() {
        return;
    }
    let cfg = crate::abi::OmacySessionConfig {
        ascii: b"A".as_ptr(),
        ascii_len: 1,
        effect: b"wipe".as_ptr(),
        effect_len: 4,
        effect_pool: std::ptr::null(),
        effect_pool_count: 0,
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut out: *mut crate::session::Session = std::ptr::null_mut();
    let status = unsafe { crate::ffi::omacy_session_create(&cfg, 20, 8, &mut out) };
    assert_eq!(status, crate::status::OmacyStatus::WrongThread);
    assert!(out.is_null());
}

#[test]
fn status_strings_are_nul_terminated() {
    unsafe {
        let p = crate::ffi::omacy_status_string(crate::status::OmacyStatus::Ok);
        assert!(!p.is_null());
        let s = std::ffi::CStr::from_ptr(p).to_str().unwrap();
        assert_eq!(s, "OMACY_OK");
    }
    assert!(crate::ffi::omacy_status_string(crate::status::OmacyStatus(99)).is_null());
}

#[test]
fn mark_dead_clears_published_cells() {
    let mut s = session("beams", 20, 8);
    let frame = s.step(1.0 / 60.0).unwrap().frame;
    assert!(!frame.cells.is_null());
    s.mark_dead("test".into());
    assert!(s.is_dead());
    let frame = s.published_c_frame();
    assert!(frame.cells.is_null());
}

fn wait_for_end(s: &mut Session) {
    for _ in 0..20_000 {
        let waiting = s.step(1.0 / 60.0).unwrap().waiting;
        if waiting {
            return;
        }
    }
    panic!("effect did not complete");
}

#[test]
fn reentrant_step_is_invalid() {
    let mut s = session("wipe", 20, 8);
    match s.force_reentrant_step() {
        Err(EngineError::InvalidArg(_)) => {}
        other => panic!("expected invalid arg, got {other:?}"),
    }
    s.step(1.0 / 60.0)
        .expect("session still live after re-entrant reject");
}

#[test]
fn esc_in_art_is_invalid() {
    let err = match Session::create(
        "\u{1b}[31mX".into(),
        "wipe".into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        20,
        8,
        ClockKind::Virtual60,
    ) {
        Err(e) => e,
        Ok(_) => panic!("expected error"),
    };
    assert!(matches!(err, EngineError::InvalidArg(_)));
}

#[test]
fn ascii_line_cap() {
    let art = (0..129).map(|_| "X").collect::<Vec<_>>().join("\n");
    let err = match Session::create(
        art,
        "wipe".into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        20,
        8,
        ClockKind::Virtual60,
    ) {
        Err(e) => e,
        Ok(_) => panic!("expected error"),
    };
    assert!(matches!(err, EngineError::Limit(_)));
}

#[test]
fn effect_pool_is_thirty_seven() {
    assert_eq!(ttfx::effects::EffectCommand::NAMES.len(), 37);
}

#[test]
fn zero_elapsed_step_reports_zero_advances() {
    let mut s = session("wipe", 40, 12);
    let first = s.step(1.0 / 60.0).unwrap();
    assert!(first.steps_taken >= 1);
    assert!(!first.waiting);
    let second = s.step(0.0).unwrap();
    assert_eq!(second.steps_taken, 0);
    assert_eq!(second.frame.cells, first.frame.cells);
}

#[test]
fn sub_dt_elapsed_does_not_advance() {
    let mut s = session("wipe", 40, 12);
    s.step(1.0 / 60.0).unwrap();
    let r = s.step(1.0 / 120.0).unwrap();
    assert_eq!(r.steps_taken, 0);
}

#[test]
fn atomic_next_commits_content_pool_geometry_and_generation() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);

    s.begin_next_with_config("NEW\nART".into(), vec!["beams".into()], 30, 12)
        .unwrap();

    assert_eq!(s.generation(), 1);
    assert_eq!(s.selected_effect_pool(), &["beams".to_string()]);
    let published = s.step(0.0).unwrap();
    assert!(!published.waiting);
    assert_eq!((published.frame.cols, published.frame.rows), (30, 12));
    assert_eq!(
        [
            published.frame.clear_r,
            published.frame.clear_g,
            published.frame.clear_b,
            published.frame.clear_a,
        ],
        [0, 0, 0, 255]
    );
}

#[test]
fn atomic_next_empty_pool_means_all_effects() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);
    s.begin_next_with_config("NEXT".into(), vec![], 20, 8)
        .unwrap();
    assert!(s.selected_effect_pool().is_empty());
}

#[test]
fn atomic_next_validation_failures_leave_published_state_unchanged() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);
    let before = s.published_c_frame();
    let generation = s.generation();

    let invalid_cases = [
        s.begin_next_with_config("\u{1b}[31mX".into(), vec!["wipe".into()], 30, 12),
        s.begin_next_with_config("NEXT".into(), vec!["unknown".into()], 30, 12),
        s.begin_next_with_config("NEXT".into(), vec!["wipe".into(), "wipe".into()], 30, 12),
        s.begin_next_with_config("NEXT".into(), vec!["wipe".into()], 513, 1),
        s.begin_next_with_config("".into(), vec!["wipe".into()], 30, 12),
    ];
    for result in invalid_cases {
        assert!(result.is_err());
        let after = s.published_c_frame();
        assert_eq!(s.generation(), generation);
        assert_eq!((after.cols, after.rows), (before.cols, before.rows));
        assert_eq!(after.cells, before.cells);
        assert_eq!(
            [after.clear_r, after.clear_g, after.clear_b, after.clear_a],
            [
                before.clear_r,
                before.clear_g,
                before.clear_b,
                before.clear_a
            ]
        );
        assert!(s.is_waiting());
    }
}

#[test]
fn atomic_next_is_rejected_while_running_without_mutation() {
    let mut s = session("wipe", 20, 8);
    let before = s.published_c_frame();
    let result = s.begin_next_with_config("NEXT".into(), vec!["wipe".into()], 30, 12);
    assert!(matches!(result, Err(EngineError::InvalidArg(_))));
    let after = s.published_c_frame();
    assert_eq!(s.generation(), 0);
    assert_eq!((after.cols, after.rows), (before.cols, before.rows));
    assert_eq!(after.cells, before.cells);
}

#[test]
fn waiting_republish_reports_zero_advances() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);
    let r = s.step(1.0 / 60.0).unwrap();
    assert!(r.waiting);
    assert_eq!(r.steps_taken, 0);
}
