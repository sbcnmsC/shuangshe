import SwiftUI

struct ContentView: View {
    @StateObject private var manager = CameraManager()
    @State private var toolsPresented = false
    @State private var pipDragOrigin: CGPoint?
    @State private var pipResizeOrigin: CGFloat?
    @State private var splitDragOrigin: CGFloat?
    @State private var exposureDragOrigin: Double?
    @State private var zoomGestureOrigin: CGFloat?
    @State private var showingStatus = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                livePreview(in: geometry.size)

                if manager.settings.gridEnabled {
                    thirdsGrid
                        .allowsHitTesting(false)
                }

                // These transparent handles sit over the already-composited preview so the image remains WYSIWYG.
                if manager.settings.layout == .pictureInPicture && manager.isMultiCameraActive {
                    pipInteractionLayer(in: geometry.size)
                } else if manager.settings.layout == .split && manager.isMultiCameraActive {
                    splitInteractionLayer(in: geometry.size)
                }

                VStack(spacing: 0) {
                    topControls
                    Spacer(minLength: 0)
                    if !manager.statusMessage.isEmpty && showingStatus {
                        HStack(spacing: 7) {
                            Circle().fill(manager.isRecording ? .red : .white.opacity(0.65)).frame(width: 5, height: 5)
                            Text(manager.statusMessage).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.28), in: Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity)
                    }
                    bottomControls(in: geometry.size)
                }
                .padding(.top, max(geometry.safeAreaInsets.top, 10))
                .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8))

                if let countdown = manager.countdownText {
                    Text(countdown)
                        .font(.system(size: 100, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 18)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(20)
                        .allowsHitTesting(false)
                }

                if !manager.isRunning && !manager.isStarting {
                    cameraPermissionOverlay
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.18)) { showingStatus.toggle() }
            }
            .sheet(isPresented: $toolsPresented) {
                CameraToolsPanel(manager: manager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(30)
            }
            .task { manager.start() }
            .onDisappear {
                if manager.isRecording { manager.stopRecording() }
                manager.stop()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    @ViewBuilder
    private func livePreview(in size: CGSize) -> some View {
        if let preview = manager.previewImage {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let normalized = normalizedPoint(value.location, in: size)
                    if manager.settings.layout == .split && manager.isMultiCameraActive {
                        let upperHalfHeight = 1 - manager.settings.splitRatio
                        let tappedTop = normalized.y < upperHalfHeight
                        let tappedFront = tappedTop ? manager.settings.mainUsesFrontCamera : !manager.settings.mainUsesFrontCamera
                        if tappedFront != manager.settings.mainUsesFrontCamera { manager.toggleMainCamera() }
                    }
                    manager.focus(at: normalized)
                })
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                    if exposureDragOrigin == nil { exposureDragOrigin = manager.settings.exposureBias }
                    let origin = exposureDragOrigin ?? manager.settings.exposureBias
                    let change = Double(-value.translation.height / max(1, size.height)) * 4
                    manager.setExposureBias(min(2, max(-2, origin + change)))
                }.onEnded { _ in exposureDragOrigin = nil })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if zoomGestureOrigin == nil { zoomGestureOrigin = manager.settings.zoom }
                    let origin = zoomGestureOrigin ?? manager.settings.zoom
                    manager.setZoom(Double(min(10, max(1, origin * value.magnification))))
                }.onEnded { _ in zoomGestureOrigin = nil })
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.11), .black, Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.white.opacity(0.55))
                    Text("DualCam").font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                    Text("正在连接镜头").font(.caption).foregroundStyle(.white.opacity(0.42))
                }
            }.frame(width: size.width, height: size.height)
        }
    }

    private var topControls: some View {
        HStack(spacing: 9) {
            GlassIconButton(symbol: manager.settings.flashEnabled ? "flashlight.on.fill" : "bolt.slash.fill", isActive: manager.settings.flashEnabled, accessibilityLabel: "闪光灯 / 补光灯") {
                manager.toggleFlash()
            }
            GlassIconButton(symbol: manager.settings.timerSeconds == 0 ? "timer" : "timer.circle.fill", isActive: manager.settings.timerSeconds > 0, accessibilityLabel: "定时器") {
                manager.timerButtonPressed()
            }
            GlassIconButton(symbol: manager.settings.layout == .pictureInPicture ? "pip" : "rectangle.split.2x1", isActive: false, accessibilityLabel: "切换布局") {
                withAnimation(.snappy(duration: 0.24)) {
                    manager.settings.layout = manager.settings.layout == .pictureInPicture ? .split : .pictureInPicture
                }
            }
            Spacer(minLength: 3)
            VStack(spacing: 3) {
                Text(manager.isRecording ? formattedDuration(manager.recordingDuration) : manager.actualResolutionText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(manager.isRecording ? "REC" : "\(manager.actualFPS) FPS")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(manager.isRecording ? .red : .white.opacity(0.62))
            }
            .frame(minWidth: 60)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.black.opacity(0.2), in: Capsule())
            .cameraGlass(cornerRadius: 20)
            Spacer(minLength: 3)
            Button {
                manager.cycleLensCombination()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "camera.macro")
                        .font(.system(size: 15, weight: .semibold))
                    Text(manager.currentRearLensLabel).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(width: 43, height: 43)
                .background(.white.opacity(0.1), in: Circle())
                .cameraGlass(cornerRadius: 24)
            }.buttonStyle(.plain).accessibilityLabel("切换镜头组合")
        }
        .padding(.horizontal, 15)
        .padding(.top, 5)
    }

    private func bottomControls(in size: CGSize) -> some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { zoom in
                    Button {
                        manager.setZoom(zoom)
                    } label: {
                        Text(zoom == 1 ? "1×" : String(format: "%.1f×", zoom))
                            .font(.system(size: 12, weight: abs(Double(manager.settings.zoom) - zoom) < 0.2 ? .bold : .medium, design: .rounded))
                            .foregroundStyle(abs(Double(manager.settings.zoom) - zoom) < 0.2 ? .black : .white)
                            .frame(width: 42, height: 32)
                            .background(abs(Double(manager.settings.zoom) - zoom) < 0.2 ? .white : .black.opacity(0.26), in: Capsule())
                            .cameraGlass(cornerRadius: 18)
                    }.buttonStyle(.plain)
                }
            }

            HStack(alignment: .center, spacing: 0) {
                Button {
                    toolsPresented = true
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .medium))
                        Text("工具").font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(.white).frame(width: 58, height: 60)
                }.buttonStyle(.plain)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { manager.settings.captureMode = mode }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: manager.settings.captureMode == mode ? .semibold : .regular))
                                .foregroundStyle(manager.settings.captureMode == mode ? .white : .white.opacity(0.55))
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(manager.settings.captureMode == mode ? .white.opacity(0.18) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(4)
                .cameraGlass(cornerRadius: 24)
                Spacer(minLength: 8)
                Button {
                    manager.shutterPressed()
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.92), lineWidth: 4).frame(width: 70, height: 70)
                        if manager.settings.captureMode == .video && manager.isRecording {
                            RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 25, height: 25)
                        } else {
                            Circle().fill(manager.settings.captureMode == .video ? .red : .white).frame(width: 57, height: 57)
                        }
                    }
                }
                .buttonStyle(ShutterButtonStyle())
                Spacer(minLength: 8)
                Button {
                    manager.settings.gridEnabled.toggle()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: manager.settings.gridEnabled ? "grid" : "square.grid.3x3")
                            .font(.system(size: 19, weight: .medium))
                        Text("构图").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(manager.settings.gridEnabled ? .yellow : .white)
                    .frame(width: 58, height: 60)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 19)
        }
        .padding(.bottom, 12)
    }

    private var thirdsGrid: some View {
        GeometryReader { geo in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geo.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * fraction, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: geo.size.height * fraction))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * fraction))
                }
            }.stroke(.white.opacity(0.38), lineWidth: 0.7)
        }
    }

    private func pipInteractionLayer(in size: CGSize) -> some View {
        let canvas = manager.settings.outputSize
        let displayScale = max(size.width / max(1, canvas.width), size.height / max(1, canvas.height))
        let displayWidth = canvas.width * displayScale
        let displayHeight = canvas.height * displayScale
        let originX = (size.width - displayWidth) / 2
        let originY = (size.height - displayHeight) / 2
        let ratio = manager.settings.pipAspect.ratio
        let width = displayWidth * manager.settings.pipScale
        let height = width / ratio
        let x = originX + displayWidth * manager.settings.pipX
        let y = originY + displayHeight * manager.settings.pipY
        return ZStack {
            RoundedRectangle(cornerRadius: manager.settings.pipShape == .circle ? min(width, height) / 2 : manager.settings.pipCornerRadius * displayScale / 2)
                .fill(.clear)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 23, height: 23)
                        .background(.black.opacity(0.46), in: Circle())
                        .offset(x: 4, y: 4)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                            if pipResizeOrigin == nil { pipResizeOrigin = manager.settings.pipScale }
                            manager.settings.pipScale = min(0.48, max(0.18, (pipResizeOrigin ?? manager.settings.pipScale) + value.translation.width / max(1, displayWidth)))
                        }.onEnded { _ in pipResizeOrigin = nil })
                }
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if pipDragOrigin == nil { pipDragOrigin = CGPoint(x: x, y: y) }
                    let origin = pipDragOrigin ?? CGPoint(x: x, y: y)
                    manager.settings.pipX = min(1 - manager.settings.pipScale / 2, max(manager.settings.pipScale / 2, (origin.x + value.translation.width - originX) / max(1, displayWidth)))
                    let normalizedHeight = manager.settings.pipScale / ratio * canvas.width / max(1, canvas.height)
                    manager.settings.pipY = min(1 - normalizedHeight / 2, max(normalizedHeight / 2, (origin.y + value.translation.height - originY) / max(1, displayHeight)))
                }.onEnded { _ in
                    pipDragOrigin = nil
                    if manager.settings.snapPip { snapPip(in: size) }
                })
                .onTapGesture {
                    manager.toggleMainCamera()
                    manager.focus(at: CGPoint(x: 0.5, y: 0.5))
                }
                .position(x: x, y: y)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(true)
    }

    private func splitInteractionLayer(in size: CGSize) -> some View {
        let canvas = manager.settings.outputSize
        let displayScale = max(size.width / max(1, canvas.width), size.height / max(1, canvas.height))
        let displayHeight = canvas.height * displayScale
        let originY = (size.height - displayHeight) / 2
        let dividerY = originY + displayHeight * (1 - manager.settings.splitRatio)
        return ZStack {
            Capsule().fill(.white.opacity(0.9)).frame(width: 48, height: 4)
                .padding(.vertical, 10)
                .frame(width: size.width, height: 30)
                .background(.black.opacity(0.22), in: Capsule())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if splitDragOrigin == nil { splitDragOrigin = manager.settings.splitRatio }
                    manager.settings.splitRatio = min(0.75, max(0.25, (splitDragOrigin ?? manager.settings.splitRatio) - value.translation.height / max(1, displayHeight)))
                }.onEnded { _ in splitDragOrigin = nil })
                .position(x: size.width / 2, y: dividerY)
        }.frame(width: size.width, height: size.height)
    }

    private var cameraPermissionOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 34, weight: .light))
            Text("需要相机权限").font(.headline)
            Text(manager.statusMessage).font(.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.65))
            Button("重新尝试") { manager.start() }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(.white, in: Capsule()).foregroundStyle(.black)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .cameraGlass(cornerRadius: 26)
    }

    private func normalizedPoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint {
        let canvas = manager.settings.outputSize
        let displayScale = max(viewSize.width / max(1, canvas.width), viewSize.height / max(1, canvas.height))
        let displayWidth = canvas.width * displayScale
        let displayHeight = canvas.height * displayScale
        let originX = (viewSize.width - displayWidth) / 2
        let originY = (viewSize.height - displayHeight) / 2
        return CGPoint(x: min(1, max(0, (point.x - originX) / max(1, displayWidth))), y: min(1, max(0, (point.y - originY) / max(1, displayHeight))))
    }

    private func snapPip(in size: CGSize) {
        let canvas = manager.settings.outputSize
        let horizontalHalf = manager.settings.pipScale / 2
        let verticalHalf = manager.settings.pipScale / manager.settings.pipAspect.ratio * canvas.width / max(1, canvas.height) / 2
        let xStops: [CGFloat] = [horizontalHalf, 0.5, 1 - horizontalHalf]
        let yStops: [CGFloat] = [verticalHalf, 0.5, 1 - verticalHalf]
        manager.settings.pipX = xStops.min(by: { abs($0 - manager.settings.pipX) < abs($1 - manager.settings.pipX) }) ?? manager.settings.pipX
        manager.settings.pipY = yStops.min(by: { abs($0 - manager.settings.pipY) < abs($1 - manager.settings.pipY) }) ?? manager.settings.pipY
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1).animation(.spring(response: 0.24, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
