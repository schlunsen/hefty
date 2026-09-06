import SwiftUI
import UniformTypeIdentifiers
import QuickLook

/// Main rectangular window with animated block border
struct MainWindowView: View {
    @State private var scanner = FileScanner()
    @State private var selectedIndex: Int? = nil
    @State private var markedFiles: Set<UUID> = []
    @State private var showDeleteConfirm = false
    @State private var showBatchDeleteConfirm = false
    @State private var deleteTargetIndex: Int? = nil
    @State private var alertMessage: String? = nil
    @State private var showAlert = false
    @State private var isHoveringClose = false
    @State private var keyMonitor: Any? = nil
    @State private var previewURL: URL? = nil

    // Folder drill-down state
    @State private var browseMode: BrowseMode = .files
    @State private var currentDir: URL? = nil
    @State private var folderItems: [FolderItem] = []
    @State private var folderTreemapEntries: [FileEntry] = []
    @State private var selectedFolderItemID: UUID? = nil
    @State private var treemapSelectedPath: String? = nil
    @State private var treemapHoveredPath: String? = nil

    enum BrowseMode: String, CaseIterable {
        case files = "Files"
        case folders = "Folders"
    }

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

                // Full Disk Access hint (shown when some paths couldn't be read)
                if scanner.permissionDeniedCount > 0 {
                    permissionBanner
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
        .quickLookPreview($previewURL)
        .onChange(of: currentDir) { _, _ in
            treemapSelectedPath = nil
            treemapHoveredPath = nil
            rebuildFolderItems()
        }
        .onChange(of: browseMode) { _, _ in rebuildFolderItems() }
        .onChange(of: treemapSelectedPath) { _, newValue in
            // Mirror treemap selection into the folder list when possible.
            guard let path = newValue else { return }
            if let item = folderItems.first(where: { $0.url.path == path }) {
                selectedFolderItemID = item.id
            }
        }
        .onChange(of: scanner.dirSizesVersion) { _, _ in rebuildFolderItems() }
        .onChange(of: scanner.files.count) { _, _ in
            if browseMode == .folders { rebuildFolderItems() }
        }
        .alert("Move to Trash", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { deleteTargetIndex = nil }
            Button("Move to Trash", role: .destructive) {
                if let index = deleteTargetIndex { performDelete(at: index) }
            }
        } message: {
            if let index = deleteTargetIndex, index < scanner.files.count {
                let file = scanner.files[index]
                Text("Move \"\(file.name)\" (\(file.formattedSize)) to the Trash?\n\nYou can restore it from the Trash later.")
            }
        }
        .alert("Move to Trash", isPresented: $showBatchDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move All to Trash", role: .destructive) {
                performBatchDelete()
            }
        } message: {
            let count = markedFiles.count
            let totalSize = markedTotalSize()
            Text("Move \(count) selected files (\(formattedBytes(totalSize))) to the Trash?\n\nYou can restore them from the Trash later.")
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

            // Files / Folders mode toggle
            if scanner.rootPath != nil {
                Picker("", selection: $browseMode) {
                    ForEach(BrowseMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 130)
                .help("Switch between largest-files list and folder drill-down")
            }

            // Batch delete button (visible when files are marked)
            if !markedFiles.isEmpty {
                Button {
                    showBatchDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 10))
                        Text("Trash \(markedFiles.count)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.red.opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
                .help("Move \(markedFiles.count) selected files to the Trash")
            }

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

            Text("or quick scan")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 4)

            // Quick scan shortcuts
            HStack(spacing: 10) {
                quickScanButton(label: "Home", icon: "house.fill", url: FileManager.default.homeDirectoryForCurrentUser)
                quickScanButton(label: "Downloads", icon: "arrow.down.circle.fill", url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
                quickScanButton(label: "Documents", icon: "doc.fill", url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                quickScanButton(label: "Desktop", icon: "menubar.dock.rectangle", url: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
                quickScanButton(label: "Macintosh HD", icon: "internaldrive.fill", url: URL(fileURLWithPath: "/"))
            }

            Text("or drag & drop a folder")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func quickScanButton(label: String, icon: String, url: URL?) -> some View {
        Button {
            if let url {
                chooseFolderPreNavigated(to: url)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 80, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
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
                if browseMode == .folders {
                    if let dir = currentDir, let node = scanner.fullTreeNode(for: dir) {
                        // Full grouped treemap: every scanned file, grouped by folder.
                        GroupedTreemapView(
                            rootNode: node,
                            rootURL: dir,
                            treeVersion: scanner.fullTreeVersion,
                            currentDir: $currentDir,
                            selectedPath: $treemapSelectedPath,
                            hoveredPath: $treemapHoveredPath
                        )
                    } else {
                        // Fallback while the full tree is still being built.
                        TreemapView(
                            files: folderTreemapEntries,
                            selectedIndex: selectedFolderTreemapIndex,
                            onSelect: { handleFolderTreemapSelect($0) },
                            onDelete: { handleFolderTreemapDelete($0) }
                        )
                    }
                } else {
                    TreemapView(
                        files: scanner.files,
                        selectedIndex: selectedIndex,
                        onSelect: { selectedIndex = $0 },
                        onDelete: { confirmDelete(at: $0) }
                    )
                }
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            // Right: File list or folder browser
            VStack(spacing: 0) {
                if browseMode == .folders {
                    fileListHeader
                    FolderBrowserView(
                        scanner: scanner,
                        currentDir: $currentDir,
                        selectedItemID: $selectedFolderItemID,
                        items: folderItems,
                        onQuickLook: { previewURL = $0 },
                        onTrashFile: { trashFile(withID: $0) }
                    )
                } else {
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
            }
            .frame(minWidth: 280, idealWidth: 380)
        }
    }

    // MARK: - Folder mode helpers

    private var selectedFolderTreemapIndex: Int? {
        guard let id = selectedFolderItemID else { return nil }
        return folderItems.firstIndex(where: { $0.id == id })
    }

    private func handleFolderTreemapSelect(_ index: Int) {
        guard index < folderItems.count else { return }
        let item = folderItems[index]
        if item.isDirectory {
            currentDir = item.url
            selectedFolderItemID = nil
        } else {
            selectedFolderItemID = item.id
        }
    }

    private func handleFolderTreemapDelete(_ index: Int) {
        guard index < folderItems.count else { return }
        let item = folderItems[index]
        if !item.isDirectory, let fileID = item.fileID {
            trashFile(withID: fileID)
        }
    }

    private func trashFile(withID fileID: UUID) {
        if let index = scanner.files.firstIndex(where: { $0.id == fileID }) {
            confirmDelete(at: index)
        }
    }

    private func rebuildFolderItems() {
        guard browseMode == .folders, let root = scanner.rootPath else {
            folderItems = []
            folderTreemapEntries = []
            return
        }
        if currentDir == nil || !(currentDir!.path + "/").hasPrefix(root.path == "/" ? "/" : root.path + "/") && currentDir!.path != root.path {
            currentDir = root
        }
        guard let dir = currentDir else { return }

        let dirs = scanner.childDirectories(of: dir).map {
            FolderItem(url: $0.url, size: $0.size, isDirectory: true)
        }
        let fileItems = scanner.childFiles(of: dir).map {
            FolderItem(url: $0.path, size: $0.size, isDirectory: false, fileID: $0.id)
        }
        let combined = (dirs + fileItems).sorted { $0.size > $1.size }
        folderItems = combined
        folderTreemapEntries = combined.map { FileEntry(path: $0.url, size: $0.size) }

        if let id = selectedFolderItemID, !combined.contains(where: { $0.id == id }) {
            selectedFolderItemID = nil
        }
    }

    private var treemapHeader: some View {
        HStack(spacing: 6) {
            if scanner.scanning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text(browseMode == .folders && scanner.fullTree == nil
                     ? "Treemap (scanning — building full map...)"
                     : "Treemap (scanning...)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.7))
            } else {
                Text("Treemap")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            if browseMode == .folders {
                if let info = treemapPathInfo {
                    Text(info)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let selected = treemapSelectedPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected)])
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Reveal selection in Finder")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.06))
    }

    /// Hovered (preferred) or selected treemap path, relative to the root, with its size.
    private var treemapPathInfo: String? {
        guard let path = treemapHoveredPath ?? treemapSelectedPath else { return nil }
        var display = path
        if let root = scanner.rootPath, path.hasPrefix(root.path) {
            let relative = String(path.dropFirst(root.path.count))
            display = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            if display.isEmpty { display = root.lastPathComponent }
        }
        if let size = scanner.sizeOfScannedPath(path) {
            return "\(display) — \(formattedBytes(size))"
        }
        return display
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

            if !markedFiles.isEmpty {
                Text("\(markedFiles.count) selected (\(formattedBytes(markedTotalSize())))")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.8))

                Button {
                    markedFiles.removeAll()
                } label: {
                    Text("Clear")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
            }
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
        let isMarked = markedFiles.contains(file.id)
        let color = Self.rowColors[index % Self.rowColors.count]

        return HStack(spacing: 8) {
            // Selection checkbox
            Image(systemName: isMarked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(isMarked ? .orange : .white.opacity(0.2))
                .onTapGesture {
                    toggleMark(file.id)
                }

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
            .help("Move to Trash")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMarked ? Color.orange.opacity(0.15) : (isSelected ? Color.orange.opacity(0.35) : Color.white.opacity(0.03)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isMarked ? Color.orange.opacity(0.5) : (isSelected ? Color.orange.opacity(0.6) : Color.clear), lineWidth: 1)
        )
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                toggleMark(file.id)
            } else {
                selectedIndex = index
            }
        }
        .contextMenu {
            Button(isMarked ? "Deselect" : "Select for Batch Delete") {
                toggleMark(file.id)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.path])
            }
            Button("Quick Look") {
                previewURL = file.path
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path.path, forType: .string)
            }
            Divider()
            if !markedFiles.isEmpty {
                Button("Move \(markedFiles.count) Selected Files to Trash", role: .destructive) {
                    showBatchDeleteConfirm = true
                }
            }
            Button("Move to Trash", role: .destructive) { confirmDelete(at: index) }
        }
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.yellow.opacity(0.8))

            Text("\(scanner.permissionDeniedCount) items couldn't be read due to permissions. Grant Full Disk Access for complete results.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                openFullDiskAccessSettings()
            } label: {
                Text("Grant Full Disk Access")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.yellow.opacity(0.8))
                    )
            }
            .buttonStyle(.plain)
            .help("Open System Settings > Privacy & Security > Full Disk Access")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
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

