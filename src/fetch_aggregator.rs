use std::{
    collections::{hash_map::Entry, HashMap},
    sync::{Arc, Mutex},
    time::Duration,
};

use tokio::{
    runtime::Handle,
    sync::{mpsc, oneshot},
};
use tracing::{info, instrument};

use crate::{
    fetcher::Fetcher,
    lua_interface::{RequestPayload, ResponsePayload},
};

pub struct FetchAggregator {
    fetchers: Mutex<HashMap<RequestPayload, Fetcher>>,
}

impl FetchAggregator {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            fetchers: Mutex::new(HashMap::new()),
        })
    }

    /// Must be called in a tokio context
    pub fn new_session(self: &Arc<Self>) -> Session {
        let (tx, rx) = mpsc::channel(32);
        Session {
            fetch_aggregator: Arc::clone(self),
            tx,
            rx: Arc::new(Mutex::new(rx)),
            tokio_handle: Handle::current(),
            kill_txs: Vec::new(),
        }
    }
}

pub struct Session {
    fetch_aggregator: Arc<FetchAggregator>,
    tx: mpsc::Sender<Option<ResponsePayload>>,
    rx: Arc<Mutex<mpsc::Receiver<Option<ResponsePayload>>>>,
    tokio_handle: Handle,
    kill_txs: Vec<oneshot::Sender<()>>,
}

impl Session {
    #[instrument(skip(self))]
    pub fn subscribe(&mut self, payload: RequestPayload, period: Duration) -> eyre::Result<()> {
        let mut fetchers = self
            .fetch_aggregator
            .fetchers
            .lock()
            .expect("fetchers lock poisoned");
        let _guard = self.tokio_handle.enter();

        let ktx = match fetchers.entry(payload.clone()) {
            Entry::Occupied(x) => x.get().subscribe(self.tx.clone()),
            Entry::Vacant(x) => x
                .insert(Fetcher::new(payload, period))
                .subscribe(self.tx.clone()),
        };

        self.kill_txs.push(ktx);

        info!("new subscription created");

        Ok(())
    }

    pub fn next(&self) -> Option<ResponsePayload> {
        self.rx
            .lock()
            .expect("lock poisoned")
            .blocking_recv()
            .flatten()
    }

    pub fn kill_all_fetchers(&mut self) {
        for ktx in self.kill_txs.drain(..) {
            ktx.send(()).expect("cannot kill fetcher bridge task");
        }
    }
}
