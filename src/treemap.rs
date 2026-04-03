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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_empty() {
        let rects = layout(&[], 100.0, 100.0);
        assert!(rects.is_empty());
    }

    #[test]
    fn layout_single_item() {
        let rects = layout(&[1000], 80.0, 40.0);
        assert_eq!(rects.len(), 1);
        assert!((rects[0].x - 0.0).abs() < f64::EPSILON);
        assert!((rects[0].y - 0.0).abs() < f64::EPSILON);
        assert!((rects[0].w - 80.0).abs() < f64::EPSILON);
        assert!((rects[0].h - 40.0).abs() < f64::EPSILON);
        assert_eq!(rects[0].index, 0);
    }

    #[test]
    fn layout_preserves_total_area() {
        let sizes = vec![500, 300, 200, 100, 50];
        let w = 120.0;
        let h = 60.0;
        let rects = layout(&sizes, w, h);

        assert_eq!(rects.len(), sizes.len());

        let total_area: f64 = rects.iter().map(|r| r.w * r.h).sum();
        let expected_area = w * h;
        // Allow small floating point error
        assert!(
            (total_area - expected_area).abs() < 1.0,
            "Total area {} should be close to {}",
            total_area,
            expected_area
        );
    }

    #[test]
    fn layout_rects_within_bounds() {
        let sizes = vec![1000, 800, 400, 200, 100, 50];
        let w = 100.0;
        let h = 50.0;
        let rects = layout(&sizes, w, h);

        for rect in &rects {
            assert!(rect.x >= -0.001, "x={} out of bounds", rect.x);
            assert!(rect.y >= -0.001, "y={} out of bounds", rect.y);
            assert!(
                rect.x + rect.w <= w + 0.001,
                "x+w={} exceeds width {}",
                rect.x + rect.w,
                w
            );
            assert!(
                rect.y + rect.h <= h + 0.001,
                "y+h={} exceeds height {}",
                rect.y + rect.h,
                h
            );
        }
    }

    #[test]
    fn layout_proportional_sizes() {
        // Two items, one twice the size of the other
        let rects = layout(&[200, 100], 90.0, 30.0);
        assert_eq!(rects.len(), 2);

        let area_0 = rects[0].w * rects[0].h;
        let area_1 = rects[1].w * rects[1].h;

        let ratio = area_0 / area_1;
        assert!(
            (ratio - 2.0).abs() < 0.1,
            "Area ratio should be ~2.0, got {}",
            ratio
        );
    }

    #[test]
    fn layout_indices_correct() {
        let sizes = vec![500, 300, 100];
        let rects = layout(&sizes, 60.0, 40.0);

        let mut indices: Vec<usize> = rects.iter().map(|r| r.index).collect();
        indices.sort();
        assert_eq!(indices, vec![0, 1, 2]);
    }

    #[test]
    fn layout_no_zero_dimension_rects() {
        let sizes = vec![1000, 500, 250, 125];
        let rects = layout(&sizes, 80.0, 40.0);

        for rect in &rects {
            assert!(rect.w > 0.0, "Width should be positive");
            assert!(rect.h > 0.0, "Height should be positive");
        }
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
