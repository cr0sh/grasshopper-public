use std::{sync::Arc, time::Duration};

use tokio::{
    sync::{broadcast, mpsc, oneshot},
    time::interval,
};
use tracing::{debug, error, warn};

use crate::{
    lua_interface::{RequestPayload, ResponsePayload},
    TERMINATE_NOTIFY,
};

pub struct Fetcher {
    sender: Arc<broadcast::Sender<ResponsePayload>>,
    kill: Option<oneshot::Sender<()>>,
}

impl Fetcher {
    pub fn new(payload: RequestPayload, period: Duration) -> Self {
        let (tx, _) = broadcast::channel(32);
        let tx = Arc::new(tx);
        let (ktx, krx) = oneshot::channel();
        tokio::spawn(Self::task(payload, Arc::clone(&tx), krx, period));
        Self {
            sender: tx,
            kill: Some(ktx),
        }
    }

    async fn task(
        payload: RequestPayload,
        sender: Arc<broadcast::Sender<ResponsePayload>>,
        mut krx: oneshot::Receiver<()>,
        period: Duration,
    ) {
        let client = reqwest::Client::new();
        let mut interval = interval(period);
        loop {
            interval.tick().await;
            let payload = payload.clone();
            let req = match payload.clone().into_async_reqwest() {
                Ok(req) => req,
                Err(err) => {
                    error!(%err,"cannot convert request");
                    debug!(?err);
                    continue;
                }
            };
            let resp = tokio::select! {
                r = client.execute(req) => r,
                _ = &mut krx => break,
            };

            match resp {
                Ok(x) => {
                    if !x.status().is_success() {
                        error!(%payload.url, %payload.method, status=%x.status(), "request failed");
                    }
                    let status = x.status().as_u16();
                    let headers = x
                        .headers()
                        .iter()
                        .map(|(k, v)| {
                            (
                                k.to_string(),
                                String::from_utf8_lossy(v.as_bytes()).to_string(),
                            )
                        })
                        .collect();
                    let Ok(content) = x.bytes().await else {
                            error!(%payload.url, "cannot read bytes");
                            continue
                        };
                    let content = String::from_utf8_lossy(&content).to_string();
                    if sender
                        .send(ResponsePayload {
                            url: payload.url.clone(),
                            content,
                            status,
                            headers,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
                Err(err) => error!(%err, "cannot send request"),
            }
        }
    }

    pub fn subscribe(&self, tx: mpsc::Sender<Option<ResponsePayload>>) -> oneshot::Sender<()> {
        let mut receiver = self.sender.subscribe();
        let (ktx, mut krx) = oneshot::channel();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    r = receiver.recv() => {
                        match r {
                            Ok(x) => {
                                let _ = tx.send(Some(x)).await;
                            }
                            Err(e) => warn!(%e),
                        }
                    }
                    _ = &mut krx => return,
                    _ = TERMINATE_NOTIFY.notified() => {
                        let _ = tx.send(None).await;
                    }
                }
            }
        });
        ktx
    }
}

impl Drop for Fetcher {
    fn drop(&mut self) {
        let _ = self.kill.take().unwrap().send(());
    }
}
