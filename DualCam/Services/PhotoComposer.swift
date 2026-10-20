import UIKit

enum PhotoComposer {
    static func compose(
        rear: UIImage,
        front: UIImage,
        layout: CameraLayout,
        swapped: Bool,
        pipPosition: CGPoint,
        splitRatio: CGFloat
    ) -> UIImage {
        let canvas = CGSize(width: 1080, height: 1920)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let primary = swapped ? front : rear
        let secondary = swapped ? rear : front

        return renderer.image { rendererContext in
            UIColor.black.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: canvas))
            let context = rendererContext.cgContext

            switch layout {
            case .pictureInPicture:
                drawAspectFill(primary, in: CGRect(origin: .zero, size: canvas), context: context)
                let inset = CGRect(
                    x: max(18, min(canvas.width - 330, pipPosition.x * canvas.width - 150)),
                    y: max(24, min(canvas.height - 450, pipPosition.y * canvas.height - 215)),
                    width: 300,
                    height: 400
                )
                let insetPath = UIBezierPath(roundedRect: inset, cornerRadius: 34)
                context.saveGState()
                insetPath.addClip()
                drawAspectFill(secondary, in: inset, context: context)
                context.restoreGState()
                UIColor.white.withAlphaComponent(0.92).setStroke()
                insetPath.lineWidth = 5
                insetPath.stroke()

            case .split:
                let ratio = max(0.3, min(0.7, splitRatio))
                let divider: CGFloat = 5
                let firstHeight = (canvas.height - divider) * ratio
                let first = CGRect(x: 0, y: 0, width: canvas.width, height: firstHeight)
                let second = CGRect(x: 0, y: firstHeight + divider, width: canvas.width, height: canvas.height - firstHeight - divider)
                drawAspectFill(primary, in: first, context: context)
                drawAspectFill(secondary, in: second, context: context)
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: firstHeight, width: canvas.width, height: divider))
            }
        }
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect, context: CGContext) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawnSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawnRect = CGRect(
            x: rect.midX - drawnSize.width / 2,
            y: rect.midY - drawnSize.height / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: drawnRect)
        context.restoreGState()
    }
}
