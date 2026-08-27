use std::ffi::c_int;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OmacyStatus {
    Ok = 0,
    Null = 1,
    InvalidArg = 2,
    Limit = 3,
    Engine = 4,
    Panic = 5,
    Dead = 6,
    WrongThread = 7,
}

impl OmacyStatus {
    pub fn as_c_int(self) -> c_int {
        self as c_int
    }

    pub fn as_str(self) -> &'static str {
        match self {
            OmacyStatus::Ok => "OMACY_OK",
            OmacyStatus::Null => "OMACY_ERR_NULL",
            OmacyStatus::InvalidArg => "OMACY_ERR_INVALID_ARG",
            OmacyStatus::Limit => "OMACY_ERR_LIMIT",
            OmacyStatus::Engine => "OMACY_ERR_ENGINE",
            OmacyStatus::Panic => "OMACY_ERR_PANIC",
            OmacyStatus::Dead => "OMACY_ERR_DEAD",
            OmacyStatus::WrongThread => "OMACY_ERR_WRONG_THREAD",
        }
    }

    pub fn as_c_str(self) -> &'static std::ffi::CStr {
        match self {
            OmacyStatus::Ok => c"OMACY_OK",
            OmacyStatus::Null => c"OMACY_ERR_NULL",
            OmacyStatus::InvalidArg => c"OMACY_ERR_INVALID_ARG",
            OmacyStatus::Limit => c"OMACY_ERR_LIMIT",
            OmacyStatus::Engine => c"OMACY_ERR_ENGINE",
            OmacyStatus::Panic => c"OMACY_ERR_PANIC",
            OmacyStatus::Dead => c"OMACY_ERR_DEAD",
            OmacyStatus::WrongThread => c"OMACY_ERR_WRONG_THREAD",
        }
    }
}

#[derive(Debug)]
pub enum EngineError {
    Null,
    InvalidArg(String),
    Limit(String),
    Engine(String),
    Dead,
    WrongThread,
}

impl EngineError {
    pub fn status(&self) -> OmacyStatus {
        match self {
            EngineError::Null => OmacyStatus::Null,
            EngineError::InvalidArg(_) => OmacyStatus::InvalidArg,
            EngineError::Limit(_) => OmacyStatus::Limit,
            EngineError::Engine(_) => OmacyStatus::Engine,
            EngineError::Dead => OmacyStatus::Dead,
            EngineError::WrongThread => OmacyStatus::WrongThread,
        }
    }

    pub fn message(&self) -> String {
        match self {
            EngineError::Null => "null pointer".into(),
            EngineError::InvalidArg(m) | EngineError::Limit(m) | EngineError::Engine(m) => m.clone(),
            EngineError::Dead => "session is dead".into(),
            EngineError::WrongThread => "wrong thread".into(),
        }
    }
}
