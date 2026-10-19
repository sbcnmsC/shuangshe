import SwiftUI

/// 底部参数面板：iPhone 原相机风格的半透明深色调节面板。
/// 包含变焦、曝光补偿、手动 ISO/快门、白平衡、AE/AF 锁定。
struct ControlPanel: View {
    @ObservedObject var cam: DualCameraManager

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 38, height: 5)
                .padding(.top, 10)

            // 变焦
            panelRow("变焦") {
                Slider(value: Binding(get: { Double(cam.zoom) },
                                      set: { cam.setZoom(CGFloat($0)) }),
                       in: 1...5, step: 0.1)
                    .tint(.white)
                valueText(String(format: "%.1fx", cam.zoom))
            }

            // 曝光补偿（手动曝光时无效，置灰）
            panelRow("曝光") {
                Slider(value: Binding(get: { Double(cam.ev) },
                                      set: { cam.ev = Float($0) }),
                       in: -2...2, step: 0.1)
                    .tint(.yellow)
                    .disabled(cam.manualExposure)
                valueText(String(format: "%+.1f", cam.ev))
            }

            // 手动 ISO / 快门
            HStack {
                Text("手动 ISO/快门")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Toggle("", isOn: $cam.manualExposure)
                    .labelsHidden()
                    .tint(.yellow)
            }
            if cam.manualExposure {
                panelRow("ISO") {
                    Slider(value: Binding(get: { Double(cam.iso) },
                                          set: { cam.iso = Float($0) }),
                           in: 24...1600, step: 8)
                        .tint(.white)
                    valueText("\(Int(cam.iso))")
                }
                panelRow("快门") {
                    Slider(value: Binding(get: { cam.shutter },
                                          set: { cam.shutter = $0 }),
                           in: 1.0 / 8000...1.0 / 30)
                        .tint(.white)
                    valueText(shutterText(cam.shutter))
                }
            }

            // 白平衡预设
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WBPreset.allCases) { p in
                        Button {
                            cam.wbPreset = p
                        } label: {
                            Text(p.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(cam.wbPreset == p ? .black : .white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(cam.wbPreset == p ? Color.white : Color.white.opacity(0.15),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if cam.wbPreset == .custom {
                panelRow("色温") {
                    Slider(value: Binding(get: { Double(cam.wbTemperature) },
                                          set: { cam.wbTemperature = Float($0) }),
                           in: 2000...8000, step: 100)
                        .tint(.white)
                    valueText("\(Int(cam.wbTemperature))K")
                }
            }

            // AE/AF 锁定
            Button {
                cam.toggleAEAFLock()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cam.aeAfLocked ? "lock.fill" : "lock.open")
                    Text(cam.aeAfLocked ? "已锁定对焦/曝光" : "锁定对焦/曝光")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(cam.aeAfLocked ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(cam.aeAfLocked ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        .shadow(radius: 20)
    }

    private func panelRow<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 44, alignment: .leading)
            content()
        }
    }

    private func valueText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .frame(width: 46, alignment: .trailing)
    }

    private func shutterText(_ s: Double) -> String {
        if s >= 1 { return String(format: "%.0f\"", s) }
        return "1/\(Int((1.0 / s).rounded()))"
    }
}
