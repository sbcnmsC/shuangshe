import SwiftUI

private enum ToolsTab: String, CaseIterable, Identifiable {
    case pip = "小窗"
    case filters = "滤镜"
    case parameters = "参数"
    case settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pip: return "pip"
        case .filters: return "camera.filters"
        case .parameters: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

struct CameraToolsPanel: View {
    @ObservedObject var manager: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ToolsTab = .pip

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(.white.opacity(0.28)).frame(width: 38, height: 5).padding(.top, 8)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("相机工具").font(.system(size: 21, weight: .semibold))
                    Text("调整的效果会直接反映在预览与成片中").font(.caption).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34)
                        .background(.white.opacity(0.1), in: Circle())
                }.buttonStyle(.plain)
            }
            HStack(spacing: 7) {
                ForEach(ToolsTab.allCases) { tab in
                    Button { withAnimation(.snappy(duration: 0.2)) { selectedTab = tab } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .medium))
                            Text(tab.rawValue).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.58))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(selectedTab == tab ? .white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }.cameraGlass(cornerRadius: 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedTab {
                    case .pip: pipControls
                    case .filters: filterControls
                    case .parameters: parameterControls
                    case .settings: settingsControls
                    }
                }.padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 18)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.08, blue: 0.095)
                LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear { manager.refreshFilterThumbnails() }
    }

    private var pipControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            if manager.settings.layout == .pictureInPicture {
                sectionTitle("画中画", detail: "拖动画面上的小窗可改变位置")
                sliderRow("小窗大小", value: doubleBinding(\.pipScale), range: 0.18...0.48, valueText: "\(Int(manager.settings.pipScale * 100))%")
                pickerRow("形状", selection: binding(\.pipShape), options: PipShape.allCases)
                pickerRow("比例", selection: binding(\.pipAspect), options: PipAspect.allCases)
                sliderRow("圆角", value: doubleBinding(\.pipCornerRadius), range: 0...80, valueText: "\(Int(manager.settings.pipCornerRadius))")
                sliderRow("边框", value: doubleBinding(\.pipBorderWidth), range: 0...12, valueText: "\(Int(manager.settings.pipBorderWidth))")
                sliderRow("透明度", value: binding(\.pipOpacity), range: 0.2...1.0, valueText: "\(Int(manager.settings.pipOpacity * 100))%")
                Toggle("松手吸附边缘 / 中线", isOn: binding(\.snapPip)).tint(.white)
                Button {
                    manager.settings.pipX = 0.73
                    manager.settings.pipY = 0.22
                    manager.settings.pipScale = 0.31
                } label: { Label("复位小窗位置与大小", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(PanelActionButtonStyle())
                Button {
                    manager.toggleMainCamera()
                } label: { Label("互换主 / 副画面", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(PanelActionButtonStyle())
            } else {
                sectionTitle("上下分屏", detail: "拖动中间的分隔线或使用滑杆")
                sliderRow("上下比例", value: doubleBinding(\.splitRatio), range: 0.25...0.75, valueText: "上方 \(Int((1 - manager.settings.splitRatio) * 100))%")
            }
            Text("提示：设备只支持单摄时，小窗 / 分屏会自动使用同一路画面。")
                .font(.caption).foregroundStyle(.white.opacity(0.52))
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("实时滤镜", detail: "滤镜应用于合成画面；原始镜头不加滤镜")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(LiveFilter.allCases) { filter in
                    Button { manager.settings.filter = filter } label: {
                        VStack(spacing: 7) {
                            ZStack(alignment: .bottomLeading) {
                                if let thumbnail = manager.filterThumbnails[filter] {
                                    Image(uiImage: thumbnail).resizable().scaledToFill().frame(height: 82).frame(maxWidth: .infinity).clipped()
                                } else {
                                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)).frame(height: 82)
                                }
                                if filter == manager.settings.filter {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white).padding(5)
                                }
                            }
                            Text(filter.rawValue).font(.system(size: 12, weight: manager.settings.filter == filter ? .semibold : .regular))
                                .foregroundStyle(manager.settings.filter == filter ? .white : .white.opacity(0.68))
                        }
                        .padding(5)
                        .background(manager.settings.filter == filter ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(manager.settings.filter == filter ? 0.35 : 0.08), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            sliderRow("滤镜强度", value: binding(\.filterIntensity), range: 0...1, valueText: "\(Int(manager.settings.filterIntensity * 100))%")
        }
    }

    private var parameterControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("成像参数", detail: "参数会尽可能写入真实镜头；超出设备能力时自动限制")
            sliderRow("变焦", value: bindingZoom, range: 1...5, valueText: String(format: "%.1f×", manager.settings.zoom), onEditingChanged: { _ in manager.setZoom(manager.settings.zoom) })
            sliderRow("曝光补偿", value: binding(\.exposureBias), range: -2...2, valueText: String(format: "%+.1f EV", manager.settings.exposureBias), onEditingChanged: { _ in manager.setExposureBias(manager.settings.exposureBias) })
            Divider().overlay(.white.opacity(0.12))
            Text("手动曝光（ISO = 自动）").font(.subheadline.weight(.semibold))
            sliderRow("ISO", value: binding(\.manualISO), range: 0...3200, valueText: manager.settings.manualISO == 0 ? "自动" : "ISO \(Int(manager.settings.manualISO))", onEditingChanged: { _ in manager.applyManualExposure(iso: manager.settings.manualISO, shutter: manager.settings.shutterSeconds) })
            HStack {
                Text("快门").font(.subheadline)
                Spacer()
                Picker("快门", selection: bindingShutter) {
                    ForEach(["1/4000", "1/1000", "1/250", "1/120", "1/60", "1/30", "1/15", "1/8", "1/4", "1/2", "1s"], id: \.self) { item in
                        Text(item).tag(item)
                    }
                }.pickerStyle(.menu).tint(.white)
            }
            Divider().overlay(.white.opacity(0.12))
            sliderRow("白平衡色温", value: binding(\.whiteBalanceKelvin), range: 2500...9000, valueText: "\(Int(manager.settings.whiteBalanceKelvin)) K", onEditingChanged: { _ in manager.applyWhiteBalance(kelvin: manager.settings.whiteBalanceKelvin, tint: manager.settings.whiteBalanceTint) })
            sliderRow("色调", value: binding(\.whiteBalanceTint), range: -150...150, valueText: String(format: "%+.0f", manager.settings.whiteBalanceTint), onEditingChanged: { _ in manager.applyWhiteBalance(kelvin: manager.settings.whiteBalanceKelvin, tint: manager.settings.whiteBalanceTint) })
            sliderRow("手动对焦", value: binding(\.manualFocus), range: 0...1, valueText: String(format: "%.2f", manager.settings.manualFocus), onEditingChanged: { _ in manager.setManualFocus(manager.settings.manualFocus) })
            HStack(spacing: 10) {
                Button { manager.toggleFocusLock() } label: { Label(manager.settings.focusLocked ? "已锁焦" : "锁定对焦", systemImage: manager.settings.focusLocked ? "viewfinder.circle.fill" : "viewfinder") }
                    .buttonStyle(PanelActionButtonStyle())
                Button { manager.toggleExposureLock() } label: { Label(manager.settings.exposureLocked ? "已锁曝光" : "锁定曝光", systemImage: manager.settings.exposureLocked ? "sun.max.fill" : "sun.max") }
                    .buttonStyle(PanelActionButtonStyle())
            }
        }
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("画幅与质量", detail: "最高分辨率受实际传感器输出与双摄性能预算限制")
            pickerRow("画幅", selection: binding(\.aspect), options: CanvasAspect.allCases)
            pickerRow("分辨率", selection: binding(\.resolution), options: OutputResolution.allCases)
            HStack(spacing: 10) {
                Text("帧率").font(.subheadline)
                Spacer()
                Picker("帧率", selection: Binding(get: { manager.settings.frameRate }, set: { manager.setFrameRate($0) })) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }.pickerStyle(.segmented).frame(maxWidth: 180)
            }
            Text("实际帧率取决于设备当前镜头格式与双摄硬件负载。")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
            Divider().overlay(.white.opacity(0.12))
            Toggle("保存两路原片", isOn: binding(\.saveTwoOriginals)).tint(.white)
            Toggle("弱光增亮（系统支持时）", isOn: Binding(get: { manager.settings.lowLightBoost }, set: { manager.settings.lowLightBoost = $0; manager.applyLowLightBoost() })).tint(.white)
            Toggle("视频防抖", isOn: Binding(get: { manager.settings.stabilizationEnabled }, set: { manager.settings.stabilizationEnabled = $0; manager.updateStabilization() })).tint(.white)
            Toggle("前置镜像", isOn: binding(\.frontMirror)).tint(.white)
            Toggle("三分参考线", isOn: binding(\.gridEnabled)).tint(.white)
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.6))
                Text(manager.isMultiCameraActive ? "当前设备已建立前后双摄链路。" : "当前运行单摄；可尝试更换设备以使用双摄。")
                    .font(.caption).foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(valueText).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.62)).monospacedDigit()
            }
            Slider(value: value, in: range, onEditingChanged: onEditingChanged).tint(.white)
        }
    }

    private func pickerRow<T: StringRawRepresentableIdentifiable>(_ title: String, selection: Binding<T>, options: [T]) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.menu).tint(.white)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CameraSettings, T>) -> Binding<T> {
        Binding(get: { manager.settings[keyPath: keyPath] }, set: { manager.settings[keyPath: keyPath] = $0 })
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<CameraSettings, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(manager.settings[keyPath: keyPath]) }, set: { manager.settings[keyPath: keyPath] = CGFloat($0) })
    }

    private var bindingZoom: Binding<Double> {
        Binding(get: { Double(manager.settings.zoom) }, set: { manager.settings.zoom = CGFloat($0); manager.setZoom($0) })
    }

    private var bindingShutter: Binding<String> {
        let choices: [(String, Double)] = [("1/4000", 1.0/4000), ("1/1000", 1.0/1000), ("1/250", 1.0/250), ("1/120", 1.0/120), ("1/60", 1.0/60), ("1/30", 1.0/30), ("1/15", 1.0/15), ("1/8", 1.0/8), ("1/4", 1.0/4), ("1/2", 1.0/2), ("1s", 1)]
        return Binding(get: { choices.min(by: { abs($0.1 - manager.settings.shutterSeconds) < abs($1.1 - manager.settings.shutterSeconds) })?.0 ?? "1/60" }, set: { selected in
            manager.settings.shutterSeconds = choices.first(where: { $0.0 == selected })?.1 ?? 1.0/60
            manager.applyManualExposure(iso: manager.settings.manualISO, shutter: manager.settings.shutterSeconds)
        })
    }
}

private protocol StringRawRepresentableIdentifiable: RawRepresentable, Identifiable, Hashable where RawValue == String {}
extension PipShape: StringRawRepresentableIdentifiable {}
extension PipAspect: StringRawRepresentableIdentifiable {}
extension CanvasAspect: StringRawRepresentableIdentifiable {}
extension OutputResolution: StringRawRepresentableIdentifiable {}
extension LiveFilter: StringRawRepresentableIdentifiable {}

private struct PanelActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.11), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
