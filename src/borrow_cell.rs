use std::{
    cell::Cell,
    panic::{catch_unwind, AssertUnwindSafe},
    process::abort,
};

#[allow(dead_code)]
pub(crate) trait BorrowCell<T> {
    fn borrowed<R>(&self, func: impl FnOnce(&T) -> R) -> R;
}

impl<T> BorrowCell<T> for Cell<Option<T>> {
    fn borrowed<R>(&self, func: impl FnOnce(&T) -> R) -> R {
        let value = self.take().expect("empty Cell<Option<T>>");
        // unwind safety: we abort immediately if catch_unwind catches a panic
        let ret = catch_unwind(AssertUnwindSafe(|| func(&value)));
        self.set(Some(value));
        match ret {
            Ok(x) => x,
            Err(_) => abort(),
        }
    }
}
