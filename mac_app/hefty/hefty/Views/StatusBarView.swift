import SwiftUI

struct StatusBarView: View {
    let scanner: FileScanner
    let selectedIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            // Scan status
            if scanner.scanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning: \(scanner.scanFileCount) files (\(formattedBytes(scanner.scanTotalBytes)))")
                    .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Total: \(formattedBytes(max(scanner.scanTotalBytes, scanner.totalSize))) | Files: \(scanner.files.count)")
                    .font(.caption)
            }

            Divider().frame(height: 12)

            // Selected file
            if let idx = selectedIndex, idx < scanner.files.count {
                let file = scanner.files[idx]
                Text("Selected: \(file.name) (\(file.formattedSize))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Freed space
            if scanner.deletedCount > 0 {
                Divider().frame(height: 12)
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("Freed: \(formattedBytes(scanner.deletedBytes)) (\(scanner.deletedCount) files)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
