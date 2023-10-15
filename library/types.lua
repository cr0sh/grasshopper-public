---@class Decimal
---@operator add(Decimal): Decimal
---@operator sub(Decimal): Decimal
---@operator mul(Decimal): Decimal
---@operator div(Decimal): Decimal
---@operator mod(Decimal): Decimal
---@operator pow(Decimal): Decimal
---@operator unm: Decimal
---@field min fun(self: Decimal, other: Decimal): Decimal
---@field max fun(self: Decimal, other: Decimal): Decimal
---@field abs fun(self: Decimal): Decimal
---@field floor_to_decimals fun(self: Decimal, decimals: integer): Decimal
---@field ceil_to_decimals fun(self: Decimal, decimals: integer): Decimal
---@field round_to_decimals fun(self: Decimal, decimals: integer): Decimal

---@alias MarketType "spot" | "swap"
---@alias Market string

---@class Orderbook
---@field bids OrderbookEntry[]
---@field asks OrderbookEntry[]

---@class OrderbookEntry
---@field price Decimal
---@field quantity Decimal

---@class Balance: {[string]:BalanceEntry}

---@class BalanceEntry
---@field free Decimal
---@field locked Decimal
---@field total Decimal
---@field debt Decimal | nil

---@class Position: {[string]:Decimal}

---@class Request
---@field url string
---@field method "get" | "post" | "delete" | "put"
---@field body string | nil
---@field headers {[string]:string} | nil
---@field sign string | nil
---@field primary_only boolean | nil

---@class Order
---@field price Decimal | nil
---@field amount Decimal
---@field id string

---@class Exchange
---@field subscribe_orderbook fun(market: Market, params: table | nil): Extractor<Orderbook>
---@field subscribe_balance fun(market_type: MarketType, params: table | nil): Extractor<Balance>
---@field subscribe_position nil | fun(market_type: MarketType, params: table | nil): Extractor<Position>
---@field subscribe_orders fun(market: Market, params: table | nil): Extractor<Order[]>
---@field limit_order fun(market: Market, price: Decimal, amount: Decimal, params: table | nil): Order
---@field market_order fun(market: Market, amount: Decimal, params: table | nil): Order
---@field cancel_order fun(market: Market, order: Order, params: table | nil)
