import SwiftUI

/// Lays its subviews out left to right, starting a new row whenever the next one would
/// not fit — the arrangement a row of chips wants when there are more of them than fit
/// across the screen.
///
/// The alternative, a horizontal `ScrollView`, hides the overflow behind a gesture that
/// nothing on screen suggests: with indicators off there is no hint the strip scrolls,
/// and with them on there is a hairline that appears only while it is moving. Wrapping
/// shows everything instead of advertising that something is hidden.
///
/// Each subview is given the size it asks for. That suits chips and buttons, which size
/// to their content; it is not a general-purpose grid.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let available = proposal.width ?? .infinity
        let rows = rows(subviews, availableWidth: available)
        let height = rows.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        // Report the widest row rather than the width offered, so the layout does not
        // claim space it is not using when it sits beside something else.
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: available.isFinite ? min(available, widest) : widest,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(subviews, availableWidth: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                // Centred within the row: chips of unequal height (a wrapped name, say)
                // sit on a common midline rather than hanging from the top.
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Packs the subviews into rows. Called from both `sizeThatFits` and
    /// `placeSubviews`, which must agree, so there is only the one implementation.
    private func rows(_ subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = row.width + horizontalSpacing + size.width
            // A subview wider than the row starts one of its own and overflows it —
            // better than an empty row above it.
            if !row.items.isEmpty, extended > availableWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index: index, size: size))
        }
        if !row.items.isEmpty { rows.append(row) }

        return rows
    }
}
