import Foundation

/// One file inside a ScanNode. Only the leaf name is stored; the full path is
/// reconstructed by walking the tree, which keeps the structure compact even
/// for scans with hundreds of thousands of files.
nonisolated struct ScanFile {
    let name: String
    let size: UInt64
}

/// Lightweight node in the full scan tree: a directory with its aggregated
/// size, subdirectories, and every regular file directly inside it.
///
/// Built with purely local state on the scan task and handed to the MainActor
/// exactly once at scan completion; it is never mutated afterwards, which is
/// why the @unchecked Sendable is safe.
nonisolated final class ScanNode: @unchecked Sendable {
    let name: String
    var size: UInt64 = 0
    var dirs: [ScanNode] = []
    var files: [ScanFile] = []

    init(name: String) {
        self.name = name
    }

    /// Build the full tree from per-directory file lists and aggregated sizes.
    /// `dirFiles` maps a directory path to the files directly inside it;
    /// `dirSizes` maps every directory path to its total (recursive) size.
    static func buildTree(
        rootPath: String,
        dirFiles: [String: [ScanFile]],
        dirSizes: [String: UInt64]
    ) -> ScanNode {
        let rootName = rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        let root = ScanNode(name: rootName)
        root.size = dirSizes[rootPath] ?? 0

        var nodes: [String: ScanNode] = [rootPath: root]
        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"

        func ensureNode(_ path: String) -> ScanNode? {
            if let existing = nodes[path] { return existing }
            guard path.hasPrefix(rootPrefix), path != "/" else { return nil }
            let parentPath = (path as NSString).deletingLastPathComponent
            guard parentPath != path, let parent = ensureNode(parentPath) else { return nil }
            let node = ScanNode(name: (path as NSString).lastPathComponent)
            node.size = dirSizes[path] ?? 0
            parent.dirs.append(node)
            nodes[path] = node
            return node
        }

        for (dirPath, files) in dirFiles {
            guard let node = ensureNode(dirPath) else { continue }
            node.files = files
        }

        // Sort children largest-first so the treemap layout can consume them directly.
        for node in nodes.values {
            node.dirs.sort { $0.size > $1.size }
            node.files.sort { $0.size > $1.size }
        }
        return root
    }
}
