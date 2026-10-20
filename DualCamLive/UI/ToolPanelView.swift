import SwiftUI

struct ToolPanelView: View {
    @EnvironmentObject private var settings: CaptureSettings
    @EnvironmentObject private var camera: DualCameraSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("相机工具").font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            HStack {
                tabButton("布局", 0)
                tabButton("滤镜", 1)
                tabButton("参数", 2)
                tabButton("设置", 3)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == 0 {
                        Picker("布局", selection: $settings.layout) {
                            ForEach(CaptureLayout.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Toggle("前置镜像", isOn: $settings.mirrorFrontCamera)
                        Toggle("显示三分线", isOn: $settings.showGrid)
                        Toggle("小窗边缘吸附", isOn: $settings.snapToEdge)
                        slider("小窗圆角", value: $settings.cornerRadius, range: 0...48, format: "%.0f")
                    } else if tab == 1 {
                        ForEach(FilterCatalog.allCases) { filter in
                            Button(filter.rawValue) { settings.filter = filter; camera.apply(settings: settings) }
                                .foregroundStyle(settings.filter == filter ? .blue : .primary)
                        }
                        slider("滤镜强度", value: $settings.filterStrength, range: 0...1, format: "%.0f%%", multiplier: 100)
                    } else if tab == 2 {
                        slider("曝光补偿", value: $settings.exposureBias, range: -3...3, format: "%.1f EV")
                        slider("变焦", value: $settings.zoom, range: 1...5, format: "%.1f×")
                    } else {
                        Picker("画幅", selection: $settings.aspectRatio) {
                            ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Picker("分辨率", selection: $settings.resolution) {
                            ForEach(OutputResolution.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu)
                        Picker("帧率", selection: $settings.frameRate) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }.pickerStyle(.segmented)
                        Toggle("保存两路原片（未接入）", isOn: $settings.saveOriginalStreams)
                        Toggle("弱光增亮（未接入）", isOn: $settings.lowLightBoost)
                        Toggle("防抖（未接入）", isOn: $settings.stabilization)
                        Text("当前合成画布安全上限为 1080p；设备双摄格式与 60fps 能力需在真机验证。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
        }
        .padding(20)
        .onChange(of: settings.layout) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.mirrorFrontCamera) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.filter) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.filterStrength) { _, _ in camera.apply(settings: settings) }
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button(title) { tab = index }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(tab == index ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        format: String, multiplier: Double = 1) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue * multiplier)).foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        format: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: format, Double(value.wrappedValue))).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }
}
