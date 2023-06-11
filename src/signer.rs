use std::{
    collections::{BTreeMap, HashMap},
    env,
};

use base64::Engine;
use eyre::Context;
use hmac::{Hmac, Mac};
use jwt::SignWithKey;
use reqwest::{Method, Url};
use serde::Serialize;
use sha2::{Digest, Sha256, Sha512};
use uuid::Uuid;

use crate::lua_interface::RequestPayload;

fn timestamp_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis()
}

fn sign_bithumb(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    let api_key = env::var("BITHUMB_API_KEY").context("cannot get BITHUMB_API_KEY")?;
    let api_secret = env::var("BITHUMB_API_SECRET").context("cannot get BITHUMB_API_SECRET")?;

    let url = Url::parse(&payload.url).context("cannot parse URL")?;
    let nonce = timestamp_millis();
    let endpoint = url.path();
    let query_string = payload.body.clone().unwrap_or_default().replace('/', "%2F");
    let encode_target = format!("{}\x00{}\x00{}", endpoint, query_string, nonce);

    let mut mac = Hmac::<Sha512>::new_from_slice(api_secret.as_bytes())
        .context("cannot create HMAC instance")?;
    mac.update(encode_target.as_bytes());
    let encrypted = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();

    let base64 = base64::engine::general_purpose::STANDARD.encode(encrypted);

    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }
    let headers = payload.headers.as_mut().unwrap();
    headers.insert("Accept".to_string(), "application/json".to_string());
    headers.insert(
        "Content-Type".to_string(),
        "application/x-www-form-urlencoded".to_string(),
    );
    headers.insert("Api-Key".to_string(), api_key);
    headers.insert("Api-Nonce".to_string(), nonce.to_string());
    headers.insert("Api-Sign".to_string(), base64);

    Ok(payload)
}

fn sign_bybit(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    const RECV_WINDOW: u32 = 5000;

    let api_key = env::var("BYBIT_API_KEY").context("cannot get BYBIT_API_KEY")?;
    let api_secret = env::var("BYBIT_API_SECRET").context("cannot get BYBIT_API_SECRET")?;

    let url = Url::parse(&payload.url).context("cannot parse URL")?;
    let timestamp = timestamp_millis();

    let param_str = match payload.method.as_str() {
        "GET" => {
            let query_string = url.query().unwrap_or("");
            format!("{timestamp}{api_key}{RECV_WINDOW}{query_string}")
        }
        "POST" => {
            format!(
                "{timestamp}{api_key}{RECV_WINDOW}{}",
                payload.body.as_deref().unwrap_or_default()
            )
        }
        other => eyre::bail!("unsupported method {other}"),
    };

    let mut mac = Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())
        .context("cannot create HMAC instance")?;
    mac.update(param_str.as_bytes());
    let encrypted = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();

    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }
    let headers = payload.headers.as_mut().unwrap();
    headers.insert("X-BAPI-API-KEY".to_string(), api_key);
    headers.insert("X-BAPI-TIMESTAMP".to_string(), timestamp.to_string());
    headers.insert("X-BAPI-SIGN".to_string(), encrypted);
    headers.insert("X-BAPI-RECV-WINDOW".to_string(), RECV_WINDOW.to_string());

    Ok(payload)
}

fn sign_binance(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    const RECV_WINDOW: u32 = 3000;

    let api_key = env::var("BINANCE_API_KEY").context("cannot get BINANCE_API_KEY")?;
    let api_secret = env::var("BINANCE_API_SECRET").context("cannot get BINANCE_API_SECRET")?;

    let url = Url::parse(&payload.url).context("cannot parse URL")?;
    let timestamp = timestamp_millis();

    let query_str = url.query().unwrap_or_default().to_string();
    let mut param_str = query_str.clone() + payload.body.as_deref().unwrap_or_default();
    if query_str.is_empty() {
        payload.url += &format!("?recvWindow={RECV_WINDOW}&timestamp={timestamp}");
    } else {
        payload.url += &format!("&recvWindow={RECV_WINDOW}&timestamp={timestamp}");
    }

    if param_str.is_empty() {
        param_str += &format!("recvWindow={RECV_WINDOW}&timestamp={timestamp}");
    } else {
        param_str += &format!("&recvWindow={RECV_WINDOW}&timestamp={timestamp}");
    }

    let mut mac = Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())
        .context("cannot create HMAC instance")?;
    mac.update(param_str.as_bytes());
    let encrypted = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();

    payload.url += &format!("&signature={encrypted}");

    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }
    let headers = payload.headers.as_mut().unwrap();
    headers.insert("X-MBX-APIKEY".to_string(), api_key);

    Ok(payload)
}

