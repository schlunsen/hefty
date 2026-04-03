import SwiftUI

/// The main circular window container with block ring and dragging support
struct CircularWindowView: View {
    let diameter: CGFloat = 700
    @State private var scanner = FileScanner()

    var body: some View {
        ZStack {
            // Dark background circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.1),
                            Color(white: 0.04),
                            Color.black
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .frame(width: diameter, height: diameter)

            // Block ring animation - tetris blocks around the edge
            BlockRingView(
                diameter: diameter,
                isScanning: scanner.scanning
            )

            // Content area (clipped to inner circle) - close button is inside here
            CircularContentView(scanner: scanner)
                .frame(width: diameter - 80, height: diameter - 80)
                .clipShape(Circle())
        }
        .frame(width: diameter, height: diameter)
    }
}
