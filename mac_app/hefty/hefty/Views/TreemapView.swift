import SwiftUI

struct TreemapView: View {
    let files: [FileEntry]
    let selectedIndex: Int?
    let onSelect: (Int) -> Void
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
        GeometryReader { geometry in
            let sizes = files.map(\.size)
            let rects = TreemapLayout.layout(
                sizes: sizes,
                width: Double(geometry.size.width),
                height: Double(geometry.size.height)
            )

            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.element.index) { _, rect in
                    let isSelected = rect.index == selectedIndex
                    let color = Self.colors[rect.index % Self.colors.count]

                    TreemapCell(
                        rect: rect,
                        file: rect.index < files.count ? files[rect.index] : nil,
                        color: color,
                        isSelected: isSelected
                    )
                    .animation(.easeInOut(duration: 0.35), value: rect.x)
                    .animation(.easeInOut(duration: 0.35), value: rect.y)
                    .animation(.easeInOut(duration: 0.35), value: rect.w)
                    .animation(.easeInOut(duration: 0.35), value: rect.h)
                    .transition(.scale.combined(with: .opacity))
                    .onTapGesture {
                        onSelect(rect.index)
                    }
                    .contextMenu {
                        if rect.index < files.count {
                            let file = files[rect.index]
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.path])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path.path, forType: .string)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                onDelete(rect.index)
                            }
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: files.count)
        }
    }
}

private struct TreemapCell: View {
    let rect: TreemapRect
    let file: FileEntry?
    let color: Color
    let isSelected: Bool

    var body: some View {
        let w = max(rect.w, 1)
        let h = max(rect.h, 1)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : color)
                .opacity(isSelected ? 1.0 : 0.8)

            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)

            if let file, w > 40, h > 20 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: labelFontSize(w: w, h: h), weight: isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if h > 35 {
                        Text(file.formattedSize)
                            .font(.system(size: max(labelFontSize(w: w, h: h) - 1, 8)))
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(isSelected ? .white : .black)
                .padding(5)
            }
        }
        .frame(width: w, height: h)
        .offset(x: rect.x, y: rect.y)
    }

    private func labelFontSize(w: Double, h: Double) -> CGFloat {
        let minDim = min(w, h)
        if minDim < 30 { return 8 }
        if minDim < 60 { return 10 }
        if minDim < 120 { return 12 }
        return 14
    }
}
