use std::{
    env::{set_var, var},
    ffi::{c_char, CString},
    fs,
    path::Path,
    slice,
    str::FromStr,
    sync::{Mutex, Once},
    thread::JoinHandle,
    time::Duration,
};

use event::{install, restart};
use grasshopper_macros::lua_export;
use metrics::{metrics_server, ERROR_LOG_COUNTER, WARNING_LOG_COUNTER};
use notify_debouncer_full::{
    new_debouncer,
    notify::{RecursiveMode, Watcher},
    DebouncedEvent,
};
use tokio::{runtime::Handle, sync::oneshot};
use tracing::{debug, error};
use tracing_subscriber::{prelude::*, EnvFilter};

mod borrow_cell;
pub mod event;
mod fetch_aggregator;
mod fetcher;
pub mod lazy_value;
pub mod logging;
pub mod lua_decimal;
mod math_utils;
pub mod metrics;
mod rethrow;
mod signer;
mod twilio;

static INITIALIZE_ONCE: Once = Once::new();

static RUNTIME_HANDLE: Mutex<Option<Handle>> = Mutex::new(None);
static RUNTIME_JOIN_HANDLE: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);
static RUNTIME_KILL: Mutex<Option<oneshot::Sender<()>>> = Mutex::new(None);

#[lua_export]
pub extern "C-unwind" fn initialize() {
    INITIALIZE_ONCE.call_once(|| {
        if var("RUST_LOG").is_err() {
            set_var("RUST_LOG", "info,grasshopper=debug");
        }

        let file_appender = tracing_appender::rolling::daily("logs", "grasshopper.log");
        let (nb_file, _guard) = tracing_appender::non_blocking(file_appender);
        std::mem::forget(_guard);

        tracing_subscriber::Registry::default()
            .with(
                tracing_subscriber::fmt::Layer::default()
                    .with_level(true)
                    .with_filter(EnvFilter::from_default_env()),
            )
            .with(
                tracing_subscriber::fmt::Layer::default()
                    .with_level(true)
                    .with_ansi(false)
                    .with_writer(nb_file)
                    .with_filter(EnvFilter::from_str("info,grasshopper=debug").unwrap()),
            )
            .init();

        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |panic_info| {
            tracing_panic::panic_hook(panic_info);
            prev_hook(panic_info);
        }));

        exqwest::initialize_credentials();

        let (tx, handle) = std::sync::mpsc::channel();
        let (kill_tx, kill_rx) = oneshot::channel();

        let rt_handle = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();

            rt.spawn(async {
                if let Err(err) = metrics_server().await {
                    error!(%err, "cannot start metrics server");
                }
            });

            rt.spawn(async {
                if let Err(err) = twilio::axum_server().await {
                    error!(%err, "cannot start twilio webhook server");
                }
            });
            install(&rt);

            let handle = rt.handle().clone();

            let mut debouncer = new_debouncer(
                Duration::from_secs(1),
                None,
                move |res: Result<Vec<DebouncedEvent>, _>| match res {
                    Ok(evs) => {
                        for ev in evs {
                            let kind = ev.kind;
                            let paths = &ev.paths;
                            let paths = paths
                                .iter()
                                .map(|x| x.as_os_str().to_str().unwrap_or("<invalid path>"))
                                .collect::<Vec<_>>();
                            let mut should_restart = false;
                            for path in paths {
                                match kind {
                                    notify_debouncer_full::notify::EventKind::Create(_) => (),
                                    notify_debouncer_full::notify::EventKind::Modify(_) => (),
                                    notify_debouncer_full::notify::EventKind::Remove(_) => (),
                                    _ => continue,
                                };
                                if path.ends_with(".lua") {
                                    debug!(?kind, path, "file change notified");
                                    should_restart = true
                                }
                            }
                            if should_restart {
                                handle.block_on(restart());
                            }
                        }
                    }
                    Err(errors) => {
                        for e in errors {
                            error!(
                                error = Box::new(e) as Box<dyn std::error::Error>,
                                "watch failure"
                            )
                        }
                    }
                },
            )
            .expect("cannot create notify debouncer");
            debouncer
                .watcher()
                .watch(Path::new("library"), RecursiveMode::Recursive)
                .expect("cannot watch library");
            debouncer
                .watcher()
                .watch(Path::new("scripts"), RecursiveMode::Recursive)
                .expect("cannot watch scripts");
            std::mem::forget(debouncer);

            let _ = tx.send(rt.handle().clone());

            rt.block_on(kill_rx).unwrap();
        });

        *RUNTIME_JOIN_HANDLE.lock().unwrap() = Some(rt_handle);
        *RUNTIME_KILL.lock().unwrap() = Some(kill_tx);
        *RUNTIME_HANDLE.lock().unwrap() = Some(handle.recv().unwrap());
    })
}

#[lua_export]
pub extern "C-unwind" fn deinitialize() {
    RUNTIME_KILL
        .lock()
        .unwrap()
        .take()
        .unwrap()
        .send(())
        .unwrap();
    RUNTIME_JOIN_HANDLE
        .lock()
        .unwrap()
        .take()
        .unwrap()
        .join()
        .unwrap();
}

#[no_mangle]
pub extern "C" fn list_strategies() -> *mut c_char {
    let mut dir = fs::read_dir("scripts").expect("cannot read directory");
    let mut names = Vec::new();
    while let Ok(Some(entry)) = dir.next().transpose() {
        let filename = entry
            .path()
            .file_stem()
            .expect("file without a name")
            .to_string_lossy()
            .to_string();
        if filename == "test" {
            continue;
        }
        if filename.contains('.') {
            continue;
        }
        names.push(filename);
    }

    let s = CString::new(serde_json::to_string(&names).unwrap()).unwrap();
    s.into_raw()
}

#[lua_export]
pub extern "C" fn reset_metrics(filename: LuaStr) {
    let filename = unsafe { filename.as_str() };

    if !filename.is_empty() && filename.is_ascii() {
        WARNING_LOG_COUNTER.with_label_values(&[filename]).reset();
        ERROR_LOG_COUNTER.with_label_values(&[filename]).reset();
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LuaStr {
    ptr: *const u8,
    len: usize,
}

impl LuaStr {
    pub(crate) unsafe fn as_str<'a>(self) -> &'a str {
        let s = slice::from_raw_parts(self.ptr, self.len);
        std::str::from_utf8(s)
            .map_err(|e| {
                let lossy = String::from_utf8_lossy(s).to_string();
                debug!(lossy);
                e
            })
            .expect("string is not a valid UTF-8 sequence")
    }
}

#[no_mangle]
pub extern "C-unwind" fn free_string(ptr: *mut c_char) {
    unsafe { std::mem::drop(CString::from_raw(ptr as *mut _)) }
}
