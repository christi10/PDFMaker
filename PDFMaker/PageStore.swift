import SwiftUI
import PhotosUI

/// One page of the PDF. Images are kept as compressed JPEG so a long list of
/// pages stays light on memory; the thumbnail is what the list shows.
struct Page: Identifiable {
    var id = UUID()
    /// The upright photo as imported; crops are always cut from this, so a
    /// page can be re-cropped (or un-cropped) any time.
    var original: Data
    /// Crop corners on `original`; nil means the whole photo.
    var quad: Quad?
    /// What goes into the PDF.
    var jpeg: Data
    var thumbnail: UIImage

    /// Longest side of a stored page — about 300 dpi on A4, plenty for documents.
    static let maxDimension: CGFloat = 2500

    init?(image: UIImage) {
        let full = image.redrawn(maxDimension: Page.maxDimension)
        guard let jpeg = full.jpegData(compressionQuality: 0.8) else { return nil }
        self.original = jpeg
        self.jpeg = jpeg
        self.thumbnail = full.redrawn(maxDimension: 240)
    }

    init(id: UUID, original: Data, quad: Quad?, jpeg: Data, thumbnail: UIImage) {
        self.id = id
        self.original = original
        self.quad = quad
        self.jpeg = jpeg
        self.thumbnail = thumbnail
    }

    /// The same page cut from `original` with the given corners.
    func cropped(to quad: Quad?) -> Page? {
        guard let source = UIImage(data: original) else { return nil }
        let image = quad.map { ImageCropper.crop(source, to: $0) } ?? source
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        var page = self
        page.quad = quad
        page.jpeg = jpeg
        page.thumbnail = image.redrawn(maxDimension: 240)
        return page
    }
}

enum PageSize: String, CaseIterable, Identifiable, Codable {
    case a4 = "A4"
    case image = "Same as image"

    var id: Self { self }
}

/// The document being assembled: its pages and settings, undo/redo, import and export.
@MainActor
@Observable
final class PageStore {
    private(set) var pages: [Page] = []
    var name = PageStore.defaultName() { didSet { hasChanges = true } }
    var pageSize: PageSize = .a4 { didSet { hasChanges = true } }
    /// The History entry this document is saved as.
    private(set) var documentID = UUID()
    /// True when there are edits that aren't saved to History yet.
    var hasChanges = false

    private var undoStack: [[Page]] = []
    private var redoStack: [[Page]] = []
    private var jobs = 0

    var isWorking: Bool { jobs > 0 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Documents

    func startNew() {
        load(id: UUID(), name: PageStore.defaultName(), pageSize: .a4, pages: [])
    }

    func load(id: UUID, name: String, pageSize: PageSize, pages: [Page]) {
        documentID = id
        self.name = name
        self.pageSize = pageSize
        self.pages = pages
        undoStack = []
        redoStack = []
        hasChanges = false
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scan \(formatter.string(from: .now))"
    }

    // MARK: - Editing

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pages)
        pages = previous
        hasChanges = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pages)
        pages = next
        hasChanges = true
    }

    func delete(at offsets: IndexSet) {
        update { $0.remove(atOffsets: offsets) }
    }

    func move(from source: IndexSet, to destination: Int) {
        update { $0.move(fromOffsets: source, toOffset: destination) }
    }

    func add(images: [UIImage]) async {
        await append { images.compactMap(Page.init(image:)) }
    }

    func add(photos items: [PhotosPickerItem]) async {
        await append {
            var pages: [Page] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let page = Page(image: image) {
                    pages.append(page)
                }
            }
            return pages
        }
    }

    func add(files urls: [URL]) async {
        await append {
            urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
                return Page(image: image)
            }
        }
    }

    func rotate(_ page: Page) {
        guard let index = pages.firstIndex(where: { $0.id == page.id }),
              let source = UIImage(data: page.original),
              let original = source.rotatedClockwise().jpegData(compressionQuality: 0.8) else { return }
        var turned = page
        turned.original = original
        guard let rotated = turned.cropped(to: page.quad?.rotatedClockwise) else { return }
        update { $0[index] = rotated }
    }

    func crop(_ page: Page, to quad: Quad) async {
        jobs += 1
        defer { jobs -= 1 }
        let keep = quad == .full ? nil : quad
        guard keep != page.quad else { return }
        let result = await Task.detached(priority: .userInitiated) { page.cropped(to: keep) }.value
        guard let result, let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        update { $0[index] = result }
    }

    /// Applies a change to the pages, remembering the old ones for undo.
    private func update(_ change: (inout [Page]) -> Void) {
        undoStack.append(pages)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&pages)
        hasChanges = true
    }

    // MARK: - Export

    /// Writes every page into one PDF and returns its file URL.
    func makePDF() async throws -> URL {
        let pages = self.pages, name = self.name, pageSize = self.pageSize
        jobs += 1
        defer { jobs -= 1 }
        return try await Task.detached(priority: .userInitiated) {
            try PDFBuilder.write(pages, name: name, pageSize: pageSize)
        }.value
    }

    /// Runs the (slow) image decoding and resizing off the main thread.
    private func append(_ load: @escaping @Sendable () async -> [Page]) async {
        jobs += 1
        let newPages = await Task.detached(priority: .userInitiated) { await load() }.value
        if !newPages.isEmpty { update { $0.append(contentsOf: newPages) } }
        jobs -= 1
    }
}

enum PDFBuilder {
    /// A4 in PDF points (1/72 inch).
    static let a4 = CGSize(width: 595.2, height: 841.8)

    static func write(_ pages: [Page], name: String, pageSize: PageSize) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let title = fileName(from: name)
        let url = folder.appendingPathComponent(title).appendingPathExtension("pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "PDF Maker",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: a4), format: format)
        try renderer.writePDF(to: url) { context in
            for page in pages {
                // Building the image straight from the JPEG bytes lets Core Graphics
                // embed them as-is instead of re-encoding (keeps the PDF small).
                guard let provider = CGDataProvider(data: page.jpeg as CFData),
                      let cgImage = CGImage(jpegDataProviderSource: provider, decode: nil,
                                            shouldInterpolate: true, intent: .defaultIntent) else { continue }
                let image = UIImage(cgImage: cgImage)
                let bounds = pageBounds(for: image.size, pageSize: pageSize)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: aspectFit(image.size, in: bounds))
            }
        }
        return url
    }

    private static func pageBounds(for imageSize: CGSize, pageSize: PageSize) -> CGRect {
        switch pageSize {
        case .a4:
            let landscape = imageSize.width > imageSize.height
            return CGRect(origin: .zero, size: landscape ? CGSize(width: a4.height, height: a4.width) : a4)
        case .image:
            // Keep the photo's shape; its short side becomes A4's width.
            let scale = a4.width / min(imageSize.width, imageSize.height)
            return CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
        }
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func fileName(from raw: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "Document" : name
    }
}

extension UIImage {
    /// Redraws the image upright (baking in its orientation) on white, scaled so
    /// its longest side is at most `maxDimension` pixels.
    func redrawn(maxDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale, pixelHeight = size.height * scale
        let factor = min(1, maxDimension / max(pixelWidth, pixelHeight))
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func rotatedClockwise() -> UIImage {
        let rotatedSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rotatedSize, format: format).image { context in
            context.cgContext.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }
}
