use rust_decimal::Decimal;

/// Returns the `floor`-ed value using decimals_to_unit(decimals) and nearest to zero strategy.
///
/// # Examples
///
/// ```
/// # use rust_decimal_macros::dec;
/// # use grasshopper::math_utils::floor_to_decimals;
/// assert_eq!(floor_to_decimals(dec!(1.0001), 3), dec!(1.000));
/// assert_eq!(floor_to_decimals(dec!(1.0011), 3), dec!(1.001));
/// assert_eq!(floor_to_decimals(dec!(-1.0011), 3), dec!(-1.001));
/// assert_eq!(floor_to_decimals(dec!(1.0001), 0), dec!(1));
/// assert_eq!(floor_to_decimals(dec!(-1.0001), 0), dec!(-1));
/// assert_eq!(floor_to_decimals(dec!(1001.0011), -3), dec!(1000));
/// assert_eq!(floor_to_decimals(dec!(-1001.0011), -3), dec!(-1000));
/// ```
pub fn floor_to_decimals(mut value: Decimal, decimals: i32) -> Decimal {
    if decimals >= 0 {
        let multiplier = Decimal::new(
            1,
            decimals.try_into().expect("cannot fit decimals into u32"),
        );
        value /= multiplier;
        if value > Decimal::ZERO {
            value.floor() * multiplier
        } else {
            value.ceil() * multiplier
        }
    } else {
        let multiplier = Decimal::new(
            1,
            (-decimals)
                .try_into()
                .expect("cannot fit -decimals into u32"),
        );
        value *= multiplier;
        if value > Decimal::ZERO {
            value.floor() / multiplier
        } else {
            value.ceil() / multiplier
        }
    }
}

/// Returns the `ceil`-ed value using decimals_to_unit(decimals) and farthest to zero strategy.
///
/// # Examples
///
/// ```
/// # use rust_decimal_macros::dec;
/// # use grasshopper::math_utils::ceil_to_decimals;
/// assert_eq!(ceil_to_decimals(dec!(1.0001), 3), dec!(1.001));
/// assert_eq!(ceil_to_decimals(dec!(1.0011), 3), dec!(1.002));
/// assert_eq!(ceil_to_decimals(dec!(-1.0011), 3), dec!(-1.002));
/// assert_eq!(ceil_to_decimals(dec!(1.0001), 0), dec!(2));
/// assert_eq!(ceil_to_decimals(dec!(-1.0001), 0), dec!(-2));
/// assert_eq!(ceil_to_decimals(dec!(1001.0011), -3), dec!(2000));
/// assert_eq!(ceil_to_decimals(dec!(-1001.0011), -3), dec!(-2000));
/// ```
pub fn ceil_to_decimals(mut value: Decimal, decimals: i32) -> Decimal {
    if decimals >= 0 {
        let multiplier = Decimal::new(
            1,
            decimals.try_into().expect("cannot fit decimals into u32"),
        );
        value /= multiplier;
        if value > Decimal::ZERO {
            value.ceil() * multiplier
        } else {
            value.floor() * multiplier
        }
    } else {
        let multiplier = Decimal::new(
            1,
            (-decimals)
                .try_into()
                .expect("cannot fit -decimals into u32"),
        );
        value *= multiplier;
        if value > Decimal::ZERO {
            value.ceil() / multiplier
        } else {
            value.floor() / multiplier
        }
    }
}

/// Returns the `round`-ed value using decimals_to_unit(decimals) and round to even strategy.
///
/// # Examples
///
/// ```
/// # use rust_decimal_macros::dec;
/// # use grasshopper::math_utils::round_to_decimals;
/// assert_eq!(round_to_decimals(dec!(1.0001), 3), dec!(1.000));
/// assert_eq!(round_to_decimals(dec!(1.0015), 3), dec!(1.002));
/// assert_eq!(round_to_decimals(dec!(-1.0015), 3), dec!(-1.002));
/// assert_eq!(round_to_decimals(dec!(1.0001), 0), dec!(1));
/// assert_eq!(round_to_decimals(dec!(-1.0001), 0), dec!(-1));
/// assert_eq!(round_to_decimals(dec!(1005.0011), -3), dec!(1000));
/// assert_eq!(round_to_decimals(dec!(-1005.0011), -3), dec!(-1000));
/// ```
pub fn round_to_decimals(mut value: Decimal, decimals: i32) -> Decimal {
    if decimals >= 0 {
        let multiplier = Decimal::new(
            1,
            decimals.try_into().expect("cannot fit decimals into u32"),
        );
        value /= multiplier;
        value.round() * multiplier
    } else {
        let multiplier = Decimal::new(
            1,
            (-decimals)
                .try_into()
                .expect("cannot fit -decimals into u32"),
        );
        value *= multiplier;
        value.round() / multiplier
    }
}
