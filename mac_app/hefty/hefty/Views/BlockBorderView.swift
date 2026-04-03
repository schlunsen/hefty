import SwiftUI

/// Animated block border around the rectangular window
/// Smooth flowing color animation that travels along the edges
struct BlockBorderView: View {
    let isScanning: Bool

    // Warm palette for the blocks
    private static let palette: [(Double, Double, Double)] = [
        (1.0, 0.55, 0.05),   // orange
        (1.0, 0.40, 0.05),   // deep orange
        (0.95, 0.50, 0.10),  // amber
        (1.0, 0.65, 0.15),   // light orange
        (0.85, 0.35, 0.10),  // burnt orange
        (0.65, 0.30, 0.80),  // purple
        (0.40, 0.50, 0.90),  // blue
        (0.30, 0.70, 0.60),  // teal
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawBorder(context: context, size: size, time: time)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private func drawBorder(context: GraphicsContext, size: CGSize, time: Double) {
        let bw: CGFloat = 6
        let w = size.width
        let h = size.height
        let blockLen: CGFloat = 10
        let gap: CGFloat = 0.5
        let scanning = isScanning

        // Dark background
        context.fill(
            Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
            with: .color(Color(white: 0.03))
        )

        // Total perimeter distance for continuous flow
        let perimeter = 2.0 * (w + h)

        // Flow speed: how fast the highlight chases around
        let flowSpeed = scanning ? 120.0 : 30.0
        let flowPos = time * flowSpeed

        // Top edge: left to right
        var dist: CGFloat = 0
        let topCount = Int(w / blockLen)
        for i in 0..<topCount {
            let x = CGFloat(i) * blockLen
            let d = dist + CGFloat(i) * blockLen
            let rect = CGRect(x: x, y: 0, width: blockLen - gap, height: bw - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowPos: flowPos, index: i, time: time, scanning: scanning)
        }
        dist += w

        // Right edge: top to bottom
        let rightCount = Int((h - 2 * bw) / blockLen)
        for i in 0..<rightCount {
            let y = bw + CGFloat(i) * blockLen
            let d = dist + CGFloat(i) * blockLen
            let rect = CGRect(x: w - bw, y: y, width: bw - gap, height: blockLen - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowPos: flowPos, index: topCount + i, time: time, scanning: scanning)
        }
        dist += (h - 2 * bw)

        // Bottom edge: right to left
        let bottomCount = Int(w / blockLen)
        for i in 0..<bottomCount {
            let x = w - CGFloat(i + 1) * blockLen
            let d = dist + CGFloat(i) * blockLen
            let rect = CGRect(x: x, y: h - bw, width: blockLen - gap, height: bw - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowPos: flowPos, index: topCount + rightCount + i, time: time, scanning: scanning)
        }
        dist += w

        // Left edge: bottom to top
        let leftCount = Int((h - 2 * bw) / blockLen)
        for i in 0..<leftCount {
            let y = h - bw - CGFloat(i + 1) * blockLen
            let d = dist + CGFloat(i) * blockLen
            let rect = CGRect(x: 0, y: y, width: bw - gap, height: blockLen - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowPos: flowPos, index: topCount + rightCount + bottomCount + i, time: time, scanning: scanning)
        }
    }

    private func drawBlock(
        context: GraphicsContext, rect: CGRect, dist: CGFloat, perimeter: CGFloat,
        flowPos: Double, index: Int, time: Double, scanning: Bool
    ) {
        // Color from palette based on index
        let seed = index &* 2654435761
        let cIdx = ((seed >> 4) % Self.palette.count + Self.palette.count) % Self.palette.count
        let c = Self.palette[cIdx]

        // Flow highlight: a bright band that travels around the perimeter
        let normalizedDist = Double(dist).truncatingRemainder(dividingBy: Double(perimeter))
        let normalizedFlow = flowPos.truncatingRemainder(dividingBy: Double(perimeter))

        // Distance from flow position (wrapping around)
        var delta = abs(normalizedDist - normalizedFlow)
        if delta > Double(perimeter) / 2 {
            delta = Double(perimeter) - delta
        }

        // Highlight band width
        let bandWidth = scanning ? 200.0 : 120.0
        let highlight = max(0, 1.0 - delta / bandWidth)
        let smoothHighlight = highlight * highlight // ease-in curve

        // Second band for richer effect
        let normalizedFlow2 = (flowPos * 0.6 + Double(perimeter) * 0.4).truncatingRemainder(dividingBy: Double(perimeter))
        var delta2 = abs(normalizedDist - normalizedFlow2)
        if delta2 > Double(perimeter) / 2 {
            delta2 = Double(perimeter) - delta2
        }
        let highlight2 = max(0, 1.0 - delta2 / (bandWidth * 0.7))
        let smoothHighlight2 = highlight2 * highlight2 * 0.5

        // Gentle base shimmer
        let shimmerPhase = Double(seed % 6283) / 1000.0
        let shimmer = Foundation.sin(time * 1.2 + shimmerPhase) * 0.08

        // Final brightness
        let baseBrightness = scanning ? 0.45 : 0.55
        let brightness = baseBrightness + smoothHighlight * 0.55 + smoothHighlight2 * 0.3 + shimmer

        // Shift color toward white for highlights
        let r = c.0 + (1.0 - c.0) * smoothHighlight * 0.4
        let g = c.1 + (1.0 - c.1) * smoothHighlight * 0.4
        let b = c.2 + (1.0 - c.2) * smoothHighlight * 0.4

        context.fill(Path(rect), with: .color(Color(red: r, green: g, blue: b).opacity(brightness)))
        context.stroke(Path(rect), with: .color(Color.black.opacity(0.3)), lineWidth: 0.5)
    }
}
