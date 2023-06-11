use axum::{routing::get, Router};
use once_cell::sync::Lazy;
use prometheus::{default_registry, register_int_counter_vec, IntCounterVec, TextEncoder};

pub(crate) static WARNING_LOG_COUNTER: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "grasshopper_warning_logs",
        "Number of WARN level logs emitted",
        &["script"]
    )
    .unwrap()
});

pub(crate) static ERROR_LOG_COUNTER: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "grasshopper_error_logs",
        "Number of ERROR level logs emitted",
        &["script"]
    )
    .unwrap()
});

pub(crate) async fn metrics_server() -> eyre::Result<()> {
    let router = Router::new().route(
        "/metrics",
        get(|| async {
            let encoder = TextEncoder::new();
            let mut buffer = String::with_capacity(4 << 10);
            encoder
                .encode_utf8(&default_registry().gather(), &mut buffer)
                .unwrap();
            buffer
        }),
    );

    axum::Server::bind(&"0.0.0.0:8000".parse().unwrap())
        .serve(router.into_make_service())
        .await?;
    Ok(())
}
