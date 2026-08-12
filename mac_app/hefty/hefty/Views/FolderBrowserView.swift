import SwiftUI

/// One row in the folder drill-down browser: either a subdirectory or a file.
struct FolderItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let size: UInt64
    let isDirectory: Bool
    /// Backing FileEntry id when this item is a file from the scanner's list.
    let fileID: UUID?

    init(url: URL, size: UInt64, isDirectory: Bool, fileID: UUID? = nil) {
        self.id = fileID ?? UUID()
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.fileID = fileID
    }

    var name: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// Directory drill-down browser: breadcrumb + sorted list of subfolders and files.
struct FolderBrowserView: View {
    let scanner: FileScanner
    @Binding var currentDir: URL?
    @Binding var selectedItemID: UUID?
    let items: [FolderItem]
    let onQuickLook: (URL) -> Void
    let onTrashFile: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        folderRow(item)
                    }
                    if items.isEmpty {
                        Text(scanner.scanning ? "Aggregating folders..." : "Nothing here")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 24)
                    }
                }
            }
        }
    }

    // MARK: - Breadcrumb

    private var pathComponents: [URL] {
        guard let root = scanner.rootPath, let current = currentDir else { return [] }
        var components: [URL] = []
        var dir = current
        while true {
            components.append(dir)
            if dir.path == root.path || dir.path == "/" { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return components.reversed()
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Up button
                Button {
                    goUp()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(canGoUp ? 0.6 : 0.15))
                .disabled(!canGoUp)
                .help("Go to parent folder")

                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    Button {
                        currentDir = url
                        selectedItemID = nil
                    } label: {
                        Text(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
                            .font(.system(size: 10, weight: index == pathComponents.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == pathComponents.count - 1 ? .orange : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.05))
    }

    private var canGoUp: Bool {
        guard let root = scanner.rootPath, let current = currentDir else { return false }
        return current.path != root.path
    }

    private func goUp() {
        guard canGoUp, let current = currentDir else { return }
        currentDir = current.deletingLastPathComponent()
        selectedItemID = nil
    }

    // MARK: - Rows

    private func folderRow(_ item: FolderItem) -> some View {
        let isSelected = item.id == selectedItemID
        let fraction = fractionOfCurrentDir(item.size)

        return HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(item.isDirectory ? Color(red: 0.4, green: 0.6, blue: 1.0) : .white.opacity(0.35))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: item.isDirectory ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Relative size bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(item.isDirectory ? Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.6) : Color.orange.opacity(0.5))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(item.isDirectory ? Color(red: 0.4, green: 0.6, blue: 1.0) : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((item.isDirectory ? Color.blue : Color.orange).opacity(0.1))
                )

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.orange.opacity(0.3) : Color.white.opacity(0.03))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDirectory {
                currentDir = item.url
                selectedItemID = nil
            } else {
                selectedItemID = item.id
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button("Open Folder") {
                    currentDir = item.url
                    selectedItemID = nil
                }
            } else {
                Button("Quick Look") { onQuickLook(item.url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            if !item.isDirectory, let fileID = item.fileID {
                Divider()
                Button("Move to Trash", role: .destructive) { onTrashFile(fileID) }
            }
        }
    }

    private func fractionOfCurrentDir(_ size: UInt64) -> CGFloat {
        guard let dir = currentDir,
              let dirTotal = scanner.dirSizes[dir.path],
              dirTotal > 0
        else { return 0 }
        return CGFloat(Double(size) / Double(dirTotal))
    }
}