fn sign_upbit(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    let api_key = env::var("UPBIT_API_KEY").context("cannot get UPBIT_API_KEY")?;
    let api_secret = env::var("UPBIT_API_SECRET").context("cannot get UPBIT_API_SECRET")?;

    let params = if payload.method == Method::GET {
        let url = Url::parse(&payload.url).context("cannot parse URL")?;
        url.query_pairs()
            .map(|(x, y)| (x.to_string(), serde_json::Value::String(y.to_string())))
            .collect::<BTreeMap<_, _>>()
    } else if let Some(body) = &payload.body {
        serde_json::from_str::<BTreeMap<String, serde_json::Value>>(body)?
    } else {
        BTreeMap::new()
    };

    let auth = if params.is_empty() {
        #[derive(Serialize)]
        struct JwtPayload {
            access_key: String,
            nonce: String,
        }

        let jwt_payload = JwtPayload {
            access_key: api_key,
            nonce: Uuid::new_v4().to_string(),
        };
        jwt_payload.sign_with_key(&Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())?)?
    } else {
        #[derive(Serialize)]
        struct JwtPayload {
            access_key: String,
            nonce: String,
            query_hash: String,
            query_hash_alg: &'static str,
        }
        let hash_payload = params
            .into_iter()
            .flat_map(|(k, v)| match v {
                serde_json::Value::Array(x) => x
                    .into_iter()
                    .map(|x| {
                        if let serde_json::Value::String(s) = x {
                            format!("{k}[]={s}")
                        } else {
                            panic!("unexpected JSON value {x:?}")
                        }
                    })
                    .collect::<Vec<_>>(),
                serde_json::Value::String(s) => vec![format!("{k}={s}")],
                serde_json::Value::Number(x) => vec![format!("{k}={x}")],
                other => panic!("unexpected JSON value {other:?}"),
            })
            .collect::<Vec<_>>()
            .join("&");
        let mut hasher = Sha512::new();
        hasher.update(hash_payload.as_bytes());
        let hash = hasher
            .finalize()
            .as_slice()
            .iter()
            .map(|x| format!("{x:02x}"))
            .collect::<String>();

        let jwt_payload = JwtPayload {
            access_key: api_key,
            nonce: Uuid::new_v4().to_string(),
            query_hash: hash,
            query_hash_alg: "SHA512",
        };
        jwt_payload.sign_with_key(&Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())?)?
    };

    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }

    let headers = payload.headers.as_mut().unwrap();
    headers.insert("Authorization".to_string(), format!("Bearer {auth}"));

    Ok(payload)
}

fn sign_okx(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    const RECV_WINDOW: u32 = 3000;

    let api_key = env::var("OKX_API_KEY").context("cannot get OKX_API_KEY")?;
    let api_secret = env::var("OKX_API_SECRET").context("cannot get OKX_API_SECRET")?;
    let api_passphrase = env::var("OKX_API_PASSPHRASE").context("cannot get OKX_API_PASSPHRASE")?;

    let url = Url::parse(&payload.url).context("cannot parse URL")?;
    let path_and_query = {
        let path = url.path();
        if let Some(query) = url.query() {
            format!("{path}?{query}")
        } else {
            path.to_string()
        }
    };
    let now = chrono::Utc::now();
    let timestamp = now.to_rfc3339_opts(chrono::SecondsFormat::Millis, true);

    let hmac_payload = timestamp.clone()
        + payload.method.as_ref()
        + &path_and_query
        + payload.body.as_deref().unwrap_or_default();
    let mut mac = Hmac::<Sha256>::new_from_slice(api_secret.as_bytes())
        .context("cannot create HMAC instance")?;
    mac.update(hmac_payload.as_bytes());
    let encrypted = mac.finalize().into_bytes();
    let encoded = base64::engine::general_purpose::STANDARD.encode(encrypted);

    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }

    let exp_time = now.timestamp_millis() + RECV_WINDOW as i64;

    let headers = payload.headers.as_mut().unwrap();
    headers.insert("OK-ACCESS-KEY".to_string(), api_key);
    headers.insert("OK-ACCESS-SIGN".to_string(), encoded);
    headers.insert("OK-ACCESS-TIMESTAMP".to_string(), timestamp);
    headers.insert("OK-ACCESS-PASSPHRASE".to_string(), api_passphrase);
    headers.insert("expTime".to_string(), exp_time.to_string());

    Ok(payload)
}

fn sign_gateio(mut payload: RequestPayload) -> eyre::Result<RequestPayload> {
    let api_key = env::var("GATEIO_API_KEY").context("cannot get GATEIO_API_KEY")?;
    let api_secret = env::var("GATEIO_API_SECRET").context("cannot get GATEIO_API_SECRET")?;

    let url = Url::parse(&payload.url).context("cannot parse URL")?;

    let now = chrono::Utc::now().timestamp();

    let mut payload_hasher = Sha512::new();
    payload_hasher.update(payload.body.as_deref().unwrap_or_default().as_bytes());
    let payload_hash = payload_hasher
        .finalize()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();

    let hmac_payload = format!(
        "{}\n{}\n{}\n{}\n{}",
        payload.method,
        url.path(),
        url.query().unwrap_or_default(),
        payload_hash,
        now
    );
    let mut mac = Hmac::<Sha512>::new_from_slice(api_secret.as_bytes())
        .context("cannot create HMAC instance")?;
    mac.update(hmac_payload.as_bytes());
    let encrypted = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();
    if payload.headers.is_none() {
        payload.headers = Some(HashMap::new());
    }

    let headers = payload.headers.as_mut().unwrap();
    headers.insert("KEY".to_string(), api_key);
    headers.insert("Timestamp".to_string(), now.to_string());
    headers.insert("Sign".to_string(), encrypted);

    Ok(payload)
}

pub(crate) fn sign(payload: RequestPayload, signer: &str) -> eyre::Result<RequestPayload> {
    match signer {
        "bithumb" => sign_bithumb(payload),
        "bybit" => sign_bybit(payload),
        "binance" => sign_binance(payload),
        "upbit" => sign_upbit(payload),
        "okx" => sign_okx(payload),
        "gateio" => sign_gateio(payload),
        sgn => Err(eyre::eyre!("unknown signer {sgn}")),
    }
}
