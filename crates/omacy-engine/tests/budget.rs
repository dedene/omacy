use std::time::Instant;

use crate::session::{ClockKind, Session};

fn wordmark() -> String {
    std::fs::read_to_string(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn max_grid_session() -> Session {
    Session::create(
        wordmark(),
        "wipe".into(),
        Vec::new(),
        [0, 0, 0, 255],
        Some(1),
        256,
        128,
        ClockKind::Virtual60,
    )
    .expect("max-grid session")
}

#[test]
fn three_max_grid_sessions_step_under_budget() {
    let mut sessions = vec![max_grid_session(), max_grid_session(), max_grid_session()];
    for session in &mut sessions {
        session.step(1.0 / 60.0).expect("warmup step");
    }

    let started = Instant::now();
    for session in &mut sessions {
        let frame = session.step(1.0 / 60.0).expect("budget step").frame;
        assert_eq!(frame.cols * frame.rows, 32_768);
        assert!(!frame.cells.is_null());
    }
    let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;

    // Architecture phase-2 gate is 8.3 ms for step + Metal upload + encode.
    // This Linux job can only time the engine slice. Debug builds are slower;
    // `cargo test --release` is the production number.
    let budget_ms = if cfg!(debug_assertions) { 50.0 } else { 8.3 };
    assert!(
        elapsed_ms < budget_ms,
        "step of 3×32768-cell sessions took {elapsed_ms:.3} ms (budget {budget_ms} ms)"
    );
}
