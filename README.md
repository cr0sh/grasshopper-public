# Grasshopper

Grasshopper is a Rust-based Lua runtime for cryptocurrency trading. It offers these features:

- Periodic, asynchronous HTTP polling (`gh.subscribe()`)
    - Event loop based on subscription: see [`library/router.lua`](https://github.com/cr0sh/grasshopper-public/blob/master/library/router.lua)
    - Note: On-demand HTTP requests are performed synchronously
- Native `Decimals` support(`gh.decimal()`) - don't panic on handling precision and arithmetic errors like on CCXT!
- Type annotations based on lua-language-server(aka sumneko-lua): see [`library/types.lua`](https://github.com/cr0sh/grasshopper-public/blob/master/library/types.lua)
- Supports six cryptocurrency exchanges: Binance, Bithumb, Bybit, Gate.io, OKX, UPbit. More to come!
- Logging experience with [tracing](https://crates.io/crates/tracing) bindings on lua (`gh.info`, `gh.debug`, `gh.warn`, ...)
- Supports execution of multiple strategies at once (which are traced individually with tracing)

## Release strategy

I maintain this on my private repository and periodically synchronize to here. Feel free to ping me with the issue tracker if you want to use this library and it seems to be too outdated.

## How to use

Write down your own strategy(multiple strategies supported) on `scripts/` and it will be the entrypoint of the runtime. You can import modules from `library/` with `require()`, e.g. `local binance = require("binance");`

# Special Thanks

Thanks to [khvzak](https://github.com/khvzak) for the amazing [`mlua`](https://github.com/khvzak/mlua) crate, the ultimate Lua bindings for Rust.

Thanks to [actboy168](https://github.com/actboy168) for the [`json.lua`](https://github.com/actboy168/json.lua) library.

Thanks to [the CCXT team](https://github.com/ccxt) for inspiration of this project.
