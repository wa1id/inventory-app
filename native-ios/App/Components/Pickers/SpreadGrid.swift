import SwiftUI
import InventoryAppModels

/// Fixed-size tiles in wrapping rows that reach both edges of the column: the gap grows, never
/// the tiles (RN `useSpreadGap`, 08 §10). The swatch, emoji and type pickers use it.
struct SpreadGrid: Layout {
    /// The width of every tile's cell.
    var tileWidth: CGFloat
    var minGap: CGFloat
    var rowGap: CGFloat
    /// At most this many columns.
    var maxColumns: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (tileWidth * CGFloat(min(subviews.count, maxColumns ?? subviews.count)) + minGap * CGFloat(max(0, min(subviews.count, maxColumns ?? subviews.count) - 1)))
        let columns = TileSpread.columns(width: width, tile: tileWidth, minGap: minGap, columns: maxColumns)
        let rows = rowHeights(columns: columns, subviews: subviews)
        let height = rows.reduce(0, +) + rowGap * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = TileSpread.columns(width: bounds.width, tile: tileWidth, minGap: minGap, columns: maxColumns)
        let gap = TileSpread.gap(width: bounds.width, tile: tileWidth, minGap: minGap, columns: maxColumns)
        let rows = rowHeights(columns: columns, subviews: subviews)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (tileWidth + gap)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: tileWidth, height: height))
            }
            y += height + rowGap
        }
    }

    private func rowHeights(columns: Int, subviews: Subviews) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: max(1, columns)).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height }
                .max() ?? 0
        }
    }
}
