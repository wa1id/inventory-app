// RN: src/hooks/useSpreadGap.ts. The pickers lay fixed-size tiles in wrapping rows that reach
// both edges of the column; the gap grows instead of the tiles (08 §10).

/// How fixed-width tiles spread across a row.
public enum TileSpread {
    /// How many tiles fit on one row at `minGap`, at most `columns` (at least 1).
    public static func columns(width: Double, tile: Double, minGap: Double, columns: Int? = nil) -> Int {
        guard width > 0, tile + minGap > 0 else { return 1 }
        let fit = Int(((width + minGap) / (tile + minGap)).rounded(.down))
        return max(1, min(columns ?? .max, fit))
    }

    /// The column gap that spreads the tiles of a full row to both edges (RN `spreadGap`).
    ///
    /// As many columns fit as `minGap` allows, at most `columns`; the gap is rounded down to
    /// 0.1 pt so rounding never pushes a row's last tile onto the next line. `minGap` until the
    /// row is measured, and when fewer than two tiles fit.
    public static func gap(width: Double, tile: Double, minGap: Double, columns: Int? = nil) -> Double {
        if width <= 0 { return minGap }
        let fit = min(Double(columns ?? .max), ((width + minGap) / (tile + minGap)).rounded(.down))
        if fit < 2 { return minGap }
        return max(minGap, (((width - fit * tile) / (fit - 1)) * 10).rounded(.down) / 10)
    }
}
