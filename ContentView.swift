import SwiftUI
import AVFoundation

enum CaptureKind: String, CaseIterable, Identifiable {
    case photo = "拍照"
    case video = "录像"
    case live = "实况"
    var id: String { rawValue }
}

/// 主界面（Liquid Glass 风格）：
/// 预览显示的就是最终合成帧（所见即所得）；小窗可拖动 / 捏合 / 拖角缩放；
/// 点按对焦、上下滑动调曝光、双指变焦；底部玻璃工具面板里有小窗、滤镜、参数、设置。
struct ContentView: View {
    @StateObject private var cam = DualCameraManager()
    @State private var kind: CaptureKind = .photo
    @State private var showPanel = false
    @State private var tab: PanelTab = .pip
    @State private var showGallery = false

    // 预览手势状态
    @State private var pinchBase: CGFloat?
    @State private var evStart: Float?
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0

    // 小窗手势状态
    @State private var pipDragStart: CGPoint?
    @State private var pipPinchBase: CGFloat?
    @State private var pipResizeBase: CGFloat?
    @State private var pipActive = false
    @State private var pipHideWork: DispatchWorkItem?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let rect = previewRect(in: geo.size)
            ZStack {
                previewArea(rect: rect)

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomArea
                }

                if let text = cam.statusText {
                    Text(text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .liquidGlass(Capsule(), interactive: false)
                        .frame(maxWidth: geo.size.width - 40)
                        .position(x: geo.size.width / 2, y: rect.minY + 46)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showPanel)
        .animation(.easeInOut(duration: 0.2), value: cam.statusText)
        .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        .animation(.easeInOut(duration: 0.25), value: cam.canvasSize)
        .onAppear {
            cam.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? cam.resume() : cam.pause()
        }
        .sheet(isPresented: $showGallery) { MediaGalleryView() }
    }

    // MARK: - 预览

    /// 预览区域：按输出画幅等比显示，顶部给玻璃工具栏留位置。
    private func previewRect(in size: CGSize) -> CGRect {
        let ratio = cam.canvasSize.width / max(cam.canvasSize.height, 1)
        let top: CGFloat = 54
        let maxH = max(size.height - top - 4, 100)
        var w = size.width
        var h = w / ratio
        if h > maxH {
            h = maxH
            w = h * ratio
        }
        return CGRect(x: (size.width - w) / 2, y: top, width: w, height: h)
    }

