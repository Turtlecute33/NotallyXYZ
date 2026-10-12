import SwiftUI

/// Staggered grid like the NotallyX overview: each card goes to the shortest column.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat

    struct Cache {
        var width: CGFloat = -1
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func compute(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        if cache.width == width && cache.frames.count == subviews.count { return }
        let columns = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = [CGFloat](repeating: 0, count: columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        for view in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let x = CGFloat(column) * (columnWidth + spacing)
            let height = ceil(size.height)  // fractional heights would cut the last text line
            frames.append(CGRect(x: x, y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        cache = Cache(width: width, frames: frames, height: max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? minColumnWidth * 3
        compute(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        compute(width: bounds.width, subviews: subviews, cache: &cache)
        for (view, frame) in zip(subviews, cache.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }
}
