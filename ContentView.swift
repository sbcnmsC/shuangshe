import SwiftUI
import AVFoundation

enum CaptureKind: String, CaseIterable, Identifiable {
    case photo = "拍照"
    case video = "录像"
    var id: String { rawValue }
    var icon: String { self == .photo ? "camera" : "video" }
}

/// iPhone 原相机风格的主界面：
/// 纯黑预览、顶部对称工具、底部模式栏（可滑动切换）、双层快门、
/// 变焦档位、点按对焦/曝光、上下滑动调 EV、上滑呼出参数面板。
struct ContentView: View {
    @StateObject private var cam = DualCameraManager()
    @State private var kind: CaptureKind = .photo
    @State private var showPanel = false
    @State private var pinchBase: CGFloat = 1
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            preview

            VStack(spacing: 0) {
                Spacer()
                zoomControl
                controls
            }

            topBar

            focusOverlay
            evBadge

            if let text = cam.statusText {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            if showPanel {
                VStack(spacing: 0) {
                    Spacer()
                    ControlPanel(cam: cam)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showPanel)
        .animation(.easeInOut(duration: 0.2), value: cam.statusText)
        .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        .onAppear { cam.start() }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? cam.resume() : cam.pause()
        }
    }

    // MARK: 预览（含对焦/曝光手势）

