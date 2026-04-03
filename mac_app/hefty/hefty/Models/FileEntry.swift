import Foundation

struct FileEntry: Identifiable, Equatable {
    let id = UUID()
    let path: URL
    let size: UInt64

    var name: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        lhs.id == rhs.id
    }
}
