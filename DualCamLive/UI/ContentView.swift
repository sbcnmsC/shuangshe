import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: CaptureSettings
    @EnvironmentObject private var camera: DualCameraSessionModel
    @State private var showTools = false
    @State private var pipOffset = CGSize.zero
    @State private var modeVideo = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreviewView(frameStore: camera.frameStore).ignoresSafeArea()
                if settings.showGrid { GridOverlay().stroke(.white.opacity(0.32), lineWidth: 0.6).allowsHitTesting(false) }
                if settings.layout == .pictureInPicture {
                    RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: geometry.size.width * settings.pipRect.width, height: geometry.size.height * settings.pipRect.height)
                        .position(x: geometry.size.width * settings.pipRect.midX + pipOffset.width,
                                  y: geometry.size.height * settings.pipRect.midY + pipOffset.height)
                        .gesture(DragGesture().onChanged { pipOffset = $0.translation }.onEnded { value in
                            if settings.snapToEdge {
                                let x = geometry.size.width * settings.pipRect.midX + value.translation.width
                                pipOffset.width = (x < geometry.size.width / 2 ? 1 : -1) * 0
                            }
                            var rect = settings.pipRect
                            rect.origin.x = min(max((rect.midX * geometry.size.width + value.translation.width) / geometry.size.width - rect.width / 2, 0), 1 - rect.width)
                            rect.origin.y = min(max((rect.midY * geometry.size.height + value.translation.height) / geometry.size.height - rect.height / 2, 0), 1 - rect.height)
                            settings.pipRect = rect
                            pipOffset = .zero
                            camera.apply(settings: settings)
                        })
                }
                VStack {
                    HStack {
                        Button { settings.showGrid.toggle() } label: { Image(systemName: "grid").frame(width: 42, height: 42) }
                            .adaptiveGlass(in: Circle(), interactive: true)
                        Button { settings.primaryFront.toggle(); camera.apply(settings: settings) } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 42, height: 42)
                        }.adaptiveGlass(in: Circle(), interactive: true)
                        Spacer()
                        VStack(spacing: 3) {
                            Text("DUALCAM").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2)
                            Text(camera.statusText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                        Button { showTools = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 42, height: 42) }
                            .adaptiveGlass(in: Circle(), interactive: true)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 12)
                    Spacer()
                    VStack(spacing: 15) {
                        HStack(spacing: 28) {
                            Button("拍照") { modeVideo = false }
                                .foregroundStyle(modeVideo ? .white.opacity(0.55) : .white)
                            Button("录像") { modeVideo = true }
                                .foregroundStyle(modeVideo ? .white : .white.opacity(0.55))
                        }.padding(.horizontal, 22).padding(.vertical, 9).adaptiveGlass(in: Capsule())
                        HStack {
                            Button { camera.takePhoto() } label: {
                                Image(systemName: "square.stack.3d.up").font(.system(size: 22)).frame(width: 52, height: 52)
                            }.adaptiveGlass(in: Circle(), interactive: true)
                            Spacer()
                            Button {
                                if camera.isRecording { camera.stopRecording() }
                                else if modeVideo { camera.startRecording() }
                                else { camera.takePhoto() }
                            } label: {
                                ZStack {
                                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                                    if camera.isRecording { RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 28, height: 28) }
                                    else { Circle().fill(modeVideo ? .red : .white).frame(width: 60, height: 60) }
                                }.frame(width: 82, height: 82)
                            }.disabled(!camera.isRunning)
                            Spacer()
                            Button { settings.layout = settings.layout == .pictureInPicture ? .split : .pictureInPicture; camera.apply(settings: settings) } label: {
                                Image(systemName: "rectangle.split.2x1").font(.system(size: 22)).frame(width: 52, height: 52)
                            }.adaptiveGlass(in: Circle(), interactive: true)
                        }.foregroundStyle(.white).padding(.horizontal, 28)
                    }.padding(.bottom, 22)
                }
            }
        }
        .sheet(isPresented: $showTools) { ToolPanelView().presentationDetents([.medium, .large]).presentationDragIndicator(.hidden) }
        .onAppear { camera.start(settings: settings) }
        .onDisappear { camera.stop() }
        .onChange(of: settings.layout) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.primaryFront) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.pipRect) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.cornerRadius) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.filter) { _, _ in camera.apply(settings: settings) }
        .onChange(of: settings.filterStrength) { _, _ in camera.apply(settings: settings) }
        .alert("相机提示", isPresented: Binding(get: { camera.lastError != nil }, set: { if !$0 { camera.lastError = nil } })) {
            Button("确定", role: .cancel) { camera.lastError = nil }
        } message: { Text(camera.lastError ?? "") }
    }
}

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            let y = rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}
