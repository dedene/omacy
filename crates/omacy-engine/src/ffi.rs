use std::cell::RefCell;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::slice;

use crate::abi::{
    slice_ptr_len, OmacyAsciiConfig, OmacyPendingConfig, OmacySessionConfig, OmacyStepResult,
    OmacyText,
};
use crate::ascii;
use crate::session::{self, ClockKind, Session};
use crate::status::{EngineError, OmacyStatus};

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_tls_error(msg: impl Into<String>) {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = msg.into());
}

fn write_error_buf(src: &str, buf: *mut c_char, buf_len: usize) -> OmacyStatus {
    if buf.is_null() {
        return OmacyStatus::Null;
    }
    if buf_len < 1 {
        return OmacyStatus::InvalidArg;
    }
    let bytes = src.as_bytes();
    let n = bytes.len().min(buf_len - 1);
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    OmacyStatus::Ok
}

pub fn is_main_thread() -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        libc::pthread_main_np() != 0
    }
    #[cfg(target_os = "linux")]
    unsafe {
        libc::getpid() as i64 == libc::syscall(libc::SYS_gettid)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        true
    }
}

fn require_main() -> Result<(), EngineError> {
    if is_main_thread() {
        Ok(())
    } else {
        Err(EngineError::WrongThread)
    }
}