    private var activeLayer: AVCaptureVideoPreviewLayer {
        cam.swapped ? cam.layerB : cam.layerA
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                switch cam.layout {
                case .pip:
                    LayerHost(layer: cam.swapped ? cam.layerB : cam.layerA)
                        .ignoresSafeArea()
                case .split:
                    VStack(spacing: 0) {
                        LayerHost(layer: cam.swapped ? cam.layerB : cam.layerA)
                        LayerHost(layer: cam.swapped ? cam.layerA : cam.layerB)
                    }
                    .ignoresSafeArea()
                }
            }
            .contentShape(Rectangle())
            // 双指捏合变焦（iPhone 原相机手势）
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        cam.setZoom(pinchBase * value)
                    }
                    .onEnded { _ in
                        pinchBase = cam.zoom
                    }
            )
            // 上下滑动调节曝光补偿（上滑加亮）
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dy = value.translation.height
                        if abs(dy) > abs(value.translation.width) {
                            cam.adjustEV(by: Float(-dy / 160))
                        }
                    }
            )
            // 点按对焦 / 曝光
            .onTapGesture { location in
                if cam.layout == .split {
                    let half = geo.size.height / 2
                    if location.y < half {
                        let layer = cam.swapped ? cam.layerB : cam.layerA
                        cam.focusAndExpose(atLayerPoint: CGPoint(x: location.x, y: location.y * 2),
                                           in: layer, indicator: location)
                    } else {
                        let layer = cam.swapped ? cam.layerA : cam.layerB
                        cam.focusAndExpose(atLayerPoint: CGPoint(x: location.x, y: (location.y - half) * 2),
                                           in: layer, indicator: location)
                    }
                } else {
                    cam.focusAndExpose(atLayerPoint: location,
                                       in: activeLayer, indicator: location)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 顶部栏

    private var topBar: some View {
        VStack {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    topButton(cam.layout == .pip ? "rectangle.split.2x1.fill" : "pip",
                              hint: cam.layout == .pip ? "分屏" : "画中画",
                              enabled: true) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            cam.layout = cam.layout == .pip ? .split : .pip
                        }
                    }
                    topButton(cam.flashOn ? "bolt.fill" : "bolt.slash",
                              hint: "闪光灯",
                              enabled: !cam.isRecording) {
                        cam.flashOn.toggle()
                    }
                    topButton(cam.saveRaw ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash",
                              hint: cam.saveRaw ? "存原片" : "仅合成",
                              enabled: !cam.isRecording) {
                        cam.saveRaw.toggle()
                    }
                }

                Spacer()

                if cam.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text(timeString(cam.elapsed))
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .transition(.opacity)
                }

                Spacer()

                HStack(spacing: 10) {
                    if cam.layout == .pip { pipThumb }
                    topButton("arrow.triangle.2.circlepath.camera",
                              hint: "镜头",
                              enabled: !cam.isRecording) {
                        cycleMode()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    // 画中画小窗：点一下互换主/副画面
    private var pipThumb: some View {
        LayerHost(layer: cam.swapped ? cam.layerA : cam.layerB)
            .frame(width: 76, height: 103)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 1.2)
            )
            .shadow(radius: 6)
            .onTapGesture { swapViews() }
    }

    private func topButton(_ icon: String, hint: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.32), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(hint)
    }

    private func cycleMode() {
        let all = CameraMode.allCases
        let idx = all.firstIndex(of: cam.mode) ?? 0
        withAnimation(.easeInOut(duration: 0.25)) {
            cam.mode = all[(idx + 1) % all.count]
        }
    }

    // MARK: 对焦框 / EV 徽章

    @ViewBuilder
    private var focusOverlay: some View {
        if let p = cam.focusIndicator {
            GeometryReader { _ in
                Circle()
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: 76, height: 76)
                    .position(x: p.x, y: p.y)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var evBadge: some View {
        if let ev = cam.evIndicator, let p = cam.focusIndicator {
            HStack(spacing: 4) {
                Image(systemName: "sun.max")
                Text(String(format: "%+.1f", ev))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .position(x: p.x, y: max(p.y - 56, 70))
            .allowsHitTesting(false)
        }
    }

    // MARK: 底部控制区

    private var zoomControl: some View {
        HStack(spacing: 26) {
            zoomLabel(1)
            zoomLabel(2)
            zoomLabel(5)
        }
        .padding(.bottom, 6)
    }

    private func zoomLabel(_ z: Int) -> some View {
        let current = abs(cam.zoom - CGFloat(z)) < 0.15
        return Text("\(z)x")
            .font(.system(size: z == 1 ? 17 : 15, weight: .semibold))
            .foregroundStyle(current ? .white : .white.opacity(0.45))
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                cam.setZoom(CGFloat(z))
            }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            modeBar
                .padding(.bottom, 12)

            HStack {
                sideButton(icon: "arrow.up.arrow.down.circle",
                           label: "换画面",
                           enabled: true) { swapViews() }
                Spacer()
                shutter
                Spacer()
                sideButton(icon: "slider.horizontal.3",
                           label: "参数",
                           enabled: true) { showPanel.toggle() }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 8)
        }
        .padding(.bottom, 6)
    }

    // 底部模式栏：点击切换 + 左右滑动切换（iPhone 原相机风格）
    private var modeBar: some View {
        HStack(spacing: 0) {
            modeItem(.photo)
            modeItem(.video)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    guard !cam.isRecording else { return }
                    if abs(value.translation.width) > 40 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            kind = value.translation.width < 0 ? .video : .photo
                        }
                    }
                }
        )
    }

    private func modeItem(_ k: CaptureKind) -> some View {
        Button {
            guard !cam.isRecording else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { kind = k }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: k.icon)
                Text(k.rawValue)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(kind == k ? .white : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // 双层快门：拍照白色圆环 + 白圆；录像白色圆环 + 白色圆 / 红色方块
    private var shutter: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            switch kind {
            case .photo:
                cam.capture()
            case .video:
                cam.isRecording ? cam.stopRecording() : cam.startRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                if kind == .photo {
                    Circle().fill(.white).frame(width: 64, height: 64)
                } else {
                    if cam.isRecording {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.red)
                            .frame(width: 34, height: 34)
                    } else {
                        Circle().fill(.white).frame(width: 64, height: 64)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!cam.isReady)
        .opacity(cam.isReady ? 1 : 0.4)
    }

    private func sideButton(icon: String, label: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(width: 56)
            .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: 工具

    private func swapViews() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        cam.swapped.toggle()
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
