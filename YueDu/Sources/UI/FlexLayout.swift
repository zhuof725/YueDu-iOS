import SwiftUI

/// 每个子视图的 Flexbox 参数（对应 Legado 登录界面 style 字段）
struct FlexStyleKey: LayoutValueKey {
    static let defaultValue = LoginRowStyle()
}
/// 子视图是否默认占满一行（输入框在 Legado 里是 match_parent）
struct FlexFullWidthKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    func flexStyle(_ s: LoginRowStyle, fullWidth: Bool = false) -> some View {
        layoutValue(key: FlexStyleKey.self, value: s).layoutValue(key: FlexFullWidthKey.self, value: fullWidth)
    }
}

/// 简化版 FlexboxLayout：横向排列、自动换行，支持 flexGrow / flexBasisPercent / wrapBefore / alignSelf
struct FlexLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    private struct Item { var index: Int; var width: CGFloat; var height: CGFloat }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[Item]] {
        var result: [[Item]] = []
        var cur: [Item] = []
        var used: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let st = v[FlexStyleKey.self]
            var w: CGFloat
            if st.flexBasisPercent > 0 {
                w = max(0, width * CGFloat(st.flexBasisPercent) - spacing * (st.flexBasisPercent < 1 ? 0.5 : 0))
            } else if v[FlexFullWidthKey.self] {
                w = width
            } else {
                w = min(width, v.sizeThatFits(.unspecified).width)
            }
            let need = cur.isEmpty ? w : used + spacing + w
            if !cur.isEmpty && (st.wrapBefore || need > width + 0.5) {
                result.append(cur); cur = []; used = 0
            }
            let h = v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            cur.append(Item(index: i, width: w, height: h))
            used = cur.count == 1 ? w : used + spacing + w
        }
        if !cur.isEmpty { result.append(cur) }
        // flexGrow 分配剩余宽度
        for li in result.indices {
            let total = result[li].reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, result[li].count - 1))
            let free = width - total
            let grow = result[li].reduce(0.0) { $0 + subviews[$1.index][FlexStyleKey.self].flexGrow }
            if free > 0 && grow > 0 {
                for j in result[li].indices {
                    let g = subviews[result[li][j].index][FlexStyleKey.self].flexGrow
                    if g > 0 {
                        result[li][j].width += free * CGFloat(g / grow)
                        result[li][j].height = subviews[result[li][j].index]
                            .sizeThatFits(ProposedViewSize(width: result[li][j].width, height: nil)).height
                    }
                }
            }
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let ls = lines(width, subviews)
        let h = ls.reduce(0) { $0 + ($1.map(\.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, ls.count - 1))
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            let lh = line.map(\.height).max() ?? 0
            var x = bounds.minX
            for it in line {
                let st = subviews[it.index][FlexStyleKey.self]
                var dy: CGFloat = 0
                switch st.alignSelf {
                case "flex_end": dy = lh - it.height
                case "center": dy = (lh - it.height) / 2
                default: dy = 0
                }
                let h = st.alignSelf == "stretch" ? lh : it.height
                subviews[it.index].place(at: CGPoint(x: x, y: y + dy), anchor: .topLeading,
                                         proposal: ProposedViewSize(width: it.width, height: h))
                x += it.width + spacing
            }
            y += lh + lineSpacing
        }
    }
}
