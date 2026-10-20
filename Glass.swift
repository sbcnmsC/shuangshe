import SwiftUI

// MARK: - Liquid Glass（动态玻璃）
//
// iOS 26+ 使用系统的 glassEffect；更早的系统自动回退到毛玻璃材质。
// 用 #if compiler(>=6.2) 包起来，所以即使用旧版 Xcode 编译也不会报错（只是没有玻璃效果）。

#if compiler(>=6.2)
@available(iOS 26.0, *)
enum LiquidGlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint.opacity(0.75)) }
        if interactive { g = g.interactive() }
        return g
    }
}
#endif

extension View {
    /// 把视图做成 Liquid Glass 的形状。tint 用于选中 / 强调状态。
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(LiquidGlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self.legacyGlass(shape, tint: tint)
        }
        #else
        self.legacyGlass(shape, tint: tint)
        #endif
    }

    /// iOS 26 之前的回退：系统毛玻璃 + 高光描边。
    func legacyGlass<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? Color.clear).opacity(0.55), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.20), lineWidth: 0.6))
    }
}

/// 一组玻璃元素的容器：iOS 26 下相邻的玻璃会互相融合 / 变形，
/// 同一容器里的玻璃共享一次采样，也更省性能。
struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 三分参考线
struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            let y = rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: rect.height))
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return p
    }
}
