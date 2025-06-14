use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{Arc, OnceLock},
    time::Duration,
};

use futures::{future::select_all, FutureExt};
use tokio::sync::Mutex;
use tracing::{info, instrument, warn};

use crate::{
    event::{RequestPayload, ResponsePayload},
    fetcher::Fetcher,
};

pub(crate) static DEFAULT_FETCH_AGGREGATOR: OnceLock<FetchAggregator> = OnceLock::new();

#[derive(Clone)]
pub struct FetchAggregator {
    #[allow(clippy::type_complexity)]
    fetchers: Arc<Mutex<RefCell<HashMap<RequestPayload, Arc<Fetcher>>>>>,
}

impl FetchAggregator {
    pub fn new() -> Self {
        Self {
            fetchers: Arc::new(Mutex::const_new(RefCell::new(HashMap::new()))),
        }
    }

    #[instrument(skip(self))]
    pub async fn subscribe(&self, payload: RequestPayload, period: Duration) {
        let guard = self.fetchers.lock().await;
        let mut fetchers = guard.borrow_mut();

        fetchers.entry(payload.clone()).or_insert_with(|| {
            info!("new subscription created");
            Arc::new(Fetcher::new(payload.clone(), period))
        });
    }

    pub async fn next(&self) -> Option<ResponsePayload> {
        let mut futs = Vec::new();
        {
            let guard = self.fetchers.lock().await;
            let fetchers = guard.borrow();
            for fetcher in fetchers.values() {
                futs.push(Arc::clone(fetcher).next().boxed_local());
            }
        }
        if futs.is_empty() {
            warn!("no subscription to fetch");
            tokio::time::sleep(Duration::from_secs(1)).await;
            return None;
        }
        select_all(futs).await.0
    }
}
