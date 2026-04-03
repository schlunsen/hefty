import SwiftUI
import UniformTypeIdentifiers

/// Main rectangular window with animated block border
struct MainWindowView: View {
    @State private var scanner = FileScanner()
    @State private var selectedIndex: Int? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteTargetIndex: Int? = nil
    @State private var alertMessage: String? = nil
    @State private var showAlert = false
    @State private var isHoveringClose = false
    @State private var keyMonitor: Any? = nil

    var body: some View {
        ZStack {
            // Animated block border
            BlockBorderView(isScanning: scanner.scanning)

            // Main content with dark background inset
            VStack(spacing: 0) {
                // Title bar area
                titleBar

                Divider().opacity(0.3)

                // Content
                if scanner.rootPath == nil {
                    welcomeView
                } else if scanner.files.isEmpty && !scanner.scanning {
                    emptyResultView
                } else {
                    twoColumnView
                }

                Divider().opacity(0.3)

                // Status bar
                statusBar
            }
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(6) // Inset from the block border
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { setupKeyboardMonitor() }
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

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            // Close button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Circle()
                    .fill(isHoveringClose ? Color.red : Color.red.opacity(0.7))
                    .frame(width: 12, height: 12)
                    .overlay {
                        if isHoveringClose {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.black.opacity(0.7))
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }

            // App title
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Hefty")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }

            if let root = scanner.rootPath {
                Text("—")
                    .foregroundStyle(.white.opacity(0.2))
                    .font(.system(size: 11))
                Text(root.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer()

            // Toolbar buttons
            if scanner.rootPath != nil {
                Button { chooseFolder() } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Open folder")

                Button { rescan() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .disabled(scanner.scanning)
                .help("Rescan")

                if scanner.scanning {
                    Button { scanner.stopScan() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.7))
                    .help("Stop scan")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.06))
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "flame.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red, .yellow], startPoint: .bottom, endPoint: .top)
                )

            Text("Hefty")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Find the hefty files hogging your disk space")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.5))

            Button {
                chooseFolder()
            } label: {
                Label("Choose a Folder to Scan", systemImage: "folder.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Text("or drag & drop a folder")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))
            Text("No files found above minimum size threshold")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.5))
            Button("Change Folder") { chooseFolder() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Two Column View (like CLI)

    private var twoColumnView: some View {
        HStack(spacing: 0) {
            // Left: Treemap
            VStack(spacing: 0) {
                treemapHeader
                TreemapView(
                    files: scanner.files,
                    selectedIndex: selectedIndex,
                    onSelect: { selectedIndex = $0 },
                    onDelete: { confirmDelete(at: $0) }
                )
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            // Right: File list
            VStack(spacing: 0) {
                fileListHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(scanner.files.enumerated()), id: \.element.id) { index, file in
                                fileRow(file: file, index: index)
                                    .id(file.id)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        if let idx = newValue, idx < scanner.files.count {
                            let fileId = scanner.files[idx].id
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(fileId, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 380)
        }
    }

    private var treemapHeader: some View {
        HStack {
            if scanner.scanning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text("Treemap (scanning...)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.7))
            } else {
                Text("Treemap")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.06))
    }

    private var fileListHeader: some View {
        HStack {
            if scanner.scanning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text("Files (\(scanner.files.count) found, scanning \(scanner.scanFileCount)...)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.7))
            } else {
                Text("Files (\(scanner.files.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.06))
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

        return HStack(spacing: 8) {
            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 32)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(relativePath(for: file))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Size badge
            Text(file.formattedSize)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange.opacity(0.1))
                )

            // Action buttons
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.25))
            .help("Reveal in Finder")

            Button {
                confirmDelete(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.4))
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.orange.opacity(0.35) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
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
            Button("Delete", role: .destructive) { confirmDelete(at: index) }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if scanner.scanning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text("Scanning: \(scanner.scanFileCount) files (\(formattedBytes(scanner.scanTotalBytes)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.6))
            } else if scanner.rootPath != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.6))
                Text("Total: \(formattedBytes(max(scanner.scanTotalBytes, scanner.totalSize))) | \(scanner.files.count) files")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Spacer()

            if scanner.deletedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 9))
                    Text("Freed: \(formattedBytes(scanner.deletedBytes)) (\(scanner.deletedCount) files)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.red.opacity(0.6))
            }

            if let idx = selectedIndex, idx < scanner.files.count {
                Text("Selected: \(scanner.files[idx].name) (\(scanner.files[idx].formattedSize))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }

            Text("↑↓ navigate  ⌫ delete  ⌘O open folder")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.15))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.06))
    }

    // MARK: - Keyboard

    private func setupKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't handle keys when a dialog/alert is showing
            if showDeleteConfirm || showAlert { return event }

            switch event.keyCode {
            case 125, 38: // down arrow, j
                moveSelection(by: 1); return nil
            case 126, 40: // up arrow, k
                moveSelection(by: -1); return nil
            case 121: // page down
                moveSelection(by: 20); return nil
            case 116: // page up
                moveSelection(by: -20); return nil
            case 115: // home
                selectedIndex = scanner.files.isEmpty ? nil : 0; return nil
            case 119: // end
                selectedIndex = scanner.files.isEmpty ? nil : scanner.files.count - 1; return nil
            case 51, 117, 2: // delete, forward delete, d
                handleDeleteKey(); return nil
            case 36: // return
                handleRevealKey(); return nil
            default:
                return event
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !scanner.files.isEmpty else { return }
        if let current = selectedIndex {
            let newIndex = max(0, min(scanner.files.count - 1, current + delta))
            selectedIndex = newIndex
        } else {
            selectedIndex = delta > 0 ? 0 : scanner.files.count - 1
        }
    }

    private func handleDeleteKey() {
        if let idx = selectedIndex, idx < scanner.files.count {
            confirmDelete(at: idx)
        }
    }

    private func handleRevealKey() {
        if let idx = selectedIndex, idx < scanner.files.count {
            NSWorkspace.shared.activateFileViewerSelecting([scanner.files[idx].path])
        }
    }

    private func handleTabKey() {
        // Could toggle views in the future
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
        scanner.startScan(path: url, minSize: 0, topN: 500)
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

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
