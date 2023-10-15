use std::{
    collections::HashMap,
    env::var,
    time::{Duration, Instant},
};

use axum::{extract::Path, routing::post, Router};
use eyre::Context;
use once_cell::sync::Lazy;
use reqwest::Client;
use tokio::sync::Mutex;
use tracing::{debug, instrument};

#[instrument]
pub(crate) async fn notice(message: &str) -> eyre::Result<()> {
    static LAST_CALL: Mutex<Option<Instant>> = Mutex::const_new(None);
    static CLIENT: Lazy<Client> = Lazy::new(Client::new);

    let sid = var("TWILIO_API_KEY").context("cannot get TWILIO_API_KEY")?;
    let token = var("TWILIO_API_SECRET").context("cannot get TWILIO_API_SECRET")?;
    let target = var("TWILIO_CALL_TARGET").context("cannot get TWILIO_CALL_TARGET")?;
    let number = var("TWILIO_NOTICE_NUMBER").context("cannot get TWILIO_NOTICE_NUMBER")?;
    let webhook = var("TWILIO_WEBHOOK_ADDRESS").context("cannot get TWILIO_WEBHOOK_ADDRESS")?;

    let mut last_call = LAST_CALL.lock().await;

    let message = message.replace(' ', "-");

    if last_call
        .map(|x| x.elapsed() >= Duration::from_secs(120))
        .unwrap_or(true)
    {
        let resp = CLIENT
            .post(format!(
                "https://api.twilio.com/2010-04-01/Accounts/{sid}/Calls.json"
            ))
            .form(
                &[
                    ("Url", format!("http://{webhook}/{message}")),
                    ("From", number),
                    ("To", target),
                ]
                .into_iter()
                .collect::<HashMap<&'static str, String>>(),
            )
            .basic_auth(sid, Some(token))
            .send()
            .await
            .context("cannot invoke request to Twilio")?;
        let text = resp.text().await?;
        debug!(resp = text, "Twilio webhook succeeded");
        *last_call = Some(Instant::now());
    }

    Ok(())
}

#[instrument]
pub(crate) async fn emergency(message: &str) -> eyre::Result<()> {
    static LAST_CALL: Mutex<Option<Instant>> = Mutex::const_new(None);
    static CLIENT: Lazy<Client> = Lazy::new(Client::new);

    let sid = var("TWILIO_API_KEY").context("cannot get TWILIO_API_KEY")?;
    let token = var("TWILIO_API_SECRET").context("cannot get TWILIO_API_SECRET")?;
    let target = var("TWILIO_CALL_TARGET").context("cannot get TWILIO_CALL_TARGET")?;
    let number = var("TWILIO_EMERGENCY_NUMBER").context("cannot get TWILIO_EMERGENCY_NUMBER")?;
    let webhook = var("TWILIO_WEBHOOK_ADDRESS").context("cannot get TWILIO_WEBHOOK_ADDRESS")?;

    let mut last_call = LAST_CALL.lock().await;

    let message = message.replace(' ', "-");

    if last_call
        .map(|x| x.elapsed() >= Duration::from_secs(30))
        .unwrap_or(true)
    {
        let resp = CLIENT
            .post(format!(
                "https://api.twilio.com/2010-04-01/Accounts/{sid}/Calls.json"
            ))
            .form(
                &[
                    ("Url", format!("http://{webhook}/{message}")),
                    ("From", number),
                    ("To", target),
                ]
                .into_iter()
                .collect::<HashMap<&'static str, String>>(),
            )
            .basic_auth(sid, Some(token))
            .send()
            .await
            .context("cannot invoke request to Twilio")?;
        let text = resp.text().await?;
        debug!(resp = text, "Twilio webhook succeeded");
        *last_call = Some(Instant::now());
    }

    Ok(())
}

#[instrument]
fn inline_xml(say: &str) -> String {
    let say = say.replace('-', " ");
    debug!(say);
    format!(
        r#"
<Response>
<Say voice="woman">{say}</Say>
</Response>
    "#
    )
}

pub(crate) async fn axum_server() -> eyre::Result<()> {
    let router = Router::new().route(
        "/:message",
        post(|Path(message): Path<String>| async move { inline_xml(&message) }),
    );
    axum::Server::bind(&"0.0.0.0:8282".parse().unwrap())
        .serve(router.into_make_service())
        .await?;
    Ok(())
}
