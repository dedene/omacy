use omacy_engine::abi::{OmacySessionConfig, OmacyStepResult};
use omacy_engine::ffi::{omacy_session_create, omacy_session_destroy, omacy_session_error_message, omacy_session_step};
use omacy_engine::session::Session;
use omacy_engine::OmacyStatus;
use std::os::raw::c_char;
use std::ptr;

fn wordmark() -> Vec<u8> {
    std::fs::read(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

#[test]
fn step_null_out_does_not_crash() {
    if !omacy_engine::ffi::is_main_thread() {
        let status = unsafe { omacy_session_step(ptr::null_mut(), 1.0 / 60.0, ptr::null_mut()) };
        assert_eq!(status, OmacyStatus::Null);
        return;
    }
    let art = wordmark();
    let effect = b"wipe";
    let cfg = OmacySessionConfig {
        config_dir: ptr::null(),
        config_dir_len: 0,
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut session: *mut Session = ptr::null_mut();
    let status = unsafe { omacy_session_create(&cfg, 20, 8, &mut session) };
    if status == OmacyStatus::WrongThread {
        return;
    }
    assert_eq!(status, OmacyStatus::Ok);
    let status = unsafe { omacy_session_step(session, 1.0 / 60.0, ptr::null_mut()) };
    assert_eq!(status, OmacyStatus::Null);
    unsafe { omacy_session_destroy(session) };
}

#[test]
fn error_message_null_session_any_thread() {
    let mut buf = [0 as c_char; 64];
    let status = unsafe { omacy_session_error_message(ptr::null(), buf.as_mut_ptr(), buf.len()) };
    assert_eq!(status, OmacyStatus::Ok);
}

#[test]
fn step_zeroes_out_on_invalid_elapsed() {
    if !omacy_engine::ffi::is_main_thread() {
        return;
    }
    let art = wordmark();
    let effect = b"wipe";
    let cfg = OmacySessionConfig {
        config_dir: ptr::null(),
        config_dir_len: 0,
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut session: *mut Session = ptr::null_mut();
    let status = unsafe { omacy_session_create(&cfg, 20, 8, &mut session) };
    if status != OmacyStatus::Ok {
        return;
    }
    let mut out = OmacyStepResult::zeroed();
    let status = unsafe { omacy_session_step(session, f64::NAN, &mut out) };
    assert_eq!(status, OmacyStatus::InvalidArg);
    assert!(out.frame.cells.is_null());
    assert_eq!(out.needs_begin_next, 0);
    unsafe { omacy_session_destroy(session) };
}
