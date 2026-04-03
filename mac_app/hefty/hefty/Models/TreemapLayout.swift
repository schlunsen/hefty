import Foundation

struct TreemapRect: Equatable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let index: Int
    let size: UInt64
}

/// Squarified treemap layout algorithm.
/// Takes a slice of sizes (sorted descending) and a bounding box.
enum TreemapLayout {
    static func layout(sizes: [UInt64], width: Double, height: Double) -> [TreemapRect] {
        if sizes.isEmpty { return [] }

        var rects: [TreemapRect] = []
        rects.reserveCapacity(sizes.count)
        let indexed = sizes.enumerated().map { ($0.offset, $0.element) }
        squarify(items: indexed, x: 0, y: 0, w: width, h: height, rects: &rects)
        return rects
    }

    private static func squarify(
        items: [(Int, UInt64)],
        x: Double, y: Double,
        w: Double, h: Double,
        rects: inout [TreemapRect]
    ) {
        if items.isEmpty || w <= 0 || h <= 0 { return }

        if items.count == 1 {
            rects.append(TreemapRect(x: x, y: y, w: w, h: h, index: items[0].0, size: items[0].1))
            return
        }

        let total: Double = items.reduce(0) { $0 + Double($1.1) }
        if total <= 0 { return }

        let layoutVertical = w >= h
        let side = layoutVertical ? h : w

        var row: [(Int, UInt64)] = []
        var rowSum: Double = 0
        var bestWorst = Double.greatestFiniteMagnitude
        var splitAt = items.count

        for (i, item) in items.enumerated() {
            row.append(item)
            rowSum += Double(item.1)

            let rowArea = (rowSum / total) * w * h
            let rowSide = rowArea / side
            let worst = worstAspectRatio(row: row, rowSum: rowSum, rowSide: rowSide, fixedSide: side)

            if worst <= bestWorst {
                bestWorst = worst
            } else {
                row.removeLast()
                rowSum -= Double(item.1)
                splitAt = i
                break
            }
        }

        let rowFraction = rowSum / total

        if layoutVertical {
            let rowW = w * rowFraction
            var cy = y
            for (idx, size) in row {
                let frac = Double(size) / rowSum
                let rh = h * frac
                rects.append(TreemapRect(x: x, y: cy, w: rowW, h: rh, index: idx, size: size))
                cy += rh
            }
            squarify(items: Array(items[splitAt...]), x: x + rowW, y: y, w: w - rowW, h: h, rects: &rects)
        } else {
            let rowH = h * rowFraction
            var cx = x
            for (idx, size) in row {
                let frac = Double(size) / rowSum
                let rw = w * frac
                rects.append(TreemapRect(x: cx, y: y, w: rw, h: rowH, index: idx, size: size))
                cx += rw
            }
            squarify(items: Array(items[splitAt...]), x: x, y: y + rowH, w: w, h: h - rowH, rects: &rects)
        }
    }

    private static func worstAspectRatio(row: [(Int, UInt64)], rowSum: Double, rowSide: Double, fixedSide: Double) -> Double {
        if rowSum <= 0 || rowSide <= 0 || fixedSide <= 0 { return .greatestFiniteMagnitude }

        var worst: Double = 0
        for (_, size) in row {
            let itemFrac = Double(size) / rowSum
            let itemSide = fixedSide * itemFrac
            if itemSide <= 0 || rowSide <= 0 { continue }
            let ratio = rowSide > itemSide ? rowSide / itemSide : itemSide / rowSide
            worst = max(worst, ratio)
        }
        return worst
    }
}
