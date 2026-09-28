import SwiftUI

/// Pick the part of the photo to keep by dragging its four corners. Opens with
/// the document edges auto-detected; the result is straightened like a scan.
/// Calls `onFinish` with the chosen corners, or nil if the user cancels.
struct CropEditorView: View {
    let onFinish: (Quad?) -> Void

    @State private var image: UIImage
    @State private var quad: Quad
    @State private var needsDetection: Bool
    @State private var dragStart: CGPoint?
    @State private var activeCorner: Int?
    @State private var detecting = false
    @State private var message: String?

    init(page: Page, onFinish: @escaping (Quad?) -> Void) {
        self.onFinish = onFinish
        _image = State(initialValue: UIImage(data: page.original) ?? page.thumbnail)
        _quad = State(initialValue: page.quad ?? .full)
        _needsDetection = State(initialValue: page.quad == nil)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let frame = imageFrame(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    // Dim what gets cut away, outline what stays.
                    Path { path in
                        path.addRect(frame)
                        path.addLines(corners(in: frame))
                        path.closeSubpath()
                    }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))

                    Path { path in
                        path.addLines(corners(in: frame))
                        path.closeSubpath()
                    }
                    .stroke(Color.accentColor, lineWidth: 2)

                    ForEach(0..<4, id: \.self) { index in
                        handle(index, in: frame)
                    }

                    if let activeCorner {
                        loupe(for: activeCorner, in: frame)
                    }
                }
                .coordinateSpace(.named("crop"))
            }
            .padding(28)
            .background(Color.black)
            .overlay {
                if detecting { ProgressView().controlSize(.large) }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onFinish(quad) }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .task {
                guard needsDetection else { return }
                needsDetection = false
                await autoDetect()
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Pieces

    private var controls: some View {
        VStack(spacing: 10) {
            Text(message ?? "Drag the corners to choose what to keep.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button { Task { await autoDetect() } } label: {
                    Label("Auto-detect", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    message = nil
                    withAnimation(.snappy) { quad = .full }
                } label: {
                    Label("Whole photo", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(detecting)
        }
        .padding()
        .background(Color.black)
    }

    private func handle(_ index: Int, in frame: CGRect) -> some View {
        Circle()
            .fill(Color.accentColor.opacity(0.35))
            .strokeBorder(.white, lineWidth: 2)
            .frame(width: 28, height: 28)
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .position(point(index, in: frame))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
                    .onChanged { value in
                        let start = dragStart ?? quad.points[index]
                        if dragStart == nil {
                            dragStart = start
                            activeCorner = index
                        }
                        quad.points[index] = CGPoint(
                            x: min(max(start.x + value.translation.width / frame.width, 0), 1),
                            y: min(max(start.y + value.translation.height / frame.height, 0), 1)
                        )
                    }
                    .onEnded { _ in
                        dragStart = nil
                        activeCorner = nil
                    }
            )
    }

    /// A magnified view under the finger so a corner can be placed precisely.
    /// Sits at the top, on the side away from the corner being dragged.
    private func loupe(for index: Int, in frame: CGRect) -> some View {
        let zoom: CGFloat = 2.5, size: CGFloat = 120
        let corner = point(index, in: frame)
        let x = corner.x < frame.midX ? frame.maxX - size / 2 : frame.minX + size / 2
        return Image(uiImage: image)
            .resizable()
            .frame(width: frame.width * zoom, height: frame.height * zoom)
            .offset(x: size / 2 - (corner.x - frame.minX) * zoom,
                    y: size / 2 - (corner.y - frame.minY) * zoom)
            .frame(width: size, height: size, alignment: .topLeading)
            .background(Color.black)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .overlay(Image(systemName: "plus").font(.title3.bold()).foregroundStyle(Color.accentColor))
            .position(x: x, y: max(frame.minY, 0) + size / 2)
            .allowsHitTesting(false)
    }

    // MARK: - Geometry

    private func imageFrame(in size: CGSize) -> CGRect {
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func point(_ index: Int, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + quad.points[index].x * frame.width,
                y: frame.minY + quad.points[index].y * frame.height)
    }

    private func corners(in frame: CGRect) -> [CGPoint] {
        (0..<4).map { point($0, in: frame) }
    }

    // MARK: - Actions

    private func autoDetect() async {
        detecting = true
        let image = self.image
        let found = await Task.detached(priority: .userInitiated) {
            ImageCropper.detectDocument(in: image)
        }.value
        detecting = false
        if let found {
            message = nil
            withAnimation(.snappy) { quad = found }
        } else {
            message = "No document edges found — drag the corners yourself."
        }
    }
}
