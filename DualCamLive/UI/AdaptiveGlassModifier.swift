import SwiftUI

/// Flat controls intentionally avoid iOS GlassEffect and Material blur to reduce
/// per-control compositing overhead while dual-camera preview and Metal rendering run.
struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color(white: 0.10).opacity(0.94))
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7)
            }
            .contentShape(shape)
    }
}

extension View {
    func adaptiveGlass<S: Shape>(in shape: S = Capsule(), interactive: Bool = false) -> some View {
        modifier(AdaptiveGlassModifier(shape: shape, interactive: interactive))
    }
}

struct GlassPressedFeedback: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
