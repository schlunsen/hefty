import SwiftUI

/// One pre-computed draw command for the grouped treemap canvas.
nonisolated struct TreemapDrawItem: Equatable {
    enum Kind: Equatable {
        /// A file leaf: gradient "cushion" fill.
        case file
        /// A folder large enough to recurse into: dim base fill + thin border.
        case dirFrame
        /// A folder too small to recurse into: single solid block.
        case dirBlock
    }

    let rect: CGRect
    let hue: Double
    let saturation: Double
    /// Per-file lightness jitter (-0.08...0.08) for texture.
    let brightnessJitter: Double
    let kind: Kind
    /// Depth relative to the current treemap root (0 = direct child of root).
    let depth: Int
    let path: String
    let name: String
    let size: UInt64
    let showLabel: Bool

    var isDir: Bool { kind != .file }
}

/// Recursive squarified layout over the full scan tree. Produces a flat array
/// of draw commands off the render path; the Canvas just replays the array.
nonisolated enum GroupedTreemapLayout {
    /// Safety valve: never emit more rects than this.
    static let maxItems = 60_000
    /// Stop recursing into folders smaller than this (drawn as a single block).
    static let minRecurseDim: CGFloat = 3
    /// Skip items whose rect area is below this (sub-pixel slivers).
    static let minArea: CGFloat = 1.5
    /// Folder rects at least this large get a name label.
    static let labelMinWidth: CGFloat = 80
    static let labelMinHeight: CGFloat = 40

    static func build(root: ScanNode, rootPath: String, size: CGSize) -> [TreemapDrawItem] {
        var items: [TreemapDrawItem] = []
        items.reserveCapacity(4096)
        layoutChildren(
            of: root,
            path: rootPath,
            rect: CGRect(origin: .zero, size: size),
            depth: 0,
            hue: 0,
            saturation: 0,
            items: &items
        )
        return items
    }

    private static func layoutChildren(
        of node: ScanNode,
        path: String,
        rect: CGRect,
        depth: Int,
        hue: Double,
        saturation: Double,
        items: inout [TreemapDrawItem]
    ) {
        if items.count >= maxItems { return }

        // Merge subdirs and files (each already sorted largest-first) into one
        // descending list. Indices < dirCount are dirs; the rest are files.
        let dirCount = node.dirs.count
        var merged: [(Int, UInt64)] = []
        merged.reserveCapacity(dirCount + node.files.count)
        var di = 0
        var fi = 0
        while di < dirCount || fi < node.files.count {
            let dirSize = di < dirCount ? node.dirs[di].size : 0
            let fileSize = fi < node.files.count ? node.files[fi].size : 0
            if di < dirCount && (fi >= node.files.count || dirSize >= fileSize) {
                if dirSize > 0 { merged.append((di, dirSize)) }
                di += 1
            } else {
                if fileSize > 0 { merged.append((dirCount + fi, fileSize)) }
                fi += 1
            }
        }
        guard !merged.isEmpty else { return }

        let rects = TreemapLayout.layoutIndexed(
            items: merged,
            width: Double(rect.width),
            height: Double(rect.height)
        )

        for r in rects {
            if items.count >= maxItems { return }
            let childRect = CGRect(
                x: rect.minX + CGFloat(r.x),
                y: rect.minY + CGFloat(r.y),
                width: CGFloat(r.w),
                height: CGFloat(r.h)
            )
            if childRect.width * childRect.height < minArea { continue }

            if r.index < dirCount {
                let child = node.dirs[r.index]
                let childPath = path.hasSuffix("/") ? path + child.name : path + "/" + child.name
                // Stable hue per top-level folder; deeper levels inherit it.
                let childHue = depth == 0 ? hueForName(child.name) : hue
                let childSat = depth == 0 ? 0.6 : saturation

                if childRect.width < minRecurseDim || childRect.height < minRecurseDim {
                    items.append(TreemapDrawItem(
                        rect: childRect,
                        hue: childHue,
                        saturation: childSat,
                        brightnessJitter: 0,
                        kind: .dirBlock,
                        depth: depth,
                        path: childPath,
                        name: child.name,
                        size: child.size,
                        showLabel: false
                    ))
                } else {
                    items.append(TreemapDrawItem(
                        rect: childRect,
                        hue: childHue,
                        saturation: childSat,
                        brightnessJitter: 0,
                        kind: .dirFrame,
                        depth: depth,
                        path: childPath,
                        name: child.name,
                        size: child.size,
                        showLabel: childRect.width >= labelMinWidth && childRect.height >= labelMinHeight
                    ))
                    layoutChildren(
                        of: child,
                        path: childPath,
                        rect: childRect,
                        depth: depth + 1,
                        hue: childHue,
                        saturation: childSat,
                        items: &items
                    )
                }
            } else {
                let file = node.files[r.index - dirCount]
                let filePath = path.hasSuffix("/") ? path + file.name : path + "/" + file.name
                // Files directly under the treemap root get a neutral hue.
                let fileHue = depth == 0 ? 0.0 : hue
                let fileSat = depth == 0 ? 0.05 : saturation
                let jitter = Double(fnv1a(file.name) % 100) / 100.0 * 0.16 - 0.08
                items.append(TreemapDrawItem(
                    rect: childRect,
                    hue: fileHue,
                    saturation: fileSat,
                    brightnessJitter: jitter,
                    kind: .file,
                    depth: depth,
                    path: filePath,
                    name: file.name,
                    size: file.size,
                    showLabel: false
                ))
            }
        }
    }

    /// Stable hue for a folder name (FNV-1a; String.hashValue is per-launch randomized).
    static func hueForName(_ name: String) -> Double {
        Double(fnv1a(name) % 360) / 360.0
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// GrandPerspective-style treemap: every scanned file rendered inside its
/// parent folder's rectangle, with cushion-style gradient shading and a stable
/// color per top-level folder.
struct GroupedTreemapView: View {
    let rootNode: ScanNode
    let rootURL: URL
    let treeVersion: Int
    @Binding var currentDir: URL?
    @Binding var selectedPath: String?
    @Binding var hoveredPath: String?

    @State private var items: [TreemapDrawItem] = []
    @State private var layoutTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .center) {
                TreemapBaseCanvas(items: items)
                    .equatable()

                highlightCanvas

                if items.isEmpty {
                    Text("Building map...")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in descend(at: value.location) }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in select(at: value.location) }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoveredPath = hitTest(location)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
            .contextMenu {
                if let path = selectedPath ?? hoveredPath {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            }
            .onAppear { scheduleLayout(size: geometry.size, debounce: false) }
            .onChange(of: geometry.size) { _, newSize in scheduleLayout(size: newSize, debounce: true) }
            .onChange(of: treeVersion) { _, _ in scheduleLayout(size: geometry.size, debounce: false) }
            .onChange(of: rootURL) { _, _ in scheduleLayout(size: geometry.size, debounce: false) }
        }
        .background(Color(white: 0.05))
        .onDisappear { layoutTask?.cancel() }
    }

    // MARK: - Highlight overlay (cheap: redraws only two rects on hover/selection change)

    private var highlightCanvas: some View {
        Canvas { context, _ in
            if let hovered = hoveredPath, hovered != selectedPath,
               let item = items.last(where: { $0.path == hovered }) {
                context.stroke(
                    Path(item.rect.insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(.white.opacity(0.55)),
                    lineWidth: 1
                )
            }
            if let selected = selectedPath,
               let item = items.last(where: { $0.path == selected }) {
                context.stroke(
                    Path(item.rect.insetBy(dx: 0.75, dy: 0.75)),
                    with: .color(.white),
                    lineWidth: 1.5
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Layout scheduling (off the render path, debounced on resize)

    private func scheduleLayout(size: CGSize, debounce: Bool) {
        layoutTask?.cancel()
        guard size.width > 10, size.height > 10 else { return }
        let node = rootNode
        let rootPath = rootURL.path
        layoutTask = Task.detached(priority: .userInitiated) {
            if debounce {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if Task.isCancelled { return }
            let built = GroupedTreemapLayout.build(root: node, rootPath: rootPath, size: size)
            if Task.isCancelled { return }
            await MainActor.run {
                items = built
            }
        }
    }

    // MARK: - Interactions

    /// Deepest item under the point (items are emitted parents-before-children,
    /// and rects only overlap along ancestor chains, so last match wins).
    private func hitTest(_ point: CGPoint) -> TreemapDrawItem? {
        for item in items.reversed() where item.rect.contains(point) {
            return item
        }
        return nil
    }

    private func select(at point: CGPoint) {
        selectedPath = hitTest(point)?.path
    }

    /// Double-click descends one level: into the top-level folder under the cursor.
    private func descend(at point: CGPoint) {
        guard let target = items.last(where: { $0.isDir && $0.depth == 0 && $0.rect.contains(point) })
        else { return }
        selectedPath = nil
        hoveredPath = nil
        currentDir = URL(fileURLWithPath: target.path, isDirectory: true)
    }
}

/// The heavy canvas: only depends on the draw-command array, so hover and
/// selection changes never force a full redraw.
private struct TreemapBaseCanvas: View, Equatable {
    let items: [TreemapDrawItem]

    static func == (lhs: TreemapBaseCanvas, rhs: TreemapBaseCanvas) -> Bool {
        lhs.items == rhs.items
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            // Pass 1: fills (parents are emitted before children, so folder base
            // fills land underneath their contents).
            for item in items {
                switch item.kind {
                case .file:
                    drawFile(item, in: &context)
                case .dirBlock:
                    context.fill(
                        Path(item.rect),
                        with: .color(Color(hue: item.hue, saturation: item.saturation * 0.8, brightness: 0.5))
                    )
                case .dirFrame:
                    context.fill(
                        Path(item.rect),
                        with: .color(Color(hue: item.hue, saturation: item.saturation * 0.5, brightness: 0.2))
                    )
                }
            }

            // Pass 2: folder borders and labels on top, so groups read visually.
            for item in items where item.kind == .dirFrame {
                context.stroke(
                    Path(item.rect),
                    with: .color(.black.opacity(0.45)),
                    lineWidth: 0.5
                )
                if item.showLabel {
                    var labelContext = context
                    labelContext.clip(to: Path(item.rect.insetBy(dx: 1, dy: 1)))
                    labelContext.draw(
                        Text(item.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75)),
                        at: CGPoint(x: item.rect.minX + 3, y: item.rect.minY + 2),
                        anchor: .topLeading
                    )
                }
            }
        }
    }

    /// Cushion-style file fill: lighter top-left to darker bottom-right.
    private func drawFile(_ item: TreemapDrawItem, in context: inout GraphicsContext) {
        let rect = item.rect
        let base = 0.72 + item.brightnessJitter

        // Gradients for sub-6pt slivers are invisible and just cost time.
        if rect.width < 6 || rect.height < 6 {
            context.fill(
                Path(rect),
                with: .color(Color(hue: item.hue, saturation: item.saturation, brightness: base))
            )
            return
        }

        let light = Color(hue: item.hue, saturation: item.saturation * 0.85, brightness: min(base + 0.18, 1.0))
        let dark = Color(hue: item.hue, saturation: item.saturation, brightness: max(base - 0.24, 0.05))
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [light, dark]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )
    }
}
