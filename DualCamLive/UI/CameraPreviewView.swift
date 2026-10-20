import CoreImage
import CoreVideo
import Metal
import MetalKit
import SwiftUI

final class PreviewFrameStore {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func publish(_ newBuffer: CVPixelBuffer) { lock.lock(); buffer = newBuffer; lock.unlock() }
    func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}

struct CameraPreviewView: UIViewRepresentable {
    let frameStore: PreviewFrameStore
    func makeCoordinator() -> Renderer { Renderer(frameStore: frameStore) }
    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()!
        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    final class Renderer: NSObject, MTKViewDelegate {
        private let frameStore: PreviewFrameStore
        private let queue: MTLCommandQueue?
        private let context: CIContext
        init(frameStore: PreviewFrameStore) {
            self.frameStore = frameStore
            let device = MTLCreateSystemDefaultDevice()
            queue = device?.makeCommandQueue()
            if let device { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
            else { context = CIContext(options: [.cacheIntermediates: false]) }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer(),
                  let buffer = frameStore.latest() else { return }
            let source = CIImage(cvPixelBuffer: buffer)
            let target = CGRect(origin: .zero, size: CGSize(width: drawable.texture.width, height: drawable.texture.height))
            let scale = max(target.width / source.extent.width, target.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let adjusted = scaled.transformed(by: CGAffineTransform(
                translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY
            ))
            context.render(adjusted, to: drawable.texture, commandBuffer: command, bounds: target,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            command.present(drawable)
            command.commit()
        }
    }
}
