use std::{
    fs,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{atomic::Ordering, Arc, Mutex},
    thread,
    time::Duration,
};

use eyre::Context;
use tracing::{error, info, info_span};

use crate::{fetch_aggregator::Session, lua_interface::LuaInstance, TERMINATE};

pub fn run_test() {
    let lua = LuaInstance::new(None, "test".to_string()).expect("cannot create Lua instance");
    lua.inner()
        .load(&fs::read_to_string("scripts/test.lua").expect("cannot load scripts/test.lua"))
        .exec()
        .unwrap_or_else(|e| panic!("test failed: {e}"))
}

pub struct Runtime {
    script: String,
    script_name: String,
    session: Arc<Mutex<Session>>,
}

impl Runtime {
    pub fn new(script_name: String, session: Session) -> eyre::Result<Self> {
        if script_name == "test" {
            eyre::bail!("test.lua should not be loaded by the runtime");
        }

        let script = fs::read_to_string(format!("scripts/{script_name}.lua"))
            .context(format!("cannot read script: scripts/{script_name}.lua"))?;
        Ok(Self {
            script,
            script_name,
            session: Arc::new(Mutex::new(session)),
        })
    }

    /// Runs the script in the background thread and returns the handle of it.
    pub fn run(self) -> thread::JoinHandle<()> {
        thread::spawn(move || loop {
            let span = info_span!("run", %self.script_name);
            let _enter = span.enter();
            // For early LuaInstance::drop
            {
                if TERMINATE.load(Ordering::Relaxed) {
                    break;
                }
                let lua = match LuaInstance::new(
                    Some(Arc::clone(&self.session)),
                    self.script_name.clone(),
                ) {
                    Ok(lua) => lua,
                    Err(e) => {
                        if let Some(e) = e.downcast_ref::<mlua::Error>() {
                            error!("cannot create lua instance: {e}");
                            thread::sleep(Duration::from_secs(1));
                            continue;
                        }
                        thread::sleep(Duration::from_secs(1));
                        panic!("cannot create lua instance: {e}");
                    }
                };
                self.session
                    .lock()
                    .expect("lock poisoned")
                    .kill_all_fetchers();
                let callback = || lua.inner().load(&self.script).call(());
                match catch_unwind(AssertUnwindSafe(callback)) {
                    Ok(Ok(())) => {
                        info!("script returned without an error");
                        break;
                    }
                    Ok(Err(err)) => error!(%err, "script returned error"),
                    Err(_) => error!(script_name=%self.script_name, "script panicked"),
                }
            }
            thread::sleep(Duration::from_secs(1));
        })
    }
}
