import SwiftUI

/// Animated block ring that circles the inner edge of the window
/// Inspired by mempool.space block visualizer - tetris-like packed rectangles
struct BlockRingView: View {
    let diameter: CGFloat
    let isScanning: Bool

    // Block data generated once deterministically
    private let ringBlocks: [RingBlock]

    private static let blockColors: [(Double, Double, Double)] = [
        (1.0, 0.6, 0.1),    // orange
        (1.0, 0.45, 0.05),   // deep orange
        (0.9, 0.5, 0.15),    // amber
        (1.0, 0.7, 0.2),     // light orange
        (0.85, 0.4, 0.1),    // burnt orange
        (0.6, 0.3, 0.8),     // purple
        (0.4, 0.5, 0.9),     // blue
        (0.3, 0.7, 0.6),     // teal
    ]

    init(diameter: CGFloat, isScanning: Bool) {
        self.diameter = diameter
        self.isScanning = isScanning
        self.ringBlocks = Self.generateBlocks(diameter: diameter)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let scanning = isScanning

                for block in ringBlocks {
                    drawBlock(context: context, center: center, block: block, time: time, scanning: scanning)
                }

                // Inner ring border
                let innerR = diameter / 2 - 40
                strokeCircle(context: context, center: center, radius: innerR, color: .black, opacity: 0.8, width: 2)

                // Outer ring border
                let outerR = diameter / 2 - 4
                strokeCircle(context: context, center: center, radius: outerR, color: .black, opacity: 0.4, width: 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private func strokeCircle(context: GraphicsContext, center: CGPoint, radius: CGFloat, color: Color, opacity: Double, width: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)), lineWidth: width)
    }

    private func drawBlock(context: GraphicsContext, center: CGPoint, block: RingBlock, time: Double, scanning: Bool) {
        let c = Self.blockColors[block.colorIndex % Self.blockColors.count]

        // Always animate: subtle shimmer when idle, stronger pulse when scanning
        let wave = Foundation.sin(time * (scanning ? 2.5 : 0.8) + block.phase)
        let pulse: Double
        if scanning {
            pulse = 0.65 + (wave * 0.5 + 0.5) * 0.35
        } else {
            pulse = 0.75 + (wave * 0.5 + 0.5) * 0.15
        }

        // Slow rotation always, faster when scanning
        let speed = scanning ? 0.3 : 0.02
        let angleOffset = time * speed

        let startA = block.startAngle + angleOffset
        let endA = block.endAngle + angleOffset
        let gap = 0.005

        var path = Path()
        path.addArc(center: center, radius: block.outerRadius,
                     startAngle: .radians(startA + gap), endAngle: .radians(endA - gap), clockwise: false)
        path.addArc(center: center, radius: block.innerRadius,
                     startAngle: .radians(endA - gap), endAngle: .radians(startA + gap), clockwise: true)
        path.closeSubpath()

        let opacity = pulse * block.sizeVariant
        context.fill(path, with: .color(Color(red: c.0, green: c.1, blue: c.2).opacity(opacity)))
        context.stroke(path, with: .color(Color.black.opacity(0.5)), lineWidth: 0.5)
    }

    /// Generate blocks deterministically (no randomness at draw time)
    private static func generateBlocks(diameter: CGFloat) -> [RingBlock] {
        var result: [RingBlock] = []
        let ringWidth: CGFloat = 34
        let innerRadius = diameter / 2 - ringWidth - 6
        let outerRadius = diameter / 2 - 6

        let segmentCount = 64
        for i in 0..<segmentCount {
            let startAngle = Double(i) / Double(segmentCount) * .pi * 2 - .pi / 2
            let endAngle = Double(i + 1) / Double(segmentCount) * .pi * 2 - .pi / 2

            // Deterministic "random" based on segment index
            let seed = i * 2654435761 // Knuth multiplicative hash
            let blockCount = 2 + (seed % 3)  // 2-4 blocks per segment
            let radialStep = (outerRadius - innerRadius) / CGFloat(blockCount)

            for j in 0..<blockCount {
                let r1 = innerRadius + CGFloat(j) * radialStep
                let r2 = r1 + radialStep - 1.0
                let colorIndex = ((i * 3 + j * 7 + 5) &* 2654435761) % Self.blockColors.count
                let sizeHash = ((i * 17 + j * 31 + 13) &* 2654435761)
                let sizeVariant = 0.6 + Double(sizeHash % 400) / 1000.0
                let phaseHash = ((i * 41 + j * 59 + 7) &* 2654435761)
                let phase = Double(phaseHash % 6283) / 1000.0

                result.append(RingBlock(
                    segmentIndex: i,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    innerRadius: r1,
                    outerRadius: r2,
                    colorIndex: colorIndex,
                    sizeVariant: sizeVariant,
                    phase: phase
                ))
            }
        }

        return result
    }
}

struct RingBlock {
    let segmentIndex: Int
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let colorIndex: Int
    let sizeVariant: Double
    let phase: Double
}
