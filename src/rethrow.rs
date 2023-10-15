use std::panic::{catch_unwind, UnwindSafe};

extern "C-unwind" {
    pub(crate) fn throw_to_lua() -> !;
}

pub(crate) fn rethrow_cpp<T>(func: impl FnOnce() -> T + UnwindSafe) -> T {
    match catch_unwind(func) {
        Ok(x) => x,
        Err(_) => {
            unsafe { throw_to_lua() };
        }
    }
}
