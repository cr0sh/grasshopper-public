use std::{
    collections::HashMap,
    hash::Hash,
    num::NonZeroU64,
    ptr::null_mut,
    rc::Rc,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use eyre::Context;
use grasshopper_macros::lua_export;
use reqwest::{header::HeaderName, Client, Method, Response, Url};
use serde::{Deserialize, Deserializer};
use tokio::{
    runtime::Runtime,
    signal::unix::{signal, SignalKind},
    sync::{mpsc, Mutex},
};
use tracing::info;

use crate::{
    fetch_aggregator::{FetchAggregator, DEFAULT_FETCH_AGGREGATOR},
    LuaStr, RUNTIME_HANDLE,
};

static QUEUE_TX: Mutex<Option<mpsc::Sender<Event>>> = Mutex::const_new(None);
static QUEUE_RX: Mutex<Option<mpsc::Receiver<Event>>> = Mutex::const_new(None);
static LAST_TOKEN: AtomicU64 = AtomicU64::new(1);

pub(crate) fn install(rt: &Runtime) {
    let (tx, rx) = mpsc::channel(256);
    *QUEUE_TX.blocking_lock() = Some(tx);
    *QUEUE_RX.blocking_lock() = Some(rx);
    rt.spawn(async {
        let mut sigterm = signal(SignalKind::terminate()).expect("cannot create signal receiver");
        let mut sigint = signal(SignalKind::interrupt()).expect("cannot create signal receiver");
        tokio::select! {
            _ = sigterm.recv() => {
                info!("SIGTERM");
            },
            _ = sigint.recv() => {
                info!("SIGINT");
            },
        }
        QUEUE_TX
            .lock()
            .await
            .as_mut()
            .unwrap()
            .send(Event::new(
                "signal",
                ResponsePayload::new_terminator(),
                None,
            ))
            .await
            .expect("event queue closed");
    });
}

pub(crate) async fn restart() {
    QUEUE_TX
        .lock()
        .await
        .as_mut()
        .unwrap()
        .send(Event::new("signal", ResponsePayload::new_restart(), None))
        .await
        .expect("event queue closed");
}

#[repr(C)]
pub struct Event {
    kind: *const u8,
    kind_len: usize,
    kind_cap: usize,
    response_payload: *const ResponsePayload,
    token: Option<NonZeroU64>,
}

impl Event {
    pub fn new(kind: &str, payload: ResponsePayload, token: Option<NonZeroU64>) -> Self {
        let kind = kind.to_string();
        let (kind, kind_len, kind_cap) = {
            let ptr = kind.as_ptr();
            let len = kind.len();
            let cap = kind.capacity();
            std::mem::forget(kind);
            (ptr, len, cap)
        };
        let response_payload = Rc::new(payload);
        Self {
            kind,
            kind_len,
            kind_cap,
            response_payload: Rc::into_raw(response_payload),
            token,
        }
    }

    #[no_mangle]
    pub extern "C-unwind" fn get_response_payload(self) -> *const ResponsePayload {
        unsafe { Rc::increment_strong_count(self.response_payload) };
        self.response_payload
    }

    #[no_mangle]
    pub extern "C-unwind" fn free_event(self) {
        unsafe { ResponsePayload::free_response_payload(self.response_payload) };
    }
}

unsafe impl Send for Event {}

#[derive(Clone, Debug, Deserialize)]
pub struct RequestPayload {
    pub(crate) url: String,
    #[serde(deserialize_with = "deserialize_method")]
    pub(crate) method: Method,
    pub(crate) body: Option<String>,
    pub(crate) headers: Option<HashMap<String, String>>,
    pub(crate) sign: Option<bool>,
    #[serde(default)]
    pub(crate) primary_only: bool,
}

fn deserialize_method<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Method, D::Error> {
    let method = <&str>::deserialize(deserializer)?;
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

#[lua_export]
pub extern "C-unwind" fn subscribe_rest_events(payload: LuaStr, period_ms: f64) {
    let payload = serde_json::from_str(unsafe { payload.as_str() }).expect("cannot parse payload");
    RUNTIME_HANDLE.lock().unwrap().as_ref().unwrap().spawn(
        DEFAULT_FETCH_AGGREGATOR
            .get_or_init(FetchAggregator::new)
            .subscribe(payload, Duration::from_secs_f64(period_ms / 1000.0)),
    );
}

#[lua_export]
pub extern "C-unwind" fn next_event() -> Event {
    let rt = RUNTIME_HANDLE.lock().unwrap();
    let rt = rt.as_ref().unwrap();
    rt.block_on(async move {
        let mut guard = QUEUE_RX.lock().await;
        let queue = guard.as_mut().unwrap();
        if let Ok(x) = queue.try_recv() {
            x
        } else {
            fn process_payload(payload: Option<ResponsePayload>) -> Event {
                Event::new(
                    "fetcher",
                    payload.unwrap_or(ResponsePayload::new_terminator()),
                    None,
                )
            }
            let n = DEFAULT_FETCH_AGGREGATOR
                .get_or_init(FetchAggregator::new)
                .next();
            tokio::select! {
                x = queue.recv() => x.expect("event queue closed"),
                payload = n => process_payload(payload),
            }
        }
    })
}

#[lua_export]
pub extern "C-unwind" fn send_payload(payload: LuaStr) -> NonZeroU64 {
    fn new_client() -> Client {
        Client::builder()
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(2))
            .http2_keep_alive_timeout(Duration::from_secs(2))
            .http2_keep_alive_interval(Duration::from_secs(5))
            .http2_keep_alive_while_idle(true)
            .build()
            .unwrap()
    }

    thread_local! {
        static CLIENT: Client = new_client();
    }

    let token = LAST_TOKEN.fetch_add(1, Ordering::Relaxed);
    let token = NonZeroU64::new(token).unwrap();
    let payload: RequestPayload =
        serde_json::from_str(unsafe { payload.as_str() }).expect("cannot parse payload");
    CLIENT.with(|x| {
        let x = x.clone();
        RUNTIME_HANDLE
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .spawn(async move {
                let fut = async {
                    let request_url = payload.url.to_string();
                    let resp = x.execute(payload.into_async_reqwest()?).await?;
                    let payload = ResponsePayload::new(&request_url, resp).await?;
                    Ok::<_, eyre::Report>(payload)
                };
                let payload = fut.await.unwrap_or(ResponsePayload::new_error());
                let ev = Event::new("send_response", payload, Some(token));
                QUEUE_TX
                    .lock()
                    .await
                    .as_mut()
                    .unwrap()
                    .send(ev)
                    .await
                    .expect("channel closed");
            })
    });
    token
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
    pub(crate) fn into_async_reqwest(self) -> eyre::Result<reqwest::Request> {
        if self.sign == Some(true) {
            return crate::signer::sign(self)
                .context("cannot sign payload")?
                .into_async_reqwest();
        }
        let parsed = Url::parse(&self.url)?;
        let mut req = reqwest::Request::new(self.method.clone(), parsed);
        if let Some(body) = self.body {
            *req.body_mut() = Some(reqwest::Body::from(body));
        } else if self.method != Method::GET {
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

#[repr(C)]
#[derive(Debug)]
pub struct ResponsePayload {
    url: *mut u8,
    url_len: usize,
    url_cap: usize,
    content: *mut u8,
    content_len: usize,
    content_cap: usize,
    status: u16,
    /// Responses on [`send()`] calls: indicates a network error or non-2xx response has been
    /// ocurred.
    ///
    /// Responses on fetch subscriptions: indicates a non-2xx response.
    error: bool,
    restart: bool,
    terminate: bool,
}

impl ResponsePayload {
    pub async fn new(request_url: &str, resp: Response) -> eyre::Result<Self> {
        let mut url = request_url.to_string();
        let error = !resp.status().is_success();
        let status = resp.status().as_u16();
        let mut content = resp.bytes().await?.to_vec();
        let (url, url_len, url_cap) = unsafe {
            let slice = url.as_bytes_mut();
            let ptr = slice.as_mut_ptr();
            let len = slice.len();
            let cap = url.capacity();
            std::mem::forget(url);
            (ptr, len, cap)
        };
        let (content, content_len, content_cap) = {
            let ptr = content.as_mut_ptr();
            let len = content.len();
            let cap = content.capacity();
            std::mem::forget(content);
            (ptr, len, cap)
        };
        Ok(ResponsePayload {
            url,
            url_len,
            url_cap,
            content,
            content_len,
            content_cap,
            status,
            error,
            restart: false,
            terminate: false,
        })
    }

    pub const fn new_terminator() -> Self {
        Self {
            url: null_mut(),
            url_len: 0,
            url_cap: 0,
            content: null_mut(),
            content_len: 0,
            content_cap: 0,
            status: 0,
            error: false,
            restart: false,
            terminate: true,
        }
    }

    pub const fn new_restart() -> Self {
        Self {
            url: null_mut(),
            url_len: 0,
            url_cap: 0,
            content: null_mut(),
            content_len: 0,
            content_cap: 0,
            status: 0,
            error: true,
            restart: true,
            terminate: false,
        }
    }

    pub const fn new_error() -> Self {
        Self {
            url: null_mut(),
            url_len: 0,
            url_cap: 0,
            content: null_mut(),
            content_len: 0,
            content_cap: 0,
            status: 0,
            error: true,
            restart: false,
            terminate: false,
        }
    }

    #[lua_export]
    pub unsafe extern "C-unwind" fn free_response_payload(this: *const Self) {
        unsafe { Rc::decrement_strong_count(this) }
    }
}

unsafe impl Send for ResponsePayload {}

impl Drop for ResponsePayload {
    fn drop(&mut self) {
        unsafe {
            if self.url_cap > 0 {
                let url = String::from_raw_parts(self.url, self.url_len, self.url_cap);
                drop(url);
            }
            if self.content_cap > 0 {
                let content = Vec::from_raw_parts(self.content, self.content_len, self.content_cap);
                drop(content);
            }
        }
    }
}
