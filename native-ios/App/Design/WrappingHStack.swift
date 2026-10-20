import SwiftUI

/// Lays its children in a row that wraps onto new lines, like RN's `flexWrap: 'wrap'`: the
/// location line ("Space › Container" and the tape), chips, a card's footer.
///
/// A child that fits on the current line goes there; otherwise it starts a new line, and a child
/// wider than a whole line is offered the full width so its text wraps inside it. Children are
/// never stretched or truncated, so a tape moves to the next line whole.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var alignment: VerticalAlignment

    init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 2, alignment: VerticalAlignment = .center) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.alignment = alignment
    }

    struct Line {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for (position, index) in line.indices.enumerated() {
                let size = line.sizes[position]
                let offset: CGFloat = switch alignment {
                case .top: 0
                case .bottom: line.height - size.height
                default: (line.height - size.height) / 2
                }
                subviews[index].place(at: CGPoint(x: x, y: y + offset), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    /// How far a line may run past the width it is given and still count as fitting.
    ///
    /// The width a parent places this layout in is the width it measured, rounded to the pixel
    /// grid: up to a pixel narrower than the sum of the children's fractional text widths. Without
    /// the slack, a line that just fitted when measured no longer fitted when placed, so the last
    /// piece (the tape) dropped to a second line drawn outside the one-line height that was
    /// reported: the location line over the camera "measured one line and drew two", and its
    /// glass did not fit. A point of overrun is invisible beside the 6 pt gaps.
    static let fitTolerance: CGFloat = 1

    /// The lines for a given width. `sizeThatFits` and `placeSubviews` both go through here, with
    /// the same tolerance, so what is drawn is what was measured.
    func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        let maxWidth = width ?? .infinity
        let limit = maxWidth + Self.fitTolerance
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit {
                // Too wide for any line: give it the whole width so its text wraps.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty && needed > limit {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
