use eyre::Context;
use reqwest::{header::HeaderName, Body, Url};

use crate::event::RequestPayload;

pub(crate) fn sign(payload: RequestPayload) -> eyre::Result<RequestPayload> {
    let mut req = reqwest::Request::new(
        payload.method,
        Url::parse(&payload.url).context("cannot parse URL")?,
    );
    if let Some(body) = payload.body {
        *req.body_mut() = Some(Body::from(body));
    }
    if let Some(headers) = payload.headers {
        for (k, v) in headers {
            req.headers_mut().insert(
                HeaderName::from_bytes(k.as_bytes()).context("invalid header name")?,
                v.parse().unwrap(),
            );
        }
    }
    exqwest::sign_request(&mut req)?;
    Ok(RequestPayload {
        url: req.url().to_string(),
        method: req.method().clone(),
        body: req
            .body()
            .map(|x| String::from_utf8_lossy(x.as_bytes().expect("body is a stream")).into_owned()),
        headers: Some(
            req.headers()
                .into_iter()
                .map(|(k, v)| (k.to_string(), v.to_str().unwrap().to_string()))
                .collect(),
        ),
        sign: None,
        primary_only: payload.primary_only,
    })
}
