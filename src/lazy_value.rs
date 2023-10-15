use std::{
    borrow::Borrow,
    collections::HashMap,
    ffi::{c_char, CString},
    fmt::{Debug, Display},
    hash::Hash,
    iter::Peekable,
    ops::Range,
    rc::Rc,
};

use grasshopper_macros::lua_export;
use serde::{de::Visitor, Deserialize, Deserializer};
use serde_json::value::RawValue;
use tracing::{debug, error};

use crate::{
    rethrow::{rethrow_cpp, throw_to_lua},
    LuaStr,
};

#[derive(Clone)]
pub enum LazyStr {
    Reused {
        origin: Rc<str>,
        range: Range<usize>,
    },
    Owned(String),
}

impl Debug for LazyStr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        Debug::fmt(self.as_str(), f)
    }
}

impl PartialEq for LazyStr {
    fn eq(&self, other: &Self) -> bool {
        self.as_str() == other.as_str()
    }
}

impl Eq for LazyStr {}

impl LazyStr {
    fn as_str(&self) -> &str {
        match self {
            LazyStr::Reused { origin, range } => {
                std::str::from_utf8(&origin.as_bytes()[range.clone()]).unwrap()
            }
            LazyStr::Owned(s) => s.as_str(),
        }
    }
}

impl Borrow<str> for LazyStr {
    fn borrow(&self) -> &str {
        self.as_str()
    }
}

impl Hash for LazyStr {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.as_str().hash(state);
    }
}

impl PartialOrd for LazyStr {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.as_str().partial_cmp(other.as_str())
    }
}

impl Ord for LazyStr {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_str().cmp(other.as_str())
    }
}

impl Display for LazyStr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Debug)]
pub enum LazyValue {
    Null,
    Bool(bool),
    Number(f64),
    String(LazyStr),
    Array(Vec<LazyStr>),
    Object(HashMap<LazyStr, LazyStr>),
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LazyValueKind {
    Null = 0,
    Bool = 1,
    Number = 2,
    String = 3,
    Array = 4,
    Object = 5,
}

impl Display for LazyValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LazyValue::Null => write!(f, "null"),
            LazyValue::Bool(x) => write!(f, "boolean({x})"),
            LazyValue::Number(x) => write!(f, "number({x})"),
            LazyValue::String(s) => write!(f, "string({s})"),
            LazyValue::Array(x) => write!(f, "array({} elements)", x.len()),
            LazyValue::Object(x) => write!(f, "object({} elements)", x.len()),
        }
    }
}

