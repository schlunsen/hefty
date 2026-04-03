import SwiftUI

struct ScanToolbar: View {
    @Bindable var scanner: FileScanner
    @Binding var showTreemap: Bool
    @Binding var minSizeText: String
    @Binding var topNText: String
    let onChooseFolder: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onChooseFolder()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }

            if scanner.rootPath != nil {
                Divider().frame(height: 20)

                HStack(spacing: 4) {
                    Text("Min size:")
                        .font(.caption)
                    TextField("1 MB", text: $minSizeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { onRescan() }
                }

                HStack(spacing: 4) {
                    Text("Top N:")
                        .font(.caption)
                    TextField("100", text: $topNText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onSubmit { onRescan() }
                }

                Button {
                    onRescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.scanning)

                if scanner.scanning {
                    Button {
                        scanner.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .tint(.red)
                }

                Divider().frame(height: 20)

                Toggle(isOn: $showTreemap) {
                    Label("Treemap", systemImage: "square.grid.2x2")
                }
                .toggleStyle(.button)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
