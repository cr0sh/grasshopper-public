use std::env::var;

use anchor_client::anchor_lang::AccountDeserialize;
use base64::prelude::*;
use exqwest::{serializable, ResponseExt, ValueExt};
use raydium_amm_v3::{
    libraries::{liquidity_math, tick_math},
    states::{PersonalPositionState, PoolState},
};
use reqwest::Client;
use rust_decimal::prelude::*;
use rust_decimal::Decimal;
use serde_json::json;
use solana_sdk::pubkey::Pubkey;

pub async fn fetch_personal_position(
    client: &Client,
    personal_position: Pubkey,
) -> eyre::Result<PersonalPositionState> {
    let rpc = var("SOLANA_RPC_URL")?;
    let params = [
        serde_json::Value::String(personal_position.to_string()),
        json!({
            "commitment": "processed",
            "encoding": "base64"
        }),
    ];
    let (data, _) = client
        .post(rpc)
        .json(&serializable! {
            jsonrpc: "2.0",
            id: 1,
            method: "getAccountInfo",
            params,
        })
        .send()
        .await?
        .error_for_status()?
        .json_value()
        .await?
        .query::<(String, String)>("result.value.data")?;
    let decoded = BASE64_STANDARD.decode(&data)?;
    Ok(PersonalPositionState::try_deserialize(&mut &*decoded)?)
}

pub async fn fetch_pool(client: &Client, pool: Pubkey) -> eyre::Result<PoolState> {
    let rpc = var("SOLANA_RPC_URL")?;
    let params = [
        serde_json::Value::String(pool.to_string()),
        json!({
            "commitment": "processed",
            "encoding": "base64"
        }),
    ];
    let (data, _) = client
        .post(rpc)
        .json(&serializable! {
            jsonrpc: "2.0",
            id: 1,
            method: "getAccountInfo",
            params,
        })
        .send()
        .await?
        .error_for_status()?
        .json_value()
        .await?
        .query::<(String, String)>("result.value.data")?;
    let decoded = BASE64_STANDARD.decode(&data)?;
    Ok(PoolState::try_deserialize(&mut &*decoded)?)
}

pub async fn fetch_position_value(
    client: &Client,
    personal_position: &PersonalPositionState,
) -> eyre::Result<(Decimal, Decimal)> {
    let pool_state = fetch_pool(client, personal_position.pool_id).await?;
    let sqrt_ratio_current_x64 = pool_state.sqrt_price_x64;
    let sqrt_ratio_a_x64 = tick_math::get_sqrt_price_at_tick(personal_position.tick_lower_index)?;
    let sqrt_ratio_b_x64 = tick_math::get_sqrt_price_at_tick(personal_position.tick_upper_index)?;

    let (amount_a, amount_b) = amounts_from_liquidity(
        sqrt_ratio_current_x64,
        sqrt_ratio_a_x64,
        sqrt_ratio_b_x64,
        personal_position.liquidity,
        true,
    );

    let amount_a = Decimal::from_u64(amount_a).ok_or_else(|| eyre::eyre!("amount_a overflow"))?
        / Decimal::TEN.powi(pool_state.mint_decimals_0.into());
    let amount_b = Decimal::from_u64(amount_b).ok_or_else(|| eyre::eyre!("amount_b overflow"))?
        / Decimal::TEN.powi(pool_state.mint_decimals_1.into());

    Ok((amount_a, amount_b))
}

fn amounts_from_liquidity(
    sqrt_ratio_current_x64: u128,
    mut sqrt_ratio_a_x64: u128,
    mut sqrt_ratio_b_x64: u128,
    liquidity: u128,
    round_up: bool,
) -> (u64, u64) {
    if sqrt_ratio_a_x64 > sqrt_ratio_b_x64 {
        std::mem::swap(&mut sqrt_ratio_a_x64, &mut sqrt_ratio_b_x64);
    }

    if sqrt_ratio_current_x64 <= sqrt_ratio_a_x64 {
        (
            liquidity_math::get_delta_amount_0_unsigned(
                sqrt_ratio_a_x64,
                sqrt_ratio_b_x64,
                liquidity,
                round_up,
            )
            .unwrap(),
            0,
        )
    } else if sqrt_ratio_current_x64 < sqrt_ratio_b_x64 {
        (
            liquidity_math::get_delta_amount_0_unsigned(
                sqrt_ratio_current_x64,
                sqrt_ratio_b_x64,
                liquidity,
                round_up,
            )
            .unwrap(),
            liquidity_math::get_delta_amount_1_unsigned(
                sqrt_ratio_a_x64,
                sqrt_ratio_current_x64,
                liquidity,
                round_up,
            )
            .unwrap(),
        )
    } else {
        (
            0,
            liquidity_math::get_delta_amount_1_unsigned(
                sqrt_ratio_a_x64,
                sqrt_ratio_b_x64,
                liquidity,
                round_up,
            )
            .unwrap(),
        )
    }
}
