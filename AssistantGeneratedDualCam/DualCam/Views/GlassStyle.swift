import SwiftUI

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 22
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                }
        }
    }
}

extension View {
    func cameraGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

struct GlassIconButton: View {
    let symbol: String
    var isActive: Bool = false
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? Color.yellow : Color.white)
                .frame(width: 43, height: 43)
                .contentShape(Circle())
                .background(.white.opacity(isActive ? 0.18 : 0.09), in: Circle())
                .cameraGlass(cornerRadius: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
