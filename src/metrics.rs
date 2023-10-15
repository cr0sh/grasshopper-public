use axum::{routing::get, Router};
use grasshopper_macros::lua_export;
use once_cell::sync::Lazy;
use prometheus::{
    default_registry, exponential_buckets, register_histogram_vec, register_int_counter_vec,
    HistogramVec, IntCounterVec, TextEncoder,
};
use rust_decimal::Decimal;

use crate::{lua_decimal::FfiDecimal, LuaStr};

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

pub(crate) static ELAPSED_HISTOGRAM: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "grasshopper_elapsed",
        "Milliseconds of elapsed time of each event loop invocation",
        &["script"],
        exponential_buckets(0.05, 1.075, 99).unwrap(),
    )
    .unwrap()
});

pub(crate) static WALL_ELAPSED_HISTOGRAM: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "grasshopper_wall_elapsed",
        "Milliseconds of wall-elapsed time of each event loop invocation",
        &["script"],
        exponential_buckets(0.1, 1.2, 50).unwrap(),
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

#[lua_export]
pub extern "C-unwind" fn report_timings(
    strategy_name: LuaStr,
    elapsed: FfiDecimal,
    wall_elapsed: FfiDecimal,
) {
    let strategy_name = unsafe { strategy_name.as_str() };
    let elapsed = Decimal::from(elapsed);
    let wall_elapsed = Decimal::from(wall_elapsed);
    ELAPSED_HISTOGRAM
        .with_label_values(&[strategy_name])
        .observe(f64::try_from(elapsed).expect("cannot convert Decimal to f64"));
    WALL_ELAPSED_HISTOGRAM
        .with_label_values(&[strategy_name])
        .observe(f64::try_from(wall_elapsed).expect("cannot convert Decimal to f64"));
}
