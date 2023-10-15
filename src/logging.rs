use std::{cell::Cell, panic::catch_unwind};

use tracing::{debug, error, info, info_span, trace, warn, Instrument};

use crate::{
    metrics::{ERROR_LOG_COUNTER, WARNING_LOG_COUNTER},
    twilio, LuaStr, RUNTIME_HANDLE,
};

thread_local! {
    static SCRIPT_NAME: Cell<Option<Box<str>>> = Cell::new(None);
}

#[no_mangle]
pub extern "C-unwind" fn set_script_name(script_name: LuaStr) {
    let script_name = unsafe { script_name.as_str() };
    if script_name.is_empty() {
        SCRIPT_NAME.with(|x| {
            x.set(None);
        })
    } else {
        SCRIPT_NAME.with(|x| x.set(Some(script_name.to_string().into_boxed_str())))
    }
}

#[no_mangle]
pub extern "C-unwind" fn trace(message: LuaStr) {
    SCRIPT_NAME.with(|x| {
        let script_name = x.take();
        let _ = catch_unwind(|| {
            info_span!("logging", script_name)
                .in_scope(|| trace!("{}", unsafe { message.as_str() }));
        });
        x.set(script_name);
    })
}

#[no_mangle]
pub extern "C-unwind" fn debug(message: LuaStr) {
    SCRIPT_NAME.with(|x| {
        let script_name = x.take();
        let _ = catch_unwind(|| {
            info_span!("logging", script_name)
                .in_scope(|| debug!("{}", unsafe { message.as_str() }));
        });
        x.set(script_name);
    })
}

#[no_mangle]
pub extern "C-unwind" fn info(message: LuaStr) {
    SCRIPT_NAME.with(|x| {
        let script_name = x.take();
        let _ = catch_unwind(|| {
            info_span!("logging", script_name)
                .in_scope(|| info!("{}", unsafe { message.as_str() }));
        });
        x.set(script_name);
    })
}

#[no_mangle]
pub extern "C-unwind" fn warn(message: LuaStr) {
    SCRIPT_NAME.with(|x| {
        let script_name = x.take();
        let _ = catch_unwind(|| {
            info_span!("logging", script_name)
                .in_scope(|| warn!("{}", unsafe { message.as_str() }));
        });
        if let Some(name) = &script_name {
            WARNING_LOG_COUNTER.with_label_values(&[name]).inc();
        }
        x.set(script_name);
    })
}

#[no_mangle]
pub extern "C-unwind" fn error(message: LuaStr) {
    SCRIPT_NAME.with(|x| {
        let script_name = x.take();
        let _ = catch_unwind(|| {
            info_span!("logging", script_name)
                .in_scope(|| error!("{}", unsafe { message.as_str() }));
        });
        if let Some(name) = &script_name {
            ERROR_LOG_COUNTER.with_label_values(&[name]).inc();
        }
        x.set(script_name);
    })
}

#[no_mangle]
pub extern "C-unwind" fn notice(message: LuaStr) {
    let message = unsafe { message.as_str().to_string() };
    RUNTIME_HANDLE.lock().unwrap().as_ref().unwrap().spawn(
        async move {
            if let Err(e) = twilio::notice(&message).await {
                error!(
                    error = Box::from(e) as Box<dyn std::error::Error>,
                    "cannot send message to Twilio"
                );
            }
        }
        .instrument(info_span!("notice_task")),
    );
}

#[no_mangle]
pub extern "C-unwind" fn emergency(message: LuaStr) {
    let message = unsafe { message.as_str().to_string() };
    RUNTIME_HANDLE.lock().unwrap().as_ref().unwrap().spawn(
        async move {
            if let Err(e) = twilio::emergency(&message).await {
                error!(
                    error = Box::from(e) as Box<dyn std::error::Error>,
                    "cannot send message to Twilio"
                );
            }
        }
        .instrument(info_span!("emergency_task")),
    );
}
