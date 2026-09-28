import UIKit

/// A document in History: its settings, its pages (original photos + crops)
/// and the last PDF made from it.
struct SavedDocument: Codable, Identifiable {
    struct SavedPage: Codable {
        var id: UUID
        var quad: Quad?
    }

    var id: UUID
    var name: String
    var pageSize: PageSize
    var createdAt: Date
    var updatedAt: Date
    var pages: [SavedPage]
    var pdfFileName: String?
}

/// History, stored as one folder per document in Application Support:
/// `document.json`, each page's original and cropped JPEG, a thumbnail and the PDF.
@MainActor
@Observable
final class DocumentLibrary {
    /// Newest first.
    private(set) var documents: [SavedDocument] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    private let root: URL

    init() {
        root = URL.applicationSupportDirectory.appending(path: "History", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        documents = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "document.json")) else { return nil }
            return try? JSONDecoder().decode(SavedDocument.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func pdfURL(for document: SavedDocument) -> URL? {
        document.pdfFileName.map { folder(for: document.id).appending(path: $0) }
    }

    func thumbnail(for document: SavedDocument) -> UIImage? {
        if let cached = thumbnails[document.id] { return cached }
        let image = UIImage(contentsOfFile: folder(for: document.id).appending(path: "thumb.jpg").path(percentEncoded: false))
        thumbnails[document.id] = image
        return image
    }

    /// Saves (or overwrites) a document. `pdf`, when given, replaces its stored PDF.
    func save(id: UUID, name: String, pageSize: PageSize, pages: [Page], pdf: URL?) async {
        let existing = documents.first { $0.id == id }
        let now = Date.now
        var document = SavedDocument(
            id: id, name: name, pageSize: pageSize,
            createdAt: existing?.createdAt ?? now, updatedAt: now,
            pages: pages.map { SavedDocument.SavedPage(id: $0.id, quad: $0.quad) },
            pdfFileName: existing?.pdfFileName
        )
        if let pdf { document.pdfFileName = pdf.lastPathComponent }

        let folder = folder(for: id)
        let saved = document
        let written = await Task.detached(priority: .userInitiated) {
            Self.write(saved, pages: pages, pdf: pdf, replacing: existing?.pdfFileName, to: folder)
        }.value
        guard written else { return }

        thumbnails[id] = pages.first?.thumbnail
        documents.removeAll { $0.id == id }
        documents.insert(document, at: 0)
    }

    /// Reads a document's pages back so it can be edited again.
    func pages(of document: SavedDocument) async -> [Page] {
        let folder = folder(for: document.id)
        return await Task.detached(priority: .userInitiated) {
            document.pages.compactMap { saved in
                guard let original = try? Data(contentsOf: folder.appending(path: "\(saved.id).original.jpg")),
                      let jpeg = try? Data(contentsOf: folder.appending(path: "\(saved.id).jpg")),
                      let image = UIImage(data: jpeg) else { return nil }
                return Page(id: saved.id, original: original, quad: saved.quad, jpeg: jpeg,
                            thumbnail: image.redrawn(maxDimension: 240))
            }
        }.value
    }

    func delete(_ document: SavedDocument) {
        try? FileManager.default.removeItem(at: folder(for: document.id))
        documents.removeAll { $0.id == document.id }
        thumbnails[document.id] = nil
    }

    private func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private nonisolated static func write(_ document: SavedDocument, pages: [Page], pdf: URL?,
                                          replacing oldPDF: String?, to folder: URL) -> Bool {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for page in pages {
                try page.original.write(to: folder.appending(path: "\(page.id).original.jpg"))
                try page.jpeg.write(to: folder.appending(path: "\(page.id).jpg"))
            }
            // Drop the images of pages that were deleted.
            let keep = Set(pages.flatMap { ["\($0.id).original.jpg", "\($0.id).jpg"] } + ["thumb.jpg"])
            for file in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "jpg" && !keep.contains(file.lastPathComponent) {
                try? files.removeItem(at: file)
            }
            if let thumbnail = pages.first?.thumbnail.jpegData(compressionQuality: 0.8) {
                try thumbnail.write(to: folder.appending(path: "thumb.jpg"))
            }
            if let pdf {
                if let oldPDF { try? files.removeItem(at: folder.appending(path: oldPDF)) }
                try files.copyItem(at: pdf, to: folder.appending(path: pdf.lastPathComponent))
            }
            try JSONEncoder().encode(document).write(to: folder.appending(path: "document.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
