import Foundation
import Observation

@Observable
@MainActor
final class FileScanner {
    var files: [FileEntry] = []
    var totalSize: UInt64 = 0
    var scanning = false
    var scanFileCount: UInt64 = 0
    var scanTotalBytes: UInt64 = 0
    var rootPath: URL?
    var deletedBytes: UInt64 = 0
    var deletedCount: Int = 0
    var permissionDeniedCount: Int = 0
    /// Aggregated size of every directory under the root (keyed by path).
    var dirSizes: [String: UInt64] = [:]
    /// Bumped whenever dirSizes is republished, so views can cheaply observe changes.
    var dirSizesVersion: Int = 0
    /// Full tree of every scanned file (not limited by topN/minSize).
    /// Published once at scan completion; nil while a scan is in progress.
    var fullTree: ScanNode? = nil
    /// Bumped whenever fullTree is republished, so views can cheaply observe changes.
    var fullTreeVersion: Int = 0

    private var scanTask: Task<Void, Never>?
    private var topN: Int = 100
    var minSize: UInt64 = 0

    func startScan(path: URL, minSize: UInt64 = 0, topN: Int = 500) {
        // Cancel any existing scan
        scanTask?.cancel()

        // Reset state
        files = []
        totalSize = 0
        scanning = true
        scanFileCount = 0
        scanTotalBytes = 0
        rootPath = path
        deletedBytes = 0
        deletedCount = 0
        permissionDeniedCount = 0
        dirSizes = [:]
        dirSizesVersion = 0
        fullTree = nil
        fullTreeVersion += 1
        self.topN = topN
        self.minSize = minSize

        scanTask = Task {
            await performScan(path: path, minSize: minSize)
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanning = false
    }

    func deleteFile(at index: Int) -> (success: Bool, message: String) {
        guard index >= 0 && index < files.count else {
            return (false, "Invalid file index")
        }

        let file = files[index]
        let name = file.name
        let size = file.size

        do {
            try FileManager.default.trashItem(at: file.path, resultingItemURL: nil)
            deletedBytes += size
            deletedCount += 1
            totalSize = totalSize >= size ? totalSize - size : 0
            files.remove(at: index)
            return (true, "Moved \(name) to Trash (freed \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        } catch {
            return (false, "Error moving \(name) to Trash: \(error.localizedDescription)")
        }
    }

    /// Move multiple files at the given indices to the Trash. Returns summary.
    func deleteFiles(at indices: [Int]) -> (successCount: Int, failCount: Int, totalFreed: UInt64, firstError: String?) {
        // Sort descending so removal doesn't shift indices
        let sortedIndices = indices.sorted(by: >)

        var successCount = 0
        var failCount = 0
        var totalFreed: UInt64 = 0
        var firstError: String? = nil
        var removedIndices: [Int] = []

        for index in sortedIndices {
            guard index >= 0 && index < files.count else { continue }

            let file = files[index]
            do {
                try FileManager.default.trashItem(at: file.path, resultingItemURL: nil)
                deletedBytes += file.size
                deletedCount += 1
                totalSize = totalSize >= file.size ? totalSize - file.size : 0
                totalFreed += file.size
                removedIndices.append(index)
                successCount += 1
            } catch {
                failCount += 1
                if firstError == nil {
                    firstError = "Error moving \(file.name) to Trash: \(error.localizedDescription)"
                }
            }
        }

        // Remove successfully deleted files (already sorted descending)
        for index in removedIndices {
            if index < files.count {
                files.remove(at: index)
            }
        }

        return (successCount, failCount, totalFreed, firstError)
    }

    private func performScan(path: URL, minSize: UInt64) async {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]

        let deniedCounter = PermissionDeniedCounter()

        guard let enumerator = fileManager.enumerator(
            at: path,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                let nsError = error as NSError
                if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
                    || (nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))) {
                    deniedCounter.count += 1
                }
                return true // continue scanning past errors
            }
        ) else {
            await MainActor.run { self.scanning = false }
            return
        }

        var localFileCount: UInt64 = 0
        var localTotalBytes: UInt64 = 0
        var batch: [FileEntry] = []
        let batchSize = 50
        var localDirSizes: [String: UInt64] = [:]
        /// Files directly inside each directory, for the full-tree build at scan end.
        var localDirFiles: [String: [ScanFile]] = [:]
        var lastDirPublish: UInt64 = 0
        let rootPathStr = path.path

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))

                // Skip symbolic links
                if resourceValues.isSymbolicLink == true { continue }

                guard resourceValues.isRegularFile == true else { continue }

                let size = UInt64(resourceValues.fileSize ?? 0)
                localTotalBytes = localTotalBytes &+ size
                localFileCount += 1

                // Aggregate per-directory totals up to the scan root
                var dir = fileURL.deletingLastPathComponent()
                localDirFiles[dir.path, default: []].append(
                    ScanFile(name: fileURL.lastPathComponent, size: size)
                )
                while true {
                    localDirSizes[dir.path, default: 0] &+= size
                    if dir.path == rootPathStr || dir.path == "/" { break }
                    let parent = dir.deletingLastPathComponent()
                    if parent.path == dir.path { break }
                    dir = parent
                }

                if size >= minSize {
                    batch.append(FileEntry(path: fileURL, size: size))
                }

                // Send batch updates
                if localFileCount % UInt64(batchSize) == 0 || batch.count >= batchSize {
                    let currentBatch = batch
                    let count = localFileCount
                    let bytes = localTotalBytes
                    let limit = self.topN
                    batch = []

                    // Publish directory sizes every ~2000 files (dict copy is not free)
                    let dirSnapshot: [String: UInt64]?
                    if localFileCount - lastDirPublish >= 2000 {
                        dirSnapshot = localDirSizes
                        lastDirPublish = localFileCount
                    } else {
                        dirSnapshot = nil
                    }

                    await MainActor.run {
                        for entry in currentBatch {
                            self.insertSorted(entry: entry)
                        }
                        // Enforce top-N limit
                        if limit > 0 && self.files.count > limit {
                            self.files = Array(self.files.prefix(limit))
                        }
                        self.scanFileCount = count
                        self.scanTotalBytes = bytes
                        self.permissionDeniedCount = deniedCounter.count
                        if let dirSnapshot {
                            self.dirSizes = dirSnapshot
                            self.dirSizesVersion += 1
                        }
                    }
                }
            } catch {
                continue
            }
        }

        // Process remaining batch
        if !batch.isEmpty {
            let remainingBatch = batch
            let limit = self.topN
            await MainActor.run {
                for entry in remainingBatch {
                    self.insertSorted(entry: entry)
                }
                if limit > 0 && self.files.count > limit {
                    self.files = Array(self.files.prefix(limit))
                }
            }
        }

        let finalCount = localFileCount
        let finalBytes = localTotalBytes
        let finalDirSizes = localDirSizes
        // Build the full tree once from local state and hand it over in one publish.
        let tree = Task.isCancelled
            ? nil
            : ScanNode.buildTree(rootPath: rootPathStr, dirFiles: localDirFiles, dirSizes: localDirSizes)
        await MainActor.run {
            self.scanFileCount = finalCount
            self.scanTotalBytes = finalBytes
            self.permissionDeniedCount = deniedCounter.count
            self.dirSizes = finalDirSizes
            self.dirSizesVersion += 1
            if let tree {
                self.fullTree = tree
                self.fullTreeVersion += 1
            }
            self.scanning = false
        }
    }

    // MARK: - Full tree helpers

    /// Resolve the ScanNode for `dir` by walking the full tree from the scan root.
    func fullTreeNode(for dir: URL) -> ScanNode? {
        guard let tree = fullTree, let root = rootPath else { return nil }
        if dir.path == root.path { return tree }
        let rootComponents = root.pathComponents
        let dirComponents = dir.pathComponents
        guard dirComponents.count > rootComponents.count,
              Array(dirComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        var node = tree
        for name in dirComponents.dropFirst(rootComponents.count) {
            guard let next = node.dirs.first(where: { $0.name == name }) else { return nil }
            node = next
        }
        return node
    }

    /// Size of any scanned path: directories from dirSizes, files from the full tree.
    func sizeOfScannedPath(_ path: String) -> UInt64? {
        if let dirSize = dirSizes[path] { return dirSize }
        let url = URL(fileURLWithPath: path)
        guard let parent = fullTreeNode(for: url.deletingLastPathComponent()) else { return nil }
        let name = url.lastPathComponent
        return parent.files.first(where: { $0.name == name })?.size
    }

    // MARK: - Folder browsing helpers

    /// Immediate subdirectories of `dir` with their aggregated sizes, largest first.
    func childDirectories(of dir: URL) -> [(url: URL, size: UInt64)] {
        let dirPath = dir.path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        var result: [(url: URL, size: UInt64)] = []
        for (path, size) in dirSizes {
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            if !rest.isEmpty && !rest.contains("/") {
                result.append((URL(fileURLWithPath: path, isDirectory: true), size))
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    /// Known large files directly inside `dir`, largest first (from the top-N list).
    func childFiles(of dir: URL) -> [FileEntry] {
        let dirPath = dir.path
        return files.filter { $0.path.deletingLastPathComponent().path == dirPath }
    }

    /// Insert a file entry in sorted position (largest first)
    private func insertSorted(entry: FileEntry) {
        let index = files.firstIndex(where: { $0.size < entry.size }) ?? files.count
        files.insert(entry, at: index)
    }
}

/// Reference box for counting permission-denied paths from the enumerator's error handler.
private final class PermissionDeniedCounter {
    var count = 0
}
