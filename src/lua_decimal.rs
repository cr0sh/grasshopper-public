use std::{
    borrow::{Borrow, Cow},
    ffi::{c_char, CString},
    time::Instant,
};

use crate::{math_utils, LuaStr};
use grasshopper_macros::lua_export;
use rust_decimal::{Decimal, MathematicalOps};
use tracing::error;

#[repr(C)]
pub struct FfiDecimal {
    raw: [u8; 16],
}

impl From<Decimal> for FfiDecimal {
    #[inline]
    fn from(value: Decimal) -> Self {
        Self {
            raw: value.serialize(),
        }
    }
}

impl From<FfiDecimal> for Decimal {
    #[inline]
    fn from(value: FfiDecimal) -> Self {
        Decimal::deserialize(value.raw)
    }
}

#[lua_export]
pub extern "C-unwind" fn decimal_from_string(s: LuaStr) -> FfiDecimal {
    let mut s = Cow::<str>::Borrowed(unsafe { s.as_str() });
    if s.contains(',') {
        s = Cow::Owned(s.replace(',', ""));
    }
    s.parse::<Decimal>()
        .or_else(|_| Decimal::from_scientific(s.borrow()))
        .map_err(|e| {
            error!(str = s.into_owned(), "cannot parse decimal string");
            e
        })
        .expect("cannot parse string into Decimal")
        .into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_to_string(x: FfiDecimal) -> *mut c_char {
    CString::new(Decimal::from(x).to_string())
        .unwrap()
        .into_raw() as *mut _
}

#[lua_export]
pub extern "C-unwind" fn decimal_add(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    (x + y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_sub(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    (x - y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_mul(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    (x * y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_div(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    (x / y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_mod(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    (x % y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_pow(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    x.powd(y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_unm(x: FfiDecimal) -> FfiDecimal {
    (-Decimal::from(x)).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_eq(x: FfiDecimal, y: FfiDecimal) -> bool {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    x == y
}

#[lua_export]
pub extern "C-unwind" fn decimal_lt(x: FfiDecimal, y: FfiDecimal) -> bool {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    x < y
}

#[lua_export]
pub extern "C-unwind" fn decimal_le(x: FfiDecimal, y: FfiDecimal) -> bool {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    x <= y
}

#[lua_export]
pub extern "C-unwind" fn decimal_abs(x: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    x.abs().into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_ceil_to_decimals(x: FfiDecimal, decimals: i32) -> FfiDecimal {
    math_utils::ceil_to_decimals(Decimal::from(x), decimals).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_floor_to_decimals(x: FfiDecimal, decimals: i32) -> FfiDecimal {
    math_utils::floor_to_decimals(Decimal::from(x), decimals).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_round_to_decimals(x: FfiDecimal, decimals: i32) -> FfiDecimal {
    math_utils::round_to_decimals(Decimal::from(x), decimals).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_max(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    Decimal::max(x, y).into()
}

#[lua_export]
pub extern "C-unwind" fn decimal_min(x: FfiDecimal, y: FfiDecimal) -> FfiDecimal {
    let x = Decimal::from(x);
    let y = Decimal::from(y);
    Decimal::min(x, y).into()
}

#[lua_export]
extern "C-unwind" fn millis() -> FfiDecimal {
    thread_local! {
        static NOW: Instant = Instant::now();
    }
    (Decimal::try_from(NOW.with(|x| x.elapsed().as_nanos())).unwrap() / Decimal::new(1_000_000, 0))
        .into()
}
