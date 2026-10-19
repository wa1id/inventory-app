// RN: src/core/quantity.ts. A quantity is a whole number of things currently in
// a container. Zero is allowed (the item stays filed). Only the stepper and the
// saved-quantity writer clamp to 9999; typed values above it parse unclamped.

/// Lowest quantity (RN `MIN_QUANTITY`).
public let minQuantity = 0

/// Household-scale cap applied by the stepper (RN `MAX_QUANTITY`).
public let maxQuantity = 9999

/// `value` limited to `minQuantity...maxQuantity` (RN `clampQuantity`).
public func clampQuantity(_ value: Int) -> Int {
    min(max(value, minQuantity), maxQuantity)
}

/// RN `clampQuantity` for a JS number: anything that is not a whole number (fractions, NaN, ±∞) gives 0.
public func clampQuantity(_ value: Double) -> Int {
    guard value.isFinite, value.rounded(.towardZero) == value else { return minQuantity }
    if value < Double(minQuantity) { return minQuantity }
    if value > Double(maxQuantity) { return maxQuantity }
    return Int(value)
}

/// `current + delta`, clamped (RN `stepQuantity`).
public func stepQuantity(_ current: Int, _ delta: Int) -> Int {
    let (sum, overflow) = current.addingReportingOverflow(delta)
    if overflow { return delta < 0 ? minQuantity : maxQuantity }
    return clampQuantity(sum)
}

/// What the user typed into the quantity field, or `nil` (RN `parseQuantityInput`).
///
/// Trims with JS rules, then follows JS `Number()`: `"1.0"`, `"1e2"`, `"0x1F"`,
/// `"+5"` and `"5."` parse; empty, fractional, negative and non-ASCII-digit input
/// does not. Values above 9999 come back unclamped. Unlike JS, a value outside
/// `Int` (beyond 2^63) gives `nil` instead of an imprecise float.
public func parseQuantityInput(_ raw: String) -> Int? {
    let trimmed = raw.jsTrimmed()
    if trimmed.isEmpty { return nil }
    guard let value = jsNumber(trimmed), value.isFinite, value.rounded(.towardZero) == value,
          !(value < Double(minQuantity))
    else { return nil }
    return Int(exactly: value)
}
