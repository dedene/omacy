use omacy_engine::session::{ClockKind, Session, StepPublish};
use omacy_engine::status::EngineError;

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
        [0, 0, 0, 255],
        None,
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
fn running_resize_is_pending() {
    let mut s = session("beams", 80, 24);
    let before = s.step(1.0 / 60.0).unwrap().frame;
    let ptr = before.cells;
    s.resize(100, 30).unwrap();
    let StepPublish { frame: after, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(after.cols, 80);
    assert_eq!(after.rows, 24);
    assert_eq!(after.cells, ptr);
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
fn begin_next_rejected_while_running() {
    let mut s = session("wipe", 40, 12);
    match s.begin_next() {
        Err(EngineError::InvalidArg(_)) => {}
        _ => panic!("expected invalid arg"),
    }
}

#[test]
fn unknown_effect_is_invalid() {
    let err = match Session::create(
        wordmark(),
        "not-an-effect".into(),
        [0, 0, 0, 255],
        None,
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
fn geometry_cap() {
    let err = match Session::create(
        wordmark(),
        "wipe".into(),
        [0, 0, 0, 255],
        None,
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
fn waiting_resize_applies_and_clears_cache() {
    let mut s = session("wipe", 20, 8);
    let mut waiting = false;
    for _ in 0..10_000 {
        let w = s.step(1.0 / 60.0).unwrap().waiting;
        if w {
            waiting = true;
            break;
        }
    }
    assert!(waiting, "wipe should complete on a tiny canvas");
    s.resize(24, 10).unwrap();
    let StepPublish { frame, waiting: still, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(still);
    assert_eq!(frame.cols, 24);
    assert_eq!(frame.rows, 10);
    s.begin_next().unwrap();
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(frame.cols, 24);
    assert_eq!(frame.rows, 10);
    assert_eq!(s.generation(), 1);
}

#[test]
fn ffi_create_off_main_fails() {
    use omacy_engine::ffi::is_main_thread;
    if is_main_thread() {
        return;
    }
    let cfg = omacy_engine::abi::OmacySessionConfig {
        config_dir: std::ptr::null(),
        config_dir_len: 0,
        ascii: b"A".as_ptr(),
        ascii_len: 1,
        effect: b"wipe".as_ptr(),
        effect_len: 4,
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut out: *mut omacy_engine::session::Session = std::ptr::null_mut();
    let status = unsafe {
        omacy_engine::ffi::omacy_session_create(&cfg, 20, 8, &mut out)
    };
    assert_eq!(status, omacy_engine::OmacyStatus::WrongThread);
    assert!(out.is_null());
}

#[test]
fn pending_background_is_not_published_clear() {
    let mut s = session("wipe", 20, 8);
    s.set_pending(omacy_engine::session::ContentPacket {
        art: None,
        effect: "wipe".into(),
        bg: [255, 0, 0, 255],
    })
    .unwrap();
    let mut waiting = false;
    let mut last_clear = [0u8; 4];
    for _ in 0..10_000 {
        let StepPublish { frame, waiting: w, .. } = s.step(1.0 / 60.0).unwrap();
        last_clear = [frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a];
        if w {
            waiting = true;
            break;
        }
    }
    assert!(waiting);
    assert_eq!(last_clear, [0, 0, 0, 255]);
    s.begin_next().unwrap();
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(
        [frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a],
        [255, 0, 0, 255]
    );
}

#[test]
fn status_strings_are_nul_terminated() {
    unsafe {
        let p = omacy_engine::ffi::omacy_status_string(0);
        assert!(!p.is_null());
        let s = std::ffi::CStr::from_ptr(p).to_str().unwrap();
        assert_eq!(s, "OMACY_OK");
    }
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
fn pending_queued_while_waiting_applies_at_following_boundary() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);
    s.set_pending(omacy_engine::session::ContentPacket {
        art: None,
        effect: "beams".into(),
        bg: [255, 0, 0, 255],
    })
    .unwrap();
    s.begin_next().unwrap();
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(
        [frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a],
        [0, 0, 0, 255],
        "packet queued in wait must not promote until the next boundary"
    );
    wait_for_end(&mut s);
    s.begin_next().unwrap();
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(
        [frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a],
        [255, 0, 0, 255]
    );
}

#[test]
fn begin_next_consumes_running_pending_geometry() {
    let mut s = session("wipe", 20, 8);
    s.resize(30, 12).unwrap();
    let frame = s.step(1.0 / 60.0).unwrap().frame;
    assert_eq!(frame.cols, 20);
    assert_eq!(frame.rows, 8);
    wait_for_end(&mut s);
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(waiting);
    assert_eq!(frame.cols, 20);
    assert_eq!(frame.rows, 8);
    s.begin_next().unwrap();
    let StepPublish { frame, waiting, .. } = s.step(1.0 / 60.0).unwrap();
    assert!(!waiting);
    assert_eq!(frame.cols, 30);
    assert_eq!(frame.rows, 12);
}

#[test]
fn reentrant_step_is_invalid() {
    let mut s = session("wipe", 20, 8);
    match s.force_reentrant_step() {
        Err(EngineError::InvalidArg(_)) => {}
        other => panic!("expected invalid arg, got {other:?}"),
    }
    s.step(1.0 / 60.0).expect("session still live after re-entrant reject");
}

#[test]
fn esc_in_art_is_invalid() {
    let err = match Session::create(
        "\u{1b}[31mX".into(),
        "wipe".into(),
        [0, 0, 0, 255],
        None,
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
        [0, 0, 0, 255],
        None,
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
fn waiting_republish_reports_zero_advances() {
    let mut s = session("wipe", 20, 8);
    wait_for_end(&mut s);
    let r = s.step(1.0 / 60.0).unwrap();
    assert!(r.waiting);
    assert_eq!(r.steps_taken, 0);
}
