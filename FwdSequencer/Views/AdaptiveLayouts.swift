import SwiftUI

// Why these exist: ViewThatFits crashes on iPadOS 16.
//
// The app used ViewThatFits to pick a one-line layout when it fitted and a stacked one
// when it did not. On iPadOS 16 that crashed the app on almost any change once a song
// was open (closing the Play keyboard, MIDI Learn, adding an effect, a key on a track's
// keyboard, Play after Pause, coming back to the app): SwiftUI aborts with
// "precondition failure: accessing attribute in a different namespace" while
// updating. Found 2026-11-26 on Graham's wife's iPad (16.7) and reproduced on an
// iOS 16.4 simulator; with every ViewThatFits taken out it no longer crashed there.
// iPadOS 17 and later were fine.
//
// ViewThatFits keeps every candidate alive, each with its own copy of the same
// controls, and the live readouts (meters, the bar counter, CPU) keep updating in the
// candidates that are not shown. The layouts below keep ONE copy of each control and
// decide the arrangement themselves, during layout. Do not bring ViewThatFits back
// while iPadOS 16 is supported.

/// Where a subview goes in `RowOrTwoRows` when the one-line arrangement does not fit.
enum CompactRow {
    /// First row, left to right.
    case first
    /// First row, at the right-hand end.
    case firstTrailing
    /// Second row (the default).
    case second
    /// Second row, offered whatever width the rest of that row leaves.
    case secondFlexible
}

private struct CompactRowKey: LayoutValueKey {
    static let defaultValue: CompactRow = .second
}

extension View {
    /// Places this subview of a `RowOrTwoRows` when it falls back to two rows.
    func compactRow(_ row: CompactRow) -> some View {
        layoutValue(key: CompactRowKey.self, value: row)
    }
}

/// All subviews on one line at their natural widths when that fits in the width
/// offered; otherwise two rows, chosen per subview with `.compactRow(_:)`. The first
/// row spans the width (its `.firstTrailing` subview at the right-hand end); the second
/// is placed at the leading edge or centred.
///
/// The same test ViewThatFits made of a `.fixedSize` HStack: one line if its ideal
/// width fits.
struct RowOrTwoRows: Layout {
    var wideSpacing: CGFloat
    var compactSpacing: CGFloat
    var rowGap: CGFloat
    var centersSecondRow = false

    private struct Plan {
        var wide: Bool
        var size: CGSize
        var frames: [CGRect]   // relative to the layout's origin
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        plan(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let p = plan(width: bounds.width, subviews: subviews)
        for (i, frame) in p.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
        }
    }

