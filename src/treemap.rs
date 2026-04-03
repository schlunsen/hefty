/// A rectangle in the treemap layout
#[derive(Debug, Clone)]
pub struct TreemapRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub index: usize,
    pub size: u64,
}

/// Squarified treemap layout algorithm.
/// Takes a slice of sizes (sorted descending) and a bounding box.
pub fn layout(sizes: &[u64], width: f64, height: f64) -> Vec<TreemapRect> {
    if sizes.is_empty() {
        return Vec::new();
    }

    let mut rects = Vec::with_capacity(sizes.len());
    let indexed: Vec<(usize, u64)> = sizes.iter().enumerate().map(|(i, &s)| (i, s)).collect();
    squarify(&indexed, 0.0, 0.0, width, height, &mut rects);
    rects
}

fn squarify(
    items: &[(usize, u64)],
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rects: &mut Vec<TreemapRect>,
) {
    if items.is_empty() || w <= 0.0 || h <= 0.0 {
        return;
    }

    if items.len() == 1 {
        rects.push(TreemapRect {
            x,
            y,
            w,
            h,
            index: items[0].0,
            size: items[0].1,
        });
        return;
    }

    let total: f64 = items.iter().map(|&(_, s)| s as f64).sum();
    if total <= 0.0 {
        return;
    }

    let layout_vertical = w >= h;
    let side = if layout_vertical { h } else { w }; // the fixed side for the row

    let mut row: Vec<(usize, u64)> = Vec::new();
    let mut row_sum: f64 = 0.0;
    let mut best_worst = f64::MAX;
    let mut split_at = items.len(); // default: all items in one row

    for (i, &item) in items.iter().enumerate() {
        row.push(item);
        row_sum += item.1 as f64;

        let row_area = (row_sum / total) * w * h;
        let row_side = row_area / side;
        let worst = worst_aspect_ratio(&row, row_sum, row_side, side);

        if worst <= best_worst {
            best_worst = worst;
        } else {
            // Remove last, it made things worse
            row.pop();
            row_sum -= item.1 as f64;
            split_at = i;
            break;
        }
    }

    // Lay out the row
    let row_fraction = row_sum / total;

    if layout_vertical {
        let row_w = w * row_fraction;
        let mut cy = y;
        for &(idx, size) in &row {
            let frac = size as f64 / row_sum;
            let rh = h * frac;
            rects.push(TreemapRect {
                x,
                y: cy,
                w: row_w,
                h: rh,
                index: idx,
                size,
            });
            cy += rh;
        }
        squarify(&items[split_at..], x + row_w, y, w - row_w, h, rects);
    } else {
        let row_h = h * row_fraction;
        let mut cx = x;
        for &(idx, size) in &row {
            let frac = size as f64 / row_sum;
            let rw = w * frac;
            rects.push(TreemapRect {
                x: cx,
                y,
                w: rw,
                h: row_h,
                index: idx,
                size,
            });
            cx += rw;
        }
        squarify(&items[split_at..], x, y + row_h, w, h - row_h, rects);
    }
}

fn worst_aspect_ratio(row: &[(usize, u64)], row_sum: f64, row_side: f64, fixed_side: f64) -> f64 {
    if row_sum <= 0.0 || row_side <= 0.0 || fixed_side <= 0.0 {
        return f64::MAX;
    }

    let mut worst = 0.0_f64;
    for &(_, size) in row {
        let item_frac = size as f64 / row_sum;
        let item_side = fixed_side * item_frac;
        if item_side <= 0.0 || row_side <= 0.0 {
            continue;
        }
        let ratio = if row_side > item_side {
            row_side / item_side
        } else {
            item_side / row_side
        };
        worst = worst.max(ratio);
    }
    worst
}