impl LazyValue {
    #[lua_export]
    pub extern "C-unwind" fn kind(&self) -> LazyValueKind {
        match self {
            LazyValue::Null => LazyValueKind::Null,
            LazyValue::Bool(_) => LazyValueKind::Bool,
            LazyValue::Number(_) => LazyValueKind::Number,
            LazyValue::String(_) => LazyValueKind::String,
            LazyValue::Array(_) => LazyValueKind::Array,
            LazyValue::Object(_) => LazyValueKind::Object,
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn as_bool(&self) -> bool {
        match self {
            LazyValue::Bool(x) => *x,
            other => panic!("expected bool, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn as_number(&self) -> f64 {
        match self {
            LazyValue::Number(x) => *x,
            other => panic!("expected number, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn as_string(&self) -> *mut c_char {
        match self {
            LazyValue::String(x) => {
                let s = CString::new(x.as_str()).unwrap();
                s.into_raw()
            }
            other => panic!("expected string, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn get_array_element(&self, index: u32) -> Box<Self> {
        match self {
            LazyValue::Array(x) => {
                let s = x[usize::try_from(index).expect("array index overflow")].as_str();
                let v = serde_json::from_str::<LazyValue>(s).expect("cannot parse array element");
                Box::new(v)
            }
            other => panic!("expected array, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn get_array_length(&self) -> u32 {
        match self {
            LazyValue::Array(x) => u32::try_from(x.len()).expect("array length overflow"),
            other => panic!("expected array, got {other}"),
        }
    }

    #[lua_export]
    pub unsafe extern "C-unwind" fn has_object_element(&self, key: *const u8, len: u32) -> bool {
        let key = unsafe {
            std::str::from_utf8(std::slice::from_raw_parts(
                key,
                usize::try_from(len).expect("key length overflow"),
            ))
            .expect("cannot read key")
        };

        match self {
            LazyValue::Object(x) => x.contains_key(key),
            other => panic!("expected object, got {other}"),
        }
    }

    #[lua_export]
    pub unsafe extern "C-unwind" fn get_object_element(
        &self,
        key: *const u8,
        len: u32,
    ) -> Box<Self> {
        let key = unsafe {
            std::str::from_utf8(std::slice::from_raw_parts(
                key,
                usize::try_from(len).expect("key length overflow"),
            ))
            .expect("cannot read key")
        };
        Box::new(self.get_object_element_str(key))
    }

    #[lua_export]
    pub(crate) fn get_object_element_str(&self, key: &str) -> Self {
        match self {
            LazyValue::Object(x) => {
                let s = x[key].as_str();
                serde_json::from_str::<LazyValue>(s).expect("cannot parse array element")
            }
            other => panic!("expected object, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn get_object_length(&self) -> u32 {
        match self {
            LazyValue::Object(x) => u32::try_from(x.len()).expect("object cardinality overflow"),
            other => panic!("expected object, got {other}"),
        }
    }

    #[lua_export]
    pub extern "C-unwind" fn free_value(self: Box<Self>) {}

    #[lua_export]
    pub(crate) extern "C-unwind" fn iter_elements(&self) -> Box<LazyValueObjectIterator> {
        match self {
            LazyValue::Object(x) => Box::new(LazyValueObjectIterator {
                map: x.clone().into_iter().peekable(),
            }),
            other => panic!("expected object, got {other}"),
        }
    }

    #[lua_export]
    pub(crate) extern "C-unwind" fn debug_print(&self) {
        debug!(?self);
    }
}

pub struct LazyValueObjectIterator {
    map: Peekable<std::collections::hash_map::IntoIter<LazyStr, LazyStr>>,
}

impl LazyValueObjectIterator {
    #[no_mangle]
    pub extern "C-unwind" fn has_next(&mut self) -> bool {
        self.map.peek().is_some()
    }

    #[no_mangle]
    pub extern "C-unwind" fn next_pair(&mut self) -> Box<LazyValueObjectPair> {
        let item = self.map.next();
        rethrow_cpp(|| {
            let (key, value) = item.expect("unexpected end of iterator");
            let key = Box::new(LazyValue::String(key));
            let value = Some(Box::new(
                serde_json::from_str(value.as_str()).expect("cannot parse value"),
            ));
            Box::new(LazyValueObjectPair { key, value })
        })
    }

    #[lua_export]
    pub extern "C-unwind" fn free_iterator(self: Box<Self>) {}
}

#[repr(C)]
pub struct LazyValueObjectPair {
    key: Box<LazyValue>,
    value: Option<Box<LazyValue>>,
}

impl LazyValueObjectPair {
    #[no_mangle]
    pub extern "C-unwind" fn pair_value(&mut self) -> Box<LazyValue> {
        let value = self.value.take();
        rethrow_cpp(|| value.expect("value already taken"))
    }

    #[lua_export]
    pub extern "C-unwind" fn free_pair(self: Box<Self>) {}
}

struct LazyValueVisitor(Rc<str>);

impl LazyValueVisitor {
    fn reuse(&self, s: &str) -> LazyStr {
        let start = self.0.as_ptr() as usize;
        let end = start + self.0.len();
        if (start..end).contains(&(s.as_ptr() as usize))
            && (start..=end).contains(&(s.as_ptr() as usize + s.len()))
        {
            let range = (s.as_ptr() as usize - start)..(s.as_ptr() as usize + s.len() - start);
            LazyStr::Reused {
                origin: Rc::clone(&self.0),
                range,
            }
        } else {
            LazyStr::Owned(s.to_string())
        }
    }
}

impl<'de> Visitor<'de> for LazyValueVisitor {
    type Value = LazyValue;

    #[inline]
    fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        formatter.write_str("an JSON-originated value")
    }

    #[inline]
    fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Number(v as f64))
    }

    #[inline]
    fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Number(v as f64))
    }

    #[inline]
    fn visit_f64<E>(self, v: f64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Number(v))
    }

    #[inline]
    fn visit_bool<E>(self, v: bool) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Bool(v))
    }

    #[inline]
    fn visit_none<E>(self) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Null)
    }

    #[inline]
    fn visit_unit<E>(self) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::Null)
    }

    #[inline]
    fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        Deserialize::deserialize(deserializer)
    }

    #[inline]
    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::String(self.reuse(v)))
    }

    #[inline]
    fn visit_borrowed_str<E>(self, v: &'de str) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Ok(LazyValue::String(self.reuse(v)))
    }

    #[inline]
    fn visit_string<E>(self, _: String) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        Err(serde::de::Error::custom(
            "a string never originates from the JSON payload",
        ))
    }

    #[inline]
    fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::SeqAccess<'de>,
    {
        let mut v = Vec::new();

        while let Some(elem) = seq.next_element::<&RawValue>()? {
            v.push(self.reuse(elem.get()));
        }

        Ok(LazyValue::Array(v))
    }

    #[inline]
    fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::MapAccess<'de>,
    {
        let mut hashmap = HashMap::new();
        while let Some((key, value)) = map.next_entry::<&str, &RawValue>()? {
            hashmap.insert(self.reuse(key), self.reuse(value.get()));
        }

        Ok(LazyValue::Object(hashmap))
    }
}

impl<'de> Deserialize<'de> for LazyValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let r: &RawValue = Deserialize::deserialize(deserializer)?;
        let s = Rc::from(String::from(r.get()));
        serde_json::Deserializer::from_str(&Rc::clone(&s))
            .deserialize_any(LazyValueVisitor(s))
            .map_err(serde::de::Error::custom)
    }
}

#[no_mangle]
pub extern "C-unwind" fn decode(s: LuaStr) -> Box<LazyValue> {
    unsafe {
        Box::new(serde_json::from_str(s.as_str()).unwrap_or_else(|e| {
            error!(
                error = Box::new(e) as Box<dyn std::error::Error>,
                "cannot parse JSON"
            );
            throw_to_lua();
        }))
    }
}
