import SwiftUI

/// Every saved document, newest first. Tap to reopen and keep editing, share
/// its PDF straight from the list, preview it, or swipe to delete.
struct HistoryView: View {
    let library: DocumentLibrary
    let currentID: UUID
    let onOpen: (SavedDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previewing: PreviewItem?

    var body: some View {
        NavigationStack {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("PDFs you create are kept here, so you can share them again or keep editing.")
                    )
                } else {
                    List {
                        ForEach(library.documents) { document in
                            row(for: document)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $previewing) { PDFPreviewView(url: $0.url) }
        }
    }

    private func row(for document: SavedDocument) -> some View {
        let pdf = library.pdfURL(for: document)
        return HStack(spacing: 14) {
            Group {
                if let thumbnail = library.thumbnail(for: document) {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 64)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(document.name)
                    .lineLimit(1)
                Text(subtitle(for: document, hasPDF: pdf != nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let pdf {
                ShareLink(item: pdf) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen(document) }
        .contextMenu {
            Button { onOpen(document) } label: { Label("Open & Edit", systemImage: "pencil") }
            if let pdf {
                Button { previewing = PreviewItem(url: pdf) } label: { Label("Preview PDF", systemImage: "eye") }
                ShareLink(item: pdf) { Label("Share PDF", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { library.delete(document) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions {
            Button(role: .destructive) { library.delete(document) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func subtitle(for document: SavedDocument, hasPDF: Bool) -> String {
        var parts = [document.pages.count == 1 ? "1 page" : "\(document.pages.count) pages",
                     document.updatedAt.formatted(date: .abbreviated, time: .shortened)]
        if document.id == currentID { parts.append("Editing") } else if !hasPDF { parts.append("Draft") }
        return parts.joined(separator: " · ")
    }
}

private struct PreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}
