import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case pip = "小窗"
    case filter = "滤镜"
    case params = "参数"
    case settings = "设置"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pip: return "pip"
        case .filter: return "camera.filters"
        case .params: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

/// 底部 Liquid Glass 工具面板：小窗 / 滤镜 / 参数 / 设置 四个分页。
struct ControlPanel: View {
    @ObservedObject var cam: DualCameraManager
    @Binding var tab: PanelTab
    @State private var thumbs: [FilterPreset: UIImage] = [:]

    var body: some View {
        VStack(spacing: 8) {
            tabBar

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    switch tab {
                    case .pip: pipTab
                    case .filter: filterTab
                    case .params: paramsTab
                    case .settings: settingsTab
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .frame(height: 280)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .foregroundStyle(Color.white)
        .liquidGlass(RoundedRectangle(cornerRadius: 32, style: .continuous), interactive: false)
        .padding(.horizontal, 10)
    }

    // MARK: - 分页栏

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tab = t }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon)
                        if tab == t { Text(t.rawValue) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tab == t ? Color.yellow : Color.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if tab == t { Capsule().fill(Color.white.opacity(0.16)) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 小窗

    @ViewBuilder
    private var pipTab: some View {
        if cam.layout == .pip {
            sliderRow("大小",
                      value: Binding(get: { Double(cam.pip.width) },
                                     set: { cam.resizePip(width: CGFloat($0)) }),
                      range: Double(PiPConfig.minWidth)...Double(PiPConfig.maxWidth),
                      text: "\(Int(cam.pip.width * 100))%")

            labeled("形状") {
                chips(PiPShape.allCases, selection: cam.pip.shape, label: { $0.rawValue }) { s in
                    cam.updatePip { $0.shape = s }
                }
            }

            if cam.pip.shape == .rounded {
                labeled("比例") {
                    chips(PiPAspect.allCases, selection: cam.pip.aspect, label: { $0.rawValue }) { a in
                        cam.updatePip { $0.aspect = a }
                    }
                }
                sliderRow("圆角",
                          value: Binding(get: { Double(cam.pip.corner) },
                                         set: { v in cam.updatePip { $0.corner = CGFloat(v) } }),
                          range: 0...0.5,
                          text: "\(Int(cam.pip.corner * 200))%")
            }

            sliderRow("边框",
                      value: Binding(get: { Double(cam.pip.border) },
                                     set: { v in cam.updatePip { $0.border = CGFloat(v) } }),
                      range: 0...1,
                      text: cam.pip.border < 0.02 ? "无" : "\(Int(cam.pip.border * 100))%")

            sliderRow("透明",
                      value: Binding(get: { Double(cam.pip.opacity) },
                                     set: { v in cam.updatePip { $0.opacity = CGFloat(v) } }),
                      range: 0.4...1,
                      text: "\(Int(cam.pip.opacity * 100))%")

            toggleRow("松手后吸附边缘",
                      isOn: Binding(get: { cam.pip.snap },
                                    set: { v in cam.updatePip { $0.snap = v } }))

            HStack {
                Text("拖动小窗移动，捏合或拖右下角缩放，点一下互换画面")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer(minLength: 8)
                pillButton("复位位置") { cam.resetPip() }
            }
        } else {
            sliderRow("分割",
                      value: Binding(get: { Double(cam.splitRatio) },
                                     set: { cam.splitRatio = CGFloat($0) }),
                      range: 0.3...0.7,
                      text: "\(Int(cam.splitRatio * 100)):\(100 - Int(cam.splitRatio * 100))")
            Text("上下分屏时，也可以直接拖动画面中间的分割线调整比例")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 滤镜

    private var filterTab: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.allCases) { f in
                        Button {
                            cam.filter = f
                        } label: {
                            VStack(spacing: 5) {
                                thumb(f)
                                Text(f.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(cam.filter == f ? Color.yellow : Color.white.opacity(0.8))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            sliderRow("强度",
                      value: Binding(get: { Double(cam.filterStrength) },
                                     set: { cam.filterStrength = CGFloat($0) }),
                      range: 0...1,
                      text: "\(Int(cam.filterStrength * 100))%",
                      tint: .yellow,
                      disabled: cam.filter == .original)
        }
        .onAppear {
            cam.makeFilterThumbnails { thumbs = $0 }
        }
    }

    private func thumb(_ f: FilterPreset) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let selected = cam.filter == f
        return ZStack {
            if let img = thumbs[f] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 58, height: 76)
        .clipShape(shape)
        .overlay(shape.stroke(selected ? Color.yellow : Color.white.opacity(0.2),
                              lineWidth: selected ? 2 : 0.5))
    }

    // MARK: - 参数

    @ViewBuilder
    private var paramsTab: some View {
        sliderRow("变焦",
                  value: Binding(get: { Double(cam.zoom) },
                                 set: { cam.setZoom(CGFloat($0)) }),
                  range: Double(cam.zoomRange.lowerBound)...Double(cam.zoomRange.upperBound),
                  text: String(format: "%.1f×", cam.zoom))

        sliderRow("曝光",
                  value: Binding(get: { Double(cam.ev) },
                                 set: { cam.ev = Float($0) }),
                  range: -2...2, step: 0.1,
                  text: String(format: "%+.1f", cam.ev),
                  tint: .yellow,
                  disabled: cam.manualExposure)

        toggleRow("手动 ISO / 快门", isOn: $cam.manualExposure)

        if cam.manualExposure {
            sliderRow("ISO",
                      value: Binding(get: { Double(cam.iso) },
                                     set: { cam.iso = Float($0) }),
                      range: Double(cam.isoRange.lowerBound)...Double(cam.isoRange.upperBound),
                      text: "\(Int(cam.iso))")
            // 快门按「档数」（对数）调节，慢快门和快快门的手感一致
            sliderRow("快门",
                      value: Binding(get: { log2(cam.shutter) },
                                     set: { cam.shutter = pow(2, $0) }),
                      range: log2(cam.shutterRange.lowerBound)...log2(cam.shutterRange.upperBound),
                      text: shutterText(cam.shutter))
        }

        labeled("白平衡") {
            chips(WBPreset.allCases, selection: cam.wbPreset, label: { $0.rawValue }) { cam.wbPreset = $0 }
        }

        if cam.wbPreset == .custom {
            sliderRow("色温",
                      value: Binding(get: { Double(cam.wbTemperature) },
                                     set: { cam.wbTemperature = Float($0) }),
                      range: 2000...8000, step: 100,
                      text: "\(Int(cam.wbTemperature))K")
            sliderRow("色调",
                      value: Binding(get: { Double(cam.wbTint) },
                                     set: { cam.wbTint = Float($0) }),
                      range: -100...100, step: 5,
                      text: "\(Int(cam.wbTint))")
        }

        toggleRow("手动对焦", isOn: $cam.manualFocus, disabled: !cam.canManualFocus)

        if cam.manualFocus && cam.canManualFocus {
            sliderRow("焦距",
                      value: Binding(get: { Double(cam.lensPosition) },
                                     set: { cam.lensPosition = Float($0) }),
                      range: 0...1,
                      text: cam.lensPosition < 0.15 ? "近" : (cam.lensPosition > 0.85 ? "远" : "中"))
        }

        Button {
            cam.toggleAEAFLock()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: cam.aeAfLocked ? "lock.fill" : "lock.open")
                Text(cam.aeAfLocked ? "已锁定对焦 / 曝光" : "锁定对焦 / 曝光")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(cam.aeAfLocked ? Color.black : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(cam.aeAfLocked ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 设置

    @ViewBuilder
    private var settingsTab: some View {
        labeled("画幅") {
            chips(AspectPreset.allCases, selection: cam.aspect, disabled: cam.isRecording,
                  label: { $0.rawValue }) { cam.aspect = $0 }
        }
        labeled("分辨率") {
            chips(ResolutionPreset.allCases, selection: cam.resolution, disabled: cam.isRecording,
                  label: { $0.rawValue }) { cam.resolution = $0 }
        }
        labeled("帧率") {
            chips(FPSOption.allCases, selection: cam.fps, disabled: cam.isRecording,
                  label: { "\($0.rawValue) fps" }) { cam.fps = $0 }
        }

        Text("当前输出 \(Int(cam.canvasSize.width)) × \(Int(cam.canvasSize.height)) · \(cam.activeFPS) fps（不会超过摄像头实际像素）")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)

        toggleRow("保存两路原片", isOn: $cam.saveRaw, disabled: cam.isRecording)
        toggleRow("弱光增亮（暗处自动降帧提亮）", isOn: $cam.lowLight)
        toggleRow("视频防抖", isOn: $cam.stabilize)
        toggleRow("前置镜像", isOn: $cam.mirrorFront, disabled: cam.mode != .frontBack)
        toggleRow("三分参考线", isOn: $cam.showGrid)
    }

    // MARK: - 复用组件

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 46, alignment: .leading)
            content()
        }
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double? = nil,
                           text: String,
                           tint: Color = .white,
                           disabled: Bool = false) -> some View {
        labeled(title) {
            if let step {
                Slider(value: value, in: range, step: step).tint(tint)
            } else {
                Slider(value: value, in: range).tint(tint)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 54, alignment: .trailing)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .tint(.yellow)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func chips<T: Hashable>(_ items: [T],
                                    selection: T,
                                    disabled: Bool = false,
                                    label: @escaping (T) -> String,
                                    onSelect: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = item == selection
                    Button {
                        onSelect(item)
                    } label: {
                        Text(label(item))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shutterText(_ s: Double) -> String {
        if s >= 1 { return String(format: "%.0f\"", s) }
        return "1/\(Int((1.0 / s).rounded()))"
    }
}
