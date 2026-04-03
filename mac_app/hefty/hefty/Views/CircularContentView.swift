import SwiftUI
import UniformTypeIdentifiers

/// Content view adapted to fit inside the circular window
struct CircularContentView: View {
    @Bindable var scanner: FileScanner
    @State private var selectedIndex: Int? = nil
    @State private var viewMode: ViewMode = .treemap
    @State private var minSizeText = "1 MB"
    @State private var topNText = "100"
    @State private var showDeleteConfirm = false
    @State private var deleteTargetIndex: Int? = nil
    @State private var alertMessage: String? = nil
    @State private var showAlert = false
    @State private var isHoveringClose = false

    enum ViewMode {
        case treemap
        case list
        case split
    }

    var body: some View {
        ZStack {
            Color(white: 0.08)

            if scanner.rootPath == nil {
                welcomeView
            } else if scanner.files.isEmpty && !scanner.scanning {
                emptyResultView
            } else {
                scanResultsView
            }

            // Close button - top right
            VStack {
                HStack {
                    Spacer()
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isHoveringClose ? Color.red : Color.white.opacity(0.1))
                                .frame(width: 26, height: 26)
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isHoveringClose ? .white : .white.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in isHoveringClose = hovering }
                    .padding(.trailing, 24)
                    .padding(.top, 12)
                }
                Spacer()
            }
        }
        .alert("Delete File", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { deleteTargetIndex = nil }
            Button("Delete", role: .destructive) {
                if let index = deleteTargetIndex { performDelete(at: index) }
            }
        } message: {
            if let index = deleteTargetIndex, index < scanner.files.count {
                let file = scanner.files[index]
                Text("Delete \"\(file.name)\" (\(file.formattedSize))?\n\nThis cannot be undone.")
            }
        }
        .alert("Result", isPresented: $showAlert) {
            Button("OK") { alertMessage = nil }
        } message: {
            if let msg = alertMessage { Text(msg) }
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "flame.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .red, .yellow],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )

            Text("Hefty")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Find the hefty files\nhogging your disk space")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button {
                chooseFolder()
            } label: {
                Label("Choose Folder", systemImage: "folder.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.top, 8)

            Text("or drag & drop a folder")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))

            Spacer()
        }
        .padding(40)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Empty

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text("No files found")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.6))
            Text("Try reducing minimum size")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
            Button("Change Folder") { chooseFolder() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Scan Results

    private var scanResultsView: some View {
        VStack(spacing: 0) {
            // Top toolbar
            topToolbar
                .padding(.top, 16)

            // Main content area
            switch viewMode {
            case .treemap:
                treemapContent
            case .list:
                listContent
            case .split:
                splitContent
            }

            // Bottom status bar
            bottomBar
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Toolbar

    private var topToolbar: some View {
        HStack(spacing: 6) {
            // Folder button
            Button { chooseFolder() } label: {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange.opacity(0.8))

            // Scan status
            if scanner.scanning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text("\(scanner.files.count) found...")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else {
                Text("\(scanner.files.count) files")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Freed space indicator
            if scanner.deletedCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 9))
                    Text("\(formattedBytes(scanner.deletedBytes))")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.red.opacity(0.7))
            }

            // View mode buttons
            HStack(spacing: 2) {
                viewModeButton(mode: .treemap, icon: "square.grid.2x2.fill")
                viewModeButton(mode: .split, icon: "rectangle.split.2x1.fill")
                viewModeButton(mode: .list, icon: "list.bullet")
            }

            // Rescan
            Button { rescan() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .disabled(scanner.scanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func viewModeButton(mode: ViewMode, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { viewMode = mode }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewMode == mode ? Color.orange.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewMode == mode ? .orange : .white.opacity(0.4))
    }

    // MARK: - Treemap View

    private var treemapContent: some View {
        VStack(spacing: 0) {
            TreemapView(
                files: scanner.files,
                selectedIndex: selectedIndex,
                onSelect: { selectedIndex = $0 },
                onDelete: { confirmDelete(at: $0) }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if let idx = selectedIndex, idx < scanner.files.count {
                selectedFileDetail(file: scanner.files[idx], index: idx)
            }
        }
    }

    // MARK: - List View

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(scanner.files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file: file, index: index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Split View

    private var splitContent: some View {
        VStack(spacing: 4) {
            // Treemap in top half
            TreemapView(
                files: scanner.files,
                selectedIndex: selectedIndex,
                onSelect: { selectedIndex = $0 },
                onDelete: { confirmDelete(at: $0) }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // File list in bottom half
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(scanner.files.enumerated()), id: \.element.id) { index, file in
                        fileRow(file: file, index: index)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 4)
    }

    // MARK: - File Row

    private static let rowColors: [Color] = [
        .blue, .green, .yellow, .cyan, .purple, .red,
        Color(red: 0.4, green: 0.6, blue: 1.0),
        Color(red: 0.4, green: 0.9, blue: 0.4),
        Color(red: 1.0, green: 0.9, blue: 0.4),
        Color(red: 0.4, green: 0.9, blue: 0.9),
        Color(red: 0.9, green: 0.4, blue: 0.9),
        Color(red: 1.0, green: 0.5, blue: 0.5),
    ]

    private func fileRow(file: FileEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let color = Self.rowColors[index % Self.rowColors.count]

        return HStack(spacing: 6) {
            // Color indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 28)

            // File info
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(relativePath(for: file))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Size
            Text(file.formattedSize)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.9))

            // Action buttons
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            } label: {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.3))
            .help("Reveal in Finder")

            Button {
                confirmDelete(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.5))
            .help("Delete file")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.orange.opacity(0.2) : Color.white.opacity(0.03))
        )
        .onTapGesture { selectedIndex = index }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path.path, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) {
                confirmDelete(at: index)
            }
        }
    }

    // MARK: - Selected File Detail

    private func selectedFileDetail(file: FileEntry, index: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.rowColors[index % Self.rowColors.count])
                .frame(width: 3, height: 20)

            Text(file.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(file.formattedSize)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 9))
                    Text("Reveal")
                        .font(.system(size: 9))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))

            Button {
                confirmDelete(at: index)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                    Text("Delete")
                        .font(.system(size: 9))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if scanner.scanning {
                Text("Scanning \(scanner.scanFileCount) files (\(formattedBytes(scanner.scanTotalBytes)))")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.5))
            } else {
                Text("Total: \(formattedBytes(max(scanner.scanTotalBytes, scanner.totalSize)))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))

                if let root = scanner.rootPath {
                    Text("| \(root.lastPathComponent)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.2))
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to scan for large files"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url: url)
        }
    }

    private func startScan(url: URL) {
        selectedIndex = nil
        viewMode = .treemap
        let minSize = parseSize(minSizeText)
        let topN = Int(topNText) ?? 100
        scanner.startScan(path: url, minSize: minSize, topN: topN)
    }

    private func rescan() {
        guard let root = scanner.rootPath else { return }
        startScan(url: root)
    }

    private func confirmDelete(at index: Int) {
        deleteTargetIndex = index
        showDeleteConfirm = true
    }

    private func performDelete(at index: Int) {
        let result = scanner.deleteFile(at: index)
        if !result.success {
            alertMessage = result.message
            showAlert = true
        }
        if let sel = selectedIndex, sel >= scanner.files.count, !scanner.files.isEmpty {
            selectedIndex = scanner.files.count - 1
        }
        deleteTargetIndex = nil
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                if let data = data as? Data,
                   let urlString = String(data: data, encoding: .utf8),
                   let url = URL(string: urlString) {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        DispatchQueue.main.async { startScan(url: url) }
                    }
                }
            }
        }
    }

    private func relativePath(for file: FileEntry) -> String {
        guard let root = scanner.rootPath else { return file.path.path }
        let rootStr = root.path
        let fileStr = file.path.path
        if fileStr.hasPrefix(rootStr) {
            let relative = String(fileStr.dropFirst(rootStr.count))
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return fileStr
    }

    private func parseSize(_ text: String) -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        if let n = UInt64(trimmed) { return n }
        let suffixes: [(String, UInt64)] = [
            ("TB", 1_000_000_000_000), ("GB", 1_000_000_000),
            ("MB", 1_000_000), ("KB", 1_000), ("B", 1),
        ]
        for (suffix, multiplier) in suffixes {
            if trimmed.hasSuffix(suffix) {
                let numStr = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let n = Double(numStr) { return UInt64(n * Double(multiplier)) }
            }
        }
        return 1_000_000
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
