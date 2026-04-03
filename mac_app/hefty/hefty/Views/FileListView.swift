import SwiftUI

struct FileListView: View {
    let files: [FileEntry]
    let rootPath: URL?
    @Binding var selectedIndex: Int?
    let onDelete: (Int) -> Void

    private static let colors: [Color] = [
        .blue, .green, .yellow, .cyan, .purple, .red,
        Color(red: 0.4, green: 0.6, blue: 1.0),
        Color(red: 0.4, green: 0.9, blue: 0.4),
        Color(red: 1.0, green: 0.9, blue: 0.4),
        Color(red: 0.4, green: 0.9, blue: 0.9),
        Color(red: 0.9, green: 0.4, blue: 0.9),
        Color(red: 1.0, green: 0.5, blue: 0.5),
    ]

    var body: some View {
        List(selection: Binding(
            get: { selectedIndex.flatMap { files.indices.contains($0) ? files[$0].id : nil } },
            set: { newID in
                selectedIndex = files.firstIndex(where: { $0.id == newID })
            }
        )) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                FileRowView(
                    file: file,
                    relativePath: relativePath(for: file),
                    color: Self.colors[index % Self.colors.count],
                    isSelected: index == selectedIndex
                )
                .tag(file.id)
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.path])
                    }
                    Button("Delete", role: .destructive) {
                        onDelete(index)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func relativePath(for file: FileEntry) -> String {
        guard let root = rootPath else { return file.path.path }
        let rootStr = root.path
        let fileStr = file.path.path
        if fileStr.hasPrefix(rootStr) {
            let relative = String(fileStr.dropFirst(rootStr.count))
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return fileStr
    }
}

private struct FileRowView: View {
    let file: FileEntry
    let relativePath: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 6, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(file.formattedSize)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }
}
