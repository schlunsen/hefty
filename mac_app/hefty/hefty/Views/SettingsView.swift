import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultMinSize") private var defaultMinSize: Int = 1
    @AppStorage("defaultMinSizeUnit") private var defaultMinSizeUnit: String = "MB"
    @AppStorage("defaultTopN") private var defaultTopN: Int = 100
    @AppStorage("skipHiddenFiles") private var skipHiddenFiles: Bool = true
    @AppStorage("showDeleteConfirmation") private var showDeleteConfirmation: Bool = true

    private let sizeUnits = ["KB", "MB", "GB"]

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            scanSettings
                .tabItem {
                    Label("Scanning", systemImage: "doc.text.magnifyingglass")
                }
        }
        .frame(width: 420, height: 260)
    }

    private var generalSettings: some View {
        Form {
            Section("File Deletion") {
                Toggle("Confirm before deleting files", isOn: $showDeleteConfirmation)
            }

            Section("Display") {
                Toggle("Skip hidden files and folders", isOn: $skipHiddenFiles)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var scanSettings: some View {
        Form {
            Section("Default Scan Parameters") {
                HStack {
                    Text("Minimum file size")
                    Spacer()
                    TextField("1", value: $defaultMinSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $defaultMinSizeUnit) {
                        ForEach(sizeUnits, id: \.self) { unit in
                            Text(unit).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }

                HStack {
                    Text("Maximum files to display")
                    Spacer()
                    TextField("100", value: $defaultTopN, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    SettingsView()
}
