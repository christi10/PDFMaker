import SwiftUI
import PhotosUI
import VisionKit

struct ContentView: View {
    @State private var store = PageStore()
    @State private var library = DocumentLibrary()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showHistory = false
    @State private var cropping: Page?
    @State private var exported: ExportedPDF?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.pages.isEmpty {
                    emptyState
                } else {
                    pageList
                }
            }
            .navigationTitle("PDF Maker")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!store.canUndo)
                    Button { store.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!store.canRedo)
                    Menu {
                        ForEach(Source.allCases) { source in
                            Button { open(source) } label: { Label(source.title, systemImage: source.icon) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !store.pages.isEmpty { actionBar }
            }
            .overlay {
                if store.isWorking {
                    ProgressView()
                        .controlSize(.large)
                        .padding(28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                Task { await store.add(images: images) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $cropping) { page in
            CropEditorView(page: page) { quad in
                cropping = nil
                if let quad { Task { await store.crop(page, to: quad) } }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await store.add(photos: items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.add(files: urls) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(library: library, currentID: store.documentID) { document in
                showHistory = false
                Task { await open(document) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await saveIfNeeded() } }
        }
        .sheet(item: $exported) { pdf in
            switch pdf.action {
            case .share:
                ShareSheet(url: pdf.url) { exported = nil }
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            case .preview:
                PDFPreviewView(url: pdf.url)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 28) {
            ContentUnavailableView(
                "No pages yet",
                systemImage: "doc.on.doc",
                description: Text("Scan with the camera or pick images from Photos or Files. They're combined into one PDF, in order.")
            )
            .frame(maxHeight: 280)

            VStack(spacing: 12) {
                ForEach(Source.allCases) { source in
                    Button { open(source) } label: {
                        Label(source.title, systemImage: source.icon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private var pageList: some View {
        List {
            Section("PDF") {
                TextField("File name", text: $store.name)
                    .submitLabel(.done)
                Picker("Page size", selection: $store.pageSize) {
                    ForEach(PageSize.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section {
                ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                    PageRow(page: page, number: index + 1)
                        .contentShape(Rectangle())
                        .onTapGesture { cropping = page }
                        .swipeActions(edge: .leading) {
                            Button { store.rotate(page) } label: {
                                Label("Rotate", systemImage: "rotate.right")
                            }
                            .tint(.blue)
                        }
                }
                .onDelete { store.delete(at: $0) }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text(store.pages.count == 1 ? "1 page" : "\(store.pages.count) pages")
                    Spacer()
                    EditButton()
                        .font(.subheadline)
                        .textCase(nil)
                }
            } footer: {
                Text("Tap a page to crop. Swipe right to rotate, left to delete. Tap Edit to reorder.")
            }

            Section {
                Button {
                    Task {
                        await saveIfNeeded()
                        store.startNew()
                    }
                } label: {
                    Label("Start New Document", systemImage: "doc.badge.plus")
                }
            } footer: {
                Text("This document is kept in History, so you can come back to it.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { export(.preview) } label: {
                Label("Preview", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button { export(.share) } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(store.isWorking)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func open(_ source: Source) {
        switch source {
        case .camera:
            if VNDocumentCameraViewController.isSupported {
                showScanner = true
            } else {
                errorMessage = "The camera scanner isn't available on this device."
            }
        case .photos:
            showPhotos = true
        case .files:
            showFiles = true
        }
    }

    private func export(_ action: ExportedPDF.Action) {
        Task {
            do {
                let url = try await store.makePDF()
                exported = ExportedPDF(url: url, action: action)
                await library.save(id: store.documentID, name: store.name, pageSize: store.pageSize,
                                   pages: store.pages, pdf: url)
                store.hasChanges = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Keeps unsaved edits in History (without re-making the PDF).
    private func saveIfNeeded() async {
        guard store.hasChanges, !store.pages.isEmpty else { return }
        await library.save(id: store.documentID, name: store.name, pageSize: store.pageSize,
                           pages: store.pages, pdf: nil)
        store.hasChanges = false
    }

    private func open(_ document: SavedDocument) async {
        guard document.id != store.documentID else { return }
        await saveIfNeeded()
        let pages = await library.pages(of: document)
        store.load(id: document.id, name: document.name, pageSize: document.pageSize, pages: pages)
    }
}

private enum Source: CaseIterable, Identifiable {
    case camera, photos, files

    var id: Self { self }

    var title: String {
        switch self {
        case .camera: "Scan with Camera"
        case .photos: "Choose from Photos"
        case .files: "Pick from Files"
        }
    }

    var icon: String {
        switch self {
        case .camera: "camera.viewfinder"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        }
    }
}

private struct ExportedPDF: Identifiable {
    enum Action { case share, preview }

    let url: URL
    let action: Action
    let id = UUID()
}

private struct PageRow: View {
    let page: Page
    let number: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(uiImage: page.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 80)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Page \(number)")
            Spacer()
            Image(systemName: "crop")
                .foregroundStyle(page.quad == nil ? .tertiary : .secondary)
        }
        .padding(.vertical, 2)
    }
}
