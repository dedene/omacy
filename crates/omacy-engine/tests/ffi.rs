use crate::abi::{OmacyByteSlice, OmacySessionConfig, OmacyStepResult};
use crate::ffi::{
    debug_induce_panic, omacy_effect_catalog_count, omacy_effect_catalog_get,
    omacy_session_begin_next_with_config, omacy_session_create, omacy_session_destroy,
    omacy_session_error_message, omacy_session_generation, omacy_session_step,
};
use crate::session::Session;
use crate::status::OmacyStatus;
use std::os::raw::c_char;
use std::ptr;

fn wordmark() -> Vec<u8> {
    std::fs::read(format!(
        "{}/../../assets/branding/screensaver.txt",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn create_with_pool(
    effect: &[u8],
    pool: *const OmacyByteSlice,
    pool_count: usize,
) -> (OmacyStatus, *mut Session) {
    let art = wordmark();
    let cfg = OmacySessionConfig {
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        effect_pool: pool,
        effect_pool_count: pool_count,
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut session = ptr::null_mut();
    let status = unsafe { omacy_session_create(&cfg, 20, 8, &mut session) };
    (status, session)
}

#[test]
fn create_accepts_and_retains_explicit_effect_pool() {
    if !crate::ffi::is_main_thread() {
        return;
    }
    let names = [b"wipe".as_slice(), b"beams".as_slice()];
    let slices: Vec<_> = names
        .iter()
        .map(|name| OmacyByteSlice {
            ptr: name.as_ptr(),
            len: name.len(),
        })
        .collect();
    let (status, session) = create_with_pool(b"random", slices.as_ptr(), slices.len());
    assert_eq!(status, OmacyStatus::Ok);
    assert!(!session.is_null());
    assert_eq!(
        unsafe { &*session }.selected_effect_pool(),
        &["wipe".to_string(), "beams".to_string()]
    );
    unsafe { omacy_session_destroy(session) };
}

#[test]
fn create_deep_copies_effect_pool_before_caller_buffers_change() {
    if !crate::ffi::is_main_thread() {
        return;
    }
    let mut wipe = b"wipe".to_vec();
    let mut beams = b"beams".to_vec();
    let slices = [
        OmacyByteSlice {
            ptr: wipe.as_ptr(),
            len: wipe.len(),
        },
        OmacyByteSlice {
            ptr: beams.as_ptr(),
            len: beams.len(),
        },
    ];
    let (status, session) = create_with_pool(b"random", slices.as_ptr(), slices.len());
    assert_eq!(status, OmacyStatus::Ok);
    assert!(!session.is_null());

    wipe.fill(b'x');
    beams.fill(b'y');
    drop(wipe);
    drop(beams);
    assert_eq!(
        unsafe { &*session }.selected_effect_pool(),
        &["wipe".to_string(), "beams".to_string()]
    );
    unsafe { omacy_session_destroy(session) };
}

#[test]
fn create_rejects_invalid_effect_pools_and_always_clears_out() {
    if !crate::ffi::is_main_thread() {
        return;
    }
    let too_many = [OmacyByteSlice {
        ptr: b"wipe".as_ptr(),
        len: 4,
    }; 38];
    let cases: Vec<(OmacyStatus, *const OmacyByteSlice, usize)> = vec![
        (OmacyStatus::InvalidArg, ptr::null(), 1),
        (OmacyStatus::Limit, too_many.as_ptr(), too_many.len()),
    ];
    for (expected, pool, count) in cases {
        let (status, session) = create_with_pool(b"random", pool, count);
        assert_eq!(status, expected);
        assert!(session.is_null());
    }

    let malformed = OmacyByteSlice {
        ptr: ptr::null(),
        len: 1,
    };
    let invalid_utf8_bytes = [0xff];
    let invalid_utf8 = OmacyByteSlice {
        ptr: invalid_utf8_bytes.as_ptr(),
        len: 1,
    };
    let unknown = OmacyByteSlice {
        ptr: b"unknown".as_ptr(),
        len: 7,
    };
    let duplicates = [
        OmacyByteSlice {
            ptr: b"wipe".as_ptr(),
            len: 4,
        },
        OmacyByteSlice {
            ptr: b"wipe".as_ptr(),
            len: 4,
        },
    ];
    for (pool, count) in [
        (&malformed as *const _, 1),
        (&invalid_utf8 as *const _, 1),
        (&unknown as *const _, 1),
        (duplicates.as_ptr(), duplicates.len()),
    ] {
        let (status, session) = create_with_pool(b"random", pool, count);
        assert_eq!(status, OmacyStatus::InvalidArg);
        assert!(session.is_null());
    }
}

#[test]
fn create_requires_pinned_effect_to_belong_to_explicit_pool() {
    if !crate::ffi::is_main_thread() {
        return;
    }
    let wipe = OmacyByteSlice {
        ptr: b"wipe".as_ptr(),
        len: 4,
    };
    let (status, session) = create_with_pool(b"beams", &wipe, 1);
    assert_eq!(status, OmacyStatus::InvalidArg);
    assert!(session.is_null());

    let (status, session) = create_with_pool(b"wipe", &wipe, 1);
    assert_eq!(status, OmacyStatus::Ok);
    assert!(!session.is_null());
    unsafe { omacy_session_destroy(session) };

    // A zero count is the complete catalog even when the pointer is non-null.
    let (status, session) = create_with_pool(b"beams", &wipe, 0);
    assert_eq!(status, OmacyStatus::Ok);
    assert!(!session.is_null());
    unsafe { omacy_session_destroy(session) };
}

fn waiting_ffi_session() -> Option<*mut Session> {
    if !crate::ffi::is_main_thread() {
        return None;
    }
    let art = wordmark();
    let cfg = OmacySessionConfig {
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: b"wipe".as_ptr(),
        effect_len: 4,
        effect_pool: ptr::null(),
        effect_pool_count: 0,
        bg_r: 0,
        bg_g: 0,
        bg_b: 0,
        bg_a: 255,
        has_seed: 1,
        _pad: [0; 3],
        seed: 1,
    };
    let mut session = ptr::null_mut();
    if unsafe { omacy_session_create(&cfg, 20, 8, &mut session) } != OmacyStatus::Ok {
        return None;
    }
    for _ in 0..20_000 {
        let mut out = OmacyStepResult::zeroed();
        assert_eq!(
            unsafe { omacy_session_step(session, 1.0 / 60.0, &mut out) },
            OmacyStatus::Ok
        );
        if out.needs_begin_next == 1 {
            return Some(session);
        }
    }
    unsafe { omacy_session_destroy(session) };
    panic!("effect did not reach waiting state")
}

#[test]
fn step_null_out_does_not_crash() {
    if !crate::ffi::is_main_thread() {
        let status = unsafe { omacy_session_step(ptr::null_mut(), 1.0 / 60.0, ptr::null_mut()) };
        assert_eq!(status, OmacyStatus::Null);
        return;
    }
    let art = wordmark();
    let effect = b"wipe";
    let cfg = OmacySessionConfig {
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        effect_pool: ptr::null(),
        effect_pool_count: 0,
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
    if !crate::ffi::is_main_thread() {
        return;
    }
    let art = wordmark();
    let effect = b"wipe";
    let cfg = OmacySessionConfig {
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        effect_pool: ptr::null(),
        effect_pool_count: 0,
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

#[test]
fn panic_invalidates_cells() {
    if !crate::ffi::is_main_thread() {
        return;
    }
    let art = wordmark();
    let effect = b"wipe";
    let cfg = OmacySessionConfig {
        ascii: art.as_ptr(),
        ascii_len: art.len(),
        effect: effect.as_ptr(),
        effect_len: effect.len(),
        effect_pool: ptr::null(),
        effect_pool_count: 0,
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
    let status = unsafe { omacy_session_step(session, 1.0 / 60.0, &mut out) };
    assert_eq!(status, OmacyStatus::Ok);
    assert!(!out.frame.cells.is_null());

    let status = unsafe { debug_induce_panic(session) };
    assert_eq!(status, OmacyStatus::Panic);

    let mut after = OmacyStepResult::zeroed();
    after.frame.cells = art.as_ptr() as *const _;
    let status = unsafe { omacy_session_step(session, 1.0 / 60.0, &mut after) };
    assert_eq!(status, OmacyStatus::Dead);
    assert!(after.frame.cells.is_null());
    assert_eq!(after.needs_begin_next, 0);
    unsafe { omacy_session_destroy(session) };
}

#[test]
fn effect_catalog_returns_static_utf8_and_clears_outputs_out_of_range() {
    let count = omacy_effect_catalog_count();
    assert_eq!(count, 37);
    for index in 0..count {
        let mut bytes = ptr::null();
        let mut len = 0;
        let status = unsafe { omacy_effect_catalog_get(index, &mut bytes, &mut len) };
        assert_eq!(status, OmacyStatus::Ok);
        assert!(!bytes.is_null());
        let name = unsafe { std::str::from_utf8(std::slice::from_raw_parts(bytes, len)).unwrap() };
        assert_eq!(name, ttfx::effects::EffectCommand::NAMES[index]);
    }

    let sentinel = wordmark();
    let mut bytes = sentinel.as_ptr();
    let mut len = usize::MAX;
    let status = unsafe { omacy_effect_catalog_get(count, &mut bytes, &mut len) };
    assert_eq!(status, OmacyStatus::InvalidArg);
    assert!(bytes.is_null());
    assert_eq!(len, 0);
    assert_eq!(
        unsafe { omacy_effect_catalog_get(0, ptr::null_mut(), &mut len) },
        OmacyStatus::Null
    );
    assert_eq!(len, 0);
}

#[test]
fn effect_catalog_is_available_off_main_thread() {
    std::thread::spawn(|| {
        let count = omacy_effect_catalog_count();
        assert_eq!(count, 37);
        let mut bytes = ptr::null();
        let mut len = 0;
        let status = unsafe { omacy_effect_catalog_get(0, &mut bytes, &mut len) };
        assert_eq!(status, OmacyStatus::Ok);
        let name = unsafe { std::str::from_utf8(std::slice::from_raw_parts(bytes, len)).unwrap() };
        assert_eq!(name, ttfx::effects::EffectCommand::NAMES[0]);
    })
    .join()
    .unwrap();
}

#[test]
fn atomic_ffi_rejects_invalid_pool_pointer_shapes() {
    let Some(session) = waiting_ffi_session() else {
        return;
    };
    let status = unsafe {
        omacy_session_begin_next_with_config(session, b"NEXT".as_ptr(), 4, ptr::null(), 1, 20, 8)
    };
    assert_eq!(status, OmacyStatus::InvalidArg);

    let too_many = [OmacyByteSlice {
        ptr: b"wipe".as_ptr(),
        len: 4,
    }; 38];
    let status = unsafe {
        omacy_session_begin_next_with_config(
            session,
            b"NEXT".as_ptr(),
            4,
            too_many.as_ptr(),
            too_many.len(),
            20,
            8,
        )
    };
    assert_eq!(status, OmacyStatus::Limit);

    let status = unsafe {
        omacy_session_begin_next_with_config(session, ptr::null(), 1, ptr::null(), 0, 20, 8)
    };
    assert_eq!(status, OmacyStatus::InvalidArg);

    let malformed = OmacyByteSlice {
        ptr: ptr::null(),
        len: 1,
    };
    let status = unsafe {
        omacy_session_begin_next_with_config(session, b"NEXT".as_ptr(), 4, &malformed, 1, 20, 8)
    };
    assert_eq!(status, OmacyStatus::InvalidArg);

    // The individual null+zero form is accepted as a byte slice but then
    // rejected as an empty (therefore unknown) effect name.
    let empty = OmacyByteSlice {
        ptr: ptr::null(),
        len: 0,
    };
    let status = unsafe {
        omacy_session_begin_next_with_config(session, b"NEXT".as_ptr(), 4, &empty, 1, 20, 8)
    };
    assert_eq!(status, OmacyStatus::InvalidArg);

    let status = unsafe {
        omacy_session_begin_next_with_config(session, ptr::null(), 0, ptr::null(), 0, 20, 8)
    };
    assert_eq!(status, OmacyStatus::InvalidArg);

    // All rejected calls leave the waiting generation usable; an empty pool
    // then means the complete catalog and succeeds atomically.
    let status = unsafe {
        omacy_session_begin_next_with_config(session, b"NEXT".as_ptr(), 4, ptr::null(), 0, 24, 10)
    };
    assert_eq!(status, OmacyStatus::Ok);
    unsafe { omacy_session_destroy(session) };
}

#[test]
fn atomic_ffi_wrong_thread_is_rejected_without_mutation() {
    let Some(session) = waiting_ffi_session() else {
        return;
    };
    let address = session as usize;
    let status = std::thread::spawn(move || unsafe {
        omacy_session_begin_next_with_config(
            address as *mut Session,
            b"NEXT".as_ptr(),
            4,
            ptr::null(),
            0,
            24,
            10,
        )
    })
    .join()
    .unwrap();
    assert_eq!(status, OmacyStatus::WrongThread);

    let mut generation = u64::MAX;
    assert_eq!(
        unsafe { omacy_session_generation(session, &mut generation) },
        OmacyStatus::Ok
    );
    assert_eq!(generation, 0);
    assert_eq!(
        unsafe {
            omacy_session_begin_next_with_config(
                session,
                b"NEXT".as_ptr(),
                4,
                ptr::null(),
                0,
                24,
                10,
            )
        },
        OmacyStatus::Ok
    );
    unsafe { omacy_session_destroy(session) };
}
