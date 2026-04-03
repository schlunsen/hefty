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
            try FileManager.default.removeItem(at: file.path)
            deletedBytes += size
            deletedCount += 1
            totalSize = totalSize >= size ? totalSize - size : 0
            files.remove(at: index)
            return (true, "Deleted \(name) (freed \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        } catch {
            return (false, "Error deleting \(name): \(error.localizedDescription)")
        }
    }

    /// Delete multiple files at the given indices. Returns summary.
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
                try FileManager.default.removeItem(at: file.path)
                deletedBytes += file.size
                deletedCount += 1
                totalSize = totalSize >= file.size ? totalSize - file.size : 0
                totalFreed += file.size
                removedIndices.append(index)
                successCount += 1
            } catch {
                failCount += 1
                if firstError == nil {
                    firstError = "Error deleting \(file.name): \(error.localizedDescription)"
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

        guard let enumerator = fileManager.enumerator(
            at: path,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run { self.scanning = false }
            return
        }

        var localFileCount: UInt64 = 0
        var localTotalBytes: UInt64 = 0
        var batch: [FileEntry] = []
        let batchSize = 50

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
        await MainActor.run {
            self.scanFileCount = finalCount
            self.scanTotalBytes = finalBytes
            self.scanning = false
        }
    }

    /// Insert a file entry in sorted position (largest first)
    private func insertSorted(entry: FileEntry) {
        let index = files.firstIndex(where: { $0.size < entry.size }) ?? files.count
        files.insert(entry, at: index)
    }
}
