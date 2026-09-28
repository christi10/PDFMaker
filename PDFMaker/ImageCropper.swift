import UIKit
import Vision
import CoreImage.CIFilterBuiltins

/// Four crop corners — top-left, top-right, bottom-right, bottom-left —
/// normalised to 0...1 with the origin at the image's top-left.
struct Quad: Equatable, Codable {
    var points: [CGPoint]

    static let full = Quad(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])

    /// The same corners once the image is turned 90° clockwise.
    var rotatedClockwise: Quad {
        let turned = points.map { CGPoint(x: 1 - $0.y, y: $0.x) }
        // The old bottom-left corner becomes the new top-left, and so on.
        return Quad(points: [turned[3], turned[0], turned[1], turned[2]])
    }
}

enum ImageCropper {
    private static let context = CIContext()

    /// Finds the edges of a document (paper, receipt, card…) in the photo.
    static func detectDocument(in image: UIImage) -> Quad? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        guard let found = request.results?.first else { return nil }
        // Vision's origin is bottom-left; ours is top-left.
        let corners = [found.topLeft, found.topRight, found.bottomRight, found.bottomLeft]
        return Quad(points: corners.map { CGPoint(x: $0.x, y: 1 - $0.y) })
    }

    /// Cuts out the area inside `quad` and straightens it into a rectangle.
    static func crop(_ image: UIImage, to quad: Quad) -> UIImage {
        guard quad != .full, let cgImage = image.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let width = input.extent.width, height = input.extent.height
        let corners = quad.points.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = corners[0]
        filter.topRight = corners[1]
        filter.bottomRight = corners[2]
        filter.bottomLeft = corners[3]
        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: result)
    }
}
