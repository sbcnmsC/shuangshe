import SwiftUI

enum CaptureKind: String, CaseIterable, Identifiable {
    case photo = "拍照"
    case video = "录像"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var cam = DualCameraManager()
    @State private var kind: CaptureKind = .photo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            preview

            VStack(spacing: 0) {
                topBar
                Spacer()
                controls
            }

            if let text = cam.statusText {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cam.statusText)
        .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        .onAppear { cam.start() }
        .onChange(of: cam.mode) { _, _ in
            cam.swapped = false
            cam.reconfigure()
        }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? cam.resume() : cam.pause()
        }
    }

    // MARK: 预览

    @ViewBuilder
    private var preview: some View {
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
            .onTapGesture { swapViews() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(timeString(cam.elapsed))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if cam.layout == .pip { pip }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // 画中画小窗：点一下互换主/副画面
    private var pip: some View {
        LayerHost(layer: cam.swapped ? cam.layerA : cam.layerB)
            .frame(width: 110, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
            )
            .shadow(radius: 8)
            .onTapGesture { swapViews() }
    }

    // MARK: 控制区

    private var controls: some View {
        VStack(spacing: 14) {
            Picker("摄像头", selection: $cam.mode) {
                ForEach(CameraMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(cam.isRecording)

            Picker("布局", selection: $cam.layout) {
                ForEach(LayoutMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("类型", selection: $kind) {
                ForEach(CaptureKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(cam.isRecording)

            HStack {
                Button {
                    cam.saveRaw.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: cam.saveRaw ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash")
                            .font(.title3)
                        Text(cam.saveRaw ? "存原片" : "仅合成")
                            .font(.caption2)
                    }
                    .frame(width: 64)
                }
                .disabled(cam.isRecording)

                Spacer()
                shutter
                Spacer()

                Button { swapViews() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.title3)
                        Text("换画面").font(.caption2)
                    }
                    .frame(width: 64)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

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
                    let side: CGFloat = cam.isRecording ? 34 : 64
                    RoundedRectangle(cornerRadius: cam.isRecording ? 8 : side / 2, style: .continuous)
                        .fill(.red)
                        .frame(width: side, height: side)
                }
            }
        }
        .disabled(!cam.isReady)
        .opacity(cam.isReady ? 1 : 0.4)
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
