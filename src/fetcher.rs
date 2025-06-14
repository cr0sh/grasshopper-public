use std::{
    env::var,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use tokio::{
    sync::{oneshot, Notify},
    time::interval,
};
use tracing::{debug, error};

use crate::event::{RequestPayload, ResponsePayload};

pub struct Fetcher {
    last_data: Arc<Mutex<Option<ResponsePayload>>>,
    notify: Arc<Notify>,
    kill: Option<oneshot::Sender<()>>,
}

impl Fetcher {
    pub fn new(payload: RequestPayload, period: Duration) -> Self {
        let last_data = Arc::new(Mutex::new(None));
        let notify = Arc::new(Notify::new());
        let (ktx, krx) = oneshot::channel();
        tokio::spawn(Self::task(
            payload,
            Arc::clone(&last_data),
            Arc::clone(&notify),
            krx,
            period,
        ));
        Self {
            last_data,
            notify,
            kill: Some(ktx),
        }
    }

    async fn task(
        payload: RequestPayload,
        last_data: Arc<Mutex<Option<ResponsePayload>>>,
        notify: Arc<Notify>,
        mut krx: oneshot::Receiver<()>,
        period: Duration,
    ) {
        let mut local_address_index = 0usize;
        let local_addresses = var("GRASSHOPPER_LOCAL_ADDRS")
            .ok()
            .map(|x| x.split(',').map(String::from).collect::<Vec<_>>());
        let clients = if payload.primary_only {
            vec![reqwest::Client::new()]
        } else if let Some(local_addresses) = local_addresses {
            local_addresses
                .into_iter()
                .map(|x| {
                    reqwest::ClientBuilder::new()
                        .local_address(Some(x.parse().expect("invalid local address")))
                        .build()
                        .expect("cannot build reqwest client")
                })
                .collect()
        } else {
            vec![reqwest::Client::new()]
        };
        let mut interval = interval(period);
        #[cfg(feature = "raydium")]
        let mut raydium_personal_state: Option<
            raydium_amm_v3::states::PersonalPositionState,
        > = None;
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
            match req.url().host_str() {
                Some("millis.local") => {
                    let now = SystemTime::UNIX_EPOCH
                        .elapsed()
                        .expect("timestamp before the Unix epoch")
                        .as_millis();
                    let payload = ResponsePayload::from_string(&payload.url, now.to_string());
                    *last_data.lock().unwrap() = Some(payload);
                    notify.notify_waiters();
                    continue;
                }
                #[cfg(feature = "raydium")]
                Some("raydium-position.local") => {
                    use solana_sdk::pubkey::Pubkey;
                    local_address_index = local_address_index.overflowing_add(1).0;
                    let client = &clients[local_address_index % clients.len()];
                    let personal_state = match raydium_personal_state {
                        Some(ref t) => t,
                        None => {
                            let personal_position_address = req
                                .url()
                                .path()
                                .trim_start_matches('/')
                                .parse::<Pubkey>()
                                .expect("invalid personal position pubkey");
                            let state = match crate::raydium::fetch_personal_position(
                                client,
                                personal_position_address,
                            )
                            .await
                            {
                                Ok(state) => state,
                                Err(e) => {
                                    error!(
                                        error = Box::<dyn std::error::Error>::from(e),
                                        "cannot fetch initial position"
                                    );
                                    continue;
                                }
                            };
                            raydium_personal_state = Some(state);
                            raydium_personal_state.as_ref().unwrap()
                        }
                    };
                    let (value_0, value_1) =
                        match crate::raydium::fetch_position_value(client, personal_state).await {
                            Ok(x) => x,
                            Err(e) => {
                                error!(
                                    error = Box::<dyn std::error::Error>::from(e),
                                    "cannot fetch pool state"
                                );
                                continue;
                            }
                        };
                    let payload = ResponsePayload::from_string(
                        &payload.url,
                        format!(r#"["{value_0}","{value_1}"]"#),
                    );
                    *last_data.lock().unwrap() = Some(payload);
                    notify.notify_waiters();
                    continue;
                }
                _ => (),
            }
            local_address_index = local_address_index.overflowing_add(1).0;
            let resp = tokio::select! {
                r = clients[local_address_index % clients.len()].execute(req) => r,
                _ = &mut krx => break,
            };

            match resp {
                Ok(x) => {
                    if !x.status().is_success() {
                        error!(%payload.url, %payload.method, status=%x.status(), "request failed");
                    }
                    let url = x.url().clone();
                    let payload = match ResponsePayload::new(&payload.url, payload.env_suffix, x)
                        .await
                    {
                        Ok(x) => x,
                        Err(e) => {
                            error!(%url, error = Box::from(e) as Box<dyn std::error::Error>, "cannot read response");
                            continue;
                        }
                    };
                    *last_data.lock().unwrap() = Some(payload);
                    notify.notify_waiters();
                }
                Err(err) => error!(%err, "cannot send request"),
            }
        }
    }

    /// Returns [`None`] if the sender side of the channel has been dropped.
    pub async fn next(self: Arc<Self>) -> Option<ResponsePayload> {
        loop {
            if let Some(x) = self.last_data.lock().unwrap().take() {
                break Some(x);
            }
            self.notify.notified().await;
        }
    }
}

impl Drop for Fetcher {
    fn drop(&mut self) {
        let _ = self.kill.take().unwrap().send(());
    }
}
