import SwiftUI

struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial).clipShape(shape)
        }
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
