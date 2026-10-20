import SwiftUI

/// Lightweight camera controls. Deliberately avoids system glass effects and material blur:
/// dual-camera capture already uses significant GPU bandwidth, so controls use solid fills
/// and a thin stroke instead of sampling the preview behind each control.
extension View {
    func liquidGlass<S: Shape>(_ shape: S,
                               tint: Color? = nil,
                               interactive: Bool = true) -> some View {
        self
            .background {
                shape.fill(tint.map { $0.opacity(0.96) } ?? Color(white: 0.10).opacity(0.94))
            }
            .overlay {
                shape.stroke(
                    tint.map { $0.opacity(0.82) } ?? Color.white.opacity(0.18),
                    lineWidth: 0.7
                )
            }
            .contentShape(shape)
    }

    /// Kept as a compatibility shim for existing call sites; never uses Material blur.
    func legacyGlass<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background {
                shape.fill(tint.map { $0.opacity(0.96) } ?? Color(white: 0.10).opacity(0.94))
            }
            .overlay {
                shape.stroke(
                    tint.map { $0.opacity(0.82) } ?? Color.white.opacity(0.18),
                    lineWidth: 0.7
                )
            }
    }
}

/// Lightweight grouping container. Intentionally does not create a GlassEffectContainer.
struct GlassGroup<Content: View>: View {
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

/// Rule-of-thirds guide.
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