fn zero_step(out: *mut OmacyStepResult) {
    if !out.is_null() {
        unsafe { *out = OmacyStepResult::zeroed() };
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_create(
    cfg: *const OmacySessionConfig,
    cols: u32,
    rows: u32,
    out: *mut *mut Session,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() {
            return OmacyStatus::Null;
        }
        unsafe { *out = ptr::null_mut() };
        if cfg.is_null() {
            set_tls_error("null config");
            return OmacyStatus::Null;
        }
        if let Err(e) = require_main() {
            set_tls_error(e.message());
            return e.status();
        }
        let cfg = unsafe { &*cfg };
        if cfg.has_seed > 1 {
            set_tls_error("has_seed must be 0 or 1");
            return OmacyStatus::InvalidArg;
        }
        let config_dir = match unsafe { slice_ptr_len(cfg.config_dir, cfg.config_dir_len) } {
            Ok(Some(b)) => match std::str::from_utf8(b) {
                Ok(s) if !s.is_empty() => Some(PathBuf::from(s)),
                Ok(_) => None,
                Err(_) => {
                    set_tls_error("config_dir is not UTF-8");
                    return OmacyStatus::InvalidArg;
                }
            },
            Ok(None) => None,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        let ascii = match unsafe { slice_ptr_len(cfg.ascii, cfg.ascii_len) } {
            Ok(v) => v,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        let effect = match unsafe { slice_ptr_len(cfg.effect, cfg.effect_len) } {
            Ok(v) => v,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        if ascii.is_none() && config_dir.is_none() {
            set_tls_error("ascii or config_dir is required");
            return OmacyStatus::InvalidArg;
        }
        let effect = match session::parse_c_string(effect, true, "effect") {
            Ok(s) => s,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        let art = if let Some(bytes) = ascii {
            match crate::content::parse_utf8(bytes, "ascii") {
                Ok(s) => s,
                Err(e) => {
                    set_tls_error(e.message());
                    return e.status();
                }
            }
        } else if let Some(dir) = &config_dir {
            match std::fs::read_to_string(dir.join("screensaver.txt")) {
                Ok(s) => s,
                Err(_) => {
                    set_tls_error("screensaver.txt missing from config_dir");
                    return OmacyStatus::InvalidArg;
                }
            }
        } else {
            String::new()
        };
        let seed = if cfg.has_seed == 1 {
            Some(cfg.seed)
        } else {
            None
        };
        match Session::create(
            art,
            effect,
            [cfg.bg_r, cfg.bg_g, cfg.bg_b, cfg.bg_a],
            config_dir,
            seed,
            cols,
            rows,
            ClockKind::Real,
        ) {
            Ok(session) => {
                unsafe { *out = Box::into_raw(Box::new(session)) };
                OmacyStatus::Ok
            }
            Err(e) => {
                set_tls_error(e.message());
                e.status()
            }
        }
    }));
    match result {
        Ok(status) => status,
        Err(_) => {
            set_tls_error("panic");
            if !out.is_null() {
                unsafe { *out = ptr::null_mut() };
            }
            OmacyStatus::Panic
        }
    }
}

unsafe fn session_mut<'a>(s: *mut Session) -> Result<&'a mut Session, EngineError> {
    if s.is_null() {
        Err(EngineError::Null)
    } else {
        Ok(unsafe { &mut *s })
    }
}

unsafe fn session_ref<'a>(s: *const Session) -> Result<&'a Session, EngineError> {
    if s.is_null() {
        Err(EngineError::Null)
    } else {
        Ok(unsafe { &*s })
    }
}

fn with_live_session(
    s: *mut Session,
    f: impl FnOnce(&mut Session) -> Result<(), EngineError>,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if let Err(e) = require_main() {
            set_tls_error(e.message());
            return e.status();
        }
        let session = match unsafe { session_mut(s) } {
            Ok(s) => s,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        if session.is_dead() {
            set_tls_error("session is dead");
            return OmacyStatus::Dead;
        }
        match f(session) {
            Ok(()) => OmacyStatus::Ok,
            Err(e) => {
                set_tls_error(e.message());
                session.set_last_error(e.message());
                e.status()
            }
        }
    }));
    match result {
        Ok(status) => {
            if status == OmacyStatus::Panic {
                if let Ok(session) = unsafe { session_mut(s) } {
                    session.mark_dead("panic".into());
                }
            }
            status
        }
        Err(_) => {
            set_tls_error("panic");
            if let Ok(session) = unsafe { session_mut(s) } {
                session.mark_dead("panic".into());
            }
            OmacyStatus::Panic
        }
    }
}

/// Induces a panic inside the same `catch_unwind` wrapper as session FFI.
/// Not part of the C ABI; engine tests use it to prove `cells` is invalidated.
pub unsafe fn debug_induce_panic(s: *mut Session) -> OmacyStatus {
    with_live_session(s, |_| panic!("omacy induced panic"))
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_resize(s: *mut Session, cols: u32, rows: u32) -> OmacyStatus {
    with_live_session(s, |session| session.resize(cols, rows))
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_step(
    s: *mut Session,
    elapsed_seconds: f64,
    out: *mut OmacyStepResult,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() {
            set_tls_error("null out");
            return OmacyStatus::Null;
        }
        if let Err(e) = require_main() {
            set_tls_error(e.message());
            zero_step(out);
            return e.status();
        }
        let session = match unsafe { session_mut(s) } {
            Ok(s) => s,
            Err(e) => {
                set_tls_error(e.message());
                zero_step(out);
                return e.status();
            }
        };
        if session.is_dead() {
            set_tls_error("session is dead");
            zero_step(out);
            return OmacyStatus::Dead;
        }
        match session.step(elapsed_seconds) {
            Ok(publish) => {
                unsafe {
                    *out = OmacyStepResult {
                        frame: publish.frame,
                        needs_begin_next: u8::from(publish.waiting),
                        steps_taken: publish.steps_taken,
                        _pad: [0; 2],
                    };
                }
                OmacyStatus::Ok
            }
            Err(e) => {
                set_tls_error(e.message());
                session.set_last_error(e.message());
                zero_step(out);
                e.status()
            }
        }
    }));
    match result {
        Ok(status) => status,
        Err(_) => {
            set_tls_error("panic");
            zero_step(out);
            if let Ok(session) = unsafe { session_mut(s) } {
                session.mark_dead("panic".into());
            }
            OmacyStatus::Panic
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_set_pending_config(
    s: *mut Session,
    cfg: *const OmacyPendingConfig,
) -> OmacyStatus {
    with_live_session(s, |session| {
        if cfg.is_null() {
            return Err(EngineError::Null);
        }
        let cfg = unsafe { &*cfg };
        let ascii = unsafe { slice_ptr_len(cfg.ascii, cfg.ascii_len)? };
        let effect = unsafe { slice_ptr_len(cfg.effect, cfg.effect_len)? };
        let packet = session::parse_pending(ascii, effect, [cfg.bg_r, cfg.bg_g, cfg.bg_b, cfg.bg_a])?;
        session.set_pending(packet)
    })
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_begin_next(s: *mut Session) -> OmacyStatus {
    with_live_session(s, |session| session.begin_next())
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_generation(
    s: *const Session,
    out: *mut u64,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() {
            set_tls_error("null out");
            return OmacyStatus::Null;
        }
        if let Err(e) = require_main() {
            set_tls_error(e.message());
            return e.status();
        }
        let session = match unsafe { session_ref(s) } {
            Ok(s) => s,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        unsafe { *out = session.generation() };
        OmacyStatus::Ok
    }));
    match result {
        Ok(status) => status,
        Err(_) => {
            set_tls_error("panic");
            OmacyStatus::Panic
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_error_message(
    s: *const Session,
    buf: *mut c_char,
    buf_len: usize,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if s.is_null() {
            let msg = LAST_ERROR.with(|slot| slot.borrow().clone());
            return write_error_buf(&msg, buf, buf_len);
        }
        if let Err(e) = require_main() {
            set_tls_error(e.message());
            return e.status();
        }
        let session = match unsafe { session_ref(s) } {
            Ok(s) => s,
            Err(e) => {
                set_tls_error(e.message());
                return e.status();
            }
        };
        write_error_buf(session.error_message(), buf, buf_len)
    }));
    match result {
        Ok(status) => status,
        Err(_) => {
            set_tls_error("panic");
            OmacyStatus::Panic
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_session_destroy(s: *mut Session) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if s.is_null() {
            return;
        }
        if !is_main_thread() {
            set_tls_error("wrong thread");
            return;
        }
        drop(unsafe { Box::from_raw(s) });
    }));
}

#[no_mangle]
pub extern "C" fn omacy_status_string(status: i32) -> *const c_char {
    let text = match status {
        0 => OmacyStatus::Ok.as_c_str(),
        1 => OmacyStatus::Null.as_c_str(),
        2 => OmacyStatus::InvalidArg.as_c_str(),
        3 => OmacyStatus::Limit.as_c_str(),
        4 => OmacyStatus::Engine.as_c_str(),
        5 => OmacyStatus::Panic.as_c_str(),
        6 => OmacyStatus::Dead.as_c_str(),
        7 => OmacyStatus::WrongThread.as_c_str(),
        _ => return ptr::null(),
    };
    text.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn omacy_ascii_from_bytes(
    cfg: *const OmacyAsciiConfig,
    bytes: *const u8,
    len: usize,
    out: *mut *mut OmacyText,
) -> OmacyStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if out.is_null() {
            return OmacyStatus::Null;
        }
        unsafe { *out = ptr::null_mut() };
        if cfg.is_null() {
            set_tls_error("null config");
            return OmacyStatus::Null;
        }
        let cfg = unsafe { *cfg };
        let input = if bytes.is_null() {
            if len == 0 {
                &[][..]
            } else {
                set_tls_error("null bytes with nonzero length");
                return OmacyStatus::InvalidArg;
            }
        } else {
            unsafe { slice::from_raw_parts(bytes, len) }
        };
        match ascii::ascii_from_bytes(cfg, input) {
            Ok(text) => {
                unsafe {
                    *out = Box::into_raw(Box::new(OmacyText {
                        bytes: text.into_bytes(),
                    }));
                }
                OmacyStatus::Ok
            }
            Err(e) => {
                set_tls_error(e.message());
                e.status()
            }
        }
    }));
    match result {
        Ok(status) => status,
        Err(_) => {
            set_tls_error("panic");
            if !out.is_null() {
                unsafe { *out = ptr::null_mut() };
            }
            OmacyStatus::Panic
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_text_free(t: *mut OmacyText) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if t.is_null() {
            return;
        }
        drop(unsafe { Box::from_raw(t) });
    }));
}

#[no_mangle]
pub unsafe extern "C" fn omacy_text_utf8(t: *const OmacyText) -> *const c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        if t.is_null() {
            ptr::null()
        } else {
            unsafe { (*t).bytes.as_ptr() as *const c_char }
        }
    })) {
        Ok(p) => p,
        Err(_) => ptr::null(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn omacy_text_len(t: *const OmacyText) -> usize {
    match catch_unwind(AssertUnwindSafe(|| {
        if t.is_null() {
            0
        } else {
            unsafe { (*t).bytes.len() }
        }
    })) {
        Ok(n) => n,
        Err(_) => 0,
    }
}