            if !markedFiles.isEmpty {
                Text("\(markedFiles.count) marked (\(formattedBytes(markedTotalSize())))")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.6))
            }

            if let idx = selectedIndex, idx < scanner.files.count {
                Text("Selected: \(scanner.files[idx].name) (\(scanner.files[idx].formattedSize))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }

            Text("↑↓ nav  ⌘+click select  ⌫ trash  ⌘Y quick look")
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
            if showDeleteConfirm || showBatchDeleteConfirm || showAlert { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Folder drill-down mode has its own navigation
            if browseMode == .folders {
                switch event.keyCode {
                case 125, 38: // down, j
                    moveFolderSelection(by: 1); return nil
                case 126, 40: // up, k
                    moveFolderSelection(by: -1); return nil
                case 36: // return — descend into folder / quick look file
                    if let item = selectedFolderItem() {
                        if item.isDirectory {
                            currentDir = item.url
                            selectedFolderItemID = nil
                        } else {
                            previewURL = item.url
                        }
                    }
                    return nil
                case 51, 117: // delete — trash selected file
                    if let item = selectedFolderItem(), !item.isDirectory, let fileID = item.fileID {
                        trashFile(withID: fileID)
                    }
                    return nil
                case 123: // left arrow — go up
                    if let dir = currentDir, let root = scanner.rootPath, dir.path != root.path {
                        currentDir = dir.deletingLastPathComponent()
                        selectedFolderItemID = nil
                    }
                    return nil
                default:
                    return event
                }
            }

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
            case 49: // space
                handleSpaceKey(); return nil
            case 0: // a
                if modifiers.contains(.command) {
                    // Cmd+A = select all
                    selectAll(); return nil
                }
                return event
            case 16: // y
                if modifiers.contains(.command) {
                    // Cmd+Y = Quick Look (standard Finder shortcut)
                    quickLookSelected(); return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func selectedFolderItem() -> FolderItem? {
        guard let id = selectedFolderItemID else { return nil }
        return folderItems.first(where: { $0.id == id })
    }

    private func moveFolderSelection(by delta: Int) {
        guard !folderItems.isEmpty else { return }
        if let id = selectedFolderItemID, let current = folderItems.firstIndex(where: { $0.id == id }) {
            let newIndex = max(0, min(folderItems.count - 1, current + delta))
            selectedFolderItemID = folderItems[newIndex].id
        } else {
            selectedFolderItemID = delta > 0 ? folderItems.first?.id : folderItems.last?.id
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
        if !markedFiles.isEmpty {
            // If files are marked, do batch delete
            showBatchDeleteConfirm = true
        } else if let idx = selectedIndex, idx < scanner.files.count {
            confirmDelete(at: idx)
        }
    }

    private func quickLookSelected() {
        guard let idx = selectedIndex, idx < scanner.files.count else { return }
        previewURL = scanner.files[idx].path
    }

    private func handleRevealKey() {
        if let idx = selectedIndex, idx < scanner.files.count {
            NSWorkspace.shared.activateFileViewerSelecting([scanner.files[idx].path])
        }
    }

    private func handleSpaceKey() {
        guard let idx = selectedIndex, idx < scanner.files.count else { return }
        let fileId = scanner.files[idx].id
        toggleMark(fileId)
        // Auto-advance
        if idx < scanner.files.count - 1 {
            selectedIndex = idx + 1
        }
    }

    private func selectAll() {
        for file in scanner.files {
            markedFiles.insert(file.id)
        }
    }

    // MARK: - Multi-select

    private func toggleMark(_ id: UUID) {
        if markedFiles.contains(id) {
            markedFiles.remove(id)
        } else {
            markedFiles.insert(id)
        }
    }

    private func markedTotalSize() -> UInt64 {
        scanner.files
            .filter { markedFiles.contains($0.id) }
            .reduce(0) { $0 + $1.size }
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

    private func chooseFolderPreNavigated(to directory: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to scan for large files"
        panel.prompt = "Scan"
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url: url)
        }
    }

    private func startScan(url: URL) {
        selectedIndex = nil
        markedFiles.removeAll()
        currentDir = url
        selectedFolderItemID = nil
        folderItems = []
        folderTreemapEntries = []
        treemapSelectedPath = nil
        treemapHoveredPath = nil
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
        // Clean up the mark if it was marked
        if index < scanner.files.count + 1 {
            // File was removed, marks are by UUID so they'll naturally become stale
        }
        if let sel = selectedIndex, sel >= scanner.files.count, !scanner.files.isEmpty {
            selectedIndex = scanner.files.count - 1
        }
        deleteTargetIndex = nil
    }

    private func performBatchDelete() {
        let indices = scanner.files.enumerated()
            .filter { markedFiles.contains($0.element.id) }
            .map { $0.offset }

        guard !indices.isEmpty else { return }

        let result = scanner.deleteFiles(at: indices)

        // Clear marks
        markedFiles.removeAll()

        if result.failCount > 0 {
            alertMessage = "Moved \(result.successCount) files to Trash (\(formattedBytes(result.totalFreed)) freed), \(result.failCount) failed"
            if let error = result.firstError {
                alertMessage! += " — \(error)"
            }
            showAlert = true
        }

        // Adjust selected index
        if let sel = selectedIndex, sel >= scanner.files.count, !scanner.files.isEmpty {
            selectedIndex = scanner.files.count - 1
        }
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