    private func previewArea(rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            DisplayLayerView(displayLayer: cam.displayLayer)

            gestureSurface(rect: rect)

            if cam.showGrid {
                GridLines()
                    .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }

            if cam.layout == .pip {
                pipOverlay(rect: rect)
            } else {
                splitHint(rect: rect)
            }

            focusIndicatorView
            evBadge

            if let n = cam.countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.4), radius: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named("previewSpace"))
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .position(x: rect.midX, y: rect.midY)
    }

    /// 全画面手势：点按对焦 / 曝光，上下滑动调曝光补偿，双指捏合变焦。
    private func gestureSurface(rect: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard rect.width > 0, rect.height > 0 else { return }
                cam.tapFocus(u: location.x / rect.width, v: location.y / rect.height)
                showFocus(at: location)
            }
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        if evStart == nil { evStart = cam.ev }
                        cam.setEV((evStart ?? 0) - Float(value.translation.height / 220))
                    }
                    .onEnded { _ in evStart = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = cam.zoom }
                        cam.setZoom((pinchBase ?? 1) * value)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
    }

    // MARK: 小窗（可拖动 / 捏合 / 拖角缩放，点一下互换主副画面）

    @ViewBuilder
    private func pipOverlay(rect: CGRect) -> some View {
        let r = cam.pip.rect(in: rect.size)
        let shape: AnyShape = cam.pip.shape == .circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cam.pip.cornerRadius(for: r.size), style: .continuous))

        shape
            .stroke(Color.white.opacity(pipActive ? 0.9 : 0), lineWidth: 2)
            .contentShape(shape)
            .frame(width: r.width, height: r.height)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("previewSpace"))
                    .onChanged { value in
                        touchPip()
                        if pipDragStart == nil {
                            pipDragStart = CGPoint(x: cam.pip.centerX, y: cam.pip.centerY)
                        }
                        guard let s = pipDragStart else { return }
                        cam.movePip(toCenterX: s.x + value.translation.width / rect.width,
                                    y: s.y + value.translation.height / rect.height)
                    }
                    .onEnded { _ in
                        pipDragStart = nil
                        cam.finishPipDrag()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        touchPip()
                        if pipPinchBase == nil { pipPinchBase = cam.pip.width }
                        cam.resizePip(width: (pipPinchBase ?? 0.3) * value)
                    }
                    .onEnded { _ in
                        pipPinchBase = nil
                        cam.finishPipDrag()
                    }
            )
            .onTapGesture {
                cam.tapFocus(u: r.midX / max(rect.width, 1),
                             v: r.midY / max(rect.height, 1))
                showFocus(at: CGPoint(x: r.midX, y: r.midY))
                swapViews()
            }
            .position(x: r.midX, y: r.midY)

        if pipActive || (showPanel && tab == .pip) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .liquidGlass(Circle())
                .contentShape(Circle())
                .position(x: r.maxX - 16, y: r.maxY - 16)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("previewSpace"))
                        .onChanged { value in
                            touchPip()
                            if pipResizeBase == nil { pipResizeBase = cam.pip.width }
                            let delta = (value.translation.width + value.translation.height) / rect.width
                            cam.resizePip(width: (pipResizeBase ?? 0.3) + delta)
                        }
                        .onEnded { _ in
                            pipResizeBase = nil
                            cam.finishPipDrag()
                        }
                )
                .transition(.opacity)
        }
    }

    /// 分屏模式下，在分割线上放一个玻璃把手，上下拖动调整比例。
    @ViewBuilder
    private func splitHint(rect: CGRect) -> some View {
        let y = rect.height * cam.splitRatio
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 44, height: 5)
            .padding(10)
            .contentShape(Rectangle())
            .position(x: rect.width / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("previewSpace"))
                    .onChanged { value in
                        let ratio = value.location.y / rect.height
                        cam.splitRatio = min(max(ratio, 0.3), 0.7)
                    }
            )
    }

    /// 拖动 / 缩放小窗时显示轮廓和缩放把手，停手 2 秒后淡出。
    private func touchPip() {
        if !pipActive { pipActive = true }
        pipHideWork?.cancel()
        let work = DispatchWorkItem { pipActive = false }
        pipHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: 对焦框 / EV 徽章

    @ViewBuilder
    private var focusIndicatorView: some View {
        if let p = focusPoint {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)
                .position(p)
                .allowsHitTesting(false)
                .transition(.scale(scale: 1.3).combined(with: .opacity))
        }
    }

    private func showFocus(at p: CGPoint) {
        withAnimation(.easeOut(duration: 0.18)) { focusPoint = p }
        focusToken += 1
        let token = focusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if focusToken == token {
                withAnimation(.easeOut(duration: 0.2)) { focusPoint = nil }
            }
        }
    }

    @ViewBuilder
    private var evBadge: some View {
        if let ev = cam.evIndicator {
            HStack(spacing: 5) {
                Image(systemName: "sun.max.fill")
                Text(String(format: "%+.1f", ev))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .liquidGlass(Capsule(), interactive: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        glassIcon(cam.flashOn ? "bolt.fill" : "bolt.slash",
                                  label: "闪光灯", active: cam.flashOn,
                                  enabled: !cam.isRecording) { cam.flashOn.toggle() }
                        timerButton
                        glassIcon(cam.layout == .pip ? "rectangle.split.2x1" : "pip",
                                  label: cam.layout == .pip ? "切换到分屏" : "切换到画中画") {
                            cam.layout = cam.layout == .pip ? .split : .pip
                        }
                    }
                }
                Spacer()
                lensButton
            }
            centerBadge
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func glassIcon(_ systemName: String, label: String,
                           active: Bool = false, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.black : Color.white)
        .liquidGlass(Capsule(), tint: active ? Color.yellow : nil)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private var timerButton: some View {
        let on = cam.timerSeconds > 0
        return Button {
            haptic(.light)
            cam.cycleTimer()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                if on {
                    Text("\(cam.timerSeconds)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, on ? 6 : 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.black : Color.white)
        .liquidGlass(Capsule(), tint: on ? Color.yellow : nil)
        .accessibilityLabel("定时器")
    }

    /// Tap the label to cycle quickly; use the adjacent menu to choose a specific pair.
    private var lensButton: some View {
        HStack(spacing: 0) {
            Button {
                haptic(.light)
                let all = CameraMode.allCases
                let idx = all.firstIndex(of: cam.mode) ?? 0
                cam.mode = all[(idx + 1) % all.count]
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                    Text(cam.mode.shortName)
                        .font(.system(size: 13, weight: .semibold))
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.leading, 13)
                .padding(.trailing, 8)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("循环切换镜头组合")

            Menu {
                ForEach(CameraMode.allCases) { candidate in
                    Button {
                        cam.mode = candidate
                    } label: {
                        if candidate == cam.mode {
                            Label(candidate.rawValue, systemImage: "checkmark")
                        } else {
                            Text(candidate.rawValue)
                        }
                    }
                    .disabled(cam.isRecording)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择镜头组合")
            .disabled(cam.isRecording)
        }
        .foregroundStyle(Color.white)
        .liquidGlass(Capsule())
        .disabled(cam.isRecording)
        .opacity(cam.isRecording ? 0.4 : 1)
    }

    @ViewBuilder
    private var centerBadge: some View {
        if cam.isRecording {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text(timeString(cam.elapsed))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlass(Capsule(), interactive: false)
            .allowsHitTesting(false)
            .transition(.opacity)
        } else {
            Text("\(Int(cam.canvasSize.width))p · \(cam.activeFPS)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlass(Capsule(), interactive: false)
        }
    }

    // MARK: - 底部

    private var bottomArea: some View {
        VStack(spacing: 14) {
            if showPanel {
                ControlPanel(cam: cam, tab: $tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 14) {
                    zoomPill
                    modeSelector
                }
                .transition(.opacity)
            }
            shutterRow
        }
        .padding(.bottom, 8)
    }

    private var zoomPill: some View {
        HStack(spacing: 4) {
            ForEach(cam.zoomStops, id: \.self) { z in
                let on = isNear(z)
                Button {
                    haptic(.light)
                    cam.setZoom(z, animated: true)
                } label: {
                    Text(zoomText(z, on: on))
                        .font(.system(size: on ? 15 : 13, weight: .semibold, design: .rounded))
                        .frame(width: 42, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? Color.yellow : Color.white)
                .background {
                    if on { Circle().fill(Color.white.opacity(0.18)) }
                }
            }
            if !cam.zoomStops.contains(where: { isNear($0) }) {
                Text(zoomText(cam.zoom, on: true))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.yellow)
                    .frame(minWidth: 48, minHeight: 40)
            }
        }
        .padding(4)
        .liquidGlass(Capsule())
    }

    private func isNear(_ z: CGFloat) -> Bool {
        abs(cam.zoom - z) < max(0.06, z * 0.05)
    }

    private func zoomText(_ z: CGFloat, on: Bool) -> String {
        let s = abs(z - z.rounded()) < 0.05 ? String(format: "%.0f", z) : String(format: "%.1f", z)
        return on ? s + "×" : s
    }

    // 底部模式栏：点击切换 + 左右滑动切换
    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureKind.allCases) { k in
                Button {
                    guard !cam.isRecording else { return }
                    haptic(.light)
                    withAnimation(.easeInOut(duration: 0.2)) { kind = k }
                } label: {
                    Text(k.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(kind == k ? Color.yellow : Color.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 9)
                        .background {
                            if kind == k { Capsule().fill(Color.white.opacity(0.2)) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .liquidGlass(Capsule())
        // Simultaneous swipe avoids stealing taps from individual mode buttons.
        .simultaneousGesture(
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard !cam.isRecording, abs(value.translation.width) > 42,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    let all = CaptureKind.allCases
                    let current = all.firstIndex(of: kind) ?? 0
                    let next = value.translation.width < 0 ? min(current + 1, all.count - 1) : max(current - 1, 0)
                    withAnimation(.easeInOut(duration: 0.16)) { kind = all[next] }
                }
        )
    }

    private var shutterRow: some View {
        GlassGroup(spacing: 16) {
            HStack {
                glassCircle("photo.on.rectangle.angled", label: "照片图库") { showGallery = true }
                Spacer()
                shutter
                Spacer()
                glassCircle(showPanel ? "chevron.down" : "slider.horizontal.3",
                            label: "工具面板", active: showPanel) { showPanel.toggle() }
            }
        }
        .padding(.horizontal, 36)
    }

    private func glassCircle(_ systemName: String, label: String,
                             active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            haptic(.light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.black : Color.white)
        .liquidGlass(Circle(), tint: active ? Color.yellow : nil)
        .accessibilityLabel(label)
    }

    // 双层快门：白色圆环 + 内圈（拍照白色 / 录像红色，录制中变红色圆角方块 / 倒计时显示数字）
    private var shutter: some View {
        Button {
            haptic(.medium)
            if kind == .live { cam.livePhotoAction() } else { cam.shutterAction(video: kind == .video) }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                if cam.countdown != nil {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white)
                } else if kind == .photo {
                    Circle().fill(Color.white).frame(width: 64, height: 64)
                } else if kind == .live {
                    Image(systemName: "livephoto")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                } else if cam.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle().fill(Color.red).frame(width: 64, height: 64)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!cam.isReady)
        .opacity(cam.isReady ? 1 : 0.4)
        .accessibilityLabel(kind == .photo ? "拍照" : (kind == .live ? "拍摄实况照片" : (cam.isRecording ? "停止录像" : "开始录像")))
    }

    // MARK: - 工具

    private func swapViews() {
        haptic(.light)
        cam.swapped.toggle()
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
