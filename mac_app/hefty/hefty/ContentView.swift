import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var scanner = FileScanner()
    @State private var selectedIndex: Int? = nil
    @State private var showTreemap = true
    @State private var minSizeText = "1 MB"
    @State private var topNText = "100"
    @State private var showDeleteConfirm = false
    @State private var deleteTargetIndex: Int? = nil
    @State private var alertMessage: String? = nil
    @State private var showAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ScanToolbar(
                scanner: scanner,
                showTreemap: $showTreemap,
                minSizeText: $minSizeText,
                topNText: $topNText,
                onChooseFolder: chooseFolder,
                onRescan: rescan
            )

            Divider()

            // Main content
            if scanner.rootPath == nil {
                welcomeView
            } else if scanner.files.isEmpty && !scanner.scanning {
                emptyResultView
            } else {
                mainContentView
            }

            Divider()

            // Status bar
            StatusBarView(scanner: scanner, selectedIndex: selectedIndex)
        }
        .frame(minWidth: 800, minHeight: 500)
        .alert("Delete File", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {
                deleteTargetIndex = nil
            }
            Button("Delete", role: .destructive) {
                if let index = deleteTargetIndex {
                    performDelete(at: index)
                }
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
            if let msg = alertMessage {
                Text(msg)
            }
        }
        .focusable()
    }

    // MARK: - Sub Views

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Hefty")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Find the hefty files hogging your disk space")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button {
                chooseFolder()
            } label: {
                Label("Choose a Folder to Scan", systemImage: "folder.badge.questionmark")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            Text("Or drag and drop a folder onto this window")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No files found above minimum size threshold")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Try reducing the minimum file size")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainContentView: some View {
        if showTreemap {
            HSplitView {
                treemapSection
                    .frame(minWidth: 200)

                fileListSection
                    .frame(minWidth: 200)
            }
        } else {
            fileListSection
        }
    }

    private var treemapSection: some View {
        VStack(spacing: 0) {
            HStack {
                if scanner.scanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Treemap (scanning...)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Treemap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            TreemapView(
                files: scanner.files,
                selectedIndex: selectedIndex,
                onSelect: { index in selectedIndex = index },
                onDelete: { index in confirmDelete(at: index) }
            )
            .padding(4)
        }
    }

    private var fileListSection: some View {
        VStack(spacing: 0) {
            HStack {
                if scanner.scanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Files (\(scanner.files.count) found, scanning \(scanner.scanFileCount) files...)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Files (\(scanner.files.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            FileListView(
                files: scanner.files,
                rootPath: scanner.rootPath,
                selectedIndex: $selectedIndex,
                onDelete: { index in confirmDelete(at: index) }
            )
        }
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
        // Adjust selected index
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
                        DispatchQueue.main.async {
                            startScan(url: url)
                        }
                    }
                }
            }
        }
    }

    private func parseSize(_ text: String) -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()

        // Try plain number
        if let n = UInt64(trimmed) { return n }

        // Parse with suffix
        let suffixes: [(String, UInt64)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000),
            ("B", 1),
        ]

        for (suffix, multiplier) in suffixes {
            if trimmed.hasSuffix(suffix) {
                let numStr = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let n = Double(numStr) {
                    return UInt64(n * Double(multiplier))
                }
            }
        }

        return 1_000_000 // default 1 MB
    }
}

#Preview {
    ContentView()
}
