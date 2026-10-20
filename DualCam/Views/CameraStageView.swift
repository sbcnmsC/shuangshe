import AVFoundation
import SwiftUI

struct CameraStageView: View {
    let rearLayer: AVCaptureVideoPreviewLayer?
    let frontLayer: AVCaptureVideoPreviewLayer?
    let layout: CameraLayout
    let isSwapped: Bool
    @Binding var pipPosition: CGPoint
    @Binding var splitRatio: CGFloat
    let isReady: Bool
    let onSwap: () -> Void

    @State private var dragOrigin: CGPoint?
    @State private var splitOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if layout == .pictureInPicture {
                    CameraPreview(previewLayer: isSwapped ? frontLayer : rearLayer)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    CameraPreview(previewLayer: isSwapped ? rearLayer : frontLayer)
                        .frame(width: geometry.size.width * 0.31, height: geometry.size.height * 0.24)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.95), lineWidth: 2)
                        }
                        .position(x: geometry.size.width * pipPosition.x,
                                  y: geometry.size.height * pipPosition.y)
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    if dragOrigin == nil { dragOrigin = pipPosition }
                                    let origin = dragOrigin ?? pipPosition
                                    pipPosition = CGPoint(
                                        x: min(0.82, max(0.18, origin.x + value.translation.width / geometry.size.width)),
                                        y: min(0.86, max(0.14, origin.y + value.translation.height / geometry.size.height))
                                    )
                                }
                                .onEnded { _ in
                                    let snapX: CGFloat = pipPosition.x < 0.5 ? 0.22 : 0.78
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        pipPosition.x = snapX
                                    }
                                    dragOrigin = nil
                                }
                        )
                        .onTapGesture(perform: onSwap)

                } else {
                    VStack(spacing: 0) {
                        CameraPreview(previewLayer: isSwapped ? frontLayer : rearLayer)
                            .frame(height: max(1, geometry.size.height * splitRatio))
                        Rectangle()
                            .fill(.white.opacity(0.8))
                            .frame(height: 7)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        if splitOrigin == nil { splitOrigin = splitRatio }
                                        splitRatio = min(0.7, max(0.3, (splitOrigin ?? splitRatio) + value.translation.height / geometry.size.height))
                                    }
                                    .onEnded { _ in splitOrigin = nil }
                            )
                        CameraPreview(previewLayer: isSwapped ? rearLayer : frontLayer)
                            .frame(height: max(1, geometry.size.height * (1 - splitRatio)))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }

                VStack {
                    HStack(spacing: 7) {
                        Circle().fill(isReady ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(isReady ? "双摄已连接" : "正在连接相机")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Spacer()
                        Text("竖幅预览")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.46), in: Capsule())
                    .padding(14)
                    Spacer()
                }
                .allowsHitTesting(false)

                if !isReady {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}