    private func plan(width: CGFloat?, subviews: Subviews) -> Plan {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let n = subviews.count
        // A subview that draws nothing (a button that is hidden) takes no spacing.
        let shown = (0..<n).filter { ideal[$0] != .zero }
        var frames = Array(repeating: CGRect.zero, count: n)
        let wideWidth = shown.map { ideal[$0].width }.reduce(0, +)
            + wideSpacing * CGFloat(max(0, shown.count - 1))
        let available = width ?? .infinity

        if wideWidth <= available || !available.isFinite {
            let height = shown.map { ideal[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for i in shown {
                frames[i] = CGRect(x: x, y: (height - ideal[i].height) / 2,
                                   width: ideal[i].width, height: ideal[i].height)
                x += ideal[i].width + wideSpacing
            }
            return Plan(wide: true, size: CGSize(width: wideWidth, height: height), frames: frames)
        }

        let roles = subviews.map { $0[CompactRowKey.self] }

        // First row: leading items left to right, the trailing one at the end.
        let first = shown.filter { roles[$0] == .first }
        let trailing = shown.filter { roles[$0] == .firstTrailing }
        let firstRow = first + trailing
        let row1Height = firstRow.map { ideal[$0].height }.max() ?? 0
        var x: CGFloat = 0
        for i in first {
            frames[i] = CGRect(x: x, y: (row1Height - ideal[i].height) / 2,
                               width: ideal[i].width, height: ideal[i].height)
            x += ideal[i].width + compactSpacing
        }
        var trailingX = available
        for i in trailing.reversed() {
            trailingX -= ideal[i].width
            frames[i] = CGRect(x: trailingX, y: (row1Height - ideal[i].height) / 2,
                               width: ideal[i].width, height: ideal[i].height)
            trailingX -= compactSpacing
        }

        // Second row: natural widths, the flexible item offered what is left.
        let second = shown.filter { roles[$0] == .second || roles[$0] == .secondFlexible }
        let fixedWidth = second.filter { roles[$0] == .second }.map { ideal[$0].width }.reduce(0, +)
        let spacing = compactSpacing * CGFloat(max(0, second.count - 1))
        let flexibleCount = second.filter { roles[$0] == .secondFlexible }.count
        let leftover = max(0, available - fixedWidth - spacing)
        // Shared out as an HStack would: the item that can grow least is served
        // first, and what it cannot use goes to the others.
        var sizes: [Int: CGSize] = [:]
        for i in second where roles[i] == .second { sizes[i] = ideal[i] }
        let flexible = second.filter { roles[$0] == .secondFlexible }
            .map { (i: $0, most: subviews[$0].sizeThatFits(
                ProposedViewSize(width: .infinity, height: nil)).width) }
            .sorted { $0.most < $1.most }
        var remaining = leftover
        for (n, f) in flexible.enumerated() {
            let share = remaining / CGFloat(flexibleCount - n)
            let size = subviews[f.i].sizeThatFits(ProposedViewSize(width: share, height: nil))
            sizes[f.i] = size
            remaining = max(0, remaining - size.width)
        }
        let row2Width = second.map { sizes[$0]!.width }.reduce(0, +) + spacing
        let row2Height = second.map { sizes[$0]!.height }.max() ?? 0
        let row2Y = firstRow.isEmpty || second.isEmpty ? row1Height : row1Height + rowGap
        x = centersSecondRow ? max(0, (available - row2Width) / 2) : 0
        for i in second {
            let s = sizes[i]!
            frames[i] = CGRect(x: x, y: row2Y + (row2Height - s.height) / 2,
                               width: s.width, height: s.height)
            x += s.width + compactSpacing
        }

        let height = second.isEmpty ? row1Height : row2Y + row2Height
        return Plan(wide: false, size: CGSize(width: available, height: height), frames: frames)
    }
}

/// An open track: header beside the notes when there is room, the header above them
/// when not. Expects three subviews: header, separator line, notes. The separator is
/// drawn as given `thickness` across the stacking direction.
///
/// Side by side when the header's fixed width, the separator, the spacing and the notes'
/// natural width (at least `notesMinWidth`) fit — the test ViewThatFits made of the
/// HStack this replaces.
struct TrackBodyLayout: Layout {
    var headerWidth: CGFloat = 250
    var notesMinWidth: CGFloat = 400
    var spacing: CGFloat = 10
    var thickness: CGFloat = 1

    private func sideBySide(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard subviews.count == 3, let width, width.isFinite else { return true }
        let notesIdeal = max(notesMinWidth, subviews[2].sizeThatFits(.unspecified).width)
        return headerWidth + spacing * 2 + thickness + notesIdeal <= width
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> (CGSize, [CGRect]) {
        guard subviews.count == 3 else {
            return (.zero, Array(repeating: .zero, count: subviews.count))
        }
        let header = subviews[0], notes = subviews[2]
        if sideBySide(width, subviews) {
            let notesWidth: CGFloat? = width.map {
                max(notesMinWidth, $0 - headerWidth - spacing * 2 - thickness)
            }
            let h = header.sizeThatFits(ProposedViewSize(width: headerWidth, height: nil))
            let nz = notes.sizeThatFits(ProposedViewSize(width: notesWidth, height: nil))
            let height = max(h.height, nz.height)
            let notesX = headerWidth + spacing * 2 + thickness
            return (CGSize(width: notesX + nz.width, height: height), [
                CGRect(x: 0, y: 0, width: headerWidth, height: h.height),
                CGRect(x: headerWidth + spacing, y: 0, width: thickness, height: height),
                CGRect(x: notesX, y: 0, width: nz.width, height: nz.height),
            ])
        }
        let w = width ?? 0
        let h = header.sizeThatFits(ProposedViewSize(width: w, height: nil))
        let nz = notes.sizeThatFits(ProposedViewSize(width: w, height: nil))
        let dividerY = h.height + spacing
        let notesY = dividerY + thickness + spacing
        return (CGSize(width: max(w, h.width, nz.width), height: notesY + nz.height), [
            CGRect(x: 0, y: 0, width: h.width, height: h.height),
            CGRect(x: 0, y: dividerY, width: w, height: thickness),
            CGRect(x: 0, y: notesY, width: nz.width, height: nz.height),
        ])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        frames(proposal.width, subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let (_, rects) = frames(bounds.width, subviews)
        for (i, r) in rects.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY),
                              proposal: ProposedViewSize(r.size))
        }
    }
}

/// Reads the width this view is given and passes it to `content`, which can then
/// choose between two arrangements with a plain `if` — only the chosen one exists.
/// Before the first measurement `content` is given nil.
struct WidthReader<Content: View>: View {
    private let content: (CGFloat?) -> Content
    @State private var width: CGFloat?

    init(@ViewBuilder content: @escaping (CGFloat?) -> Content) {
        self.content = content
    }

    var body: some View {
        content(width)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { width = $0 }
                }
            )
    }
}
