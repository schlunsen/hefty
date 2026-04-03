import SwiftUI

/// Animated block border around the rectangular window
/// Smooth flowing color animation that travels along the edges
struct BlockBorderView: View {
    let isScanning: Bool

    // Pre-computed warm palette as Color values
    private static let paletteColors: [Color] = {
        let rgb: [(Double, Double, Double)] = [
            (1.0, 0.55, 0.05),   // orange
            (1.0, 0.40, 0.05),   // deep orange
            (0.95, 0.50, 0.10),  // amber
            (1.0, 0.65, 0.15),   // light orange
            (0.85, 0.35, 0.10),  // burnt orange
            (0.65, 0.30, 0.80),  // purple
            (0.40, 0.50, 0.90),  // blue
            (0.30, 0.70, 0.60),  // teal
        ]
        return rgb.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawBorder(context: context, size: size, time: time)
            }
        }
        .drawingGroup() // Metal-backed rendering for smoother compositing
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
        let perimeter = 2.0 * (Double(w) + Double(h))

        // Flow speed: how fast the highlight chases around
        let flowSpeed = scanning ? 120.0 : 30.0
        let flowPos = time * flowSpeed

        // Pre-compute flow positions (avoid repeated modulo)
        let flowMod = flowPos.truncatingRemainder(dividingBy: perimeter)
        let flow2Mod = (flowPos * 0.6 + perimeter * 0.4).truncatingRemainder(dividingBy: perimeter)
        let halfPerimeter = perimeter * 0.5
        let bandWidth = scanning ? 200.0 : 120.0
        let bandWidth2 = bandWidth * 0.7
        let invBandWidth = 1.0 / bandWidth
        let invBandWidth2 = 1.0 / bandWidth2
        let baseBrightness = scanning ? 0.45 : 0.55

        // Top edge: left to right
        var dist: Double = 0
        var globalIndex = 0
        let topCount = Int(w / blockLen)
        for i in 0..<topCount {
            let x = CGFloat(i) * blockLen
            let d = dist + Double(i) * Double(blockLen)
            let rect = CGRect(x: x, y: 0, width: blockLen - gap, height: bw - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowMod: flowMod, flow2Mod: flow2Mod, halfPerimeter: halfPerimeter,
                      invBandWidth: invBandWidth, invBandWidth2: invBandWidth2,
                      baseBrightness: baseBrightness, index: globalIndex,
                      time: time, palette: Self.paletteColors)
            globalIndex += 1
        }
        dist += Double(w)

        // Right edge: top to bottom
        let rightCount = Int((h - 2 * bw) / blockLen)
        for i in 0..<rightCount {
            let y = bw + CGFloat(i) * blockLen
            let d = dist + Double(i) * Double(blockLen)
            let rect = CGRect(x: w - bw, y: y, width: bw - gap, height: blockLen - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowMod: flowMod, flow2Mod: flow2Mod, halfPerimeter: halfPerimeter,
                      invBandWidth: invBandWidth, invBandWidth2: invBandWidth2,
                      baseBrightness: baseBrightness, index: globalIndex,
                      time: time, palette: Self.paletteColors)
            globalIndex += 1
        }
        dist += Double(h - 2 * bw)

        // Bottom edge: right to left
        let bottomCount = Int(w / blockLen)
        for i in 0..<bottomCount {
            let x = w - CGFloat(i + 1) * blockLen
            let d = dist + Double(i) * Double(blockLen)
            let rect = CGRect(x: x, y: h - bw, width: blockLen - gap, height: bw - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowMod: flowMod, flow2Mod: flow2Mod, halfPerimeter: halfPerimeter,
                      invBandWidth: invBandWidth, invBandWidth2: invBandWidth2,
                      baseBrightness: baseBrightness, index: globalIndex,
                      time: time, palette: Self.paletteColors)
            globalIndex += 1
        }
        dist += Double(w)

        // Left edge: bottom to top
        let leftCount = Int((h - 2 * bw) / blockLen)
        for i in 0..<leftCount {
            let y = h - bw - CGFloat(i + 1) * blockLen
            let d = dist + Double(i) * Double(blockLen)
            let rect = CGRect(x: 0, y: y, width: bw - gap, height: blockLen - gap)
            drawBlock(context: context, rect: rect, dist: d, perimeter: perimeter,
                      flowMod: flowMod, flow2Mod: flow2Mod, halfPerimeter: halfPerimeter,
                      invBandWidth: invBandWidth, invBandWidth2: invBandWidth2,
                      baseBrightness: baseBrightness, index: globalIndex,
                      time: time, palette: Self.paletteColors)
            globalIndex += 1
        }
    }

    private func drawBlock(
        context: GraphicsContext, rect: CGRect, dist: Double, perimeter: Double,
        flowMod: Double, flow2Mod: Double, halfPerimeter: Double,
        invBandWidth: Double, invBandWidth2: Double,
        baseBrightness: Double, index: Int,
        time: Double, palette: [Color]
    ) {
        // Deterministic palette lookup via hash
        let raw = (index &* 2654435761) >> 4
        let cIdx = ((raw % palette.count) + palette.count) % palette.count
        let baseColor = palette[cIdx]

        // Distance from flow position (wrapping around perimeter)
        var delta = abs(dist - flowMod)
        if delta > halfPerimeter { delta = perimeter - delta }

        // Smooth highlight with cubic ease for silkier transitions
        let highlight = max(0, 1.0 - delta * invBandWidth)
        let smoothHighlight = highlight * highlight * highlight // cubic ease

        // Second band
        var delta2 = abs(dist - flow2Mod)
        if delta2 > halfPerimeter { delta2 = perimeter - delta2 }
        let highlight2 = max(0, 1.0 - delta2 * invBandWidth2)
        let smoothHighlight2 = highlight2 * highlight2 * 0.5

        // Gentle base shimmer (pre-computed phase from index)
        let shimmerPhase = Double((index &* 2654435761) % 6283) / 1000.0
        let shimmer = sin(time * 1.2 + shimmerPhase) * 0.08

        // Final brightness
        let brightness = baseBrightness + smoothHighlight * 0.55 + smoothHighlight2 * 0.3 + shimmer

        context.fill(Path(rect), with: .color(baseColor.opacity(brightness)))
        // Removed per-block stroke — gap separation is sufficient and much cheaper
    }
}
