#[repr(transparent)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OmacyStatus(pub i32);

impl OmacyStatus {
    #[allow(non_upper_case_globals)]
    pub const Ok: Self = Self(0);
    #[allow(non_upper_case_globals)]
    pub const Null: Self = Self(1);
    #[allow(non_upper_case_globals)]
    pub const InvalidArg: Self = Self(2);
    #[allow(non_upper_case_globals)]
    pub const Limit: Self = Self(3);
    #[allow(non_upper_case_globals)]
    pub const Engine: Self = Self(4);
    #[allow(non_upper_case_globals)]
    pub const Panic: Self = Self(5);
    #[allow(non_upper_case_globals)]
    pub const Dead: Self = Self(6);
    #[allow(non_upper_case_globals)]
    pub const WrongThread: Self = Self(7);

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
            _ => c"OMACY_UNKNOWN",
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
            EngineError::InvalidArg(m) | EngineError::Limit(m) | EngineError::Engine(m) => {
                m.clone()
            }
            EngineError::Dead => "session is dead".into(),
            EngineError::WrongThread => "wrong thread".into(),
        }
    }
}
