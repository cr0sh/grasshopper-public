use std::{
    process::exit,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use eyre::Context;
use fetch_aggregator::FetchAggregator;
use metrics::metrics_server;
use once_cell::sync::Lazy;
use tokio::{
    fs,
    signal::unix::{signal, SignalKind},
    sync::Notify,
};
use tracing::{error, info, warn};

mod fetch_aggregator;
mod fetcher;
mod lua_interface;
mod lua_runtime;
mod metrics;
mod signer;

pub(crate) static TERMINATE: AtomicBool = AtomicBool::new(false);
pub(crate) static TERMINATE_NOTIFY: Lazy<Notify> = Lazy::new(Notify::new);

#[tokio::main(flavor = "multi_thread")]
async fn main() -> eyre::Result<()> {
    tracing_subscriber::fmt::init();

    tokio::spawn(async {
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

        TERMINATE.store(true, Ordering::SeqCst);
        TERMINATE_NOTIFY.notify_waiters();

        tokio::time::sleep(Duration::from_secs(10)).await;
        warn!("timeout; force exiting without cleanup");
        exit(-1);
    });

    lua_runtime::run_test();

    tokio::spawn(async {
        if let Err(err) = metrics_server().await {
            error!(%err, "cannot start metrics server");
        }
    });

    let fetch_aggregator = FetchAggregator::new();

    let mut runtimes = Vec::new();
    let mut dir = fs::read_dir("scripts").await?;
    while let Ok(Some(entry)) = dir.next_entry().await {
        let filename = entry
            .path()
            .file_stem()
            .expect("file without a name")
            .to_string_lossy()
            .to_string();
        if filename == "test" {
            continue;
        }
        let handle = lua_runtime::Runtime::new(filename, fetch_aggregator.new_session())
            .context("cannot instantiate runtime")?
            .run();
        runtimes.push(handle)
    }

    for runtime in runtimes {
        runtime.join().expect("Lua runtime panicked");
    }

    Ok(())
}
