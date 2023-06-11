use std::{
    collections::HashMap,
    convert::Infallible,
    hash::Hash,
    io::Cursor,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use eyre::Context;
use mlua::prelude::*;
use once_cell::sync::Lazy;
use reqwest::{header::HeaderName, Method, Url};
use rust_decimal::{
    prelude::{FromPrimitive, ToPrimitive},
    Decimal, MathematicalOps,
};
use serde::{Deserialize, Deserializer, Serialize};
use tracing::{debug, error, info, trace, warn};

use crate::{
    fetch_aggregator::Session,
    metrics::{ERROR_LOG_COUNTER, WARNING_LOG_COUNTER},
    TERMINATE,
};

use grasshopper::math_utils::{ceil_to_decimals, floor_to_decimals, round_to_decimals};

pub struct LuaInstance(Lua);

impl LuaInstance {
    pub fn new(session: Option<Arc<Mutex<Session>>>, script_name: String) -> eyre::Result<Self> {
        let lua = Lua::new();

        let main_lua = r#"package.path = "./library/?.lua;./json/?.lua""#;
        lua.load(main_lua)
            .exec()
            .context("cannot execute main.lua")?;
        let gh = lua.create_table().context("cannot create gh table")?;

        if let Some(session) = session {
            let sess = Arc::clone(&session);
            let next = lua
                .create_function_mut(move |lua: &Lua, _: ()| {
                    if TERMINATE.load(std::sync::atomic::Ordering::SeqCst) {
                        return Ok(LuaNil);
                    }
                    let userdata = sess.lock().expect("lock poisoned").next().to_lua(lua)?;
                    Ok(userdata)
                })
                .context("cannot create next function")?;
            gh.set("_next", next).context("cannot set gh.next")?;

            let sess = Arc::clone(&session);
            let subscribe = lua
                .create_function_mut(
                    move |lua: &Lua, (payload, period_ms): (LuaValue<'_>, u32)| {
                        let payload: RequestPayload = lua.from_value(payload)?;
                        let period = Duration::from_millis(period_ms as u64);

                        sess.lock()
                            .expect("lock poisoned")
                            .subscribe(payload, period)
                            .map_err(|e| LuaError::RuntimeError(format!("{e:?}")))?;

                        Ok(())
                    },
                )
                .context("cannot create subscribe function")?;
            gh.set("_subscribe", subscribe)
                .context("cannot set gh.subscribe")?;
        }

        let send = lua
            .create_function({
                static CLIENT: Lazy<reqwest::blocking::Client> = Lazy::new(|| {
                    reqwest::blocking::Client::builder()
                        .timeout(Duration::from_millis(1000))
                        .build()
                        .unwrap()
                });
                move |lua, payload: LuaValue| {
                    let payload: RequestPayload = lua.from_value(payload)?;
                    let url = payload.url.clone();
                    let req = payload
                        .into_reqwest()
                        .map_err(|e| LuaError::RuntimeError(format!("{e:?}")))?;
                    let resp = CLIENT.execute(req).map_err(into_lua_error)?;

                    let status = resp.status().as_u16();
                    let headers = resp
                        .headers()
                        .iter()
                        .map(|(k, v)| {
                            (
                                k.to_string(),
                                String::from_utf8_lossy(v.as_bytes()).to_string(),
                            )
                        })
                        .collect();
                    let content = resp.bytes().map_err(into_lua_error)?;
                    Ok(ResponsePayload {
                        url,
                        content: String::from_utf8_lossy(&content).to_string(),
                        status,
                        headers,
                    })
                }
            })
            .context("cannot create send function")?;
        gh.set("_send", send).context("cannot set gh.send")?;
        let millis = lua
            .create_function({
                let start = Instant::now();
                move |_lua: &Lua, ()| {
                    Ok(LuaDecimal(
                        Decimal::try_from(start.elapsed().as_millis()).unwrap(),
                    ))
                }
            })
            .context("cannot create trace function")?;
        gh.set("millis", millis).context("cannot set gh.now")?;

        let micros = lua
            .create_function({
                let start = Instant::now();
                move |_lua: &Lua, ()| {
                    Ok(LuaDecimal(
                        Decimal::try_from(start.elapsed().as_micros()).unwrap(),
                    ))
                }
            })
            .context("cannot create trace function")?;
        gh.set("micros", micros).context("cannot set gh.now")?;

        let trace = lua
            .create_function(|_lua: &Lua, (s,): (Box<str>,)| {
                trace!("{s}");
                Ok(())
            })
            .context("cannot create trace function")?;
        gh.set("trace", trace).context("cannot set gh.trace")?;

        let debug = lua
            .create_function(|_lua: &Lua, (s,): (Box<str>,)| {
                debug!("{s}");
                Ok(())
            })
            .context("cannot create debug function")?;
        gh.set("debug", debug).context("cannot set gh.debug")?;

        let info = lua
            .create_function(|_lua: &Lua, (s,): (Box<str>,)| {
                info!("{s}");
                Ok(())
            })
            .context("cannot create info function")?;
        gh.set("info", info).context("cannot set gh.info")?;

        let warn = lua
            .create_function({
                let script_name = script_name.clone();
                move |_lua: &Lua, (s,): (Box<str>,)| {
                    WARNING_LOG_COUNTER.with_label_values(&[&script_name]).inc();
                    warn!("{s}");
                    Ok(())
                }
            })
            .context("cannot create warn function")?;
        gh.set("warn", warn).context("cannot set gh.warn")?;

        let error = lua
            .create_function(move |_lua: &Lua, (s,): (Box<str>,)| {
                ERROR_LOG_COUNTER.with_label_values(&[&script_name]).inc();
                error!("{s}");
                Ok(())
            })
            .context("cannot create error function")?;
        gh.set("error", error).context("cannot set gh.error")?;

        lua.globals()
            .set("gh", gh)
            .context("cannot set gh global")?;

        let decimal = lua
            .create_function(|_lua: &Lua, (s,): (LuaValue,)| match s {
                LuaValue::Integer(n) => Ok(LuaDecimal(Decimal::from_i64(n).unwrap())),
                LuaValue::Number(n) => Decimal::from_f64(n).map(LuaDecimal).ok_or_else(|| {
                    LuaError::RuntimeError("cannot convert f64 to decimal".to_string())
                }),
                LuaValue::String(s) => s.to_str()?.parse().map(LuaDecimal).map_err(into_lua_error),
                _ => Err(LuaError::RuntimeError(
                    "invalid type for decimal".to_string(),
                )),
            })
            .context("cannot create decimal function")?;
        lua.globals()
            .set("decimal", decimal)
            .context("cannot set decimal")?;

        let atexit = lua.create_table().context("cannot create table")?;
        lua.globals()
            .set("atexit", atexit)
            .context("cannot set atexit")?;

        Ok(Self(lua))
    }

    fn atexit(&mut self) -> eyre::Result<()> {
        let atexit: LuaTable = self
            .0
            .globals()
            .get("atexit")
            .context("cannot get atexit table")?;

        for pair in atexit.pairs::<LuaValue, LuaValue>() {
            let (LuaValue::String(k), LuaValue::Function(v)) = pair? else { continue };
            let Ok(key) = k.to_str() else { continue };
            if let Err::<(), _>(err) = v.call(()) {
                warn!(%err, key, "cannot call atexit handler");
            }
        }
        Ok(())
    }

    pub fn inner(&self) -> &Lua {
        &self.0
    }
}

impl Drop for LuaInstance {
    fn drop(&mut self) {
        debug!("running atexit handler");
        if let Err(err) = self.atexit() {
            warn!(%err, "atexit handler failed");
        }
    }
}

fn into_lua_error(e: impl std::error::Error) -> LuaError {
    LuaError::RuntimeError(e.to_string())
}

fn deserialize_method<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Method, D::Error> {
    let method = String::deserialize(deserializer)?;
    match method.to_lowercase().as_str() {
        "get" => Ok(Method::GET),
        "post" => Ok(Method::POST),
        "put" => Ok(Method::PUT),
        "delete" => Ok(Method::DELETE),
        "patch" => Ok(Method::PATCH),
        _ => Err(serde::de::Error::custom(format!(
            "method {method} is not a valid HTTP method"
        ))),
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct RequestPayload {
    pub(crate) url: String,
    #[serde(deserialize_with = "deserialize_method")]
    pub(crate) method: Method,
    pub(crate) body: Option<String>,
    pub(crate) headers: Option<HashMap<String, String>>,
    pub(crate) sign: Option<String>,
}

impl PartialEq for RequestPayload {
    fn eq(&self, other: &Self) -> bool {
        self.url == other.url && self.method == other.method && self.body == other.body
    }
}

impl Eq for RequestPayload {}

impl Hash for RequestPayload {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.url.hash(state);
        self.method.hash(state);
        self.body.hash(state);
    }
}

impl RequestPayload {
    pub(crate) fn into_reqwest(mut self) -> eyre::Result<reqwest::blocking::Request> {
        if let Some(signer) = self.sign {
            self.sign = None;
            return crate::signer::sign(self, &signer)
                .context("cannot sign payload")?
                .into_reqwest();
        }
        let parsed = Url::parse(&self.url)?;
        let mut req = reqwest::blocking::Request::new(self.method, parsed);
        if let Some(body) = self.body {
            *req.body_mut() = Some(reqwest::blocking::Body::new(Cursor::new(
                body.as_bytes().to_vec(),
            )));
        }
        if let Some(headers) = self.headers {
            for (k, v) in headers {
                req.headers_mut()
                    .insert(HeaderName::from_bytes(k.as_bytes())?, v.parse()?);
            }
        }
        Ok(req)
    }

    pub(crate) fn into_async_reqwest(mut self) -> eyre::Result<reqwest::Request> {
        if let Some(signer) = self.sign {
            self.sign = None;
            return crate::signer::sign(self, &signer)
                .context("cannot sign payload")?
                .into_async_reqwest();
        }
        let parsed = Url::parse(&self.url)?;
        let mut req = reqwest::Request::new(self.method, parsed);
        if let Some(body) = self.body {
            *req.body_mut() = Some(reqwest::Body::wrap_stream(futures::stream::once(
                futures::future::ready(Ok::<_, Infallible>(body.as_bytes().to_vec())),
            )));
        } else {
            req.headers_mut().insert(
                HeaderName::from_bytes("Content-Length".as_bytes()).unwrap(),
                "0".parse().unwrap(),
            );
        }
        if let Some(headers) = self.headers {
            for (k, v) in headers {
                req.headers_mut()
                    .insert(HeaderName::from_bytes(k.as_bytes())?, v.parse()?);
            }
        }
        Ok(req)
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ResponsePayload {
    pub(crate) url: String,
    pub(crate) content: String,
    pub(crate) status: u16,
    pub(crate) headers: HashMap<String, String>,
}

impl<'lua> ToLua<'lua> for ResponsePayload {
    fn to_lua(self, lua: &'lua Lua) -> LuaResult<LuaValue<'lua>> {
        lua.to_value(&self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct LuaDecimal(Decimal);

impl LuaUserData for LuaDecimal {
    fn add_fields<'lua, F: LuaUserDataFields<'lua, Self>>(fields: &mut F) {
        fields.add_field_method_get("value", |_lua: &Lua, user_data| {
            user_data
                .0
                .to_f64()
                .ok_or_else(|| LuaError::RuntimeError("cannot convert decimal to f64".to_string()))
        })
    }

    fn add_methods<'lua, M: LuaUserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_meta_function(
            LuaMetaMethod::Add,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0 + y.0)),
        );
        methods.add_meta_function(
            LuaMetaMethod::Sub,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0 - y.0)),
        );
        methods.add_meta_function(
            LuaMetaMethod::Mul,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0 * y.0)),
        );
        methods.add_meta_function(
            LuaMetaMethod::Div,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0 / y.0)),
        );
        methods.add_meta_function(
            LuaMetaMethod::Mod,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0 % y.0)),
        );
        methods.add_meta_function(
            LuaMetaMethod::Pow,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(LuaDecimal(x.0.powd(y.0))),
        );
        methods.add_meta_function(LuaMetaMethod::Unm, |_lua: &Lua, (x,): (LuaDecimal,)| {
            Ok(LuaDecimal(-x.0))
        });
        methods.add_meta_function(
            LuaMetaMethod::Eq,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(x.0 == y.0),
        );
        methods.add_meta_function(
            LuaMetaMethod::Lt,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(x.0 < y.0),
        );
        methods.add_meta_function(
            LuaMetaMethod::Le,
            |_lua: &Lua, (x, y): (LuaDecimal, LuaDecimal)| Ok(x.0 <= y.0),
        );
        methods.add_meta_function(
            LuaMetaMethod::ToString,
            |_lua: &Lua, (x,): (LuaDecimal,)| Ok(x.0.normalize().to_string()),
        );
        methods.add_method("abs", |_lua: &Lua, x: &LuaDecimal, ()| {
            Ok(LuaDecimal(x.0.abs()))
        });
        methods.add_method(
            "ceil_to_decimals",
            |_lua: &Lua, x: &LuaDecimal, d: LuaNumber| {
                Ok(LuaDecimal(ceil_to_decimals(x.0, d as i32)))
            },
        );
        methods.add_method(
            "floor_to_decimals",
            |_lua: &Lua, x: &LuaDecimal, d: LuaNumber| {
                Ok(LuaDecimal(floor_to_decimals(x.0, d as i32)))
            },
        );
        methods.add_method(
            "round_to_decimals",
            |_lua: &Lua, x: &LuaDecimal, d: LuaNumber| {
                Ok(LuaDecimal(round_to_decimals(x.0, d as i32)))
            },
        );
        methods.add_method("max", |_lua: &Lua, x: &LuaDecimal, y: LuaDecimal| {
            Ok(LuaDecimal(x.0.max(y.0)))
        });
        methods.add_method("min", |_lua: &Lua, x: &LuaDecimal, y: LuaDecimal| {
            Ok(LuaDecimal(x.0.min(y.0)))
        });
    }
}
