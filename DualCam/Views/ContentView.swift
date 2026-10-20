import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var layout: CameraLayout = .pictureInPicture
    @State private var isSwapped = false
    @State private var timerSeconds = 0
    @State private var countdownValue: Int?
    @State private var pipPosition = CGPoint(x: 0.75, y: 0.22)
    @State private var splitRatio: CGFloat = 0.5
    @State private var isCapturing = false
    @State private var alertMessage: String?
    @State private var countdownTask: Task<Void, Never>?

    private let accent = Color(red: 1.0, green: 0.83, blue: 0.34)

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 15) {
                topBar

                CameraStageView(
                    rearLayer: camera.rearPreviewLayer,
                    frontLayer: camera.frontPreviewLayer,
                    layout: layout,
                    isSwapped: isSwapped,
                    pipPosition: $pipPosition,
                    splitRatio: $splitRatio,
                    isReady: camera.isRunning,
                    onSwap: { withAnimation(.easeInOut(duration: 0.2)) { isSwapped.toggle() } }
                )
                .aspectRatio(0.68, contentMode: .fit)
                .padding(.horizontal, 17)
                .overlay(alignment: .center) {
                    if let countdownValue {
                        Text("\(countdownValue)")
                            .font(.system(size: 76, weight: .light, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 18)
                    }
                }

                capturePanel
                    .padding(.horizontal, 24)

                Text("轻点小窗可交换镜头 · 拖动小窗调整位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.bottom, 4)
            }
            .padding(.top, 7)
            .padding(.bottom, 8)
        }
        .onAppear { camera.requestAccessAndStart() }
        .onDisappear { countdownTask?.cancel() }
        .onChange(of: camera.errorMessage) { _, newValue in
            if let newValue { alertMessage = newValue }
        }
        .alert("DualCam", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DUALCAM")
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                Text("双摄相机")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer()

            topButton(systemName: camera.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill", title: "补光") {
                camera.toggleTorch()
            }
            topButton(systemName: "timer", title: timerTitle) {
                cycleTimer()
            }
            topButton(systemName: layout == .pictureInPicture ? "rectangle.inset.filled" : "rectangle.split.2x1", title: layout == .pictureInPicture ? "画中画" : "分屏") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    layout = layout == .pictureInPicture ? .split : .pictureInPicture
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private var capturePanel: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                modePill("照片", selected: true)
                modePill("视频", selected: false, disabled: true)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isSwapped.toggle() }
                } label: {
                    Label("交换镜头", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center) {
                VStack(spacing: 5) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 18, weight: .medium))
                    Text("9:16")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 52)

                Spacer()

                Button(action: beginCapture) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.95), lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(accent).frame(width: 62, height: 62)
                        if isCapturing {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCapturing || !camera.isRunning)
                .accessibilityLabel("拍照并保存")

                Spacer()

                VStack(spacing: 5) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 18, weight: .medium))
                    Text("双摄")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 52)
            }

            Text(isCapturing ? "正在合成并保存…" : "拍摄合成照片")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var timerTitle: String {
        timerSeconds == 0 ? "关闭" : "\(timerSeconds)秒"
    }

    private func topButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.88))
            .frame(width: 51, height: 53)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func modePill(_ title: String, selected: Bool, disabled: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? .black : .white.opacity(0.45))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(selected ? accent : .white.opacity(0.07), in: Capsule())
            .opacity(disabled ? 0.62 : 1)
            .accessibilityLabel(disabled ? "\(title)，尚未实现" : title)
    }

    private func cycleTimer() {
        switch timerSeconds {
        case 0: timerSeconds = 3
        case 3: timerSeconds = 10
        default: timerSeconds = 0
        }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        if timerSeconds > 0 {
            countdownTask?.cancel()
            countdownTask = Task { @MainActor in
                for remaining in stride(from: timerSeconds, through: 1, by: -1) {
                    countdownValue = remaining
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { countdownValue = nil; return }
                }
                countdownValue = nil
                captureNow()
            }
        } else {
            captureNow()
        }
    }

    private func captureNow() {
        guard camera.isRunning else {
            alertMessage = "相机还没有准备好。"
            return
        }
        isCapturing = true
        camera.capturePhoto { result in
            switch result {
            case .success(let pair):
                let image = PhotoComposer.compose(
                    rear: pair.rear,
                    front: pair.front,
                    layout: layout,
                    swapped: isSwapped,
                    pipPosition: pipPosition,
                    splitRatio: splitRatio
                )
                PhotoLibrarySaver.save(image) { saveResult in
                    DispatchQueue.main.async {
                        isCapturing = false
                        switch saveResult {
                        case .success:
                            alertMessage = "照片已保存到系统「照片」App。"
                        case .failure(let error):
                            alertMessage = error.localizedDescription
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    isCapturing = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }
}
